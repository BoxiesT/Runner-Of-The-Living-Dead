@tool
class_name GLCSessionManager
extends Node
## Star-topology session over SceneMultiplayer + ENet (UDP), meant for a local network or a LAN-emulating
## VPN such as Radmin VPN. There is deliberately no internet/tunnel transport.
##
## * With `lan_only` (default) the host refuses any peer whose address is not a LAN/VPN address
##   (see GLCProtocol.is_lan_address) before the handshake even starts.
## * Authentication runs inside SceneMultiplayer's auth phase (HMAC challenge/response): a peer that
##   fails never becomes "connected" and never receives anything.
## * All traffic uses send_bytes() with our own framing (no RPC, no node-path coupling).
## * Message kinds registered by the sync modules:
##     "op"     client -> host (handler may canonicalize / reject) -> host sequences it, relays the
##              canonical op to the other subscribers and acks the origin (with optional corrections).
##     "bcast"  best-effort fan-out through the host (presence, cursors, transform hints).
##     "direct" point-to-point request / response.

signal session_started(is_host: bool)
signal session_ended(reason: String)
signal connection_state_changed(state: String, detail: String)
signal peers_changed()
signal peer_joined(peer_id: int, info: Dictionary)
signal peer_left(peer_id: int, info: Dictionary)
signal log_line(text: String, level: int)

const AUTH_TIMEOUT_S := 10.0
const PEER_TIMEOUT_MS := 25000
const PING_INTERVAL_MS := 2000
const CONNECT_TIMEOUT_MS := 15000
## Bulk (file) bytes handed to ENet per second of frame time. The editor may run at ~10 fps when its
## window is not focused, so the budget scales with the frame delta instead of being per frame.
const BULK_BYTES_PER_SECOND := 40 * 1024 * 1024
const BULK_MIN_PER_FRAME := 256 * 1024
const BULK_MAX_PER_FRAME := 6 * 1024 * 1024
const RECONNECT_DELAYS := [1.0, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0, 30.0, 30.0, 30.0]

var mp: SceneMultiplayer = null
var is_hosting: bool = false
var is_active_session: bool = false
var peers: Dictionary = {}            # peer_id -> {name, color, rtt, host, scene, ip, ...}
var local_name: String = "User"
var local_color: Color = Color.SPRING_GREEN
var session_id: String = ""
var session_password: String = ""
var session_port: int = 0
var seq: int = 0
var last_error: String = ""
var state: String = "idle"
var rtt_ms: int = 0
## User option: try to reconnect automatically when the connection to the host drops.
var auto_reconnect: bool = true
## Host: only accept peers coming from LAN / VPN addresses.
var lan_only: bool = true
var verbose: bool = false

# traffic counters (shown in the dock)
var bytes_sent: int = 0
var bytes_received: int = 0
var packets_sent: int = 0
var packets_received: int = 0

var _handlers: Dictionary = {}
var _subs: Dictionary = {}            # host: channel -> {peer_id: true}
var _my_subs: Dictionary = {}         # client: channel -> true
var _auth_pending: Dictionary = {}    # host: peer_id -> {nonce, info}
var _next_op_id: int = 1
var _pending_acks: Dictionary = {}    # client: op_id -> {ack: Callable, rej: Callable}
var _bulk_queue: Array = []
var _last_rx: Dictionary = {}
var _last_ping_ms: int = 0
var _connect_started_ms: int = 0
var _join_args: Dictionary = {}
var _reconnect_attempt: int = 0
var _reconnect_timer: Timer = null
var _reconnecting: bool = false
## Set when the host refused us (wrong password, version...): retrying would only fail again.
var _no_retry: bool = false
var _closing: bool = false
var _bulk_delta: float = 0.016
## SceneMultiplayer emits several signals from inside poll(); dropping the last reference to it there
## is a use-after-free. Old instances are parked here and released at the start of the next frame.
var _graveyard: Array = []

func _ready() -> void:
	set_process(true)
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_attempt_reconnect)
	add_child(_reconnect_timer)

func _exit_tree() -> void:
	close_session("plugin disabled", false)

# =========================================================================== public API

func local_id() -> int:
	if mp != null and mp.multiplayer_peer != null and mp.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return mp.get_unique_id()
	return 0

