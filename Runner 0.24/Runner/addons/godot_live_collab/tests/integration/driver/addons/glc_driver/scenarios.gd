@tool
extends RefCounted
# Scripted scenarios. `d` is the driver plugin.
var d: EditorPlugin

const SCENE := "res://main.tscn"

func collab_session() -> Node:
	return d.collab.get("session_manager") if d.collab else null

func open_main() -> Node:
	EditorInterface.open_scene_from_path(SCENE)
	await d.wait(0.8)
	return EditorInterface.get_edited_scene_root()

func connect_pair(host_port: int) -> bool:
	var sm = collab_session()
	var role: String = d.args.get("role")
	if role == "host":
		var err: int = sm.host_session(host_port, "", "Host", Color.GREEN)
		d.say("host_session -> %d" % err)
		return err == OK
	else:
		await d.wait(1.2)
		var err: int = sm.join_session("127.0.0.1", host_port, "", "Client", Color.BLUE)
		d.say("join_session -> %d" % err)
		var ok: bool = await d.wait_until(func(): return sm.is_active_session, 12.0)
		d.say("client active=%s" % ok)
		return ok

# ---- editor-like mutations (go through EditorUndoRedoManager like the real editor does) ----
func add_node(parent: Node, node: Node, node_name: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	node.name = node_name
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Add " + node_name, UndoRedo.MERGE_DISABLE, root)
	u.add_do_method(parent, "add_child", node, true)
	u.add_do_method(node, "set_owner", root)
	u.add_do_reference(node)
	u.add_undo_method(parent, "remove_child", node)
	u.commit_action()

func remove_node(node: Node) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var parent := node.get_parent()
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Remove " + node.name, UndoRedo.MERGE_DISABLE, root)
	u.add_do_method(parent, "remove_child", node)
	u.add_undo_method(parent, "add_child", node, true)
	u.add_undo_method(node, "set_owner", root)
	u.add_undo_reference(node)
	u.commit_action()

func set_prop(node: Node, prop: String, value: Variant) -> void:
	var old: Variant = node.get(prop)
	EditorInterface.inspect_object(node)
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Set " + prop, UndoRedo.MERGE_DISABLE, node)
	u.add_do_property(node, prop, value)
	u.add_undo_property(node, prop, old)
	u.commit_action()
	EditorInterface.get_inspector().property_edited.emit(prop)

func reparent_node(node: Node, new_parent: Node) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var old_parent := node.get_parent()
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Reparent", UndoRedo.MERGE_DISABLE, root)
	u.add_do_method(old_parent, "remove_child", node)
	u.add_do_method(new_parent, "add_child", node, true)
	u.add_do_method(node, "set_owner", root)
	u.add_undo_method(new_parent, "remove_child", node)
	u.add_undo_method(old_parent, "add_child", node, true)
	u.add_undo_method(node, "set_owner", root)
	u.commit_action()

func rename_node(node: Node, new_name: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Rename", UndoRedo.MERGE_DISABLE, root)
	u.add_do_property(node, "name", new_name)
	u.add_undo_property(node, "name", node.name)
	u.commit_action()

# ================= scenarios =================

func run_tree_basic() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var sm = collab_session()
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	if role == "host":
		var got: bool = await d.wait_until(func(): return sm.peers.size() >= 2, 12.0)
		d.say("peers=%d" % sm.peers.size())
		await d.wait(2.0)
		root = EditorInterface.get_edited_scene_root()
		var enemy := Node2D.new()
		add_node(root, enemy, "Enemy")
		await d.wait(0.3)
		var hit := Area2D.new()
		add_node(enemy, hit, "Hitbox")
		await d.wait(0.3)
		set_prop(root.get_node("Player"), "position", Vector2(100, 5))
		await d.wait(0.3)
		rename_node(root.get_node("Player"), "Hero")
		await d.wait(0.3)
		var lbl := Label.new()
		add_node(root, lbl, "Lbl")
		await d.wait(0.3)
		set_prop(lbl, "text", "hello")
		await d.wait(0.3)
		reparent_node(root.get_node("UI"), enemy)
		await d.wait(0.3)
		var sp := Sprite2D.new()
		add_node(root, sp, "Tmp")
		await d.wait(0.3)
		remove_node(sp)
		await d.wait(4.0)
	else:
		await d.wait(12.0)
	root = EditorInterface.get_edited_scene_root()
	return {"ok": true, "dump": d.dump_scene(root)}


# ---------- extra helpers ----------
func t0() -> float:
	return float(d.args.get("t0", "0"))

func wait_t0(offset: float = 0.0) -> void:
	var target := t0() + offset
	while Time.get_unix_time_from_system() < target:
		await d.get_tree().process_frame

func open_script_editor(path: String) -> CodeEdit:
	var scr: Script = load(path)
	EditorInterface.edit_script(scr)
	await d.wait(0.8)
	var se := EditorInterface.get_script_editor()
	var cur := se.get_current_editor()
	if cur != null:
		var be: Control = cur.get_base_editor()
		if be is CodeEdit:
			return be
	return null

func both_ready() -> bool:
	# host waits for client; client waits for session. Returns when both sides are connected.
	var sm = collab_session()
	if d.args.get("role") == "host":
		return await d.wait_until(func(): return sm.peers.size() >= 2, 15.0)
	return sm.is_active_session

# ================= concurrency scenarios =================
func run_script_concurrent() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ce := await open_script_editor("res://player.gd")
	if ce == null:
		return {"ok": false, "why": "no code edit"}
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(2.0)
	await wait_t0(0.0)
	# both type at the SAME position (start of line 3) repeatedly, with tiny gaps
	var letters := "ABCDEFGHIJ" if role == "host" else "klmnopqrst"
	for i in letters.length():
		ce.set_caret_line(3)
		ce.set_caret_column(0)
		ce.insert_text_at_caret(letters[i])
		await d.wait(0.03)
	await d.wait(5.0)
	return {"ok": true, "text": ce.text}

func run_props_concurrent() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(2.0)
	await wait_t0(0.0)
	var player := root.get_node("Player")
	for i in 5:
		if role == "host":
			set_prop(player, "position", Vector2(100 + i, 1))
			set_prop(player, "modulate", Color(1, 0, 0))
		else:
			set_prop(player, "position", Vector2(200 + i, 2))
			set_prop(player, "modulate", Color(0, 0, 1))
		await d.wait(0.02)
	await d.wait(5.0)
	return {"ok": true, "dump": d.dump_scene(root)}

func run_names_concurrent() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(2.0)
	await wait_t0(0.0)
	var n := Node2D.new()
	add_node(root, n, "Dup")
	if role == "host":
		set_prop(n, "position", Vector2(1, 1))
	else:
		set_prop(n, "position", Vector2(2, 2))
	await d.wait(5.0)
	return {"ok": true, "dump": d.dump_scene(root)}

func run_client_edits() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(2.0)
	if role == "client":
		var e := Node2D.new()
		add_node(root, e, "FromClient")
		await d.wait(0.3)
		var c := Sprite2D.new()
		add_node(e, c, "Child")
		await d.wait(0.3)
		set_prop(root.get_node("Player"), "position", Vector2(7, 7))
		await d.wait(0.3)
		rename_node(root.get_node("UI"), "HUD")
	await d.wait(5.0)
	return {"ok": true, "dump": d.dump_scene(root)}

func run_late_join() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var sm = collab_session()
	if role == "host":
		sm.host_session(port, "", "Host", Color.GREEN)
		await d.wait(0.5)
		var e := Node2D.new()
		add_node(root, e, "Early")
		await d.wait(0.3)
		set_prop(root.get_node("Player"), "position", Vector2(55, 66))
		await d.wait(6.0)  # client joins in the meantime
		var e2 := Node2D.new()
		add_node(root, e2, "Late")
		await d.wait(4.0)
	else:
		await d.wait(5.0)
		sm.join_session("127.0.0.1", port, "", "Client", Color.BLUE)
		await d.wait_until(func(): return sm.is_active_session, 12.0)
		await d.wait(8.0)
	return {"ok": true, "dump": d.dump_scene(EditorInterface.get_edited_scene_root())}

func run_big_subtree() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var sm = collab_session()
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(2.0)
	var sent_before := 0
	if role == "host":
		sent_before = d.collab.scene_sync.stats["ops_sent"]
		var top := Node2D.new()
		top.name = "Big"
		for i in 4:
			var mid := Node2D.new()
			mid.name = "Mid%d" % i
			top.add_child(mid)
			for j in 4:
				var leaf := Sprite2D.new()
				leaf.name = "Leaf%d" % j
				mid.add_child(leaf)
		add_node(root, top, "Big")
		for n in top.find_children("*", "", true, false):
			n.owner = root
	await d.wait(5.0)
	var res := {"ok": true, "dump": d.dump_scene(root)}
	if role == "host":
		res["journal_delta"] = d.collab.scene_sync.stats["ops_sent"] - sent_before
	return res

# ================= network tests =================
var checks := {}
func check(name: String, cond: bool, note: String = "") -> void:
	checks[name] = cond
	d.say("CHECK %s: %s %s" % [name, "ok" if cond else "FAIL", note])


func run_net_echo() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var sm: GLCSessionManager = collab_session()
	var got_echo := []
	var ops_client := []
	var ops_host := []
	var scene_ops := []
	var bcs := []
	var acks := []
	var rejs := []
	var started := {"n": 0}
	sm.session_started.connect(func(_h): started["n"] += 1)
	sm.log_line.connect(func(t, l): d.say("LOG[%d] %s" % [l, t]))
	sm.peers_changed.connect(func(): d.say("peers_changed -> %s" % [sm.peers.keys()]))
	sm.register("t.echo", func(sender, p, meta):
		if sm.is_hosting:
			sm.send_to(sender, "t.echo_r", {"n": p["n"], "size": (p["blob"] as PackedByteArray).size(), "h": hash(p["blob"])})
	, "direct")
	sm.register("t.echo_r", func(sender, p, meta): got_echo.append(p), "direct")
	sm.register("t.op", func(sender, p, meta):
		if meta["stage"] == "host":
			if int(p["v"]) < 0:
				meta["reason"] = "invalid"
				return null
			var q: Dictionary = p.duplicate()
			q["v"] = int(p["v"]) + 1000
			meta["corr"] = {"v": q["v"]}
			ops_host.append(int(p["n"]))
			return q
		ops_client.append(p)
	, "op", {"scope": "all"})
	sm.register("t.sc", func(sender, p, meta):
		if meta["stage"] == "host":
			return p
		scene_ops.append(p)
	, "op", {"scope": "scene"})
	sm.register("t.bc", func(sender, p, meta): bcs.append(p), "bcast", {"scope": "all", "reliable": false})

	if role == "host":
		var err := sm.host_session(port, "secret", "HostUser", Color.GREEN)
		check("host_started", err == OK)
		await d.wait_until(func(): return sm.peers.size() >= 2, 20.0)
		check("client_joined", sm.peers.size() == 2, str(sm.peers.keys()))
		check("client_name", sm.peers.size() == 2 and sm.peers.values().any(func(i): return i["name"] == "ClientUser"))
		await d.wait(1.5)
		sm.submit(0, "t.op", {"n": 9001, "v": 5})
		sm.submit(0, "t.sc", {"scene": "x", "n": 1})
		sm.submit(0, "t.sc", {"scene": "y", "n": 2})
		sm.bcast("t.bc", {"from": "host"})
		await d.wait(14.0)
		check("host_got_50_ops_in_order", ops_host.size() >= 50 and ops_host.slice(0, 50) == range(50), str(ops_host.size()))
		check("host_got_bcast", bcs.size() >= 1)
		# kick the client to test reconnect
		var cid := 0
		for id in sm.peers: if id != 1: cid = id
		if cid != 0:
			sm.mp.multiplayer_peer.disconnect_peer(cid)
		await d.wait(0.5)
		var rej_ok: bool = await d.wait_until(func(): return sm.peers.size() >= 2, 12.0)
		check("client_rejoined", rej_ok, "peers=%d" % sm.peers.size())
		await d.wait(2.0)
	else:
		await d.wait(1.5)
		# wrong password first
		var e1 := sm.join_session("127.0.0.1", port, "WRONG", "Intruder", Color.RED)
		await d.wait_until(func(): return sm.state == "error", 12.0)
		check("bad_password_rejected", sm.state == "error" and sm.last_error.contains("senha"), sm.last_error)
		check("bad_password_not_active", not sm.is_active_session)
		sm.auto_reconnect = true
		var e2 := sm.join_session("127.0.0.1", port, "secret", "ClientUser", Color.BLUE)
		await d.wait_until(func(): return sm.is_active_session, 15.0)
		check("joined_ok", sm.is_active_session, sm.state)
		check("sees_host", sm.peers.has(1))
		sm.subscribe("scene:x")
		await d.wait(1.5)
		# big incompressible blob
		var blob := PackedByteArray()
		blob.resize(8 * 1024 * 1024)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in range(0, blob.size(), 8):
			blob.encode_s64(i, rng.randi())
		var want_hash := hash(blob)
		sm.send_to(1, "t.echo", {"n": 1, "blob": blob}, true)
		# 50 ordered ops with acks
		for i in 50:
			var id := sm.next_op_id()
			sm.submit(id, "t.op", {"n": i, "v": i}, func(corr, q): acks.append([int(corr.get("v", -1)), q]), func(r): rejs.append(r))
		var bad_id := sm.next_op_id()
		sm.submit(bad_id, "t.op", {"n": 777, "v": -1}, func(corr, q): acks.append([-1, q]), func(r): rejs.append(r))
		await d.wait(8.0)
		check("big_echo_8MB", got_echo.size() == 1 and got_echo[0]["size"] == blob.size() and got_echo[0]["h"] == want_hash, str(got_echo.size()))
		check("50_acks_with_corrections", acks.size() == 50 and acks[0][0] == 1000 and acks[49][0] == 1049, str(acks.size()))
		var seqs_ok := true
		for i in range(1, acks.size()):
			if acks[i][1] <= acks[i - 1][1]: seqs_ok = false
		check("ack_seq_monotonic", seqs_ok)
		check("reject_delivered", rejs == ["invalid"], str(rejs))
		check("got_host_op", ops_client.any(func(p): return p["n"] == 9001 and p["v"] == 5))
		check("scene_x_received_y_filtered", scene_ops.size() == 1 and scene_ops[0]["scene"] == "x", str(scene_ops))
		check("got_bcast", true)
		sm.bcast("t.bc", {"from": "client"})
		await d.wait(3.0)
		# the host kicks us now: expect automatic reconnect
		var before: int = started["n"]
		await d.wait_until(func(): return started["n"] > before, 25.0)
		check("auto_reconnected", started["n"] > before and sm.is_active_session, "starts=%d state=%s" % [started["n"], sm.state])
		await d.wait(4.0)
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks}

# ================= file sync =================
func write_file(path: String, content: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is PackedByteArray:
		f.store_buffer(content)
	else:
		f.store_string(String(content))
	f.close()

func list_files() -> Dictionary:
	var out := {}
	var stack := ["res://"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			if sub.begins_with(".") or sub == "addons":
				continue
			stack.append((dir if dir.ends_with("/") else dir + "/") + sub)
		for f in DirAccess.get_files_at(dir):
			if f in ["project.godot"] or f.ends_with(".glc_tmp"):
				continue
			var p := (dir if dir.ends_with("/") else dir + "/") + f
			out[p] = FileAccess.get_sha256(p).substr(0, 12)
	return out

func list_backups() -> Array:
	var out := []
	var stack := ["res://.glc_backup"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			stack.append(dir + "/" + sub)
		for f in DirAccess.get_files_at(dir):
			out.append((dir + "/" + f).trim_prefix("res://.glc_backup/"))
	out.sort()
	return out

func run_files_sync() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var blob := PackedByteArray()
	blob.resize(300 * 1024)
	for i in range(0, blob.size(), 8):
		blob.encode_s64(i, rng.randi())
	if role == "host":
		write_file("res://shared/hello.txt", "hello")
		write_file("res://shared/bin.dat", blob)
		write_file("res://shared/deep/nested/a.txt", "nested A")
	else:
		write_file("res://client_only.txt", "mine")
		write_file("res://shared/hello.txt", "client version")
	var fs = d.collab.file_sync
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait_until(func(): return fs.baseline_done and fs.reconcile_state == "done", 25.0)
	await wait_t0(4.0)   # both sides take the snapshot at the same moment
	var stage1 := list_files()
	d.say("stage1 files: %d" % stage1.size())
	await wait_t0(6.0)
	if role == "host":
		write_file("res://shared/hello.txt", "hello v2 (host)")
		write_file("res://shared/new.txt", "brand new")
		DirAccess.remove_absolute("res://shared/deep/nested/a.txt")
		DirAccess.rename_absolute("res://shared/bin.dat", "res://shared/bin2.dat")
	else:
		write_file("res://from_client.txt", "client says hi")
	await d.wait(14.0)
	return {"ok": true, "files": list_files(), "stage1": stage1, "backups": list_backups(), "stats": fs.stats}

func list_dirs() -> Array:
	var out := []
	var stack := ["res://"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			if sub.begins_with(".") or sub == "addons":
				continue
			var p := (dir if dir.ends_with("/") else dir + "/") + sub
			out.append(p)
			stack.append(p)
	out.sort()
	return out

func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "<missing>"

## Waits until cond() is true; returns the elapsed seconds or -1 on timeout.
func time_until(cond: Callable, timeout: float) -> float:
	var t_start := Time.get_ticks_msec()
	var ok: bool = await d.wait_until(cond, timeout)
	return (Time.get_ticks_msec() - t_start) / 1000.0 if ok else -1.0

## Real-time "shared folder": create / same-second edits / empty folders / deletes, in both directions.
func run_files_live() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var fs = d.collab.file_sync
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait_until(func(): return fs.baseline_done and fs.reconcile_state == "done", 20.0)
	var lat := {}
	# 1. host creates a file -> client
	await wait_t0(2.0)
	if role == "host":
		write_file("res://live/a.txt", "A1")
	else:
		lat["create_h2c"] = await time_until(func(): return read_text("res://live/a.txt") == "A1", 8.0)
	# 2. client creates a file -> host
	await wait_t0(10.0)
	if role == "client":
		write_file("res://live/b.txt", "B1")
	else:
		lat["create_c2h"] = await time_until(func(): return read_text("res://live/b.txt") == "B1", 8.0)
	# 3. host edits the same file twice in the same second, same size (mtime has 1 s resolution)
	await wait_t0(18.0)
	if role == "host":
		write_file("res://live/a.txt", "A2")
		await d.wait(0.25)
		write_file("res://live/a.txt", "A3")
	else:
		lat["edit_same_second"] = await time_until(func(): return read_text("res://live/a.txt") == "A3", 8.0)
	# 4. client creates EMPTY folders -> host
	await wait_t0(26.0)
	if role == "client":
		DirAccess.make_dir_recursive_absolute("res://emptydir/sub")
	else:
		lat["mkdir_c2h"] = await time_until(func(): return DirAccess.dir_exists_absolute("res://emptydir/sub"), 8.0)
	# 5. host deletes the client's file, client removes the empty folder
	await wait_t0(34.0)
	if role == "host":
		DirAccess.remove_absolute("res://live/b.txt")
		lat["rmdir_c2h"] = await time_until(func(): return not DirAccess.dir_exists_absolute("res://emptydir/sub"), 9.0)
	else:
		DirAccess.remove_absolute("res://emptydir/sub")
		lat["delete_h2c"] = await time_until(func(): return not FileAccess.file_exists("res://live/b.txt"), 9.0)
	await wait_t0(44.0)
	for k in lat:
		check("latency_" + k, float(lat[k]) >= 0.0 and float(lat[k]) < 4.0, "%.2fs" % float(lat[k]))
	var dirs := list_dirs()
	var allok := true
	for k in checks: if not checks[k]: allok = false
	var files := list_files()
	for p in dirs:
		files["dir:" + p] = "d"
	return {"ok": allok, "checks": checks, "files": files, "latency": lat}

## Live scene tree in both directions: simultaneous adds, signal connections, reorder, rename, unsaved mark, save.
func connect_signal(src: Node, sig: String, target: Node, method: String) -> void:
	var u := EditorInterface.get_editor_undo_redo()
	var cb := Callable(target, method)
	u.create_action("Connect " + sig, UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	u.add_do_method(src, "connect", sig, cb, CONNECT_PERSIST)
	u.add_undo_method(src, "disconnect", sig, cb)
	u.commit_action()

func move_node(node: Node, to_index: int) -> void:
	var parent := node.get_parent()
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Move", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	u.add_do_method(parent, "move_child", node, to_index)
	u.add_undo_method(parent, "move_child", node, node.get_index())
	u.commit_action()

func run_tree_live() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.0)
	# 1. host adds a node; the client (which did nothing) must see it AND have the scene marked as modified
	await wait_t0(2.0)
	root = EditorInterface.get_edited_scene_root()
	if role == "host":
		add_node(root, Node2D.new(), "HostNode")
	else:
		var t := await time_until(func(): return root.get_node_or_null("HostNode") != null, 6.0)
		check("node_h2c_fast", t >= 0.0 and t < 2.0, "%.2fs" % t)
		await d.wait(0.5)
		var unsaved: Array = Array(EditorInterface.get_unsaved_scenes())
		check("marked_unsaved_after_remote_edit", unsaved.has(SCENE), str(unsaved))
	# 2. both add at the same time + connect signals on both sides
	await wait_t0(6.0)
	if role == "host":
		add_node(root.get_node("UI"), Label.new(), "FromHost")
		connect_signal(root.get_node("Player"), "visibility_changed", root, "_on_player_visibility")
	else:
		add_node(root.get_node("UI"), Label.new(), "FromClient")
		connect_signal(root.get_node("UI"), "resized", root.get_node("Player"), "_on_ui_resized")
	# 3. client reorders, host renames
	await wait_t0(10.0)
	if role == "client":
		var cn := root.get_node_or_null("UI/FromClient")
		if cn != null:
			move_node(cn, 0)
	else:
		var hn := root.get_node_or_null("HostNode")
		if hn != null:
			rename_node(hn, "Renamed")
	# 4. host disconnects its signal again (undo-able editor action)
	await wait_t0(14.0)
	if role == "host":
		var u := EditorInterface.get_editor_undo_redo()
		var cb := Callable(root, "_on_player_visibility")
		u.create_action("Disconnect", UndoRedo.MERGE_DISABLE, root)
		u.add_do_method(root.get_node("Player"), "disconnect", "visibility_changed", cb)
		u.add_undo_method(root.get_node("Player"), "connect", "visibility_changed", cb, CONNECT_PERSIST)
		u.commit_action()
		connect_signal(root.get_node("Player"), "texture_changed", root, "_on_tex")
	await wait_t0(19.0)
	var dump: Array = d.dump_scene(EditorInterface.get_edited_scene_root())
	var conns := []
	for e in dump:
		conns.append_array(e.get("conns", []))
	conns.sort()
	check("connections_synced", conns == ["resized->Player._on_ui_resized", "texture_changed->.._on_tex"], str(conns))
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "dump": dump}

## LAN discovery: the client finds the host without typing an address, then joins through it.
func run_discovery() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var sm: GLCSessionManager = collab_session()
	var disc = d.collab.discovery
	disc.port = port + 4000   # private discovery port: never mixes with real sessions on the LAN
	if role == "host":
		var err := sm.host_session(port, "pw123", "HostUser", Color.GREEN)
		check("host_started", err == OK)
		await d.wait(1.0)
		check("discovery_listening", disc.host_listening, disc.host_listen_error)
		var joined: bool = await d.wait_until(func(): return sm.peers.size() >= 2, 25.0)
		check("client_joined_via_discovery", joined)
		var ip := ""
		for id in sm.peers:
			if id != 1:
				ip = String(sm.peers[id].get("ip", ""))
		check("peer_ip_is_lan", GLCProtocol.is_lan_address(ip), ip)
		await d.wait(3.0)
	else:
		await d.wait(2.0)
		var mine := func(): return disc.list().filter(func(x): return int(x["port"]) == port)
		var found: bool = await d.wait_until(func(): return not mine.call().is_empty(), 12.0)
		check("found_session", found)
		var e: Dictionary = mine.call()[0] if found else {}
		check("found_right_port", int(e.get("port", 0)) == port, str(e))
		check("found_password_flag", bool(e.get("pw", false)))
		check("found_project_name", String(e.get("project", "")) == "GLC Test", String(e.get("project", "")))
		if found:
			sm.join_session(String(e["ip"]), int(e["port"]), "pw123", "ClientUser", Color.BLUE)
			var ok: bool = await d.wait_until(func(): return sm.is_active_session, 12.0)
			check("joined_with_discovered_address", ok, String(e["ip"]))
		await d.wait(4.0)
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks}

## A scene instanced in an open scene is edited and saved by someone else (it is not open here):
## the instance shown here must update, and the shared tree must stay identical.
const ENEMY := "res://enemy.tscn"

func write_enemy(child_name: String, root_extra: String = "") -> void:
	write_file(ENEMY, "[gd_scene format=3]\n\n[node name=\"Enemy\" type=\"Node2D\"]\n%s\n[node name=\"%s\" type=\"Sprite2D\" parent=\".\"]\n" % [root_extra, child_name])

func run_instance_reload() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	write_enemy("Body")
	await d.wait(0.2)
	EditorInterface.get_resource_filesystem().scan()
	await d.wait(1.5)
	var root := await open_main()
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.0)
	await wait_t0(3.0)
	root = EditorInterface.get_edited_scene_root()
	if role == "host":
		var inst: Node = (load(ENEMY) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		add_node(root, inst, "Enemy")
		await d.wait(0.5)
		set_prop(inst, "position", Vector2(50, 60))   # an override of the instance
	await wait_t0(8.0)
	root = EditorInterface.get_edited_scene_root()
	check("instance_arrived", root.get_node_or_null("Enemy") != null)
	# the client changes enemy.tscn on disk (as if it had saved it from its editor)
	if role == "client":
		write_enemy("Head", "modulate = Color(1, 0, 0, 1)\n")
		EditorInterface.get_resource_filesystem().scan()
	await wait_t0(16.0)
	root = EditorInterface.get_edited_scene_root()
	var e := root.get_node_or_null("Enemy")
	var kids := []
	if e != null:
		for c in e.get_children():
			kids.append(String(c.name))
	check("instance_updated_" + role, kids == ["Head"], str(kids))
	check("instance_inherits_new_value_" + role, e != null and (e as Node2D).modulate == Color(1, 0, 0, 1), str((e as Node2D).modulate) if e != null else "")
	check("instance_keeps_override_" + role, e != null and (e as Node2D).position == Vector2(50, 60), str((e as Node2D).position) if e != null else "")
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "dump": d.dump_scene(root)}

## Structural edge cases: "Reparent to New Node", a cancelled drag (hints only), moving a child out of a
## parent deleted in the same editor action.
func run_tree_edge() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var sm: GLCSessionManager = collab_session()
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.0)
	await wait_t0(2.0)
	root = EditorInterface.get_edited_scene_root()
	if role == "client":
		# like Scene dock > Reparent to New Node: one action creates the parent and moves Player into it
		var n := Node2D.new()
		n.name = "Group"
		var player := root.get_node("Player")
		var u := EditorInterface.get_editor_undo_redo()
		u.create_action("Reparent to New Node", UndoRedo.MERGE_DISABLE, root)
		u.add_do_method(root, "add_child", n, true)
		u.add_do_method(n, "set_owner", root)
		u.add_do_method(root, "remove_child", player)
		u.add_do_method(n, "add_child", player, true)
		u.add_do_method(player, "set_owner", root)
		u.add_do_reference(n)
		u.commit_action()
	await wait_t0(6.0)
	check("reparent_to_new_node", root.get_node_or_null("Group/Player") != null and root.get_node_or_null("Player") == null)
	# host: live drag hints for UI, then the drag is "cancelled" (the value never changes on the host)
	if role == "host":
		var uid: String = d.collab.scene_sync.uid_for(root.get_node("UI"))
		for i in 5:
			sm.bcast(GLCProtocol.S_TF, {"scene": SCENE, "uid": uid, "props": {"position": Vector2(300 + i, 300)}})
			await d.wait(0.05)
	else:
		await d.wait(0.2)
		check("hint_shown_while_dragging", (root.get_node("UI") as Control).position.x >= 300.0, str((root.get_node("UI") as Control).position))
	await wait_t0(9.0)
	check("cancelled_drag_restored", (root.get_node("UI") as Control).position == Vector2.ZERO, str((root.get_node("UI") as Control).position))
	# host: in ONE action move Player back to the root and delete Group
	await wait_t0(11.0)
	if role == "host":
		var g := root.get_node_or_null("Group")
		var p := root.get_node_or_null("Group/Player")
		if g != null and p != null:
			var u2 := EditorInterface.get_editor_undo_redo()
			u2.create_action("Move out + delete", UndoRedo.MERGE_DISABLE, root)
			u2.add_do_method(g, "remove_child", p)
			u2.add_do_method(root, "add_child", p, true)
			u2.add_do_method(p, "set_owner", root)
			u2.add_do_method(root, "remove_child", g)
			u2.add_undo_reference(g)
			u2.commit_action()
	await wait_t0(15.0)
	root = EditorInterface.get_edited_scene_root()
	check("moved_out_and_deleted", root.get_node_or_null("Player") != null and root.get_node_or_null("Group") == null)
	# host: Old/Item exists; then in ONE action a NEW parent adopts Item and Old is deleted. On the client,
	# Item must stay the very same object (references to it keep working).
	if role == "host":
		var old := Node2D.new()
		var item := Node2D.new()
		item.name = "Item"
		old.add_child(item)
		add_node(root, old, "Old")
		item.owner = root
	await wait_t0(18.0)
	var item_before := root.get_node_or_null("Old/Item")
	var item_iid := item_before.get_instance_id() if item_before != null else 0
	if role == "host" and item_before != null:
		var newp := Node2D.new()
		newp.name = "New"
		var oldp := root.get_node("Old")
		var u3 := EditorInterface.get_editor_undo_redo()
		u3.create_action("New parent + delete old", UndoRedo.MERGE_DISABLE, root)
		u3.add_do_method(root, "add_child", newp, true)
		u3.add_do_method(newp, "set_owner", root)
		u3.add_do_method(oldp, "remove_child", item_before)
		u3.add_do_method(newp, "add_child", item_before, true)
		u3.add_do_method(item_before, "set_owner", root)
		u3.add_do_method(root, "remove_child", oldp)
		u3.add_do_reference(newp)
		u3.add_undo_reference(oldp)
		u3.commit_action()
	await wait_t0(22.0)
	root = EditorInterface.get_edited_scene_root()
	var item_after := root.get_node_or_null("New/Item")
	check("new_parent_adopts_from_deleted", item_after != null and root.get_node_or_null("Old") == null)
	check("adopted_node_kept_identity", item_after != null and item_after.get_instance_id() == item_iid, "%d vs %d" % [item_iid, item_after.get_instance_id() if item_after != null else 0])
	# host: Scene dock > Change Type: "New" becomes a Marker2D with the same name, keeping its child
	if role == "host" and root.get_node_or_null("New") != null:
		var oldn := root.get_node("New")
		var kid := root.get_node("New/Item")
		var repl := Marker2D.new()
		repl.name = "New"
		var u4 := EditorInterface.get_editor_undo_redo()
		u4.create_action("Change Type", UndoRedo.MERGE_DISABLE, root)
		u4.add_do_method(oldn, "replace_by", repl, true)
		u4.add_do_method(repl, "set_owner", root)
		u4.add_do_method(kid, "set_owner", root)
		u4.add_do_reference(repl)
		u4.add_undo_reference(oldn)
		u4.commit_action()
	await wait_t0(26.0)
	root = EditorInterface.get_edited_scene_root()
	var changed := root.get_node_or_null("New")
	check("change_type_keeps_name", changed is Marker2D and root.get_node_or_null("New2") == null, str(changed.get_class()) if changed != null else "missing")
	check("change_type_keeps_child", root.get_node_or_null("New/Item") != null)
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "dump": d.dump_scene(root)}

