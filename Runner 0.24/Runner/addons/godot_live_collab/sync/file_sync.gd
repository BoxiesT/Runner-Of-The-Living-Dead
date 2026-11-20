@tool
class_name GLCFileSync
extends RefCounted
## Mirrors the project folder (res://) between peers, like a shared directory.
##
## * Everything flows through the host: a change is announced with a tiny *notice*; whoever needs the
##   bytes *pulls* them (the host pulls from the author first). Large files are chunked and drained on a
##   separate ENet channel, so the live editing channel is never starved.
## * Folders are mirrored too (including empty ones): creating, removing and renaming folders replicates.
## * Joining: the client compares the host's manifest with its own. Missing/different files are pulled
##   (host wins, the client's old copy is kept in res://.glc_backup/), files and folders only the client has
##   are pushed to the host. NOTHING is deleted during the initial reconcile.
## * Afterwards, creates / edits / renames / deletes are detected by a time-sliced scanner (a few times per
##   second, plus immediately after the editor reports a filesystem change) and replicated.
##   Deletions and overwrites always keep a copy in res://.glc_backup/<session>/.
## * Files that are open in the editor (scenes, scripts) are owned by the live layer: their bytes are not
##   overwritten / deleted under your cursor; that happens when you close them.

signal activity(text: String)
signal file_arrived(path: String)
## A file changed on this disk without this editor saving it (external tool, git checkout...).
signal local_file_changed(path: String)
signal progress_changed()

const CHUNK := 192 * 1024
const MAX_FILE_BYTES := 128 * 1024 * 1024
const SCAN_BUDGET_US := 3500
const SCAN_PAUSE_MIN_S := 0.3
const SCAN_PAUSE_MAX_S := 2.5
const STABLE_SCANS := 2
## FileAccess.get_modified_time() has a 1 second resolution: files touched this recently are compared by
## size + content hash, so two saves within the same second are never missed.
const HOT_SECONDS := 3
const HOT_HASH_LIMIT := 2 * 1024 * 1024
## A pull that got no answer for this long may be requested again (sender left, transfer lost...).
const WANT_TIMEOUT_MS := 20000
## A brand-new asset waits (at most this long) for the .import / .uid file the editor writes next to it,
## so every machine ends up with the *same* uid instead of generating its own.
const SIDECAR_WAIT_MS := 4000
const FS_REFRESH_QUIET_MS := 300
const FS_REFRESH_MAX_WAIT_MS := 3000
const BACKUP_DIR := "res://.glc_backup"
const CACHE_FILE := "res://.godot/glc_manifest_cache.json"
const OUT_BACKLOG_LIMIT := 4 * 1024 * 1024
## Files up to this size travel inside their change notice (scripts, scenes, most resources).
const INLINE_LIMIT := 128 * 1024
const IMPORT_EXTS := ["png", "jpg", "jpeg", "webp", "svg", "tga", "bmp", "hdr", "exr", "dds", "ktx", "ktx2",
	"wav", "ogg", "mp3", "glb", "gltf", "fbx", "obj", "blend", "dae", "ttf", "otf", "woff", "woff2", "fnt", "font"]
const UID_EXTS := ["gd", "cs", "gdshader", "gdshaderinc"]

var session: GLCSessionManager
var plugin: EditorPlugin
## Turning it back on during a session re-indexes and reconciles with the host (changes made by others
## while it was off are fetched).
var enabled: bool = true:
	set(v):
		var was := enabled
		enabled = v
		if v and not was and session != null and session.is_active_session:
			_on_session_started(session.is_hosting)
var push_local_only: bool = true
var sidecars_first: bool = true
## func(path: String) -> bool : true if the file is open in the editor and owned by the live layer
var is_live_managed: Callable = Callable()

var manifest: Dictionary = {}          # path -> [sha256, size, mtime]   (what we last synced / know to be on disk)
var dirs: Dictionary = {}              # folder path -> true             (folders we know exist)
var baseline_done: bool = false
var reconcile_state: String = "idle"   # idle | waiting_manifest | pulling | done
var stats: Dictionary = {"bytes_out": 0, "bytes_in": 0, "files_in": 0, "files_out": 0, "backups": 0}

var _scan_stack: Array = []
var _scan_found: Dictionary = {}
var _scan_dirs: Dictionary = {}
var _scanning: bool = false
var _scan_wait: float = 0.0
var _scan_started_ms: int = 0
var _force_scan: bool = false
var _pending_change: Dictionary = {}   # path -> {sig, n, since}
var _missing_count: Dictionary = {}    # path -> consecutive scans without the file
var _dir_new: Dictionary = {}          # folder -> consecutive scans seen (not yet announced)
var _dir_missing: Dictionary = {}      # folder -> consecutive scans missing
var _incoming: Dictionary = {}         # path -> {hash, size, n, chunks, got, from}
var _deferred: Dictionary = {}         # path -> {hash, size, from}      (file is open here: pull later)
var _deferred_del: Dictionary = {}     # path -> sha256 at deletion time (file is open here: delete later)
var _want_sent: Dictionary = {}        # path -> hash
var _want_time: Dictionary = {}        # path -> ms when requested (or when data last arrived)
var _want_from: Dictionary = {}        # path -> peer asked
var _last_want_check_ms: int = 0
var _deferred_rmdir: Dictionary = {}   # folder -> true: removal waits for files still open here
var _last_rmdir_check_ms: int = 0
var _suspect: Dictionary = {}          # path -> true: large file touched twice in one mtime second
var _out_queue: Array = []             # [{peer, path}]
var _notice_queue: Array = []          # throttled notices for the initial push
var _fs_refresh_first_ms: int = 0
var _fs_refresh_last_ms: int = 0
var _backup_stamp: String = ""
var _cache: Dictionary = {}            # path -> [mtime, size, hash] persisted between sessions
var _cache_dirty: bool = false
var _last_cache_save_ms: int = 0
var _expected_pulls: int = 0
var _pulled: int = 0