func is_connected_to_session() -> bool:
	return is_active_session

func peer_name(id: int) -> String:
	return String(peers.get(id, {}).get("name", "peer %d" % id))

func peer_color(id: int) -> Color:
	var c: Variant = peers.get(id, {}).get("color", Color.WHITE)
	return c if c is Color else Color.WHITE

## kind: "op" | "bcast" | "direct";  opts: {scope: "all"|"scene"|"doc", reliable: bool}
## handler(sender: int, payload: Dictionary, meta: Dictionary) -> Variant
##   op @host   : return canonical payload (Dictionary) or null to reject (set meta["reason"], optional meta["corr"])
##   op @client : apply a canonical operation made by meta["origin"]
func register(t: String, handler: Callable, kind: String = "op", opts: Dictionary = {}) -> void:
	_handlers[t] = {"cb": handler, "kind": kind, "scope": String(opts.get("scope", "all")), "reliable": bool(opts.get("reliable", true))}

func unregister(t: String) -> void:
	_handlers.erase(t)

func next_op_id() -> int:
	var id := _next_op_id
	_next_op_id += 1
	return id

## Submit a locally-made change. Host: sequences + relays. Client: sends to host, `on_ack(corr, seq)` / `on_rej(reason)` later.
func submit(op_id: int, t: String, payload: Dictionary, on_ack: Callable = Callable(), on_rej: Callable = Callable()) -> bool:
	if not is_active_session:
		return false
	var reg: Variant = _handlers.get(t)
	if reg == null:
		push_warning("GLC: submit of unregistered type " + t)
		return false
	if is_hosting:
		seq += 1
		_route(reg, payload, {"t": t, "p": payload, "o": 1, "q": seq}, 1)
		return true
	_pending_acks[op_id] = {"ack": on_ack, "rej": on_rej}
	_send(1, {"t": t, "p": payload, "i": op_id}, true)
	return true

## Best-effort broadcast to everyone else (scope applies on the host).
func bcast(t: String, payload: Dictionary) -> void:
	if not is_active_session:
		return
	var reg: Variant = _handlers.get(t)
	if reg == null:
		return
	if is_hosting:
		_route(reg, payload, {"t": t, "p": payload, "o": 1}, 1)
	else:
		_send(1, {"t": t, "p": payload}, bool(reg["reliable"]))

func send_to(peer_id: int, t: String, payload: Dictionary, reliable: bool = true) -> void:
	if not is_active_session:
		return
	_send(peer_id, {"t": t, "p": payload}, reliable)

## Low-priority / large transfers: drained by a byte budget on a separate ENet channel, so live
## operations are never queued behind file data.
func queue_to(peer_id: int, t: String, payload: Dictionary) -> void:
	if not is_active_session:
		return
	var bytes := GLCProtocol.pack({"t": t, "p": payload})
	_bulk_bytes += bytes.size()
	_bulk_queue.append({"peer": peer_id, "bytes": bytes})

var _bulk_bytes: int = 0

func bulk_backlog_bytes() -> int:
	return _bulk_bytes

func subscribe(channel: String) -> void:
	_my_subs[channel] = true
	if is_active_session and not is_hosting:
		_send(1, {"t": GLCProtocol.C_SUB, "p": {"ch": channel}}, true)

func unsubscribe(channel: String) -> void:
	_my_subs.erase(channel)
	if is_active_session and not is_hosting:
		_send(1, {"t": GLCProtocol.C_UNSUB, "p": {"ch": channel}}, true)

func subscribers_of(channel: String) -> Array:
	return (_subs.get(channel, {}) as Dictionary).keys()

## Merge presence-level info about *this* peer (active scene, ...); host rebroadcasts the table.
func publish_info(info: Dictionary) -> void:
	if not is_active_session:
		return
	if is_hosting:
		_merge_peer_info(1, info)
	else:
		_send(1, {"t": GLCProtocol.C_INFO, "p": info}, true)

func notify_all(text: String, level: int = 0) -> void:
	# host-only: an event line shown in every dock's activity feed
	if is_hosting and is_active_session:
		for pid in peers:
			if pid != 1:
				_send(pid, {"t": GLCProtocol.C_NOTICE, "p": {"text": text, "level": level}}, true)

# =========================================================================== hosting / joining

