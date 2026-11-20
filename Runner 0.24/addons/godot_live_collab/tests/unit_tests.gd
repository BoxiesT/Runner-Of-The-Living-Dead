@tool
extends SceneTree
## Pure-logic unit tests (no editor needed).
##   godot --headless --path <project> -s res://addons/godot_live_collab/tests/unit_tests.gd
## Exit code is the number of failed tests.

var _rng := RandomNumberGenerator.new()
var _failed := 0
var _passed := 0

func _init() -> void:
	_rng.seed = 20261020
	var tests := []
	for m in get_script().get_script_method_list():
		if (m["name"] as String).begins_with("test_"):
			tests.append(m["name"])
	tests.sort()
	for t in tests:
		var started := Time.get_ticks_msec()
		var err: String = str(call(t))
		var ms := Time.get_ticks_msec() - started
		if err.is_empty():
			_passed += 1
			print("  PASS  %s (%d ms)" % [t, ms])
		else:
			_failed += 1
			print("  FAIL  %s: %s" % [t, err])
	print("\nUnit tests: %d passed, %d failed" % [_passed, _failed])
	quit(_failed)

# ------------------------------------------------------------------ helpers

func rand_text(max_len: int) -> String:
	var alphabet := "abc \n"
	var n := _rng.randi_range(0, max_len)
	var s := ""
	for i in n:
		s += alphabet[_rng.randi_range(0, alphabet.length() - 1)]
	return s

func rand_op(doc: String) -> GLCTextOT:
	var op := GLCTextOT.new()
	var pos := 0
	var n := doc.length()
	while pos < n:
		var r := _rng.randf()
		var k := _rng.randi_range(1, mini(4, n - pos))
		if r < 0.45:
			op.retain(k)
			pos += k
		elif r < 0.70:
			op.delete(k)
			pos += k
		else:
			op.insert(rand_text(3))
	if _rng.randf() < 0.4:
		op.insert(rand_text(3))
	if op.base_length != n:
		op.retain(n - op.base_length)
	return op

# ------------------------------------------------------------------ OT tests

func test_ot_diff_roundtrip() -> String:
	for i in 3000:
		var a := rand_text(30)
		var b := rand_text(30)
		var op := GLCTextOT.from_diff(a, b)
		if op.base_length != a.length() or op.target_length != b.length():
			return "length bookkeeping wrong for %s -> %s : %s" % [a.c_escape(), b.c_escape(), op]
		if op.apply(a) != b:
			return "diff roundtrip failed %s -> %s" % [a.c_escape(), b.c_escape()]
	return ""

func test_ot_diff_large_regions() -> String:
	# exercise the line-level path
	var lines_a: Array = []
	for i in 120:
		lines_a.append("line %d content" % i)
	var a := "\n".join(PackedStringArray(lines_a))
	var lines_b := lines_a.duplicate()
	lines_b[5] = "line 5 CHANGED"
	lines_b.remove_at(40)
	lines_b.insert(77, "brand new line")
	lines_b[110] = "line 110 edited"
	var b := "\n".join(PackedStringArray(lines_b))
	var op := GLCTextOT.from_diff(a, b)
	if op.apply(a) != b:
		return "large diff roundtrip failed"
	if op.ops.size() > 40:
		return "large diff is not multi-hunk compact enough (%d components)" % op.ops.size()
	return ""

func test_ot_tp1_convergence() -> String:
	for i in 6000:
		var s := rand_text(24)
		var a := rand_op(s)
		var b := rand_op(s)
		var t := GLCTextOT.transform(a, b)
		var via_a: String = (t[1] as GLCTextOT).apply(a.apply(s))
		var via_b: String = (t[0] as GLCTextOT).apply(b.apply(s))
		if via_a != via_b:
			return "TP1 violated on %s a=%s b=%s : %s vs %s" % [s.c_escape(), a, b, via_a.c_escape(), via_b.c_escape()]
	return ""

