@tool
extends EditorPlugin
## Godot Live Collab — plugin entry point. Wires the modules together and hosts the dock.

var session_manager: GLCSessionManager
var scene_sync: GLCSceneTreeSync
var script_sync: GLCScriptLiveSync
var file_sync: GLCFileSync
var presence_sync: GLCAvatarPresenceSync
var project_sync: GLCProjectSettingsSync
## (loaded by path: works even before the editor has registered the class name of this newer module)
const LanDiscovery := preload("res://addons/godot_live_collab/core/lan_discovery.gd")
var discovery: LanDiscovery
var dock: GLCCollabDock
var _dock_wrapper: Control = null
var _classic_dock := false

func _enter_tree() -> void:
	name = "GodotLiveCollabPlugin"
	set_force_draw_over_forwarding_enabled()
	session_manager = GLCSessionManager.new()
	session_manager.name = "GLCSessionManager"
	add_child(session_manager)

	scene_sync = GLCSceneTreeSync.new(session_manager, self)
	script_sync = GLCScriptLiveSync.new(session_manager, self)
	file_sync = GLCFileSync.new(session_manager, self)
	presence_sync = GLCAvatarPresenceSync.new(session_manager, self, scene_sync)
	project_sync = GLCProjectSettingsSync.new(session_manager, self)
	discovery = LanDiscovery.new(session_manager)
	file_sync.is_live_managed = Callable(self, "_is_live_managed")
	scene_sync.ensure_files = Callable(file_sync, "ensure_announced")
	_apply_options()

	scene_sync.start()
	project_sync.start()

	# editor events
	scene_changed.connect(_on_scene_changed)
	scene_saved.connect(_on_scene_saved)
	resource_saved.connect(_on_resource_saved)
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.filesystem_changed.connect(_on_filesystem_changed)
		efs.script_classes_updated.connect(_on_scripts_reloaded)
	session_manager.peer_joined.connect(func(_id, _info): presence_sync.republish())
	session_manager.session_started.connect(_on_session_started_open_scene)

	# feedback
	session_manager.log_line.connect(_on_log)
	session_manager.peer_joined.connect(func(_id, info): _notify("%s entrou" % info.get("name", "?")))
	session_manager.peer_left.connect(func(_id, info): _notify("%s saiu" % info.get("name", "?")))
	session_manager.session_started.connect(func(h): _notify("Sessão iniciada (%s)" % ("host" if h else "cliente")))
	session_manager.session_ended.connect(func(r): _notify("Sessão encerrada: %s" % r, 1))
	for m in [scene_sync, script_sync, file_sync]:
		m.activity.connect(func(t): _on_log(t, 0))   # routine activity: dock only, never a pop-up
	file_sync.file_arrived.connect(scene_sync.on_file_arrived)
	file_sync.local_file_changed.connect(scene_sync.on_scene_file_changed)
	scene_sync.saved_remotely.connect(func(p): file_sync.note_saved(p))
	script_sync.saved_remotely.connect(func(p): file_sync.note_saved(p))

	_install_dock()
	set_process(true)

func _exit_tree() -> void:
	set_process(false)
	if _saved_sleep_usec >= 0:
		_restore_sleep()
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		if efs.filesystem_changed.is_connected(_on_filesystem_changed):
			efs.filesystem_changed.disconnect(_on_filesystem_changed)
		if efs.script_classes_updated.is_connected(_on_scripts_reloaded):
			efs.script_classes_updated.disconnect(_on_scripts_reloaded)
	for m in [scene_sync, script_sync, file_sync, project_sync, discovery]:
		if m != null:
			m.stop()
	_remove_dock()
	if session_manager != null:
		session_manager.close_session("plugin desativado", false)
		session_manager.queue_free()

## The editor sleeps ~100 ms per frame when its window is not focused (to save CPU). During a session
## that would add up to 100 ms per network hop, so the idle sleep is capped while connected and the
## editor's own value is restored afterwards.
const SESSION_MAX_SLEEP_USEC := 8000
var _saved_sleep_usec: int = -1   # >= 0 while our cap is in place