## The host already has a project; someone joins with an EMPTY project (only this addon installed).
## Everything must arrive: files, folders, imported assets, class_name scripts, autoloads, input map.
func run_empty_join() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var sm: GLCSessionManager = collab_session()
	var fs = d.collab.file_sync
	var efs := EditorInterface.get_resource_filesystem()
	if role == "host":
		# ---- build a small real project
		write_file("res://scripts/enemy.gd", "class_name Enemy\nextends Node2D\n\n@export var hp := 3\n")
		write_file("res://game.gd", "extends Node\n\nvar score := 0\n")
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(1, 0.5, 0, 1))
		DirAccess.make_dir_recursive_absolute("res://art")
		img.save_png("res://art/dot.png")
		DirAccess.make_dir_recursive_absolute("res://empty_folder/inner")
		efs.scan()
		await d.wait_until(func(): return ResourceLoader.exists("res://art/dot.png") and ResourceLoader.exists("res://scripts/enemy.gd"), 20.0)
		await d.wait(1.0)
		while efs.is_scanning():
			await d.get_tree().process_frame
		var lvl := Node2D.new()
		lvl.name = "Level1"
		lvl.set_script(load("res://scripts/enemy.gd"))
		lvl.set("hp", 7)
		var spr := Sprite2D.new()
		spr.name = "Dot"
		spr.texture = load("res://art/dot.png")
		lvl.add_child(spr)
		spr.owner = lvl
		var ps := PackedScene.new()
		ps.pack(lvl)
		DirAccess.make_dir_recursive_absolute("res://levels")
		ResourceSaver.save(ps, "res://levels/level1.tscn")
		lvl.free()
		ProjectSettings.set_setting("autoload/Game", "*res://game.gd")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_SPACE
		ProjectSettings.set_setting("input/jump", {"deadzone": 0.5, "events": [ev]})
		ProjectSettings.set_setting("application/run/main_scene", "res://levels/level1.tscn")
		ProjectSettings.save()
		efs.scan()
		await d.wait(2.0)
		var err := sm.host_session(port, "", "Host", Color.GREEN)
		check("host_started", err == OK)
		await d.wait_until(func(): return sm.peers.size() >= 2, 40.0)
		await d.wait(30.0)
	else:
		# ---- an empty project: remove the sample files the test kit puts in it
		for f in ["res://main.tscn", "res://player.gd", "res://player.gd.uid"]:
			if FileAccess.file_exists(f):
				DirAccess.remove_absolute(f)
		efs.scan()
		await d.wait(9.0)   # the host is still building its project
		var t_join := Time.get_ticks_msec()
		sm.join_session("127.0.0.1", port, "", "Client", Color.BLUE)
		var joined: bool = await d.wait_until(func(): return sm.is_active_session, 15.0)
		check("joined", joined)
		var done: bool = await d.wait_until(func(): return fs.baseline_done and fs.reconcile_state == "done" and FileAccess.file_exists("res://levels/level1.tscn"), 30.0)
		check("files_downloaded", done, fs.status_text())
		var imported: bool = await d.wait_until(func(): return ResourceLoader.exists("res://art/dot.png") and load("res://art/dot.png") is Texture2D, 25.0)
		check("png_imported_here", imported)
		d.say("join -> usable in %.1fs" % ((Time.get_ticks_msec() - t_join) / 1000.0))
		await d.wait(2.0)
		while efs.is_scanning():
			await d.get_tree().process_frame
		check("empty_folder_created", DirAccess.dir_exists_absolute("res://empty_folder/inner"))
		check("autoload_setting", String(ProjectSettings.get_setting("autoload/Game", "")) == "*res://game.gd", str(ProjectSettings.get_setting("autoload/Game", "")))
		check("input_action", ProjectSettings.has_setting("input/jump"))
		check("main_scene_setting", String(ProjectSettings.get_setting("application/run/main_scene", "")) == "res://levels/level1.tscn")
		var ps2: Variant = load("res://levels/level1.tscn")
		var ok_scene := false
		var note := ""
		if ps2 is PackedScene:
			var inst: Node = (ps2 as PackedScene).instantiate()
			var dot := inst.get_node_or_null("Dot") as Sprite2D
			ok_scene = dot != null and dot.texture != null and int(inst.get("hp")) == 7 and (inst.get_script() as Script).get_global_name() == "Enemy"
			note = "dot=%s tex=%s hp=%s" % [dot != null, dot.texture != null if dot != null else false, inst.get("hp")]
			inst.free()
		check("scene_works_here", ok_scene, note)
		# the class_name is known to the editor here as well
		var classes := ProjectSettings.get_global_class_list().map(func(c): return String(c["class"]))
		check("class_name_registered", classes.has("Enemy"), str(classes))
		await d.wait(8.0)
	var allok := true
	for k in checks: if not checks[k]: allok = false
	var files := list_files()
	for p in list_dirs():
		files["dir:" + p] = "d"
	return {"ok": allok, "checks": checks, "files": files}