func test_ot_same_position_inserts_converge() -> String:
	# the exact scenario that diverged in the original implementation
	var s := "xy"
	var a := GLCTextOT.new().retain(1).insert("A").retain(1)
	var b := GLCTextOT.new().retain(1).insert("B").retain(1)
	var t := GLCTextOT.transform(a, b)
	var r1: String = (t[1] as GLCTextOT).apply(a.apply(s))
	var r2: String = (t[0] as GLCTextOT).apply(b.apply(s))
	if r1 != r2 or r1 != "xABy":
		return "got %s / %s" % [r1, r2]
	return ""

func test_ot_compose() -> String:
	for i in 4000:
		var s := rand_text(24)
		var a := rand_op(s)
		var mid := a.apply(s)
		var b := rand_op(mid)
		var c := GLCTextOT.compose(a, b)
		if c.apply(s) != b.apply(mid):
			return "compose mismatch on %s a=%s b=%s" % [s.c_escape(), a, b]
	return ""

func test_ot_transform_index() -> String:
	# an index pointing into retained text keeps pointing at the same character
	for i in 3000:
		var s := rand_text(24)
		if s.length() < 2:
			continue
		var op := rand_op(s)
		var idx := _rng.randi_range(0, s.length() - 1)
		var target_char := s[idx]
		var applied := op.apply(s)
		var nidx := op.transform_index(idx, true)
		# if the char survived, it must be found at nidx; skip when it was deleted
		var deleted := false
		var pos := 0
		for c in op.ops:
			if GLCTextOT.is_retain(c):
				pos += int(c)
			elif GLCTextOT.is_delete(c):
				if idx >= pos and idx < pos - int(c):
					deleted = true
				pos += -int(c)
		if not deleted and (nidx >= applied.length() or applied[nidx] != target_char):
			return "index drift on %s op=%s idx=%d -> %d" % [s.c_escape(), op, idx, nidx]
	return ""

# Network simulation: one server, several clients, FIFO links, random interleaving.
func _simulate_jupiter(clients_n: int, steps: int, seed_val: int) -> String:
	_rng.seed = seed_val
	var server := GLCTextOT.Server.new()
	server.text = "hello\nworld\n"
	var ctexts: Array = []
	var clients: Array = []
	var up: Array = []     # client -> server queues
	var down: Array = []   # server -> client queues
	for i in clients_n:
		var c := GLCTextOT.Client.new()
		clients.append(c)
		ctexts.append(server.text)
		up.append([])
		down.append([])
	for step in steps:
		var r := _rng.randf()
		if r < 0.35:
			# a client edits locally
			var ci := _rng.randi_range(0, clients_n - 1)
			var op := rand_op(ctexts[ci])
			if op.is_noop():
				continue
			ctexts[ci] = op.apply(ctexts[ci])
			var send: GLCTextOT = clients[ci].apply_local(op)
			if send != null:
				up[ci].append({"rev": clients[ci].revision, "op": send})
		elif r < 0.45:
			# the host edits locally
			var hop := rand_op(server.text)
			if hop.is_noop():
				continue
			var applied: GLCTextOT = server.apply_local(hop)
			for ci in clients_n:
				down[ci].append({"kind": "op", "op": applied})
		elif r < 0.72:
			# server processes one message from a random non-empty uplink
			var cands := []
			for ci in clients_n:
				if not up[ci].is_empty():
					cands.append(ci)
			if cands.is_empty():
				continue
			var ci2: int = cands[_rng.randi_range(0, cands.size() - 1)]
			var msg: Dictionary = up[ci2].pop_front()
			var applied2: GLCTextOT = server.receive(msg["rev"], msg["op"])
			if applied2 == null:
				return "server rejected op (rev %d)" % msg["rev"]
			for cj in clients_n:
				if cj == ci2:
					down[cj].append({"kind": "ack"})
				else:
					down[cj].append({"kind": "op", "op": applied2})
		else:
			# a client processes one message from its downlink
			var cj2 := _rng.randi_range(0, clients_n - 1)
			if down[cj2].is_empty():
				continue
			var m: Dictionary = down[cj2].pop_front()
			var cl: GLCTextOT.Client = clients[cj2]
			if m["kind"] == "ack":
				var nxt: GLCTextOT = cl.server_ack()
				if nxt != null:
					up[cj2].append({"rev": cl.revision, "op": nxt})
			else:
				var local_op: GLCTextOT = cl.apply_server(m["op"])
				if local_op.base_length != ctexts[cj2].length():
					return "client %d: base length mismatch (%d vs %d)" % [cj2, local_op.base_length, ctexts[cj2].length()]
				ctexts[cj2] = local_op.apply(ctexts[cj2])
	# drain
	var guard := 0
	while guard < 100000:
		guard += 1
		var busy := false
		for ci3 in clients_n:
			if not up[ci3].is_empty():
				busy = true
				var msg3: Dictionary = up[ci3].pop_front()
				var ap: GLCTextOT = server.receive(msg3["rev"], msg3["op"])
				if ap == null:
					return "server rejected op while draining"
				for cj3 in clients_n:
					if cj3 == ci3:
						down[cj3].append({"kind": "ack"})
					else:
						down[cj3].append({"kind": "op", "op": ap})
		for cj4 in clients_n:
			while not down[cj4].is_empty():
				busy = true
				var m4: Dictionary = down[cj4].pop_front()
				var cl4: GLCTextOT.Client = clients[cj4]
				if m4["kind"] == "ack":
					var nx: GLCTextOT = cl4.server_ack()
					if nx != null:
						up[cj4].append({"rev": cl4.revision, "op": nx})
				else:
					var lo: GLCTextOT = cl4.apply_server(m4["op"])
					ctexts[cj4] = lo.apply(ctexts[cj4])
		if not busy:
			break
	for ci5 in clients_n:
		if ctexts[ci5] != server.text:
			return "client %d diverged:\n  client: %s\n  server: %s" % [ci5, String(ctexts[ci5]).c_escape(), server.text.c_escape()]
	return ""

