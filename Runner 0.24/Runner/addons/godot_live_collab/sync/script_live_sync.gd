@tool
class_name GLCScriptLiveSync
extends RefCounted
## Live text editing of the scripts/shaders/text files open in the script editor.
##
## * The host holds the authoritative text + revision history of every shared document
##   (GLCTextOT.Server); every other peer runs a Jupiter client state machine (GLCTextOT.Client).
##   This is what makes simultaneous typing, even at the very same position, converge.
## * Remote edits are applied to the CodeEdit as *minimal* insert_text / remove_text calls, so your
##   caret, selection, scroll position and undo history are preserved (no more `text = ...`).
## * Remote carets and selections are drawn on top of the CodeEdit and follow the text as it changes.

signal activity(text: String)
signal saved_remotely(path: String)

const MAX_DOC_CHARS := 1_500_000
const SCAN_INTERVAL := 0.3
const CURSOR_INTERVAL_MS := 70

var session: GLCSessionManager
var plugin: EditorPlugin
var enabled: bool = true
var verbose: bool = false

var docs: Dictionary = {}           # path -> Doc (a CodeEdit is bound on this machine)
var server_docs: Dictionary = {}    # host: path -> GLCTextOT.Server
var _scan_accum: float = 0.0
var _last_cursor_ms: int = 0
var _saving_remote: bool = false
var _last_saved_hash: Dictionary = {}
## path -> {hash, until}: a save announced by someone else while our copy was not identical yet
## (concurrent typing in flight); retried for a moment until the texts converge.
var _pending_saves: Dictionary = {}
const SAVE_RETRY_MS := 2500
var _too_big: Dictionary = {}       # paths already reported as too large for live editing
var stats: Dictionary = {"ops_sent": 0, "ops_received": 0, "resyncs": 0}

class Doc extends RefCounted:
	var path: String = ""
	var editor: CodeEdit = null
	var client: GLCTextOT.Client = GLCTextOT.Client.new()
	var shadow: String = ""             # text the document model believes the editor contains
	var state: String = "new"           # new | waiting | synced
	var applying: bool = false
	var cursors: Dictionary = {}        # peer id -> {idx, from, to}
	var starts: PackedInt32Array = PackedInt32Array()
	var starts_dirty: bool = true
	var last_caret_sig: String = ""
	var connections: Array = []         # [signal, callable] pairs to disconnect later
	var was_editable: bool = true

func _init(p_session: GLCSessionManager, p_plugin: EditorPlugin) -> void:
	session = p_session
	plugin = p_plugin
	session.register(GLCProtocol.D_OPEN, _on_d_open, "direct")
	session.register(GLCProtocol.D_STATE, _on_d_state, "direct")
	session.register(GLCProtocol.D_CLOSE, _on_d_close, "direct")
	session.register(GLCProtocol.D_OP, _on_d_op, "op", {"scope": "doc"})
	session.register(GLCProtocol.D_CURSOR, _on_d_cursor, "bcast", {"scope": "doc", "reliable": false})
	session.register(GLCProtocol.D_SAVED, _on_d_saved, "bcast", {"scope": "doc"})
	session.session_started.connect(func(_h):
		server_docs.clear()
		_last_saved_hash.clear()
		_pending_saves.clear()
		_scan_accum = 1.0)
	session.session_ended.connect(func(_r):
		_unbind_all(false)
		# authoritative texts belong to that session only
		server_docs.clear()
		_pending_saves.clear())
	session.peer_left.connect(_on_peer_left)

func stop() -> void:
	_unbind_all(false)
	server_docs.clear()

# ====================================================================== editor discovery

func process(delta: float) -> void:
	if not session.is_active_session:
		return
	if not enabled:
		if not docs.is_empty():
			_unbind_all(true)
		return
	_scan_accum += delta
	if _scan_accum >= SCAN_INTERVAL:
		_scan_accum = 0.0
		_scan_editors()
	if not _pending_saves.is_empty():
		_retry_pending_saves()

func is_live_managed(path: String) -> bool:
	return docs.has(path)

func open_paths() -> Array:
	return docs.keys()