func host_session(port: int, password: String, user_name: String, color: Color) -> int:
	if port < 1 or port > 65535:
		return _fail("Porta inválida (%d): use um valor entre 1 e 65535" % port, ERR_INVALID_PARAMETER)
	# a session still running ends properly first (the sync modules drop its bindings and models)
	close_session("restart", is_active_session)
	_closing = false
	_join_args = {}
	local_name = user_name
	local_color = color
	session_password = password
	var en := ENetMultiplayerPeer.new()
	var eerr := en.create_server(port, GLCProtocol.MAX_PEERS, GLCProtocol.ENET_CHANNELS)
	if eerr != OK:
		return _fail("Falha ao abrir a sessão na porta %d (já está em uso?): %s" % [port, error_string(eerr)], eerr)
	is_hosting = true
	session_id = GLCProtocol.new_uid()
	session_port = port
	seq = 0
	_setup_mp(en)
	peers = {1: {"name": local_name, "color": local_color, "rtt": 0, "host": true}}
	is_active_session = true
	_set_state("hosting", "porta %d" % port)
	_log("Sessão hospedada na porta %d (%s)" % [port, "somente rede local/VPN" if lan_only else "qualquer endereço"])
	session_started.emit(true)
	peers_changed.emit()
	return OK

func join_session(address: String, port: int, password: String, user_name: String, color: Color) -> int:
	if port < 1 or port > 65535:
		return _fail("Porta inválida (%d): use um valor entre 1 e 65535" % port, ERR_INVALID_PARAMETER)
	address = address.strip_edges()
	if address.is_empty():
		return _fail("Informe o endereço do host", ERR_INVALID_PARAMETER)
	if address.contains("://") or address.contains("/"):
		return _fail("Use só o IP do host (ex.: 192.168.0.10 ou 26.x.x.x do Radmin VPN)", ERR_INVALID_PARAMETER)
	if lan_only:
		var resolved := address if address.is_valid_ip_address() else IP.resolve_hostname(address)
		if resolved.is_empty():
			return _fail("Não foi possível resolver o endereço \"%s\"" % address, ERR_CANT_RESOLVE)
		if not GLCProtocol.is_lan_address(resolved):
			return _fail("%s não é um endereço de rede local/VPN. O Live Collab só conecta na rede local (ou Radmin VPN)." % resolved, ERR_UNAUTHORIZED)
	close_session("join", is_active_session)
	_closing = false
	_no_retry = false
	_reconnect_attempt = 0
	_join_args = {"address": address, "port": port, "password": password, "name": user_name, "color": color}
	return _connect_with(_join_args)

func _connect_with(a: Dictionary) -> int:
	_client_nonce = PackedByteArray()
	local_name = a["name"]
	local_color = a["color"]
	session_password = a["password"]
	session_port = int(a["port"])
	var en := ENetMultiplayerPeer.new()
	var eerr := en.create_client(String(a["address"]), int(a["port"]), GLCProtocol.ENET_CHANNELS)
	if eerr != OK:
		return _fail("Falha ao conectar: %s" % error_string(eerr), eerr)
	is_hosting = false
	_setup_mp(en)
	_connect_started_ms = Time.get_ticks_msec()
	_set_state("connecting", "%s:%d" % [a["address"], int(a["port"])])
	return OK

## The user left on purpose: never reconnect.
func leave(reason: String = "você saiu") -> void:
	_join_args = {}
	close_session(reason)

func close_session(reason: String = "closed", allow_events: bool = true) -> void:
	var was_active := is_active_session
	_closing = true
	_reconnecting = false
	if _reconnect_timer != null:
		_reconnect_timer.stop()
	if mp != null:
		if mp.multiplayer_peer != null:
			mp.multiplayer_peer.close()
		mp.multiplayer_peer = null
		_graveyard.append(mp)
	mp = null
	var old_peers := peers
	peers = {}
	_subs.clear()
	_my_subs.clear()
	_auth_pending.clear()
	_pending_acks.clear()
	_bulk_queue.clear()
	_bulk_bytes = 0
	_last_rx.clear()
	is_active_session = false
	is_hosting = false
	rtt_ms = 0
	if was_active and allow_events:
		session_ended.emit(reason)
		peers_changed.emit()
	if state != "idle" and allow_events:
		_set_state("idle", reason)
	elif not allow_events:
		state = "idle"
	old_peers.clear()

