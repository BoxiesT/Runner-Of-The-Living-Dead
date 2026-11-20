@tool
class_name GLCProtocol
extends RefCounted
## Wire format, ids, path rules and small helpers shared by every module.

const VERSION := 4   # bump whenever peers with different versions must not mix
const DEFAULT_PORT := 24680
## UDP port used to find sessions on the local network (LAN / Radmin VPN / Hamachi...).
const DISCOVERY_PORT := 24679
const DISCOVERY_MAGIC := "GLC-DISCOVER"
const MAX_PEERS := 16
const MAX_MESSAGE_BYTES := 192 * 1024 * 1024
## ENet channels: 0 = live operations (system channels), 1 = bulk file data (so big transfers never
## delay live edits).
const CHANNEL_LIVE := 0
const CHANNEL_BULK := 1
const ENET_CHANNELS := 2

# --- message types -----------------------------------------------------------------
# control (never sequenced)
const C_PING := "c.ping"
const C_PONG := "c.pong"
const C_PEERS := "c.peers"
const C_ACK := "c.ack"
const C_REJ := "c.rej"
const C_SUB := "c.sub"
const C_UNSUB := "c.unsub"
const C_INFO := "c.info"        # peer -> host: presence-level info (active scene, open scripts...)
const C_NOTICE := "c.notice"    # host -> peers: human readable event (toast / activity log)
# scene model (sequenced ops are in GLCSceneModel: s.add s.del s.ren s.mov s.set s.res)
const S_OPEN := "s.open"        # client -> host: I bound this scene
const S_STATE := "s.state"      # host -> client: full snapshot
const S_SEED := "s.seed"        # client -> host: my tree, because you have no model for this scene yet
const S_CLOSE := "s.close"
const S_RESYNC := "s.resync"
const S_TF := "s.tf"            # live transform hints while dragging (unreliable broadcast)
const S_SAVED := "s.saved"      # someone saved this scene
# text documents
const D_OPEN := "d.open"
const D_STATE := "d.state"
const D_OP := "d.op"
const D_CLOSE := "d.close"
const D_CURSOR := "d.cur"
const D_SAVED := "d.saved"
# project settings
const P_SET := "p.set"
const P_STATE := "p.state"
# files
const F_MANIFEST := "f.man"
const F_WANT := "f.want"
const F_DATA := "f.data"
const F_PUT := "f.put"
const F_NOTICE := "f.note"
const F_DEL := "f.del"
const F_MOVE := "f.mov"
const F_DONE := "f.done"
const F_MKDIR := "f.mkd"
const F_RMDIR := "f.rmd"
# presence
const V_POINTER := "v.ptr"
const V_SELECT := "v.sel"
const V_CAMERA := "v.cam"

# ------------------------------------------------------------------------------------
# framing

