extends CanvasLayer
## 调试控制台界面。任意界面按 ` / ~ 键呼出：第一次先输入口令 super 解锁，之后本次运行内每次按 ~ 直接打开图形面板。
## 面板打开时冻结游戏并拦截输入；解锁状态只保存在内存，不写入存档或设置。
## 命令本身在 debug_commands.gd，各页签在 tabs/ 下；界面上的每个按钮背后都是一条命令，
## 命令行只是进阶入口。面板内容在第一次呼出时才构建，普通玩家不按 ~ 键就没有任何开销。
const CommandsScript = preload("res://systems/debug_console/debug_commands.gd")
const AutoPlayScript = preload("res://systems/debug_console/debug_auto_play.gd")
const DebugTheme = preload("res://systems/debug_console/debug_theme.gd")
const TAB_SCRIPTS := {
	"overview": preload("res://systems/debug_console/tabs/tab_overview.gd"),
	"jump": preload("res://systems/debug_console/tabs/tab_jump.gd"),
	"items": preload("res://systems/debug_console/tabs/tab_items.gd"),
	"story": preload("res://systems/debug_console/tabs/tab_story.gd"),
	"autoplay": preload("res://systems/debug_console/tabs/tab_autoplay.gd"),
	"tools": preload("res://systems/debug_console/tabs/tab_tools.gd"),
	"terminal": preload("res://systems/debug_console/tabs/tab_terminal.gd"),
}
const TAB_ORDER := [["overview", "概览"], ["jump", "跳转"], ["items", "物品"], ["story", "剧情"], ["autoplay", "自动推进"], ["tools", "调试"], ["terminal", "命令行"]]
const UNLOCK_WORD := "super"
# 反引号、波浪号、中文输入法下同一个键产生的间隔号和全角波浪号。
const TOGGLE_UNICODE := [96, 126, 183, 0xFF5E]
const MAX_PARAGRAPHS := 800
const MAX_LOG_LINES := 1000
const OVERVIEW_REFRESH_MS := 500
signal opened
signal closed

var app: Control
var commands: RefCounted
var unlocked := false
var is_open := false
## 自动推进正在实机演示：面板收起、游戏运行，只响应停止。
var live_mode := false
var hud_enabled := false
var log_lines: Array[String] = []
## 累计产生过的日志行数。log_lines 超过上限会丢弃最旧的行，要判断"有没有新输出"应当比较这个计数。
var log_count := 0
var current_tab := "overview"
var panel_root: Control
var prompt_box: Control
var prompt_edit: LineEdit
var prompt_message: Label
var main_panel: Control
var stack: Control
var output_label: RichTextLabel
## 命令行页的输入框，该页建好后赋值。
var input_edit: LineEdit
var state_label: Label
var progress_label: Label
var busy_overlay: Control
var busy_label: Label
var banner: Control
var banner_label: Label
var hud_label: Label
var tabs := {}
var tab_buttons := {}
var _built := false
var _paused_before := false
var _hud_next := 0
var _refresh_next := 0
var _submitting := false
var _busy_seen := false

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	panel_root = Control.new()
	panel_root.name = "ConsoleRoot"
	panel_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel_root.mouse_filter = Control.MOUSE_FILTER_STOP
	panel_root.visible = false
	add_child(panel_root)
	_build_hud()

func bind(host: Control) -> void:
	app = host
	commands = CommandsScript.new(host, self)
	commands.output_requested.connect(_on_output)
	commands.live_run_changed.connect(_on_live_changed)

func _exit_tree() -> void:
	var tree := get_tree()
	if (is_open or live_mode) and tree != null: tree.paused = _paused_before
	if commands != null and commands.speed_changed: Engine.time_scale = 1.0

# ---------- 构建界面（首次呼出时） ----------

