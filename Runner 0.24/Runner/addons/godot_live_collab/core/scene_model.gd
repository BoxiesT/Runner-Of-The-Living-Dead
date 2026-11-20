@tool
class_name GLCSceneModel
extends RefCounted
## Pure-data model of one scene (no engine nodes). The host owns the authoritative copy and turns
## every client operation into a *canonical* one (unique sibling names, final child index).
## Every peer keeps a replica (see `Replica`) so the editor tree can be rebuilt/verified at any time.
##
## Node record:  { parent: String, name: String, cls: String, inst: String, kids: Array[String], props: Dictionary }
## Resource rec: { cls: String, ext: String (path, "" if embedded), props: Dictionary }
## Property values are already *encoded* (see GLCProtocol.encode_value); resources inside them are
## referenced as { "__glc": "rref", "u": <resource uid> }.

const OP_ADD := "s.add"
const OP_DEL := "s.del"
const OP_REN := "s.ren"
const OP_MOV := "s.mov"
const OP_SET := "s.set"
const OP_RES := "s.res"

var scene_path: String = ""
var root_uid: String = ""
var nodes: Dictionary = {}
var res: Dictionary = {}
var name_sep: String = ""
var version: int = 0
var last_error: String = ""

## Filled while operations are applied; consumers (the tree binder) drain it with `take_changes()`.
var touched: Dictionary = {}        # uid -> true  (record changed: structure and/or props)
var touched_props: Dictionary = {}  # uid -> {prop: true} or {"*": true} (everything)
var touched_res: Dictionary = {}    # ruid -> true
var removed: Dictionary = {}        # uid -> true  (record deleted)
## When true every applied operation also records how to undo it (`last_undo`). Only replicas need it.
var record_undo: bool = false
var last_undo: Dictionary = {}
## Number of times a canonical name collided with an existing sibling (should stay 0; see tests).
var room_made_count: int = 0


func take_changes() -> Dictionary:
	# rollback/replay may remove and re-add the same uid: only the *final* state matters
	var t := {}
	for uid in touched:
		if nodes.has(uid):
			t[uid] = true
	var r := {}
	for uid in removed:
		if not nodes.has(uid):
			r[uid] = true
	var tp := {}
	for uid in touched_props:
		if nodes.has(uid):
			tp[uid] = touched_props[uid]
	var tr := touched_res
	touched = {}
	touched_props = {}
	touched_res = {}
	removed = {}
	return {"touched": t, "removed": r, "props": tp, "res": tr}

func clear() -> void:
	nodes = {}
	res = {}
	root_uid = ""
	touched = {}
	touched_props = {}
	touched_res = {}
	removed = {}

func _touch_props(uid: String, names: Variant) -> void:
	var cur: Dictionary = touched_props.get(uid, {})
	if names is Dictionary:
		for k in names:
			cur[k] = true
	else:
		cur["*"] = true
	touched_props[uid] = cur

# ------------------------------------------------------------------ queries

func has_node(uid: String) -> bool:
	return nodes.has(uid)

func node_name(uid: String) -> String:
	return String(nodes[uid]["name"]) if nodes.has(uid) else ""

func parent_of(uid: String) -> String:
	return String(nodes[uid]["parent"]) if nodes.has(uid) else ""

func kids_of(uid: String) -> Array:
	return nodes[uid]["kids"] if nodes.has(uid) else []

func index_of(uid: String) -> int:
	var p := parent_of(uid)
	if p.is_empty() or not nodes.has(p):
		return 0
	return (nodes[p]["kids"] as Array).find(uid)

func size() -> int:
	return nodes.size()

## True if `a` is `b` or an ancestor of `b`.
func is_ancestor_or_self(a: String, b: String) -> bool:
	var cur := b
	var guard := 0
	while not cur.is_empty() and guard < 100000:
		if cur == a:
			return true
		cur = parent_of(cur)
		guard += 1
	return false

