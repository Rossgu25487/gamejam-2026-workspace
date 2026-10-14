extends Control
## 地图页面私有逻辑：显示当前地点、可达节点和前往/取消操作。

const UI = preload("res://pages/core/page_controls.gd")
var service: Node

func bind(value: Node) -> void:
	service = value
	if service != null and service.has_method("bind_visual_controller"): service.bind_visual_controller()
	if service != null and not service.changed.is_connected(_render): service.changed.connect(_render)
	if service != null and not service.phase_changed.is_connected(_on_phase_changed): service.phase_changed.connect(_on_phase_changed)
	if service != null and not service.transition_completed.is_connected(_on_transition_completed): service.transition_completed.connect(_on_transition_completed)
	_render()

func open() -> void:
	if service != null and service.open():
		show()
		_render()

func close() -> void:
	if service != null: service.cancel()
	hide()

func _ready() -> void:
	hide()
	mouse_filter = Control.MOUSE_FILTER_STOP

func _render() -> void:
	if not is_inside_tree() or service == null or not visible: return
	for child in get_children(): child.queue_free()
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 560)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	UI.label(box, "地图", 30)
	UI.label(box, "当前地点：" + service.current_scene_id(), 18)
	var phase: String = service.state.get("phase", "closed")
	if phase == "failure": UI.label(box, "切换失败：" + str(service.state.get("failure_reason", "请重试")), 16)
	var board := PanelContainer.new()
	board.custom_minimum_size = Vector2(420, 220)
	box.add_child(board)
	var board_box := VBoxContainer.new()
	board.add_child(board_box)
	UI.label(board_box, "货运站地图", 22)
	UI.label(board_box, "点击地点先预览，确认后再前往", 14)
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list)
	for item in service.available_transitions():
		var title := str(item.get("title", item.get("to_scene", "前往")))
		if item.get("selected", false):
			UI.label(box, "预览：" + str(item.get("to_scene", "")), 16)
		if not bool(item.get("available", false)): title += "（" + str(item.reason) + "）"
		var button := UI.button(list, title, service.select_transition.bind(str(item.transition_id)), bool(item.available))
		if item.selected: button.grab_focus()
	var travel_button := UI.button(box, "前往", service.travel)
	travel_button.disabled = str(service.state.get("selected_transition_id", "")).is_empty()
	if phase in ["preparing", "moving", "arrival_hold", "transitioning"]: travel_button.disabled = true
	UI.button(box, "返回调查", close)

func _on_phase_changed(phase: String) -> void:
	if phase == "moving":
		# 简化版页面动画：服务先提交状态，页面在下一帧完成到达确认与转场。
		call_deferred("_complete_visual_transition")
	_render()

func _complete_visual_transition() -> void:
	if service == null: return
	if service.state.get("phase") == "moving": service.finish_movement()
	if service.state.get("phase") == "arrival_hold": service.begin_transition()
	if service.state.get("phase") == "transitioning": service.finish_transition()

func _on_transition_completed(_scene_id: String) -> void:
	hide()
