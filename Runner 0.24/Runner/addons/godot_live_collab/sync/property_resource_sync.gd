@tool
class_name GLCPropertyResourceSync
extends RefCounted
## Turns engine objects into plain data and back.
##
## * Only properties the scene file would store (PROPERTY_USAGE_STORAGE) are replicated, and values equal
##   to the class default are skipped (small snapshots, and a freshly instantiated node already has them).
## * Resources: external files travel as a path reference; embedded sub-resources are hoisted into a
##   per-op `res` table (shared instances stay shared) and referenced as {"__glc":"rref","u":id}.
## * Nodes inside property values travel as {"__glc":"nref","u":uid}.
##
## `ctx` is a Dictionary: { "b": binding, "res_out": {}, "res_in": {}, "missing": [] }
## where `binding` provides: uid_of_node(node), node_of_uid(uid), ruid_of(res), resource_of(ruid),
## register_resource(ruid, res), watch_resource(res), res_cache(ruid) -> Dictionary.

const SKIP_NAMES := {
	"owner": true, "name": true, "scene_file_path": true, "multiplayer": true,
	"filename": true, "script_source": true,
}

var _list_cache: Dictionary = {}      # key -> Array of {name, type, hint, native}
var _default_cache: Dictionary = {}   # class -> {prop: default}

# ------------------------------------------------------------------ property lists

static func _usable_type(info: Dictionary) -> bool:
	var t: int = info["type"]
	if t == TYPE_NIL or t == TYPE_RID or t == TYPE_CALLABLE or t == TYPE_SIGNAL:
		return false
	if t == TYPE_OBJECT:
		var hint: int = info.get("hint", 0)
		var hs: String = info.get("hint_string", "")
		# only resources and nodes are representable
		return hint == PROPERTY_HINT_RESOURCE_TYPE or hint == PROPERTY_HINT_NODE_TYPE or hs == "Resource" or info["name"] == "script"
	return true

func _list_key(obj: Object) -> String:
	var s: Variant = obj.get_script()
	return "%s|%d" % [obj.get_class(), (s as Object).get_instance_id() if s != null else 0]

## Names (in set order, `script` first) of the properties that should be replicated for `obj`.
func syncable_props(obj: Object) -> Array:
	var key := _list_key(obj)
	if _list_cache.has(key):
		return _list_cache[key]
	var native := {}
	for p in ClassDB.class_get_property_list(obj.get_class()):
		native[p["name"]] = true
	var out: Array = []
	var first: Array = []
	for info in obj.get_property_list():
		var usage: int = info["usage"]
		var pname: String = info["name"]
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		# (the engine flags `script` as INTERNAL, but it is exactly what "Attach Script" changes)
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_INTERNAL | PROPERTY_USAGE_READ_ONLY) and pname != "script":
			continue
		if SKIP_NAMES.has(pname):
			continue
		# engine-internal "_..." properties are skipped, but exported script variables such as
		# `@export var _speed` are real data
		if pname.begins_with("_") and not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if pname.begins_with("metadata/_glc"):
			continue
		if not _usable_type(info):
			continue
		var entry := {"name": pname, "type": info["type"], "native": native.has(pname)}
		if pname == "script":
			first.append(entry)
		else:
			out.append(entry)
	var res: Array = first + out
	_list_cache[key] = res
	return res

## Scripts were (re)loaded: their exported variables / signals may have changed.
func invalidate_lists() -> void:
	_list_cache.clear()
	_signal_cache.clear()
	_inst_base_cache.clear()

## Only project resources may be referenced by path (never user://, absolute or other schemes).
static func is_allowed_resource_path(path: String) -> bool:
	if path.begins_with("uid://"):
		return true
	return GLCProtocol.is_safe_res_path(path)

func class_default(cls: String, prop: String) -> Variant:
	var d: Dictionary = _default_cache.get(cls, {})
	if not _default_cache.has(cls):
		_default_cache[cls] = d
	if not d.has(prop):
		d[prop] = ClassDB.class_get_property_default_value(cls, prop)
	return d[prop]

## Instance roots (a node that instances another scene) inherit their values from that scene: those are
## their "defaults", so only real overrides are replicated (and a change of the instanced scene shows up).
var _inst_base_cache: Dictionary = {}   # scene path -> {prop: value}