func path_of(uid: String) -> String:
	if not nodes.has(uid):
		return ""
	if uid == root_uid:
		return "."
	var parts: Array = []
	var cur := uid
	var guard := 0
	while not cur.is_empty() and cur != root_uid and guard < 10000:
		parts.push_front(node_name(cur))
		cur = parent_of(cur)
		guard += 1
	return "/".join(PackedStringArray(parts))

func find_by_path(path: String) -> String:
	if root_uid.is_empty():
		return ""
	if path == "." or path.is_empty():
		return root_uid
	var cur := root_uid
	for part in path.split("/", false):
		var next := ""
		for k in kids_of(cur):
			if node_name(k) == part:
				next = k
				break
		if next.is_empty():
			return ""
		cur = next
	return cur

func unique_name(parent_uid: String, desired: String, exclude_uid: String = "") -> String:
	if not nodes.has(parent_uid):
		return desired
	var taken := {}
	for k in nodes[parent_uid]["kids"]:
		if k != exclude_uid:
			taken[node_name(k)] = true
	if not taken.has(desired):
		return desired
	var i := desired.length() - 1
	while i >= 0 and desired.unicode_at(i) >= 48 and desired.unicode_at(i) <= 57:
		i -= 1
	var base := desired.substr(0, i + 1)
	var digits := desired.substr(i + 1)
	var n := (digits.to_int() + 1) if not digits.is_empty() else 2
	while true:
		var cand := base + name_sep + str(n)
		if not taken.has(cand):
			return cand
		n += 1
	return desired

# ------------------------------------------------------------------ applying operations

## Applies one operation.
## canonical == false : the operation is *proposed* (host, or optimistic local apply). Names are made
##                      unique, indexes clamped, invalid operations rejected (-> null).
## canonical == true  : the operation already went through the host. Values are trusted; name collisions
##                      with locally-pending nodes are resolved by giving *them* a temporary name.
## Returns the canonical payload, or null if the operation was rejected / is a no-op (see last_error).
func apply(t: String, p: Dictionary, canonical: bool) -> Variant:
	last_error = ""
	last_undo = {}
	match t:
		OP_ADD:
			return _op_add(p, canonical)
		OP_DEL:
			return _op_del(p)
		OP_REN:
			return _op_ren(p, canonical)
		OP_MOV:
			return _op_mov(p, canonical)
		OP_SET:
			return _op_set(p)
		OP_RES:
			return _op_res(p)
	last_error = "unknown"
	return null

func _merge_res(p: Dictionary) -> void:
	var r: Variant = p.get("res", null)
	if r is Dictionary:
		for k in r:
			var e: Variant = r[k]
			if not (e is Dictionary) or (e as Dictionary).is_empty():
				continue
			if res.has(k) and res[k] is Dictionary and (e as Dictionary).has("v"):
				var cur: Dictionary = res[k]
				if not cur.has("v"):
					cur["v"] = {}
				for pk in e["v"]:
					cur["v"][pk] = e["v"][pk]
				if e.has("c"):
					cur["c"] = e["c"]
			else:
				res[k] = (e as Dictionary).duplicate(true)
			touched_res[k] = true

func _make_room(parent_uid: String, wanted: String, for_uid: String) -> void:
	# canonical name `wanted` must be free in `parent_uid`; whoever holds it temporarily moves aside
	if not nodes.has(parent_uid):
		return
	for k in nodes[parent_uid]["kids"]:
		if k != for_uid and node_name(k) == wanted:
			room_made_count += 1
			nodes[k]["name"] = unique_name(parent_uid, wanted + "_glc", k)
			touched[k] = true

