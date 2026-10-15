extends ScrollContainer
## 目标导航共用的滚动区：滚轮永远由本区处理（到首尾也不传给背后的场景或另一分区），
## 方向键滚一行，PageUp/PageDown 滚一屏并保留一行衔接；只有内容需要滚动且可见时才可 Tab 选中。

signal scrolled # 滚动位置发生变化

var line_px := 30
var content: VBoxContainer


func _init() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 需要时才显示滚动条，但始终预留其宽度，换行宽度不随滚动条出现而变化。
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(content)


func _ready() -> void:
	var bar := get_v_scroll_bar()
	bar.changed.connect(_update_focus)
	bar.value_changed.connect(func(_value: float): scrolled.emit())
	visibility_changed.connect(_update_focus)


func max_scroll() -> int:
	var bar := get_v_scroll_bar()
	return maxi(0, int(ceil(bar.max_value - bar.page)))


func is_scrollable() -> bool:
	return max_scroll() > 0


func page_px() -> int:
	return int(get_v_scroll_bar().page)


func scroll_by(delta: int) -> void:
	scroll_vertical = clampi(scroll_vertical + delta, 0, max_scroll())


func scroll_to(value: int) -> void:
	scroll_vertical = clampi(value, 0, max_scroll())


func wheel_px() -> int:
	# 一格滚轮约三行，较矮的列表不超过半屏。
	return maxi(line_px, mini(line_px * 3, page_px() / 2))


func _update_focus() -> void:
	# 内容不需要滚动或区域不可见时不参与 Tab，也不保留焦点。
	var focusable := is_scrollable() and is_visible_in_tree()
	var mode := Control.FOCUS_ALL if focusable else Control.FOCUS_NONE
	if focus_mode == mode:
		return
	focus_mode = mode
	if not focusable and has_focus():
		release_focus()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if not event.pressed:
			return
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				scroll_by(-wheel_px())
			MOUSE_BUTTON_WHEEL_DOWN:
				scroll_by(wheel_px())
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT:
				pass # 不横向滚动，但同样不向下层传播
			_:
				return
		accept_event()
	elif event is InputEventKey and event.pressed and has_focus():
		match event.keycode:
			KEY_UP:
				scroll_by(-line_px)
			KEY_DOWN:
				scroll_by(line_px)
			KEY_PAGEUP:
				scroll_by(-maxi(line_px, page_px() - line_px))
			KEY_PAGEDOWN:
				scroll_by(maxi(line_px, page_px() - line_px))
			_:
				return
		accept_event()