func _scan_editors() -> void:
	var se := EditorInterface.get_script_editor()
	if se == null:
		return
	var scripts: Array = se.get_open_scripts()
	var eds: Array = se.get_open_script_editors()
	var pairs: Array = []
	if scripts.size() == eds.size():
		for i in scripts.size():
			pairs.append([scripts[i], eds[i]])
	# the visible tab is always a certain pair (a text file or docs tab makes index pairing ambiguous)
	var cs := se.get_current_script()
	var cur_ed := se.get_current_editor()
	if cs != null and cur_ed != null:
		pairs.append([cs, cur_ed])
	var live := {}
	for pr in pairs:
		var scr: Script = pr[0]
		if scr == null or pr[1] == null:
			continue
		var base: Control = (pr[1] as ScriptEditorBase).get_base_editor()
		var path := scr.resource_path
		if path.is_empty() or path.contains("::") or not GLCProtocol.is_syncable_path(path) or not (base is CodeEdit):
			continue
		var bound: Doc = docs.get(path, null)
		var already := bound != null and bound.editor == base
		if not already and (base as CodeEdit).text.is_empty() and not scr.source_code.is_empty():
			continue   # tab not filled in yet (lazy loading): bind it on a later scan
		live[path] = true
		var d: Doc = docs.get(path, null)
		if d == null or d.editor != base:
			if d != null:
				_unbind(path, true)
			_bind(path, base as CodeEdit)
	if scripts.size() == eds.size():
		for path in docs.keys():
			if not live.has(path):
				_unbind(path, true)
	else:
		for path in docs.keys():
			var d2: Doc = docs[path]
			if d2.editor == null or not is_instance_valid(d2.editor):
				_unbind(path, true)

# ====================================================================== bind / unbind

func _bind(path: String, ce: CodeEdit) -> void:
	if ce.text.length() > MAX_DOC_CHARS:
		if not _too_big.has(path):
			_too_big[path] = true
			activity.emit("%s é grande demais para edição ao vivo (limite %d caracteres)" % [path.get_file(), MAX_DOC_CHARS])
		return
	_too_big.erase(path)
	var d := Doc.new()
	d.path = path
	d.editor = ce
	d.shadow = ce.text
	d.was_editable = ce.editable
	docs[path] = d
	var cb_text := Callable(self, "_on_local_change").bind(path)
	var cb_caret := Callable(self, "_on_caret").bind(path)
	var cb_draw := Callable(self, "_on_draw").bind(path)
	ce.text_changed.connect(cb_text)
	ce.text_set.connect(cb_text)
	ce.caret_changed.connect(cb_caret)
	ce.draw.connect(cb_draw)
	d.connections = [[ce.text_changed, cb_text], [ce.text_set, cb_text], [ce.caret_changed, cb_caret], [ce.draw, cb_draw]]
	if session.is_hosting:
		var sd: GLCTextOT.Server = server_docs.get(path, null)
		if sd == null:
			sd = GLCTextOT.Server.new()
			sd.text = d.shadow
			server_docs[path] = sd
		elif sd.text != d.shadow:
			_replace_text(d, sd.text)
		d.state = "synced"
	else:
		_begin_wait(d)
		session.subscribe("doc:" + path)
		session.send_to(1, GLCProtocol.D_OPEN, {"path": path, "text": d.shadow})

## While the shared text is on its way (a few ms on a LAN) typing would be lost, so the editor is
## read-only for that moment.
func _begin_wait(d: Doc) -> void:
	d.state = "waiting"
	if d.editor != null and is_instance_valid(d.editor) and d.editor.editable:
		d.was_editable = true
		d.editor.editable = false

func _end_wait(d: Doc) -> void:
	if d.editor != null and is_instance_valid(d.editor) and d.was_editable:
		d.editor.editable = true

func _unbind(path: String, notify: bool) -> void:
	var d: Doc = docs.get(path, null)
	if d == null:
		return
	docs.erase(path)
	if d.state == "waiting":
		_end_wait(d)
	for pair in d.connections:
		var sig: Signal = pair[0]
		var cb: Callable = pair[1]
		if d.editor != null and is_instance_valid(d.editor) and sig.is_connected(cb):
			sig.disconnect(cb)
	if d.editor != null and is_instance_valid(d.editor):
		d.editor.queue_redraw()
	if notify and session.is_active_session and not session.is_hosting:
		session.unsubscribe("doc:" + path)
		session.send_to(1, GLCProtocol.D_CLOSE, {"path": path})
	if session.is_hosting:
		_maybe_drop_server_doc(path)

func _unbind_all(notify: bool) -> void:
	for path in docs.keys():
		_unbind(path, notify)