func test_ot_jupiter_simulation() -> String:
	for seed_val in range(1, 121):
		var err := _simulate_jupiter(3, 260, seed_val)
		if not err.is_empty():
			return "seed %d: %s" % [seed_val, err]
	return ""

func test_ot_jupiter_simulation_many_clients() -> String:
	for seed_val in range(500, 530):
		var err := _simulate_jupiter(6, 500, seed_val)
		if not err.is_empty():
			return "seed %d: %s" % [seed_val, err]
	return ""

# ------------------------------------------------------------------ scene model simulation

const _NAME_POOL := ["N", "M", "K", "N2"]

func _rand_scene_op(m: GLCSceneModel, counter: Array) -> Array:
	# returns [type, payload] valid in the *local* view of `m`, or [] if nothing to do
	var uids: Array = m.nodes.keys()
	if uids.is_empty():
		return []
	uids.sort()
	var r := _rng.randf()
	var uid: String = uids[_rng.randi_range(0, uids.size() - 1)]
	if r < 0.28:
		counter[0] += 1
		var nu := "u%d" % counter[0]
		var kids_n: int = m.kids_of(uid).size()
		var entry := {"uid": nu, "parent": uid, "name": _NAME_POOL[_rng.randi_range(0, _NAME_POOL.size() - 1)], "cls": "Node2D", "index": _rng.randi_range(0, kids_n), "props": {"x": _rng.randi_range(0, 9)}}
		if _rng.randf() < 0.25:
			counter[0] += 1
			entry["kids"] = [{"uid": "u%d" % counter[0], "name": "Sub", "cls": "Node2D", "props": {}}]
		return [GLCSceneModel.OP_ADD, entry]
	elif r < 0.55:
		var pname: String = ["x", "y", "z"][_rng.randi_range(0, 2)]
		return [GLCSceneModel.OP_SET, {"uid": uid, "props": {pname: _rng.randi_range(0, 99)}}]
	elif r < 0.68:
		if uid == m.root_uid:
			return []
		return [GLCSceneModel.OP_REN, {"uid": uid, "name": _NAME_POOL[_rng.randi_range(0, _NAME_POOL.size() - 1)]}]
	elif r < 0.86:
		if uid == m.root_uid:
			return []
		var np: String = uids[_rng.randi_range(0, uids.size() - 1)]
		if m.is_ancestor_or_self(uid, np):
			return []
		return [GLCSceneModel.OP_MOV, {"uid": uid, "parent": np, "index": _rng.randi_range(0, m.kids_of(np).size()), "name": m.node_name(uid)}]
	else:
		if uid == m.root_uid:
			return []
		return [GLCSceneModel.OP_DEL, {"uid": uid}]