func _keep_responsive() -> void:
	var live := session_manager.is_active_session and bool(GLCSettings.get_value("responsive_background"))
	if live:
		# (the editor sets its own value again on every focus change: re-apply the cap)
		if OS.low_processor_usage_mode_sleep_usec > SESSION_MAX_SLEEP_USEC:
			_saved_sleep_usec = OS.low_processor_usage_mode_sleep_usec
			OS.low_processor_usage_mode_sleep_usec = SESSION_MAX_SLEEP_USEC
	elif _saved_sleep_usec >= 0:
		_restore_sleep()

## Back to what the editor itself would use right now (focused / unfocused editor settings).
func _restore_sleep() -> void:
	_saved_sleep_usec = -1
	if OS.low_processor_usage_mode_sleep_usec != SESSION_MAX_SLEEP_USEC:
		return   # the editor already set its own value
	var es := EditorInterface.get_editor_settings()
	var key := "interface/editor/low_processor_mode_sleep_usec" if DisplayServer.window_is_focused() else "interface/editor/unfocused_low_processor_mode_sleep_usec"
	if es != null and es.has_setting(key):
		OS.low_processor_usage_mode_sleep_usec = int(es.get_setting(key))

## Joining: open the scene the host is editing as soon as its file is here.
const OPEN_HOST_SCENE_TIMEOUT_MS := 90000
var _open_host_scene_until: int = 0

var _open_host_scene_armed: bool = false   # set by "Entrar" (not by automatic reconnections)

func _on_session_started_open_scene(is_host: bool) -> void:
	_open_host_scene_until = 0
	if not is_host and _open_host_scene_armed and bool(GLCSettings.get_value("open_host_scene")):
		_open_host_scene_until = Time.get_ticks_msec() + OPEN_HOST_SCENE_TIMEOUT_MS
	_open_host_scene_armed = false

func _try_open_host_scene() -> void:
	if _open_host_scene_until == 0:
		return
	if not session_manager.is_active_session or Time.get_ticks_msec() > _open_host_scene_until:
		_open_host_scene_until = 0
		return
	var host: Dictionary = session_manager.peers.get(1, {})
	if not host.has("scene"):
		return   # the host's info has not arrived yet
	var path := String(host["scene"])
	if path.is_empty() or not GLCProtocol.is_syncable_path(path):
		_open_host_scene_until = 0   # the host has no saved scene open
		return
	# wait until the file is here and complete (the join download may still be running)
	if not FileAccess.file_exists(path) or not ResourceLoader.exists(path):
		return
	if file_sync.enabled and (file_sync.reconcile_state in ["waiting_manifest", "pulling"] or file_sync.is_receiving(path)):
		return
	_open_host_scene_until = 0
	var cur := EditorInterface.get_edited_scene_root()
	if cur != null and cur.scene_file_path == path:
		return
	EditorInterface.open_scene_from_path(path)
	_on_log("Abrindo a cena em que o host está: " + path.get_file(), 0)

func _process(delta: float) -> void:
	if session_manager == null:
		return
	_keep_responsive()
	_try_open_host_scene()
	scene_sync.process(delta)
	script_sync.process(delta)
	script_sync.process_carets()
	file_sync.process(delta)
	presence_sync.process(delta)
	project_sync.process(delta)
	discovery.process()

# ---------------------------------------------------------------- overlays (presence)

func _forward_canvas_force_draw_over_viewport(overlay: Control) -> void:
	if presence_sync != null:
		presence_sync.draw_2d(overlay)

func _forward_3d_force_draw_over_viewport(overlay: Control) -> void:
	if presence_sync != null:
		presence_sync.draw_3d(overlay)

# ---------------------------------------------------------------- editor events

func _on_scene_changed(_root: Node) -> void:
	if scene_sync != null:
		scene_sync.on_editor_scene_changed()

