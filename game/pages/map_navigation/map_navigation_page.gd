extends Control
## 地图页维护自己的节点、列表、预览和焦点；资格与切换事务由服务校验。

signal closed

const UI = preload("res://pages/core/page_controls.gd")
const BoardScript = preload("res://pages/map_navigation/map_board.gd")
const PolygonButton = preload("res://pages/map_navigation/map_polygon_button.gd")
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
var movement_from_group := ""

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
	resized.connect(_queue_render)

func _queue_render(force: bool = false) -> void:
	# 状态和阶段信号可能在同一按钮回调中连续发出，每帧只重建一次。
	if not force and not animation_phase.is_empty() and is_instance_valid(board_view): return
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_render")

func _render() -> void:
	refresh_queued = false
	if not is_inside_tree() or service == null or not visible: return
	if service.is_spatial() and service.map_definition.has("ui_layout"):
		_render_spatial()
		return
	# 旧按钮先脱离树再延迟释放，避免同帧重叠触区和发信号时释放自身。
	UI.clear(self)
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = PanelContainer.new()
	panel.name = "MapPanel"
	panel.custom_minimum_size = Vector2(720, 560)
	if service.is_spatial():
		var effective := get_viewport_rect().size
		panel.custom_minimum_size = Vector2(minf(effective.x - 32, 1400), minf(effective.y - 32, 820))
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
	if service.is_spatial(): known_groups.append("overview")
	for item in records:
		var group := str(item.node.get("group_id", ""))
		if not group.is_empty() and group not in known_groups: known_groups.append(group)
	for group in known_groups:
		var record: Dictionary = service.map_definition.get("groups", {}).get(group, {})
		var region: String = service.core.ui(str(record.get("region_name_text_id", "")))
		var floor_name: String = service.core.ui(str(record.get("floor_name_text_id", "")))
		var title := str(record.get("name", group)) if region.is_empty() else region + (" / " + floor_name if not floor_name.is_empty() else "")
		if service.is_spatial(): title = "两层总览" if group == "overview" else str(record.get("region_label", "货运站")) + " / " + str(record.get("floor_label", group))
		UI.button(groups, title, _select_group.bind(group), not busy).set_meta("tutorial_target", "map.view_" + group.to_lower())
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	box.add_child(content)
	var board := VBoxContainer.new()
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(board)
	UI.label(board, "地点节点", 20)
	var board_scroll: Control = _scroll(board) if not service.is_spatial() else Control.new()
	if service.is_spatial():
		board.add_child(board_scroll)
		board_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		board_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_scroll.custom_minimum_size.y = 300
	var current_node: Dictionary = service.locations.get(service.current_scene_id(), {}).get("node", {})
	var group_id := selected_group
	var has_board: bool = not current_node.is_empty() and service.map_definition.get("boards", {}).has(group_id)
	var nodes: Control
	if has_board:
		board_view = BoardScript.new()
		board_view.custom_minimum_size = Vector2(360, 300)
		board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		board_view.configure_art(service.map_definition, group_id)
		board_view.setup(records, service.map_definition.boards[group_id], group_id)
		board_view.set_pawn(service.current_pawn_point(), 0)
		board_view.pawn_visible = group_id == "overview" or group_id == str(current_node.get("group_id", "")) or not animation_phase.is_empty()
		board_view.confirmed_actors = service.confirmed_actor_records()
		board_view.display_scale = clampf(get_viewport_rect().size.y / 900.0, 0.6, 2.0)
		nodes = board_view
	else:
		board_view = null
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		nodes = grid
	board_scroll.add_child(nodes)
	if service.is_spatial() and has_board: nodes.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	var last_list_group := ""
	for item in records:
		if service.is_spatial() and group_id != "overview" and str(item.node.get("group_id", "")) != group_id: continue
		var scene_id := str(item.to_scene)
		var status := "当前位置" if item.current else ("可前往" if item.available else "暂不可前往")
		for target in [nodes, list]:
			if target == nodes and has_board and group_id != "overview" and item.node.get("group_id", "") != group_id: continue
			# 侧栏地点列表按楼层分区，每组前插入楼层标题（反馈#20）。
			if target == list:
				var list_group := str(item.node.get("group_id", ""))
				if not list_group.is_empty() and list_group != last_list_group:
					last_list_group = list_group
					var gdef: Dictionary = service.map_definition.get("groups", {}).get(list_group, {})
					var gregion: String = service.core.ui(str(gdef.get("region_name_text_id", "")))
					var gfloor: String = service.core.ui(str(gdef.get("floor_name_text_id", "")))
					var gtitle := str(gdef.get("name", list_group)) if gregion.is_empty() else gregion + (" / " + gfloor if not gfloor.is_empty() else "")
					UI.label(list, gtitle, 18)
			# 已公开但不可达的地点仍可选中查看原因，只有前往动作受资格限制。
			var button: Button
			if target == nodes and has_board and service.is_spatial():
				button = PolygonButton.new()
				target.add_child(button)
				button.disabled = busy
				button.pressed.connect(service.select_scene.bind(scene_id))
				button.flat = true
				var polygon := PackedVector2Array()
				for point in item.node.get("hit_polygon_px", []): polygon.append(Vector2(float(point[0]), float(point[1])))
				button.set_meta("source_polygon", polygon)
				for style_name in ["normal", "hover", "pressed", "focus", "disabled"]: button.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
			else: button = UI.button(target, str(item.title) + "\n" + status, service.select_scene.bind(scene_id), not busy)
			button.set_meta("scene_id", scene_id)
			button.set_meta("map_role", "node" if target == nodes else "list")
			button.custom_minimum_size = Vector2(160 if target == nodes else 200, 64)
			if target == nodes and has_board and not service.is_spatial():
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
	if service.is_spatial():
		var actor_names: Array[String] = []
		for actor in service.confirmed_actor_records():
			if actor.scene_id == service.state.get("selected_scene_id", ""): actor_names.append(str(actor.public_name))
		if not actor_names.is_empty(): UI.label(box, "已知位置：" + "、".join(actor_names), 16)
	UI.label(box, "预览：" + str(preview.get("title", "请选择地点")), 20)
	var reason: String = service.travel_disabled_reason()
	if phase == "failure": reason = "切换失败：" + str(service.state.get("failure_reason", "请重新选择地点"))
	UI.label(box, reason if not reason.is_empty() else "确认后前往选中地点", 16)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	box.add_child(actions)
	var travel_button := UI.button(actions, "前往", service.travel, service.travel_disabled_reason().is_empty())
	travel_button.set_meta("tutorial_target", "map.travel")
	travel_button.tooltip_text = service.travel_disabled_reason()
	UI.button(actions, "取消准备" if phase == "preparing" else "返回调查", close, not busy or phase == "preparing").set_meta("tutorial_target", "map.return")
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
	if phase == "departure":
		animation_phase = ""
		hide()
		return
	if phase == "moving" and movement_request != str(service.state.active_request.get("request_id", "")):
		show()
		movement_request = str(service.state.active_request.request_id)
		route = service.movement_path()
		animation_phase = "cross" if service.cross_group() else "lift"
		if animation_phase == "cross" and route.size() > 1: route = [route.front(), route.back()]
		animation_ms = 0.0
		cross_switched = false
		animation_step = 1
		selected_group = str(service.locations.get(service.state.active_request.from_scene, {}).get("node", {}).get("group_id", ""))
		movement_from_group = selected_group
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
		# 跨层中点原地换楼层背景，避免整页重建出现空帧花屏（反馈#21）。
		# 目标层无棋盘定义时无法原地换背景，仍走整页重建（保留原处理）。
		if is_instance_valid(board_view) and service.map_definition.get("boards", {}).has(selected_group):
			board_view.switch_group(selected_group)
		else:
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
					selected_group = movement_from_group
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

