@tool
class_name GLCAvatarPresenceSync
extends RefCounted
## Shows where everybody is working.
##
## * 2D: the mouse pointer of each peer in *world* coordinates (so it lands on the same spot of the scene
##   whatever their zoom/pan is), drawn as an overlay over the 2D editor.
## * 3D: each peer's editor camera position, drawn as a labelled marker over the 3D editor.
## * Selection: nodes selected by others get a coloured outline in the viewport and a coloured row
##   in the Scene dock (matched by exact node path, not by name).
##
## Nothing is added to your scene tree or to the editor viewports: it is all overlay drawing.

signal activity(text: String)

const SEND_INTERVAL_MS := 50
const STALE_MS := 6000
## Unchanged presence is re-sent this often, so a still pointer does not expire and newcomers see it.
const REFRESH_MS := 2000

var session: GLCSessionManager
var plugin: EditorPlugin
var scenes: GLCSceneTreeSync
var enabled: bool = true
var show_pointers: bool = true
var show_selection: bool = true

var peers_state: Dictionary = {}     # peer id -> {scene, p2, p3, cam, sel: [uids], t}
var _last_send_ms: int = 0
var _last_sel_sig: String = ""
var _last_p2: Vector2 = Vector2.INF
var _last_cam_sig: String = ""
var _tree_dirty: bool = true
var _highlighted: Array = []          # [TreeItem, original color]
var _last_refresh_ms: int = 0
var _last_highlight_ms: int = 0
var _last_overlay_poke_ms: int = 0

## Forget what was sent, so everything is published again on the next frame (e.g. someone joined).
func republish() -> void:
	_last_sel_sig = ""
	_last_cam_sig = ""
	_last_p2 = Vector2.INF

func _init(p_session: GLCSessionManager, p_plugin: EditorPlugin, p_scenes: GLCSceneTreeSync) -> void:
	session = p_session
	plugin = p_plugin
	scenes = p_scenes
	session.register(GLCProtocol.V_POINTER, _on_remote_pointer, "bcast", {"scope": "all", "reliable": false})
	session.register(GLCProtocol.V_SELECT, _on_remote_selection, "bcast", {"scope": "all", "reliable": true})
	session.register(GLCProtocol.V_CAMERA, _on_remote_camera, "bcast", {"scope": "all", "reliable": false})
	session.peer_left.connect(_on_peer_left)
	session.session_ended.connect(func(_r): _clear())

func _clear() -> void:
	peers_state.clear()
	_clear_tree_highlights()
	plugin.update_overlays()

func _on_peer_left(peer_id: int, _info: Dictionary) -> void:
	peers_state.erase(peer_id)
	_tree_dirty = true
	plugin.update_overlays()

# ====================================================================== publishing

func process(_delta: float) -> void:
	if not enabled or not session.is_active_session:
		return
	var now := Time.get_ticks_msec()
	if (_overlay_2d == null or not is_instance_valid(_overlay_2d)) and now - _last_overlay_poke_ms > 1000:
		_last_overlay_poke_ms = now
		plugin.update_overlays()   # the editor hands us its 2D overlay on the next redraw
	if now - _last_send_ms >= SEND_INTERVAL_MS:
		_last_send_ms = now
		if now - _last_refresh_ms >= REFRESH_MS:
			_last_refresh_ms = now
			republish()
		_publish_pointer()
		_publish_selection()
	_expire(now)
	# the Scene dock rebuilds its rows when the tree changes (losing our colours): refresh now and then
	if not peers_state.is_empty() and now - _last_highlight_ms > 1500:
		_tree_dirty = true
	if _tree_dirty:
		_tree_dirty = false
		_last_highlight_ms = now
		_update_tree_highlights()

func _current_scene_path() -> String:
	var r := EditorInterface.get_edited_scene_root()
	return r.scene_file_path if r != null else ""

func _publish_pointer() -> void:
	if not show_pointers or not DisplayServer.window_is_focused():
		return
	var scene := _current_scene_path()
	if scene.is_empty():
		return
	var vp2 := EditorInterface.get_editor_viewport_2d()
	if vp2 != null and _main_screen_is("2D") and _overlay_2d != null and is_instance_valid(_overlay_2d) and _overlay_2d.is_visible_in_tree():
		# the mouse in the SAME space the pointers are drawn in (the 2D editor overlay), then through the
		# editor view (zoom + pan) into scene coordinates: everybody sees it on the same spot of the scene
		var mp := _overlay_2d.get_local_mouse_position()
		if Rect2(Vector2.ZERO, _overlay_2d.size).has_point(mp):   # (outside the 2D view: nothing to show)
			var world: Vector2 = _view_2d(vp2).affine_inverse() * mp
			if _last_p2 == Vector2.INF or world.distance_to(_last_p2) > 0.5:
				_last_p2 = world
				session.bcast(GLCProtocol.V_POINTER, {"scene": scene, "p2": world})
	var vp3 := EditorInterface.get_editor_viewport_3d(0)
	if vp3 != null and _main_screen_is("3D"):
		var cam := vp3.get_camera_3d()
		if cam != null:
			var gt := cam.global_transform
			var sig := "%s|%s" % [str(gt.origin.snapped(Vector3.ONE * 0.01)), str(gt.basis.get_euler().snapped(Vector3.ONE * 0.01))]
			if sig != _last_cam_sig:
				_last_cam_sig = sig
				session.bcast(GLCProtocol.V_CAMERA, {"scene": scene, "t": gt})

