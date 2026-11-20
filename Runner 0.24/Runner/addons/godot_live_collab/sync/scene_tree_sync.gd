@tool
class_name GLCSceneTreeSync
extends RefCounted
## Keeps every open scene identical on all peers.
##
##  local edits   ->  detected by diffing the live tree against the scene model (signals only mark "dirty")
##                    -> operations (s.add / s.del / s.ren / s.mov / s.set / s.res) -> host
##  host stream   ->  canonical operations -> replica model (optimistic rebase) -> projected onto the tree
##                    through a time-budgeted queue
##
## Node identity is a runtime uid kept in a registry (instance id -> uid); nothing is written into your
## scene files. On join, existing nodes are *matched by name* with the host's snapshot instead of duplicated.

signal activity(text: String)
signal scene_synced(path: String)
signal scene_unsynced(path: String)
signal saved_remotely(path: String)

const PROJECT_BUDGET_MS := 6.0
const SWEEP_PER_FRAME := 48
const GRAVE_SECONDS := 30.0
const HINT_INTERVAL_MS := 33
const HINT_STALE_MS := 300
const HINT_SETTLE_MS := 500
const RETRY_INTERVAL_MS := 1500
const MAX_RETRIES := 40

const HINT_PROPS := {
	"Node2D": ["position", "rotation", "scale", "skew"],
	"Node3D": ["position", "rotation", "scale", "transform"],
	"Control": ["position", "size", "rotation", "scale", "offset_left", "offset_top", "offset_right", "offset_bottom"],
}

var session: GLCSessionManager
var plugin: EditorPlugin
var codec: GLCPropertyResourceSync = GLCPropertyResourceSync.new()
var enabled: bool = true
var verbose: bool = false
## func(paths: Array): announce referenced files the others may not have yet (set by the plugin)
var ensure_files: Callable = Callable()

var bindings: Dictionary = {}       # scene path -> Binding
var models: Dictionary = {}         # host only: scene path -> GLCSceneModel (authoritative)
var _by_root: Dictionary = {}       # root instance id -> Binding
var _seed_waiters: Dictionary = {}  # host: scene path -> [peer ids waiting for the first model]
var _graveyard: Array = []
var _scan_accum: float = 0.0
var _last_hint_ms: int = 0
var _hint_cache: Dictionary = {}    # uid -> {prop: hash}
var _drag_lock: Dictionary = {}     # uid -> expiry ms (we are dragging it; ignore remote hints)
var _started: bool = false
var _retry_accum: float = 0.0
var _inspector_refresh_pending: bool = false
var _undo_dirty: bool = false
var _saving_remote_until_ms: int = 0
var _needs_save: Dictionary = {}
var _marking_unsaved: bool = false
var _last_mark_ms: int = 0
var _warned_classes: Dictionary = {}   # classes already reported as unavailable (reported once)
var stats: Dictionary = {"ops_sent": 0, "ops_received": 0, "projected": 0, "resyncs": 0}

func _init(p_session: GLCSessionManager, p_plugin: EditorPlugin) -> void:
	session = p_session
	plugin = p_plugin
	for t in [GLCSceneModel.OP_ADD, GLCSceneModel.OP_DEL, GLCSceneModel.OP_REN, GLCSceneModel.OP_MOV, GLCSceneModel.OP_SET, GLCSceneModel.OP_RES]:
		session.register(t, _on_op.bind(t), "op", {"scope": "scene"})
	session.register(GLCProtocol.S_OPEN, _on_s_open, "direct")
	session.register(GLCProtocol.S_STATE, _on_s_state, "direct")
	session.register(GLCProtocol.S_SEED, _on_s_seed, "direct")
	session.register(GLCProtocol.S_CLOSE, _on_s_close, "direct")
	session.register(GLCProtocol.S_TF, _on_s_tf, "bcast", {"scope": "scene", "reliable": false})
	session.register(GLCProtocol.S_SAVED, _on_s_saved, "bcast", {"scope": "scene"})
	session.session_started.connect(_on_session_started)
	session.session_ended.connect(_on_session_ended)
	session.peer_left.connect(_on_peer_left)

func start() -> void:
	if _started:
		return
	_started = true
	var tree := plugin.get_tree()
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)
	tree.node_renamed.connect(_on_node_renamed)
	var insp := EditorInterface.get_inspector()
	if insp != null:
		insp.property_edited.connect(_on_inspector_edited)
	var ur := EditorInterface.get_editor_undo_redo()
	if ur != null:
		ur.version_changed.connect(_on_undo_changed)
		ur.history_changed.connect(_on_undo_changed)

func stop() -> void:
	if not _started:
		return
	_started = false
	var tree := plugin.get_tree()
	if tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
		tree.node_removed.disconnect(_on_node_removed)
		tree.node_renamed.disconnect(_on_node_renamed)
	var insp := EditorInterface.get_inspector()
	if insp != null and insp.property_edited.is_connected(_on_inspector_edited):
		insp.property_edited.disconnect(_on_inspector_edited)
	var ur := EditorInterface.get_editor_undo_redo()
	if ur != null:
		if ur.version_changed.is_connected(_on_undo_changed):
			ur.version_changed.disconnect(_on_undo_changed)
		if ur.history_changed.is_connected(_on_undo_changed):
			ur.history_changed.disconnect(_on_undo_changed)
	for path in bindings.keys():
		_unbind(path, false)
	models.clear()

# ====================================================================== binding record

class Binding extends RefCounted:
	var path: String = ""
	var root: Node = null
	var sync: GLCSceneTreeSync = null
	var model: GLCSceneModel = null
	var replica: GLCSceneModel.Replica = null     # null on the host
	var state: String = "new"                     # new | waiting | seeding | synced
	var uid_by_iid: Dictionary = {}
	var node_by_uid: Dictionary = {}
	var hashes: Dictionary = {}
	var ruid_by_iid: Dictionary = {}
	var res_refs: Dictionary = {}                 # ruid -> WeakRef
	var res_hashes: Dictionary = {}
	var dirty_parents: Dictionary = {}
	var dirty_names: Dictionary = {}
	var dirty_props: Dictionary = {}
	var dirty_res: Dictionary = {}
	var project_queue: Array = []
	var project_filter: Dictionary = {}           # uid -> {prop: true} | {"*": true}
	var project_seq: Dictionary = {}              # uid -> enqueue sequence (stable ordering)
	var project_counter: int = 0
	var queue_dirty: bool = false
	var projecting_guard: Dictionary = {}
	var applying: int = 0
	var sweep_list: Array = []
	var sweep_pos: int = 0
	var retry: Dictionary = {}                    # uid -> attempts
	var fallback_inst: Dictionary = {}            # uid -> scene path we could not load yet
	var pending_full_sweep: bool = false
	var last_retry_ms: int = 0
	var remote_dirty: bool = false                # someone else changed this scene: mark it as unsaved here
	var root_iid: int = 0
	var stalled: Dictionary = {}                  # uid -> true: gave up retrying; woken when a file arrives
	var hinted: Dictionary = {}                   # uid -> {t, props}: values shown from live drag hints
	var last_projected: Dictionary = {}           # uid -> ms of the last reliable projection

	func is_current() -> bool:
		return root != null and is_instance_valid(root) and root == EditorInterface.get_edited_scene_root()

	func is_user_node(n: Node) -> bool:
		return n == root or n.owner == root

	# --- codec interface ---
	func uid_of_node(n: Node) -> String:
		var u: String = uid_by_iid.get(n.get_instance_id(), "")
		if u.is_empty() and root != null and is_user_node(n) and n.is_inside_tree() == root.is_inside_tree():
			u = ensure_uid(n)
		return u

	func node_of_uid(u: String) -> Node:
		var n: Variant = node_by_uid.get(u, null)
		if n != null and is_instance_valid(n):
			return n
		return null

	func ruid_of(r: Resource) -> String:
		var iid := r.get_instance_id()
		var u: String = ruid_by_iid.get(iid, "")
		if u.is_empty():
			u = GLCProtocol.new_uid()
			ruid_by_iid[iid] = u
			res_refs[u] = weakref(r)
			watch_resource(r)
		return u

	func resource_of(u: String) -> Resource:
		var w: Variant = res_refs.get(u, null)
		if w != null:
			var r: Variant = (w as WeakRef).get_ref()
			if r != null and is_instance_valid(r):
				return r
		return null

	func register_resource(u: String, r: Resource) -> void:
		ruid_by_iid[r.get_instance_id()] = u
		res_refs[u] = weakref(r)

	func watch_resource(r: Resource) -> void:
		var u: String = ruid_by_iid.get(r.get_instance_id(), "")
		if u.is_empty():
			return
		var cb := Callable(sync, "_on_res_changed").bind(self, u)
		if not r.changed.is_connected(cb):
			r.changed.connect(cb)

	func res_cache(u: String) -> Dictionary:
		if not res_hashes.has(u):
			res_hashes[u] = {}
		return res_hashes[u]

	# --- registry ---
	func hash_cache(u: String) -> Dictionary:
		if not hashes.has(u):
			hashes[u] = {}
		return hashes[u]

	func ensure_uid(n: Node) -> String:
		var iid := n.get_instance_id()
		var u: String = uid_by_iid.get(iid, "")
		if u.is_empty():
			u = GLCProtocol.new_uid()
			register_node(u, n)
		return u

	func register_node(u: String, n: Node) -> void:
		var old: Variant = node_by_uid.get(u, null)
		if old != null and is_instance_valid(old) and old != n:
			uid_by_iid.erase((old as Node).get_instance_id())
		uid_by_iid[n.get_instance_id()] = u
		node_by_uid[u] = n
		var cb := Callable(sync, "_on_child_order").bind(self, u)
		if not n.child_order_changed.is_connected(cb):
			n.child_order_changed.connect(cb)

	func forget_node(u: String) -> void:
		var n: Variant = node_by_uid.get(u, null)
		if n != null and is_instance_valid(n):
			uid_by_iid.erase((n as Node).get_instance_id())
		node_by_uid.erase(u)
		hashes.erase(u)
		retry.erase(u)
		fallback_inst.erase(u)
		_hint_forget(u)

	func _hint_forget(u: String) -> void:
		if sync != null:
			sync._hint_cache.erase(u)

	func new_ctx() -> Dictionary:
		return {"b": self, "res_out": {}, "res_in": model.res if model != null else {}, "missing": []}

	func user_kids(n: Node) -> Array:
		var out: Array = []
		for c in n.get_children():
			if is_user_node(c):
				out.append(c)
		return out