func _render_spatial() -> void:
	# 最终地图布局取本册记录；模型、点击区、棋子共用同一个 contain/crop。
	UI.clear(self)
	var phase := str(service.state.get("phase", "closed"))
	var busy := phase in ["preparing", "moving", "arrival_hold", "transitioning"]
	var layout_state := "floor_two" if selected_group == "MAP02" else ("overview" if selected_group == "overview" else "browse")
	panel = PanelContainer.new()
	panel.name = "MapPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _spatial_style("PAPER_V2_panel_paper"))
	add_child(panel)
	_place_spatial(panel, "map.panel_surface_1", layout_state)
	var title := _spatial_label("地图", 30)
	_place_spatial(title, "map.text_map_title_1", layout_state)
	# 地点信息只占自己的文字区域，避免把模型宽度当成文字的最小尺寸。
	var current := _spatial_label("当前位置：" + service.scene_name(service.current_scene_id()), 18)
	current.position = Vector2(300, 28) * _spatial_scale()
	current.size = Vector2(maxf(200, size.x / _spatial_scale() - 540), 44) * _spatial_scale()
	for group in ["overview", "MAP01", "MAP02"]:
		var has_group: bool = group == "overview"
		for item in service.location_records():
			if item.node.get("group_id", "") == group: has_group = true
		if not has_group: continue
		var label := "两层总览" if group == "overview" else ("一楼与站外" if group == "MAP01" else "二楼")
		var tab := _spatial_button(label, _select_group.bind(group), not busy)
		_place_spatial(tab, "map.view_" + group.to_lower(), layout_state)
		if group == selected_group: tab.add_theme_color_override("font_color", Color("3f6b4c"))
	board_view = BoardScript.new()
	board_view.name = "SpatialBoard"
	add_child(board_view)
	_place_spatial(board_view, "UI_MAP_MODEL", layout_state)
	board_view.configure_art(service.map_definition, selected_group)
	board_view.display_scale = _spatial_scale()
	board_view.confirmed_actors = service.confirmed_actor_records()
	board_view.setup(service.location_records(), service.map_definition.boards[selected_group], selected_group)
	board_view.set_pawn(service.current_pawn_point(), 0)
	var current_group := str(service.locations.get(service.current_scene_id(), {}).get("node", {}).get("group_id", ""))
	board_view.pawn_visible = selected_group == "overview" or selected_group == current_group or not animation_phase.is_empty()
	for item in service.location_records():
		if selected_group != "overview" and item.node.get("group_id", "") != selected_group: continue
		var hotspot := PolygonButton.new()
		hotspot.disabled = busy
		hotspot.set_meta("scene_id", str(item.to_scene))
		hotspot.set_meta("map_role", "node")
		hotspot.tooltip_text = str(item.title) + (" · 当前位置" if item.current else (" · 点击预览" if item.available else " · 暂不可前往"))
		var polygon := PackedVector2Array()
		for point in item.node.get("hit_polygon_px", []): polygon.append(Vector2(float(point[0]), float(point[1])))
		hotspot.set_meta("source_polygon", polygon)
		for style_name in ["normal", "hover", "pressed", "focus", "disabled"]: hotspot.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
		hotspot.pressed.connect(service.select_scene.bind(str(item.to_scene)))
		board_view.add_child(hotspot)
	var list_panel := PanelContainer.new()
	list_panel.add_theme_stylebox_override("panel", _spatial_style("PAPER_V2_panel_paper"))
	add_child(list_panel)
	_place_spatial(list_panel, "map.panel_surface_2", layout_state)
	var list_margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]: list_margin.add_theme_constant_override("margin_" + edge, int(16 * _spatial_scale()))
	list_panel.add_child(list_margin)
	var list_box := VBoxContainer.new()
	list_margin.add_child(list_box)
	var list_title := Label.new()
	list_title.text = "站内地点"
	list_title.add_theme_color_override("font_color", Color("34413f"))
	list_box.add_child(list_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_box.add_child(scroll)
	var rows_box := VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows_box)
	var previous_group := ""
	var selected_button: Button
	for item in service.location_records():
		var group := str(item.node.get("group_id", ""))
		if selected_group != "overview" and group != selected_group: continue
		if group != previous_group:
			previous_group = group
			var floor_label := Label.new()
			floor_label.text = "二楼" if group == "MAP02" else "一楼与站外"
			floor_label.add_theme_color_override("font_color", Color("3f6b4c"))
			rows_box.add_child(floor_label)
		var row := _spatial_button(str(item.title), service.select_scene.bind(str(item.to_scene)), not busy, rows_box)
		row.set_meta("scene_id", str(item.to_scene))
		row.set_meta("map_role", "list")
		row.custom_minimum_size = Vector2(0, 50 * _spatial_scale())
		row.clip_text = true
		row.tooltip_text = str(item.reason)
		if item.selected: selected_button = row
	if is_instance_valid(selected_button): scroll.call_deferred("ensure_control_visible", selected_button)
	var destination := PanelContainer.new()
	destination.add_theme_stylebox_override("panel", _spatial_style("PAPER_V2_panel_paper"))
	add_child(destination)
	_place_spatial(destination, "map.panel_surface_3", layout_state)
	var preview: Dictionary = service.preview_scene(str(service.state.get("selected_scene_id", "")))
	var preview_title := _spatial_label("目的地：" + str(preview.get("title", "请选择地点")), 20)
	_place_spatial(preview_title, "map.text_map_destination_1", layout_state)
	var detail: String = service.travel_disabled_reason()
	if phase == "failure": detail = str(service.state.get("failure_reason", "请重新选择地点"))
	var actor_names: Array[String] = []
	for actor in service.confirmed_actor_records():
		if actor.scene_id == service.state.get("selected_scene_id", ""): actor_names.append(str(actor.public_name))
	if not actor_names.is_empty(): detail += ("\n" if not detail.is_empty() else "") + "已知位置：" + "、".join(actor_names)
	var hint := _spatial_label(detail, 16)
	_place_spatial(hint, "map.text_region_6", layout_state)
	hint.size.y = 106 * _spatial_scale()
	var travel := _spatial_button("前往", service.travel, detail.is_empty() or service.travel_disabled_reason().is_empty())
	travel.tooltip_text = service.travel_disabled_reason()
	_place_spatial(travel, "map.travel", layout_state)
	var back := _spatial_button("取消准备" if phase == "preparing" else "返回调查", close, not busy or phase == "preparing")
	_place_spatial(back, "map.return", layout_state)
	board_view.call_deferred("_layout_buttons")
	if is_instance_valid(selected_button) and not busy: selected_button.grab_focus()

