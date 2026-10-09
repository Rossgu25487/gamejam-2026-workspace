extends Control
## 保存页只负责手动存档栏位的显示、焦点和点击处理。

signal closed

var save_service: Node
var snapshot: Dictionary = {}
var panel: PanelContainer
var box: VBoxContainer

func _ready() -> void:
	_build_page()
	hide()

func _build_page() -> void:
	var host := CenterContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	host.add_child(panel)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "保存存档"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var detail := Label.new()
	detail.text = "请选择一个手动存档栏位。"
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	for index in range(3):
		var button := Button.new()
		button.text = "手动存档 %d" % (index + 1)
		button.pressed.connect(_save_slot.bind(index))
		box.add_child(button)
	var close := Button.new()
	close.text = "关闭保存"
	close.pressed.connect(closed.emit)
	box.add_child(close)

func open(service: Node, current_snapshot: Dictionary) -> void:
	save_service = service
	snapshot = current_snapshot.duplicate(true)
	show()
	var first := box.get_child(2) as Button
	if is_instance_valid(first): first.grab_focus()

func close_page() -> void:
	hide()

func _save_slot(index: int) -> void:
	if is_instance_valid(save_service) and save_service.save_snapshot("manual", index, snapshot):
		closed.emit()