# ====================================================================== binding lifecycle

func current_binding() -> Binding:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	return _by_root.get(root.get_instance_id(), null)

func binding_of_scene(path: String) -> Binding:
	return bindings.get(path, null)

func node_for(scene_path: String, uid: String) -> Node:
	var b: Binding = bindings.get(scene_path, null)
	return b.node_of_uid(uid) if b != null else null

func uid_for(node: Node) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	var b: Binding = _by_root.get(root.get_instance_id(), null)
	if b == null:
		return ""
	return b.uid_by_iid.get(node.get_instance_id(), "")

func _scan_open_scenes() -> void:
	var live := {}
	for r in EditorInterface.get_open_scene_roots():
		var path: String = r.scene_file_path
		if path.is_empty():
			continue
		live[path] = r
		var b: Binding = bindings.get(path, null)
		if b == null:
			_bind(r)
		elif b.root != r or not is_instance_valid(b.root):
			# scene was reloaded from disk (new root object): rebind
			_unbind(path, true)
			_bind(r)
	for path in bindings.keys():
		if not live.has(path):
			_unbind(path, true)

func _bind(root: Node) -> void:
	var path: String = root.scene_file_path
	var b := Binding.new()
	b.path = path
	b.root = root
	b.root_iid = root.get_instance_id()
	b.sync = self
	bindings[path] = b
	_by_root[b.root_iid] = b
	if session.is_hosting:
		var m: GLCSceneModel = models.get(path, null)
		if m == null:
			m = _seed_model(b)
			models[path] = m
			b.model = m
			b.state = "synced"
			_refresh_sweep(b)
			scene_synced.emit(path)
			if verbose:
				print("[GLC] host seeded model for ", path, " (", m.size(), " nodes)")
		else:
			# others already changed this scene: the host tree adopts the live state
			b.model = m
			_adopt_and_project(b)
			b.state = "synced"
			scene_synced.emit(path)
	else:
		b.state = "waiting"
		b.replica = GLCSceneModel.Replica.new()
		b.model = b.replica.model
		b.model.scene_path = path
		session.subscribe("scene:" + path)
		session.send_to(1, GLCProtocol.S_OPEN, {"scene": path})
	_publish_active_scene()

func _unbind(path: String, notify: bool) -> void:
	var b: Binding = bindings.get(path, null)
	if b == null:
		return
	bindings.erase(path)
	# the root may already be freed (scene closed / reloaded): use the id recorded at bind time
	_by_root.erase(b.root_iid)
	for u in b.node_by_uid.keys():
		var n: Node = b.node_of_uid(u)
		if n != null:
			var cb := Callable(self, "_on_child_order").bind(b, u)
			if n.child_order_changed.is_connected(cb):
				n.child_order_changed.disconnect(cb)
	if notify and session.is_active_session:
		if not session.is_hosting:
			session.unsubscribe("scene:" + path)
			session.send_to(1, GLCProtocol.S_CLOSE, {"scene": path})
		else:
			_maybe_drop_model(path)
	scene_unsynced.emit(path)

func _maybe_drop_model(path: String) -> void:
	if not session.is_hosting:
		return
	if bindings.has(path):
		return
	if session.subscribers_of("scene:" + path).is_empty():
		models.erase(path)

func _publish_active_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var open: Array = []
	for r in EditorInterface.get_open_scene_roots():
		if not String(r.scene_file_path).is_empty():
			open.append(r.scene_file_path)
	session.publish_info({"scene": root.scene_file_path if root != null else "", "open_scenes": open})

func on_editor_scene_changed() -> void:
	_publish_active_scene()
	var b := current_binding()
	if b != null and b.state == "synced":
		b.pending_full_sweep = true
		b.dirty_parents[b.uid_by_iid.get(b.root.get_instance_id(), "")] = true
		if _needs_save.has(b.path):
			_needs_save.erase(b.path)
			b.remote_dirty = false
			call_deferred("_save_current_for_remote", b.path)

## The local user saved a scene: tell the others who have it open so they save their (identical) copy too.
func notify_scene_saved(path: String) -> void:
	if not session.is_active_session or Time.get_ticks_msec() < _saving_remote_until_ms:
		return
	var b: Binding = bindings.get(path, null)
	if b != null:
		# edits made right before Ctrl+S must reach the others before the "save" notice does
		_flush_local(b)
		session.bcast(GLCProtocol.S_SAVED, {"scene": path})

func _on_s_saved(_sender: int, p: Dictionary, _meta: Dictionary) -> void:
	var path := String(p.get("scene", ""))
	var b: Binding = bindings.get(path, null)
	if b == null or b.state != "synced":
		return
	if b.is_current():
		call_deferred("_save_current_for_remote", path)
	else:
		_needs_save[path] = true

func _save_current_for_remote(path: String, attempt: int = 0) -> void:
	var b: Binding = bindings.get(path, null)
	if b == null or not b.is_current() or b.state != "synced":
		return
	if not b.project_queue.is_empty() or not b.fallback_inst.is_empty():
		# remote changes are still being applied (or an instanced scene has not arrived yet and a
		# placeholder stands in for it): save only once the tree shows the real thing
		if attempt >= 200:
			b.remote_dirty = true   # give up (never save a half-applied tree); the scene stays "unsaved"
			return
		var t := plugin.get_tree().create_timer(0.05)
		t.timeout.connect(_save_current_for_remote.bind(path, attempt + 1))
		return
	_flush_local(b)
	_saving_remote_until_ms = Time.get_ticks_msec() + 2500
	b.remote_dirty = false
	EditorInterface.save_scene()
	saved_remotely.emit(path)

func _on_session_started(is_host: bool) -> void:
	_scan_accum = 1.0
	if is_host:
		models.clear()
	_scan_open_scenes()

func _on_session_ended(_reason: String) -> void:
	for path in bindings.keys():
		_unbind(path, false)
	models.clear()
	_seed_waiters.clear()

func _on_peer_left(peer_id: int, _info: Dictionary) -> void:
	for path in _seed_waiters.keys():
		(_seed_waiters[path] as Array).erase(peer_id)
	for path in models.keys():
		_maybe_drop_model(path)

# ====================================================================== capture (tree -> data)

## `existing_out` (optional): nodes that are already in the model are NOT nested (the model would ignore
## them); they are reported as [uid, parent_uid, index, name] so the caller can move them instead
## (e.g. "Reparent to New Node": a new parent adopting existing children).
func _capture_subtree(b: Binding, node: Node, ctx: Dictionary, existing_out: Variant = null) -> Dictionary:
	var uid := b.ensure_uid(node)
	var inst := ""
	if node != b.root:
		inst = String(node.scene_file_path)
	var entry := {
		"uid": uid,
		"name": String(node.name),
		"cls": node.get_class(),
		"inst": inst,
		"props": codec.capture_node(node, ctx, b.hash_cache(uid)),
		"kids": [],
	}
	var kids := b.user_kids(node)
	for i in kids.size():
		var c: Node = kids[i]
		if existing_out is Array:
			var cu: String = b.uid_by_iid.get(c.get_instance_id(), "")
			if not cu.is_empty() and b.model.has_node(cu):
				(existing_out as Array).append([cu, uid, i, String(c.name)])
				continue
		entry["kids"].append(_capture_subtree(b, c, ctx, existing_out))
	return entry