func _main_screen_is(name: String) -> bool:
	var screen := EditorInterface.get_editor_main_screen()
	if screen == null:
		return false
	for c in screen.get_children():
		if not (c is Control) or not (c as Control).visible:
			continue
		var cls := c.get_class()
		if name == "2D" and cls == "CanvasItemEditor":
			return true
		if name == "3D" and cls == "Node3DEditor":
			return true
	return false

func _publish_selection() -> void:
	if not show_selection:
		return
	var uids: Array = []
	var b := scenes.current_binding()
	if b != null:
		for n in EditorInterface.get_selection().get_selected_nodes():
			var u: String = b.uid_by_iid.get(n.get_instance_id(), "")
			if not u.is_empty():
				uids.append(u)
	uids.sort()
	var sig := "%s|%s" % [_current_scene_path(), ",".join(PackedStringArray(uids))]
	if sig == _last_sel_sig:
		return
	_last_sel_sig = sig
	session.bcast(GLCProtocol.V_SELECT, {"scene": _current_scene_path(), "uids": uids})

# ====================================================================== receiving

func _state_of(peer: int) -> Dictionary:
	if not peers_state.has(peer):
		peers_state[peer] = {"scene": "", "sel": [], "t": 0}
	return peers_state[peer]

func _on_remote_pointer(sender: int, p: Dictionary, meta: Dictionary) -> void:
	var s := _state_of(int(meta.get("origin", sender)))
	s["scene"] = String(p.get("scene", ""))
	s["p2"] = p.get("p2", Vector2.ZERO)
	s["t"] = Time.get_ticks_msec()
	plugin.update_overlays()

func _on_remote_camera(sender: int, p: Dictionary, meta: Dictionary) -> void:
	var s := _state_of(int(meta.get("origin", sender)))
	s["scene"] = String(p.get("scene", ""))
	s["cam"] = p.get("t", Transform3D.IDENTITY)
	s["t"] = Time.get_ticks_msec()
	plugin.update_overlays()

func _on_remote_selection(sender: int, p: Dictionary, meta: Dictionary) -> void:
	var s := _state_of(int(meta.get("origin", sender)))
	var scene := String(p.get("scene", ""))
	var sel: Variant = p.get("uids", [])
	s["t"] = Time.get_ticks_msec()
	if scene == String(s.get("scene", "")) and str(sel) == str(s.get("sel", [])):
		return   # periodic refresh, nothing changed: no redraw, no Scene dock walk
	s["scene"] = scene
	s["sel"] = sel
	_tree_dirty = true
	plugin.update_overlays()

func _expire(now: int) -> void:
	var changed := false
	for k in peers_state.keys():
		var s: Dictionary = peers_state[k]
		if now - int(s.get("t", 0)) > STALE_MS and (s.has("p2") or s.has("cam")):
			s.erase("p2")
			s.erase("cam")
			changed = true
	if changed:
		plugin.update_overlays()

# ====================================================================== overlay drawing

## The 2D editor overlay (the Control the editor hands to plugins to draw over the 2D view).
var _overlay_2d: Control = null

## Scene coordinates -> 2D overlay coordinates: the editor's view (zoom and pan) of the 2D scene.
static func _view_2d(vp2: Viewport) -> Transform2D:
	return vp2.global_canvas_transform * vp2.canvas_transform

func draw_2d(overlay: Control) -> void:
	if not enabled or not session.is_active_session:
		return
	var vp2 := EditorInterface.get_editor_viewport_2d()
	if vp2 == null:
		return
	_overlay_2d = overlay
	var scene := _current_scene_path()
	var xf: Transform2D = _view_2d(vp2)
	var font := overlay.get_theme_default_font()
	var fsize := 13
	for peer in peers_state:
		var s: Dictionary = peers_state[peer]
		if String(s.get("scene", "")) != scene or not session.peers.has(peer):
			continue
		var col := session.peer_color(peer)
		var nm := session.peer_name(peer)
		# selection outlines
		if show_selection:
			for uid in s.get("sel", []):
				var n := scenes.node_for(scene, String(uid))
				_draw_selection_2d(overlay, n, xf, col)
		if show_pointers and s.has("p2"):
			var sp: Vector2 = xf * (s["p2"] as Vector2)
			var pts := PackedVector2Array([sp, sp + Vector2(0, 17), sp + Vector2(5, 13), sp + Vector2(11, 12)])
			overlay.draw_colored_polygon(pts, col)
			overlay.draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(0, 0, 0, 0.6), 1.0, true)
			var w := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x + 10
			overlay.draw_rect(Rect2(sp + Vector2(12, 14), Vector2(w, fsize + 5)), col)
			overlay.draw_string(font, sp + Vector2(17, 14 + fsize), nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.05, 0.05, 0.08))