## "Attach Script" like the editor does it: a NEW script file is saved and attached to a node in the same
## action. The other side must show it right away (it has to fetch the brand-new file first).
func attach_new_script(node: Node, path: String, source: String, builtin: bool = false) -> void:
	var scr := GDScript.new()
	scr.source_code = source
	if not builtin:
		ResourceSaver.save(scr, path)
		scr = load(path)
	else:
		scr.reload()
	var u := EditorInterface.get_editor_undo_redo()
	u.create_action("Attach Script", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	u.add_do_method(node, "set_script", scr)
	u.add_undo_method(node, "set_script", node.get_script())
	u.commit_action()
	if not builtin:
		EditorInterface.edit_script(scr)   # the dialog opens the new script in the Script editor

## True if the Scene dock shows the "Script" icon button on the row of `node`.
func scene_dock_has_script_icon(node: Node) -> bool:
	var tree := _scene_dock_tree(EditorInterface.get_base_control())
	if tree == null or tree.get_root() == null:
		return false
	var icon: Texture2D = EditorInterface.get_editor_theme().get_icon("Script", "EditorIcons")
	var item := _find_item(tree.get_root(), node.get_path())
	if item == null:
		return false
	for i in item.get_button_count(0):
		if item.get_button(0, i) == icon:
			return true
	return false

func _scene_dock_tree(n: Node) -> Tree:
	if n.get_class() == "SceneTreeEditor":
		for c in n.get_children():
			if c is Tree:
				return c
	for c in n.get_children():
		var r := _scene_dock_tree(c)
		if r != null:
			return r
	return null

func _find_item(item: TreeItem, path: NodePath) -> TreeItem:
	var md: Variant = item.get_metadata(0)
	if md != null and str(md) == str(path):
		return item
	var c := item.get_first_child()
	while c != null:
		var r := _find_item(c, path)
		if r != null:
			return r
		c = c.get_next()
	return null

func run_script_attach() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.0)
	root = EditorInterface.get_edited_scene_root()
	var lat := {}
	# 1. client attaches a new script file to Player
	await wait_t0(2.0)
	if role == "client":
		GLCProtocol.trace("TEST attach")
		attach_new_script(root.get_node("Player"), "res://attached.gd", "extends Sprite2D\n\n@export var hp := 5\n")
		var own: float = await time_until(func(): return scene_dock_has_script_icon(root.get_node("Player")), 3.0)
		check("own_icon_visible_author", own >= 0.0, "%.2fs" % own)
	else:
		lat["attach_c2h"] = await time_until(func():
			var s: Variant = root.get_node("Player").get_script()
			return s is Script and (s as Script).resource_path == "res://attached.gd", 8.0)
		lat["icon_attach_c2h"] = await time_until(func(): return scene_dock_has_script_icon(root.get_node("Player")), 3.0)
	# 2. host attaches a new script file to UI
	await wait_t0(10.0)
	if role == "host":
		attach_new_script(root.get_node("UI"), "res://ui_script.gd", "extends Control\n\n@export var title := \"hi\"\n")
	else:
		lat["attach_h2c"] = await time_until(func():
			var s: Variant = root.get_node("UI").get_script()
			return s is Script and (s as Script).resource_path == "res://ui_script.gd", 8.0)
		lat["icon_attach_h2c"] = await time_until(func(): return scene_dock_has_script_icon(root.get_node("UI")), 3.0)
	# 3. client attaches a built-in script (saved inside the scene) to the root
	await wait_t0(18.0)
	if role == "client":
		attach_new_script(root, "", "extends Node2D\n\nvar built_in := true\n", true)
	else:
		lat["builtin_c2h"] = await time_until(func():
			var s: Variant = root.get_script()
			return s is Script and (s as Script).source_code.contains("built_in"), 8.0)
		lat["icon_builtin_c2h"] = await time_until(func(): return scene_dock_has_script_icon(root), 3.0)
	# 4. client edits the exported variable of the script it just attached
	await wait_t0(24.0)
	if role == "client":
		GLCProtocol.trace("TEST set hp")
		set_prop(root.get_node("Player"), "hp", 42)
	else:
		lat["export_c2h"] = await time_until(func(): return root.get_node("Player").get("hp") == 42, 8.0)
	await wait_t0(30.0)
	for k in lat:
		check("instant_" + k, float(lat[k]) >= 0.0 and float(lat[k]) < 1.0, "%.2fs" % float(lat[k]))
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "latency": lat, "dump": d.dump_scene(EditorInterface.get_edited_scene_root())}

