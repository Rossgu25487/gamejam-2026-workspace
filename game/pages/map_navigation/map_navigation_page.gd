extends Control
## 地图页维护自己的节点、列表、预览和焦点；资格与切换事务由服务校验。

signal closed

const UI = preload("res://pages/core/page_controls.gd")
const BoardScript = preload("res://pages/map_navigation/map_board.gd")
var service: Node
var refresh_queued := false
var return_focus: Control
var panel: PanelContainer
var board_view: Control
var animation_phase := ""
var animation_ms := 0.0
var animation_step := 1
var route: Array[Vector2] = []
var movement_request := ""
var reduced := false
var selected_group := ""
var cross_switched := false

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
		selected_group = str(service.locations.get(service.current_scene_id(), {}).get("node", {}).get("group_id", ""))
		show()
		_queue_render()

func close() -> void:
	if service != null: service.cancel()
	# 移动期间服务拒绝关闭，界面必须继续拦住下层调查输入。
	if service != null and not service.state.get("open", false): _hide_map(true)

func _ready() -> void:
	hide()
	mouse_filter = Control.MOUSE_FILTER_STOP

func _queue_render(force: bool = false) -> void:
	# 状态和阶段信号可能在同一按钮回调中连续发出，每帧只重建一次。
	if not force and not animation_phase.is_empty() and is_instance_valid(board_view): return
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
	panel.add_theme_stylebox_override("panel", _opaque_panel())
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
	var groups := HBoxContainer.new()
	box.add_child(groups)
	var known_groups: Array[String] = []
	for item in records:
		var group := str(item.node.get("group_id", ""))
		if not group.is_empty() and group not in known_groups: known_groups.append(group)
	for group in known_groups:
		var record: Dictionary = service.map_definition.get("groups", {}).get(group, {})
		var region: String = service.core.ui(str(record.get("region_name_text_id", "")))
		var floor_name: String = service.core.ui(str(record.get("floor_name_text_id", "")))
		var title := str(record.get("name", group)) if region.is_empty() else region + (" / " + floor_name if not floor_name.is_empty() else "")
		UI.button(groups, title, _select_group.bind(group), not busy)
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	box.add_child(content)
	var board := VBoxContainer.new()
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(board)
	UI.label(board, "地点节点", 20)
	var board_scroll := _scroll(board)
	board_scroll.custom_minimum_size.y = 300
	var current_node: Dictionary = service.locations.get(service.current_scene_id(), {}).get("node", {})
	var group_id := selected_group
	var has_board: bool = not current_node.is_empty() and service.map_definition.get("boards", {}).has(group_id)
	var nodes: Control
	if has_board:
		board_view = BoardScript.new()
		board_view.custom_minimum_size = Vector2(420, 300)
		board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		board_view.configure_art(service.map_definition, group_id)
		board_view.setup(records, service.map_definition.boards[group_id], group_id)
		board_view.set_pawn(Vector2(int(current_node.grid_col), int(current_node.grid_row)), 0)
		board_view.pawn_visible = group_id == str(current_node.get("group_id", "")) or not animation_phase.is_empty()
		nodes = board_view
	else:
		board_view = null
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		nodes = grid
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
			if target == nodes and has_board and item.node.get("group_id", "") != group_id: continue
			# 已公开但不可达的地点仍可选中查看原因，只有前往动作受资格限制。
			var button := UI.button(target, str(item.title) + "\n" + status, service.select_scene.bind(scene_id), not busy)
			button.set_meta("scene_id", scene_id)
			button.set_meta("map_role", "node" if target == nodes else "list")
			button.custom_minimum_size = Vector2(160 if target == nodes else 200, 64)
			if target == nodes and has_board:
				button.custom_minimum_size = Vector2(76, 48)
				button.size = Vector2(76, 48)
				button.add_theme_font_size_override("font_size", 14)
				button.set_meta("cell", Vector2(int(item.node.grid_col), int(item.node.grid_row)))
				button.set_meta("logical_hit_size", Vector2(float(item.node.w), float(item.node.h)) if item.node.has("w") and item.node.has("h") else Vector2.ZERO)
				button.clip_text = true
				button.flat = true
				for color_key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]: button.add_theme_color_override(color_key, Color("21180f"))
				button.add_theme_color_override("font_outline_color", Color("f7ead3"))
				button.add_theme_constant_override("outline_size", 3)
				button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			button.autowrap_mode = TextServer.AUTOWRAP_OFF if target == nodes and has_board else TextServer.AUTOWRAP_WORD_SMART
			button.tooltip_text = str(item.title) + "\n" + (str(item.reason) if not item.available else "点击预览，再点击前往")
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
	UI.button(actions, "取消准备" if phase == "preparing" else "返回调查", close, not busy or phase == "preparing")
	if has_board: board_view.call_deferred("_layout_buttons")
	if is_instance_valid(selected_button) and not selected_button.disabled: selected_button.grab_focus()