func _init(p_session: GLCSessionManager, p_plugin: EditorPlugin) -> void:
	session = p_session
	plugin = p_plugin
	session.register(GLCProtocol.F_MANIFEST, _on_manifest, "direct")
	session.register(GLCProtocol.F_WANT, _on_want, "direct")
	session.register(GLCProtocol.F_DATA, _on_data, "direct")
	session.register(GLCProtocol.F_NOTICE, _on_notice, "direct")
	session.register(GLCProtocol.F_DEL, _on_delete, "direct")
	session.register(GLCProtocol.F_MOVE, _on_move, "direct")
	session.register(GLCProtocol.F_MKDIR, _on_mkdir, "direct")
	session.register(GLCProtocol.F_RMDIR, _on_rmdir, "direct")
	session.session_started.connect(_on_session_started)
	session.session_ended.connect(_on_session_ended)
	session.peer_left.connect(func(id, _info): drop_transfers_from(id))

func stop() -> void:
	_save_cache(true)

# ====================================================================== session

func _on_session_started(is_host: bool) -> void:
	_backup_stamp = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	baseline_done = false
	reconcile_state = "waiting_manifest" if not is_host else "done"
	manifest.clear()
	dirs.clear()
	_pending_change.clear()
	_missing_count.clear()
	_dir_new.clear()
	_dir_missing.clear()
	_incoming.clear()
	_deferred.clear()
	_deferred_del.clear()
	_want_sent.clear()
	_want_time.clear()
	_want_from.clear()
	_deferred_rmdir.clear()
	_suspect.clear()
	_editor_saved.clear()
	_out_queue.clear()
	_notice_queue.clear()
	_expected_pulls = 0
	_pulled = 0
	_load_cache()
	_start_scan(true)

func _on_session_ended(_reason: String) -> void:
	_scanning = false
	_scan_stack.clear()
	_out_queue.clear()
	_incoming.clear()
	_notice_queue.clear()
	reconcile_state = "idle"
	progress_changed.emit()

## True while `path` is being downloaded (or was asked for and has not arrived yet).
func is_receiving(path: String) -> bool:
	return _incoming.has(path) or _want_sent.has(path)

func status_text() -> String:
	if not session.is_active_session:
		return ""
	var parts: PackedStringArray = []
	if not baseline_done:
		parts.append("indexando arquivos…")
	if reconcile_state == "waiting_manifest":
		parts.append("aguardando lista do host")
	if not _incoming.is_empty():
		parts.append("recebendo %d" % _incoming.size())
	if _expected_pulls > 0 and _pulled < _expected_pulls:
		parts.append("%d/%d baixados" % [_pulled, _expected_pulls])
	if not _out_queue.is_empty() or session.bulk_backlog_bytes() > 0:
		parts.append("enviando %d (%s)" % [_out_queue.size(), GLCProtocol.human_bytes(session.bulk_backlog_bytes())])
	if not _deferred.is_empty() or not _deferred_del.is_empty():
		parts.append("%d aguardando você fechar o arquivo" % (_deferred.size() + _deferred_del.size()))
	return ", ".join(parts)

# ====================================================================== scanner (time sliced)

func request_scan() -> void:
	_force_scan = true

func process(delta: float) -> void:
	if not enabled or not session.is_active_session:
		return
	_drain_out_queue()
	_drain_notice_queue()
	if _scanning:
		_scan_step()
	else:
		_scan_wait -= delta
		if _scan_wait <= 0.0 or _force_scan:
			_start_scan(false)
	_retry_deferred()
	_retry_deferred_rmdirs()
	_retry_stale_wants()
	_maybe_refresh_editor_fs()
	if _cache_dirty and Time.get_ticks_msec() - _last_cache_save_ms > 15000:
		_save_cache(false)

func _start_scan(baseline: bool) -> void:
	_scanning = true
	_force_scan = false
	_scan_found = {}
	_scan_dirs = {}
	_scan_stack = ["res://"]
	_scan_started_ms = Time.get_ticks_msec()
	if baseline:
		baseline_done = false

func _join(dir: String, name: String) -> String:
	return dir + name if dir.ends_with("/") else dir + "/" + name

func _scan_step() -> void:
	var t0 := Time.get_ticks_usec()
	while not _scan_stack.is_empty() and Time.get_ticks_usec() - t0 < SCAN_BUDGET_US:
		var dir: String = _scan_stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			if sub.begins_with(".") or sub in GLCProtocol.EXCLUDED_DIRS:
				continue
			var sp := _join(dir, sub)
			if sp == GLCProtocol.SELF_ADDON_DIR:
				continue
			if GLCProtocol.is_syncable_dir(sp):
				_scan_dirs[sp] = true
			_scan_stack.append(sp)
		for f in DirAccess.get_files_at(dir):
			var fp := _join(dir, f)
			if GLCProtocol.is_syncable_path(fp):
				_scan_found[fp] = FileAccess.get_modified_time(fp)
	if _scan_stack.is_empty():
		_finish_scan()

## [hash, size]; uses the persistent cache unless `force` (recently modified files).
func _hash_file(path: String, mtime: int, force: bool = false) -> Array:
	var size := FileAccess.get_size(path)
	if size < 0 or not FileAccess.file_exists(path):
		return ["", 0]
	var c: Variant = _cache.get(path, null)
	# mtime AND size must match: a file copied in from elsewhere keeps its original mtime
	if not force and c is Array and int(c[0]) == mtime and int(c[1]) == size and not String(c[2]).is_empty():
		return [String(c[2]), int(c[1])]
	if size > MAX_FILE_BYTES:
		_cache[path] = [mtime, size, ""]
		return ["", size]
	var h := FileAccess.get_sha256(path)
	_cache[path] = [mtime, size, h]
	_cache_dirty = true
	return [h, size]

func _is_sidecar(path: String) -> bool:
	return path.ends_with(".import") or path.ends_with(".uid")