func _ensure_built() -> void:
	if _built: return
	_built = true
	panel_root.theme = DebugTheme.build()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_root.add_child(dim)
	_build_main()
	_build_prompt()
	_build_busy_overlay()
	_build_banner()
	# 命令行页要先建好：测试和补全都依赖 input_edit。
	_tab("terminal").ensure_built()

func _build_prompt() -> void:
	prompt_box = CenterContainer.new()
	prompt_box.name = "UnlockPrompt"
	prompt_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	prompt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_root.add_child(prompt_box)
	var dialog := PanelContainer.new()
	dialog.custom_minimum_size = Vector2(500, 0)
	prompt_box.add_child(dialog)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	dialog.add_child(column)
	var title := Label.new()
	title.text = "调试控制台"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", DebugTheme.ACCENT_TEXT)
	column.add_child(title)
	var note := Label.new()
	note.text = "仅供测试人员使用。输入口令后解锁图形面板，之后本次运行内按 ~ 键即可直接打开。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", DebugTheme.DIM)
	column.add_child(note)
	prompt_edit = LineEdit.new()
	prompt_edit.name = "UnlockInput"
	prompt_edit.placeholder_text = "输入口令，按 Enter 解锁"
	prompt_edit.add_theme_font_size_override("font_size", 18)
	guard_line_edit(prompt_edit)
	prompt_edit.text_submitted.connect(_on_prompt_submitted)
	column.add_child(prompt_edit)
	prompt_message = Label.new()
	prompt_message.add_theme_color_override("font_color", DebugTheme.ERROR)
	prompt_message.custom_minimum_size.y = 22
	column.add_child(prompt_message)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	var unlock := Button.new()
	unlock.text = "解锁"
	unlock.focus_mode = Control.FOCUS_NONE
	unlock.pressed.connect(func(): _on_prompt_submitted(prompt_edit.text))
	row.add_child(unlock)
	var cancel := Button.new()
	cancel.text = "关闭（Esc）"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(close_console)
	row.add_child(cancel)