func _op_add(p: Dictionary, canonical: bool) -> Variant:
	var uid := String(p.get("uid", ""))
	if uid.is_empty():
		last_error = "invalid"
		return null
	var parent := String(p.get("parent", ""))
	if nodes.has(uid):
		if not canonical:
			last_error = "duplicate"
			return null
		_merge_res(p)
		var props: Variant = p.get("props", null)
		if props is Dictionary:
			for k in props:
				nodes[uid]["props"][k] = props[k]
			_touch_props(uid, props)
		_enforce(uid, parent, int(p.get("index", -1)), String(p.get("name", node_name(uid))))
		touched[uid] = true
		return p
	if parent.is_empty():
		if not nodes.is_empty():
			last_error = "invalid"
			return null
		root_uid = uid
	elif not nodes.has(parent):
		last_error = "missing"
		return null
	_merge_res(p)
	var name := String(p.get("name", "Node"))
	if not parent.is_empty():
		if canonical:
			_make_room(parent, name, uid)
		else:
			name = unique_name(parent, name)
	var idx := _insert_record(uid, parent, name, p, int(p.get("index", 1 << 30)))
	for kid in p.get("kids", []):
		if kid is Dictionary:
			_add_nested(kid, uid, canonical)
	version += 1
	if record_undo:
		last_undo = {"k": "del", "uid": uid}
	var out := p.duplicate()
	out["name"] = name
	out["index"] = idx
	return out

func _insert_record(uid: String, parent: String, name: String, entry: Dictionary, index: int) -> int:
	var rec := {
		"parent": parent,
		"name": name,
		"cls": String(entry.get("cls", "Node")),
		"inst": String(entry.get("inst", "")),
		"kids": [],
		"props": {},
	}
	var props: Variant = entry.get("props", null)
	if props is Dictionary:
		rec["props"] = props.duplicate()
	nodes[uid] = rec
	touched[uid] = true
	touched_props[uid] = {"*": true}
	var idx := 0
	if not parent.is_empty():
		var lst: Array = nodes[parent]["kids"]
		idx = clampi(index, 0, lst.size())
		lst.insert(idx, uid)
	return idx

func _add_nested(entry: Dictionary, parent: String, canonical: bool) -> void:
	var uid := String(entry.get("uid", ""))
	if uid.is_empty() or nodes.has(uid):
		return
	var name := String(entry.get("name", "Node"))
	if not canonical:
		name = unique_name(parent, name)
	_insert_record(uid, parent, name, entry, 1 << 30)
	for kid in entry.get("kids", []):
		if kid is Dictionary:
			_add_nested(kid, uid, canonical)

func _op_del(p: Dictionary) -> Variant:
	var uid := String(p.get("uid", ""))
	if not nodes.has(uid):
		last_error = "missing"
		return null
	if uid == root_uid:
		last_error = "invalid"
		return null
	var parent := parent_of(uid)
	if record_undo:
		last_undo = {"k": "restore", "parent": parent, "index": index_of(uid), "entry": export_entry(uid)}
	if nodes.has(parent):
		(nodes[parent]["kids"] as Array).erase(uid)
		touched[parent] = true
	_remove_subtree(uid)
	version += 1
	return p

func _remove_subtree(uid: String) -> void:
	if not nodes.has(uid):
		return
	for k in (nodes[uid]["kids"] as Array).duplicate():
		_remove_subtree(k)
	nodes.erase(uid)
	removed[uid] = true
	touched.erase(uid)

func _op_ren(p: Dictionary, canonical: bool) -> Variant:
	var uid := String(p.get("uid", ""))
	if not nodes.has(uid):
		last_error = "missing"
		return null
	var parent := parent_of(uid)
	var name := String(p.get("name", ""))
	if name.is_empty():
		last_error = "invalid"
		return null
	if not parent.is_empty():
		if canonical:
			_make_room(parent, name, uid)
		else:
			name = unique_name(parent, name, uid)
	if record_undo:
		last_undo = {"k": "name", "uid": uid, "name": node_name(uid)}
	nodes[uid]["name"] = name
	touched[uid] = true
	version += 1
	var out := p.duplicate()
	out["name"] = name
	return out

