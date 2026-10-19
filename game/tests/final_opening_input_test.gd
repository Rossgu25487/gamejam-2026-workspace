extends SceneTree
## 开场站名牌必须通过真实鼠标进入、读完并退出观察，避免服务贯通掩盖输入阻塞。
var app: Control
var failures: Array[String] = []
var checks := 0
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("OPENING_INPUT_FAIL: " + message)
func frames(count := 5) -> void:
	for index in range(count): await process_frame
func click(point: Vector2) -> void:
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event)
		await process_frame
	await frames()
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://opening_input_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(8)
	app.settings_service.apply_window_enabled = false
	# 开场字幕仅准备待测公开调查画面，站名牌及其退出全部使用输入分发。
	check(app.debug_new_game(), "沿正式新游戏路径初始化")
	for index in range(300):
		if app.session.mode != "narrative": break
		app.session.narrative.tick(100)
		if not app.session.narrative.advance(): break
	await frames(8)
	check(app.session.mode == "investigation", "开场字幕结束于站外调查")
	var tutorial: Node = app.gameplay_page.tutorial
	var sign: Control = tutorial.target_control()
	check(sign != null and sign.name == "HS_SC01_SIGN", "首次教学的真实站名牌可见")
	if sign == null: quit(1); return
	await click(sign.get_global_transform_with_canvas() * (sign.size / 2))
	print("AFTER_SIGN mode=", app.session.mode, " entry=", app.session.active_entry, " step=", tutorial.current_step)
	check(app.session.mode == "narrative" and app.session.active_entry == "ENTRY_CH01_SIGN_FIRST", "真实点击打开正式首次站名牌观察")
	check(tutorial.completed({"group_id":"TUT_INV_SIGN", "step":1}) and tutorial.current_step.is_empty(), "正文出现即完成调查引导并撤层")
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/opening-sign-before-continue.png")
	var visited: Array[String] = []
	for index in range(30):
		if app.session.mode != "narrative": break
		var before := str(app.session.narrative.state.current_text_id)
		if not visited.has(before): visited.append(before)
		app.session.narrative.tick(100)
		await click(app.display_surface.get_global_rect().position + app.display_surface.size * Vector2(0.5, 0.82))
	print("SIGN_READ ", visited, " mode=", app.session.mode, " text=", app.session.narrative.state.get("current_text_id", ""), " step=", tutorial.current_step, " feedback=", tutorial.feedback_left)
	check(app.session.mode == "investigation", "点击画面可读完观察并返回调查")
	check(app.session.case_state.data.tutorial_completed_steps.has("TUT_INV_SIGN:1"), "真实打开观察完成首次调查引导")
	check(visited.size() == 3 and visited.all(func(id): return app.session.case_state.data.texts.get(id, false)), "三句观察正文真实提交已读回执")
	check(tutorial.current_step.is_empty(), "观察读完不会重新锁回站名牌")
	# 复现旧版本卡点存档：观察已读而教学步骤未登记；再次观察可解除旧档阻塞。
	var old_save: Dictionary = app.session.export_snapshot()
	old_save.case_state.tutorial_completed_steps.erase("TUT_INV_SIGN:1")
	check(app.debug_load_snapshot(old_save), "可读取已看完站名牌但教学未完成的旧卡点状态")
	await frames(8)
	sign = tutorial.target_control()
	check(sign != null and sign.name == "HS_SC01_SIGN", "旧卡点可再次点击实际站名牌")
	if sign != null:
		await click(sign.get_global_transform_with_canvas() * (sign.size / 2))
		check(app.session.active_entry == "ENTRY_CH01_SIGN_REPEAT" and tutorial.completed({"group_id":"TUT_INV_SIGN", "step":1}), "复查分支也能实际完成引导")
		for index in range(12):
			if app.session.mode != "narrative": break
			app.session.narrative.tick(100)
			await click(app.display_surface.get_global_rect().position + app.display_surface.size * Vector2(0.5, 0.82))
		check(app.session.mode == "investigation" and tutorial.current_step.is_empty(), "旧卡点复查后不再锁住调查")
	var scene: Control = app.gameplay_page.scene_page
	var doors: Array = scene.render_hotspots.filter(func(row): return row.get("hotspot_id") == "HS_SC01_DOOR")
	check(not doors.is_empty(), "读完站名牌后站房大门公开")
	if not doors.is_empty():
		var door: Control = scene.hotspot_buttons.get(str(doors[0].hotspot_id))
		check(is_instance_valid(door), "大门有真实可点控件")
		if is_instance_valid(door):
			await click(door.get_global_transform_with_canvas() * (door.size / 2))
			check(app.session.mode == "narrative" and not app.session.case_state.data.events.get("EV_CH01_RECEPTION_DONE", false), "点击真实大门接入进站正文")
			for index in range(50):
				if app.session.case_state.data.scene == "SC02": break
				app.session.narrative.tick(100)
				await click(app.display_surface.get_global_rect().position + app.display_surface.size * Vector2(0.5, 0.82))
			check(app.session.case_state.data.scene == "SC02", "进站正文读完正常抵达大厅")
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/opening-sign-after-continue.png")
	# 清理场景测试安装的全局自定义鼠标纹理，避免退出渲染器后才释放。
	Input.set_custom_mouse_cursor(null, Input.CURSOR_POINTING_HAND)
	app.queue_free(); await frames(12)
	print("FINAL_OPENING_INPUT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