## True while a new file should still wait for the sidecar the editor generates next to it.
func _waits_for_sidecar(path: String) -> bool:
	var ext := GLCProtocol.ext_of(path)
	if ext in IMPORT_EXTS:
		return not _scan_found.has(path + ".import")
	if ext in UID_EXTS:
		return not _scan_found.has(path + ".uid")
	return false

func _finish_scan() -> void:
	_scanning = false
	var took := (Time.get_ticks_msec() - _scan_started_ms) / 1000.0
	_scan_wait = clampf(took * 4.0, SCAN_PAUSE_MIN_S, SCAN_PAUSE_MAX_S)
	var first := not baseline_done
	var now_s := int(Time.get_unix_time_from_system())
	var now_ms := Time.get_ticks_msec()
	var changed: Array = []
	var created_by_hash: Dictionary = {}
	var gone: Array = []
	# ---- folders
	var new_dirs: Array = []
	var gone_dirs: Array = []
	for d in _scan_dirs:
		if dirs.has(d):
			_dir_new.erase(d)
			continue
		if first:
			dirs[d] = true
			continue
		var n := int(_dir_new.get(d, 0)) + 1
		_dir_new[d] = n
		if n >= STABLE_SCANS:
			_dir_new.erase(d)
			dirs[d] = true
			new_dirs.append(d)
	for d in dirs.keys():
		if _scan_dirs.has(d):
			_dir_missing.erase(d)
			continue
		if first:
			dirs.erase(d)
			continue
		var n2 := int(_dir_missing.get(d, 0)) + 1
		_dir_missing[d] = n2
		if n2 >= STABLE_SCANS:
			_dir_missing.erase(d)
			dirs.erase(d)
			gone_dirs.append(d)
	# ---- new or modified files
	for path in _scan_found:
		var m: int = _scan_found[path]
		var known: Variant = manifest.get(path, null)
		var hot := m >= now_s - HOT_SECONDS
		var size_now := -1
		var quick := ""
		var settled := false   # content already verified as a finished change
		if known is Array and int(known[2]) == m:
			if first:
				_pending_change.erase(path)
				continue
			if not hot:
				if not _suspect.has(path):
					_pending_change.erase(path)
					continue
				# a large file written twice in the same mtime second: check its content once, now that
				# it is no longer being written
				_suspect.erase(path)
				size_now = FileAccess.get_size(path)
				quick = FileAccess.get_sha256(path)
				if quick == String(known[0]):
					continue
				settled = true
			else:
				# same mtime second as what we know: compare size, then content
				size_now = FileAccess.get_size(path)
				if size_now == int(known[1]):
					if size_now > HOT_HASH_LIMIT:
						_suspect[path] = true
						continue
					quick = FileAccess.get_sha256(path)
					if quick == String(known[0]):
						_pending_change.erase(path)
						continue
		if not first and not settled:
			if size_now < 0:
				size_now = FileAccess.get_size(path)
			var sig := "%d:%d" % [m, size_now]
			if hot and size_now <= HOT_HASH_LIMIT:
				if quick.is_empty():
					quick = FileAccess.get_sha256(path)
				sig += ":" + quick
			var pc: Dictionary = _pending_change.get(path, {})
			if String(pc.get("sig", "")) != sig:
				pc = {"sig": sig, "n": 0, "since": int(pc.get("since", now_ms))}
			pc["n"] = int(pc["n"]) + 1
			_pending_change[path] = pc
			# a stable signature for two scans: the write is complete, and a rename is matched with the
			# disappearance of the old path in the same pass
			if int(pc["n"]) < STABLE_SCANS:
				continue
			if known == null and _waits_for_sidecar(path) and now_ms - int(pc["since"]) < SIDECAR_WAIT_MS:
				continue
		var hs: Array
		if not quick.is_empty():
			hs = [quick, size_now]
			_cache[path] = [m, size_now, quick]
			_cache_dirty = true
		else:
			hs = _hash_file(path, m, hot)
		if String(hs[0]).is_empty():
			continue   # unreadable or too large
		_pending_change.erase(path)
		if known is Array and String(known[0]) == String(hs[0]):
			known[2] = m
			continue
		manifest[path] = [hs[0], hs[1], m]
		if first:
			continue
		if known == null:
			created_by_hash[hs[0]] = path
		changed.append(path)
	# ---- deleted files
	for path in manifest.keys():
		if _scan_found.has(path):
			_missing_count.erase(path)
			continue
		if first:
			manifest.erase(path)
			continue
		var cnt: int = int(_missing_count.get(path, 0)) + 1
		_missing_count[path] = cnt
		if cnt >= STABLE_SCANS:
			gone.append(path)
	if first:
		baseline_done = true
		_after_baseline()
		return
	# ---- announce: folders (parents first), sidecars, files, moves, deletions, then removed folders
	new_dirs.sort_custom(func(a, b): return String(a).count("/") < String(b).count("/"))
	for d in new_dirs:
		_broadcast(GLCProtocol.F_MKDIR, {"path": d})
		activity.emit("Pasta criada: " + String(d).trim_prefix("res://"))
	for path in gone:
		var h: String = String(manifest[path][0])
		if created_by_hash.has(h):
			var to: String = created_by_hash[h]
			created_by_hash.erase(h)
			changed.erase(to)
			manifest.erase(path)
			_missing_count.erase(path)
			_announce_move(path, to, h)
		else:
			manifest.erase(path)
			_missing_count.erase(path)
			_announce_delete(path)
	_order_sidecars(changed)
	for path in changed:
		_announce_change(path)
	gone_dirs.sort_custom(func(a, b): return String(a).count("/") > String(b).count("/"))
	for d in gone_dirs:
		_broadcast(GLCProtocol.F_RMDIR, {"path": d})
		activity.emit("Pasta removida: " + String(d).trim_prefix("res://"))
	if _cache_dirty:
		_prune_cache()

func _prune_cache() -> void:
	if _cache.size() > _scan_found.size() * 2 + 100:
		for p in _cache.keys():
			if not _scan_found.has(p):
				_cache.erase(p)