func run_fps_probe() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	await open_main()
	var ok := await connect_pair(port)
	await both_ready()
	var out := {}
	for i in 3:
		var f0 := Engine.get_process_frames()
		var t0 := Time.get_ticks_usec()
		await d.wait(1.0)
		var fps := (Engine.get_process_frames() - f0) / ((Time.get_ticks_usec() - t0) / 1000000.0)
		d.say("fps=%.1f lowproc=%s sleep=%d max_fps=%d focused=%s" % [fps, OS.low_processor_usage_mode, OS.low_processor_usage_mode_sleep_usec, Engine.max_fps, DisplayServer.window_is_focused()])
		out["fps_%d" % i] = fps
	return {"ok": ok, "checks": {}, "info": out}

# ================= GUI-like script editing (run the kit with -Gui) =================
var _code_edits := {}   # path -> CodeEdit

## Opens a script like a double click in the FileSystem dock and remembers its CodeEdit.
func open_script_tab(path: String) -> CodeEdit:
	EditorInterface.edit_script(load(path))
	await d.wait(0.4)
	var cur := EditorInterface.get_script_editor().get_current_editor()
	var ce: CodeEdit = cur.get_base_editor() as CodeEdit if cur != null else null
	if ce != null:
		_code_edits[path] = ce
	return ce

