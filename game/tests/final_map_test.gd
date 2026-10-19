extends SceneTree
## 最终地图行为回归：真实空间路径、等比命中、确认位置和切换提交边界。
var failures: Array[String] = []
var checks := 0

func _init() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message); printerr("FINAL_MAP_FAIL: " + message)

func frames(count := 3) -> void:
	for i in range(count): await process_frame

func _run() -> void:
	var session := preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式最终包载入")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset()
	session.mode = "investigation"
	var bridge := preload("res://systems/aurora/aurora_map_bridge.gd").new()
	root.add_child(bridge)
	bridge.bind(session)
	var definition := bridge.definition()
	check(definition.get("schema") == "map-spatial-v2", "采用最终空间地图而非旧棋盘")
	check(definition.waypoints.size() == 51 and definition.edges.size() == 51, "加载51路点和51条实际连线")
	var map := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(map)
	map.bind_core(bridge)
	check(map.configure(definition), "最终空间地图结构验证通过：" + str(map.configuration_errors))
	map.initialize("SC01")
	check(map.scene_name("SC11") == "货运卡车", "货车使用正式display_name，不显示空白或内部ID")
	map.state.active_request = {"from_scene": "SC02", "to_scene": "SC04"}
	bridge.state.current_view_id = "VIEW_SC02_MAIN"
	var route := map.movement_path()
	check(route.size() == 6, "大厅至档案间合并为5段真实转折：" + str(route.size()))
	check(not route.is_empty() and route[0].is_equal_approx(map.node_point(map.locations.SC02.node)), "路线从实际大厅路点开始")
	check(not route.is_empty() and route[-1].is_equal_approx(map.node_point(map.locations.SC04.node)), "路线在档案间真实路点结束")
	map.state.active_request = {"from_scene": "SC01", "to_scene": "SC11"}
	bridge.state.current_view_id = "VIEW_SC01_REAR"
	route = map.movement_path()
	check(not route.is_empty() and route[0].is_equal_approx(map.waypoint_point("P_REAR_YARD")), "后院视角从后院锚点寻路")
	bridge.state.current_scene_id = "SC01"
	map.state.selected_scene_id = "SC01"
	check(not map.location_records()[0].current and map.location_records()[0].transition_id == "SC01->SC01", "同地点后院视图可明确选择前门")
	bridge.state.confirmed_actor_locations = []
	session.case_state.data.npc.CHR02 = {"scene_id": "SC06"}
	check(map.confirmed_actor_records().is_empty(), "后台真实位置不自动成为地图位置")
	bridge.state.confirmed_actor_locations = [{"actor_id":"CHR02", "scene_id":"SC06"}, {"actor_id":"CHR03", "scene_id":"SC06"}]
	check(map.confirmed_actor_records().size() == 2, "同一地点显示两个明确确认人物")
	var board := preload("res://pages/map_navigation/map_board.gd").new()
	root.add_child(board)
	board.size = Vector2(1000, 600)
	board.configure_art(definition, "overview")
	board.setup([], definition.boards.overview, "overview")
	board._geometry()
	var point := map.node_point(map.locations.SC06.node)
	var original := board.cell_point(point)
	board.switch_group("MAP02")
	board._geometry()
	check(not original.is_equal_approx(board.cell_point(point)), "总览与二楼共用源坐标并按视图裁切")
	var polygon_button := preload("res://pages/map_navigation/map_polygon_button.gd").new()
	polygon_button.hit_polygon = PackedVector2Array([Vector2(0,20), Vector2(20,0), Vector2(40,20), Vector2(20,40)])
	check(polygon_button._has_point(Vector2(20,20)) and not polygon_button._has_point(Vector2(0,0)), "多边形包围盒角落不会误选")
	polygon_button.free()
	board.queue_free()
	map.state.active_request = {}
	bridge.refresh()
	map.initialize("SC01")
	var page := preload("res://pages/map_navigation/map_navigation_page.gd").new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(map)
	page.open()
	await frames(6)
	check(page.visible and is_instance_valid(page.board_view), "最终地图页面能够建立空间棋盘")
	page._select_group("overview")
	await frames(6)
	var target: Button
	for child in page.board_view.get_children():
		if child is Button and child.get_meta("scene_id", "") == "SC02": target = child
	check(is_instance_valid(target), "大厅公开后存在真实多边形点击节点")
	if is_instance_valid(target):
		var node: Dictionary = map.locations.SC02.node
		var click_point: Vector2 = page.board_view.get_global_transform() * page.board_view.cell_point(Vector2(float(node.label_anchor_x), float(node.label_anchor_y)))
		var motion := InputEventMouseMotion.new()
		motion.position = click_point
		root.push_input(motion, true)
		await frames()
		check(root.gui_get_hovered_control() == target, "地图多边形内部实际鼠标命中大厅节点")
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = click_point; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
			root.push_input(event, true)
			await frames()
		check(map.state.selected_scene_id == "SC02" and session.case_state.data.scene == "SC01", "实际点击只选择预览、不提前改变地点")
	for size_value in [Vector2i(1600,900), Vector2i(1440,900), Vector2i(1200,900), Vector2i(2100,900)]:
		root.size = size_value
		root.content_scale_size = size_value
		page._queue_render(true)
		await frames(6)
		check(page.panel.get_global_rect().end.x <= root.size.x + 1 and page.panel.get_global_rect().end.y <= root.size.y + 1, "地图面板在有效画面内：%s / %s / %s" % [size_value, page.panel.get_global_rect(), page.get_viewport_rect()])
		for action in page.find_children("*", "Button", true, false):
			if action.text in ["前往", "返回调查"]: check(root.get_visible_rect().encloses(action.get_global_rect()), "前往/返回按钮在有效画面内：" + str(size_value))
		if "--capture" in OS.get_cmdline_user_args():
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final_map_%d.png" % size_value.x))
	page.close()
	# 独立夹具验证切换事务：地图表现完成前不提交、资格失效原位失败。
	session.case_state.data.chapter = "CH02"
	session.mode = "investigation"
	session.narrative.end_reading()
	bridge.refresh()
	var transaction := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(transaction)
	transaction.bind_core(bridge)
	check(transaction.configure(definition), "事务使用同一正式地图定义")
	transaction.initialize("SC01")
	transaction.bind_visual_controller()
	check(transaction.open() and transaction.select_scene("SC11"), "货车地点明确选择")
	check(transaction.travel(), "前往建立唯一准备请求")
	var request_id := str(transaction.state.active_request.get("request_id", ""))
	transaction.complete_preparation(request_id)
	check(session.case_state.data.scene == "SC01" and transaction.state.phase == "moving", "移动表现中保持原真实地点")
	check(transaction.finish_movement() and session.case_state.data.scene == "SC11", "终点提交后才改变真实地点")
	check(transaction.begin_transition() and transaction.finish_transition() and not transaction.state.open, "提交后完成落定和关闭")
	check(session.force_travel("SC02"), "建立跨层可操作起点")
	bridge.refresh()
	map.initialize("SC02")
	page.open()
	await frames(5)
	check(map.select_scene("SC06") and map.travel(), "实际地图页面提交跨层目标")
	for i in range(120):
		if not page.visible: break
		await create_timer(0.01).timeout
	check(not page.visible and session.case_state.data.scene == "SC06", "跨层动画完成后落在正确目的地")
	check(page.route.size() == 2 and page.route[-1].is_equal_approx(map.node_point(map.locations.SC06.node)), "跨层使用起终点淡入，不误停第一条楼梯路点")
	transaction.queue_free()
	page.queue_free(); map.queue_free(); bridge.queue_free(); session.queue_free()
	await frames(10)
	print("FINAL_MAP_PASS: %d checks" % checks if failures.is_empty() else "FINAL_MAP_FAILED: %d / %d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
