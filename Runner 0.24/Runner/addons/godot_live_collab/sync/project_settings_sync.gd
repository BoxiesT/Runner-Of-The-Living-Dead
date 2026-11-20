@tool
class_name GLCProjectSettingsSync
extends RefCounted
## Keeps the shared project configuration identical: Input Map, Autoloads, display, physics, layers,
## global groups... (see PREFIXES). The host's values win when somebody joins; afterwards every change
## is replicated, and project.godot is saved a moment later so the file on disk follows too.
## Editor plugins (`editor_plugins/`) are deliberately NOT synchronized.

const OP_SET := "p.set"
const PREFIXES := [
	"application/", "display/", "rendering/", "physics/", "input/", "layer_names/", "audio/",
	"autoload/", "global_group/", "gui/", "internationalization/", "debug/", "navigation/",
	"shader_globals/", "xr/", "dotnet/",
]
const SAVE_DELAY_MS := 1500

var session: GLCSessionManager
var plugin: EditorPlugin
var codec: GLCPropertyResourceSync = GLCPropertyResourceSync.new()
var enabled: bool = true

var _hashes: Dictionary = {}
var _applying: int = 0
var _save_at_ms: int = 0
var _started: bool = false
var _names_cache: Array = []

## Minimal "binding" for the codec: project settings only contain embedded resources (InputEvents...).
class Ctx extends RefCounted:
	var _by_iid: Dictionary = {}
	var _refs: Dictionary = {}
	func uid_of_node(_n: Node) -> String:
		return ""
	func node_of_uid(_u: String) -> Node:
		return null
	func ruid_of(r: Resource) -> String:
		var u: String = _by_iid.get(r.get_instance_id(), "")
		if u.is_empty():
			u = GLCProtocol.new_uid()
			_by_iid[r.get_instance_id()] = u
			_refs[u] = r
		return u
	func resource_of(u: String) -> Resource:
		return _refs.get(u, null)
	func register_resource(u: String, r: Resource) -> void:
		_by_iid[r.get_instance_id()] = u
		_refs[u] = r
	func watch_resource(_r: Resource) -> void:
		pass
	func res_cache(_u: String) -> Dictionary:
		return {}

func _init(p_session: GLCSessionManager, p_plugin: EditorPlugin) -> void:
	session = p_session
	plugin = p_plugin
	session.register(OP_SET, _on_set, "op", {"scope": "all"})
	session.register(GLCProtocol.P_STATE, _on_state, "direct")
	session.session_started.connect(_on_session_started)

func start() -> void:
	if _started:
		return
	_started = true
	ProjectSettings.settings_changed.connect(_on_settings_changed)
	_snapshot_hashes()

func stop() -> void:
	if _started and ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	_started = false
	_flush_save()