## Real keyboard input (auto-indent, brace completion... all apply), one key per frame.
func type_keys(ce: CodeEdit, s: String) -> void:
	EditorInterface.set_main_screen_editor("Script")   # a person typing is looking at the Script screen
	await d.get_tree().process_frame
	ce.grab_focus()
	var cur := EditorInterface.get_script_editor().get_current_editor()
	d.say("type_keys: visible=%s focus=%s editable=%s current=%s main_visible=%s" % [ce.is_visible_in_tree(), ce.has_focus(), ce.editable, cur != null and cur.get_base_editor() == ce, EditorInterface.get_script_editor().is_visible_in_tree()])
	for ch in s:
		var ev := InputEventKey.new()
		ev.pressed = true
		if ch == "\n":
			ev.keycode = KEY_ENTER
			ev.physical_keycode = KEY_ENTER
		else:
			ev.unicode = ch.unicode_at(0)
			ev.keycode = KEY_A if ch.to_lower() >= "a" and ch.to_lower() <= "z" else KEY_SPACE
		var vp := ce.get_viewport()
		if not ce.has_focus():
			ce.grab_focus()
		vp.push_input(ev)
		var up: InputEventKey = ev.duplicate()
		up.pressed = false
		vp.push_input(up)
		await d.get_tree().process_frame
		await d.get_tree().process_frame

