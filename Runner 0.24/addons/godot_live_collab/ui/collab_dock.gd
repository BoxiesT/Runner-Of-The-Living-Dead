@tool
class_name GLCCollabDock
extends VBoxContainer
## Control panel of the plugin (hosted inside an EditorDock, or a classic dock on older versions).

signal host_requested(port: int, password: String, user_name: String, color: Color)
signal join_requested(address: String, port: int, password: String, user_name: String, color: Color)
signal disconnect_requested()
signal reconnect_requested()
signal option_changed(key: String, value: Variant)
signal resync_requested()
signal rescan_files_requested()
signal open_backups_requested()

var session: GLCSessionManager
var scenes: GLCSceneTreeSync
var scripts: GLCScriptLiveSync
var files: GLCFileSync
const LanDiscovery := preload("res://addons/godot_live_collab/core/lan_discovery.gd")
var discovery: LanDiscovery

var _status: Label
var _status_dot: ColorRect
var _name_edit: LineEdit
var _color_btn: ColorPickerButton
var _found_box: VBoxContainer
var _found: ItemList
var _found_hint: Label
var _found_sig: String = ""
var _copy_btn: Button
var _address: LineEdit
var _port: SpinBox
var _password: LineEdit
var _btn_host: Button
var _btn_join: Button
var _btn_leave: Button
var _btn_reconnect: Button
var _share_label: RichTextLabel
var _people: Tree
var _log: RichTextLabel
var _files_label: Label
var _scenes_label: Label
var _checks: Dictionary = {}
var _refresh_accum: float = 0.0
var _log_lines: int = 0

func _ready() -> void:
	name = "Live Collab"
	# small minimum height: long pages scroll instead of forcing the editor layout (docks, bottom panel)
	custom_minimum_size = Vector2(260, 160)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()
	set_process(true)

func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum >= 0.5:
		_refresh_accum = 0.0
		refresh()

# ------------------------------------------------------------------ construction

