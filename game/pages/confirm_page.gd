extends Control
## 确认页只负责确认文案、按钮状态和用户选择。

signal cancelled
signal direct_requested
signal accepted

var panel: PanelContainer
var box: VBoxContainer
var cancel_button: Button
var direct_button: Button
var accept_button: Button

func _ready() -> void:
	_build_page()
	hide()

func _build_page() -> void:
	var host := CenterContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 0)
	host.add_child(panel)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var detail := Label.new()
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	cancel_button = _button("取消", cancelled.emit)
	direct_button = _button("直接返回", direct_requested.emit)
	accept_button = _button("确认", accepted.emit)

func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	box.add_child(button)
	return button

func open(title: String, detail: String, direct_text: String, accept_text: String, show_direct: bool, show_accept: bool) -> void:
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	direct_button.text = direct_text
	direct_button.visible = show_direct
	accept_button.text = accept_text
	accept_button.visible = show_accept
	show()
	cancel_button.grab_focus()

func close_page() -> void:
	hide()
