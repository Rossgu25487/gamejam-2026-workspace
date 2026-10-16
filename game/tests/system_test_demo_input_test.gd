extends SceneTree
## 实际配置包的控件输入回归；所有存档/设置均在本次独立目录。
var scene: Control
var failures: Array[String] = []
var checks := 0
var capture := false
var capture_root := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/system-test-captures")

func _initialize() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("DEMO_INPUT_FAILED: " + message)

func frames(count: int = 5) -> void:
	for i in range(count): await process_frame

func button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == text: return node
	return null

func click(control: Control) -> void:
	expect(is_instance_valid(control) and control.is_visible_in_tree(), "可见点击目标")
	if not is_instance_valid(control): return
	var viewport: Viewport = control.get_viewport()
	var point := control.get_global_rect().get_center()
	# 嵌入Window由根Viewport分派输入；坐标需加上窗口在根中的位置。
	if viewport is Window and viewport != root and viewport.is_embedded():
		point += Vector2(viewport.position)
		viewport = root
	await click_point(viewport, point)

func click_point(viewport: Viewport, point: Vector2) -> void:
	expect(viewport.get_visible_rect().has_point(point), "命中位置位于窗口内")
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		# point已经是视口坐标，不能再次应用窗口拉伸变换。
		viewport.push_input(event, true)
		await process_frame
	await frames()

func check_scene_layout(page: Control) -> void:
	var canvas: Control = page.investigation.scene_canvas
	expect(is_instance_valid(canvas), "调查场景画布存在")
	if not is_instance_valid(canvas): return
	var viewport_size := root.get_visible_rect().size
	var factor := minf(viewport_size.x / 1600.0, viewport_size.y / 900.0)
	var expected_size := Vector2(1600, 900) * factor
	var rect := canvas.get_global_rect()
	expect(rect.size.is_equal_approx(expected_size), "调查场景使用完整窗口等比缩放")
	expect(rect.position.is_equal_approx((viewport_size - expected_size) / 2), "调查场景与开场使用相同居中规则")
	for candidate in page.investigation.find_children("*", "Button", true, false):
		if not candidate.has_meta("hotspot_id"): continue
		var row: Dictionary = scene.session_service.scene_interaction.hotspots[candidate.get_meta("hotspot_id")]
		var expected := Rect2(rect.position + Vector2(row.x, row.y) * factor, Vector2(row.w, row.h) * factor)
		expect(candidate.get_global_rect().is_equal_approx(expected), "热点与调查画布使用同一坐标变换")