func _setup_mp(peer: MultiplayerPeer) -> void:
	mp = SceneMultiplayer.new()
	mp.root_path = get_path() if is_inside_tree() else NodePath("/root")
	mp.server_relay = false
	mp.allow_object_decoding = false
	mp.auth_timeout = AUTH_TIMEOUT_S
	mp.auth_callback = Callable(self, "_on_auth_data")
	mp.peer_authenticating.connect(_on_peer_authenticating)
	mp.peer_authentication_failed.connect(_on_peer_auth_failed)
	mp.peer_connected.connect(_on_peer_connected)
	mp.peer_disconnected.connect(_on_peer_disconnected)
	mp.connected_to_server.connect(_on_connected_to_server)
	mp.connection_failed.connect(_on_connection_failed)
	mp.server_disconnected.connect(_on_server_disconnected)
	mp.peer_packet.connect(_on_peer_packet)
	mp.multiplayer_peer = peer

# =========================================================================== auth

## Remote address of a connected ENet peer ("" if unknown).
func peer_address(id: int) -> String:
	if mp == null or not (mp.multiplayer_peer is ENetMultiplayerPeer):
		return ""
	var en := mp.multiplayer_peer as ENetMultiplayerPeer
	var pp: ENetPacketPeer = en.get_peer(id)
	return pp.get_remote_address() if pp != null else ""

func _on_peer_authenticating(id: int) -> void:
	if is_hosting:
		var addr := peer_address(id)
		if lan_only and not addr.is_empty() and not GLCProtocol.is_lan_address(addr):
			_log("Conexão de %s recusada: fora da rede local/VPN" % addr, 1)
			_reject_auth(id, "o host só aceita conexões da rede local ou VPN (Radmin, Hamachi...)")
			return
		var nonce := GLCProtocol.random_bytes(16)
		_auth_pending[id] = {"nonce": nonce, "info": {}, "ip": addr}
		mp.send_auth(id, var_to_bytes({"k": "challenge", "ver": GLCProtocol.VERSION, "nonce": nonce, "sid": session_id, "pw": not session_password.is_empty()}))
	else:
		_set_state("authenticating", "")

func _on_peer_auth_failed(id: int) -> void:
	_auth_pending.erase(id)
	if is_hosting:
		_log("Conexão de peer %d não concluiu a autenticação" % id, 1)
	else:
		last_error = "Falha na autenticação com o host"
		_log(last_error, 2)