func _opaque_panel() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("101b25")
	return style

func _scroll(parent: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 220
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	return scroll

func _on_phase_changed(phase: String) -> void:
	if phase == "moving" and movement_request != str(service.state.active_request.get("request_id", "")):
		movement_request = str(service.state.active_request.request_id)
		route = service.movement_path()
		animation_phase = "cross" if service.cross_group() else "lift"
		animation_ms = 0.0
		cross_switched = false
		animation_step = 1
		selected_group = str(service.locations.get(service.state.active_request.from_scene, {}).get("node", {}).get("group_id", ""))
		service.pawn_sound("lift")
		_queue_render(true)
	else: _queue_render()

func _process(delta: float) -> void:
	if not is_visible_in_tree() or service == null or service.core.paused: return
	if service.state.get("phase") == "preparing":
		service.complete_preparation(str(service.state.active_request.get("request_id", "")))
		return
	if animation_phase.is_empty(): return
	animation_ms += delta * 1000
	if animation_phase == "final_land" and animation_ms >= service.display_value("pawn_contact_ms", 50) and not cross_switched:
		cross_switched = true
		service.pawn_sound("land")
	var lift_ms: float = service.display_value("pawn_lift_ms", 60)
	var move_ms: float = service.display_value("pawn_move_ms", 200)
	var land_ms: float = service.display_value("pawn_land_ms", 90)
	var lift: float = 0.0 if reduced else service.display_value("pawn_lift_height", 10)
	var duration: float = {"lift": lift_ms, "move": move_ms, "land": land_ms, "final_land": land_ms, "cross": service.display_value("pawn_cross_group_ms", 400), "hold": service.display_value("pawn_arrival_hold_ms", 140), "fade": service.display_value("map_transition_ms", 260)}.get(animation_phase, 1)
	var amount := clampf(animation_ms / maxf(1, duration), 0, 1)
	if animation_phase == "cross" and amount >= 0.5 and not cross_switched:
		cross_switched = true
		selected_group = str(service.locations.get(service.state.active_request.to_scene, {}).get("node", {}).get("group_id", ""))
		_queue_render(true)
	if is_instance_valid(board_view) and route.size() > 1:
		var from_cell: Vector2 = route[clampi(animation_step - 1, 0, route.size() - 1)]
		var to_cell: Vector2 = route[clampi(animation_step, 0, route.size() - 1)]
		match animation_phase:
			"lift": board_view.set_pawn(from_cell, lift * amount)
			"move": board_view.set_pawn(to_cell if reduced else from_cell.lerp(to_cell, amount), lift)
			"land", "final_land": board_view.set_pawn(to_cell, lift * (1 - amount))
			"cross": board_view.set_pawn(to_cell if cross_switched else route[0], 0, absf(amount * 2 - 1))
			"hold": board_view.set_pawn(to_cell, 0)
	if animation_phase == "fade": modulate.a = 1 - amount
	if animation_ms < duration: return
	animation_ms = 0
	match animation_phase:
		"lift": animation_phase = "move"
		"move", "cross":
			if animation_phase == "cross" or route.size() < 2 or animation_step >= route.size() - 1:
				# 终点上方先提交；失败回原位，成功后只续最后落子与淡出。
				if service.finish_movement(): animation_phase = "final_land"; cross_switched = false
				else:
					animation_phase = ""
					_queue_render(true)
			else: animation_phase = "land"
		"land": animation_step += 1; animation_phase = "lift"
		"final_land": animation_phase = "hold"
		"hold": service.begin_transition(); animation_phase = "fade"
		"fade": animation_phase = ""; service.finish_transition()

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))

func _select_group(group: String) -> void:
	if service.state.get("phase") not in ["browsing", "failure"]: return
	selected_group = group
	_queue_render()

func _on_transition_completed(_scene_id: String) -> void:
	_hide_map(false)

func _hide_map(restore_focus: bool) -> void:
	animation_phase = ""
	movement_request = ""
	modulate.a = 1.0
	hide()
	if restore_focus and is_instance_valid(return_focus) and return_focus.is_visible_in_tree(): return_focus.grab_focus()
	closed.emit()