func _on_scene_saved(path: String) -> void:
	scene_sync.codec.invalidate_instance_bases()   # instances of this scene inherit its new values
	scene_sync.notify_scene_saved(path)
	file_sync.note_saved(path)

func _on_resource_saved(res: Resource) -> void:
	script_sync.on_resource_saved(res)
	if res is Script:
		_on_scripts_reloaded()
	if res != null and not res.resource_path.is_empty() and not res.resource_path.contains("::"):
		file_sync.note_saved(res.resource_path)

func _on_filesystem_changed() -> void:
	file_sync.request_scan()

## Exported variables / signals of scripts may have changed: property lists must be read again.
func _on_scripts_reloaded() -> void:
	if scene_sync != null:
		scene_sync.codec.invalidate_lists()

## A file is "owned by the editor" while it is open in a tab here, whether or not it is (already) bound
## to live editing: its bytes are never replaced under an open editor (that would make the editor ask to
## reload it from disk).
func _is_live_managed(path: String) -> bool:
	if scene_sync.bindings.has(path) or script_sync.docs.has(path):
		return true
	var now := Time.get_ticks_msec()
	if now - _open_cache_ms > 250:
		_open_cache_ms = now
		_open_cache.clear()
		for p in EditorInterface.get_open_scenes():
			_open_cache[String(p)] = true
		var se := EditorInterface.get_script_editor()
		if se != null:
			for s in se.get_open_scripts():
				if s != null:
					_open_cache[String(s.resource_path)] = true
	return _open_cache.has(path)

var _open_cache: Dictionary = {}
var _open_cache_ms: int = -100000

# ---------------------------------------------------------------- options

func _apply_options() -> void:
	scene_sync.enabled = bool(GLCSettings.get_value("sync_scene"))
	script_sync.enabled = bool(GLCSettings.get_value("sync_scripts"))
	file_sync.enabled = bool(GLCSettings.get_value("sync_files"))
	file_sync.push_local_only = bool(GLCSettings.get_value("push_local_files"))
	project_sync.enabled = bool(GLCSettings.get_value("sync_scene"))
	presence_sync.enabled = true
	presence_sync.show_pointers = bool(GLCSettings.get_value("presence"))
	presence_sync.show_selection = bool(GLCSettings.get_value("selection"))
	discovery.enabled = bool(GLCSettings.get_value("discovery"))
	var v := bool(GLCSettings.get_value("verbose"))
	session_manager.verbose = v
	scene_sync.verbose = v
	script_sync.verbose = v
	session_manager.auto_reconnect = bool(GLCSettings.get_value("auto_reconnect"))
	session_manager.lan_only = bool(GLCSettings.get_value("lan_only"))

func _on_option_changed(_key: String, _value: Variant) -> void:
	_apply_options()
	update_overlays()

# ---------------------------------------------------------------- dock

func _install_dock() -> void:
	dock = GLCCollabDock.new()
	dock.session = session_manager
	dock.scenes = scene_sync
	dock.scripts = script_sync
	dock.files = file_sync
	dock.discovery = discovery
	dock.host_requested.connect(_on_host_requested)
	dock.join_requested.connect(_on_join_requested)
	dock.disconnect_requested.connect(_on_disconnect_requested)
	dock.reconnect_requested.connect(func(): session_manager.reconnect_now())
	dock.option_changed.connect(_on_option_changed)
	dock.resync_requested.connect(func():
		scene_sync.resync_all()
		_notify("Pedido de ressincronização enviado"))
	dock.rescan_files_requested.connect(func(): file_sync.request_scan())
	dock.open_backups_requested.connect(func():
		var dir := ProjectSettings.globalize_path("res://.glc_backup")
		DirAccess.make_dir_recursive_absolute(dir)
		OS.shell_open(dir))
	var output_was_open := _bottom_panel_open_dock()
	if ClassDB.class_exists("EditorDock") and has_method("add_dock"):
		_dock_wrapper = ClassDB.instantiate("EditorDock")
		_dock_wrapper.set("title", "Live Collab")
		_dock_wrapper.set("default_slot", DOCK_SLOT_RIGHT_UL)
		_dock_wrapper.add_child(dock)
		call("add_dock", _dock_wrapper)
	else:
		_classic_dock = true
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	_keep_output_panel(output_was_open)