func _corr_for(t: String, canon: Dictionary) -> Dictionary:
	match t:
		GLCSceneModel.OP_ADD, GLCSceneModel.OP_MOV:
			return {"uid": canon["uid"], "parent": canon["parent"], "index": canon["index"], "name": canon["name"]}
		GLCSceneModel.OP_REN:
			return {"uid": canon["uid"], "name": canon["name"]}
	return {}

func _simulate_scene(clients_n: int, steps: int, seed_val: int) -> String:
	_rng.seed = seed_val
	var counter := [0]
	var host := GLCSceneModel.new()
	host.scene_path = "res://sim.tscn"
	host.apply(GLCSceneModel.OP_ADD, {"uid": "R", "parent": "", "name": "Root", "cls": "Node2D"}, false)
	host.apply(GLCSceneModel.OP_ADD, {"uid": "a", "parent": "R", "name": "A", "cls": "Node2D", "index": 0}, false)
	host.apply(GLCSceneModel.OP_ADD, {"uid": "b", "parent": "R", "name": "B", "cls": "Node2D", "index": 1}, false)
	var snap := host.snapshot()
	var reps: Array = []
	var up: Array = []
	var down: Array = []
	var next_id: Array = []
	var waiting: Array = []
	for i in clients_n:
		reps.append(GLCSceneModel.Replica.new(GLCSceneModel.from_snapshot(snap)))
		up.append([])
		down.append([])
		next_id.append(1)
		waiting.append(false)
	var resyncs := 0
	for step in steps:
		var r := _rng.randf()
		if r < 0.36:
			var ci := _rng.randi_range(0, clients_n - 1)
			if waiting[ci]:
				continue
			var rep: GLCSceneModel.Replica = reps[ci]
			var op := _rand_scene_op(rep.model, counter)
			if op.is_empty():
				continue
			var id: int = next_id[ci]
			var payload: Variant = rep.apply_local(id, op[0], op[1])
			if payload == null:
				continue
			next_id[ci] += 1
			up[ci].append({"kind": "op", "id": id, "t": op[0], "p": payload})
		elif r < 0.44:
			var hop := _rand_scene_op(host, counter)
			if hop.is_empty():
				continue
			var canon: Variant = host.apply(hop[0], hop[1], false)
			if canon == null:
				continue
			for cj in clients_n:
				down[cj].append({"kind": "op", "t": hop[0], "p": canon})
		elif r < 0.72:
			var cands := []
			for ci2 in clients_n:
				if not up[ci2].is_empty():
					cands.append(ci2)
			if cands.is_empty():
				continue
			var from: int = cands[_rng.randi_range(0, cands.size() - 1)]
			_host_process(host, from, up[from].pop_front(), down, clients_n)
		else:
			var cj2 := _rng.randi_range(0, clients_n - 1)
			if down[cj2].is_empty():
				continue
			if _client_process(reps[cj2], cj2, down[cj2].pop_front(), up, waiting):
				resyncs += 1
	# drain everything
	var guard := 0
	while guard < 200000:
		guard += 1
		var busy := false
		for ci3 in clients_n:
			while not up[ci3].is_empty():
				busy = true
				_host_process(host, ci3, up[ci3].pop_front(), down, clients_n)
		for cj3 in clients_n:
			while not down[cj3].is_empty():
				busy = true
				if _client_process(reps[cj3], cj3, down[cj3].pop_front(), up, waiting):
					resyncs += 1
		if not busy:
			break
	if resyncs > 0:
		return "needed %d resyncs (rebase should make them unnecessary)" % resyncs
	var want := host.full_signature()
	for ck in clients_n:
		if (reps[ck] as GLCSceneModel.Replica).model.room_made_count > 0:
			return "client %d had canonical name collisions (%d)" % [ck, (reps[ck] as GLCSceneModel.Replica).model.room_made_count]
		var got: String = (reps[ck] as GLCSceneModel.Replica).model.full_signature()
		if got != want:
			return "client %d diverged (resyncs so far: %d)\n--- host\n%s\n--- client\n%s" % [ck, resyncs, want, got]
	return ""