func _op_mov(p: Dictionary, canonical: bool) -> Variant:
	var uid := String(p.get("uid", ""))
	var new_parent := String(p.get("parent", ""))
	if not nodes.has(uid):
		last_error = "missing"
		return null
	if uid == root_uid or not nodes.has(new_parent):
		last_error = "missing" if not nodes.has(new_parent) else "invalid"
		return null
	if is_ancestor_or_self(uid, new_parent):
		last_error = "cycle"
		return null
	var name := String(p.get("name", node_name(uid)))
	if record_undo:
		last_undo = {"k": "place", "uid": uid, "parent": parent_of(uid), "index": index_of(uid), "name": node_name(uid)}
	_detach(uid)
	if canonical:
		_make_room(new_parent, name, uid)
	else:
		name = unique_name(new_parent, name, uid)
	nodes[uid]["name"] = name
	nodes[uid]["parent"] = new_parent
	var lst: Array = nodes[new_parent]["kids"]
	var idx := clampi(int(p.get("index", 1 << 30)), 0, lst.size())
	lst.insert(idx, uid)
	touched[uid] = true
	touched[new_parent] = true
	version += 1
	var out := p.duplicate()   # keeps routing fields such as "scene"
	out["uid"] = uid
	out["parent"] = new_parent
	out["index"] = idx
	out["name"] = name
	return out

func _detach(uid: String) -> void:
	var old := parent_of(uid)
	if nodes.has(old):
		(nodes[old]["kids"] as Array).erase(uid)
		touched[old] = true

func _op_set(p: Dictionary) -> Variant:
	var uid := String(p.get("uid", ""))
	if not nodes.has(uid):
		last_error = "missing"
		return null
	_merge_res(p)
	var props: Variant = p.get("props", null)
	if record_undo:
		var old := {}
		var absent: Array = []
		if props is Dictionary:
			for k in props:
				if nodes[uid]["props"].has(k):
					old[k] = nodes[uid]["props"][k]
				else:
					absent.append(k)
		last_undo = {"k": "props", "uid": uid, "old": old, "absent": absent}
	if props is Dictionary:
		for k in props:
			nodes[uid]["props"][k] = props[k]
		_touch_props(uid, props)
	touched[uid] = true
	version += 1
	return p

func _op_res(p: Dictionary) -> Variant:
	_merge_res(p)
	version += 1
	return p

## Make an existing node match the canonical placement (used for acks of our own operations).
func _enforce(uid: String, parent: String, index: int, name: String) -> void:
	if not nodes.has(uid) or uid == root_uid:
		if nodes.has(uid) and uid == root_uid and not name.is_empty():
			nodes[uid]["name"] = name
			touched[uid] = true
		return
	if parent.is_empty() or not nodes.has(parent):
		return
	if is_ancestor_or_self(uid, parent):
		last_error = "cycle"
		return
	_detach(uid)
	_make_room(parent, name, uid)
	nodes[uid]["name"] = name
	nodes[uid]["parent"] = parent
	var lst: Array = nodes[parent]["kids"]
	lst.insert(clampi(index, 0, lst.size()), uid)
	touched[uid] = true
	touched[parent] = true

func enforce_canonical(uid: String, payload: Dictionary) -> void:
	if payload.has("parent"):
		_enforce(uid, String(payload.get("parent", "")), int(payload.get("index", 1 << 30)), String(payload.get("name", node_name(uid))))
	elif payload.has("name") and nodes.has(uid):
		var parent := parent_of(uid)
		if not parent.is_empty():
			_make_room(parent, String(payload["name"]), uid)
		nodes[uid]["name"] = String(payload["name"])
		touched[uid] = true