## Whole tree as a model snapshot (assigns uids).
func _capture_snapshot(b: Binding) -> Dictionary:
	var ctx := b.new_ctx()
	var m := GLCSceneModel.new()
	m.scene_path = b.path
	var top := _capture_subtree(b, b.root, ctx)
	top["parent"] = ""
	top["index"] = 0
	m.apply(GLCSceneModel.OP_ADD, top, false)
	m.res = ctx["res_out"]
	m.take_changes()
	return m.snapshot()

func _seed_model(b: Binding) -> GLCSceneModel:
	var snap := _capture_snapshot(b)
	var m := GLCSceneModel.from_snapshot(snap)
	m.scene_path = b.path
	m.take_changes()
	return m

## Host: builds the model of a scene that is not open here from the file on disk (null if impossible).
func _seed_model_from_disk(path: String) -> GLCSceneModel:
	if not GLCProtocol.is_scene_ext(path) or not FileAccess.file_exists(path):
		return null
	var ps: Variant = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not (ps is PackedScene) or not (ps as PackedScene).can_instantiate():
		return null
	var root: Node = (ps as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		return null
	var tmp := Binding.new()
	tmp.path = path
	tmp.root = root
	tmp.sync = self
	var m := _seed_model(tmp)
	for u in tmp.node_by_uid.keys():
		var n: Node = tmp.node_of_uid(u)
		if n != null:
			var cb := Callable(self, "_on_child_order").bind(tmp, u)
			if n.child_order_changed.is_connected(cb):
				n.child_order_changed.disconnect(cb)
	root.free()
	if verbose:
		print("[GLC] host seeded model for ", path, " from disk (", m.size(), " nodes)")
	return m

# ====================================================================== network: handshake

func _on_s_open(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not session.is_hosting:
		return
	var path := String(p.get("scene", ""))
	if not GLCProtocol.is_safe_res_path(path):
		return
	var b: Binding = bindings.get(path, null)
	if b != null and b.state == "synced":
		_flush_local(b)
	var m: GLCSceneModel = models.get(path, null)
	if m == null and b == null and not _seed_waiters.has(path):
		# nobody has this scene open yet: the host's saved file is the reference (the client's open copy
		# may be older — the file reconcile also lets the host win)
		m = _seed_model_from_disk(path)
		if m != null:
			models[path] = m
	if m != null:
		session.send_to(sender, GLCProtocol.S_STATE, {"scene": path, "snapshot": m.snapshot()})
		return
	if not _seed_waiters.has(path):
		_seed_waiters[path] = []
	if not (_seed_waiters[path] as Array).has(sender):
		_seed_waiters[path].append(sender)
	if (_seed_waiters[path] as Array).size() == 1:
		session.send_to(sender, GLCProtocol.S_STATE, {"scene": path, "need_seed": true})

func _on_s_seed(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not session.is_hosting:
		return
	var path := String(p.get("scene", ""))
	var snap: Variant = p.get("snapshot", null)
	if not (snap is Dictionary):
		return
	var m: GLCSceneModel = models.get(path, null)
	if m == null:
		m = GLCSceneModel.from_snapshot(snap)
		m.scene_path = path
		m.take_changes()
		models[path] = m
	for peer in _seed_waiters.get(path, []):
		if session.peers.has(peer):
			session.send_to(peer, GLCProtocol.S_STATE, {"scene": path, "snapshot": m.snapshot()})
	_seed_waiters.erase(path)

func _on_s_close(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if session.is_hosting:
		var path := String(p.get("scene", ""))
		(session._subs.get("scene:" + path, {}) as Dictionary).erase(sender)
		_maybe_drop_model(path)

func _on_s_state(_sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if session.is_hosting:
		return
	var path := String(p.get("scene", ""))
	var b: Binding = bindings.get(path, null)
	if b == null:
		return
	if p.get("need_seed", false):
		var snap := _capture_snapshot(b)
		b.state = "seeding"
		session.send_to(1, GLCProtocol.S_SEED, {"scene": path, "snapshot": snap})
		return
	var snap2: Variant = p.get("snapshot", null)
	if not (snap2 is Dictionary):
		return
	b.replica.reset_from_snapshot(snap2)
	b.model = b.replica.model
	b.model.scene_path = path
	_adopt_and_project(b)
	b.state = "synced"
	_refresh_sweep(b)
	activity.emit("Cena sincronizada: " + path.get_file())
	scene_synced.emit(path)

func request_resync(b: Binding, reason: String = "") -> void:
	if session.is_hosting or not session.is_active_session:
		return
	stats["resyncs"] += 1
	if verbose:
		push_warning("[GLC] ressincronizando %s (%s)" % [b.path, reason])
	activity.emit("Ressincronizando %s" % b.path.get_file())
	b.state = "waiting"
	b.replica.pending.clear()
	session.send_to(1, GLCProtocol.S_OPEN, {"scene": b.path})

## Host-side: someone asks us for the canonical state right now (e.g. verification failed).
func resync_all() -> void:
	for b in bindings.values():
		request_resync(b, "manual")

# ====================================================================== network: operations

func _brief(p: Dictionary) -> String:
	var q := p.duplicate()
	q.erase("res")
	q.erase("kids")
	if q.has("props"):
		q["props"] = (q["props"] as Dictionary).keys()
	return str(q)

func _on_op(sender: int, p: Dictionary, meta: Dictionary, t: String) -> Variant:
	stats["ops_received"] += 1
	GLCProtocol.trace("recv %s stage=%s %s" % [t, meta.get("stage"), _brief(p)])
	if verbose:
		print("[GLC] recv ", t, " stage=", meta.get("stage"), " ", _brief(p))
	var path := String(p.get("scene", ""))
	if meta["stage"] == "host":
		var m: GLCSceneModel = models.get(path, null)
		if m == null:
			meta["reason"] = "noscene"
			return null
		var hb0: Binding = bindings.get(path, null)
		if hb0 != null:
			_flush_local(hb0)   # our own pending edits are ordered before the incoming one
		var canon: Variant = m.apply(t, p, false)
		if canon == null:
			meta["reason"] = m.last_error
			return null
		meta["corr"] = _corr_for(t, canon)
		var hb: Binding = bindings.get(path, null)
		if hb != null:
			_enqueue_changes(hb)
			hb.remote_dirty = true
		else:
			m.take_changes()
		return canon
	# client stage: canonical op made by another peer
	var b: Binding = bindings.get(path, null)
	if b == null or b.state != "synced" or b.replica == null:
		return null
	_flush_local(b)
	b.replica.receive(t, p)
	_after_replica_update(b)
	b.remote_dirty = true
	return null

static func _corr_for(t: String, canon: Dictionary) -> Dictionary:
	match t:
		GLCSceneModel.OP_ADD, GLCSceneModel.OP_MOV:
			return {"uid": canon["uid"], "parent": canon["parent"], "index": canon["index"], "name": canon["name"]}
		GLCSceneModel.OP_REN:
			return {"uid": canon["uid"], "name": canon["name"]}
	return {}

func _after_replica_update(b: Binding) -> void:
	_enqueue_changes(b)
	if b.replica != null and b.replica.needs_resync:
		var why := b.replica.resync_reason
		b.replica.needs_resync = false
		request_resync(b, why)

func _on_ack(corr: Variant, _seq: int, b: Binding, op_id: int) -> void:
	if b.replica == null or b.state != "synced":
		return
	b.replica.ack(op_id, corr)
	_after_replica_update(b)

func _on_rej(reason: String, b: Binding, op_id: int) -> void:
	if b.replica == null or b.state != "synced":
		return
	b.replica.reject(op_id, reason)
	_after_replica_update(b)

## Submit a local change. Returns false if the operation was invalid / not connected.
## Files referenced by an operation (external resources, instanced scenes), so the file layer can send
## the ones the others do not have yet BEFORE the operation itself.
static func _referenced_files(v: Variant, out: Dictionary, depth: int = 0) -> void:
	if depth > 32:
		return
	if v is Dictionary:
		var d: Dictionary = v
		if String(d.get("__glc", "")) == "ext":
			out[String(d.get("path", ""))] = true
			return
		if d.has("inst") and d.has("cls") and String(d["inst"]) != "":
			out[String(d["inst"])] = true
		for k in d:
			_referenced_files(d[k], out, depth + 1)
	elif v is Array:
		for e in v:
			_referenced_files(e, out, depth + 1)

func _submit(b: Binding, t: String, payload: Dictionary) -> bool:
	payload["scene"] = b.path
	if ensure_files.is_valid() and t in [GLCSceneModel.OP_ADD, GLCSceneModel.OP_SET, GLCSceneModel.OP_RES]:
		var refs := {}
		_referenced_files(payload, refs)
		if not refs.is_empty():
			ensure_files.call(refs.keys())
	stats["ops_sent"] += 1
	GLCProtocol.trace("submit %s %s" % [t, _brief(payload)])
	if verbose:
		print("[GLC] submit ", t, " ", _brief(payload))
	if session.is_hosting:
		var canon: Variant = b.model.apply(t, payload, false)
		if canon == null:
			return false
		_discard_or_project_host_changes(b, t, canon)
		session.submit(0, t, canon)
		return true
	var id := session.next_op_id()
	var canon2: Variant = b.replica.apply_local(id, t, payload)
	if canon2 == null:
		return false
	_check_local_names(b, t, canon2)
	session.submit(id, t, canon2, Callable(self, "_on_ack").bind(b, id), Callable(self, "_on_rej").bind(b, id))
	return true

## Our own apply may have uniquified a name differently from the tree; if so, the tree must follow.
func _discard_or_project_host_changes(b: Binding, t: String, canon: Dictionary) -> void:
	var differs := false
	var uid := String(canon.get("uid", ""))
	if t in [GLCSceneModel.OP_ADD, GLCSceneModel.OP_REN, GLCSceneModel.OP_MOV]:
		var n := b.node_of_uid(uid)
		differs = n != null and String(n.name) != String(canon.get("name", n.name))
	if differs:
		_enqueue_changes(b)
	else:
		b.model.take_changes()

func _check_local_names(b: Binding, t: String, canon: Dictionary) -> void:
	var uid := String(canon.get("uid", ""))
	if t in [GLCSceneModel.OP_ADD, GLCSceneModel.OP_REN, GLCSceneModel.OP_MOV]:
		var n := b.node_of_uid(uid)
		if n != null and String(n.name) != String(canon.get("name", n.name)):
			_enqueue_changes(b)
			return
	b.model.take_changes()

# ====================================================================== local change detection

func _on_node_added(node: Node) -> void:
	if not node.is_part_of_edited_scene():
		return
	var b := current_binding()
	if b == null or b.applying > 0:
		return
	var parent := node.get_parent()
	if parent != null:
		var puid: String = b.uid_by_iid.get(parent.get_instance_id(), "")
		if not puid.is_empty():
			b.dirty_parents[puid] = true

func _on_node_removed(node: Node) -> void:
	if not node.is_part_of_edited_scene():
		return
	var b := current_binding()
	if b == null or b.applying > 0:
		return
	var parent := node.get_parent()
	if parent != null:
		var puid: String = b.uid_by_iid.get(parent.get_instance_id(), "")
		if not puid.is_empty():
			b.dirty_parents[puid] = true

func _on_node_renamed(node: Node) -> void:
	if not node.is_part_of_edited_scene():
		return
	var b := current_binding()
	if b == null or b.applying > 0:
		return
	var u: String = b.uid_by_iid.get(node.get_instance_id(), "")
	if not u.is_empty():
		b.dirty_names[u] = true

func _on_child_order(b: Binding, uid: String) -> void:
	if b.applying > 0 or b.state != "synced":
		return
	b.dirty_parents[uid] = true

func _on_inspector_edited(_prop: String) -> void:
	GLCProtocol.trace("inspector edited %s" % _prop)
	var b := current_binding()
	if b == null or b.state != "synced":
		return
	var obj := EditorInterface.get_inspector().get_edited_object()
	if obj is Node:
		var u: String = b.uid_by_iid.get((obj as Node).get_instance_id(), "")
		if not u.is_empty():
			b.dirty_props[u] = true
	elif obj is Resource:
		var ruid: String = b.ruid_by_iid.get((obj as Resource).get_instance_id(), "")
		if not ruid.is_empty():
			b.dirty_res[ruid] = true

func _on_undo_changed() -> void:
	if _marking_unsaved:
		return
	_undo_dirty = true

## Remote edits are applied without going through the undo history, so the editor would not know the
## scene changed: mark it as unsaved (the "(*)" in the tab, and the save prompt when closing).
func _mark_remote_dirty() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_mark_ms < 400:
		return
	for b in bindings.values():
		if b.remote_dirty and b.project_queue.is_empty() and b.is_current():
			b.remote_dirty = false
			_last_mark_ms = now
			_marking_unsaved = true
			EditorInterface.mark_scene_as_unsaved()
			_marking_unsaved = false

func _on_res_changed(b: Binding, ruid: String) -> void:
	if b.applying > 0 or b.state != "synced":
		return
	b.dirty_res[ruid] = true

# ====================================================================== per-frame work

func process(delta: float) -> void:
	if not session.is_active_session:
		return
	if not enabled:
		if not bindings.is_empty():
			for path in bindings.keys():
				_unbind(path, true)
		return
	_scan_accum += delta
	if _scan_accum >= 0.4:
		_scan_accum = 0.0
		_scan_open_scenes()
	_free_graveyard()
	_retry_accum += delta
	for b in bindings.values():
		_settle_hints(b)
		_pump_projection(b)
		if _retry_accum * 1000.0 >= RETRY_INTERVAL_MS:
			_retry_unresolved(b)
		if b.model != null and b.sweep_list.size() != b.model.nodes.size():
			_refresh_sweep(b)   # nodes were added/removed: keep the background sweep complete
	if _retry_accum * 1000.0 >= RETRY_INTERVAL_MS:
		_retry_accum = 0.0
	_mark_remote_dirty()
	var cur := current_binding()
	if cur == null or cur.state != "synced" or not cur.project_queue.is_empty():
		return
	if _undo_dirty:
		_undo_dirty = false
		cur.pending_full_sweep = true
	_local_diff(cur)
	if _inspector_refresh_pending:
		_inspector_refresh_pending = false
		var insp := EditorInterface.get_inspector()
		if insp != null:
			var shown := insp.get_edited_object()
			if shown != null and is_instance_valid(shown):
				shown.notify_property_list_changed()

## Make the model reflect every change already made in the tree (called before applying remote data).
func _flush_local(b: Binding) -> void:
	if not b.is_current() or b.state != "synced" or not b.project_queue.is_empty():
		return
	_flush_structure(b)
	_flush_props_now(b)

func _local_diff(b: Binding) -> void:
	_flush_structure(b)
	var dragging := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not EditorInterface.get_selection().get_selected_nodes().is_empty()
	_flush_resources(b)
	# uid -> true when signal connections must be compared too (selected nodes, editor actions)
	var uids := {}
	for u in b.dirty_props:
		uids[u] = false
	b.dirty_props.clear()
	if dragging:
		_send_drag_hints(b)
	else:
		var with_conns := 16
		for n in EditorInterface.get_selection().get_selected_nodes():
			var u: String = b.uid_by_iid.get(n.get_instance_id(), "")
			if not u.is_empty():
				uids[u] = with_conns > 0
				with_conns -= 1
	if b.pending_full_sweep:
		b.pending_full_sweep = false
		_refresh_sweep(b)
		b.sweep_pos = 0
		for u in b.sweep_list:
			uids[u] = true
	elif not dragging:
		var n_sweep := mini(SWEEP_PER_FRAME, b.sweep_list.size())
		for i in n_sweep:
			if b.sweep_list.is_empty():
				break
			b.sweep_pos = (b.sweep_pos + 1) % b.sweep_list.size()
			var su: String = b.sweep_list[b.sweep_pos]
			if not uids.has(su):
				uids[su] = false
	for u in uids:
		_diff_and_send_props(b, u, bool(uids[u]))

func _flush_props_now(b: Binding) -> void:
	var uids := {}
	for u in b.dirty_props:
		uids[u] = false
	b.dirty_props.clear()
	for n in EditorInterface.get_selection().get_selected_nodes():
		var u: String = b.uid_by_iid.get(n.get_instance_id(), "")
		if not u.is_empty():
			uids[u] = true
	if _undo_dirty:
		# an editor action happened since the last frame (e.g. a signal was connected): compare everything
		_undo_dirty = false
		_refresh_sweep(b)
		for u in b.sweep_list:
			uids[u] = true
	for u in uids:
		_diff_and_send_props(b, u, bool(uids[u]))
	_flush_resources(b)

func _refresh_sweep(b: Binding) -> void:
	b.sweep_list = b.model.nodes.keys() if b.model != null else []

func _diff_and_send_props(b: Binding, uid: String, with_conns: bool = false) -> void:
	var node := b.node_of_uid(uid)
	if node == null or not b.model.has_node(uid):
		return
	var ctx := b.new_ctx()
	ctx["conns"] = with_conns
	var changed := codec.diff_node(node, ctx, b.hash_cache(uid))
	if changed.is_empty():
		return
	_submit(b, GLCSceneModel.OP_SET, {"uid": uid, "props": changed, "res": ctx["res_out"]})

func _flush_resources(b: Binding) -> void:
	if b.dirty_res.is_empty():
		return
	var todo := b.dirty_res.keys()
	b.dirty_res.clear()
	var out := {}
	for ruid in todo:
		var r := b.resource_of(ruid)
		if r == null:
			continue
		var ctx := b.new_ctx()
		var changed := codec.diff_resource(r, ctx)
		if changed.is_empty():
			continue
		out[ruid] = {"c": r.get_class(), "v": changed}
		for k in ctx["res_out"]:
			if not out.has(k):
				out[k] = ctx["res_out"][k]
	if not out.is_empty():
		_submit(b, GLCSceneModel.OP_RES, {"res": out})

# ---------------------------------------------------------------- structure diff

func _depth_of(b: Binding, n: Node) -> int:
	var d := 0
	var cur := n
	while cur != null and cur != b.root:
		d += 1
		cur = cur.get_parent()
	return d

func _flush_structure(b: Binding) -> void:
	if b.dirty_parents.is_empty() and b.dirty_names.is_empty():
		return
	if b.root == null or not is_instance_valid(b.root):
		return
	var parent_uids: Array = b.dirty_parents.keys()
	var rename_uids: Array = b.dirty_names.keys()
	b.dirty_parents.clear()
	b.dirty_names.clear()
	# parents that are no longer part of the scene are covered by their own parent
	var work: Array = []
	for puid in parent_uids:
		var pn := b.node_of_uid(puid)
		if pn == null:
			continue
		if pn != b.root and not b.root.is_ancestor_of(pn):
			continue
		work.append([_depth_of(b, pn), puid, pn])
	work.sort_custom(func(x, y): return x[0] < y[0])
	var dels: Array = []
	var movs: Array = []
	var adds: Array = []
	var actual_by_parent: Dictionary = {}
	for w in work:
		var puid: String = w[1]
		var pnode: Node = w[2]
		var actual: Array = b.user_kids(pnode)
		var actual_uids: Array = []
		var model_kids: Array = b.model.kids_of(puid) if b.model.has_node(puid) else []
		# model children whose node object is no longer here, by name: the editor sometimes replaces a node
		# by a new object (e.g. reloading an instance after its scene was saved). Same name + class +
		# instance = same node: adopt it instead of deleting and re-adding it.
		var vanished := {}
		for mu in model_kids:
			var mn0 := b.node_of_uid(mu)
			if mn0 == null or mn0.get_parent() != pnode:
				vanished[b.model.node_name(mu)] = mu
		for i in actual.size():
			var c: Node = actual[i]
			var cu: String = b.uid_by_iid.get(c.get_instance_id(), "")
			if cu.is_empty() and vanished.has(String(c.name)):
				var vu: String = vanished[String(c.name)]
				var rec: Dictionary = b.model.nodes[vu]
				var old_n := b.node_of_uid(vu)
				if c.get_class() == String(rec["cls"]) and String(c.scene_file_path) == String(rec["inst"]) and (old_n == null or not b.root.is_ancestor_of(old_n)):
					b.register_node(vu, c)   # (the hash cache is kept: real differences are still sent)
					b.dirty_parents[vu] = true   # its own children are checked on the next pass
					vanished.erase(String(c.name))
					cu = vu
			actual_uids.append(cu)
			if cu.is_empty() or not b.model.has_node(cu):
				adds.append([c, puid, i])
			elif b.model.parent_of(cu) != puid:
				movs.append([cu, puid, i, String(c.name)])
		actual_by_parent[puid] = actual_uids
		for mu in model_kids:
			if not actual_uids.has(mu):
				var n := b.node_of_uid(mu)
				if n == null or not b.root.is_ancestor_of(n):
					dels.append(mu)
	# 0. nodes leaving a subtree that is about to be deleted move out FIRST, so they keep their identity
	#    everywhere (other nodes may reference them)
	var del_set := {}
	var early_names: Array = []
	for u in dels:
		del_set[u] = true
	if not del_set.is_empty():
		var early: Array = []
		for m in movs:
			var anc := b.model.parent_of(String(m[0]))
			var guard := 0
			while not anc.is_empty() and guard < 512:
				if del_set.has(anc):
					early.append(m)
					break
				anc = b.model.parent_of(anc)
				guard += 1
		for m in early:
			movs.erase(m)
			if b.model.has_node(m[0]) and b.model.has_node(m[1]) and not del_set.has(m[1]):
				_submit(b, GLCSceneModel.OP_MOV, {"uid": m[0], "parent": m[1], "index": m[2], "name": m[3]})
		# a NEW parent that adopted nodes from the doomed subtree is created (and they moved) first too
		var early_adds: Array = []
		for a in adds:
			var an: Node = a[0]
			if is_instance_valid(an) and _subtree_adopts_from(b, an, del_set):
				early_adds.append(a)
		for a in early_adds:
			adds.erase(a)
			var desired := String((a[0] as Node).name)
			var au := _submit_add(b, a)
			if not au.is_empty():
				# (e.g. "Change Type": the replacement has the doomed node's name, which is only free
				# after the deletion below; the name is given back right after it)
				early_names.append([au, desired])
	# 1. deletions (a name may be reused by an addition in the same pass)
	var deleted := {}
	for u in dels:
		if deleted.has(u) or not b.model.has_node(u):
			continue
		_submit(b, GLCSceneModel.OP_DEL, {"uid": u})
		deleted[u] = true
		_forget_subtree_registry(b, u)
	for en in early_names:
		if b.model.has_node(en[0]) and b.model.node_name(en[0]) != String(en[1]):
			_submit(b, GLCSceneModel.OP_REN, {"uid": en[0], "name": en[1]})
	# 2. reparenting. A node moved out of a parent that was deleted in the same pass is gone from the
	#    model by now: it is re-added (same uid) instead of being lost.
	for m in movs:
		if not b.model.has_node(m[1]):
			continue
		if b.model.has_node(m[0]):
			_submit(b, GLCSceneModel.OP_MOV, {"uid": m[0], "parent": m[1], "index": m[2], "name": m[3]})
		else:
			var mn := b.node_of_uid(m[0])
			if mn != null and b.root.is_ancestor_of(mn):
				adds.append([mn, m[1], m[2]])
	# 3. renames (collision safe)
	_emit_renames(b, rename_uids)
	# 4. additions (top-most new nodes only; their subtree travels inside the op). Existing nodes found
	#    inside a new subtree are moved under it right after.
	for a in adds:
		_submit_add(b, a)
	# 5. order fix-ups
	for puid in actual_by_parent:
		var actual_uids2: Array = actual_by_parent[puid]
		if not b.model.has_node(puid):
			continue
		# refresh uids of nodes that were just added
		var fixed: Array = []
		var pnode2 := b.node_of_uid(puid)
		if pnode2 == null:
			continue
		for c in b.user_kids(pnode2):
			fixed.append(b.uid_by_iid.get(c.get_instance_id(), ""))
		var mk: Array = (b.model.kids_of(puid) as Array).duplicate()
		var common_a: Array = fixed.filter(func(u): return u in mk)
		var common_m: Array = mk.filter(func(u): return u in fixed)
		if common_a == common_m:
			continue
		for i in common_a.size():
			var u2: String = common_a[i]
			var cur_idx: int = (b.model.kids_of(puid) as Array).find(u2)
			var want: int = fixed.find(u2)
			if cur_idx != want:
				_submit(b, GLCSceneModel.OP_MOV, {"uid": u2, "parent": puid, "index": want, "name": b.model.node_name(u2)})

## Adds a new node (with its new subtree) and then moves under it the existing nodes it adopted.
## Returns the uid of the added node ("" if nothing was submitted).
func _submit_add(b: Binding, a: Array) -> String:
	var node: Node = a[0]
	if not is_instance_valid(node):
		return ""
	var existing: String = b.uid_by_iid.get(node.get_instance_id(), "")
	if not existing.is_empty() and b.model.has_node(existing):
		return ""
	if not b.model.has_node(a[1]):
		return ""
	var ctx := b.new_ctx()
	var adopt: Array = []
	var entry := _capture_subtree(b, node, ctx, adopt)
	entry["parent"] = a[1]
	entry["index"] = a[2]
	entry["res"] = ctx["res_out"]
	if not _submit(b, GLCSceneModel.OP_ADD, entry):
		return ""
	for mv in adopt:
		if b.model.has_node(mv[0]) and b.model.has_node(mv[1]) and not b.model.is_ancestor_or_self(mv[0], mv[1]):
			_submit(b, GLCSceneModel.OP_MOV, {"uid": mv[0], "parent": mv[1], "index": mv[2], "name": mv[3]})
	return String(entry["uid"])

## True if the (new) subtree of `node` contains an existing model node that currently sits inside one
## of the subtrees about to be deleted.
func _subtree_adopts_from(b: Binding, node: Node, del_set: Dictionary) -> bool:
	for c in b.user_kids(node):
		var cu: String = b.uid_by_iid.get(c.get_instance_id(), "")
		if not cu.is_empty() and b.model.has_node(cu):
			var anc := b.model.parent_of(cu)
			var guard := 0
			while not anc.is_empty() and guard < 512:
				if del_set.has(anc):
					return true
				anc = b.model.parent_of(anc)
				guard += 1
		elif _subtree_adopts_from(b, c, del_set):
			return true
	return false

func _emit_renames(b: Binding, uids: Array) -> void:
	var todo: Array = []
	for u in uids:
		var n := b.node_of_uid(u)
		if n == null or not b.model.has_node(u):
			continue
		if String(n.name) != b.model.node_name(u):
			todo.append([u, String(n.name)])
	var guard := 0
	while not todo.is_empty() and guard < 64:
		guard += 1
		var progressed := false
		for i in range(todo.size() - 1, -1, -1):
			var u: String = todo[i][0]
			var want: String = todo[i][1]
			var par := b.model.parent_of(u)
			if par.is_empty() or b.model.unique_name(par, want, u) == want:
				_submit(b, GLCSceneModel.OP_REN, {"uid": u, "name": want})
				todo.remove_at(i)
				progressed = true
		if not progressed:
			# rename cycle (swap): move one aside first
			var u2: String = todo[0][0]
			_submit(b, GLCSceneModel.OP_REN, {"uid": u2, "name": "%s~%s" % [todo[0][1], u2.substr(0, 4)]})

func _forget_subtree_registry(b: Binding, uid: String) -> void:
	# keep the node objects (undo may bring them back) but drop their model-side caches
	b.hashes.erase(uid)

# ---------------------------------------------------------------- live drag hints (unreliable)

func _send_drag_hints(b: Binding) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_hint_ms < HINT_INTERVAL_MS:
		return
	_last_hint_ms = now
	for n in EditorInterface.get_selection().get_selected_nodes():
		var uid: String = b.uid_by_iid.get(n.get_instance_id(), "")
		if uid.is_empty() or not b.model.has_node(uid):
			continue
		var names: Array = _hint_props_for(n)
		if names.is_empty():
			continue
		var cache: Dictionary = _hint_cache.get(uid, {})
		_hint_cache[uid] = cache
		var changed := {}
		for pn in names:
			var v: Variant = n.get(pn)
			var h := hash(v)
			if cache.get(pn, null) != h:
				cache[pn] = h
				changed[pn] = v
		if not changed.is_empty():
			_drag_lock[uid] = now + 400
			session.bcast(GLCProtocol.S_TF, {"scene": b.path, "uid": uid, "props": changed})

func _hint_props_for(n: Node) -> Array:
	for cls in ["Control", "Node3D", "Node2D"]:
		if n.is_class(cls):
			return HINT_PROPS[cls]
	return []

func _on_s_tf(_sender: int, p: Dictionary, _meta: Dictionary) -> void:
	var path := String(p.get("scene", ""))
	var b: Binding = bindings.get(path, null)
	if b == null or b.state != "synced":
		return
	var uid := String(p.get("uid", ""))
	var now := Time.get_ticks_msec()
	if int(_drag_lock.get(uid, 0)) > now:
		return
	# a hint that arrives after the final (reliable) value was applied is stale
	if now - int(b.last_projected.get(uid, -100000)) < HINT_STALE_MS:
		return
	var node := b.node_of_uid(uid)
	if node == null:
		return
	var props: Variant = p.get("props", {})
	if not (props is Dictionary):
		return
	# while canonical state is still being applied (fresh snapshot...), the node is not ready for hints
	if not b.project_queue.is_empty() or not b.hashes.has(uid):
		return
	var allowed: Array = _hint_props_for(node)
	if b.is_current():
		# our own not-yet-sent edits of this node go out first (the hint refresh below would hide them);
		# the cache already holds the previous hint's values, so only real local edits are found
		_diff_and_send_props(b, uid)
	var cache := b.hash_cache(uid)
	var h: Dictionary = b.hinted.get(uid, {"t": now, "props": {}})
	b.applying += 1
	for pn in props:
		if not allowed.has(pn):
			continue
		var cur: Variant = node.get(pn)
		if typeof(cur) != typeof(props[pn]):
			continue
		if not GLCPropertyResourceSync.same_value(cur, props[pn]):
			node.set(pn, props[pn])
		h["props"][pn] = true
	# a hinted property may change stored ones as a side effect (Control.position -> offset_*,
	# Node3D.position -> transform): none of that is a local edit, so nothing must be echoed back
	codec.refresh_cache(node, cache)
	b.applying -= 1
	h["t"] = now
	b.hinted[uid] = h

## Values shown from drag hints are transient: once the hints stop, the node goes back to the canonical
## value of the model (the final value if the drag was committed, the original one if it was cancelled).
func _settle_hints(b: Binding) -> void:
	if b.hinted.is_empty():
		return
	var now := Time.get_ticks_msec()
	for uid in b.hinted.keys():
		var h: Dictionary = b.hinted[uid]
		if now - int(h["t"]) < HINT_SETTLE_MS:
			continue
		b.hinted.erase(uid)
		if b.model.has_node(uid):
			_enqueue_project(b, uid, {"*": true})   # every side effect goes back to the model too

# ====================================================================== model -> tree (projection)

func _enqueue_changes(b: Binding) -> void:
	var ch := b.model.take_changes()
	var removed: Dictionary = ch["removed"]
	if not removed.is_empty():
		_remove_nodes(b, removed)
	for ruid in ch["res"]:
		_apply_res_entry(b, ruid)
	var touched: Dictionary = ch["touched"]
	if touched.is_empty():
		return
	var tp: Dictionary = ch["props"]
	for uid in touched:
		_enqueue_project(b, uid, tp.get(uid, {}))

func _enqueue_project(b: Binding, uid: String, props_filter: Dictionary) -> void:
	if b.project_filter.has(uid):
		var cur: Dictionary = b.project_filter[uid]
		for k in props_filter:
			cur[k] = true
	else:
		b.project_filter[uid] = props_filter.duplicate()
		b.project_queue.append(uid)
		b.project_counter += 1
		b.project_seq[uid] = b.project_counter
		b.queue_dirty = true

func _pump_projection(b: Binding) -> void:
	if b.project_queue.is_empty():
		return
	GLCProtocol.trace("pump %d" % b.project_queue.size())
	var t0 := Time.get_ticks_usec()
	var processed := 0
	var guard_requeue := 0
	if b.queue_dirty and b.project_queue.size() > 1:
		# parents first; ties keep enqueue order (Array.sort_custom is not stable, so the order is part of the key)
		var depths := {}
		for u in b.project_queue:
			depths[u] = _model_depth(b, u)
		var seqs: Dictionary = b.project_seq
		b.project_queue.sort_custom(func(x, y):
			var dx: int = depths[x]
			var dy: int = depths[y]
			if dx != dy:
				return dx < dy
			return int(seqs.get(x, 0)) < int(seqs.get(y, 0)))
	b.queue_dirty = false
	while not b.project_queue.is_empty():
		if (Time.get_ticks_usec() - t0) / 1000.0 > PROJECT_BUDGET_MS and processed > 0:
			break
		var uid: String = b.project_queue.pop_front()
		var filt: Dictionary = b.project_filter.get(uid, {})
		b.project_filter.erase(uid)
		b.project_seq.erase(uid)
		if not _project_node(b, uid, filt):
			# parent not there yet: try again later (bounded)
			guard_requeue += 1
			if guard_requeue < 4:
				_enqueue_project(b, uid, filt)
		processed += 1
	stats["projected"] += processed
	if processed > 0:
		_inspector_refresh_pending = true

func _model_depth(b: Binding, uid: String) -> int:
	var d := 0
	var cur := uid
	while not cur.is_empty() and d < 512:
		cur = b.model.parent_of(cur)
		d += 1
	return d

func _remove_nodes(b: Binding, removed: Dictionary) -> void:
	for uid in removed:
		var n := b.node_of_uid(uid)
		b.forget_node(uid)
		if n == null:
			continue
		var par := n.get_parent()
		if par == null:
			continue
		b.applying += 1
		var sel := EditorInterface.get_selection()
		sel.remove_node(n)
		par.remove_child(n)
		b.applying -= 1
		_graveyard.append({"node": n, "t": Time.get_ticks_msec()})

func _free_graveyard() -> void:
	if _graveyard.is_empty():
		return
	var now := Time.get_ticks_msec()
	while not _graveyard.is_empty() and now - int(_graveyard[0]["t"]) > GRAVE_SECONDS * 1000.0:
		var e: Dictionary = _graveyard.pop_front()
		var n: Variant = e["node"]
		if n != null and is_instance_valid(n) and (n as Node).get_parent() == null:
			(n as Node).queue_free()

## Returns false if the node could not be placed yet (its parent does not exist in the tree).
func _project_node(b: Binding, uid: String, filt: Dictionary) -> bool:
	var rec: Variant = b.model.nodes.get(uid, null)
	if rec == null or b.root == null or not is_instance_valid(b.root):
		return true
	var node := b.node_of_uid(uid)
	var created := false
	if node == null:
		node = _create_node(b, uid, rec)
		created = true
	var puid: String = rec["parent"]
	b.applying += 1
	if puid.is_empty():
		if String(b.root.name) != String(rec["name"]):
			b.root.name = String(rec["name"])
	else:
		var pnode := b.node_of_uid(puid)
		if pnode == null:
			b.applying -= 1
			if created:
				b.forget_node(uid)
				node.queue_free()
			return false
		_place(b, node, pnode, String(rec["name"]), uid)
	b.applying -= 1
	# properties
	var props: Dictionary = rec["props"]
	var apply_all := created or filt.has("*")
	var to_apply := {}
	var to_default: Array = []
	if apply_all:
		to_apply = props
	else:
		for k in filt:
			if props.has(k):
				to_apply[k] = props[k]
			else:
				to_default.append(k)   # absent from the model = default value
	b.last_projected[uid] = Time.get_ticks_msec()
	if apply_all:
		b.hinted.erase(uid)   # (a partial projection keeps the pending restoration of hinted values)
	if apply_all or not to_apply.is_empty() or not to_default.is_empty():
		var ctx := b.new_ctx()
		b.applying += 1
		codec.apply_node_props(node, to_apply, ctx, b.hash_cache(uid), apply_all)
		if not to_default.is_empty():
			codec.reset_to_default(node, to_default, b.hash_cache(uid), ctx)
		if apply_all:
			# properties omitted by the sender are defaults: make the cache reflect the node as it is now
			codec.refresh_cache(node, b.hash_cache(uid), ctx)
		b.applying -= 1
		if not (ctx["missing"] as Array).is_empty():
			b.retry[uid] = int(b.retry.get(uid, 0))
		elif apply_all and not b.fallback_inst.has(uid):
			# everything this node needs is here now: stop re-projecting it
			# (a placeholder standing in for a missing instanced scene keeps waiting for the real one)
			b.retry.erase(uid)
			b.stalled.erase(uid)
	return true

func _create_node(b: Binding, uid: String, rec: Dictionary) -> Node:
	var node: Node = null
	var inst: String = rec["inst"]
	if not inst.is_empty() and not GLCPropertyResourceSync.is_allowed_resource_path(inst):
		inst = ""
	if not inst.is_empty():
		if ResourceLoader.exists(inst):
			var ps: Variant = load(inst)
			if ps is PackedScene:
				node = (ps as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		if node == null:
			b.fallback_inst[uid] = inst
			b.retry[uid] = 0
	if node == null:
		var cls: String = rec["cls"]
		if ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls) and ClassDB.is_parent_class(cls, "Node"):
			node = ClassDB.instantiate(cls)
		else:
			node = Node.new()
			if not _warned_classes.has(cls):
				_warned_classes[cls] = true
				activity.emit("Classe '%s' indisponível neste editor; usando Node para '%s'" % [cls, rec["name"]])
	node.name = String(rec["name"])
	b.register_node(uid, node)
	return node

func _place(b: Binding, node: Node, parent: Node, name: String, uid: String) -> void:
	var cur_parent := node.get_parent()
	if cur_parent != parent:
		if cur_parent != null:
			cur_parent.remove_child(node)
		_free_name(b, parent, name, node)
		node.name = name
		parent.add_child(node)
		node.owner = b.root
		_set_owner_recursive(node, b.root)
	elif String(node.name) != name:
		_free_name(b, parent, name, node)
		node.name = name
	_apply_index(b, parent, node, uid)

func _set_owner_recursive(n: Node, owner: Node) -> void:
	for c in n.get_children():
		if c.owner == null or c.owner == owner:
			c.owner = owner
			_set_owner_recursive(c, owner)

## Make sure no *other* child of `parent` holds `name` (rename the holder aside; it gets its final name when projected).
func _free_name(b: Binding, parent: Node, name: String, mine: Node) -> void:
	for c in parent.get_children():
		if c != mine and String(c.name) == name:
			var tmp := "%s~glc%d" % [name, c.get_instance_id() % 10000]
			c.name = tmp
			var cu: String = b.uid_by_iid.get(c.get_instance_id(), "")
			if not cu.is_empty():
				_enqueue_project(b, cu, {})

## Position `node` right after the closest preceding sibling (in model order) that already exists in the tree,
## or in front of every other user node if there is none. This is correct whatever order siblings get created in.
func _apply_index(b: Binding, parent: Node, node: Node, uid: String) -> void:
	var kids: Array = b.model.kids_of(b.model.parent_of(uid))
	var pos := kids.find(uid)
	var pred: Node = null
	for i in range(pos - 1, -1, -1):
		var n := b.node_of_uid(kids[i])
		if n != null and n != node and n.get_parent() == parent:
			pred = n
			break
	var my_idx := node.get_index()
	var target := my_idx
	if pred != null:
		var pi := pred.get_index()
		target = pi if my_idx < pi else pi + 1
	else:
		var first: Node = null
		for c in b.user_kids(parent):
			if c != node:
				first = c
				break
		if first == null or my_idx < first.get_index():
			return
		target = first.get_index()
	target = clampi(target, 0, parent.get_child_count() - 1)
	if target != my_idx:
		parent.move_child(node, target)

func _apply_res_entry(b: Binding, ruid: String) -> void:
	var r := b.resource_of(ruid)
	var entry: Variant = b.model.res.get(ruid, null)
	if r == null or not (entry is Dictionary):
		return
	var ctx := b.new_ctx()
	b.applying += 1
	codec.apply_resource_entry(r, entry, ctx)
	b.applying -= 1
	_inspector_refresh_pending = true

# ====================================================================== reconcile (adopt existing nodes)

## Make the live tree match `b.model` while keeping every node that already exists under the same name.
func _adopt_and_project(b: Binding) -> void:
	b.uid_by_iid.clear()
	b.node_by_uid.clear()
	b.hashes.clear()
	b.project_queue.clear()
	b.project_filter.clear()
	b.model.take_changes()
	var claimed := {}
	var root_uid := b.model.root_uid
	if root_uid.is_empty():
		return
	b.register_node(root_uid, b.root)
	claimed[b.root.get_instance_id()] = true
	_adopt_rec(b, root_uid, b.root, claimed)
	# user nodes nobody claimed do not exist in the shared scene: remove them
	var strays: Array = []
	_collect_strays(b, b.root, claimed, strays)
	if not strays.is_empty():
		activity.emit("%d nó(s) locais fora da cena compartilhada foram removidos em %s" % [strays.size(), b.path.get_file()])
	for n in strays:
		var par: Node = n.get_parent()
		if par != null:
			b.applying += 1
			EditorInterface.get_selection().remove_node(n)
			par.remove_child(n)
			b.applying -= 1
			_graveyard.append({"node": n, "t": Time.get_ticks_msec()})
	# root properties + everything below, parents first
	for uid in b.model.nodes:
		_enqueue_project(b, uid, {"*": true})
	_refresh_sweep(b)

func _adopt_rec(b: Binding, uid: String, node: Node, claimed: Dictionary) -> void:
	for kuid in b.model.kids_of(uid):
		var rec: Dictionary = b.model.nodes[kuid]
		var child: Node = null
		for c in b.user_kids(node):
			if String(c.name) == String(rec["name"]) and not claimed.has(c.get_instance_id()):
				var same_inst := String(c.scene_file_path) == String(rec["inst"])
				if c.get_class() == String(rec["cls"]) and same_inst:
					child = c
					break
		if child != null:
			claimed[child.get_instance_id()] = true
			b.register_node(kuid, child)
			_adopt_rec(b, kuid, child, claimed)

func _collect_strays(b: Binding, node: Node, claimed: Dictionary, out: Array) -> void:
	for c in b.user_kids(node):
		if claimed.has(c.get_instance_id()):
			_collect_strays(b, c, claimed, out)
		else:
			out.append(c)

# ====================================================================== retries (files that have not arrived yet)

func _retry_unresolved(b: Binding) -> void:
	if b.state != "synced" or b.retry.is_empty():
		return
	for uid in b.retry.keys():
		var attempts: int = b.retry[uid]
		if not b.model.has_node(uid):
			b.retry.erase(uid)
			continue
		if attempts >= MAX_RETRIES:
			# stop polling, but wake up again when a file arrives (see on_file_arrived)
			b.retry.erase(uid)
			b.stalled[uid] = true
			continue
		b.retry[uid] = attempts + 1
		var inst: String = b.fallback_inst.get(uid, "")
		if not inst.is_empty() and ResourceLoader.exists(inst):
			_flush_local(b)   # (the replacement reprojects nodes that reference it)
			if not b.model.has_node(uid):
				continue
			_replace_fallback(b, uid, inst)
			b.fallback_inst.erase(uid)
		_enqueue_project(b, uid, {"*": true})

func _replace_fallback(b: Binding, uid: String, inst: String) -> void:
	var old := b.node_of_uid(uid)
	var rec: Variant = b.model.nodes.get(uid, null)
	if old == null or rec == null:
		return
	var par := old.get_parent()
	if par == null:
		return
	var ps: Variant = load(inst)
	if not (ps is PackedScene):
		return
	var node: Node = (ps as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if node == null:
		return
	b.applying += 1
	var idx := old.get_index()
	var name := String(old.name)
	# persistent connections to/from the old object are dropped now (they are re-created on the new one
	# by the projections below), so no callback runs twice while the old object waits to be freed
	for c in old.get_incoming_connections():
		if int(c["flags"]) & CONNECT_PERSIST:
			var sig: Signal = c["signal"]
			if sig.is_connected(c["callable"]):
				sig.disconnect(c["callable"])
	for s in old.get_signal_list():
		for c2 in old.get_signal_connection_list(s["name"]):
			if int(c2["flags"]) & CONNECT_PERSIST:
				old.disconnect(s["name"], c2["callable"])
	# nodes of the shared scene that live under the old one move to the new instance
	var kids := b.user_kids(old)
	for k in kids:
		old.remove_child(k)
	par.remove_child(old)
	node.name = name
	par.add_child(node)
	par.move_child(node, idx)
	node.owner = b.root
	for k in kids:
		node.add_child(k)
		k.owner = b.root
		_set_owner_recursive(k, b.root)
	b.register_node(uid, node)
	b.applying -= 1
	EditorInterface.get_selection().remove_node(old)
	_graveyard.append({"node": old, "t": Time.get_ticks_msec()})
	_enqueue_project(b, uid, {"*": true})
	_reproject_referrers(b, [uid])

## A scene file changed on disk without this editor saving it (it arrived from someone else, or an
## external tool wrote it). The editor does not refresh instances of it in the scenes open here, so we
## do: every instance is rebuilt from the new file, keeping its uid, overrides and the shared-scene
## nodes placed under it.
func on_scene_file_changed(path: String) -> void:
	if not GLCProtocol.is_scene_ext(path) or bindings.has(path):
		return   # a scene open here is synchronized live, not through its file
	if not ResourceLoader.exists(path):
		return
	ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	codec.invalidate_instance_bases()
	var depends_cache := {}
	var reloaded := 0
	for b in bindings.values():
		if b.state != "synced" or b.model == null:
			continue
		_flush_local(b)   # our pending edits go out before nodes are rebuilt / reprojected
		for uid in b.model.nodes.keys():
			if not b.model.has_node(uid):
				continue
			var inst := String(b.model.nodes[uid]["inst"])
			if inst.is_empty() or b.fallback_inst.has(uid):
				continue
			if inst != path and not _scene_depends_on(inst, path, depends_cache, 0):
				continue
			if b.node_of_uid(uid) != null:
				_replace_fallback(b, uid, inst)   # (also reprojects the nodes that reference it)
				reloaded += 1
	if reloaded > 0:
		_inspector_refresh_pending = true
		activity.emit("%s atualizada em %d instância(s)" % [path.get_file(), reloaded])

## True if scene `scene` instances `target`, directly or through other scenes (each level is refreshed
## in the resource cache so that instantiating `scene` uses the new `target`).
func _scene_depends_on(scene: String, target: String, memo: Dictionary, depth: int) -> bool:
	if memo.has(scene):
		return memo[scene]
	memo[scene] = false   # cycle guard
	if depth > 16 or not ResourceLoader.exists(scene):
		return false
	var hit := false
	for dep in ResourceLoader.get_dependencies(scene):
		var parts := String(dep).split("::")
		var dpath := String(parts[parts.size() - 1]) if parts.size() > 0 else String(dep)
		if dpath.begins_with("uid://"):
			dpath = ResourceUID.get_id_path(ResourceUID.text_to_id(dpath)) if ResourceUID.has_id(ResourceUID.text_to_id(dpath)) else dpath
		if dpath == target or String(dep).contains(target):
			hit = true
		elif GLCProtocol.is_scene_ext(dpath) and _scene_depends_on(dpath, target, memo, depth + 1):
			hit = true
		if hit:
			break
	if hit:
		ResourceLoader.load(scene, "", ResourceLoader.CACHE_MODE_REPLACE)
	memo[scene] = hit
	return hit

## Other nodes may hold the replaced node objects (exported Node properties, signal connections towards
## them): apply their records again so they point at the new objects.
func _reproject_referrers(b: Binding, uids: Array) -> void:
	for ruid in b.model.nodes:
		var rec: Dictionary = b.model.nodes[ruid]
		var txt := var_to_str(rec["props"])
		for u in uids:
			if txt.contains(String(u)):
				_enqueue_project(b, ruid, {"*": true})
				break

## Called by the file layer when a file finished arriving.
func on_file_arrived(path: String) -> void:
	var ext := GLCProtocol.ext_of(path)
	if ext in ["gd", "cs"]:
		codec.invalidate_lists()   # exported variables may have changed
		# a script already loaded here (used by nodes, not open in a tab - the file layer never writes
		# open files) keeps its old code until reloaded: do it now, like the editor does for external edits
		if ext == "gd" and ResourceLoader.has_cached(path):
			var cached: Variant = ResourceLoader.get_cached_ref(path)
			if cached is GDScript:
				var src := FileAccess.get_file_as_string(path)
				if (cached as GDScript).source_code != src:
					(cached as GDScript).source_code = src
					(cached as GDScript).reload(true)
	if GLCProtocol.is_scene_ext(path):
		on_scene_file_changed(path)
	# nodes waiting for a file (a script just attached by someone, a new texture...) are applied again
	# right now, not on the next retry tick
	for b in bindings.values():
		for uid in b.stalled.keys():
			b.retry[uid] = 0
		b.stalled.clear()
		# placeholders whose instanced scene just arrived become the real instance now
		for uid in b.fallback_inst.keys():
			var inst: String = b.fallback_inst[uid]
			if (inst == path or GLCProtocol.is_scene_ext(path)) and ResourceLoader.exists(inst) and b.model != null and b.model.has_node(uid):
				_flush_local(b)
				if b.model.has_node(uid):
					_replace_fallback(b, uid, inst)
					b.fallback_inst.erase(uid)
		for uid in b.retry.keys():
			b.retry[uid] = 0
			if b.model != null and b.model.has_node(uid):
				_enqueue_project(b, uid, {"*": true})

# ====================================================================== introspection (tests / dock)

func scene_state(path: String) -> String:
	var b: Binding = bindings.get(path, null)
	return b.state if b != null else "none"

func pending_ops(path: String) -> int:
	var b: Binding = bindings.get(path, null)
	if b == null or b.replica == null:
		return 0
	return b.replica.pending_count()

func queue_size(path: String) -> int:
	var b: Binding = bindings.get(path, null)
	return b.project_queue.size() if b != null else 0

## Structural fingerprint of the *live tree* (for verification against the model).
func tree_signature(b: Binding) -> String:
	var parts := PackedStringArray()
	_sig_rec(b, b.root, "", parts)
	return "\n".join(parts)

func _sig_rec(b: Binding, n: Node, path: String, out: PackedStringArray) -> void:
	out.append("%s|%s|%s" % [path if path != "" else ".", n.get_class(), n.scene_file_path if n != b.root else ""])
	for c in b.user_kids(n):
		_sig_rec(b, c, (path + "/" if path != "" else "") + String(c.name), out)