func _host_process(host: GLCSceneModel, from: int, msg: Dictionary, down: Array, clients_n: int) -> void:
	if msg["kind"] == "resync":
		down[from].append({"kind": "state", "snap": host.snapshot()})
		return
	var t: String = msg["t"]
	var canon: Variant = host.apply(t, msg["p"], false)
	if canon == null:
		down[from].append({"kind": "rej", "id": msg["id"], "reason": host.last_error})
		return
	for cj in clients_n:
		if cj == from:
			down[cj].append({"kind": "ack", "id": msg["id"], "corr": _corr_for(t, canon)})
		else:
			down[cj].append({"kind": "op", "t": t, "p": canon})

## returns true if a resync was requested
func _client_process(rep: GLCSceneModel.Replica, ci: int, msg: Dictionary, up: Array, waiting: Array) -> bool:
	match msg["kind"]:
		"op":
			rep.receive(msg["t"], msg["p"])
		"ack":
			rep.ack(msg["id"], msg["corr"])
		"rej":
			rep.reject(msg["id"], msg["reason"])
		"state":
			rep.reset_from_snapshot(msg["snap"])
			waiting[ci] = false
			return false
	if rep.needs_resync and not waiting[ci]:
		waiting[ci] = true
		rep.needs_resync = false
		up[ci].append({"kind": "resync"})
		return true
	return false

func test_scene_model_simulation() -> String:
	var total_resyncs := 0
	for seed_val in range(1, 151):
		var err := _simulate_scene(3, 300, seed_val)
		if not err.is_empty():
			return "seed %d: %s" % [seed_val, err]
	return ""

func test_scene_model_simulation_heavy() -> String:
	for seed_val in range(900, 930):
		var err := _simulate_scene(5, 900, seed_val)
		if not err.is_empty():
			return "seed %d: %s" % [seed_val, err]
	return ""

func test_scene_model_unique_names() -> String:
	var m := GLCSceneModel.new()
	m.apply(GLCSceneModel.OP_ADD, {"uid": "R", "parent": "", "name": "Root", "cls": "Node"}, false)
	m.apply(GLCSceneModel.OP_ADD, {"uid": "1", "parent": "R", "name": "Player", "cls": "Node"}, false)
	var r: Dictionary = m.apply(GLCSceneModel.OP_ADD, {"uid": "2", "parent": "R", "name": "Player", "cls": "Node"}, false)
	if r["name"] != "Player2":
		return "expected Player2, got %s" % r["name"]
	var r3: Dictionary = m.apply(GLCSceneModel.OP_ADD, {"uid": "3", "parent": "R", "name": "Player", "cls": "Node"}, false)
	if r3["name"] != "Player3":
		return "expected Player3, got %s" % r3["name"]
	if m.apply(GLCSceneModel.OP_MOV, {"uid": "R", "parent": "1"}, false) != null:
		return "moving the root must be rejected"
	if m.apply(GLCSceneModel.OP_MOV, {"uid": "1", "parent": "2", "index": 0}, false) == null:
		return "valid reparent rejected"
	if m.apply(GLCSceneModel.OP_MOV, {"uid": "2", "parent": "1"}, false) != null or m.last_error != "cycle":
		return "cycle not detected"
	return ""

# ------------------------------------------------------------------ protocol / paths / snapshots