func _draw_selection_2d(overlay: Control, n: Node, xf: Transform2D, col: Color) -> void:
	if n == null or not is_instance_valid(n) or not n.is_inside_tree():
		return
	if n is Control:
		var c := n as Control
		var m: Transform2D = c.get_global_transform()
		var pts := PackedVector2Array([m * Vector2.ZERO, m * Vector2(c.size.x, 0), m * c.size, m * Vector2(0, c.size.y), m * Vector2.ZERO])
		for i in pts.size():
			pts[i] = xf * pts[i]
		overlay.draw_polyline(pts, col, 2.0, true)
		return
	if n is Node2D:
		var c2: Vector2 = xf * (n as Node2D).global_position
		overlay.draw_arc(c2, 14.0, 0.0, TAU, 28, col, 2.0, true)
		overlay.draw_line(c2 - Vector2(18, 0), c2 + Vector2(18, 0), col, 1.5)
		overlay.draw_line(c2 - Vector2(0, 18), c2 + Vector2(0, 18), col, 1.5)

func draw_3d(overlay: Control) -> void:
	if not enabled or not session.is_active_session or not show_pointers:
		return
	var vp3 := EditorInterface.get_editor_viewport_3d(0)
	if vp3 == null:
		return
	var cam := vp3.get_camera_3d()
	if cam == null:
		return
	var scene := _current_scene_path()
	var font := overlay.get_theme_default_font()
	for peer in peers_state:
		var s: Dictionary = peers_state[peer]
		if String(s.get("scene", "")) != scene or not s.has("cam") or not session.peers.has(peer):
			continue
		var t: Transform3D = s["cam"]
		var pos: Vector3 = t.origin
		if cam.is_position_behind(pos):
			continue
		var sp := cam.unproject_position(pos)
		var col := session.peer_color(peer)
		overlay.draw_circle(sp, 7.0, col)
		overlay.draw_arc(sp, 9.0, 0.0, TAU, 20, Color(0, 0, 0, 0.6), 1.5, true)
		# where they are looking
		var ahead := pos + (-t.basis.z) * 2.0
		if not cam.is_position_behind(ahead):
			overlay.draw_line(sp, cam.unproject_position(ahead), col, 2.0, true)
		var nm := session.peer_name(peer)
		overlay.draw_string(font, sp + Vector2(10, -8), nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)
	if show_selection:
		for peer2 in peers_state:
			var s2: Dictionary = peers_state[peer2]
			if String(s2.get("scene", "")) != scene or not session.peers.has(peer2):
				continue
			for uid in s2.get("sel", []):
				var n := scenes.node_for(scene, String(uid))
				if n is Node3D and is_instance_valid(n) and n.is_inside_tree():
					var p3 := (n as Node3D).global_position
					if not cam.is_position_behind(p3):
						overlay.draw_arc(cam.unproject_position(p3), 12.0, 0.0, TAU, 24, session.peer_color(peer2), 2.0, true)

# ====================================================================== scene dock highlights

var _scene_tree_cache: Tree = null

## The Scene dock Tree (found once, then cached while it exists).
func _find_scene_tree() -> Tree:
	if _scene_tree_cache != null and is_instance_valid(_scene_tree_cache) and _scene_tree_cache.is_inside_tree():
		return _scene_tree_cache
	_scene_tree_cache = _find_tree_in(EditorInterface.get_base_control())
	return _scene_tree_cache

func _find_tree_in(n: Node) -> Tree:
	if n.get_class() == "SceneTreeEditor":
		for c in n.get_children():
			if c is Tree:
				return c
	for c in n.get_children():
		var r := _find_tree_in(c)
		if r != null:
			return r
	return null

func _clear_tree_highlights() -> void:
	for e in _highlighted:
		var item: TreeItem = e[0]
		if is_instance_valid(item):
			item.clear_custom_bg_color(0)
	_highlighted.clear()

func _update_tree_highlights() -> void:
	_clear_tree_highlights()
	if not show_selection:
		return
	var tree := _find_scene_tree()
	if tree == null:
		return
	var scene := _current_scene_path()
	var wanted: Dictionary = {}   # node path string -> color
	for peer in peers_state:
		var s: Dictionary = peers_state[peer]
		if String(s.get("scene", "")) != scene or not session.peers.has(peer):
			continue
		for uid in s.get("sel", []):
			var n := scenes.node_for(scene, String(uid))
			if n != null and is_instance_valid(n) and n.is_inside_tree():
				wanted[str(n.get_path())] = Color(session.peer_color(peer), 0.35)
	if wanted.is_empty():
		return
	var root := tree.get_root()
	if root != null:
		_walk_tree(root, wanted)

func _walk_tree(item: TreeItem, wanted: Dictionary) -> void:
	var md: Variant = item.get_metadata(0)
	if md != null and wanted.has(str(md)):
		item.set_custom_bg_color(0, wanted[str(md)])
		_highlighted.append([item, null])
	var c := item.get_first_child()
	while c != null:
		_walk_tree(c, wanted)
		c = c.get_next()
