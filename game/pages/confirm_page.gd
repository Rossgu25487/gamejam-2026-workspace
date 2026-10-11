extends Control
## 页面自行读取装饰图片，确认动作仍由原信号通知调度层。

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "confirm")

## 确认页只负责确认文案、按钮状态和用户选择。

signal cancelled # 用户取消离开。
signal direct_requested # 用户选择直接返回或退出。
signal accepted # 用户选择确认保存后离开。

var panel: PanelContainer
var box: VBoxContainer
var cancel_button: Button
var direct_button: Button
var accept_button: Button

func _ready() -> void:
	# 页面创建一次，后续打开时只更新文字和按钮状态。
	_build_page()
	hide()

func _build_page() -> void:
	# 所有确认页控件由本节点创建，避免 Main 持有私有界面逻辑。
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
	# 统一创建并连接确认页按钮。
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	box.add_child(button)
	return button

func open(title: String, detail: String, direct_text: String, accept_text: String, show_direct: bool, show_accept: bool) -> void:
	# 根据调用场景配置确认文案和可见按钮。
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	direct_button.text = direct_text
	direct_button.visible = show_direct
	accept_button.text = accept_text
	accept_button.visible = show_accept
	show()
	cancel_button.grab_focus()

func close_page() -> void:
	# 隐藏页面，保留控件供下次复用。
	hide()
