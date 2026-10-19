extends SceneTree
## 使用正式调查、核查与地图页面验证引导定位；--render可保存真实渲染截图。
var failures: Array[String] = []
var checks := 0
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("TUTORIAL_RENDER_FAIL: " + message)
func frames(count := 3) -> void:
	for i in range(count): await process_frame
func run() -> void:
	root.size = Vector2i(1600, 900)
	var session := preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "最终包载入")
	session.case_state.reset()
	session.run_id = "tutorial-render"
	session.mode = "investigation"
	var bridge := preload("res://systems/aurora/aurora_map_bridge.gd").new()
	root.add_child(bridge)
	bridge.bind(session)
	var map := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(map)
	map.bind_core(bridge)
	check(map.configure(bridge.definition()), "最终地图载入")
	map.initialize("SC01")
	var gameplay := preload("res://pages/aurora/aurora_gameplay_page.gd").new()
	root.add_child(gameplay)
	gameplay.size = Vector2(1600, 900)
	gameplay.bind(session, map)
	gameplay.set_active(true)
	var tutorial: Node = gameplay.tutorial
	var overlay: Control = gameplay.tutorial_page
	await frames(5)
	var target: Control = tutorial.target_control()
	check(target != null and str(target.name) == "HS_SC01_SIGN", "调查教学找到实际站名牌按钮")
	check(overlay.target_polygon.size() >= 3, "真实调查视图高亮有轮廓")
	check(overlay.text.text == "点击画面中的站名牌。", "提示使用最终配置正文：" + overlay.text.text)
	if OS.get_cmdline_user_args().has("--render"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/final_tutorial_sign.png")
	session.case_state.grant("E01_V1", {"test":true})
	session.case_state.grant("E28_V1", {"test":true})
	tutorial.previous_owns_first = true
	tutorial._finish_feedback()
	session.case_state.data.tutorial_completed_steps.append("TUT_INV_SIGN:1")
	session.mode = "selection"
	session.question = "T00_R01"
	session.current_statement = "TXT_QUESTION_T00_R01"
	session.case_state.data.texts.TXT_QUESTION_T00_R01 = true
	session.case_state.data.chances.T00_R01 = 3
	session.changed.emit()
	await frames(5)
	check(tutorial.target_control() != null and tutorial.target_control().name == "TargetStatement", "核查教学绑定真实原话按钮")
	session.select_target()
	await frames(5)
	target = tutorial.target_control()
	check(target != null and target.name == "Card_E28_V1", "核查教学绑定真实内页手牌")
	check(overlay.target_polygon.size() == 4, "手牌高亮读取实际旋转四角")
	if target != null:
		var mouse := InputEventMouseButton.new()
		mouse.position = target.get_global_transform_with_canvas() * Vector2(target.size.x / 2, 12)
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.pressed = true
		check(tutorial.input_allowed(mouse), "目标卡牌原始命中放行")
		mouse.position = Vector2(10, 10)
		check(not tutorial.input_allowed(mouse), "错误控件和遮罩阻止操作")
	if OS.get_cmdline_user_args().has("--render"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/final_tutorial_card.png")
	session.select_content("E28_V1")
	await frames(5)
	check(tutorial.target_control() != null and tutorial.target_control().name == "PresentMaterials", "真实入槽后转出示按钮")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	gameplay.card_page.find_child("TargetStatement", true, false).grab_focus()
	check(not tutorial.input_allowed(space), "键盘焦点留在原话时不能绕过出示指引")
	tutorial.target_control().grab_focus()
	check(tutorial.input_allowed(space), "键盘只激活当前实际目标")
	session.mode = "investigation"
	session.question = ""
	session.slots = ["", ""]
	session.case_state.data.scene = "SC02"
	session.case_state.data.view = "VIEW_SC02_MAIN"
	session.case_state.data.events.EV_CH01_RECEPTION_DONE = true
	session.case_state.data.events.EV_CH01_TEA_READY = true
	bridge.refresh()
	session.changed.emit()
	await frames()
	gameplay.map_page.open()
	await frames(5)
	check(gameplay.map_page.visible, "合法路线打开真实地图")
	check(tutorial.target_control() != null and str(tutorial.current_step.get("target_ref")) == "map.view_map02", "地图先指向真实二楼页签")
	gameplay.map_page._select_group("MAP02")
	await frames(5)
	check(tutorial.target_control() != null and tutorial.current_step.get("target_ref") == "map.select_sc06", "切层后指向休息室真实节点")
	map.select_scene("SC06")
	await frames(5)
	check(tutorial.target_control() != null and tutorial.current_step.get("target_ref") == "map.travel", "实际选择后指向前往")
	gameplay.map_page.close()
	await frames()
	check(not session.case_state.data.tutorial_completed_steps.has("TUT_MAP_FIRST:3"), "关闭地图不完成移动教程")
	print("FINAL_TUTORIAL_RENDER_TEST: %d checks, %d failures" % [checks, failures.size()])
	gameplay.free()
	map.free()
	bridge.free()
	session.free()
	quit(0 if failures.is_empty() else 1)
