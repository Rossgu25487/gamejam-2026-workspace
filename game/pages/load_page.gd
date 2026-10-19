extends Control
## 读取页只负责有效存档列表、焦点和读取结果展示。

signal closed # 用户关闭读取页。
signal loaded(snapshot: Dictionary) # 成功读取后把完整快照交给主程序。
signal save_first_requested(target: Dictionary)

var save_service: Node
var panel: PanelContainer
var box: VBoxContainer
var selected := {"slot_kind": "manual", "slot_index": 0}
var allow_replace := false
var allow_save_first := false
var confirmation: Control
var load_button: Button
var status_label: Label
var formal_layout: RefCounted
var slot_buttons: Array[Button] = []

func _ready() -> void:
	# 页面只初始化一次，重复打开通过 open() 刷新列表。
	_build_page()
	hide()

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "load")

func _build_page() -> void:
	# 创建读取页标题、说明和关闭按钮。
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
	formal_layout = preload("res://pages/aurora/aurora_save_layout.gd").new()
	formal_layout.bind(self, "load", panel, box, close)
	confirmation = preload("res://pages/confirm_page.tscn").instantiate()
	add_child(confirmation)
	confirmation.cancelled.connect(cancel_confirmation)
	confirmation.direct_requested.connect(_read_selected)
	confirmation.accepted.connect(_save_first)
	formal_layout.bind_confirmation(confirmation)

func open(service: Node, replacing: bool = false, can_save_current: bool = false) -> void:
	# 扫描磁盘中的有效栏位并重新生成当前列表。
	save_service = service
	allow_replace = replacing
	allow_save_first = can_save_current
	_clear_records()
	var records: Array = save_service.scan()
	selected = {"slot_kind": "manual", "slot_index": 0}
	if not records.is_empty(): selected = {"slot_kind": records[0].slot_kind, "slot_index": records[0].slot_index}
	for kind in ["manual", "auto", "pre_accusation"]:
		for index in range(service.manual_slot_count if kind == "manual" else 1): _add_record_button({"slot_kind": kind, "slot_index": index})
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)
	load_button = Button.new()
	load_button.text = "读取"
	load_button.pressed.connect(_request_load)
	box.add_child(load_button)
	formal_layout.set_records(slot_buttons, load_button, status_label)
	_refresh_selected()
	for index in range(slot_buttons.size()):
		if str(slot_buttons[index].get_meta("slot_kind")) == selected.slot_kind and int(slot_buttons[index].get_meta("slot_index")) == int(selected.slot_index): formal_layout.reveal(index)
	show()
	var focus_control: Control = slot_buttons[0] if not slot_buttons.is_empty() else formal_layout.close
	if is_instance_valid(focus_control): focus_control.grab_focus()

func close_page() -> void:
	# 隐藏读取页，不销毁页面本身。
	hide()
	confirmation.close_page()

func _clear_records() -> void:
	for button in slot_buttons:
		button.get_parent().remove_child(button)
		button.queue_free()
	slot_buttons.clear()
	for control in [status_label, load_button]:
		if is_instance_valid(control):
			control.get_parent().remove_child(control)
			control.queue_free()
	# 先从容器移除旧条目，再延迟释放节点，确保读取回调结束后可以再次打开页面。
	for index in range(box.get_child_count() - 1, 2, -1):
		var old_record := box.get_child(index)
		box.remove_child(old_record)
		old_record.queue_free()

func _add_record_button(record: Dictionary) -> void:
	# 每个按钮只保存栏位身份，读取时再由服务校验和加载。
	var kind := str(record.get("slot_kind", "manual"))
	var index := int(record.get("slot_index", 0))
	var button := Button.new()
	var info: Dictionary = save_service.slot_info(kind, index)
	button.text = save_service.slot_label(kind, index) + "\n" + info.summary
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size = Vector2.ZERO
	button.tooltip_text = info.get("full_summary", info.summary)
	button.set_meta("slot_kind", kind)
	button.set_meta("slot_index", index)
	button.pressed.connect(_load_slot.bind(kind, index))
	box.add_child(button)
	slot_buttons.append(button)

func _load_slot(kind: String, index: int) -> void:
	# 列表点击只预览，不替换会话。
	if confirmation.visible or save_service.busy: return
	selected = {"slot_kind": kind, "slot_index": index}
	_refresh_selected()

func _refresh_selected() -> void:
	var info: Dictionary = save_service.slot_info(selected.slot_kind, int(selected.slot_index))
	status_label.text = info.summary
	status_label.tooltip_text = info.get("full_summary", info.summary)
	load_button.disabled = not info.valid
	for button in slot_buttons:
		var kind: String = str(button.get_meta("slot_kind"))
		var index: int = int(button.get_meta("slot_index"))
		formal_layout.decorate(button, save_service.slot_label(kind, index), save_service.slot_info(kind, index), kind == selected.slot_kind and index == int(selected.slot_index))
	formal_layout.layout()

func _request_load() -> void:
	if load_button.disabled or confirmation.visible or save_service.busy: return
	if allow_replace:
		confirmation.open("读取存档", "读取所选存档将替换当前调查。", "直接读取", "先保存当前", true, allow_save_first)
	else: _read_selected()

func _read_selected() -> void:
	if save_service.busy: return
	confirmation.close_page()
	var record: Dictionary = save_service.load_snapshot(str(selected.slot_kind), int(selected.slot_index))
	if not record.is_empty(): loaded.emit(record)
	else:
		status_label.text = "读取失败，当前会话已保留。请选择其他档案或重试。"
		load_button.disabled = not save_service.slot_info(selected.slot_kind, int(selected.slot_index)).valid

func _save_first() -> void:
	if not allow_save_first or not confirmation.visible: return
	confirmation.close_page()
	save_first_requested.emit(selected.duplicate(true))

func resume_confirmation() -> void:
	show()
	_request_load()

func complete_save_first() -> void:
	show()
	_read_selected()

func cancel_confirmation() -> void:
	confirmation.close_page()
	load_button.grab_focus()

func show_restore_failure() -> void:
	# 公开恢复入口也用于继续与测试；未打开列表时没有状态控件。
	if not is_instance_valid(status_label): return
	status_label.text = "目的地必需内容尚未就绪，当前会话已保留。可重试或选择其他档案。"
	load_button.grab_focus()

func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if confirmation.visible: cancel_confirmation()
		else: closed.emit()
		get_viewport().set_input_as_handled()