func _on_auth_data(id: int, data: PackedByteArray) -> void:
	var d: Variant = bytes_to_var(data)
	if not (d is Dictionary):
		_reject_auth(id, "mensagem inválida")
		return
	if is_hosting:
		if d.get("k", "") != "join":
			return
		if int(d.get("ver", 0)) != GLCProtocol.VERSION:
			_reject_auth(id, "versões incompatíveis (host v%d, você v%d)" % [GLCProtocol.VERSION, int(d.get("ver", 0))])
			return
		if peers.size() >= GLCProtocol.MAX_PEERS:
			_reject_auth(id, "sessão cheia")
			return
		var pend: Dictionary = _auth_pending.get(id, {})
		if pend.is_empty():
			_reject_auth(id, "sem desafio pendente")
			return
		var expected := GLCProtocol.hmac_sha256(session_password, pend["nonce"])
		var proof: Variant = d.get("proof", PackedByteArray())
		if not (proof is PackedByteArray) or proof != expected:
			_reject_auth(id, "senha incorreta")
			return
		var nm := String(d.get("name", "User")).strip_edges().substr(0, 32)
		if nm.is_empty():
			nm = "User"
		var base := nm
		var n := 2
		var names := []
		for p in peers.values():
			names.append(p.get("name", ""))
		while nm in names:
			nm = "%s #%d" % [base, n]
			n += 1
		var col: Variant = d.get("color", GLCProtocol.color_for_name(nm))
		pend["info"] = {"name": nm, "color": col if col is Color else GLCProtocol.color_for_name(nm), "rtt": 0, "host": false, "joined": Time.get_unix_time_from_system(), "ip": String(pend.get("ip", ""))}
		_auth_pending[id] = pend
		# prove to the client that we know the password too (mutual authentication)
		var cn: Variant = d.get("cn", PackedByteArray())
		var hp := GLCProtocol.hmac_sha256(session_password, _host_proof_msg(cn if cn is PackedByteArray else PackedByteArray()))
		mp.send_auth(id, var_to_bytes({"k": "accept", "sid": session_id, "your_id": id, "your_name": nm, "host_name": local_name, "ver": GLCProtocol.VERSION, "hp": hp}))
		mp.complete_auth(id)
	else:
		match String(d.get("k", "")):
			"challenge":
				if int(d.get("ver", 0)) != GLCProtocol.VERSION:
					last_error = "Versão do protocolo incompatível (host v%d, você v%d)" % [int(d.get("ver", 0)), GLCProtocol.VERSION]
					_fail_client_async(last_error)
					return
				var proof := GLCProtocol.hmac_sha256(session_password, d.get("nonce", PackedByteArray()))
				_client_nonce = GLCProtocol.random_bytes(16)
				mp.send_auth(id, var_to_bytes({"k": "join", "ver": GLCProtocol.VERSION, "name": local_name, "color": local_color, "proof": proof, "cn": _client_nonce}))
			"accept":
				# only valid after THIS connection's challenge (no replay of an old acceptance)
				var expected_hp := GLCProtocol.hmac_sha256(session_password, _host_proof_msg(_client_nonce))
				var hp: Variant = d.get("hp", PackedByteArray())
				if _client_nonce.is_empty() or not (hp is PackedByteArray) or hp != expected_hp:
					last_error = "O host não comprovou a senha da sessão (endereço errado ou possível impostor na rede)"
					_no_retry = true
					_fail_client_async(last_error)
					return
				session_id = String(d.get("sid", ""))
				local_name = String(d.get("your_name", local_name))
				mp.complete_auth(id)
			"reject":
				last_error = "Entrada recusada: " + String(d.get("reason", "?"))
				_no_retry = true
				_fail_client_async(last_error)

var _client_nonce: PackedByteArray = PackedByteArray()

static func _host_proof_msg(client_nonce: PackedByteArray) -> PackedByteArray:
	var m := "glc-host-proof:".to_utf8_buffer()
	m.append_array(client_nonce)
	return m

func _reject_auth(id: int, reason: String) -> void:
	_log("Peer %d recusado: %s" % [id, reason], 1)
	if mp != null:
		mp.send_auth(id, var_to_bytes({"k": "reject", "reason": reason}))
	_auth_pending.erase(id)
	var t := get_tree().create_timer(0.5)
	t.timeout.connect(func():
		if mp != null and mp.multiplayer_peer != null:
			mp.multiplayer_peer.disconnect_peer(id)
	)

func _fail_client_async(msg: String) -> void:
	# called from inside the auth callback: tear down on the next frame
	_log(msg, 2)
	call_deferred("_client_auth_failed", msg)

func _client_auth_failed(msg: String) -> void:
	close_session(msg, true)
	_set_state("error", msg)

# =========================================================================== connection events

func _on_peer_connected(id: int) -> void:
	_last_rx[id] = Time.get_ticks_msec()
	if not is_hosting:
		return
	var pend: Dictionary = _auth_pending.get(id, {})
	_auth_pending.erase(id)
	var info: Dictionary = pend.get("info", {"name": "peer %d" % id, "color": Color.WHITE, "rtt": 0, "host": false})
	peers[id] = info
	_log("%s entrou (peer %d)" % [info["name"], id])
	peer_joined.emit(id, info)
	_broadcast_peers()
	notify_all("%s entrou na sessão" % info["name"])

func _on_peer_disconnected(id: int) -> void:
	_last_rx.erase(id)
	if is_hosting:
		var info: Dictionary = peers.get(id, {})
		peers.erase(id)
		for ch in _subs.keys():
			(_subs[ch] as Dictionary).erase(id)
		_bulk_queue = _bulk_queue.filter(func(e): return e["peer"] != id)
		_bulk_bytes = 0
		for e in _bulk_queue:
			_bulk_bytes += (e["bytes"] as PackedByteArray).size()
		if not info.is_empty():
			_log("%s saiu" % info.get("name", "peer %d" % id))
			peer_left.emit(id, info)
			_broadcast_peers()
			notify_all("%s saiu da sessão" % info.get("name", "?"))