func instance_base(obj: Object) -> Dictionary:
	if not (obj is Node):
		return {}
	var n := obj as Node
	var path := String(n.scene_file_path)
	if path.is_empty() or n.owner == null:
		return {}   # not an instance (the edited scene root also has a scene_file_path, but no owner)
	if _inst_base_cache.has(path):
		return _inst_base_cache[path]
	var base := {}
	if is_allowed_resource_path(path) and ResourceLoader.exists(path):
		var ps: Variant = load(path)
		if ps is PackedScene:
			# an inherited scene stores only its own overrides: walk down to the first base scene and
			# overlay each level on top of the previous one
			var chain: Array = []
			var st: SceneState = (ps as PackedScene).get_state()
			var guard := 0
			while st != null and guard < 16:
				guard += 1
				chain.push_front(st)
				var next: SceneState = st.get_base_scene_state()
				if next == null and st.get_node_count() > 0:
					var inst_ps: PackedScene = st.get_node_instance(0)
					if inst_ps != null:
						next = inst_ps.get_state()
				st = next
			for s in chain:
				if s.get_node_count() > 0:
					for i in s.get_node_property_count(0):
						base[String(s.get_node_property_name(0, i))] = s.get_node_property_value(0, i)
	_inst_base_cache[path] = base
	return base

## Scene files changed: instance defaults must be read again.
func invalidate_instance_bases() -> void:
	_inst_base_cache.clear()

## True when `value` equals the default the freshly instantiated object would have.
func is_default(obj: Object, entry: Dictionary, value: Variant) -> bool:
	var pname: String = entry["name"]
	var base := instance_base(obj)
	if base.has(pname):
		var bv: Variant = base[pname]
		if pname == "script":
			return value == bv
		return typeof(bv) == typeof(value) and bv == value
	if pname == "script":
		return value == null
	if entry["native"]:
		var dv: Variant = class_default(obj.get_class(), pname)
		if dv == null:
			return value == null
		return typeof(dv) == typeof(value) and dv == value
	var s: Variant = obj.get_script()
	if s is Script:
		var sd: Variant = (s as Script).get_property_default_value(pname)
		if sd != null and typeof(sd) == typeof(value):
			return sd == value
	return false