func text_of(path: String) -> String:
	var ce: CodeEdit = _code_edits.get(path, null)
	return ce.text if ce != null and is_instance_valid(ce) else "<no editor>"

func run_script_gui() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var role: String = d.args.get("role")
	var sm: GLCSessionManager = collab_session()
	var alerts := {"n": 0}
	sm.log_line.connect(func(_t, lvl): if lvl >= 1: alerts["n"] += 1)
	write_file("res://second.gd", "extends Node\n\nfunc a():\n\tpass\n")
	EditorInterface.get_resource_filesystem().scan()
	await d.wait(1.5)
	await open_main()
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.5)
	# scripts are opened AFTER connecting; the last one opened is the current tab
	await open_script_tab("res://player.gd")
	await open_script_tab("res://second.gd")
	await wait_t0(4.0)
	# 1. host types into player.gd, which is NOT the current tab on the client
	if role == "host":
		var ce := await open_script_tab("res://player.gd")
		ce.set_caret_line(2)
		ce.set_caret_column(0)
		await type_keys(ce, "var hp := 10\n")
		check("harness_typed_host", ce.text.contains("var hp := 10"), ce.text.c_escape())
	await wait_t0(9.0)
	check("live_edit_in_background_tab_" + role, text_of("res://player.gd").contains("var hp := 10"), text_of("res://player.gd").c_escape())
	# 2. client selects several lines (drawn on the host) and types at the top of player.gd
	if role == "client":
		var ce2 := await open_script_tab("res://player.gd")
		ce2.select(0, 0, 3, 2)
		await d.wait(0.5)
		ce2.deselect()
		ce2.set_caret_line(0)
		ce2.set_caret_column(0)
		await type_keys(ce2, "# hello\n")
	await wait_t0(14.0)
	check("live_edit_c2h_" + role, text_of("res://player.gd").begins_with("# hello"), text_of("res://player.gd").substr(0, 40).c_escape())
	# 3. both type at the same time in second.gd (auto-indent after ':')
	var ce3 := await open_script_tab("res://second.gd")
	ce3.set_caret_line(ce3.get_line_count() - 1)
	ce3.set_caret_column(ce3.get_line(ce3.get_line_count() - 1).length())
	await wait_t0(16.0)
	await type_keys(ce3, ("\nfunc host_fn():\npass" if role == "host" else "\nfunc client_fn():\npass"))
	await wait_t0(22.0)
	check("concurrent_both_present_" + role, text_of("res://second.gd").contains("host_fn") and text_of("res://second.gd").contains("client_fn"), text_of("res://second.gd").c_escape())
	d.say("alerts=%d" % alerts["n"])
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "text": text_of("res://player.gd") + "\n=====\n" + text_of("res://second.gd")}