## Inverse of an operation recorded in `last_undo`. Only valid in strict stack order.
func rollback(u: Dictionary) -> void:
	match String(u.get("k", "")):
		"del":
			var uid := String(u["uid"])
			if nodes.has(uid):
				var parent := parent_of(uid)
				if nodes.has(parent):
					(nodes[parent]["kids"] as Array).erase(uid)
					touched[parent] = true
				_remove_subtree(uid)
		"restore":
			var parent2 := String(u["parent"])
			var entry: Dictionary = u["entry"]
			if nodes.has(parent2) and not nodes.has(String(entry["uid"])):
				_insert_record(String(entry["uid"]), parent2, String(entry["name"]), entry, int(u["index"]))
				for kid in entry.get("kids", []):
					_add_nested(kid, String(entry["uid"]), true)
		"name":
			var uid2 := String(u["uid"])
			if nodes.has(uid2):
				nodes[uid2]["name"] = String(u["name"])
				touched[uid2] = true
		"place":
			var uid3 := String(u["uid"])
			var np := String(u["parent"])
			if nodes.has(uid3) and nodes.has(np):
				_detach(uid3)
				nodes[uid3]["name"] = String(u["name"])
				nodes[uid3]["parent"] = np
				var lst: Array = nodes[np]["kids"]
				lst.insert(clampi(int(u["index"]), 0, lst.size()), uid3)
				touched[uid3] = true
				touched[np] = true
		"props":
			var uid4 := String(u["uid"])
			if nodes.has(uid4):
				for k in u["old"]:
					nodes[uid4]["props"][k] = u["old"][k]
				for k in u["absent"]:
					nodes[uid4]["props"].erase(k)
				_touch_props(uid4, u["old"])
				_touch_props(uid4, _keys_to_dict(u["absent"]))
				touched[uid4] = true

static func _keys_to_dict(keys: Array) -> Dictionary:
	var d := {}
	for k in keys:
		d[k] = true
	return d

# ------------------------------------------------------------------ snapshots

func snapshot() -> Dictionary:
	var used := {}
	for uid in nodes:
		_collect_res_refs(nodes[uid]["props"], used)
	# nested references inside resources
	var queue := used.keys()
	while not queue.is_empty():
		var r: String = queue.pop_back()
		if res.has(r):
			var nested := {}
			_collect_res_refs(res[r].get("v", {}), nested)
			for k in nested:
				if not used.has(k):
					used[k] = true
					queue.append(k)
	var rs := {}
	for k in used:
		if res.has(k):
			rs[k] = res[k]
	return {"scene": scene_path, "root": root_uid, "nodes": nodes.duplicate(true), "res": rs, "version": version}

static func _collect_res_refs(v: Variant, out: Dictionary) -> void:
	if v is Dictionary:
		if v.get("__glc", "") == "rref":
			out[String(v.get("u", ""))] = true
			return
		for k in v:
			_collect_res_refs(v[k], out)
	elif v is Array:
		for e in v:
			_collect_res_refs(e, out)

func load_snapshot(s: Dictionary) -> void:
	nodes = (s.get("nodes", {}) as Dictionary).duplicate(true)
	res = (s.get("res", {}) as Dictionary).duplicate(true)
	root_uid = String(s.get("root", ""))
	version = int(s.get("version", 0))
	touched = {}
	touched_props = {}
	touched_res = {}
	removed = {}
	for uid in nodes:
		touched[uid] = true
		touched_props[uid] = {"*": true}
	for k in res:
		touched_res[k] = true

static func from_snapshot(s: Dictionary) -> GLCSceneModel:
	var m := GLCSceneModel.new()
	m.scene_path = String(s.get("scene", ""))
	m.load_snapshot(s)
	return m

## Entry (nested payload form used by s.add) for a subtree.
func export_entry(uid: String) -> Dictionary:
	var n: Dictionary = nodes[uid]
	var kids: Array = []
	for k in n["kids"]:
		kids.append(export_entry(k))
	return {"uid": uid, "name": n["name"], "cls": n["cls"], "inst": n["inst"], "props": (n["props"] as Dictionary).duplicate(), "kids": kids}

## Order-independent, cross-machine-stable fingerprint of the tree structure.
func structure_hash() -> int:
	var parts := PackedStringArray()
	var keys := nodes.keys()
	keys.sort()
	for uid in keys:
		var n: Dictionary = nodes[uid]
		parts.append("%s|%s|%s|%s|%s|%s" % [uid, n["parent"], n["name"], n["cls"], n["inst"], ",".join(PackedStringArray(n["kids"]))])
	return "\n".join(parts).hash()