func _build() -> void:
	var head := HBoxContainer.new()
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.color = Color(0.5, 0.5, 0.5)
	var dot_holder := CenterContainer.new()
	dot_holder.add_child(_status_dot)
	head.add_child(dot_holder)
	_status = Label.new()
	_status.text = "Desconectado"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	head.add_child(_status)
	add_child(head)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)

	# ---- Sessão
	var sess := VBoxContainer.new()
	sess.name = "Sessão"
	_add_scroll_page(tabs, sess)
	var grid := GridContainer.new()
	grid.columns = 2
	sess.add_child(grid)
	_name_edit = _row(grid, "Seu nome", LineEdit.new())
	_name_edit.text = GLCSettings.default_name()
	_name_edit.text_changed.connect(func(t): GLCSettings.set_value("name", t))
	_color_btn = ColorPickerButton.new()
	_color_btn.color = GLCSettings.get_value("color")
	_color_btn.custom_minimum_size = Vector2(0, 26)
	_color_btn.color_changed.connect(func(c): GLCSettings.set_value("color", c))
	_row(grid, "Sua cor", _color_btn)

	# sessions found on the LAN / VPN
	_found_box = VBoxContainer.new()
	sess.add_child(_found_box)
	var found_title := Label.new()
	found_title.text = "Sessões encontradas na rede local / VPN:"
	_found_box.add_child(found_title)
	_found = ItemList.new()
	_found.custom_minimum_size = Vector2(0, 64)
	_found.auto_height = true
	_found.tooltip_text = "Clique para preencher o endereço; clique duplo para entrar."
	_found.item_selected.connect(_on_found_selected)
	_found.item_activated.connect(_on_found_activated)
	_found_box.add_child(_found)
	_found_hint = Label.new()
	_found_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_found_hint.modulate = Color(1, 1, 1, 0.6)
	_found_hint.text = "Procurando… (ou digite o IP do host abaixo)"
	_found_box.add_child(_found_hint)

	var grid2 := GridContainer.new()
	grid2.columns = 2
	sess.add_child(grid2)
	_address = _row(grid2, "IP do host", LineEdit.new())
	_address.text = String(GLCSettings.get_value("address"))
	_address.placeholder_text = "ex.: 192.168.0.10 ou 26.x.x.x (Radmin)"
	_address.text_changed.connect(func(t): GLCSettings.set_value("address", t))
	grid = grid2
	_port = _row(grid, "Porta", SpinBox.new())
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = int(GLCSettings.get_value("port"))
	_port.value_changed.connect(func(v): GLCSettings.set_value("port", int(v)))
	_password = _row(grid, "Senha", LineEdit.new())
	_password.secret = true
	_password.placeholder_text = "(opcional, não é salva)"
	var buttons := HBoxContainer.new()
	sess.add_child(buttons)
	_btn_host = Button.new()
	_btn_host.text = "Hospedar"
	_btn_host.tooltip_text = "Você vira o host: a sessão passa por você e outros entram no seu endereço."
	_btn_host.pressed.connect(_on_host_pressed)
	buttons.add_child(_btn_host)
	_btn_join = Button.new()
	_btn_join.text = "Entrar"
	_btn_join.pressed.connect(_on_join_pressed)
	buttons.add_child(_btn_join)
	_btn_leave = Button.new()
	_btn_leave.text = "Sair"
	_btn_leave.pressed.connect(func(): disconnect_requested.emit())
	buttons.add_child(_btn_leave)
	_btn_reconnect = Button.new()
	_btn_reconnect.text = "Reconectar"
	_btn_reconnect.pressed.connect(func(): reconnect_requested.emit())
	buttons.add_child(_btn_reconnect)
	_share_label = RichTextLabel.new()
	_share_label.bbcode_enabled = true
	_share_label.fit_content = true
	_share_label.selection_enabled = true
	_share_label.scroll_active = false
	sess.add_child(_share_label)
	_copy_btn = Button.new()
	_copy_btn.text = "Copiar endereço"
	_copy_btn.tooltip_text = "Copia IP:porta para a área de transferência (prefere o IP do Radmin VPN, se houver)."
	_copy_btn.pressed.connect(_on_copy_pressed)
	_copy_btn.visible = false
	sess.add_child(_copy_btn)
	_scenes_label = Label.new()
	_scenes_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sess.add_child(_scenes_label)

	# ---- Pessoas
	var ppl := VBoxContainer.new()
	ppl.name = "Pessoas"
	tabs.add_child(ppl)
	_people = Tree.new()
	_people.columns = 4
	_people.set_column_title(0, "Nome")
	_people.set_column_title(1, "Cena")
	_people.set_column_title(2, "IP")
	_people.set_column_title(3, "ms")
	_people.column_titles_visible = true
	_people.hide_root = true
	_people.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_people.set_column_expand(0, true)
	_people.set_column_expand(1, true)
	_people.set_column_expand(2, true)
	_people.set_column_expand(3, false)
	_people.set_column_custom_minimum_width(3, 44)
	ppl.add_child(_people)

	# ---- Atividade
	var act := VBoxContainer.new()
	act.name = "Atividade"
	tabs.add_child(act)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.selection_enabled = true
	act.add_child(_log)
	var clear := Button.new()
	clear.text = "Limpar"
	clear.pressed.connect(func():
		_log.clear()
		_log_lines = 0)
	act.add_child(clear)

	# ---- Arquivos
	var fl := VBoxContainer.new()
	fl.name = "Arquivos"
	_add_scroll_page(tabs, fl)
	_files_label = Label.new()
	_files_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fl.add_child(_files_label)
	var rescan := Button.new()
	rescan.text = "Verificar arquivos agora"
	rescan.pressed.connect(func(): rescan_files_requested.emit())
	fl.add_child(rescan)
	var backups := Button.new()
	backups.text = "Abrir pasta de backups"
	backups.tooltip_text = "Cópias de arquivos sobrescritos ou apagados por outras pessoas ficam em res://.glc_backup"
	backups.pressed.connect(func(): open_backups_requested.emit())
	fl.add_child(backups)
	_check(fl, "sync_files", "Sincronizar arquivos do projeto (pasta compartilhada)")
	_check(fl, "push_local_files", "Enviar ao host arquivos que só existem aqui")

	# ---- Opções
	var opt := VBoxContainer.new()
	opt.name = "Opções"
	_add_scroll_page(tabs, opt)
	_check(opt, "sync_scene", "Sincronizar cenas e propriedades")
	_check(opt, "sync_scripts", "Sincronizar scripts ao vivo")
	_check(opt, "presence", "Mostrar ponteiros e câmeras de outras pessoas")
	_check(opt, "selection", "Mostrar seleção de outras pessoas")
	_check(opt, "toasts", "Avisos no canto do editor")
	_check(opt, "auto_reconnect", "Reconectar automaticamente")
	_check(opt, "responsive_background", "Tempo real mesmo com a janela da Godot em segundo plano")
	_check(opt, "open_host_scene", "Ao entrar numa sessão, abrir a cena em que o host está")
	_check(opt, "lan_only", "Somente rede local / VPN (Radmin, Hamachi...) — recomendado")
	_check(opt, "discovery", "Procurar e anunciar sessões na rede local")
	_check(opt, "verbose", "Log detalhado no console")
	var resync := Button.new()
	resync.text = "Forçar ressincronização das cenas"
	resync.tooltip_text = "Pede ao host o estado atual de todas as cenas abertas."
	resync.pressed.connect(func(): resync_requested.emit())
	opt.add_child(resync)