func _on_connected_to_server() -> void:
	is_active_session = true
	_reconnecting = false
	_reconnect_attempt = 0
	_last_rx[1] = Time.get_ticks_msec()
	peers = {1: {"name": "host", "color": Color.WHITE, "rtt": 0, "host": true, "ip": String(_join_args.get("address", ""))}}
	_set_state("connected", "id %d" % mp.get_unique_id())
	_log("Conectado ao host")
	session_started.emit(false)
	peers_changed.emit()

func _on_connection_failed() -> void:
	call_deferred("_handle_connection_failed")

func _handle_connection_failed() -> void:
	if _closing or mp == null:
		return
	_log("Falha ao conectar ao host", 2)
	last_error = "Não foi possível conectar ao host"
	var keep := _reconnecting
	_teardown_transport()
	if keep and auto_reconnect and not _no_retry and _reconnect_attempt < RECONNECT_DELAYS.size():
		_schedule_reconnect()
	else:
		_set_state("error", last_error)
		session_ended.emit(last_error)

func _on_server_disconnected() -> void:
	call_deferred("_handle_server_disconnected")

func _handle_server_disconnected() -> void:
	if _closing or mp == null:
		return
	var was_active := is_active_session
	_log("Conexão com o host perdida", 2)
	last_error = "Conexão com o host perdida"
	_teardown_transport()
	if was_active:
		session_ended.emit(last_error)
		peers_changed.emit()
	if auto_reconnect and not _no_retry and not _join_args.is_empty() and _reconnect_attempt < RECONNECT_DELAYS.size():
		_reconnecting = true
		_schedule_reconnect()
	else:
		_set_state("disconnected", last_error)

func _teardown_transport() -> void:
	if mp != null:
		if mp.multiplayer_peer != null:
			mp.multiplayer_peer.close()
		mp.multiplayer_peer = null
		_graveyard.append(mp)
	mp = null
	is_active_session = false
	is_hosting = false
	peers = {}
	_pending_acks.clear()
	_bulk_queue.clear()
	_bulk_bytes = 0
	_subs.clear()
	_my_subs.clear()
	_last_rx.clear()

func _schedule_reconnect() -> void:
	_reconnecting = true
	var delay: float = RECONNECT_DELAYS[mini(_reconnect_attempt, RECONNECT_DELAYS.size() - 1)]
	_set_state("reconnecting", "tentativa %d em %.0fs" % [_reconnect_attempt + 1, delay])
	_reconnect_timer.start(delay)

func _attempt_reconnect() -> void:
	if _join_args.is_empty() or _closing:
		return
	_reconnect_attempt += 1
	var err := _connect_with(_join_args)
	if err != OK:
		if _reconnect_attempt < RECONNECT_DELAYS.size():
			_schedule_reconnect()
		else:
			_set_state("error", "reconexão esgotada")
	else:
		_reconnecting = true

## Manual reconnect from the UI after the automatic attempts were exhausted.
func reconnect_now() -> void:
	if _join_args.is_empty():
		return
	_reconnect_attempt = 0
	_no_retry = false
	_reconnecting = true
	_attempt_reconnect()

# =========================================================================== process

func _process(delta: float) -> void:
	if not _graveyard.is_empty():
		_graveyard.clear()
	if mp == null:
		return
	_bulk_delta = delta
	mp.poll()
	if mp == null:
		return
	var now := Time.get_ticks_msec()
	# connect timeout (client)
	if not is_hosting and not is_active_session and state in ["connecting", "authenticating"] and now - _connect_started_ms > CONNECT_TIMEOUT_MS:
		_handle_connection_failed()
		return
	if is_active_session:
		_drain_bulk()
		if now - _last_ping_ms >= PING_INTERVAL_MS:
			_last_ping_ms = now
			if is_hosting:
				for pid in peers.keys():
					if pid != 1 and now - int(_last_rx.get(pid, now)) > PEER_TIMEOUT_MS:
						_log("%s não responde, desconectando" % peer_name(pid), 1)
						if mp != null and mp.multiplayer_peer != null:
							mp.multiplayer_peer.disconnect_peer(pid)
			else:
				_send(1, {"t": GLCProtocol.C_PING, "p": {"ts": now, "rtt": rtt_ms}}, false)
				if now - int(_last_rx.get(1, now)) > PEER_TIMEOUT_MS:
					_handle_server_disconnected()