func _build_main() -> void:
	var margin := MarginContainer.new()
	margin.name = "ConsoleMargin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 26)
	panel_root.add_child(margin)
	main_panel = PanelContainer.new()
	main_panel.name = "ConsolePanel"
	margin.add_child(main_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	main_panel.add_child(column)
	# 标题栏
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	column.add_child(header)
	var title := Label.new()
	title.text = "调试控制台"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", DebugTheme.ACCENT_TEXT)
	header.add_child(title)
	state_label = Label.new()
	header.add_child(state_label)
	progress_label = Label.new()
	progress_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	progress_label.clip_text = true
	progress_label.add_theme_color_override("font_color", DebugTheme.WARN)
	header.add_child(progress_label)
	var key_hint := Label.new()
	key_hint.text = "~ / Esc 关闭"
	key_hint.add_theme_color_override("font_color", DebugTheme.DIM)
	header.add_child(key_hint)
	var close := Button.new()
	close.text = "关闭"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(close_console)
	header.add_child(close)
	# 主体与日志
	var split := VSplitContainer.new()
	split.name = "ConsoleSplit"
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(split)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_stretch_ratio = 3.2
	body.custom_minimum_size.y = 300
	split.add_child(body)
	var nav := VBoxContainer.new()
	nav.name = "ConsoleNav"
	nav.add_theme_constant_override("separation", 6)
	nav.custom_minimum_size.x = 150
	body.add_child(nav)
	var group := ButtonGroup.new()
	for item in TAB_ORDER:
		var button := Button.new()
		button.text = str(item[1])
		button.name = "Tab_" + str(item[0])
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(150, 42)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(show_tab.bind(str(item[0])))
		nav.add_child(button)
		tab_buttons[str(item[0])] = button
	stack = MarginContainer.new()
	stack.name = "ConsoleStack"
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(stack)
	var log_box := VBoxContainer.new()
	log_box.add_theme_constant_override("separation", 4)
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.size_flags_stretch_ratio = 1.0
	log_box.custom_minimum_size.y = 120
	split.add_child(log_box)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	log_box.add_child(bar)
	var log_title := Label.new()
	log_title.text = "日志"
	log_title.add_theme_color_override("font_color", DebugTheme.DIM)
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(log_title)
	for item in [["清空", clear_log], ["复制", copy_log]]:
		var button := Button.new()
		button.text = str(item[0])
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(item[1])
		bar.add_child(button)
	output_label = RichTextLabel.new()
	output_label.name = "ConsoleOutput"
	output_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	output_label.scroll_following = true
	output_label.selection_enabled = true
	output_label.focus_mode = Control.FOCUS_CLICK
	output_label.add_theme_font_override("normal_font", DebugTheme.make_font(true))
	output_label.add_theme_font_size_override("normal_font_size", 14)
	log_box.add_child(output_label)
	# 重放建好之前已经产生的日志
	for line in log_lines: _append_line(line, "info")

func _build_busy_overlay() -> void:
	busy_overlay = Control.new()
	busy_overlay.name = "BusyOverlay"
	busy_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	busy_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	busy_overlay.visible = false
	panel_root.add_child(busy_overlay)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	busy_overlay.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	busy_overlay.add_child(center)
	var dialog := PanelContainer.new()
	dialog.custom_minimum_size = Vector2(560, 0)
	center.add_child(dialog)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	dialog.add_child(column)
	var title := Label.new()
	title.text = "正在运行……"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", DebugTheme.ACCENT_TEXT)
	column.add_child(title)
	busy_label = Label.new()
	busy_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	busy_label.custom_minimum_size.y = 44
	column.add_child(busy_label)
	var stop := Button.new()
	stop.text = "取消（Esc）"
	stop.focus_mode = Control.FOCUS_NONE
	stop.pressed.connect(func(): if commands != null: commands.cancel())
	column.add_child(stop)

func _build_banner() -> void:
	var holder := PanelContainer.new()
	holder.name = "LiveBanner"
	holder.theme = panel_root.theme
	holder.visible = false
	add_child(holder)
	holder.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	holder.offset_top = 12
	holder.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	holder.add_child(row)
	var title := Label.new()
	title.text = "自动推进演示中"
	title.add_theme_color_override("font_color", DebugTheme.WARN)
	row.add_child(title)
	banner_label = Label.new()
	banner_label.custom_minimum_size.x = 420
	banner_label.clip_text = true
	row.add_child(banner_label)
	var stop := Button.new()
	stop.text = "停止（Esc）"
	stop.focus_mode = Control.FOCUS_NONE
	stop.pressed.connect(func(): if commands != null: commands.cancel())
	row.add_child(stop)
	banner = holder

func _build_hud() -> void:
	hud_label = Label.new()
	hud_label.name = "ConsoleHud"
	hud_label.visible = false
	hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_label.add_theme_font_override("font", DebugTheme.make_font())
	hud_label.add_theme_font_size_override("font_size", 14)
	hud_label.add_theme_color_override("font_color", Color("e6edf3"))
	hud_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hud_label.add_theme_constant_override("outline_size", 5)
	add_child(hud_label)
	hud_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hud_label.offset_left = 8
	hud_label.offset_bottom = -6
	hud_label.grow_vertical = Control.GROW_DIRECTION_BEGIN

# ---------- 页签 ----------

func _tab(key: String) -> Control:
	if not tabs.has(key):
		var tab: Control = TAB_SCRIPTS[key].new()
		tab.name = key
		tab.visible = false
		stack.add_child(tab)
		tab.setup(self)
		tabs[key] = tab
	return tabs[key]

func show_tab(key: String) -> void:
	if not _built or not TAB_SCRIPTS.has(key): return
	current_tab = key
	for name in tab_buttons: tab_buttons[name].set_pressed_no_signal(name == key)
	var page := _tab(key)
	for name in tabs: tabs[name].visible = tabs[name] == page
	page.show_tab()

func refresh_tabs() -> void:
	if _built and tabs.has(current_tab) and unlocked and is_open: tabs[current_tab].refresh()

# ---------- 开关与输入 ----------

static func is_toggle_event(key: InputEventKey) -> bool:
	return key.physical_keycode == KEY_QUOTELEFT or key.keycode == KEY_QUOTELEFT or key.keycode == KEY_ASCIITILDE or int(key.unicode) in TOGGLE_UNICODE

func _input(event: InputEvent) -> void:
	if live_mode:
		_live_input(event)
		return
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

## 实机演示期间：只响应停止（Esc / ~ / 横幅上的按钮），其余按键和点击全部吞掉，免得干扰自动推进。
func _live_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and not key.echo and (key.keycode == KEY_ESCAPE or is_toggle_event(key)): _stop_live()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton or event is InputEventScreenTouch:
		var point: Vector2 = event.position
		if banner != null and banner.visible and banner.get_global_rect().has_point(point): return
		get_viewport().set_input_as_handled()

func _stop_live() -> void:
	if commands != null: commands.cancel()
	if banner_label != null: banner_label.text = "正在停止……"

func toggle() -> void:
	if live_mode:
		_stop_live()
	elif not is_open:
		open_console()
	elif commands != null and commands.busy:
		_say("自动推进或快进进行中，按 Esc 取消后才能关闭。", "warn")
	else:
		close_console()

func open_console() -> void:
	if is_open or live_mode: return
	_ensure_built()
	is_open = true
	_paused_before = get_tree().paused
	get_tree().paused = true
	panel_root.visible = true
	_show_view()
	opened.emit()

func close_console() -> void:
	if not is_open: return
	_hide_panel(_paused_before)
	closed.emit()

func _hide_panel(paused_after: bool) -> void:
	is_open = false
	if panel_root != null: panel_root.visible = false
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and panel_root != null and panel_root.is_ancestor_of(focused): focused.release_focus()
	get_tree().paused = paused_after

## 按解锁状态切换显示：未解锁只给口令弹窗，解锁后给完整面板。
func _show_view() -> void:
	if not _built: return
	prompt_box.visible = not unlocked
	main_panel.visible = unlocked
	_update_state()
	if unlocked:
		show_tab(current_tab)
	else:
		prompt_edit.clear()
		prompt_message.text = ""
		call_deferred("_grab_prompt")

func _grab_prompt() -> void:
	if not is_open or unlocked or not is_inside_tree() or prompt_edit == null: return
	prompt_edit.grab_focus()
	# 口令是英文；关闭输入法组字，避免中文输入法把 super 吞成拼音候选。
	DisplayServer.window_set_ime_active(false)

func lock() -> void:
	unlocked = false
	_update_state()
	if is_open: _show_view()

func _unlock() -> void:
	unlocked = true
	_update_state()
	_say("调试控制台已解锁。左侧选页操作；Esc 或 ~ 关闭，下次按 ~ 直接打开本面板。", "ok")
	if is_open: _show_view()

func _update_state() -> void:
	if state_label == null: return
	state_label.text = "已解锁" if unlocked else "未解锁"
	state_label.add_theme_color_override("font_color", DebugTheme.OK if unlocked else DebugTheme.DIM)

## 给任意 LineEdit 加上过滤：切换键产生的字符（含输入法下的间隔号）不进入输入内容。
func guard_line_edit(edit: LineEdit) -> void:
	edit.text_changed.connect(_strip_toggle_chars.bind(edit))

func _strip_toggle_chars(value: String, edit: LineEdit) -> void:
	var cleaned := value
	for code in TOGGLE_UNICODE: cleaned = cleaned.replace(String.chr(code), "")
	if cleaned == value: return
	var caret := edit.caret_column - (value.length() - cleaned.length())
	edit.text = cleaned
	edit.caret_column = clampi(caret, 0, cleaned.length())

func _on_prompt_submitted(text: String) -> void:
	prompt_edit.clear()
	submit(text)

# ---------- 提交与输出 ----------

## 提交一行输入：未解锁时只认 super，解锁后交给命令表。图形按钮和测试都走这里。
func submit(line: String) -> void:
	var text := line.strip_edges()
	if text.is_empty() or _submitting: return
	_submitting = true
	_say("> " + text, "echo")
	if not unlocked:
		if text.to_lower() == UNLOCK_WORD:
			_unlock()
		else:
			_say("未知命令。", "error")
			if prompt_message != null: prompt_message.text = "口令不对，请重新输入。"
	elif commands == null:
		_say("控制台尚未绑定游戏。", "error")
	else:
		await commands.execute(text)
	_submitting = false

## 图形界面的统一入口：执行一条命令，结束后刷新当前页。
func run(line: String) -> void:
	await submit(line)
	refresh_tabs()

## 图形界面的自动推进入口。label 是写进日志的等价命令说明。
func run_autoplay(options: Dictionary, label: String = "") -> void:
	if not unlocked or commands == null or _submitting: return
	_submitting = true
	_say("> " + (label if not label.is_empty() else "auto"), "echo")
	await commands.run_autoplay(options)
	_submitting = false
	refresh_tabs()

func _on_output(kind: String, text: String) -> void:
	if kind == "progress":
		if progress_label != null: progress_label.text = text
		if busy_label != null: busy_label.text = text
		if banner_label != null and live_mode and not text.is_empty(): banner_label.text = text
		return
	_say(text, kind)

func say(text: String, kind: String = "info") -> void:
	_say(text, kind)

func _say(text: String, kind: String = "info") -> void:
	log_count += 1
	log_lines.append(text)
	if log_lines.size() > MAX_LOG_LINES: log_lines.remove_at(0)
	if output_label != null: _append_line(text, kind)

func _append_line(text: String, kind: String) -> void:
	output_label.push_color(DebugTheme.LOG_COLORS.get(kind, DebugTheme.TEXT))
	output_label.add_text(text)
	output_label.pop()
	output_label.newline()
	while output_label.get_paragraph_count() > MAX_PARAGRAPHS: output_label.remove_paragraph(0)

func clear_log() -> void:
	if output_label != null: output_label.clear()
	log_lines.clear()

func copy_log() -> void:
	DisplayServer.clipboard_set("\n".join(log_lines))

# ---------- 实机演示与忙碌状态 ----------

func _on_live_changed(active: bool) -> void:
	live_mode = active
	if active:
		_ensure_built()
		_hide_panel(false)
		banner.visible = true
		banner_label.text = "准备开始……"
		busy_overlay.visible = false
	else:
		banner.visible = false
		# 演示结束：重新打开面板并切到自动推进页，报告随后到达。
		open_console()
		show_tab("autoplay")

func _on_busy_changed(busy: bool) -> void:
	busy_overlay.visible = busy and not live_mode and is_open
	if not busy: busy_label.text = ""
	if tabs.has("autoplay") and tabs.autoplay.built: tabs.autoplay.busy_changed(busy)

# ---------- 屏幕状态信息 ----------

func set_hud(enabled: bool) -> void:
	hud_enabled = enabled
	hud_label.visible = enabled
	_hud_next = 0

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _built and commands != null:
		var busy: bool = commands.busy
		if busy != _busy_seen:
			_busy_seen = busy
			_on_busy_changed(busy)
		elif busy and is_open and not live_mode and not busy_overlay.visible: busy_overlay.visible = true
		if is_open and unlocked and current_tab == "overview" and now >= _refresh_next:
			_refresh_next = now + OVERVIEW_REFRESH_MS
			tabs.overview.refresh()
	if not hud_enabled or app == null or not is_instance_valid(app): return
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
