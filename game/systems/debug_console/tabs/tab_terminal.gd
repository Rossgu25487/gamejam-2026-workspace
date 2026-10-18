extends "res://systems/debug_console/tabs/tab_base.gd"
## 命令行页（进阶）：所有图形按钮背后都是命令，这里可以直接输入。
## 上下键翻历史，Tab 补全命令与 ID；双击命令表中的一行把用法填进输入框。
const MAX_HISTORY := 100
var input_edit: LineEdit
var reference: Tree
var _history: Array[String] = []
var _cursor := 0

func build() -> void:
	hint("命令行是进阶功能，常规操作请用左侧各页。命令的输出显示在下方日志里。", self)
	reference = make_tree([{"title": "命令", "width": 90}, {"title": "分组", "width": 80}, {"title": "用法", "width": 300, "expand": true}, {"title": "说明", "width": 360, "expand": true}], self)
	reference.item_activated.connect(_insert_usage)
	var row := hbox(self)
	var prompt := Label.new()
	prompt.text = ">"
	prompt.add_theme_color_override("font_color", DebugTheme.OK)
	row.add_child(prompt)
	input_edit = LineEdit.new()
	input_edit.name = "ConsoleInput"
	input_edit.placeholder_text = "输入命令，如 give E01、jump 3、auto -s random；help 查看全部"
	input_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_edit.add_theme_font_override("font", DebugTheme.make_font(true))
	console.guard_line_edit(input_edit)
	input_edit.text_submitted.connect(_submitted)
	input_edit.gui_input.connect(_on_gui_input)
	row.add_child(input_edit)
	make_button("执行", func(): _submitted(input_edit.text), row)
	_fill_reference()
	console.input_edit = input_edit

func _fill_reference() -> void:
	reference.clear()
	var root := reference.create_item()
	for name in console.commands.registry:
		var entry: Dictionary = console.commands.registry[name]
		var item := reference.create_item(root)
		item.set_metadata(0, str(name))
		item.set_text(0, str(name))
		item.set_text(1, str(entry.group))
		item.set_text(2, str(entry.usage))
		item.set_text(3, str(entry.brief))
		item.set_tooltip_text(2, str(entry.detail) if not str(entry.detail).is_empty() else str(entry.brief))

func focus_input() -> void:
	if input_edit == null or not input_edit.is_inside_tree() or not input_edit.is_visible_in_tree(): return
	input_edit.grab_focus()
	# 命令都是英文与 ID；关闭输入法组字，避免中文输入法把 super 之类吞成拼音候选。
	DisplayServer.window_set_ime_active(false)

func show_tab() -> void:
	super.show_tab()
	call_deferred("focus_input")

func _insert_usage(_arg = null) -> void:
	var item := reference.get_selected()
	if item == null: return
	input_edit.text = str(item.get_metadata(0)) + " "
	input_edit.caret_column = input_edit.text.length()
	focus_input()

func _submitted(text: String) -> void:
	var line := text.strip_edges()
	input_edit.clear()
	if line.is_empty(): return
	if _history.is_empty() or _history.back() != line: _history.append(line)
	if _history.size() > MAX_HISTORY: _history.remove_at(0)
	_cursor = _history.size()
	await console.run(line)
	focus_input()

func _on_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed: return
	match key.keycode:
		KEY_UP:
			_step_history(-1)
			input_edit.accept_event()
		KEY_DOWN:
			_step_history(1)
			input_edit.accept_event()
		KEY_TAB:
			_complete()
			input_edit.accept_event()

func _step_history(direction: int) -> void:
	if _history.is_empty(): return
	_cursor = clampi(_cursor + direction, 0, _history.size())
	input_edit.text = "" if _cursor >= _history.size() else _history[_cursor]
	input_edit.caret_column = input_edit.text.length()

func _complete() -> void:
	var line := input_edit.text
	var options: Array = console.commands.completions(line)
	if options.is_empty(): return
	var start := line.length() if (line.ends_with(" ") or line.ends_with("\u3000")) else maxi(line.rfind(" "), line.rfind("\u3000")) + 1
	var prefix := line.substr(0, start)
	if options.size() == 1:
		input_edit.text = prefix + str(options[0]) + " "
	else:
		input_edit.text = prefix + _common_prefix(options)
		console.say("  " + "  ".join(options.slice(0, 24)) + ("  ……" if options.size() > 24 else ""), "dim")
	input_edit.caret_column = input_edit.text.length()

func _common_prefix(options: Array) -> String:
	var prefix := str(options[0])
	for option in options:
		var text := str(option)
		var length := 0
		while length < prefix.length() and length < text.length() and prefix[length].to_lower() == text[length].to_lower(): length += 1
		prefix = prefix.substr(0, length)
	return prefix