func _drain_bulk() -> void:
	var budget := clampi(int(BULK_BYTES_PER_SECOND * _bulk_delta), BULK_MIN_PER_FRAME, BULK_MAX_PER_FRAME)
	while not _bulk_queue.is_empty() and budget > 0:
		var e: Dictionary = _bulk_queue.pop_front()
		var bytes: PackedByteArray = e["bytes"]
		budget -= bytes.size()
		_bulk_bytes -= bytes.size()
		_send_bytes(int(e["peer"]), bytes, true, GLCProtocol.CHANNEL_BULK)
	if _bulk_queue.is_empty():
		_bulk_bytes = 0

# =========================================================================== packets

func _send(peer_id: int, msg: Dictionary, reliable: bool) -> void:
	_send_bytes(peer_id, GLCProtocol.pack(msg), reliable)

func _send_bytes(peer_id: int, bytes: PackedByteArray, reliable: bool, channel: int = GLCProtocol.CHANNEL_LIVE) -> void:
	if mp == null or mp.multiplayer_peer == null:
		return
	if mp.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	var mode := MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
	bytes_sent += bytes.size()
	packets_sent += 1
	var err := mp.send_bytes(bytes, peer_id, mode, channel)
	if err != OK and verbose:
		_log("send_bytes -> %d falhou: %s" % [peer_id, error_string(err)], 1)

func _on_peer_packet(sender: int, bytes: PackedByteArray) -> void:
	bytes_received += bytes.size()
	packets_received += 1
	_last_rx[sender] = Time.get_ticks_msec()
	var msg: Variant = GLCProtocol.unpack(bytes)
	if not (msg is Dictionary):
		return
	var t := String(msg.get("t", ""))
	if t.begins_with("c."):
		_on_control(sender, t, msg)
		return
	var reg: Variant = _handlers.get(t)
	if reg == null:
		if verbose:
			_log("mensagem sem handler: " + t, 1)
		return
	var p: Dictionary = msg.get("p", {}) if msg.get("p", {}) is Dictionary else {}
	match String(reg["kind"]):
		"direct":
			(reg["cb"] as Callable).call(sender, p, {"stage": "direct", "origin": sender})
		"bcast":
			_on_bcast(sender, msg, p, reg)
		"op":
			_on_op(sender, msg, p, reg)

func _on_bcast(sender: int, msg: Dictionary, p: Dictionary, reg: Dictionary) -> void:
	if is_hosting:
		if not peers.has(sender):
			return
		var meta := {"stage": "host", "origin": sender}
		var out: Variant = (reg["cb"] as Callable).call(sender, p, meta)
		if out is Dictionary:
			p = out
		elif out == null and meta.get("drop", false):
			return
		_route(reg, p, {"t": msg["t"], "p": p, "o": sender}, sender)
	else:
		(reg["cb"] as Callable).call(1, p, {"stage": "client", "origin": int(msg.get("o", 1))})

func _on_op(sender: int, msg: Dictionary, p: Dictionary, reg: Dictionary) -> void:
	if is_hosting:
		if not peers.has(sender):
			return
		var meta := {"stage": "host", "origin": sender, "reason": "", "corr": {}}
		var canon: Variant = (reg["cb"] as Callable).call(sender, p, meta)
		if not (canon is Dictionary):
			_send(sender, {"t": GLCProtocol.C_REJ, "i": msg.get("i", 0), "r": String(meta.get("reason", ""))}, true)
			return
		seq += 1
		_route(reg, canon, {"t": msg["t"], "p": canon, "o": sender, "q": seq}, sender)
		_send(sender, {"t": GLCProtocol.C_ACK, "i": msg.get("i", 0), "q": seq, "c": meta.get("corr", {})}, true)
	else:
		seq = maxi(seq, int(msg.get("q", seq)))
		(reg["cb"] as Callable).call(1, p, {"stage": "client", "origin": int(msg.get("o", 1)), "seq": int(msg.get("q", 0))})