static func same_value(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
			return is_equal_approx(float(a), float(b))
		if (ta == TYPE_STRING or ta == TYPE_STRING_NAME) and (tb == TYPE_STRING or tb == TYPE_STRING_NAME):
			return str(a) == str(b)
		return false
	if ta == TYPE_FLOAT:
		return is_equal_approx(a, b) or (is_nan(a) and is_nan(b))
	return a == b

# ------------------------------------------------------------------ encode

func encode(v: Variant, ctx: Dictionary, depth: int = 0) -> Variant:
	if depth > 24:
		return null
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			return v
		TYPE_OBJECT:
			return _encode_object(v, ctx, depth)
		TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL:
			return null
		TYPE_ARRAY:
			var arr: Array = v
			var items: Array = []
			for e in arr:
				items.append(encode(e, ctx, depth + 1))
			if arr.is_typed():
				var script_path := ""
				var ts: Variant = arr.get_typed_script()
				if ts is Script:
					script_path = (ts as Script).resource_path
				return {"__glc": "tarr", "t": arr.get_typed_builtin(), "c": String(arr.get_typed_class_name()), "s": script_path, "v": items}
			return items
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var out := {}
			for k in d:
				out[k] = encode(d[k], ctx, depth + 1)
			if out.has("__glc"):
				return {"__glc": "dict", "d": out}
			return out
	return v   # vectors, colors, transforms, packed arrays...

func _encode_object(o: Object, ctx: Dictionary, depth: int) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	var b: Object = ctx["b"]
	if o is Node:
		var uid: String = b.uid_of_node(o)
		return {"__glc": "nref", "u": uid} if not uid.is_empty() else null
	if o is Resource:
		var r: Resource = o
		var path := r.resource_path
		if not path.is_empty() and not path.contains("::"):
			return {"__glc": "ext", "path": path, "cls": r.get_class()}
		var ruid: String = b.ruid_of(r)
		var out: Dictionary = ctx["res_out"]
		if not out.has(ruid):
			out[ruid] = {}   # cycle guard
			out[ruid] = capture_resource_entry(r, ctx, depth + 1)
		return {"__glc": "rref", "u": ruid}
	return null

## Full entry for an embedded resource (non-default storage properties).
func capture_resource_entry(r: Resource, ctx: Dictionary, depth: int = 0) -> Dictionary:
	var props := {}
	var cache: Dictionary = ctx["b"].res_cache(ctx["b"].ruid_of(r))
	for entry in syncable_props(r):
		var pname: String = entry["name"]
		var val: Variant = r.get(pname)
		cache[pname] = hash(val)
		if is_default(r, entry, val):
			continue
		props[pname] = encode(val, ctx, depth + 1)
	var out := {"c": r.get_class(), "v": props}
	if r is Script:
		out["src"] = (r as Script).source_code
	return out

## Properties of `r` whose value changed since the last capture/apply (hash based).
func diff_resource(r: Resource, ctx: Dictionary) -> Dictionary:
	var changed := {}
	var cache: Dictionary = ctx["b"].res_cache(ctx["b"].ruid_of(r))
	for entry in syncable_props(r):
		var pname: String = entry["name"]
		var val: Variant = r.get(pname)
		var h := hash(val)
		if cache.get(pname, null) != h:
			cache[pname] = h
			changed[pname] = encode(val, ctx, 1)
	return changed

# ------------------------------------------------------------------ decode

func decode(v: Variant, ctx: Dictionary, depth: int = 0) -> Variant:
	if depth > 24:
		return null
	if v is Dictionary:
		var d: Dictionary = v
		var kind: String = String(d.get("__glc", ""))
		match kind:
			"nref":
				var n: Node = ctx["b"].node_of_uid(String(d.get("u", "")))
				if n == null:
					(ctx["missing"] as Array).append({"kind": "node", "u": d.get("u", "")})
				return n
			"ext":
				var path: String = String(d.get("path", ""))
				if not is_allowed_resource_path(path):
					return null
				if ResourceLoader.exists(path):
					var loaded: Resource = load(path)
					if loaded != null:
						return loaded
				# not here yet, or not loadable yet (a dependency still on its way): retried later
				(ctx["missing"] as Array).append({"kind": "file", "path": path})
				return null
			"rref":
				return _decode_rref(String(d.get("u", "")), ctx, depth)
			"tarr":
				var items: Array = []
				for e in d.get("v", []):
					items.append(decode(e, ctx, depth + 1))
				var script: Variant = null
				if String(d.get("s", "")) != "" and is_allowed_resource_path(String(d["s"])) and ResourceLoader.exists(String(d["s"])):
					script = load(String(d["s"]))
				return Array(items, int(d.get("t", TYPE_NIL)), StringName(String(d.get("c", ""))), script)
			"dict":
				var inner := {}
				for k in (d.get("d", {}) as Dictionary):
					inner[k] = decode(d["d"][k], ctx, depth + 1)
				return inner
		var out := {}
		for k in d:
			out[k] = decode(d[k], ctx, depth + 1)
		return out
	if v is Array:
		var arr: Array = []
		for e in v:
			arr.append(decode(e, ctx, depth + 1))
		return arr
	return v

func _decode_rref(ruid: String, ctx: Dictionary, depth: int) -> Variant:
	var b: Object = ctx["b"]
	var entry: Variant = (ctx["res_in"] as Dictionary).get(ruid, null)
	var res: Resource = b.resource_of(ruid)
	if res == null:
		if not (entry is Dictionary):
			(ctx["missing"] as Array).append({"kind": "res", "u": ruid})
			return null
		var cls := String(entry.get("c", "Resource"))
		if entry.has("src") and ClassDB.class_exists(cls) and ClassDB.is_parent_class(cls, "Script"):
			var sc: Script = ClassDB.instantiate(cls)
			sc.source_code = String(entry["src"])
			sc.reload()
			res = sc
		elif ClassDB.class_exists(cls) and ClassDB.can_instantiate(cls) and ClassDB.is_parent_class(cls, "Resource"):
			res = ClassDB.instantiate(cls)
		else:
			(ctx["missing"] as Array).append({"kind": "class", "c": cls})
			return null
		b.register_resource(ruid, res)
		b.watch_resource(res)
		apply_resource_entry(res, entry, ctx, depth + 1, true)
	elif entry is Dictionary and not (entry as Dictionary).is_empty():
		apply_resource_entry(res, entry, ctx, depth + 1, false)
	return res

## Applies an embedded-resource entry onto an existing instance. `full` resets unspecified props to default.
func apply_resource_entry(res: Resource, entry: Dictionary, ctx: Dictionary, depth: int = 0, full: bool = false) -> void:
	var b: Object = ctx["b"]
	var cache: Dictionary = b.res_cache(b.ruid_of(res))
	var vals: Dictionary = entry.get("v", {})
	var guard: Dictionary = ctx.get("res_guard", {})
	ctx["res_guard"] = guard
	var ruid: String = b.ruid_of(res)
	if guard.has(ruid):
		return
	guard[ruid] = true
	for pname in vals:
		var decoded: Variant = decode(vals[pname], ctx, depth + 1)
		var cur: Variant = res.get(pname)
		if not same_value(cur, decoded):
			res.set(pname, decoded)
		cache[pname] = hash(res.get(pname))
	guard.erase(ruid)

# ------------------------------------------------------------------ nodes

## Non-default storage properties + groups + signal connections of a node (used for add / snapshot).
func capture_node(node: Node, ctx: Dictionary, cache: Dictionary) -> Dictionary:
	var props := {}
	for entry in syncable_props(node):
		var pname: String = entry["name"]
		var val: Variant = node.get(pname)
		cache[pname] = hash(val)
		if is_default(node, entry, val):
			continue
		props[pname] = encode(val, ctx)
	var groups := _groups_of(node)
	cache["@groups"] = hash(groups)
	if not groups.is_empty():
		props["@groups"] = groups
	var conns := conns_of(node, ctx)
	cache["@conns"] = hash(conns)
	if not conns.is_empty():
		props["@conns"] = conns
	return props

## Properties that changed since the last capture/apply. Updates the cache.
## Signal connections are only compared when ctx["conns"] is true (they are costlier to read and only
## change through editor actions, which trigger such a pass).
func diff_node(node: Node, ctx: Dictionary, cache: Dictionary) -> Dictionary:
	var changed := {}
	for entry in syncable_props(node):
		var pname: String = entry["name"]
		var val: Variant = node.get(pname)
		var h := hash(val)
		if cache.get(pname, null) != h:
			cache[pname] = h
			changed[pname] = encode(val, ctx)
	var groups := _groups_of(node)
	var gh := hash(groups)
	if cache.get("@groups", null) != gh:
		cache["@groups"] = gh
		changed["@groups"] = groups
	if bool(ctx.get("conns", false)):
		var conns := conns_of(node, ctx)
		var ch := hash(conns)
		if cache.get("@conns", null) != ch:
			cache["@conns"] = ch
			changed["@conns"] = conns
	return changed

## Re-reads every replicated property and stores its hash (so the next diff reports only *new* edits).
func refresh_cache(node: Node, cache: Dictionary, ctx: Dictionary = {}) -> void:
	for entry in syncable_props(node):
		var pname: String = entry["name"]
		cache[pname] = hash(node.get(pname))
	cache["@groups"] = hash(_groups_of(node))
	if not ctx.is_empty():
		cache["@conns"] = hash(conns_of(node, ctx))

# ------------------------------------------------------------------ signal connections

## Internal editor flag of connections that come from an instanced/inherited scene (never saved by the
## outer scene, so never replicated or removed by us).
const CONNECT_INHERITED_FLAG := 32
const _CONN_FLAG_MASK := CONNECT_DEFERRED | CONNECT_PERSIST | CONNECT_ONE_SHOT | CONNECT_REFERENCE_COUNTED | CONNECT_APPEND_SOURCE_OBJECT

var _signal_cache: Dictionary = {}    # list key -> PackedStringArray of signal names

func _signal_names(obj: Object) -> PackedStringArray:
	var key := _list_key(obj)
	if _signal_cache.has(key):
		return _signal_cache[key]
	var names := PackedStringArray()
	for s in obj.get_signal_list():
		names.append(String(s["name"]))
	_signal_cache[key] = names
	return names

## Persistent (saved-in-scene) connections from `node` to other nodes of the same shared scene, as
## sorted plain data: [signal, target_uid, method, flags, binds(encoded), unbinds].
func conns_of(node: Node, ctx: Dictionary) -> Array:
	var b: Object = ctx["b"]
	var out: Array = []
	for sig in _signal_names(node):
		for c in node.get_signal_connection_list(sig):
			var flags := int(c["flags"])
			if not (flags & CONNECT_PERSIST) or (flags & CONNECT_INHERITED_FLAG):
				continue
			var cb: Callable = c["callable"]
			var tgt: Object = cb.get_object()
			if not (tgt is Node) or not is_instance_valid(tgt):
				continue
			var tuid: String = b.uid_of_node(tgt)
			if tuid.is_empty():
				continue
			var binds: Array = []
			for a in cb.get_bound_arguments():
				binds.append(encode(a, ctx))
			out.append([sig, tuid, String(cb.get_method()), flags & _CONN_FLAG_MASK, binds, cb.get_unbound_arguments_count()])
	out.sort_custom(func(x, y): return var_to_str(x) < var_to_str(y))
	return out

static func _conn_key(e: Array) -> String:
	return var_to_str([e[0], e[1], e[2], e[3], e[4], e[5]])

## Makes the persistent connections of `node` (towards nodes of the shared scene) equal to `wanted`.
func _apply_conns(node: Node, wanted: Array, ctx: Dictionary) -> void:
	var b: Object = ctx["b"]
	var want := {}
	for e in wanted:
		if e is Array and (e as Array).size() >= 6:
			want[_conn_key(e)] = e
	var have := {}
	for sig in _signal_names(node):
		for c in node.get_signal_connection_list(sig):
			var flags := int(c["flags"])
			if not (flags & CONNECT_PERSIST) or (flags & CONNECT_INHERITED_FLAG):
				continue
			var cb: Callable = c["callable"]
			var tgt: Object = cb.get_object()
			if not (tgt is Node) or not is_instance_valid(tgt):
				continue
			var tuid: String = b.uid_of_node(tgt)
			if tuid.is_empty():
				continue
			var binds: Array = []
			for a in cb.get_bound_arguments():
				binds.append(encode(a, ctx))
			var key := _conn_key([sig, tuid, String(cb.get_method()), flags & _CONN_FLAG_MASK, binds, cb.get_unbound_arguments_count()])
			if want.has(key):
				have[key] = true
			else:
				node.disconnect(sig, cb)
	for key in want:
		if have.has(key):
			continue
		var e: Array = want[key]
		var target: Node = b.node_of_uid(String(e[1]))
		if target == null:
			(ctx["missing"] as Array).append({"kind": "node", "u": e[1]})
			continue
		# bind first, unbind last: the signal's trailing arguments are dropped, then the extra ones appended
		var cb2 := Callable(target, StringName(String(e[2])))
		var binds2: Array = []
		for a in e[4]:
			binds2.append(decode(a, ctx))
		if not binds2.is_empty():
			cb2 = cb2.bindv(binds2)
		if int(e[5]) > 0:
			cb2 = cb2.unbind(int(e[5]))
		if node.has_signal(String(e[0])) and not node.is_connected(String(e[0]), cb2):
			node.connect(String(e[0]), cb2, int(e[3]) | CONNECT_PERSIST)

## [has_default, value] for a property of `obj`.
func default_value(obj: Object, entry: Dictionary) -> Array:
	var pname: String = entry["name"]
	var base := instance_base(obj)
	if base.has(pname):
		return [true, base[pname]]
	if pname == "script":
		return [true, null]
	if entry["native"]:
		var dv: Variant = class_default(obj.get_class(), pname)
		if dv == null:
			return [int(entry["type"]) == TYPE_OBJECT, null]
		return [true, dv]
	var s: Variant = obj.get_script()
	if s is Script:
		var sd: Variant = (s as Script).get_property_default_value(pname)
		if sd != null:
			return [true, sd]
	return [false, null]

## Applies encoded `props` to `node`. With `full`, every replicated property that is *absent* from `props`
## is reset to its default (the sender omits defaults, so absence means "default").
func apply_node_props(node: Node, props: Dictionary, ctx: Dictionary, cache: Dictionary, full: bool = false) -> Array:
	var applied: Array = []
	# script first: it defines extra properties
	var names: Array = props.keys()
	if names.has("script"):
		names.erase("script")
		names.push_front("script")
	elif full:
		# no script in the canonical record = the default one (none, or the instanced scene's own script)
		var base_script: Variant = instance_base(node).get("script", null)
		if node.get_script() != base_script:
			node.set_script(base_script)
			cache["script"] = hash(node.get_script())
			applied.append("script")
	for pname in names:
		if SKIP_NAMES.has(pname):
			continue   # structural / identity properties never travel as plain values
		var enc: Variant = props[pname]
		if pname == "@groups":
			_apply_groups(node, enc if enc is Array else [])
			cache["@groups"] = hash(_groups_of(node))
			applied.append(pname)
			continue
		if pname == "@conns":
			_apply_conns(node, enc if enc is Array else [], ctx)
			cache["@conns"] = hash(conns_of(node, ctx))
			applied.append(pname)
			continue
		var missing_before := (ctx["missing"] as Array).size()
		var decoded: Variant = decode(enc, ctx)
		if (ctx["missing"] as Array).size() > missing_before and decoded == null:
			# something it needs has not arrived: keep the current value (never "remove the script") and
			# leave the cache alone, so this property is applied again once the file is here
			continue
		if pname == "script":
			if decoded != node.get_script():
				node.set_script(decoded)
		else:
			var cur: Variant = node.get(pname)
			if not same_value(cur, decoded):
				# typed arrays: keep the property's own array type
				if cur is Array and decoded is Array and (cur as Array).is_typed() and not (decoded as Array).is_typed():
					var typed: Array = (cur as Array).duplicate()
					typed.clear()
					typed.assign(decoded)
					decoded = typed
				node.set(pname, decoded)
		cache[pname] = hash(node.get(pname))
		applied.append(pname)
	if full:
		for entry in syncable_props(node):
			var pn: String = entry["name"]
			if props.has(pn) or pn == "script":
				continue
			var dflt: Array = default_value(node, entry)
			if not dflt[0]:
				continue
			var cur2: Variant = node.get(pn)
			if not same_value(cur2, dflt[1]):
				node.set(pn, dflt[1])
				cache[pn] = hash(node.get(pn))
				applied.append(pn)
		if not props.has("@groups") and not _groups_of(node).is_empty():
			_apply_groups(node, [])
			cache["@groups"] = hash(_groups_of(node))
		if not props.has("@conns"):
			_apply_conns(node, [], ctx)
			cache["@conns"] = hash(conns_of(node, ctx))
	return applied

## Puts the given replicated properties back to their default value (they are absent from the model).
func reset_to_default(node: Node, names: Array, cache: Dictionary, ctx: Dictionary) -> void:
	var by_name := {}
	for entry in syncable_props(node):
		by_name[entry["name"]] = entry
	for pn in names:
		if pn == "@groups":
			_apply_groups(node, [])
			cache["@groups"] = hash(_groups_of(node))
		elif pn == "@conns":
			_apply_conns(node, [], ctx)
			cache["@conns"] = hash(conns_of(node, ctx))
		elif by_name.has(pn) and pn != "script":
			var dflt: Array = default_value(node, by_name[pn])
			if dflt[0] and not same_value(node.get(pn), dflt[1]):
				node.set(pn, dflt[1])
			cache[pn] = hash(node.get(pn))

static func _groups_of(node: Node) -> Array:
	var g: Array = []
	for n in node.get_groups():
		var s := String(n)
		if not s.begins_with("_"):
			g.append(s)
	g.sort()
	return g

static func _apply_groups(node: Node, wanted: Array) -> void:
	var have := _groups_of(node)
	for g in have:
		if not wanted.has(g):
			node.remove_from_group(g)
	for g in wanted:
		if not have.has(g):
			node.add_to_group(String(g), true)