func _maybe_drop_server_doc(path: String) -> void:
	if docs.has(path):
		return
	if session.subscribers_of("doc:" + path).is_empty():
		server_docs.erase(path)

func _on_peer_left(peer_id: int, _info: Dictionary) -> void:
	for d in docs.values():
		(d as Doc).cursors.erase(peer_id)
		if d.editor != null and is_instance_valid(d.editor):
			d.editor.queue_redraw()
	for path in server_docs.keys():
		_maybe_drop_server_doc(path)

# ====================================================================== handshake

func _on_d_open(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not session.is_hosting:
		return
	var path := String(p.get("path", ""))
	if not GLCProtocol.is_syncable_path(path):
		return
	var sd: GLCTextOT.Server = server_docs.get(path, null)
	var hd: Doc = docs.get(path, null)
	if hd != null:
		_flush_local(hd)
	if sd == null:
		sd = GLCTextOT.Server.new()
		# nobody has it open yet: the host's saved file is the reference ("host wins", like the file
		# reconcile); the client's buffer is only used for files the host does not have
		if FileAccess.file_exists(path):
			sd.text = FileAccess.get_file_as_string(path).replace("\r\n", "\n")
		else:
			sd.text = String(p.get("text", ""))
		server_docs[path] = sd
	session.send_to(sender, GLCProtocol.D_STATE, {"path": path, "text": sd.text, "rev": sd.revision()})

func _on_d_close(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if session.is_hosting:
		var path := String(p.get("path", ""))
		(session._subs.get("doc:" + path, {}) as Dictionary).erase(sender)
		_maybe_drop_server_doc(path)

func _on_d_state(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if session.is_hosting or sender != 1:
		return   # only the host hands out document states
	var path := String(p.get("path", ""))
	var d: Doc = docs.get(path, null)
	if d == null:
		return
	d.client.reset(int(p.get("rev", 0)))
	var text := String(p.get("text", ""))
	if d.editor.text != text:
		_replace_text(d, text)
	d.shadow = text
	d.state = "synced"
	_end_wait(d)
	d.starts_dirty = true
	d.editor.queue_redraw()

func _resync_doc(d: Doc, why: String) -> void:
	stats["resyncs"] += 1
	if verbose:
		push_warning("[GLC] ressincronizando script %s (%s)" % [d.path, why])
	if session.is_hosting:
		var sd: GLCTextOT.Server = server_docs.get(d.path, null)
		if sd != null:
			_replace_text(d, sd.text)
			d.shadow = sd.text
		return
	_begin_wait(d)
	session.send_to(1, GLCProtocol.D_OPEN, {"path": d.path, "text": d.shadow})

# ====================================================================== local edits

func _on_local_change(path: String) -> void:
	var d: Doc = docs.get(path, null)
	if d == null or d.applying or d.state != "synced":
		return
	_flush_local(d)

## Turn whatever the user typed since the last flush into one operation.
func _flush_local(d: Doc) -> void:
	if d.state != "synced" or d.editor == null or not is_instance_valid(d.editor):
		return
	var cur := d.editor.text
	if cur == d.shadow:
		return
	if cur.length() > MAX_DOC_CHARS:
		return
	var op := GLCTextOT.from_diff(d.shadow, cur)
	d.shadow = cur
	d.starts_dirty = true
	_shift_cursors(d, op)
	if session.is_hosting:
		var sd: GLCTextOT.Server = server_docs.get(d.path, null)
		if sd == null:
			return
		var applied := sd.apply_local(op)
		if applied == null:
			_resync_doc(d, "host server rejected local op")
			return
		stats["ops_sent"] += 1
		session.submit(0, GLCProtocol.D_OP, {"path": d.path, "rev": sd.revision(), "op": applied.to_array()})
	else:
		var to_send := d.client.apply_local(op)
		if to_send != null:
			_send_op(d, to_send)

func _send_op(d: Doc, op: GLCTextOT) -> void:
	stats["ops_sent"] += 1
	var id := session.next_op_id()
	session.submit(id, GLCProtocol.D_OP, {"path": d.path, "rev": d.client.revision, "op": op.to_array()},
		Callable(self, "_on_ack").bind(d.path), Callable(self, "_on_rej").bind(d.path))

func _on_ack(_corr: Variant, _seq: int, path: String) -> void:
	var d: Doc = docs.get(path, null)
	if d == null:
		return
	var nxt := d.client.server_ack()
	if nxt != null:
		_send_op(d, nxt)

func _on_rej(reason: String, path: String) -> void:
	var d: Doc = docs.get(path, null)
	if d != null:
		_resync_doc(d, "rejected: " + reason)

# ====================================================================== remote edits

func _on_d_op(sender: int, p: Dictionary, meta: Dictionary) -> Variant:
	stats["ops_received"] += 1
	var path := String(p.get("path", ""))
	var op := GLCTextOT.from_array(p.get("op", []))
	if meta["stage"] == "host":
		var sd: GLCTextOT.Server = server_docs.get(path, null)
		if sd == null:
			meta["reason"] = "nodoc"
			return null
		var hd: Doc = docs.get(path, null)
		if hd != null:
			_flush_local(hd)
		var applied := sd.receive(int(p.get("rev", 0)), op)
		if applied == null:
			meta["reason"] = "resync"
			return null
		if hd != null:
			_apply_op(hd, applied)
		return {"path": path, "rev": sd.revision(), "op": applied.to_array()}
	var d: Doc = docs.get(path, null)
	if d == null or d.state != "synced":
		return null
	_flush_local(d)
	var local_op := d.client.apply_server(op)
	if local_op.base_length != d.shadow.length():
		_resync_doc(d, "length mismatch")
		return null
	_apply_op(d, local_op)
	return null

static func _hunks_of(op: GLCTextOT) -> Array:
	var hunks: Array = []
	var pos := 0
	var cur: Variant = null
	for c in op.ops:
		if GLCTextOT.is_retain(c):
			cur = null
			pos += int(c)
		elif GLCTextOT.is_insert(c):
			if cur == null:
				cur = {"pos": pos, "del": 0, "ins": ""}
				hunks.append(cur)
			cur["ins"] = String(cur["ins"]) + String(c)
		else:
			if cur == null:
				cur = {"pos": pos, "del": 0, "ins": ""}
				hunks.append(cur)
			cur["del"] = int(cur["del"]) + (-int(c))
			pos += -int(c)
	return hunks

## Our carets / selections (and the first visible line) as text indices, before a remote edit.
static func _save_view(ce: CodeEdit, text: String, starts: PackedInt32Array) -> Dictionary:
	var carets: Array = []
	for i in ce.get_caret_count():
		var idx := _lc_to_index(text, starts, ce.get_caret_line(i), ce.get_caret_column(i))
		var origin := -1
		if ce.has_selection(i):
			origin = _lc_to_index(text, starts, ce.get_selection_origin_line(i), ce.get_selection_origin_column(i))
		carets.append([idx, origin])
	var first := ce.get_first_visible_line()
	return {"carets": carets, "anchor": _lc_to_index(text, starts, first, 0), "first": first}

## Puts our carets back where they belong in the new text. A remote insertion exactly at our caret
## stays AFTER the caret (we keep typing our own word, and the other person keeps typing theirs: no
## interleaved letters when both type at the same spot); text inserted above keeps the view still.
static func _restore_view(ce: CodeEdit, view: Dictionary, op: GLCTextOT, new_text: String) -> void:
	var ns := _line_starts(new_text)
	var carets: Array = view["carets"]
	for i in mini(carets.size(), ce.get_caret_count()):
		var idx: int = carets[i][0]
		var origin: int = carets[i][1]
		if origin < 0 or origin == idx:
			var p := _index_to_lc(ns, op.transform_index(idx, false))
			ce.deselect(i)
			ce.set_caret_line(p.x, false, true, 0, i)
			ce.set_caret_column(p.y, false, i)
		else:
			# the selection does not grow with text typed at its edges
			var s := op.transform_index(mini(origin, idx), true)
			var e := maxi(op.transform_index(maxi(origin, idx), false), s)
			var a := _index_to_lc(ns, s if origin < idx else e)
			var b := _index_to_lc(ns, e if origin < idx else s)
			ce.select(a.x, a.y, b.x, b.y, i)
	var anchor: int = view["anchor"]
	var moved := op.transform_index(anchor, false)
	if moved != anchor:
		var line := _index_to_lc(ns, moved).x
		if line != ce.get_first_visible_line():
			ce.set_line_as_first_visible(line)

## Apply an operation to the CodeEdit using minimal edits (undo history and caret survive).
func _apply_op(d: Doc, op: GLCTextOT) -> void:
	if d.editor == null or not is_instance_valid(d.editor) or op.is_noop():
		return
	var old := d.shadow
	var ce := d.editor
	var starts := _line_starts(old)
	var hunks := _hunks_of(op)
	var in_sync := ce.text == old
	var view := _save_view(ce, old, starts) if in_sync else {}
	d.applying = true
	ce.begin_complex_operation()
	for i in range(hunks.size() - 1, -1, -1):
		var h: Dictionary = hunks[i]
		var a := _index_to_lc(starts, int(h["pos"]))
		if int(h["del"]) > 0:
			var b := _index_to_lc(starts, int(h["pos"]) + int(h["del"]))
			ce.remove_text(a.x, a.y, b.x, b.y)
		if String(h["ins"]) != "":
			ce.insert_text(String(h["ins"]), a.x, a.y)
	ce.end_complex_operation()
	d.shadow = op.apply(old)
	if in_sync and ce.text == d.shadow:
		_restore_view(ce, view, op, d.shadow)
		d.last_caret_sig = ""   # our caret may sit on the other side of their text now: publish it again
	d.applying = false
	d.starts_dirty = true
	_shift_cursors(d, op)
	if ce.text != d.shadow:
		# should never happen; recover rather than diverge silently
		_resync_doc(d, "editor text differs after applying op")
		if session.is_hosting or d.state != "waiting":
			_replace_text(d, d.shadow)
	ce.queue_redraw()

## Replace the whole text through a minimal diff (used for initial state / recovery).
func _replace_text(d: Doc, new_text: String) -> void:
	if d.editor == null or not is_instance_valid(d.editor):
		return
	var old := d.editor.text
	var op := GLCTextOT.from_diff(old, new_text)
	var save_shadow := d.shadow
	d.shadow = old
	d.applying = true
	_apply_op_raw(d, op, old)
	d.applying = false
	d.shadow = new_text
	if d.editor.text != new_text:
		d.applying = true
		d.editor.text = new_text
		d.applying = false
	d.starts_dirty = true

func _apply_op_raw(d: Doc, op: GLCTextOT, old: String) -> void:
	var starts := _line_starts(old)
	var hunks: Array = []
	var pos := 0
	var cur: Variant = null
	for c in op.ops:
		if GLCTextOT.is_retain(c):
			cur = null
			pos += int(c)
		elif GLCTextOT.is_insert(c):
			if cur == null:
				cur = {"pos": pos, "del": 0, "ins": ""}
				hunks.append(cur)
			cur["ins"] = String(cur["ins"]) + String(c)
		else:
			if cur == null:
				cur = {"pos": pos, "del": 0, "ins": ""}
				hunks.append(cur)
			cur["del"] = int(cur["del"]) + (-int(c))
			pos += -int(c)
	for i in range(hunks.size() - 1, -1, -1):
		var h: Dictionary = hunks[i]
		var a := _index_to_lc(starts, int(h["pos"]))
		if int(h["del"]) > 0:
			var b := _index_to_lc(starts, int(h["pos"]) + int(h["del"]))
			d.editor.remove_text(a.x, a.y, b.x, b.y)
		if String(h["ins"]) != "":
			d.editor.insert_text(String(h["ins"]), a.x, a.y)

static func _line_starts(text: String) -> PackedInt32Array:
	var starts := PackedInt32Array([0])
	var idx := 0
	var n := text.length()
	var i := text.find("\n")
	while i != -1:
		starts.append(i + 1)
		i = text.find("\n", i + 1)
	return starts

static func _index_to_lc(starts: PackedInt32Array, idx: int) -> Vector2i:
	var lo := 0
	var hi := starts.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if starts[mid] <= idx:
			lo = mid
		else:
			hi = mid - 1
	return Vector2i(lo, idx - starts[lo])

static func _lc_to_index(text: String, starts: PackedInt32Array, line: int, col: int) -> int:
	line = clampi(line, 0, starts.size() - 1)
	return mini(starts[line] + col, text.length())

# ====================================================================== carets & selections

func _on_caret(path: String) -> void:
	var d: Doc = docs.get(path, null)
	if d == null or d.state != "synced" or d.applying:
		return
	var now := Time.get_ticks_msec()
	if now - _last_cursor_ms < CURSOR_INTERVAL_MS:
		# retry shortly: the final caret position must always get through
		d.last_caret_sig = ""
		return
	_send_caret(d)

func _send_caret(d: Doc) -> void:
	var ce := d.editor
	if ce == null or not is_instance_valid(ce):
		return
	_flush_local(d)
	var starts := _line_starts(d.shadow)
	var idx := _lc_to_index(d.shadow, starts, ce.get_caret_line(), ce.get_caret_column())
	var from := idx
	var to := idx
	if ce.has_selection():
		from = _lc_to_index(d.shadow, starts, ce.get_selection_from_line(), ce.get_selection_from_column())
		to = _lc_to_index(d.shadow, starts, ce.get_selection_to_line(), ce.get_selection_to_column())
	var sig := "%d,%d,%d" % [idx, from, to]
	if sig == d.last_caret_sig:
		return
	d.last_caret_sig = sig
	_last_cursor_ms = Time.get_ticks_msec()
	session.bcast(GLCProtocol.D_CURSOR, {"path": d.path, "idx": idx, "from": from, "to": to})

## Flush a pending (throttled) caret update; called every frame.
func process_carets() -> void:
	if not enabled or not session.is_active_session:
		return
	if Time.get_ticks_msec() - _last_cursor_ms < CURSOR_INTERVAL_MS:
		return
	var focused := EditorInterface.get_script_editor().get_current_editor()
	if focused == null:
		return
	for d in docs.values():
		if d.editor == focused.get_base_editor() and d.state == "synced" and d.last_caret_sig == "":
			_send_caret(d)

func _on_d_cursor(sender: int, p: Dictionary, meta: Dictionary) -> void:
	var path := String(p.get("path", ""))
	var d: Doc = docs.get(path, null)
	if d == null:
		return
	var origin := int(meta.get("origin", sender))
	d.cursors[origin] = {"idx": int(p.get("idx", 0)), "from": int(p.get("from", 0)), "to": int(p.get("to", 0)), "t": Time.get_ticks_msec()}
	if d.editor != null and is_instance_valid(d.editor):
		d.editor.queue_redraw()

func _shift_cursors(d: Doc, op: GLCTextOT) -> void:
	for k in d.cursors:
		var c: Dictionary = d.cursors[k]
		c["idx"] = op.transform_index(int(c["idx"]), true)
		c["from"] = op.transform_index(int(c["from"]), false)
		c["to"] = op.transform_index(int(c["to"]), true)

## (line, column) that is always valid for this CodeEdit: calling get_rect_at_line_column() with an
## out-of-range column makes the engine print an error on every redraw.
static func _clamp_lc(ce: CodeEdit, lc: Vector2i) -> Vector2i:
	var line := clampi(lc.x, 0, maxi(ce.get_line_count() - 1, 0))
	return Vector2i(line, clampi(lc.y, 0, ce.get_line(line).length()))

func _on_draw(path: String) -> void:
	var d: Doc = docs.get(path, null)
	if d == null or d.cursors.is_empty() or d.state != "synced" or d.applying:
		return
	var ce := d.editor
	if ce == null or not is_instance_valid(ce):
		return
	if d.starts_dirty:
		d.starts = _line_starts(d.shadow)
		d.starts_dirty = false
	var font := ce.get_theme_default_font()
	var fsize := maxi(ce.get_theme_default_font_size() - 3, 8)
	var nlines := ce.get_line_count()
	var first := clampi(ce.get_first_visible_line(), 0, maxi(nlines - 1, 0))
	var last := clampi(ce.get_last_full_visible_line() + 1, 0, maxi(nlines - 1, 0))
	var text_len := d.shadow.length()
	for peer in d.cursors:
		var c: Dictionary = d.cursors[peer]
		var col: Color = session.peer_color(peer)
		var name := session.peer_name(peer)
		var lc := _clamp_lc(ce, _index_to_lc(d.starts, clampi(int(c["idx"]), 0, text_len)))
		# selection
		if int(c["from"]) != int(c["to"]):
			var a := _clamp_lc(ce, _index_to_lc(d.starts, clampi(mini(int(c["from"]), int(c["to"])), 0, text_len)))
			var b := _clamp_lc(ce, _index_to_lc(d.starts, clampi(maxi(int(c["from"]), int(c["to"])), 0, text_len)))
			var sel_col := Color(col, 0.22)
			for ln in range(maxi(a.x, first), mini(b.x, last) + 1):
				var line_len := ce.get_line(ln).length()
				var c0 := clampi(a.y if ln == a.x else 0, 0, line_len)
				var c1 := clampi(b.y if ln == b.x else line_len, 0, line_len)
				var r0 := ce.get_rect_at_line_column(ln, c0)
				var r1 := ce.get_rect_at_line_column(ln, c1)
				if r0.position.x < 0 or r0.position.y < 0:
					continue
				var w := r1.position.x - r0.position.x if r1.position.x >= 0 else 0
				if ln != b.x:
					w += 6   # the selected line break
				ce.draw_rect(Rect2(r0.position.x, r0.position.y, maxi(w, 2), r0.size.y), sel_col)
		if lc.x < first or lc.x > last:
			continue
		var rect := ce.get_rect_at_line_column(lc.x, lc.y)
		if rect.position.x < 0 or rect.position.y < 0:
			continue
		ce.draw_rect(Rect2(rect.position.x, rect.position.y, 2, rect.size.y), col)
		var tag_w := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x + 8
		var tag_pos := Vector2(rect.position.x, maxf(rect.position.y - fsize - 4, 0))
		ce.draw_rect(Rect2(tag_pos.x, tag_pos.y, tag_w, fsize + 4), col)
		ce.draw_string(font, Vector2(tag_pos.x + 4, tag_pos.y + fsize), name, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.05, 0.05, 0.08))

# ====================================================================== save propagation

## Called when the editor saved a script (resource_saved).
func on_resource_saved(res: Resource) -> void:
	if _saving_remote or not (res is Script):
		return
	var path := res.resource_path
	var d: Doc = docs.get(path, null)
	if d == null or d.state != "synced":
		return
	_flush_local(d)
	var h := d.shadow.hash()
	if int(_last_saved_hash.get(path, 0)) == h:
		return
	_last_saved_hash[path] = h
	session.bcast(GLCProtocol.D_SAVED, {"path": path, "hash": h})

func _on_d_saved(_sender: int, p: Dictionary, _meta: Dictionary) -> void:
	var path := String(p.get("path", ""))
	var d: Doc = docs.get(path, null)
	if d == null or d.state != "synced":
		return
	_flush_local(d)
	var h := int(p.get("hash", 0))
	if d.shadow.hash() != h:
		# not identical yet (operations still in flight): try again for a moment
		_pending_saves[path] = {"hash": h, "until": Time.get_ticks_msec() + SAVE_RETRY_MS}
		return
	_save_for_remote(path, h)

## Saves THIS script only (never your other unsaved scripts): the shared text is written through the
## Script resource the editor is showing, and the tab is marked as saved. Going through ResourceSaver
## keeps the editor's bookkeeping right, so no "file changed on disk, reload?" prompt appears later.
func _save_for_remote(path: String, h: int, record: bool = true) -> void:
	_pending_saves.erase(path)
	var d: Doc = docs.get(path, null)
	if d == null or d.editor == null or not is_instance_valid(d.editor):
		return
	var scr: Variant = load(path)
	if not (scr is Script):
		return
	_saving_remote = true
	(scr as Script).source_code = d.editor.text
	var err := ResourceSaver.save(scr, path)
	_saving_remote = false
	if err != OK:
		activity.emit("Não foi possível salvar %s (%s)" % [path.get_file(), error_string(err)])
		return
	d.editor.tag_saved_version()
	if record:
		_last_saved_hash[path] = h
	saved_remotely.emit(path)

func _retry_pending_saves() -> void:
	var now := Time.get_ticks_msec()
	for path in _pending_saves.keys():
		var e: Dictionary = _pending_saves[path]
		var d: Doc = docs.get(path, null)
		if d == null:
			_pending_saves.erase(path)
			continue
		if d.state != "synced":
			continue
		_flush_local(d)
		if d.shadow.hash() == int(e["hash"]):
			_save_for_remote(path, int(e["hash"]))
		elif now > int(e["until"]):
			# people kept typing, so the exact saved text will never exist here: save the current
			# (merged) text anyway, which is what "someone pressed save" means for everybody
			_save_for_remote(path, d.shadow.hash(), false)   # (a later Ctrl+S here is still announced)

# ====================================================================== introspection

func doc_state(path: String) -> String:
	var d: Doc = docs.get(path, null)
	return d.state if d != null else "none"

func doc_text(path: String) -> String:
	var d: Doc = docs.get(path, null)
	return d.editor.text if d != null and d.editor != null else ""