func _load_cache() -> void:
	_cache.clear()
	if FileAccess.file_exists(CACHE_FILE):
		var txt := FileAccess.get_file_as_string(CACHE_FILE)
		var v: Variant = JSON.parse_string(txt)
		if v is Dictionary:
			_cache = v

func _save_cache(force: bool) -> void:
	if not (_cache_dirty or force) or _cache.is_empty():
		return
	_cache_dirty = false
	_last_cache_save_ms = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute("res://.godot")
	var f := FileAccess.open(CACHE_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_cache))
		f.close()

# ====================================================================== reconcile at join

func _after_baseline() -> void:
	if session.is_hosting:
		reconcile_state = "done"
		return
	reconcile_state = "waiting_manifest"
	session.send_to(1, GLCProtocol.F_MANIFEST, {"req": true})

func _compact_manifest() -> Dictionary:
	var d := {}
	for p in manifest:
		d[p] = [manifest[p][0], manifest[p][1]]
	return d

func _on_manifest(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	if session.is_hosting:
		if p.get("req", false):
			if not baseline_done:
				# our own index is not ready yet: answer a bit later
				var timer := plugin.get_tree().create_timer(0.5)
				timer.timeout.connect(func(): _on_manifest(sender, p, _meta))
				return
			session.send_to(sender, GLCProtocol.F_MANIFEST, {"files": _compact_manifest(), "dirs": dirs.keys()})
		return
	if not baseline_done:
		var timer2 := plugin.get_tree().create_timer(0.5)
		timer2.timeout.connect(func(): _on_manifest(sender, p, _meta))
		return
	# folders first (empty ones included)
	var remote_dirs := {}
	for d in p.get("dirs", []):
		var ds := String(d)
		if not GLCProtocol.is_syncable_dir(ds):
			continue
		remote_dirs[ds] = true
		if not DirAccess.dir_exists_absolute(ds):
			DirAccess.make_dir_recursive_absolute(ds)
			_request_fs_refresh()
		_register_dir_chain(ds)
	var push_dirs: Array = []
	for d in dirs:
		if not remote_dirs.has(d):
			push_dirs.append(d)
	var remote: Dictionary = p.get("files", {})
	var need: Array = []
	var push: Array = []
	for path in remote:
		if not GLCProtocol.is_syncable_path(path):
			continue
		var rh: String = String(remote[path][0])
		var l: Variant = manifest.get(path, null)
		if l == null or String(l[0]) != rh:
			if int(remote[path][1]) > MAX_FILE_BYTES:
				continue
			need.append(path)
	for path in manifest:
		if not remote.has(path):
			push.append(path)
	_order_sidecars(need)
	_order_sidecars(push)
	var live_skipped := 0
	var to_pull: Array = []
	for path in need:
		if _is_live(path):
			_deferred[path] = {"hash": String(remote[path][0]), "size": int(remote[path][1]), "from": 1}
			live_skipped += 1
		else:
			to_pull.append(path)
	_expected_pulls = to_pull.size()
	_pulled = 0
	reconcile_state = "pulling" if not to_pull.is_empty() else "done"
	for i in range(0, to_pull.size(), 120):
		var batch: Array = to_pull.slice(i, i + 120)
		var now_ms := Time.get_ticks_msec()
		for pp in batch:
			_want_sent[pp] = String(remote[pp][0])
			_want_time[pp] = now_ms
			_want_from[pp] = 1
		session.send_to(1, GLCProtocol.F_WANT, {"paths": batch})
	if push_local_only:
		push_dirs.sort_custom(func(a, b): return String(a).count("/") < String(b).count("/"))
		for d in push_dirs:
			session.send_to(1, GLCProtocol.F_MKDIR, {"path": d})
		_notice_queue = push.duplicate()
	if not need.is_empty() or not push.is_empty():
		activity.emit("Arquivos: %d para baixar, %d para enviar%s" % [to_pull.size(), push.size() if push_local_only else 0, (", %d em uso aguardando" % live_skipped) if live_skipped > 0 else ""])
	else:
		activity.emit("Arquivos já idênticos ao host")
	progress_changed.emit()

## Transfer order = dependency order, so nothing is loaded before what it needs: sidecars (.import/.uid),
## scripts and shaders, other assets, resources (.tres), and scenes last.
static func _transfer_rank(p: String) -> int:
	if p.ends_with(".import") or p.ends_with(".uid"):
		return 0
	var ext := GLCProtocol.ext_of(p)
	if ext in ["gd", "cs", "gdshader", "gdshaderinc", "gdextension"]:
		return 1
	if ext in ["tres", "res"]:
		return 3
	if ext in ["tscn", "scn"]:
		return 4
	return 2

func _order_sidecars(paths: Array) -> void:
	if not sidecars_first:
		return
	paths.sort_custom(func(a, b):
		var sa := _transfer_rank(String(a))
		var sb := _transfer_rank(String(b))
		if sa != sb:
			return sa < sb
		return String(a) < String(b))

func _drain_notice_queue() -> void:
	if _notice_queue.is_empty() or not baseline_done:
		return
	for i in mini(40, _notice_queue.size()):
		var path: String = _notice_queue.pop_front()
		var m: Variant = manifest.get(path, null)
		if m is Array:
			_send_notice(path, String(m[0]), int(m[1]))

# ====================================================================== announcing local changes

func _is_live(path: String) -> bool:
	return is_live_managed.is_valid() and bool(is_live_managed.call(path))

## Host: to every client. Client: to the host (which relays).
func _broadcast(t: String, payload: Dictionary) -> void:
	if session.is_hosting:
		for pid in session.peers:
			if pid != 1:
				session.send_to(pid, t, payload)
	else:
		session.send_to(1, t, payload)

func _send_notice(path: String, hash: String, size: int) -> void:
	_broadcast(GLCProtocol.F_NOTICE, _notice_payload(path, hash, size))

func _announce_change(path: String) -> void:
	var m: Array = manifest[path]
	_send_notice(path, String(m[0]), int(m[1]))
	stats["files_out"] += 1
	# the exact version this editor just saved is not an "external" change; anything else is. The marker
	# is used once: the next revision of the file is judged on its own.
	var saved_hash := String(_editor_saved.get(path, ""))
	_editor_saved.erase(path)
	if saved_hash != String(m[0]):
		local_file_changed.emit(path)
	if not _is_sidecar(path):
		activity.emit("Arquivo alterado: " + path.trim_prefix("res://"))
	progress_changed.emit()

func _announce_delete(path: String) -> void:
	_broadcast(GLCProtocol.F_DEL, {"path": path})
	if not _is_sidecar(path):
		activity.emit("Arquivo apagado: " + path.trim_prefix("res://"))

func _announce_move(from: String, to: String, hash: String) -> void:
	_broadcast(GLCProtocol.F_MOVE, {"from": from, "to": to, "hash": hash})
	if not _is_sidecar(from):
		activity.emit("Arquivo movido: %s → %s" % [from.trim_prefix("res://"), to.trim_prefix("res://")])

## Called by the plugin after the editor itself saved a file (scene, script, resource). The editor has
## finished writing it, so it is announced RIGHT NOW (no waiting for the scanner): e.g. a script created
## by "Attach Script" reaches the others before the operation that attaches it does.
func note_saved(path: String) -> void:
	GLCProtocol.trace("note_saved %s" % path)
	# (never touch the results of a scan in progress: a file missing from them counts as deleted)
	if GLCProtocol.is_scene_ext(path) and FileAccess.file_exists(path):
		_editor_saved[path] = FileAccess.get_sha256(path)
	_force_scan = true
	_scan_wait = 0.0
	if enabled and session.is_active_session and baseline_done:
		_announce_now(path)

var _editor_saved: Dictionary = {}     # scene path -> sha256 of the last version saved by this editor

## The scene layer is about to send an operation that references these files (a script just attached,
## a texture, an instanced scene...). Any of them the others may not have yet is announced NOW, so it
## arrives before the operation (same ordered channel; small files travel inside the notice).
func ensure_announced(paths: Array) -> void:
	if not enabled or not session.is_active_session or not baseline_done:
		return
	for p in paths:
		var path := String(p)
		if not GLCProtocol.is_syncable_path(path) or not FileAccess.file_exists(path):
			continue
		var known: Variant = manifest.get(path, null)
		if known is Array and int(known[2]) == FileAccess.get_modified_time(path) and int(known[1]) == FileAccess.get_size(path):
			continue   # already known to everybody (the scanner covers same-second edits)
		_announce_now(path)

func _announce_now(path: String) -> void:
	if not GLCProtocol.is_syncable_path(path) or not FileAccess.file_exists(path):
		return
	# folders that do not exist on the others yet go first (parents first)
	var missing_dirs: Array = []
	var dir := path.get_base_dir()
	var guard := 0
	while dir != "res://" and dir.length() > 6 and guard < 64:
		guard += 1
		if GLCProtocol.is_syncable_dir(dir) and not dirs.has(dir):
			missing_dirs.push_front(dir)
		dir = dir.get_base_dir()
	for d in missing_dirs:
		dirs[d] = true
		_dir_new.erase(d)
		_broadcast(GLCProtocol.F_MKDIR, {"path": d})
	# the sidecars written by the same save (.uid of a script, .import of an asset) before the file
	for side in [path + ".uid", path + ".import"]:
		if FileAccess.file_exists(side) and GLCProtocol.is_syncable_path(side):
			_announce_if_changed(side)
	_announce_if_changed(path)

func _announce_if_changed(p: String) -> void:
	var m := FileAccess.get_modified_time(p)
	var hs := _hash_file(p, m, true)
	if String(hs[0]).is_empty():
		return
	var known: Variant = manifest.get(p, null)
	if known is Array and String(known[0]) == String(hs[0]):
		known[2] = m
		return
	manifest[p] = [hs[0], hs[1], m]
	_pending_change.erase(p)
	_missing_count.erase(p)
	_announce_change(p)

## The live layer wrote `path` itself (remote-triggered save): record it so it is not echoed.
func note_written_by_live_layer(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var m := FileAccess.get_modified_time(path)
	var hs := _hash_file(path, m, true)
	if not String(hs[0]).is_empty():
		manifest[path] = [hs[0], hs[1], m]

# ====================================================================== receiving notices

func _on_notice(sender: int, p: Dictionary, meta: Dictionary) -> void:
	GLCProtocol.trace("notice %s inline=%s" % [p.get("path", ""), p.has("data")])
	if not enabled:
		return
	var path := String(p.get("path", ""))
	var hash := String(p.get("hash", ""))
	if not GLCProtocol.is_syncable_path(path) or hash.is_empty():
		return
	if not baseline_done:
		var t := plugin.get_tree().create_timer(0.5)
		t.timeout.connect(func(): _on_notice(sender, p, meta))
		return
	_deferred_del.erase(path)
	var l: Variant = manifest.get(path, null)
	if l is Array and String(l[0]) == hash:
		return
	if int(p.get("size", 0)) > MAX_FILE_BYTES:
		return
	if _is_live(path):
		_deferred[path] = {"hash": hash, "size": int(p.get("size", 0)), "from": sender}
		return
	# small files travel inside the notice: written right away, before any operation that uses them
	# (both go in order on the same channel), no request / answer round trip
	var data: Variant = p.get("data", null)
	if data is PackedByteArray and (data as PackedByteArray).size() == int(p.get("size", -1)) and (data as PackedByteArray).size() <= INLINE_LIMIT and sha256_of(data) == hash:
		_want_sent[path] = hash
		_want_time[path] = Time.get_ticks_msec()
		_want_from[path] = sender
		_write_incoming(path, {"hash": hash, "size": (data as PackedByteArray).size(), "n": 1, "chunks": {0: data}}, sender)
		return
	_request_pull(sender, path, hash)

## Notice payload; files up to INLINE_LIMIT carry their bytes along.
func _notice_payload(path: String, hash: String, size: int, bytes: PackedByteArray = PackedByteArray()) -> Dictionary:
	var payload := {"path": path, "hash": hash, "size": size}
	if size <= INLINE_LIMIT:
		if bytes.size() != size:
			bytes = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
		if bytes.size() == size and sha256_of(bytes) == hash:
			payload["data"] = bytes
	return payload

func _request_pull(from: int, path: String, hash: String) -> void:
	var now := Time.get_ticks_msec()
	if _want_sent.get(path, "") == hash and now - int(_want_time.get(path, 0)) < WANT_TIMEOUT_MS:
		var prev := int(_want_from.get(path, from))
		if prev == from or prev == 1 or session.peers.has(prev):
			return   # already asked someone who is still here
	_want_sent[path] = hash
	_want_time[path] = now
	_want_from[path] = from
	session.send_to(from, GLCProtocol.F_WANT, {"paths": [path]})

## Pulls that got no answer (sender left, transfer lost, sharing paused) are asked for again.
func _retry_stale_wants() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_want_check_ms < 5000 or (_want_sent.is_empty() and _incoming.is_empty()):
		return
	_last_want_check_ms = now
	_expire_transfers(now)
	for path in _want_sent.keys():
		if _incoming.has(path) or now - int(_want_time.get(path, 0)) < WANT_TIMEOUT_MS:
			continue
		var from := int(_want_from.get(path, 1))
		if from != 1 and not session.peers.has(from):
			from = 1   # the author left: the host may have it by now
		if session.is_hosting and from == 1:
			_want_sent.erase(path)   # nobody else to ask
			_want_time.erase(path)
			_want_from.erase(path)
			continue
		_want_time[path] = now
		_want_from[path] = from
		_want_sent[path] = ""   # the answer is the sender's current version, whatever it is now
		session.send_to(from, GLCProtocol.F_WANT, {"paths": [path]})

func _retry_deferred() -> void:
	if not _deferred.is_empty():
		for path in _deferred.keys():
			if not _is_live(path):
				var d: Dictionary = _deferred[path]
				_deferred.erase(path)
				var l: Variant = manifest.get(path, null)
				if l is Array and String(l[0]) == String(d["hash"]):
					continue
				_request_pull(int(d["from"]), path, String(d["hash"]))
	if not _deferred_del.is_empty():
		for path in _deferred_del.keys():
			if _is_live(path):
				continue
			var h0: String = _deferred_del[path]
			_deferred_del.erase(path)
			if not FileAccess.file_exists(path):
				continue
			# you changed the file after it was deleted elsewhere: your version wins (it will be re-sent)
			if not h0.is_empty() and FileAccess.get_sha256(path) != h0:
				continue
			_apply_delete(path)
			activity.emit("Arquivo apagado (remoto, ao fechar): " + path.trim_prefix("res://"))

func _apply_delete(path: String) -> void:
	if FileAccess.file_exists(path):
		if not _backup(path):
			# no copy could be kept: keep the file (it will be announced again, so nobody loses it)
			push_warning("[GLC] backup de %s falhou; o arquivo não foi apagado" % path)
			manifest.erase(path)
			return
		DirAccess.remove_absolute(path)
		_request_fs_refresh()
	manifest.erase(path)
	_cache.erase(path)
	_missing_count.erase(path)
	_pending_change.erase(path)

func _on_delete(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	var path := String(p.get("path", ""))
	if not GLCProtocol.is_syncable_path(path):
		return
	if session.is_hosting:
		_relay(GLCProtocol.F_DEL, p, sender)
	_want_sent.erase(path)
	_incoming.erase(path)
	_deferred.erase(path)
	if _is_live(path):
		_deferred_del[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		activity.emit("%s foi apagado por outra pessoa; será removido quando você fechar" % path.get_file())
		return
	var existed := FileAccess.file_exists(path)
	_apply_delete(path)
	if existed and not _is_sidecar(path):
		activity.emit("Arquivo apagado (remoto): " + path.trim_prefix("res://"))

func _on_move(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	var from := String(p.get("from", ""))
	var to := String(p.get("to", ""))
	var hash := String(p.get("hash", ""))
	if not GLCProtocol.is_syncable_path(from) or not GLCProtocol.is_syncable_path(to):
		return
	if session.is_hosting:
		_relay(GLCProtocol.F_MOVE, p, sender)
	_want_sent.erase(from)
	_incoming.erase(from)
	var l: Variant = manifest.get(from, null)
	if l is Array and String(l[0]) == hash and not _is_live(from) and FileAccess.file_exists(from) and not FileAccess.file_exists(to):
		DirAccess.make_dir_recursive_absolute(to.get_base_dir())
		_register_dir_chain(to.get_base_dir())
		if DirAccess.rename_absolute(from, to) == OK:
			var mt := FileAccess.get_modified_time(to)
			manifest[to] = [l[0], l[1], mt]
			_cache[to] = [mt, l[1], l[0]]
			manifest.erase(from)
			_cache.erase(from)
			_missing_count.erase(from)
			_request_fs_refresh()
			if not _is_sidecar(from):
				activity.emit("Arquivo movido (remoto): %s → %s" % [from.trim_prefix("res://"), to.trim_prefix("res://")])
			return
	# we cannot replay the move: fetch the new path and drop the old one
	if not (manifest.get(to, null) is Array and String(manifest[to][0]) == hash):
		_request_pull(sender, to, hash)
	if FileAccess.file_exists(from):
		if _is_live(from):
			_deferred_del[from] = FileAccess.get_sha256(from)
		else:
			_apply_delete(from)
	else:
		manifest.erase(from)

# ====================================================================== folders

## Marks `dir` and all its parents as known (so the scanner does not announce them back).
func _register_dir_chain(dir: String) -> void:
	if dir.ends_with("/") and dir != "res://":
		dir = dir.substr(0, dir.length() - 1)
	var guard := 0
	while dir != "res://" and dir.length() > 6 and guard < 64:
		guard += 1
		if GLCProtocol.is_syncable_dir(dir):
			dirs[dir] = true
			_dir_new.erase(dir)
			_deferred_rmdir.erase(dir)   # something new lives here: the folder stays
		dir = dir.get_base_dir()

func _on_mkdir(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	var path := String(p.get("path", ""))
	if not GLCProtocol.is_syncable_dir(path):
		return
	if session.is_hosting:
		_relay(GLCProtocol.F_MKDIR, p, sender)
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)
		_request_fs_refresh()
		activity.emit("Pasta criada (remoto): " + path.trim_prefix("res://"))
	_register_dir_chain(path)
	_dir_missing.erase(path)

func _on_rmdir(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	var path := String(p.get("path", ""))
	if not GLCProtocol.is_syncable_dir(path):
		return
	if session.is_hosting:
		_relay(GLCProtocol.F_RMDIR, p, sender)
	if DirAccess.dir_exists_absolute(path):
		# only empty folders: anything still inside (files open here, local-only files) keeps it alive;
		# it is removed later once what is left inside goes away (e.g. a deferred delete on closing)
		if not _remove_dir_if_empty(path):
			_deferred_rmdir[path] = true
	else:
		dirs.erase(path)

func _remove_dir_if_empty(path: String) -> bool:
	if not DirAccess.get_files_at(path).is_empty() or not DirAccess.get_directories_at(path).is_empty():
		return false
	if DirAccess.remove_absolute(path) != OK:
		return false
	dirs.erase(path)
	_dir_new.erase(path)
	_deferred_rmdir.erase(path)
	_request_fs_refresh()
	activity.emit("Pasta removida (remoto): " + path.trim_prefix("res://"))
	return true

func _retry_deferred_rmdirs() -> void:
	var now := Time.get_ticks_msec()
	if _deferred_rmdir.is_empty() or now - _last_rmdir_check_ms < 1000:
		return
	_last_rmdir_check_ms = now
	var lst: Array = _deferred_rmdir.keys()
	lst.sort_custom(func(a, b): return String(a).count("/") > String(b).count("/"))   # deepest first
	for d in lst:
		if not DirAccess.dir_exists_absolute(d):
			_deferred_rmdir.erase(d)
			dirs.erase(d)
		else:
			_remove_dir_if_empty(d)

func _relay(t: String, payload: Dictionary, except: int) -> void:
	for pid in session.peers:
		if pid != 1 and pid != except:
			session.send_to(pid, t, payload)

# ====================================================================== editor FileSystem dock

func _request_fs_refresh() -> void:
	var now := Time.get_ticks_msec()
	if _fs_refresh_first_ms == 0:
		_fs_refresh_first_ms = now
	_fs_refresh_last_ms = now

## Rescans the editor filesystem shortly after remote writes (debounced; waits for a batch to finish so
## an asset and its .import arrive together).
func _maybe_refresh_editor_fs() -> void:
	if _fs_refresh_first_ms == 0:
		return
	var now := Time.get_ticks_msec()
	# during the initial download the editor scans once the whole batch is there (a half-copied
	# project would only produce "file not found" noise); 20 s at most
	if reconcile_state == "pulling" and now - _fs_refresh_first_ms < 20000:
		return
	var quiet := now - _fs_refresh_last_ms >= FS_REFRESH_QUIET_MS and _incoming.is_empty()
	if not quiet and now - _fs_refresh_first_ms < FS_REFRESH_MAX_WAIT_MS:
		return
	var efs := EditorInterface.get_resource_filesystem()
	if efs == null or efs.is_scanning():
		return
	_fs_refresh_first_ms = 0
	efs.scan()

# ====================================================================== serving files

func _on_want(sender: int, p: Dictionary, _meta: Dictionary) -> void:
	if not enabled:
		return
	for path in p.get("paths", []):
		if GLCProtocol.is_syncable_path(String(path)):
			_out_queue.append({"peer": sender, "path": String(path)})
	progress_changed.emit()

func _drain_out_queue() -> void:
	var guard := 0
	while not _out_queue.is_empty() and session.bulk_backlog_bytes() < OUT_BACKLOG_LIMIT and guard < 16:
		guard += 1
		var e: Dictionary = _out_queue.pop_front()
		if not session.peers.has(int(e["peer"])) and int(e["peer"]) != 1:
			continue
		_send_file(int(e["peer"]), String(e["path"]))

static func sha256_of(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

func _send_file(peer: int, path: String) -> void:
	if not FileAccess.file_exists(path):
		session.send_to(peer, GLCProtocol.F_DATA, {"path": path, "missing": true})
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > MAX_FILE_BYTES:
		return
	var hash := sha256_of(bytes)
	var n := maxi(1, int(ceil(float(bytes.size()) / CHUNK)))
	for i in n:
		var part := bytes.slice(i * CHUNK, mini((i + 1) * CHUNK, bytes.size()))
		session.queue_to(peer, GLCProtocol.F_DATA, {"path": path, "hash": hash, "size": bytes.size(), "idx": i, "n": n, "data": part})
	stats["bytes_out"] += bytes.size()
	stats["files_out"] += 1
	progress_changed.emit()

# ====================================================================== receiving files

func _on_data(sender: int, p: Dictionary, meta: Dictionary) -> void:
	if not enabled:
		return
	var path := String(p.get("path", ""))
	if not GLCProtocol.is_syncable_path(path):
		return
	if p.get("missing", false):
		_want_sent.erase(path)
		return
	# only data we asked for: a delete/move that arrived meanwhile cancels the transfer
	if not _want_sent.has(path) and not _incoming.has(path):
		return
	var size := int(p.get("size", -1))
	var n := int(p.get("n", 0))
	var idx := int(p.get("idx", -1))
	var data: Variant = p.get("data", null)
	var hash := String(p.get("hash", ""))
	if hash.is_empty() or size < 0 or size > MAX_FILE_BYTES or n != maxi(1, ceili(float(size) / CHUNK)) or idx < 0 or idx >= n or not (data is PackedByteArray) or (data as PackedByteArray).size() > CHUNK:
		return   # malformed transfer
	_want_time[path] = Time.get_ticks_msec()
	# several versions of the same file may be in flight: each one is assembled on its own
	var per: Dictionary = _incoming.get(path, {})
	_incoming[path] = per
	var inc: Dictionary = per.get(hash, {})
	if inc.is_empty():
		inc = {"hash": hash, "size": size, "n": n, "chunks": {}, "got": 0, "from": sender}
		per[hash] = inc
	if int(inc["n"]) != n:
		return
	inc["t"] = Time.get_ticks_msec()
	if not (inc["chunks"] as Dictionary).has(idx):
		inc["chunks"][idx] = data
		inc["got"] = int(inc["got"]) + 1
	if int(inc["got"]) >= int(inc["n"]):
		per.erase(hash)
		if per.is_empty():
			_incoming.erase(path)
		_write_incoming(path, inc, sender)
	progress_changed.emit()

## A version `h` of `path` was installed (or found identical, `force`). The request is satisfied when that
## was the requested version; versions still in flight that are neither requested nor newer are dropped,
## so an older transfer finishing later can never overwrite what was just installed.
func _settle_want(path: String, h: String, force: bool = false) -> void:
	var wanted := String(_want_sent.get(path, ""))
	if force or wanted == h or (wanted.is_empty() and _want_sent.has(path)):
		_want_sent.erase(path)
		_want_time.erase(path)
		_want_from.erase(path)
		_incoming.erase(path)
		return
	var per: Dictionary = _incoming.get(path, {})
	for k in per.keys():
		if k != wanted:
			per.erase(k)
	if per.is_empty():
		_incoming.erase(path)

## Partial transfers from someone who left, or that stopped arriving, are discarded (the pull is retried).
func drop_transfers_from(peer_id: int) -> void:
	for path in _incoming.keys():
		var per: Dictionary = _incoming[path]
		for k in per.keys():
			if int(per[k].get("from", 0)) == peer_id:
				per.erase(k)
		if per.is_empty():
			_incoming.erase(path)

func _expire_transfers(now: int) -> void:
	for path in _incoming.keys():
		var per: Dictionary = _incoming[path]
		for k in per.keys():
			if now - int(per[k].get("t", now)) > WANT_TIMEOUT_MS:
				per.erase(k)
		if per.is_empty():
			_incoming.erase(path)

func _write_incoming(path: String, inc: Dictionary, sender: int) -> void:
	var bytes := PackedByteArray()
	for i in int(inc["n"]):
		bytes.append_array(inc["chunks"][i])
	var h := sha256_of(bytes)
	if h != String(inc["hash"]) or bytes.size() != int(inc["size"]):
		push_warning("[GLC] arquivo corrompido na transferência, descartado: " + path)
		_want_sent.erase(path)
		return
	if _is_live(path):
		_settle_want(path, h, true)   # pulled again (fresh) when the file is closed
		_deferred[path] = {"hash": h, "size": bytes.size(), "from": sender}
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_register_dir_chain(path.get_base_dir())
	if FileAccess.file_exists(path) and FileAccess.get_sha256(path) == h:
		# identical to what we have: satisfies the request only if this is the version asked for (or a
		# retry asked for "whatever you have now"); an older answer must not cancel a newer request
		if String(_want_sent.get(path, "")) in [h, ""]:
			_settle_want(path, h, true)
		var mt0 := FileAccess.get_modified_time(path)
		manifest[path] = [h, bytes.size(), mt0]
		_cache[path] = [mt0, bytes.size(), h]
		_pending_change.erase(path)
		_count_pulled()
		_fan_out(path, h, bytes.size(), sender)   # we may never announce it ourselves now
		return
	var tmp := path + ".glc_tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[GLC] não foi possível gravar " + path)
		return
	f.store_buffer(bytes)
	f.close()
	# never replace anything with an incomplete write (disk full...)
	if FileAccess.get_sha256(tmp) != h:
		push_warning("[GLC] gravação incompleta de %s (disco cheio?): arquivo mantido como estava" % path)
		DirAccess.remove_absolute(tmp)
		return
	if FileAccess.file_exists(path):
		if not _backup(path):
			push_warning("[GLC] não foi possível guardar backup de %s: arquivo mantido como estava" % path)
			DirAccess.remove_absolute(tmp)
			return
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("[GLC] falha ao mover arquivo temporário para %s (a cópia anterior está em %s)" % [path, BACKUP_DIR])
		DirAccess.remove_absolute(tmp)
		return   # (the pull stays pending and is retried)
	_settle_want(path, h)
	var m := FileAccess.get_modified_time(path)
	manifest[path] = [h, bytes.size(), m]
	_cache[path] = [m, bytes.size(), h]
	_cache_dirty = true
	_pending_change.erase(path)
	_missing_count.erase(path)
	_deferred_del.erase(path)
	stats["bytes_in"] += bytes.size()
	stats["files_in"] += 1
	_request_fs_refresh()
	file_arrived.emit(path)
	_count_pulled()
	GLCProtocol.trace("written %s" % path)
	_fan_out(path, h, bytes.size(), sender, bytes)
	progress_changed.emit()

## Host: the author sent us the bytes, now tell everyone else.
func _fan_out(path: String, h: String, size: int, sender: int, bytes: PackedByteArray = PackedByteArray()) -> void:
	if not session.is_hosting:
		return
	var payload := _notice_payload(path, h, size, bytes)
	for pid in session.peers:
		if pid != 1 and pid != sender:
			session.send_to(pid, GLCProtocol.F_NOTICE, payload)

func _count_pulled() -> void:
	_pulled += 1
	if reconcile_state == "pulling" and _pulled >= _expected_pulls:
		reconcile_state = "done"
		activity.emit("Arquivos sincronizados (%d recebidos)" % _pulled)

func _backup(path: String) -> bool:
	var rel := path.trim_prefix("res://")
	var dst := "%s/%s/%s" % [BACKUP_DIR, _backup_stamp if not _backup_stamp.is_empty() else "session", rel]
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	if DirAccess.copy_absolute(path, dst) == OK:
		stats["backups"] += 1
		return true
	return false