## Full fingerprint (structure + encoded properties). Used by tests.
func full_signature() -> String:
	var parts := PackedStringArray()
	var keys := nodes.keys()
	keys.sort()
	for uid in keys:
		var n: Dictionary = nodes[uid]
		var pk: Array = (n["props"] as Dictionary).keys()
		pk.sort()
		var pp := PackedStringArray()
		for k in pk:
			pp.append("%s=%s" % [k, str(n["props"][k])])
		parts.append("%s|%s|%s|%s|%s|%s|%s" % [uid, n["parent"], n["name"], n["cls"], n["inst"], ",".join(PackedStringArray(n["kids"])), ";".join(pp)])
	return "\n".join(parts)

# ====================================================================================
## Client-side wrapper. The model always equals  (host state as of the last message we processed)
## + (our un-acknowledged local operations replayed on top).
## Every message from the host is processed as:  rollback pending -> apply canonical -> replay pending.
## An op the host rejects is simply dropped from the pending list; no special cases needed.
class Replica extends RefCounted:
	var model: GLCSceneModel
	var pending: Array = []          # [{id, t, p0, undo}] oldest first
	var needs_resync: bool = false
	var resync_reason: String = ""

	func _init(m: GLCSceneModel = null) -> void:
		model = m if m != null else GLCSceneModel.new()
		model.record_undo = true

	func pending_count() -> int:
		return pending.size()

	## Optimistically apply a local change. Returns the payload to send to the host, or null if invalid.
	func apply_local(op_id: int, t: String, p: Dictionary) -> Variant:
		var canon: Variant = model.apply(t, p, false)
		if canon == null:
			return null
		pending.append({"id": op_id, "t": t, "p0": canon, "undo": model.last_undo})
		return canon

	func _rollback_all() -> void:
		for i in range(pending.size() - 1, -1, -1):
			var u: Dictionary = pending[i]["undo"]
			if not u.is_empty():
				model.rollback(u)

	func _replay_all() -> void:
		for e in pending:
			var canon: Variant = model.apply(e["t"], e["p0"], false)
			e["undo"] = model.last_undo if canon != null else {}

	## A canonical operation produced by someone else.
	func receive(t: String, p: Dictionary) -> void:
		_rollback_all()
		var r: Variant = model.apply(t, p, true)
		if r == null and model.last_error in ["cycle", "invalid", "missing"]:
			# with exact rebase this means our copy diverged: recover from a snapshot
			if not (t == GLCSceneModel.OP_DEL and model.last_error == "missing"):
				_need_resync("canonical %s failed: %s" % [t, model.last_error])
		_replay_all()

	func ack(op_id: int, corr: Variant) -> void:
		var idx := _find(op_id)
		if idx < 0:
			return
		_rollback_all()
		var e: Dictionary = pending[idx]
		pending.remove_at(idx)
		var pc: Dictionary = (e["p0"] as Dictionary).duplicate()
		if corr is Dictionary:
			pc.merge(corr, true)
		var r: Variant = model.apply(e["t"], pc, true)
		if r == null and model.last_error in ["cycle", "invalid"]:
			_need_resync("ack of %s failed: %s" % [e["t"], model.last_error])
		_replay_all()

	func reject(op_id: int, _reason: String = "") -> void:
		var idx := _find(op_id)
		if idx < 0:
			return
		_rollback_all()
		pending.remove_at(idx)
		_replay_all()

	func _find(op_id: int) -> int:
		for i in pending.size():
			if pending[i]["id"] == op_id:
				return i
		return -1

	func _need_resync(reason: String) -> void:
		needs_resync = true
		resync_reason = reason

	func reset_from_snapshot(s: Dictionary) -> void:
		pending.clear()
		needs_resync = false
		resync_reason = ""
		model.load_snapshot(s)
