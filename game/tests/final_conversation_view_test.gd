extends SceneTree
## 使用正式案后规则和真实 PNG 点击区域回归获批的交谈视角；图形模式发送真实鼠标事件。
var session: Node
var page: Control
var failures: Array[String] = []
var checks := 0
func _init() -> void: call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr(message)
func _frames(count: int = 2) -> void:
	for i in range(count): await process_frame
func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "正式配置初始化")
	session.case_state.reset()
	session.case_state.data.chapter = "CH02"
	session.case_state.data.scene = "SC02"
	session.case_state.data.view = "VIEW_SC02_MAIN"
	session.case_state.data.events["EV_CASE_INVESTIGATION_OPEN"] = true
	session.case_state.data.npc["CHR04"] = {"scene_id": "SC02"}
	session.case_state.data.npc["CHR10"] = {"scene_id": "SC02"}
	session.case_state.data.npc["CHR03"] = {"scene_id": "SC03"}
	session.mode = "investigation"
	session.return_context = {"kind": "scene", "scene": session.case_state.data.scene, "view": session.case_state.data.view}
	page = preload("res://pages/aurora/aurora_scene_page.gd").new()
	root.add_child(page)
	page.size = Vector2(1600, 900)
	page.bind(session)
	await _frames()
	_check(not is_instance_valid(page.conversation_view), "调查默认收起近景")
	_check(page.find_child("ConversationViewSwitch", true, false) != null, "调查有明确交谈视角切换")
	var candidates: Array = page.model.conversation_candidates()
	_check(candidates.any(func(row): return row.object_ref == "CHR04"), "案后大厅实际伊万有合法近景入口")
	_check(candidates.any(func(row): return row.object_ref == "CHR10"), "案后大厅实际基里尔不丢失")
	_check(candidates.all(func(row): return row.object_ref != "CHR03"), "大厅隔门尼娜不能当厨房近问")
	page._toggle_conversation_view()
	await _frames()
	_check(is_instance_valid(page.conversation_view), "显式切换才显示近景")
	_check(page.render_hotspots.is_empty(), "交谈视角不保留背后调查热点")
	if not is_instance_valid(page.conversation_view): page.queue_free(); session.queue_free(); await process_frame; quit(1); return
	page._switch_conversation_actor("CHR04")
	await _frames()
	_check(page.conversation_view.selected_row.object_ref == "CHR04", "多人物切换到伊万实际图片")
	var button: Button = page.conversation_view.actor_button
	_check(button.size.x > 0 and button.size.y > 0 and Rect2(Vector2.ZERO, page.canvas.size).encloses(button.get_rect()), "人物命中区域在有效画面内")
	_check(page.conversation_view.portrait_rect.get_center().x > page.canvas.size.x / 2, "朝左伊万排在右侧且不翻图")
	_check(not button._has_point(Vector2(-1, -1)), "人物外部透明区不命中")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/final-conversation-view.png")
	var valid := Vector2.ZERO
	var found := false
	for y in range(10, int(button.size.y), 12):
		for x in range(10, int(button.size.x), 12):
			if button._has_point(Vector2(x, y)): valid = Vector2(x, y); found = true; break
		if found: break
	_check(found, "近景像素确有可点击位置")
	if found and DisplayServer.get_name() != "headless":
		var point := button.get_global_transform_with_canvas() * valid
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT; down.pressed = true; down.position = point; down.global_position = point
		Input.parse_input_event(down)
		await process_frame
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT; up.position = point; up.global_position = point
		Input.parse_input_event(up)
		await _frames()
	elif found:
		button.pressed.emit()
		await _frames()
	_check(session.active_entry == "ENTRY_CLICK_CHR04_SC02" or str(session.return_context.get("object", "")) == "CHR04", "实际鼠标点击人物启动已交付伊万入口")
	for i in range(100):
		if session.mode != "narrative": break
		session.narrative.tick(100)
		if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
		else: session.narrative.advance()
	await _frames()
	_check(page.current_context.get("conversation_view", false), "交谈结束回原交谈视角")
	if page.current_context.get("kind") in ["topics", "reasoning"]: page._close_context()
	await _frames()
	_check(page.handle_escape(), "返回键可关闭交谈视角")
	await _frames()
	_check(not is_instance_valid(page.conversation_view), "关闭后回原调查")
	page.set_preferences({"aspect_ratio": 3})
	page._toggle_conversation_view()
	await _frames()
	_check(page.canvas.size.x == 1200 and page.conversation_view.visible_rect.has_area(), "4比3交谈视角有实际可见近景")
	page.set_preferences({"aspect_ratio": 3, "brightness": 50})
	await _frames()
	var portrait: TextureRect
	for child in page.conversation_view.get_children():
		if child is TextureRect: portrait = child
	_check(is_equal_approx(page.world.modulate.r, 0.5) and portrait != null and is_equal_approx(portrait.modulate.r, 0.5), "亮度只应用世界图片和近景人物")
	_check(page.find_child("ConversationViewSwitch", true, false).modulate == Color.WHITE, "亮度不改变按钮文字")
	if page.current_context.get("kind") in ["topics", "reasoning"]: page._close_context()
	if page.current_context.get("conversation_view", false): page._toggle_conversation_view()
	session.case_state.data.scene = "SC11"
	session.case_state.data.view = "VIEW_SC11_MAIN"
	session.case_state.data.npc["CHR11"] = {"scene_id": "SC11"}
	session.return_context = {"kind": "scene", "scene": "SC11", "view": "VIEW_SC11_MAIN", "view_offset_x": 600.0}
	page.current_context = session.return_context.duplicate(true)
	page.refresh()
	await _frames()
	var original_offset: float = page.view_offset_x
	page._toggle_conversation_view()
	await _frames()
	_check(is_instance_valid(page.conversation_view) and page.conversation_view.selected_row.object_ref == "CHR11", "货车实际帕维尔可切近景")
	page._toggle_conversation_view()
	await _frames()
	_check(is_equal_approx(page.view_offset_x, original_offset), "关闭近景保留宽景原镜头")
	page._toggle_conversation_view()
	await _frames()
	session.case_state.data.scene = "SC03"
	session.case_state.data.view = "VIEW_SC03_MAIN"
	session.return_context = {"kind": "scene", "scene": "SC03", "view": "VIEW_SC03_MAIN"}
	page.refresh()
	await _frames()
	_check(not is_instance_valid(page.conversation_view), "地图切换地点清除原近景视角")
	_check(page.model.conversation_candidates().any(func(row): return row.object_ref == "CHR03"), "厨房尼娜只在实际地点开放")
	session.case_state.data.scene = "SC07"
	session.case_state.data.view = "VIEW_SC07_MAIN"
	var luggage: Array = page.model.hotspots().filter(func(row): return row.hotspot_id == "HS_SC07_BEDROLL")
	_check(luggage.size() == 1 and luggage[0].inspect_entry_ref == "ENTRY_CH02_WRENCH" and luggage[0].detail_view_ref == "VIEW_E12_DETAIL", "案后床尾行李精确调用扳手并进入已交付局部图")
	print("FINAL_CONVERSATION_VIEW ", failures.is_empty(), " checks=", checks)
	page.queue_free(); session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