func test_protocol_pack_roundtrip() -> String:
	var big := PackedByteArray()
	big.resize(200000)
	for i in big.size():
		big[i] = i % 7
	var msg := {"t": "x", "p": {"a": [1, 2, 3], "b": big, "c": Color.RED, "d": Vector2(1, 2), "e": "ação ✓"}}
	var packed := GLCProtocol.pack(msg)
	if packed[0] != 1 or packed.size() > 100000:
		return "large compressible message was not compressed (flag %d, %d bytes)" % [packed[0], packed.size()]
	var back: Variant = GLCProtocol.unpack(packed)
	if not (back is Dictionary) or back["p"]["b"] != big or back["p"]["e"] != "ação ✓" or back["p"]["c"] != Color.RED:
		return "roundtrip mismatch"
	var small := GLCProtocol.pack({"t": "y"})
	if small[0] != 0:
		return "small message should be stored raw"
	if GLCProtocol.unpack(PackedByteArray([1, 2, 3])) != null or GLCProtocol.unpack(PackedByteArray()) != null:
		return "garbage must unpack to null"
	return ""

func test_protocol_path_safety() -> String:
	for bad in ["res://../x", "res://a/../b", "res://a//b", "/etc/passwd", "res://a\\b", "user://x", "res://", "res://a/b:c", "res://" + "x".repeat(500)]:
		if GLCProtocol.is_safe_res_path(bad):
			return "should be unsafe: " + bad
	for good in ["res://a/b.gd", "res://scenes/level 1.tscn", "res://.hidden.txt"]:
		if not GLCProtocol.is_safe_res_path(good):
			return "should be safe: " + good
	for nope in ["res://.godot/x", "res://.git/config", "res://addons/godot_live_collab/plugin.cfg", "res://a/b.glc_tmp", "res://project.godot", "res://.glc_backup/s/x.gd", "res://export_presets.cfg"]:
		if GLCProtocol.is_syncable_path(nope):
			return "should not be synced: " + nope
	for yes in ["res://addons/other_plugin/x.gd", "res://art/player.png", "res://art/player.png.import", "res://main.gd.uid"]:
		if not GLCProtocol.is_syncable_path(yes):
			return "should be synced: " + yes
	return ""

func test_protocol_lan_addresses() -> String:
	for ip in ["127.0.0.1", "10.0.0.5", "172.16.3.4", "172.31.255.1", "192.168.0.10", "169.254.1.1",
			"26.12.34.56", "25.1.2.3", "100.64.0.1", "100.127.255.254", "::1", "fe80::1", "fd12:3456::1",
			"::ffff:192.168.1.2"]:
		if not GLCProtocol.is_lan_address(ip):
			return "should be LAN/VPN: " + ip
	for ip in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "100.128.0.1", "1.1.1.1", "2001:4860::8888",
			"::ffff:8.8.8.8", "", "abc", "300.1.1.1", "192.168.1"]:
		if GLCProtocol.is_lan_address(ip):
			return "should NOT be LAN: " + ip
	if GLCProtocol.network_label("26.1.2.3") != "Radmin VPN" or GLCProtocol.network_label("192.168.0.2") != "rede local":
		return "network labels wrong"
	return ""

func test_protocol_syncable_dirs() -> String:
	for yes in ["res://art", "res://art/empty", "res://addons/other"]:
		if not GLCProtocol.is_syncable_dir(yes):
			return "should be synced: " + yes
	for no in ["res://.godot", "res://.git/x", "res://.glc_backup/s", "res://addons/godot_live_collab", "res://addons/godot_live_collab/core", "res://a/../b"]:
		if GLCProtocol.is_syncable_dir(no):
			return "should not be synced: " + no
	return ""

class _FakeBinding extends RefCounted:
	var by_node := {}
	var by_uid := {}
	func uid_of_node(n: Node) -> String:
		return by_node.get(n, "")
	func node_of_uid(u: String) -> Node:
		return by_uid.get(u, null)
	func ruid_of(_r: Resource) -> String:
		return ""
	func resource_of(_u: String) -> Resource:
		return null
	func register_resource(_u: String, _r: Resource) -> void:
		pass
	func watch_resource(_r: Resource) -> void:
		pass
	func res_cache(_u: String) -> Dictionary:
		return {}
	func add(u: String, n: Node) -> void:
		by_node[n] = u
		by_uid[u] = n

