extends VBoxContainer
## 控制台页签的公共基类：首次显示时构建，之后每次显示都刷新；
## 按钮一律通过控制台发出命令串，所以界面操作和命令行走同一条路径、同一份日志。
const DebugTheme = preload("res://systems/debug_console/debug_theme.gd")

var console: CanvasLayer
var built := false

func setup(host: CanvasLayer) -> void:
	console = host
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

func ensure_built() -> void:
	if not built:
		built = true
		build()

func show_tab() -> void:
	ensure_built()
	refresh()

## 子类重写：创建控件，只调用一次。
func build() -> void:
	pass

## 子类重写：按当前游戏状态更新显示，应当轻量。
func refresh() -> void:
	pass

func app() -> Control:
	return console.app

func session() -> Node:
	return console.app.session

func config() -> RefCounted:
	return console.app.session.config

## 游戏是否已经开始一局（标题界面没有可操作的案件状态）。
func in_game() -> bool:
	return console.app.current_layer != "title" and not console.app.session.run_id.is_empty()

# ---------- 控件工厂 ----------

func heading(text: String, parent: Node = null) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", DebugTheme.ACCENT_TEXT)
	if parent != null: parent.add_child(label)
	return label

func hint(text: String, parent: Node = null) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", DebugTheme.DIM)
	if parent != null: parent.add_child(label)
	return label

func caption(text: String, parent: Node = null) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", DebugTheme.DIM)
	if parent != null: parent.add_child(label)
	return label

func make_button(text: String, callback: Callable, parent: Node = null, tip: String = "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	if parent != null: parent.add_child(button)
	return button

## 点击后把一条命令送进控制台执行（带回显、写日志、结束后刷新）。
func run_button(text: String, line: String, parent: Node = null, tip: String = "") -> Button:
	return make_button(text, func(): console.run(line), parent, tip if not tip.is_empty() else line)

func hbox(parent: Node = null, gap: int = 8) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", gap)
	if parent != null: parent.add_child(box)
	return box

func flow(parent: Node = null, gap: int = 6) -> HFlowContainer:
	var box := HFlowContainer.new()
	box.add_theme_constant_override("h_separation", gap)
	box.add_theme_constant_override("v_separation", gap)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null: parent.add_child(box)
	return box

func check_box(text: String, parent: Node = null, pressed: bool = false) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = pressed
	box.focus_mode = Control.FOCUS_NONE
	if parent != null: parent.add_child(box)
	return box

func option_button(items: Array, parent: Node = null, selected: int = 0) -> OptionButton:
	var option := OptionButton.new()
	option.focus_mode = Control.FOCUS_NONE
	option.fit_to_longest_item = true
	for item in items: option.add_item(str(item))
	if not items.is_empty(): option.select(clampi(selected, 0, items.size() - 1))
	if parent != null: parent.add_child(option)
	return option

func line_edit(placeholder: String, parent: Node = null) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.clear_button_enabled = true
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	console.guard_line_edit(edit)
	if parent != null: parent.add_child(edit)
	return edit

## 在 parent 里放一个只纵向滚动的容器。内容再高也不会撑高页面：页面的最小高度由这里决定，而不是由内容决定。
func scroll_in(parent: Node) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	return scroll

## 整页可滚动：返回放内容的 VBox，横向不滚动。
func scrolled() -> VBoxContainer:
	var scroll := scroll_in(self)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)
	return content

## 建一棵带列标题的树。columns 每项 {title, width, expand}。
func make_tree(columns: Array, parent: Node = null, multi: bool = false) -> Tree:
	var tree := Tree.new()
	tree.columns = columns.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_MULTI if multi else Tree.SELECT_ROW
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.focus_mode = Control.FOCUS_CLICK
	for index in range(columns.size()):
		var spec: Dictionary = columns[index]
		tree.set_column_title(index, str(spec.get("title", "")))
		tree.set_column_expand(index, bool(spec.get("expand", false)))
		tree.set_column_custom_minimum_width(index, int(spec.get("width", 60)))
		tree.set_column_clip_content(index, true)
	if parent != null: parent.add_child(tree)
	return tree

func selected_items(tree: Tree) -> Array:
	var found: Array = []
	var item := tree.get_next_selected(null)
	while item != null:
		found.append(item)
		item = tree.get_next_selected(item)
	return found

func color_item(item: TreeItem, columns: int, color: Color) -> void:
	for column in range(columns): item.set_custom_color(column, color)
