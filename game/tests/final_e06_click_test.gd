extends SceneTree
var session: Node
var page: Control
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr(message)
func _frames() -> void:
	await process_frame
	await process_frame
func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "正式配置初始化")
	session.case_state.reset()
	session.case_state.data.chapter = "CH02"
	session.case_state.data.scene = "SC02"
	session.case_state.data.view = "VIEW_SC02_COUNTER"
	session.case_state.data.events["EV_CASE_INVESTIGATION_OPEN"] = true
	session.mode = "investigation"
	session.return_context = {"kind": "inspection", "scene": "SC02", "view": "VIEW_SC02_COUNTER"}
	page = preload("res://pages/aurora/aurora_scene_page.gd").new()
	root.add_child(page)
	page.size = Vector2(1600, 900)
	page.bind(session)
	await _frames()
	var cards: Array = page.render_layers.filter(func(row): return row.get("object_ref", "") == "OBJ_SC02_LAST_SHEET")
	_check(cards.size() == 1 and cards[0].image_path == session.config.contents.E06_V1.image_ref, "实际显示正式E06纸卡资源")
	_check(page.find_children("*", "Label", true, false).any(func(label): return label.text == "最后一联货单"), "纸卡名称可见")
	var button: Button = page.find_child("HS_SC02_LAST_SHEET_COUNTER", true, false)
	_check(button != null and button.size == Vector2(322, 466), "纸本体有独立精确点击范围")
	_check(page._picked_hotspot(Vector2(650, 320)) == "HS_SC02_LAST_SHEET_COUNTER", "纸本体命中自身")
	_check(page._picked_hotspot(Vector2(625, 270)) != "HS_SC02_LAST_SHEET_COUNTER", "摄影底与纸外不命中货单")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/final-e06-visible-card.png")
		var point := button.get_global_transform_with_canvas() * Vector2(80, 120)
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed; event.position = point; event.global_position = point
			Input.parse_input_event(event)
			await process_frame
	else: button.pressed.emit()
	await _frames()
	_check(session.active_entry == "ENTRY_CH02_COUNTER_LAST_SHEET_FIRST", "点纸卡只启动最后一联入口")
	_check(not session.case_state.owns("E06_V1"), "未读纸卡正文不提前取得")
	for i in range(100):
		if session.mode != "narrative": break
		session.narrative.tick(100)
		if not session.narrative.advance(): break
	_check(session.case_state.owns("E06_V1") and session.case_state.data.events.get("EV_E06_READ", false), "实际读完货单取得E06")
	await _frames()
	var register: Array = page.model.hotspots().filter(func(row): return row.hotspot_id == "HS_SC02_REGISTER_COUNTER")
	_check(register.size() == 1 and register[0].inspect_entry_ref == "ENTRY_CH02_REGISTER_READ", "案后登记簿仍自身热区且沿案后正文")
	if not register.is_empty(): page._inspect(register[0])
	_check(session.active_entry == "ENTRY_CH02_REGISTER_READ", "登记簿实际调用案后入口")
	print("FINAL_E06_CLICK ", failures.is_empty(), " checks=", checks)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_POINTING_HAND)
	page.queue_free(); session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