func test_codec_signal_connections() -> String:
	var codec := GLCPropertyResourceSync.new()
	var a := Node2D.new()
	var b := Node.new()
	var a2 := Node2D.new()
	var b2 := Node.new()
	var fb1 := _FakeBinding.new()
	fb1.add("A", a)
	fb1.add("B", b)
	var fb2 := _FakeBinding.new()
	fb2.add("A", a2)
	fb2.add("B", b2)
	a.connect("visibility_changed", Callable(b, "queue_free"), CONNECT_PERSIST)
	a.connect("renamed", Callable(b, "set_name").bind("x"), CONNECT_PERSIST | CONNECT_DEFERRED)
	a.connect("ready", Callable(b, "queue_free"))   # not persistent: never replicated
	# drops the signal argument (the new child) and passes "Renamed" instead
	a.connect("child_entered_tree", Callable(b, "set_name").bindv(["Renamed"]).unbind(1), CONNECT_PERSIST)
	var ctx1 := {"b": fb1, "res_out": {}, "res_in": {}, "missing": []}
	var conns := codec.conns_of(a, ctx1)
	if conns.size() != 3:
		return "expected 3 persistent connections, got %s" % str(conns)
	var ctx2 := {"b": fb2, "res_out": {}, "res_in": {}, "missing": []}
	codec.apply_node_props(a2, {"@conns": conns}, ctx2, {}, false)
	var got := codec.conns_of(a2, ctx2)
	if var_to_str(got) != var_to_str(conns):
		return "connections differ after apply:\n%s\n%s" % [str(conns), str(got)]
	var kid := Node.new()
	a2.emit_signal("child_entered_tree", kid)   # (a2 is not inside a SceneTree, so emit it by hand)
	if String(b2.name) != "Renamed":
		return "bind/unbind connection called the target with the wrong arguments (name=%s)" % b2.name
	kid.free()
	# removing one on the source and re-applying removes it on the replica too
	codec.apply_node_props(a2, {"@conns": [conns[0]]}, ctx2, {}, false)
	if codec.conns_of(a2, ctx2).size() != 1:
		return "connection was not removed"
	# a full apply without @conns clears them
	codec.apply_node_props(a2, {}, ctx2, {}, true)
	if not codec.conns_of(a2, ctx2).is_empty():
		return "full apply did not clear connections"
	for n in [a, b, a2, b2]:
		n.free()
	return ""

func test_codec_script_is_synced() -> String:
	# the engine flags `script` as INTERNAL: it must still be replicated ("Attach Script")
	var codec := GLCPropertyResourceSync.new()
	var n := Sprite2D.new()
	var names: Array = codec.syncable_props(n).map(func(e): return e["name"])
	n.free()
	if not names.has("script"):
		return "`script` is not in the replicated properties"
	if names[0] != "script":
		return "`script` must be applied first (it defines the exported variables)"
	return ""

## Two people typing at the same spot: a remote insertion exactly at our caret must not push the caret
## past it (otherwise the letters of both words interleave); insertions before it do shift it.
func test_script_caret_stays_before_remote_insert_at_caret() -> String:
	var ce := CodeEdit.new()
	ce.text = "ab\ncd"
	ce.set_caret_line(0)
	ce.set_caret_column(1)   # between a and b
	var old := ce.text
	var starts := GLCScriptLiveSync._line_starts(old)
	# remote types "X" exactly at our caret
	var op := GLCTextOT.new().retain(1).insert("X").retain(old.length() - 1)
	var view := GLCScriptLiveSync._save_view(ce, old, starts)
	ce.insert_text("X", 0, 1)
	GLCScriptLiveSync._restore_view(ce, view, op, op.apply(old))
	if ce.get_caret_line() != 0 or ce.get_caret_column() != 1:
		ce.free()
		return "caret was pushed past a remote insertion at its position (col %d)" % ce.get_caret_column()
	# remote types "YY" at the start of the line: the caret moves with its text
	old = ce.text
	starts = GLCScriptLiveSync._line_starts(old)
	var op2 := GLCTextOT.new().insert("YY").retain(old.length())
	view = GLCScriptLiveSync._save_view(ce, old, starts)
	ce.insert_text("YY", 0, 0)
	GLCScriptLiveSync._restore_view(ce, view, op2, op2.apply(old))
	var col := ce.get_caret_column()
	ce.free()
	if col != 3:
		return "caret did not follow an insertion before it (col %d, expected 3)" % col
	return ""