## A tab page that scrolls vertically (the tab keeps the page's name as its title).
func _add_scroll_page(tabs: TabContainer, page: Control) -> void:
	var sc := ScrollContainer.new()
	sc.name = page.name
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.name = "Content"
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(page)
	tabs.add_child(sc)

func _row(grid: GridContainer, label: String, ctl: Control) -> Variant:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(ctl)
	return ctl

func _check(parent: Control, key: String, text: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = bool(GLCSettings.get_value(key))
	c.toggled.connect(func(on):
		GLCSettings.set_value(key, on)
		option_changed.emit(key, on))
	parent.add_child(c)
	_checks[key] = c

# ------------------------------------------------------------------ actions

func _on_host_pressed() -> void:
	host_requested.emit(int(_port.value), _password.text, _name_edit.text.strip_edges(), _color_btn.color)

func _on_join_pressed() -> void:
	join_requested.emit(_address.text.strip_edges(), int(_port.value), _password.text, _name_edit.text.strip_edges(), _color_btn.color)

func _found_entry(index: int) -> Dictionary:
	if index < 0 or index >= _found.item_count:
		return {}
	var md: Variant = _found.get_item_metadata(index)
	return md if md is Dictionary else {}

func _on_found_selected(index: int) -> void:
	var e := _found_entry(index)
	if e.is_empty():
		return
	_address.text = String(e["ip"])
	GLCSettings.set_value("address", _address.text)
	_port.value = int(e["port"])
	if bool(e.get("pw", false)) and _password.text.is_empty():
		_password.grab_focus()

func _on_found_activated(index: int) -> void:
	_on_found_selected(index)
	var e := _found_entry(index)
	if e.is_empty() or session.is_active_session:
		return
	if bool(e.get("pw", false)) and _password.text.is_empty():
		add_log("Essa sessão tem senha: digite-a e clique em Entrar.", 1)
		return
	_on_join_pressed()

func _on_copy_pressed() -> void:
	var addrs := GLCProtocol.local_lan_addresses()
	if addrs.is_empty():
		return
	var best: Dictionary = addrs[0]
	for a in addrs:
		if String(a["label"]) == "Radmin VPN":
			best = a
	DisplayServer.clipboard_set("%s:%d" % [best["ip"], session.session_port])
	add_log("Copiado: %s:%d" % [best["ip"], session.session_port])

func _refresh_found() -> void:
	if discovery == null or _found == null:
		return
	var browsing: bool = not session.is_active_session and discovery.enabled
	_found_box.visible = browsing
	if not browsing:
		return
	var lst: Array = discovery.list()
	var sig := ""
	for e in lst:
		sig += "%s|%s|%d|%d|%s;" % [e["sid"], e["ip"], int(e["port"]), int(e["peers"]), e["name"]]
	if sig == _found_sig:
		return
	_found_sig = sig
	var keep_ip := _address.text
	_found.clear()
	for e in lst:
		var proj := String(e["project"])
		var txt := "%s%s — %s:%d (%s) • %d pessoa(s)%s" % [e["name"], (" · " + proj) if not proj.is_empty() else "", e["ip"], int(e["port"]), e["label"], int(e["peers"]), "  [com senha]" if bool(e["pw"]) else ""]
		if int(e.get("version", 0)) != GLCProtocol.VERSION:
			txt += "  (versão diferente do plugin!)"
		var idx := _found.add_item(txt)
		_found.set_item_metadata(idx, e)
		if String(e["ip"]) == keep_ip:
			_found.select(idx)
	_found_hint.text = "Nenhuma sessão encontrada ainda. Dica: com Radmin VPN, todos na mesma rede do Radmin aparecem aqui; ou digite o IP." if lst.is_empty() else "Clique para preencher, clique duplo para entrar."

func add_log(text: String, level: int = 0) -> void:
	if _log == null:
		return
	var col := "#cfd3d8" if level == 0 else ("#e8c46a" if level == 1 else "#ff7b72")
	_log.append_text("[color=#7d8590]%s[/color] [color=%s]%s[/color]\n" % [Time.get_time_string_from_system(), col, text.replace("[", "[lb]")])
	_log_lines += 1
	if _log_lines > 400:
		_log.clear()
		_log_lines = 0

# ------------------------------------------------------------------ refresh

func refresh() -> void:
	if session == null or _status == null:
		return
	var st := session.state
	var txt := ""
	var col := Color(0.55, 0.55, 0.55)
	match st:
		"hosting":
			txt = "Hospedando • %d pessoa(s)" % session.peers.size()
			col = Color(0.35, 0.85, 0.5)
		"connected":
			txt = "Conectado • %d pessoa(s) • %d ms" % [session.peers.size(), session.rtt_ms]
			col = Color(0.35, 0.85, 0.5)
		"connecting", "authenticating":
			txt = "Conectando…"
			col = Color(0.9, 0.75, 0.3)
		"reconnecting":
			txt = "Reconectando…"
			col = Color(0.9, 0.75, 0.3)
		"error":
			txt = "Erro: " + session.last_error
			col = Color(0.95, 0.4, 0.35)
		"disconnected":
			txt = "Desconectado: " + session.last_error
			col = Color(0.95, 0.4, 0.35)
		_:
			txt = "Desconectado"
	_status.text = txt
	_status.tooltip_text = txt
	_status_dot.color = col
	var active := session.is_active_session
	_btn_host.disabled = active or st in ["connecting", "authenticating", "reconnecting"]
	_btn_join.disabled = _btn_host.disabled
	_btn_leave.disabled = not active and st not in ["connecting", "authenticating", "reconnecting"]
	_btn_reconnect.visible = st in ["error", "disconnected"]
	_address.editable = not active
	_port.editable = not active
	_password.editable = not active
	# share info
	if session.is_hosting:
		var lines: PackedStringArray = []
		for a in GLCProtocol.local_lan_addresses():
			lines.append("  [b]%s[/b]  (%s%s)" % [a["ip"], a["label"], (" · " + String(a["iface"])) if not String(a["iface"]).is_empty() and String(a["iface"]) != String(a["label"]) else ""])
		if lines.is_empty():
			lines.append("  (nenhuma rede local encontrada — conecte-se à rede ou ao Radmin VPN)")
		var disc := ""
		if discovery != null and discovery.enabled:
			disc = "\nOs colegas na mesma rede veem esta sessão na lista automaticamente." if discovery.host_listening else ("\n[color=#e8c46a]Descoberta automática indisponível: %s[/color]" % discovery.host_listen_error)
		_share_label.text = "[b]Passe para seus colegas[/b] (porta [b]%d[/b], %s):\n%s%s" % [session.session_port, "com senha" if not session.session_password.is_empty() else "sem senha", "\n".join(lines), disc]
		_copy_btn.visible = true
	else:
		_share_label.text = ""
		_copy_btn.visible = false
	_refresh_found()
	_refresh_people()
	_refresh_info()

func _refresh_people() -> void:
	if _people == null:
		return
	_people.clear()
	var root := _people.create_item()
	for id in session.peers:
		var info: Dictionary = session.peers[id]
		var it := _people.create_item(root)
		var nm := String(info.get("name", "?"))
		if id == session.local_id():
			nm += " (você)"
		if info.get("host", false):
			nm += " ★"
		it.set_text(0, nm)
		it.set_custom_color(0, info.get("color", Color.WHITE) if info.get("color", Color.WHITE) is Color else Color.WHITE)
		it.set_text(1, String(info.get("scene", "")).get_file())
		it.set_text(2, String(info.get("ip", "")))
		it.set_text(3, str(int(info.get("rtt", 0))) if id != 1 or not session.is_hosting else "-")

func _refresh_info() -> void:
	var lines: PackedStringArray = []
	if scenes != null and session.is_active_session:
		for path in scenes.bindings:
			var b: GLCSceneTreeSync.Binding = scenes.bindings[path]
			lines.append("%s  %s%s" % ["●" if b.state == "synced" else "◌", String(path).get_file(), ("  (+%d pendentes)" % b.replica.pending_count()) if b.replica != null and b.replica.pending_count() > 0 else ""])
	if scripts != null and session.is_active_session:
		for path in scripts.docs:
			var d: GLCScriptLiveSync.Doc = scripts.docs[path]
			lines.append("%s  %s" % ["●" if d.state == "synced" else "◌", String(path).get_file()])
	_scenes_label.text = ("Em sincronia:\n" + "\n".join(lines)) if not lines.is_empty() else ""
	if files != null:
		var s := files.stats
		var status := files.status_text()
		_files_label.text = "%s\nRecebidos: %d (%s)   Enviados: %d (%s)\nBackups feitos: %d\nTráfego da sessão: ↑ %s  ↓ %s" % [
			status if not status.is_empty() else "Tudo em dia.",
			s["files_in"], GLCProtocol.human_bytes(int(s["bytes_in"])), s["files_out"], GLCProtocol.human_bytes(int(s["bytes_out"])),
			s["backups"], GLCProtocol.human_bytes(session.bytes_sent), GLCProtocol.human_bytes(session.bytes_received)]