func _spatial_scale() -> float:
	return size.y / 900.0

func _place_spatial(control: Control, id: String, state_name: String) -> void:
	control.set_meta("tutorial_target", id)
	var extent := size
	var ratio := extent.x / maxf(1, extent.y)
	var aspect := 1 if absf(ratio - 16.0 / 9) < 0.05 else (2 if absf(ratio - 1.6) < 0.05 else (3 if ratio < 1.5 else 4))
	var row := {}
	for item in service.map_definition.ui_layout.get("records", []):
		if item.control_id == id and item.state_id == state_name and int(item.aspect_ratio) == aspect: row = item; break
	if row.is_empty(): return
	var scale_value := _spatial_scale()
	var dimensions := Vector2(float(row.width), float(row.height)) * scale_value
	var anchor := int(row.anchor) - 1
	var column := anchor % 3
	var line := int(anchor / 3)
	var anchor_point := Vector2(extent.x * column / 2.0, extent.y * line / 2.0)
	var alignment := Vector2(dimensions.x * column / 2.0, dimensions.y * line / 2.0)
	control.position = anchor_point + Vector2(float(row.offset_x), float(row.offset_y)) * scale_value - alignment
	control.size = dimensions

func _spatial_label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", maxi(12, int(font_size * _spatial_scale())))
	label.add_theme_color_override("font_color", Color("34413f"))
	add_child(label)
	return label

func _spatial_button(value: String, callback: Callable, enabled: bool, parent: Node = self) -> Button:
	var button := Button.new()
	button.text = value
	button.disabled = not enabled
	button.pressed.connect(callback)
	button.add_theme_font_size_override("font_size", maxi(12, int(20 * _spatial_scale())))
	for state_name in ["normal", "hover", "pressed", "disabled"]: button.add_theme_stylebox_override(state_name, _spatial_style("PAPER_V2_button_secondary_" + state_name))
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]: button.add_theme_color_override(color_name, Color("34413f"))
	button.add_theme_color_override("font_disabled_color", Color("8e9186"))
	parent.add_child(button)
	return button

func _spatial_style(asset_id: String) -> StyleBox:
	var path := str(service.map_definition.get("ui_assets", {}).get(asset_id, ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var style := StyleBoxTexture.new()
		style.texture = load(path)
		style.set_texture_margin_all(10)
		return style
	var fallback := StyleBoxFlat.new()
	fallback.bg_color = Color("eee7d3")
	return fallback
