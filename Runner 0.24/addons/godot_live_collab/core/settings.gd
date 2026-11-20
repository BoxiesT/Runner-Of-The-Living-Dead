@tool
class_name GLCSettings
extends RefCounted
## Persistent per-user options (stored in the Godot editor settings, shared by all your projects).
## The session password is never stored.

const PREFIX := "godot_live_collab/"
const DEFAULTS := {
	"name": "",
	"color": Color(0.35, 0.85, 0.55),
	"address": "",
	"port": 24680,
	"lan_only": true,
	"discovery": true,
	"sync_scene": true,
	"sync_scripts": true,
	"sync_files": true,
	"push_local_files": true,
	"presence": true,
	"selection": true,
	"toasts": true,
	"auto_reconnect": true,
	"responsive_background": true,
	"open_host_scene": true,
	"verbose": false,
}

static func get_value(key: String) -> Variant:
	var es := EditorInterface.get_editor_settings()
	var full := PREFIX + key
	if es != null and es.has_setting(full):
		return es.get_setting(full)
	return DEFAULTS.get(key)

static func set_value(key: String, value: Variant) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(PREFIX + key, value)

static func default_name() -> String:
	var n := String(get_value("name"))
	if not n.is_empty():
		return n
	var os_name := OS.get_environment("USERNAME") if OS.has_environment("USERNAME") else OS.get_environment("USER")
	return os_name if not os_name.is_empty() else "Dev%d" % (Time.get_ticks_msec() % 1000)
