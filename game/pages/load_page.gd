extends Control
## 读取页只负责有效存档列表、焦点和读取结果展示。

signal closed
signal loaded(snapshot: Dictionary)

var save_service: Node
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
	panel.custom_minimum_size = Vector2(420, 0)
	host.add_child(panel)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "读取存档"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var detail := Label.new()
	detail.text = "请选择有效存档；读取失败会保留当前会话。"
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	var close := Button.new()
	close.text = "关闭读取"
	close.pressed.connect(closed.emit)
	box.add_child(close)

func open(service: Node) -> void:
	save_service = service
	_clear_records()
	var records: Array = save_service.scan() if is_instance_valid(save_service) else []
	if records.is_empty():
		var empty := Label.new()
		empty.text = "没有可读取的有效存档"
		box.add_child(empty)
	else:
		for record in records:
			_add_record_button(record)
	show()
	var focus_index := 3 if not records.is_empty() else 2
	var focus_control := box.get_child(focus_index) as Control
	if is_instance_valid(focus_control): focus_control.grab_focus()

func close_page() -> void:
	hide()

func _clear_records() -> void:
	# 先从容器移除旧条目，再延迟释放节点，确保读取回调结束后可以再次打开页面。
	for index in range(box.get_child_count() - 1, 2, -1):
		var old_record := box.get_child(index)
		box.remove_child(old_record)
		old_record.queue_free()

func _add_record_button(record: Dictionary) -> void:
	var kind := str(record.get("slot_kind", "manual"))
	var index := int(record.get("slot_index", 0))
	var button := Button.new()
	button.text = "%s %d  |  序号 %s" % [kind, index + 1, str(record.get("save_sequence", "-"))]
	button.pressed.connect(_load_slot.bind(kind, index))
	box.add_child(button)

func _load_slot(kind: String, index: int) -> void:
	var record: Dictionary = save_service.load_snapshot(kind, index) if is_instance_valid(save_service) else {}
	if not record.is_empty():
		loaded.emit(record)
