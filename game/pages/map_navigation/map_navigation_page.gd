extends Control
## 地图页维护自己的节点、列表、预览和焦点；资格与切换事务由服务校验。

signal closed

const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var refresh_queued := false
var return_focus: Control
var panel: PanelContainer

func bind(value: Node) -> void:
	service = value
	if service != null and service.has_method("bind_visual_controller"): service.bind_visual_controller()
	if service != null and not service.changed.is_connected(_queue_render): service.changed.connect(_queue_render)
	if service != null and not service.phase_changed.is_connected(_on_phase_changed): service.phase_changed.connect(_on_phase_changed)
	if service != null and not service.transition_completed.is_connected(_on_transition_completed): service.transition_completed.connect(_on_transition_completed)
	_queue_render()

func open() -> void:
	if service != null and service.open():
		return_focus = get_viewport().gui_get_focus_owner()
		show()
		_queue_render()

func close() -> void:
	if service != null: service.cancel()
	# 移动期间服务拒绝关闭，界面必须继续拦住下层调查输入。
	if service != null and not service.state.get("open", false): _hide_map(true)

func _ready() -> void:
	hide()
	mouse_filter = Control.MOUSE_FILTER_STOP

func _queue_render() -> void:
	# 状态和阶段信号可能在同一按钮回调中连续发出，每帧只重建一次。
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_render")

func _render() -> void:
	refresh_queued = false
	if not is_inside_tree() or service == null or not visible: return
	# 旧按钮先脱离树再延迟释放，避免同帧重叠触区和发信号时释放自身。
	UI.clear(self)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = PanelContainer.new()
	panel.name = "MapPanel"
	panel.custom_minimum_size = Vector2(720, 560)
	center.add_child(panel)
	var margin := MarginContainer.new()
	for edge in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 16)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)
	UI.label(box, "地图", 30)
	UI.label(box, "当前地点：" + service.scene_name(service.current_scene_id()), 18)
	var phase: String = service.state.get("phase", "closed")
	var busy := phase in ["preparing", "moving", "arrival_hold", "transitioning"]
	var records: Array = service.location_records()
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	box.add_child(content)
	var board := VBoxContainer.new()
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(board)
	UI.label(board, "地点节点", 20)
	var board_scroll := _scroll(board)
	var nodes := GridContainer.new()
	nodes.columns = 2
	nodes.add_theme_constant_override("h_separation", 12)
	nodes.add_theme_constant_override("v_separation", 12)
	board_scroll.add_child(nodes)
	var sidebar := VBoxContainer.new()
	sidebar.custom_minimum_size.x = 220
	content.add_child(sidebar)
	UI.label(sidebar, "地点列表", 20)
	var list_scroll := _scroll(sidebar)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	list_scroll.add_child(list)
	var selected_button: Button
	for item in records:
		var scene_id := str(item.to_scene)
		var status := "当前位置" if item.current else ("可前往" if item.available else "暂不可前往")
		for target in [nodes, list]:
			# 已公开但不可达的地点仍可选中查看原因，只有前往动作受资格限制。
			var button := UI.button(target, str(item.title) + "\n" + status, service.select_scene.bind(scene_id), not busy)
			button.set_meta("scene_id", scene_id)
			button.set_meta("map_role", "node" if target == nodes else "list")
			button.custom_minimum_size = Vector2(160 if target == nodes else 200, 64)
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.tooltip_text = str(item.reason) if not item.available else "点击预览，再点击前往"
			if item.selected and target == nodes: selected_button = button
	var preview: Dictionary = service.preview_scene(str(service.state.get("selected_scene_id", "")))
	UI.label(box, "预览：" + str(preview.get("title", "请选择地点")), 20)
	var reason: String = service.travel_disabled_reason()
	if phase == "failure": reason = "切换失败：" + str(service.state.get("failure_reason", "请重新选择地点"))
	UI.label(box, reason if not reason.is_empty() else "确认后前往选中地点", 16)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	box.add_child(actions)
	var travel_button := UI.button(actions, "前往", service.travel, service.travel_disabled_reason().is_empty())
	travel_button.tooltip_text = service.travel_disabled_reason()
	UI.button(actions, "返回调查", close, not busy)
	if is_instance_valid(selected_button) and not selected_button.disabled: selected_button.grab_focus()

func _scroll(parent: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 220
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	return scroll

func _on_phase_changed(phase: String) -> void:
	if phase == "moving":
		# 简化版页面动画：服务先提交状态，页面在下一帧完成到达确认与转场。
		call_deferred("_complete_visual_transition")
	_queue_render()

func _complete_visual_transition() -> void:
	if service == null: return
	if service.state.get("phase") == "moving": service.finish_movement()
	if service.state.get("phase") == "arrival_hold": service.begin_transition()
	if service.state.get("phase") == "transitioning": service.finish_transition()

func _on_transition_completed(_scene_id: String) -> void:
	_hide_map(false)

func _hide_map(restore_focus: bool) -> void:
	hide()
	if restore_focus and is_instance_valid(return_focus) and return_focus.is_visible_in_tree(): return_focus.grab_focus()
	closed.emit()