func _route(reg: Dictionary, payload: Dictionary, out: Dictionary, exclude: int) -> void:
	var targets: Array = []
	match String(reg["scope"]):
		"scene":
			targets = (_subs.get("scene:" + String(payload.get("scene", "")), {}) as Dictionary).keys()
		"doc":
			targets = (_subs.get("doc:" + String(payload.get("path", "")), {}) as Dictionary).keys()
		_:
			targets = peers.keys()
	if targets.is_empty():
		return
	var bytes := GLCProtocol.pack(out)
	var reliable: bool = bool(reg["reliable"])
	for pid in targets:
		if pid != exclude and pid != 1 and peers.has(pid):
			_send_bytes(pid, bytes, reliable)

func _on_control(sender: int, t: String, msg: Dictionary) -> void:
	var p: Dictionary = msg.get("p", {}) if msg.get("p", {}) is Dictionary else {}
	match t:
		GLCProtocol.C_PING:
			if is_hosting and peers.has(sender):
				peers[sender]["rtt"] = int(p.get("rtt", 0))
				_send(sender, {"t": GLCProtocol.C_PONG, "p": {"ts": p.get("ts", 0)}}, false)
		GLCProtocol.C_PONG:
			rtt_ms = Time.get_ticks_msec() - int(p.get("ts", 0))
		GLCProtocol.C_PEERS:
			if not is_hosting:
				var incoming: Variant = p.get("peers", {})
				if incoming is Dictionary:
					var old := peers
					peers = incoming
					for id in peers:
						if not old.has(id) and id != mp.get_unique_id():
							peer_joined.emit(id, peers[id])
					for id in old:
						if not peers.has(id):
							peer_left.emit(id, old[id])
					peers_changed.emit()
		GLCProtocol.C_ACK:
			if not is_hosting:
				var pend: Variant = _pending_acks.get(int(msg.get("i", 0)))
				_pending_acks.erase(int(msg.get("i", 0)))
				seq = maxi(seq, int(msg.get("q", seq)))
				if pend != null and (pend["ack"] as Callable).is_valid():
					(pend["ack"] as Callable).call(msg.get("c", {}), int(msg.get("q", 0)))
		GLCProtocol.C_REJ:
			if not is_hosting:
				var pend2: Variant = _pending_acks.get(int(msg.get("i", 0)))
				_pending_acks.erase(int(msg.get("i", 0)))
				if pend2 != null and (pend2["rej"] as Callable).is_valid():
					(pend2["rej"] as Callable).call(String(msg.get("r", "")))
		GLCProtocol.C_SUB:
			if is_hosting and peers.has(sender):
				var ch := String(p.get("ch", ""))
				if not _subs.has(ch):
					_subs[ch] = {}
				_subs[ch][sender] = true
		GLCProtocol.C_UNSUB:
			if is_hosting and _subs.has(String(p.get("ch", ""))):
				(_subs[String(p.get("ch", ""))] as Dictionary).erase(sender)
		GLCProtocol.C_INFO:
			if is_hosting and peers.has(sender):
				_merge_peer_info(sender, p)
		GLCProtocol.C_NOTICE:
			log_line.emit(String(p.get("text", "")), int(p.get("level", 0)))

func _merge_peer_info(id: int, info: Dictionary) -> void:
	if not peers.has(id):
		return
	var changed := false
	for k in info:
		if peers[id].get(k) != info[k]:
			peers[id][k] = info[k]
			changed = true
	if changed:
		_broadcast_peers()
		peers_changed.emit()

func _broadcast_peers() -> void:
	for pid in peers.keys():
		if pid != 1:
			_send(pid, {"t": GLCProtocol.C_PEERS, "p": {"peers": peers}}, true)
	peers_changed.emit()

# =========================================================================== misc

func _set_state(s: String, detail: String) -> void:
	state = s
	connection_state_changed.emit(s, detail)

func _fail(msg: String, err: int) -> int:
	last_error = msg
	_log(msg, 2)
	_set_state("error", msg)
	return err

func _log(text: String, level: int = 0) -> void:
	# (shown in the dock; engine warnings only in verbose mode, so the editor is not flooded with alerts)
	if verbose and level == 2:
		push_warning("[GLC] " + text)
	log_line.emit(text, level)
