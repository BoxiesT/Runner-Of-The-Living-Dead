@tool
class_name GLCLanDiscovery
extends RefCounted
## Finds Live Collab sessions on the local network (LAN, Radmin VPN, Hamachi, ZeroTier...).
##
## * A peer that is not in a session broadcasts a tiny UDP query every QUERY_INTERVAL_MS on every local
##   network interface (one socket bound per interface, so VPN adapters such as Radmin are included).
## * A host listens on GLCProtocol.DISCOVERY_PORT and answers (unicast) with the session name, project
##   and port, only to LAN/VPN addresses. Nothing is sent outside the local network.

signal sessions_changed()

const QUERY_INTERVAL_MS := 1500
const EXPIRE_MS := 5500
const IFACE_REFRESH_MS := 10000

var session: GLCSessionManager
var enabled: bool = true
## UDP port of the discovery protocol (only tests change it, to stay away from real sessions)
var port: int = GLCProtocol.DISCOVERY_PORT
## sid -> {ip, port, name, project, pw, peers, t}
var sessions: Dictionary = {}
var host_listening: bool = false
var host_listen_error: String = ""

var _listener: PacketPeerUDP = null
var _senders: Array = []            # PacketPeerUDP, one per local interface address (+ one on loopback)
var _last_query_ms: int = -100000
var _last_iface_ms: int = -100000
var _last_listen_try_ms: int = -100000

func _init(p_session: GLCSessionManager) -> void:
	session = p_session

func stop() -> void:
	_close_listener()
	_close_senders()
	sessions.clear()

func process() -> void:
	if not enabled:
		if _listener != null or not _senders.is_empty():
			stop()
		return
	var now := Time.get_ticks_msec()
	# ---- host side: answer queries
	if session.is_hosting and session.is_active_session:
		if _listener == null and now - _last_listen_try_ms > 3000:
			_last_listen_try_ms = now
			_open_listener()
		_serve()
	else:
		_close_listener()
	# ---- browsing side: look for hosts while we are not in a session
	var browsing := not session.is_active_session and session.state not in ["connecting", "authenticating"]
	if browsing:
		if _senders.is_empty() or now - _last_iface_ms > IFACE_REFRESH_MS:
			_last_iface_ms = now
			_open_senders()
		if now - _last_query_ms > QUERY_INTERVAL_MS:
			_last_query_ms = now
			_send_queries()
		_read_replies()
	elif not _senders.is_empty():
		_close_senders()
	_expire(now)

# ---------------------------------------------------------------- host

func _open_listener() -> void:
	var l := PacketPeerUDP.new()
	var err := l.bind(port, "*")
	if err != OK:
		host_listening = false
		host_listen_error = "porta de descoberta %d em uso (outra instância hospedando?)" % port
		return
	_listener = l
	host_listening = true
	host_listen_error = ""

func _close_listener() -> void:
	if _listener != null:
		_listener.close()
		_listener = null
	host_listening = false

func _serve() -> void:
	if _listener == null:
		return
	var guard := 0
	while _listener.get_available_packet_count() > 0 and guard < 32:
		guard += 1
		var pkt := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var reply_port := _listener.get_packet_port()
		if session.lan_only and not GLCProtocol.is_lan_address(ip):
			continue
		var q: Variant = JSON.parse_string(pkt.get_string_from_utf8())
		if not (q is Dictionary) or String(q.get("m", "")) != GLCProtocol.DISCOVERY_MAGIC or String(q.get("k", "")) != "q":
			continue
		var reply := {
			"m": GLCProtocol.DISCOVERY_MAGIC, "k": "r", "v": GLCProtocol.VERSION,
			"sid": session.session_id, "name": session.local_name,
			"project": String(ProjectSettings.get_setting("application/config/name", "")),
			"port": session.session_port, "pw": not session.session_password.is_empty(),
			"peers": session.peers.size(),
		}
		_listener.set_dest_address(ip, reply_port)
		_listener.put_packet(JSON.stringify(reply).to_utf8_buffer())

# ---------------------------------------------------------------- browser

func _open_senders() -> void:
	_close_senders()
	var addrs: Array = ["127.0.0.1"]
	for e in GLCProtocol.local_lan_addresses():
		addrs.append(String(e["ip"]))
	for ip in addrs:
		var s := PacketPeerUDP.new()
		if s.bind(0, ip) != OK:
			continue
		s.set_broadcast_enabled(true)
		_senders.append({"sock": s, "ip": ip})

func _close_senders() -> void:
	for e in _senders:
		(e["sock"] as PacketPeerUDP).close()
	_senders.clear()

func _send_queries() -> void:
	var q := JSON.stringify({"m": GLCProtocol.DISCOVERY_MAGIC, "k": "q", "v": GLCProtocol.VERSION}).to_utf8_buffer()
	for e in _senders:
		var s: PacketPeerUDP = e["sock"]
		if String(e["ip"]) == "127.0.0.1":
			s.set_dest_address("127.0.0.1", port)
		else:
			s.set_dest_address("255.255.255.255", port)
		s.put_packet(q)

func _read_replies() -> void:
	var changed := false
	for e in _senders:
		var s: PacketPeerUDP = e["sock"]
		var guard := 0
		while s.get_available_packet_count() > 0 and guard < 32:
			guard += 1
			var pkt := s.get_packet()
			var ip := s.get_packet_ip()
			var r: Variant = JSON.parse_string(pkt.get_string_from_utf8())
			if not (r is Dictionary) or String(r.get("m", "")) != GLCProtocol.DISCOVERY_MAGIC or String(r.get("k", "")) != "r":
				continue
			var sid := String(r.get("sid", ""))
			if sid.is_empty():
				continue
			var prev: Dictionary = sessions.get(sid, {})
			var best_ip := ip
			# prefer a real interface address over loopback when the same host answers on both
			if not prev.is_empty() and ip.begins_with("127.") and not String(prev.get("ip", "")).begins_with("127."):
				best_ip = String(prev["ip"])
			var entry := {
				"ip": best_ip, "port": int(r.get("port", GLCProtocol.DEFAULT_PORT)), "name": String(r.get("name", "?")),
				"project": String(r.get("project", "")), "pw": bool(r.get("pw", false)), "peers": int(r.get("peers", 1)),
				"version": int(r.get("v", 0)), "t": Time.get_ticks_msec(),
				"label": GLCProtocol.network_label(best_ip),
			}
			if prev.is_empty() or prev.get("ip") != entry["ip"] or prev.get("peers") != entry["peers"] or prev.get("name") != entry["name"]:
				changed = true
			sessions[sid] = entry
	if changed:
		sessions_changed.emit()

func _expire(now: int) -> void:
	var changed := false
	for sid in sessions.keys():
		if now - int(sessions[sid]["t"]) > EXPIRE_MS:
			sessions.erase(sid)
			changed = true
	if changed:
		sessions_changed.emit()

## Sessions sorted by name, as an Array of entries (each with "sid").
func list() -> Array:
	var out: Array = []
	for sid in sessions:
		var e: Dictionary = (sessions[sid] as Dictionary).duplicate()
		e["sid"] = sid
		out.append(e)
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out