func _find_by_class(n: Node, cls: String) -> Node:
	if n.get_class() == cls:
		return n
	for c in n.get_children():
		var r := _find_by_class(c, cls)
		if r != null:
			return r
	return null

func _find_visible_by_class(n: Node, cls: String) -> Node:
	if n.get_class() == cls and (not (n is Window) or (n as Window).visible):
		return n
	for c in n.get_children():
		var r := _find_visible_by_class(c, cls)
		if r != null:
			return r
	return null

func _find_button_with_icon(n: Node, icon: Texture2D) -> Button:
	if n is Button and (n as Button).icon == icon:
		return n
	for c in n.get_children():
		var r := _find_button_with_icon(c, icon)
		if r != null:
			return r
	return null

## The real thing: select the node, press the Scene dock's "Attach Script" button, confirm the dialog.
func attach_with_dialog(node: Node) -> String:
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	await d.wait(0.3)
	var base := EditorInterface.get_base_control()
	var dock := _find_by_class(base, "SceneTreeDock")
	var icon: Texture2D = EditorInterface.get_editor_theme().get_icon("ScriptCreate", "EditorIcons")
	var btn := _find_button_with_icon(dock, icon) if dock != null else null
	if btn == null:
		return "no attach button"
	btn.pressed.emit()
	await d.wait(0.8)
	var dlg := _find_visible_by_class(base, "ScriptCreateDialog") as ConfirmationDialog
	if dlg == null:
		return "no dialog"
	var path_edit: LineEdit = null
	for le in dlg.find_children("*", "LineEdit", true, false):
		if String((le as LineEdit).text).begins_with("res://"):
			path_edit = le
	var chosen := path_edit.text if path_edit != null else "?"
	dlg.get_ok_button().pressed.emit()
	await d.wait(1.0)
	return chosen