func take(name: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(capture_root)
	root.get_texture().get_image().save_png(capture_root.path_join(name + ".png"))

func finish_reading() -> void:
	var service: Node = scene.session_service.narrative
	for i in range(500):
		if service.state.get("finished", false) or service.state.get("waiting_for_choice", false): return
		service.tick(1000)
		service.advance()
		await frames(2)

func run() -> void:
	root.size = Vector2i(1280, 800)
	if DisplayServer.get_name() != "headless": root.grab_focus()
	scene = load("res://examples/system_test_demo.tscn").instantiate()
	scene.test_storage_path = "user://system-test-input/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	# 自动化使用push_input注入；桌面其他窗口的焦点变化不属于本用例，单独的失焦用例负责该规则。
	if root.focus_exited.is_connected(scene.gameplay_page.handle_window_focus_loss): root.focus_exited.disconnect(scene.gameplay_page.handle_window_focus_loss)
	await frames(12)
	expect(scene.session_service.core.catalog.errors.is_empty(), "配置包可启动")
	await take("01-title")
	await click(scene.title_page.settings_button)
	var settings: Control = scene.settings_page
	var slider: HSlider = settings.sliders.master_volume
	await click(slider)
	expect(scene.settings_service.values.master_volume < 90, "滑条鼠标点击可改变数值")
	await click(settings.reset_button)
	await click(settings.reset_confirmation.accept_button)
	expect(scene.settings_service.values.master_volume == 100 and scene.settings_service.volume_step == 5, "恢复默认来自工作簿")
	await click(settings.close_button)
	expect(scene.current_layer == "title", "设置返回标题")
	await click(scene.title_page.new_game_button)
	if not scene.confirm_page.visible:
		expect(false, "新游戏确认弹窗出现")
		scene.audio_service.shutdown()
		scene.queue_free()
		await frames(15)
		quit(1)
		return
	await click(scene.confirm_page.accept_button)
	var session: Node = scene.session_service
	var page: Control = scene.gameplay_page
	expect(page.narrative_page.visible, "新游戏显示开场")
	var initial: Dictionary = scene.save_service.load_latest()
	expect(initial.narrative_snapshot.state.current_text_id == "5000201", "初始自动档包含开头位置")
	await take("02-opening")
	var narrative: Node = session.narrative
	expect(button(page.narrative_page, "继续") == null, "对白没有独立继续按钮")
	var text_id: String = narrative.state.current_text_id
	narrative.tick(1000)
	await click(page.narrative_page.text_label)
	expect(narrative.state.current_text_id != text_id, "点击正文可继续阅读")
	text_id = narrative.state.current_text_id
	narrative.tick(1000)
	await click_point(root, Vector2(1120, 500))
	expect(narrative.state.current_text_id != text_id, "点击背景可继续阅读")
	text_id = narrative.state.current_text_id
	await click(button(page.narrative_page, "记录"))
	expect(narrative.reading_log and narrative.state.current_text_id == text_id, "记录按钮不会同时推进正文")
	await click(button(page.narrative_page, "返回对白"))
	await click(button(page.narrative_page, "隐藏 H"))
	await click_point(root, Vector2(1120, 500))
	expect(not narrative.hidden and narrative.state.current_text_id == text_id, "隐藏时点击画面只恢复对白")
	await finish_reading()
	text_id = narrative.state.current_text_id
	await click_point(root, Vector2(1120, 500))
	expect(narrative.state.waiting_for_choice and narrative.state.current_text_id == text_id, "选择时点击背景不会替玩家选择")
	await click(button(page.narrative_page, "开始交接演练"))
	expect(not page.narrative_page.visible and session.can_save(), "选择后可操作调查")
	check_scene_layout(page)
	var original_rect: Rect2 = page.investigation.scene_canvas.get_global_rect()
	await click(page.objective_hud.header)
	expect(page.investigation.scene_canvas.get_global_rect().is_equal_approx(original_rect), "目标面板开合不会缩小或移动场景")
	await click(page.objective_hud.header)
	await take("03-investigation")
	var hotspots: Array = page.investigation.find_children("*", "Button", true, false).filter(func(b): return b.has_meta("hotspot_id"))
	expect(hotspots.size() == 4, "前厅四个实际命中区")
	var paper: Button
	for candidate in hotspots:
		if session.scene_interaction.hotspots[candidate.get_meta("hotspot_id")].get("object_kind") == "object": paper = candidate; break
	await click(paper)
	expect(is_instance_valid(page.investigation.overlay) and page.investigation.overlay.visible, "图片位置实际点击打开检查")
	if is_instance_valid(page.investigation.overlay):
		await click(button(page.investigation.overlay, "确认检查结果"))
		expect(session.scene_interaction.state.observations.size() == 1, "检查窗口确认实际提交")
	await click(button(page.investigation, "地图"))
	expect(page.map_page.visible, "实际打开地图")
	await take("04-map")
	var destination: Button
	for candidate in page.map_page.find_children("*", "Button", true, false):
		if candidate.get_meta("scene_id", "") == "TEST_1014_BACK" and candidate.get_meta("map_role", "") == "node": destination = candidate
	await click(destination)
	var go := button(page.map_page, "前往")
	expect(go != null and go.disabled, "未解锁前往按钮灰显")
	await click(button(page.map_page, "返回调查"))
	# 普通交谈从实际正文提交，第一问通过真实出示按钮提交，覆盖页面与服务接线。
	expect(session.activate_entry("TEST_1014_ENTRY_TALK"), "普通交谈入口可用")
	await finish_reading()
	await frames()
	var core: Node = session.core
	await click(button(page.investigation, core.catalog.text(core.catalog.data.questions.TEST_1014_Q01.title)))
	expect(core.state.mode == "selection", "问题面板实际点击打开选材")
	await take("07-q01-selection")
	expect(core.select_material(core.catalog.material_ref("TEST_1014_C_HANDOFF_1")), "选择交接单初版")
	await frames()
	await click(button(page.selection, core.ui("UI_CORE_PRESENT")))
	expect(core.presenting, "实际出示触发表现")
	# 显式完成表现时钟用于快速验证，画面时长另由原音画用例人工验收。
	page.feedback.cancel()
	core.finish_presentation()
	await frames()
	await take("08-q01-result")
	await click(button(page.result, core.ui("UI_TITLE_CONTINUE")))
	expect("TEST_1014_Q01" in core.state.completed_questions, "第一问实际继续后提交")
	# 解锁前置仍由真实出示规则产生，不写预制完成状态。
	for row in session.scene_interaction.hotspots.values():
		if row.get("inspect_entry_ref", "") == "TEST_1014_ENTRY_DOORLOG":
			var request: Dictionary = session.scene_interaction.begin_inspection(row.hotspot_id)
			session.scene_interaction.commit_inspection(request.get("request_id", ""), true)
	expect(core.open_card_session("TEST_1014_Q02") and core.select_target(), "第二问选定说法")
	core.select_material(core.catalog.material_ref("TEST_1014_C_DOORLOG_1"))
	core.present_materials()
	page.feedback.cancel()
	core.finish_presentation()
	core.continue_result()
	await frames()
	await click(button(page.investigation, "地图"))
	for candidate in page.map_page.find_children("*", "Button", true, false):
		if candidate.get_meta("scene_id", "") == "TEST_1014_BACK" and candidate.get_meta("map_role", "") == "node": destination = candidate
	await click(destination)
	await click(button(page.map_page, "前往"))
	for i in range(600):
		if not page.map_page.visible: break
		page.map_page._process(0.1)
		await process_frame
	expect(core.state.current_scene_id == "TEST_1014_BACK" and not page.map_page.visible, "地图动画完成实际切到后室")
	await frames()
	await take("06-back-room")
	# 沿真实前置进入自主推理，比较普通窗口与1080p，不预置问题完成状态。
	for row in session.scene_interaction.hotspots.values():
		if row.get("inspect_entry_ref", "") == "TEST_1014_ENTRY_ROUTE":
			var request: Dictionary = session.scene_interaction.begin_inspection(row.hotspot_id)
			session.scene_interaction.commit_inspection(request.get("request_id", ""), true)
	expect(core.open_card_session("TEST_1014_Q03"), "第三问打开自主推理")
	await frames()
	await take("09-q03-selection")
	core.fold_card_selection()
	await frames()
	# 第二分辨率沿同一布局重建，命中区与图片同时缩放。
	root.size = Vector2i(1920, 1080)
	await frames(12)
	check_scene_layout(page)
	await take("05-investigation-1080p")
	for candidate in page.investigation.find_children("*", "Button", true, false):
		if candidate.has_meta("hotspot_id"): expect(root.get_visible_rect().encloses(candidate.get_global_rect()), "1080p热点完整可见")
	# 最小窗口也使用同一完整画布；地图往返不能把新背景落回旧的小框。
	root.size = Vector2i(960, 600)
	await frames(12)
	check_scene_layout(page)
	await click(button(page.investigation, "地图"))
	expect(page.map_page.visible, "小窗口可以打开地图")
	await click(button(page.map_page, "返回调查"))
	expect(not page.map_page.visible and page.margin.visible, "小窗口关闭地图恢复调查")
	check_scene_layout(page)
	await frames(12)
	await take("10-investigation-960p")
	expect(scene.audio_service.production_errors.is_empty(), "测试声音无缺失制作错误")
	scene.audio_service.shutdown()
	scene.queue_free()
	await frames(15)
	print("SYSTEM_DEMO_INPUT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