func _remove_dock() -> void:
	if dock == null:
		return
	var output_was_open := _bottom_panel_open_dock()
	if _classic_dock:
		remove_control_from_docks(dock)
		dock.queue_free()
	elif _dock_wrapper != null and is_instance_valid(_dock_wrapper):
		call("remove_dock", _dock_wrapper)
		_dock_wrapper.queue_free()
	dock = null
	_dock_wrapper = null
	_keep_output_panel(output_was_open)

# ---------------------------------------------------------------- the bottom Output panel

## The editor's bottom panel (Output log, Debugger, Animation...): turning the plugin on/off (adding or
## removing our dock) must never close it. The dock that was open there is reopened if it got closed.
var _output_dock: Control = null
var _bottom_open: Control = null

func _find_output_dock(n: Node) -> Control:
	if n.get_class() == "EditorLog":
		return n as Control
	for c in n.get_children():
		var r := _find_output_dock(c)
		if r != null:
			return r
	return null

## The dock currently shown in the bottom panel (null if the panel is closed).
func _bottom_panel_open_dock() -> Control:
	if _output_dock == null or not is_instance_valid(_output_dock):
		_output_dock = _find_output_dock(EditorInterface.get_base_control())
	if _output_dock == null or _output_dock.get_parent() == null:
		return null
	for c in _output_dock.get_parent().get_children():
		if c is Control and (c as Control).is_visible_in_tree() and c.has_method("make_visible"):
			return c
	return null

func _keep_output_panel(was_open: Control) -> void:
	if was_open == null:
		return
	_bottom_open = was_open
	_reopen_output()
	# the dock layout may also settle over the next frames
	call_deferred("_reopen_output")
	var tree := get_tree()
	if tree != null:
		tree.create_timer(0.3).timeout.connect(_reopen_output)

func _reopen_output() -> void:
	if _bottom_open != null and is_instance_valid(_bottom_open) and not _bottom_open.is_visible_in_tree():
		_bottom_open.call("make_visible")

func _on_host_requested(port: int, password: String, user_name: String, color: Color) -> void:
	if user_name.is_empty():
		user_name = GLCSettings.default_name()
	var err := session_manager.host_session(port, password, user_name, color)
	if err != OK:
		_notify(session_manager.last_error, 2)

func _on_join_requested(address: String, port: int, password: String, user_name: String, color: Color) -> void:
	if user_name.is_empty():
		user_name = GLCSettings.default_name()
	if address.is_empty():
		_notify("Informe o endereço do host (ou escolha uma sessão encontrada na rede)", 1)
		return
	_open_host_scene_armed = true
	var err := session_manager.join_session(address, port, password, user_name, color)
	if err != OK:
		_open_host_scene_armed = false
		_notify(session_manager.last_error, 2)

func _on_disconnect_requested() -> void:
	session_manager.leave("você saiu")

# ---------------------------------------------------------------- feedback

func _on_log(text: String, level: int) -> void:
	if dock != null:
		dock.add_log(text, level)

## Pop-ups are only for session events (joined, left, connected, errors), and the same text is never
## shown twice within a few seconds.
var _last_toast: Dictionary = {}

func _notify(text: String, level: int = 0) -> void:
	if dock != null:
		dock.add_log(text, level)
	var now := Time.get_ticks_msec()
	if now - int(_last_toast.get(text, -100000)) < 8000:
		return
	_last_toast[text] = now
	if _last_toast.size() > 64:
		_last_toast.clear()
	if bool(GLCSettings.get_value("toasts")):
		var toaster := EditorInterface.get_editor_toaster()
		if toaster != null:
			toaster.push_toast("Live Collab: " + text, level)