## Serializes a message. Large messages are zstd-compressed (flag byte 1), others stored raw (flag 0).
static func pack(msg: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(msg)
	if raw.size() > 768:
		var comp := raw.compress(FileAccess.COMPRESSION_ZSTD)
		if comp.size() > 0 and comp.size() + 5 < raw.size():
			var out := PackedByteArray()
			out.resize(5)
			out[0] = 1
			out.encode_u32(1, raw.size())
			out.append_array(comp)
			return out
	var out2 := PackedByteArray()
	out2.resize(1)
	out2[0] = 0
	out2.append_array(raw)
	return out2

static func unpack(bytes: PackedByteArray) -> Variant:
	if bytes.size() < 2:
		return null
	var flag := bytes[0]
	var raw: PackedByteArray
	if flag == 1:
		if bytes.size() < 6:
			return null
		var size := bytes.decode_u32(1)
		if size > MAX_MESSAGE_BYTES:
			return null
		raw = bytes.slice(5).decompress(size, FileAccess.COMPRESSION_ZSTD)
		if raw.size() != size:
			return null
	else:
		raw = bytes.slice(1)
	var v: Variant = bytes_to_var(raw)   # objects are never decoded
	return v if v is Dictionary else null

# ------------------------------------------------------------------------------------
# ids

static var _crypto: Crypto = null

static func new_uid() -> String:
	if _crypto == null:
		_crypto = Crypto.new()
	return _crypto.generate_random_bytes(8).hex_encode()

static func random_bytes(n: int) -> PackedByteArray:
	if _crypto == null:
		_crypto = Crypto.new()
	return _crypto.generate_random_bytes(n)

static func hmac_sha256(key: String, message: PackedByteArray) -> PackedByteArray:
	if _crypto == null:
		_crypto = Crypto.new()
	var k := key if not key.is_empty() else "glc-open-session"   # mbedtls refuses empty keys
	return _crypto.hmac_digest(HashingContext.HASH_SHA256, k.to_utf8_buffer(), message)

static func color_for_name(n: String) -> Color:
	var h := float(n.hash() % 360) / 360.0
	return Color.from_hsv(h, 0.65, 0.95)

# ------------------------------------------------------------------------------------
# paths

## Directories / files that are never replicated between machines.
const EXCLUDED_DIRS := [".godot", ".git", ".svn", ".hg", ".glc_backup", ".idea", ".vscode", ".import", "node_modules"]
const EXCLUDED_FILES := ["project.godot", "export_presets.cfg", ".gitignore", ".gitattributes"]
const SELF_ADDON_DIR := "res://addons/godot_live_collab"

static func is_safe_res_path(path: String) -> bool:
	if not path.begins_with("res://") or path.length() > 400:
		return false
	var rel := path.substr(6)
	if rel.is_empty() or rel.begins_with("/") or rel.contains("\\") or rel.contains("//") or rel.contains(":"):
		return false
	for part in rel.split("/"):
		if part == ".." or part == "." or part.is_empty():
			return false
		if part.length() > 120:
			return false
	for i in rel.length():
		if rel.unicode_at(i) < 32:
			return false
	return true

## Safe AND allowed to be mirrored (not an excluded folder / the plugin itself / editor caches).
static func is_syncable_path(path: String) -> bool:
	if not is_safe_res_path(path):
		return false
	if path == SELF_ADDON_DIR or path.begins_with(SELF_ADDON_DIR + "/"):
		return false
	var rel := path.substr(6)
	var parts := rel.split("/")
	for i in parts.size():
		var part: String = parts[i]
		if i < parts.size() - 1 and (part in EXCLUDED_DIRS or part.begins_with(".")):
			return false
	var fname: String = parts[parts.size() - 1]
	if fname in EXCLUDED_FILES or fname.ends_with(".tmp") or fname.ends_with("~") or fname.begins_with(".#") or fname.ends_with(".glc_tmp"):
		return false
	if parts.size() == 1 and fname.begins_with("."):
		return false
	return true

## A folder that may be mirrored (same rules as the files inside it).
static func is_syncable_dir(path: String) -> bool:
	if path.ends_with("/"):
		path = path.substr(0, path.length() - 1)
	return is_syncable_path(path + "/x")

# ------------------------------------------------------------------------------------
# network scope (LAN only)

## True for addresses that belong to a local network or to a LAN-emulating VPN:
## loopback, 10/8, 172.16/12, 192.168/16, link-local, 100.64/10 (Tailscale/CGNAT),
## 26/8 (Radmin VPN), 25/8 (Hamachi), and the IPv6 equivalents (::1, fe80::/10, fc00::/7).
static func is_lan_address(ip: String) -> bool:
	ip = ip.strip_edges().to_lower()
	if ip.is_empty():
		return false
	if ip.begins_with("::ffff:") and ip.count(".") == 3:
		ip = ip.substr(7)
	if ip.contains(":"):
		if ip == "::1":
			return true
		var first := ip.split(":")[0]
		if first.is_empty():
			return false
		var h := ("0x" + first).hex_to_int()
		return (h & 0xffc0) == 0xfe80 or (h & 0xfe00) == 0xfc00
	var parts := ip.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if not p.is_valid_int() or int(p) < 0 or int(p) > 255:
			return false
	var a := int(parts[0])
	var b := int(parts[1])
	if a == 127 or a == 10 or a == 26 or a == 25:
		return true
	if a == 172 and b >= 16 and b <= 31:
		return true
	if a == 192 and b == 168:
		return true
	if a == 169 and b == 254:
		return true
	if a == 100 and b >= 64 and b <= 127:
		return true
	return false

## Human label for one of this machine's addresses (shown in the dock).
static func network_label(ip: String, iface_name: String = "") -> String:
	var n := iface_name.to_lower()
	if n.contains("radmin") or ip.begins_with("26."):
		return "Radmin VPN"
	if n.contains("hamachi") or ip.begins_with("25."):
		return "Hamachi"
	if n.contains("tailscale") or (ip.begins_with("100.") and is_lan_address(ip)):
		return "Tailscale"
	if n.contains("zerotier"):
		return "ZeroTier"
	return "rede local"

## IPv4 addresses of this machine that other LAN/VPN members can use: [{ip, label}].
static func local_lan_addresses() -> Array:
	var out: Array = []
	var seen := {}
	for iface in IP.get_local_interfaces():
		var friendly := String(iface.get("friendly", iface.get("name", "")))
		for ip in iface.get("addresses", []):
			var s := String(ip)
			if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254.") or seen.has(s):
				continue
			if not is_lan_address(s):
				continue
			seen[s] = true
			out.append({"ip": s, "label": network_label(s, friendly), "iface": friendly})
	return out

static func ext_of(path: String) -> String:
	return path.get_extension().to_lower()

## Files whose in-memory copy is owned by the live layer while they are open in the editor.
static func is_scene_ext(path: String) -> bool:
	return ext_of(path) in ["tscn", "scn"]

static func is_text_script_ext(path: String) -> bool:
	return ext_of(path) in ["gd", "gdshader", "gdshaderinc", "cs", "txt", "md", "json", "cfg", "csv", "toml", "yml", "yaml", "xml", "html", "ini"]

# ------------------------------------------------------------------------------------
# misc

static func now_ms() -> int:
	return Time.get_ticks_msec()

## Timing trace for diagnosing latency (only when the GLC_TRACE environment variable is set).
static var _trace_on: int = -1
static func trace(msg: String) -> void:
	if _trace_on < 0:
		_trace_on = 1 if OS.has_environment("GLC_TRACE") else 0
	if _trace_on == 1:
		print("[GLC-T %.3f] %s" % [Time.get_unix_time_from_system(), msg])

static func short(s: String, n: int = 8) -> String:
	return s.substr(0, n)

static func human_bytes(n: int) -> String:
	if n < 1024:
		return "%d B" % n
	if n < 1024 * 1024:
		return "%.1f KB" % (n / 1024.0)
	return "%.1f MB" % (n / 1048576.0)

## Stable cross-machine hash of any encoded value (Dictionary keys sorted).
static func stable_string(v: Variant) -> String:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort_custom(func(a, b): return str(a) < str(b))
		var parts := PackedStringArray()
		for k in keys:
			parts.append("%s:%s" % [str(k), stable_string(v[k])])
		return "{" + ",".join(parts) + "}"
	if v is Array:
		var parts2 := PackedStringArray()
		for e in v:
			parts2.append(stable_string(e))
		return "[" + ",".join(parts2) + "]"
	if v is PackedByteArray:
		return "bytes:%d:%d" % [(v as PackedByteArray).size(), (v as PackedByteArray).hex_encode().hash()]
	return var_to_str(v)

static func stable_hash(v: Variant) -> int:
	return stable_string(v).hash()
