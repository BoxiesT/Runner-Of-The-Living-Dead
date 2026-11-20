@tool
extends EditorPlugin
# Test-only driver. Runs a scripted scenario inside a (headless) editor and writes a JSON result.
# User args:  --glc-role=host|client  --glc-scenario=NAME  --glc-port=N  --glc-out=PATH  --glc-name=STR

var args := {}
var collab: Node = null
var log_lines: PackedStringArray = PackedStringArray()

func _enter_tree() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--glc-"):
			var kv := a.substr(6).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	if args.has("role"):
		call_deferred("_boot")

func say(msg: String) -> void:
	var line := "[%s %.2f] %s" % [args.get("role", "?"), Time.get_ticks_msec() / 1000.0, msg]
	print(line)
	log_lines.append(line)

func find_collab() -> Node:
	var p := get_parent().get_node_or_null("GodotLiveCollabPlugin")
	return p

func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

func wait_until(cond: Callable, timeout: float = 10.0) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await get_tree().create_timer(0.05).timeout
		t += 0.05
	return false

func _boot() -> void:
	await wait(1.5)
	collab = find_collab()
	say("collab plugin: %s" % [collab])
	if args.has("verbose") and collab and collab.get("scene_sync"):
		collab.scene_sync.verbose = true
	var scenario: String = args.get("scenario", "")
	var result := {"ok": false, "role": args.get("role"), "scenario": scenario}
	var sc = load("res://addons/glc_driver/scenarios.gd").new()
	sc.d = self
	if sc.has_method("run_" + scenario):
		result = await sc.call("run_" + scenario)
	else:
		say("unknown scenario " + scenario)
	result["log"] = Array(log_lines)
	var f := FileAccess.open(args.get("out", "/tmp/glc_result.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(result, "  "))
	f.close()
	say("done, quitting")
	get_tree().quit()

# ---------- helpers usable by scenarios ----------
func dump_scene(root: Node) -> Array:
	var out := []
	_dump_rec(root, root, out)
	return out

func _dump_rec(n: Node, root: Node, out: Array) -> void:
	if n.name.begins_with("_glc_"):
		return
	var d := {"path": str(root.get_path_to(n)), "class": n.get_class(), "idx": n.get_index()}
	if n is Node2D:
		d["pos"] = [snappedf(n.position.x, 0.001), snappedf(n.position.y, 0.001)]
		d["rot"] = snappedf(n.rotation, 0.0001)
		d["scale"] = [snappedf(n.scale.x, 0.001), snappedf(n.scale.y, 0.001)]
	if n is Control:
		d["size"] = [snappedf(n.size.x, 0.001), snappedf(n.size.y, 0.001)]
	if n is CanvasItem:
		d["modulate"] = n.modulate.to_html()
	if n is Label:
		d["text"] = n.text
	var conns := []
	for s in n.get_signal_list():
		for c in n.get_signal_connection_list(s["name"]):
			if int(c["flags"]) & CONNECT_PERSIST:
				var cb: Callable = c["callable"]
				var tgt: Object = cb.get_object()
				if tgt is Node:
					conns.append("%s->%s.%s" % [s["name"], str(root.get_path_to(tgt)), cb.get_method()])
	if not conns.is_empty():
		conns.sort()
		d["conns"] = conns
	out.append(d)
	for c in n.get_children():
		if c.owner == root:
			_dump_rec(c, root, out)