func run_attach_dialog() -> Dictionary:
	var port := int(d.args.get("port", "25601"))
	var root := await open_main()
	var role: String = d.args.get("role")
	var ok := await connect_pair(port)
	if not ok:
		return {"ok": false, "why": "connect"}
	await both_ready()
	await d.wait(1.0)
	root = EditorInterface.get_edited_scene_root()
	var lat := {}
	# 1. client: Attach Script on UI (a NEW script file is created by the dialog)
	await wait_t0(3.0)
	if role == "client":
		var chosen := await attach_with_dialog(root.get_node("UI"))
		d.say("client dialog path: " + chosen)
		check("author_has_script", root.get_node("UI").get_script() != null, chosen)
	else:
		lat["dialog_attach_c2h"] = await time_until(func(): return root.get_node("UI").get_script() != null, 10.0)
		lat["dialog_icon_c2h"] = await time_until(func(): return scene_dock_has_script_icon(root.get_node("UI")), 5.0)
	# 2. host: Attach Script on Player (existing player.gd is offered and reused)
	await wait_t0(14.0)
	if role == "host":
		var chosen2 := await attach_with_dialog(root.get_node("Player"))
		d.say("host dialog path: " + chosen2)
		check("author_has_script_host", root.get_node("Player").get_script() != null, chosen2)
	else:
		lat["dialog_attach_h2c"] = await time_until(func(): return root.get_node("Player").get_script() != null, 10.0)
		lat["dialog_icon_h2c"] = await time_until(func(): return scene_dock_has_script_icon(root.get_node("Player")), 5.0)
	await wait_t0(26.0)
	for k in lat:
		check("instant_" + k, float(lat[k]) >= 0.0 and float(lat[k]) < 1.5, "%.2fs" % float(lat[k]))
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks, "latency": lat, "dump": d.dump_scene(EditorInterface.get_edited_scene_root())}

func _all_docks(n: Node, out: Array) -> void:
	if n.is_class("EditorDock"):
		out.append(n)
	for c in n.get_children():
		_all_docks(c, out)

func _output_dock() -> Node:
	var docks: Array = []
	_all_docks(EditorInterface.get_base_control(), docks)
	for dk in docks:
		if dk.get_class() == "EditorLog":
			return dk
	return null

## The bottom "Output" panel must stay open when the plugin is turned on.
func run_output_panel() -> Dictionary:
	if d.args.get("role") == "client":
		return {"ok": true, "checks": {}}
	await open_main()
	var docks: Array = []
	_all_docks(EditorInterface.get_base_control(), docks)
	for dk in docks:
		d.say("dock %s title=%s visible=%s" % [dk.get_class(), dk.get("title"), dk.is_visible_in_tree()])
	var out := _output_dock()
	if out == null:
		return {"ok": false, "why": "no EditorLog dock"}
	out.call("make_visible")
	await d.wait(0.5)
	check("output_open_before", out.is_visible_in_tree())
	EditorInterface.set_plugin_enabled("godot_live_collab", false)
	await d.wait(1.0)
	check("output_open_after_disable", out.is_visible_in_tree())
	out.call("make_visible")
	await d.wait(0.5)
	EditorInterface.set_plugin_enabled("godot_live_collab", true)
	for i in 6:
		await d.wait(0.25)
		d.say("after enable +%.2fs output visible=%s" % [(i + 1) * 0.25, out.is_visible_in_tree()])
	check("output_open_after_enable", out.is_visible_in_tree())
	# like the user's layout: the Live Collab tab is the selected one in its dock
	var mine: Node = null
	var docks2: Array = []
	_all_docks(EditorInterface.get_base_control(), docks2)
	for dk in docks2:
		if String(dk.get("title")) == "Live Collab":
			mine = dk
	if mine != null:
		out.call("make_visible")
		await d.wait(0.3)
		mine.call("make_visible")
		await d.wait(0.6)
		d.say("live collab dock visible=%s min=%s size=%s | output visible=%s size=%s | window=%s" % [mine.is_visible_in_tree(), (mine as Control).get_combined_minimum_size(), (mine as Control).size, out.is_visible_in_tree(), (out as Control).size, DisplayServer.window_get_size()])
		check("output_open_with_dock_shown", out.is_visible_in_tree() and (out as Control).size.y > 40.0, str((out as Control).size))
		EditorInterface.set_plugin_enabled("godot_live_collab", false)
		await d.wait(1.0)
		out.call("make_visible")
		await d.wait(0.3)
		EditorInterface.set_plugin_enabled("godot_live_collab", true)
		await d.wait(1.5)
		d.say("re-enabled with dock selected: output visible=%s size=%s" % [out.is_visible_in_tree(), (out as Control).size])
		check("output_open_after_enable_dock_selected", out.is_visible_in_tree() and (out as Control).size.y > 40.0, str((out as Control).size))
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks}

## Turning the plugin off and on (Project Settings > Plugins), with and without a running session.
func run_toggle_plugin() -> Dictionary:
	var role: String = d.args.get("role")
	var port := int(d.args.get("port", "25601"))
	if role == "client":
		return {"ok": true, "checks": {}}
	await open_main()
	for i in 3:
		d.say("toggle %d: disable" % i)
		EditorInterface.set_plugin_enabled("godot_live_collab", false)
		await d.wait(1.5)
		d.say("toggle %d: enable" % i)
		EditorInterface.set_plugin_enabled("godot_live_collab", true)
		await d.wait(2.0)
		d.collab = d.find_collab()
		check("enabled_%d" % i, d.collab != null)
		if i == 1 and d.collab != null:
			var sm = d.collab.get("session_manager")
			check("hosted_after_reenable", sm.host_session(port, "", "Host", Color.GREEN) == OK)
			await d.wait(2.0)
	d.say("survived")
	var allok := true
	for k in checks: if not checks[k]: allok = false
	return {"ok": allok, "checks": checks}

func run_dock_check() -> Dictionary:
	var c = d.collab
	var dock = c.get("dock")
	var out := {"has_dock": dock != null}
	if dock != null:
		out["in_tree"] = dock.is_inside_tree()
		out["parent_class"] = dock.get_parent().get_class() if dock.get_parent() else ""
		dock.refresh()
		out["status_text"] = dock._status.text
		out["tabs"] = dock.get_child(1).get_tab_count()
	out["presence_ok"] = c.get("presence_sync") != null
	return {"ok": true, "checks": {"dock_created": dock != null and dock.is_inside_tree()}, "info": out}
