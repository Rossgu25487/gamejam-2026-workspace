extends CanvasLayer
## 调试控制台界面：键盘 ` / ~ 键在任何界面呼出，输入 super 解锁后可用跳关、获取物品等测试命令。
## 打开时冻结游戏并拦截全部输入；解锁状态只保存在内存，不写入存档或设置。
## 命令本身在 debug_commands.gd，界面只负责输入、输出和生命周期。
const CommandsScript = preload("res://systems/debug_console/debug_commands.gd")
const UNLOCK_WORD := "super"
# 反引号、波浪号、中文输入法下同一个键产生的间隔号和全角波浪号。
const TOGGLE_UNICODE := [96, 126, 183, 0xFF5E]
const MAX_PARAGRAPHS := 800
const MAX_LOG_LINES := 1000
const MAX_HISTORY := 100
const COLORS := {"info": Color("d8dee9"), "ok": Color("8fd694"), "warn": Color("f0c674"), "error": Color("ff7b72"),
	"dim": Color("7f8a99"), "title": Color("6cb6ff"), "echo": Color("9ecbff")}
signal opened
signal closed

var app: Control
var commands: RefCounted
var unlocked := false
var is_open := false
var hud_enabled := false
var log_lines: Array[String] = []
var panel_root: Control
var output_label: RichTextLabel
var input_edit: LineEdit
var state_label: Label
var progress_label: Label
var hud_label: Label
var _font: Font
var _paused_before := false
var _history: Array[String] = []
var _history_cursor := 0
var _hud_next := 0
var _submitting := false

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = _make_font()
	_build_panel()
	_build_hud()
	_update_state()

func bind(host: Control) -> void:
	app = host
	commands = CommandsScript.new(host, self)
	commands.output_requested.connect(_on_output)

func _exit_tree() -> void:
	var tree := get_tree()
	if is_open and tree != null: tree.paused = _paused_before
	if commands != null and commands.speed_changed: Engine.time_scale = 1.0

# ---------- 构建界面 ----------

func _make_font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "Microsoft YaHei UI", "SimHei", "monospace"])
	font.allow_system_fallback = true
	return font