func _syncable_names() -> Array:
	var out: Array = []
	for info in ProjectSettings.get_property_list():
		var n: String = info["name"]
		if not (info["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		for pre in PREFIXES:
			if n.begins_with(pre):
				out.append(n)
				break
	return out

func _snapshot_hashes() -> void:
	_hashes.clear()
	for n in _syncable_names():
		_hashes[n] = hash(ProjectSettings.get_setting(n))

func _on_session_started(is_host: bool) -> void:
	_snapshot_hashes()
	if not is_host:
		session.send_to(1, GLCProtocol.P_STATE, {"req": true})

func process(_delta: float) -> void:
	if _save_at_ms > 0 and Time.get_ticks_msec() >= _save_at_ms:
		_flush_save()

func _flush_save() -> void:
	if _save_at_ms > 0:
		_save_at_ms = 0
		ProjectSettings.save()

func _schedule_save() -> void:
	_save_at_ms = Time.get_ticks_msec() + SAVE_DELAY_MS

# ------------------------------------------------------------------ local change -> network

func _on_settings_changed() -> void:
	if not enabled or _applying > 0 or not session.is_active_session:
		return
	var ctx := Ctx.new()
	var res_ctx := {"b": ctx, "res_out": {}, "res_in": {}, "missing": []}
	var changed := {}
	var present := {}
	for n in _syncable_names():
		present[n] = true
		var v: Variant = ProjectSettings.get_setting(n)
		var h := hash(v)
		if _hashes.get(n, null) != h:
			_hashes[n] = h
			changed[n] = codec.encode(v, res_ctx)
	# settings that disappeared (input action, autoload, global group... removed)
	var removed: Array = []
	for n in _hashes.keys():
		if not present.has(n):
			_hashes.erase(n)
			removed.append(n)
	if changed.is_empty() and removed.is_empty():
		return
	var payload := {"s": changed, "res": res_ctx["res_out"], "del": removed}
	if session.is_hosting:
		session.submit(0, OP_SET, payload)
	else:
		# when the host confirms, re-apply our own values: a concurrent change by someone else may have
		# arrived (and been applied here) before the host ordered ours after it
		session.submit(session.next_op_id(), OP_SET, payload, func(_corr, _seq): _apply(payload))
	_schedule_save()

# ------------------------------------------------------------------ network -> local

func _apply(payload: Dictionary) -> void:
	var ctx := Ctx.new()
	var dctx := {"b": ctx, "res_out": {}, "res_in": payload.get("res", {}), "missing": []}
	_applying += 1
	var input_changed := false
	var s: Dictionary = payload.get("s", {})
	for n in s:
		var name := String(n)
		if not _is_allowed(name):
			continue
		var v: Variant = codec.decode(s[n], dctx)
		var cur: Variant = ProjectSettings.get_setting(name) if ProjectSettings.has_setting(name) else null
		if not GLCPropertyResourceSync.same_value(cur, v):
			ProjectSettings.set_setting(name, v)
			if name.begins_with("input/"):
				input_changed = true
		_hashes[name] = hash(ProjectSettings.get_setting(name))
	for n in payload.get("del", []):
		var dn := String(n)
		if not _is_allowed(dn) or not ProjectSettings.has_setting(dn):
			_hashes.erase(dn)
			continue
		ProjectSettings.set_setting(dn, null)   # null erases the setting
		_hashes.erase(dn)
		if dn.begins_with("input/"):
			input_changed = true
	_applying -= 1
	if input_changed:
		InputMap.load_from_project_settings()
	_schedule_save()

func _is_allowed(name: String) -> bool:
	for pre in PREFIXES:
		if name.begins_with(pre):
			return true
	return false

func _on_set(_sender: int, p: Dictionary, meta: Dictionary) -> Variant:
	if not enabled:
		return p if meta["stage"] == "host" else null
	_apply(p)
	return p if meta["stage"] == "host" else null

func _on_state(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if session.is_hosting:
		if p.get("req", false):
			var ctx := Ctx.new()
			var res_ctx := {"b": ctx, "res_out": {}, "res_in": {}, "missing": []}
			var all := {}
			for n in _syncable_names():
				if ProjectSettings.property_can_revert(n):
					all[n] = codec.encode(ProjectSettings.get_setting(n), res_ctx)
			session.send_to(sender, GLCProtocol.P_STATE, {"s": all, "res": res_ctx["res_out"], "full": true})
		return
	if not enabled:
		return
	_apply(p)
	if p.get("full", false):
		# settings we changed locally that the host never changed go back to their defaults
		var host_names: Dictionary = p.get("s", {})
		_applying += 1
		for n in _syncable_names():
			if not host_names.has(n) and ProjectSettings.property_can_revert(n):
				ProjectSettings.set_setting(n, ProjectSettings.property_get_revert(n))
				if ProjectSettings.has_setting(n):
					_hashes[n] = hash(ProjectSettings.get_setting(n))
				else:
					_hashes.erase(n)
		_applying -= 1
		InputMap.load_from_project_settings()
		_schedule_save()
