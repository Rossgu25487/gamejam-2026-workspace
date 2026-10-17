extends Control
## 保存页只负责手动存档栏位的显示、焦点和点击处理。

signal closed # 保存完成或用户关闭后返回来源页面。
signal saved # 只在成功写入后通知调度层，可用于保存后离开。

var save_service: Node
var eligibility: Callable
var snapshot: Dictionary = {}
var panel: PanelContainer
var box: VBoxContainer
var selected_slot := 0
var exclusion := -1
var submit_button: Button
var status_label: Label
var slot_buttons: Array[Button] = []
var confirmation: Control
var success_timer: Timer
var session: Node

func bind_session(value: Node) -> void:
	session = value

func _ready() -> void:
	# 保存页控件只创建一次。
	_build_page()
	success_timer = Timer.new()
	success_timer.one_shot = true
	add_child(success_timer)
	success_timer.timeout.connect(func(): status_label.text = "请选择一个手动栏位，再点击保存。")
	hide()

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "save")

func _build_page() -> void:
	# 创建三个手动栏位和关闭按钮。
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
		slot_buttons.append(button)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)
	submit_button = _button("保存", _submit)
	var close := Button.new()
	close.text = "关闭保存"
	close.pressed.connect(_close_requested)
	box.add_child(close)
	confirmation = preload("res://pages/confirm_page.tscn").instantiate()
	add_child(confirmation)
	confirmation.cancelled.connect(_cancel_overwrite)
	confirmation.accepted.connect(_write)

func _button(title: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(callback)
	box.add_child(button)
	return button

func open(service: Node, current_snapshot: Dictionary, excluded_slot: int = -1) -> void:
	# 保存打开瞬间复制快照，避免页面操作期间引用被外部修改。
	save_service = service
	if slot_buttons.size() != service.manual_slot_count:
		for button in slot_buttons: box.remove_child(button); button.queue_free()
		slot_buttons.clear()
		for index in range(service.manual_slot_count):
			var button := Button.new()
			button.pressed.connect(_save_slot.bind(index))
			box.add_child(button)
			box.move_child(button, 2 + index)
			slot_buttons.append(button)
	snapshot = current_snapshot.duplicate(true)
	exclusion = excluded_slot
	success_timer.stop()
	submit_button.text = "保存"
	selected_slot = 1 if excluded_slot == 0 else 0
	for index in range(slot_buttons.size()):
		if index != exclusion and not save_service.slot_info("manual", index).exists:
			selected_slot = index
			break
	status_label.text = "请选择一个手动栏位，再点击保存。"
	confirmation.close_page()
	_refresh_slots()
	show()
	var first := slot_buttons[selected_slot]
	if is_instance_valid(first): first.grab_focus()

func close_page() -> void:
	# 隐藏页面并保留按钮供下次使用。
	hide()
	success_timer.stop()
	confirmation.close_page()

func _save_slot(index: int) -> void:
	# 点击条目只选中；覆盖旧档须显式确认，不因浏览栏位写盘。
	if index == exclusion or confirmation.visible or save_service.busy: return
	selected_slot = index
	_refresh_slots()

func _refresh_slots() -> void:
	for index in range(slot_buttons.size()):
		var info: Dictionary = save_service.slot_info("manual", index)
		var button := slot_buttons[index]
		button.disabled = index == exclusion
		button.text = save_service.slot_label("manual", index) + "\n" + info.summary
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size.x = 460
		button.tooltip_text = "待读取目标，不能覆盖" if button.disabled else info.get("full_summary", info.summary)
		button.modulate = Color(1, 0.85, 0.5) if index == selected_slot else Color.WHITE

func _submit() -> void:
	if save_service.busy or selected_slot == exclusion or confirmation.visible: return
	var info: Dictionary = save_service.slot_info("manual", selected_slot)
	if info.exists:
		confirmation.open("覆盖存档", "覆盖手动存档 %d？\n%s" % [selected_slot + 1, info.summary], "", "确认覆盖", false, true)
	else: _write()

func _write() -> void:
	if save_service.busy or selected_slot == exclusion: return
	confirmation.close_page()
	# 每次提交和重试取同一公开会话的新快照，并复核原页资格。
	if session != null:
		if not session.can_save() or (eligibility.is_valid() and not eligibility.call()):
			status_label.text = session.save_disabled_reason()
			return
		snapshot = session.export_snapshot()
	if save_service.save_snapshot("manual", selected_slot, snapshot):
		_refresh_slots()
		submit_button.text = "保存"
		status_label.text = "保存完成"
		success_timer.start(2.0)
		submit_button.grab_focus()
		saved.emit()
	else:
		status_label.text = "保存失败，原存档与当前会话已保留。可重试或选择其他栏位。"
		submit_button.text = "重试"

func _cancel_overwrite() -> void:
	confirmation.close_page()
	submit_button.grab_focus()

func _close_requested() -> void:
	if save_service.busy: return
	if confirmation.visible: _cancel_overwrite()
	else: closed.emit()

func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_close_requested()
		get_viewport().set_input_as_handled()