func _box(color: Color, border: Color = Color.TRANSPARENT, border_bottom: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.border_width_bottom = border_bottom
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

func _build_panel() -> void:
	panel_root = Control.new()
	panel_root.name = "ConsoleRoot"
	panel_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel_root.mouse_filter = Control.MOUSE_FILTER_STOP
	panel_root.visible = false
	add_child(panel_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.42)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_root.add_child(dim)
	var panel := PanelContainer.new()
	panel.name = "ConsolePanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	panel.anchor_bottom = 0.56
	panel.offset_bottom = 0
	panel.add_theme_stylebox_override("panel", _box(Color(0.04, 0.055, 0.08, 0.97), Color("3d8bd4"), 2))
	panel_root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	header.add_child(_label("调试控制台", 18, COLORS.title))
	progress_label = _label("", 15, COLORS.warn)
	progress_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(progress_label)
	state_label = _label("", 15, COLORS.dim)
	header.add_child(state_label)
	output_label = RichTextLabel.new()
	output_label.name = "ConsoleOutput"
	output_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output_label.scroll_following = true
	output_label.selection_enabled = true
	output_label.focus_mode = Control.FOCUS_CLICK
	output_label.add_theme_font_override("normal_font", _font)
	output_label.add_theme_font_size_override("normal_font_size", 16)
	column.add_child(output_label)
	var row := HBoxContainer.new()
	column.add_child(row)
	row.add_child(_label(">", 18, COLORS.ok))
	input_edit = LineEdit.new()
	input_edit.name = "ConsoleInput"
	input_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_edit.add_theme_font_override("font", _font)
	input_edit.add_theme_font_size_override("font_size", 17)
	input_edit.add_theme_stylebox_override("normal", _box(Color(0.09, 0.115, 0.15, 1.0)))
	input_edit.add_theme_stylebox_override("focus", _box(Color(0.11, 0.14, 0.19, 1.0), Color("3d8bd4"), 2))
	input_edit.text_submitted.connect(_on_text_submitted)
	input_edit.text_changed.connect(_on_text_changed)
	input_edit.gui_input.connect(_on_input_gui_input)
	input_edit.focus_exited.connect(_on_input_focus_exited)
	row.add_child(input_edit)

func _build_hud() -> void:
	hud_label = _label("", 14, Color("e6edf3"))
	hud_label.name = "ConsoleHud"
	hud_label.visible = false
	hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hud_label.add_theme_constant_override("outline_size", 5)
	hud_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hud_label.offset_left = 8
	hud_label.offset_bottom = -6
	hud_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(hud_label)

# ---------- 开关与输入 ----------

static func is_toggle_event(key: InputEventKey) -> bool:
	return key.physical_keycode == KEY_QUOTELEFT or key.keycode == KEY_QUOTELEFT or key.keycode == KEY_ASCIITILDE or int(key.unicode) in TOGGLE_UNICODE

func _input(event: InputEvent) -> void:
	if not event is InputEventKey: return
	var key: InputEventKey = event
	if not key.pressed: return
	# 本节点在场景树末尾，先于各页面的 _input 收到按键；任何界面都能呼出。
	if is_toggle_event(key):
		get_viewport().set_input_as_handled()
		if not key.echo: toggle()
		return
	if not is_open: return
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if key.echo: return
		if commands != null and commands.busy: commands.cancel()
		else: close_console()
	elif get_viewport().gui_get_focus_owner() != input_edit and not (key.is_command_or_control_pressed() and key.keycode == KEY_C):
		_grab_input()

func toggle() -> void:
	if not is_open: open_console()
	elif commands != null and commands.busy: _say("快进进行中，按 Esc 取消后才能关闭。", "warn")
	else: close_console()

func open_console() -> void:
	if is_open: return
	is_open = true
	_paused_before = get_tree().paused
	get_tree().paused = true
	panel_root.visible = true
	input_edit.clear()
	_history_cursor = _history.size()
	_update_state()
	call_deferred("_grab_input")
	opened.emit()

func close_console() -> void:
	if not is_open: return
	is_open = false
	panel_root.visible = false
	input_edit.release_focus()
	get_tree().paused = _paused_before
	closed.emit()

func lock() -> void:
	unlocked = false
	_update_state()

func _grab_input() -> void:
	if not is_open or not is_inside_tree(): return
	input_edit.grab_focus()
	# 命令都是英文与 ID；关闭输入法组字，避免中文输入法把 super 吞成拼音候选。
	DisplayServer.window_set_ime_active(false)

func _on_input_focus_exited() -> void:
	if not is_open or not is_inside_tree(): return
	# 点击输出区选字复制时保留其焦点，其余情况把焦点收回输入框。
	await get_tree().process_frame
	if is_open and get_viewport().gui_get_focus_owner() != output_label: _grab_input()

func _on_input_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed: return
	match key.keycode:
		KEY_UP:
			_history_step(-1)
			input_edit.accept_event()
		KEY_DOWN:
			_history_step(1)
			input_edit.accept_event()
		KEY_TAB:
			_complete()
			input_edit.accept_event()

func _on_text_changed(value: String) -> void:
	var cleaned := value
	for code in TOGGLE_UNICODE: cleaned = cleaned.replace(String.chr(code), "")
	if cleaned == value: return
	var caret := input_edit.caret_column - (value.length() - cleaned.length())
	input_edit.text = cleaned
	input_edit.caret_column = clampi(caret, 0, cleaned.length())

func _on_text_submitted(text: String) -> void:
	input_edit.clear()
	submit(text)

# ---------- 提交与输出 ----------

## 提交一行输入：未解锁时只认 super，解锁后交给命令表。测试直接调用本方法。
func submit(line: String) -> void:
	var text := line.strip_edges()
	if text.is_empty() or _submitting: return
	_submitting = true
	_say("> " + text, "echo")
	if not unlocked:
		if text.to_lower() == UNLOCK_WORD:
			unlocked = true
			_update_state()
			_say("调试控制台已解锁。输入 help 查看命令，lock 可重新锁定。", "ok")
		else:
			_say("未知命令。", "error")
	elif commands == null:
		_say("控制台尚未绑定游戏。", "error")
	else:
		_remember(text)
		input_edit.editable = false
		await commands.execute(text)
		if is_instance_valid(input_edit): input_edit.editable = true
	_submitting = false
	if is_open and is_inside_tree(): call_deferred("_grab_input")

func _on_output(kind: String, text: String) -> void:
	if kind == "progress":
		progress_label.text = text
		return
	_say(text, kind)

func _say(text: String, kind: String = "info") -> void:
	log_lines.append(text)
	if log_lines.size() > MAX_LOG_LINES: log_lines.remove_at(0)
	output_label.push_color(COLORS.get(kind, COLORS.info))
	output_label.add_text(text)
	output_label.pop()
	output_label.newline()
	while output_label.get_paragraph_count() > MAX_PARAGRAPHS: output_label.remove_paragraph(0)

func clear_log() -> void:
	output_label.clear()
	log_lines.clear()

func copy_log() -> void:
	DisplayServer.clipboard_set("\n".join(log_lines))

func _update_state() -> void:
	if state_label == null: return
	state_label.text = "已解锁" if unlocked else "未解锁"
	state_label.add_theme_color_override("font_color", COLORS.ok if unlocked else COLORS.dim)

# ---------- 历史与补全 ----------

func _remember(text: String) -> void:
	if _history.is_empty() or _history.back() != text: _history.append(text)
	if _history.size() > MAX_HISTORY: _history.remove_at(0)
	_history_cursor = _history.size()

func _history_step(direction: int) -> void:
	if _history.is_empty() or not unlocked: return
	_history_cursor = clampi(_history_cursor + direction, 0, _history.size())
	input_edit.text = "" if _history_cursor >= _history.size() else _history[_history_cursor]
	input_edit.caret_column = input_edit.text.length()

func _complete() -> void:
	if not unlocked or commands == null: return
	var line := input_edit.text
	var options: Array = commands.completions(line)
	if options.is_empty(): return
	var start := line.length() if (line.ends_with(" ") or line.ends_with("\u3000")) else maxi(line.rfind(" "), line.rfind("\u3000")) + 1
	var prefix := line.substr(0, start)
	if options.size() == 1:
		input_edit.text = prefix + str(options[0]) + " "
	else:
		input_edit.text = prefix + _common_prefix(options)
		_say("  " + "  ".join(options.slice(0, 24)) + ("  ……" if options.size() > 24 else ""), "dim")
	input_edit.caret_column = input_edit.text.length()

func _common_prefix(options: Array) -> String:
	var prefix := str(options[0])
	for option in options:
		var text := str(option)
		var length := 0
		while length < prefix.length() and length < text.length() and prefix[length].to_lower() == text[length].to_lower(): length += 1
		prefix = prefix.substr(0, length)
	return prefix

# ---------- 屏幕状态信息 ----------

func set_hud(enabled: bool) -> void:
	hud_enabled = enabled
	hud_label.visible = enabled
	_hud_next = 0

func _process(_delta: float) -> void:
	if not hud_enabled or app == null or not is_instance_valid(app): return
	var now := Time.get_ticks_msec()
	if now < _hud_next: return
	_hud_next = now + 250
	hud_label.text = _hud_text()

func _hud_text() -> String:
	var session: Node = app.session
	var data: Dictionary = session.case_state.data
	var scene_id := str(data.scene)
	var place: String = session.config.text(str(session.config.scenes.get(scene_id, {}).get("name_text_id", ""))) if session.config.scenes.has(scene_id) else ""
	return "FPS %d | %s | %s %s | 模式 %s | 界面 %s | 入口 %s | 关卡 %s | 材料 %d | 倍率 %.1f" % [Engine.get_frames_per_second(), data.chapter, scene_id, place,
		session.mode, app.current_layer, session.active_entry if not session.active_entry.is_empty() else "-",
		session.question if not session.question.is_empty() else "-", data.materials.size(), Engine.time_scale]