func test_hmac_challenge() -> String:
	var nonce := GLCProtocol.random_bytes(16)
	var a := GLCProtocol.hmac_sha256("secret", nonce)
	if a != GLCProtocol.hmac_sha256("secret", nonce) or a == GLCProtocol.hmac_sha256("Secret", nonce) or a == GLCProtocol.hmac_sha256("secret", GLCProtocol.random_bytes(16)):
		return "hmac behaves wrongly"
	if GLCProtocol.hmac_sha256("", nonce).is_empty():
		return "empty password must still produce a proof"
	return ""

func test_scene_model_snapshot_roundtrip() -> String:
	var m := GLCSceneModel.new()
	m.apply(GLCSceneModel.OP_ADD, {"uid": "R", "parent": "", "name": "Root", "cls": "Node2D", "props": {"a": 1}}, false)
	m.apply(GLCSceneModel.OP_ADD, {"uid": "x", "parent": "R", "name": "X", "cls": "Sprite2D", "props": {"texture": {"__glc": "rref", "u": "r1"}}, "res": {"r1": {"c": "ImageTexture", "v": {"w": 3}}}, "kids": [{"uid": "y", "name": "Y", "cls": "Node", "props": {}}]}, false)
	var snap := m.snapshot()
	var m2 := GLCSceneModel.from_snapshot(snap)
	if m2.full_signature() != m.full_signature() or not m2.res.has("r1") or m2.structure_hash() != m.structure_hash():
		return "snapshot roundtrip differs"
	# unreferenced resources are not shipped
	m.res["orphan"] = {"c": "Resource", "v": {}}
	if (m.snapshot()["res"] as Dictionary).has("orphan"):
		return "orphan resource leaked into snapshot"
	return ""

func test_scene_model_rollback_is_exact() -> String:
	var m := GLCSceneModel.new()
	m.record_undo = true
	m.apply(GLCSceneModel.OP_ADD, {"uid": "R", "parent": "", "name": "Root", "cls": "Node"}, false)
	for n in ["a", "b", "c"]:
		m.apply(GLCSceneModel.OP_ADD, {"uid": n, "parent": "R", "name": n.to_upper(), "cls": "Node", "props": {"p": 1}, "kids": [{"uid": n + "1", "name": "K", "cls": "Node"}]}, false)
	var before := m.full_signature()
	var undos: Array = []
	var ops := [
		[GLCSceneModel.OP_SET, {"uid": "a", "props": {"p": 2, "q": 9}}],
		[GLCSceneModel.OP_REN, {"uid": "b", "name": "A"}],
		[GLCSceneModel.OP_MOV, {"uid": "c1", "parent": "a", "index": 0, "name": "K"}],
		[GLCSceneModel.OP_DEL, {"uid": "b"}],
		[GLCSceneModel.OP_ADD, {"uid": "z", "parent": "R", "name": "A", "cls": "Node", "index": 0}],
	]
	for o in ops:
		if m.apply(o[0], o[1], false) == null:
			return "op %s unexpectedly rejected: %s" % [o[0], m.last_error]
		undos.append(m.last_undo)
	for i in range(undos.size() - 1, -1, -1):
		m.rollback(undos[i])
	if m.full_signature() != before:
		return "rollback did not restore the model"
	return ""

func test_ot_unicode() -> String:
	var a := "olá 🎮 mundo\n→ ação"
	var b := "olá 🎮 MUNDO\n→ ação ✓"
	var op := GLCTextOT.from_diff(a, b)
	if op.apply(a) != b:
		return "unicode diff roundtrip failed"
	return ""
