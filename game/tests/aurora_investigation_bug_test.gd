extends SceneTree
## bug.xlsx 27–35 中程序问题的正式配置与实际输入回归；存档完全隔离。
var app: Control
var failures: Array[String] = []
var checks := 0
var capture := false
var folder := ProjectSettings.globalize_path("res://../.local/bug27-35/captures")
func _init() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("INVESTIGATION_BUG_FAILED: " + message)
func frames(count: int = 6) -> void:
	for i in range(count): await process_frame
func button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == text and node.is_visible_in_tree(): return node
	return null
func move_mouse(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)
	await frames(2)
func click(control: Control) -> void:
	check(is_instance_valid(control) and control.is_visible_in_tree(), "点击目标可见")
	if not is_instance_valid(control): return
	var point := control.get_global_transform() * (control.size / 2)
	await move_mouse(point)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame
	await frames()
func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		root.push_input(event, true)
	await frames()
func drain() -> void:
	for i in range(1000):
		if app.session.mode != "narrative": return
		app.session.narrative.tick(100)
		if app.session.narrative.state.waiting_for_choice: app.session.narrative.choose_transition(0)
		else: app.session.narrative.advance()
	check(false, "正文接续应结束")
func enter(id: String) -> void:
	check(app.session.activate_entry(id), "真实入口可用：" + id)
	drain()
	if app.session.mode == "material":
		check(app.session.material_read_complete(), "原件读完：" + id)
		drain()
func travel(id: String) -> void:
	check(app.session.travel(id), "地图前往：" + id)
	app.session.arrive()
	drain()
func take(name: String) -> void:
	if not capture: return
	await frames()
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(folder)
	check(root.get_texture().get_image().save_png(folder.path_join(name + ".png")) == OK, "保存画面证据")
func image_paths(page: Node) -> Array:
	var paths: Array = []
	for node in page.find_children("*", "TextureRect", true, false):
		if node.has_meta("image_path"): paths.append(str(node.get_meta("image_path")))
	return paths
func _run() -> void:
	root.size = Vector2i(1280, 800)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://investigation_bug_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(10)
	check(app.debug_new_game(), "启动隔离新游戏")
	drain()
	await frames()
	var game: Control = app.gameplay_page
	var page: Control = game.scene_page
	var truck: Button = page.find_child("HS_SC01_BUS", true, false)
	await move_mouse(truck.get_global_transform() * (truck.size / 2))
	check(page.hint.text.contains("检查") and page.hint.text.contains("货运"), "27 鼠标悬停即时显示对象和检查操作")
	check(truck.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND and truck.has_theme_stylebox_override("hover"), "27 热区有手形和高亮")
	await move_mouse(page.canvas.get_global_transform() * Vector2(20, 700))
	check(page.hint.text.is_empty(), "27 移开后隐藏提示")
	truck.grab_focus()
	check(page.hint.text.contains("检查"), "27 键盘聚焦与鼠标共用提示")
	await take("01-hotspot")
	await click(truck)
	check(app.session.mode == "narrative", "28 货车点击进入实际正文")
	check(app.session.investigation_view() == "VIEW_SC01_BUS", "28 货车局部视图持续绑定到本次检查")
	check(app.session.narrative.current_record().background_path.contains("SC01_货车驾驶室_票据袋在位"), "28 正文采用当前票据袋状态的驾驶室近景")
	check(game.narrative_page.stage.background.texture == load(app.session.background_path()), "28 舞台实际纹理使用配置近景")
	check(app.session.case_state.data.view == "VIEW_SC01_MAIN", "28 局部图不改变真实地点主视图")
	check(button(game.narrative_page, "返回调查") != null, "35 正文阅读中提供返回")
	await take("02-truck-reading")
	var materials_before: Dictionary = app.session.case_state.data.materials.duplicate(true)
	await click(button(game.narrative_page, "返回调查"))
	check(app.session.mode == "investigation" and app.session.case_state.data.materials == materials_before, "35 提前返回不授予未读材料")
	check(not app.session.case_state.data.entries.get("ENTRY_CH01_TRUCK_FIRST", false), "35 提前关闭不记录检查完成")
	check(button(page, "返回调查") != null, "35 返回局部检查后仍有退出入口")
	await click(button(page, "返回调查"))
	check(page.current_context.is_empty() and app.session.return_context.kind == "scene", "35 退出局部后恢复调查上下文")
	await click(page.find_child("HS_SC01_BUS", true, false))
	drain()
	await frames()
	check(app.session.mode == "investigation" and page.current_context.get("detail") == "VIEW_SC01_BUS", "28 读完后仍保持原局部图")
	check(image_paths(page).any(func(path): return path.contains("SC01_货车驾驶室_票据袋在位")), "28 局部图也消费状态背景")
	await key(KEY_ESCAPE)
	check(page.current_context.is_empty() and app.current_layer == "game", "35 Esc只退出当前局部层")
	await click(page.find_child("HS_SC01_NOTICE", true, false))
	check(app.session.narrative.current_record().scene_layers.any(func(row): return row.image_path.contains("告示栏") and row.w == 538), "28 独立物件详情沿配置矩形，不拉伸整屏")
	await key(KEY_ESCAPE)
	await key(KEY_ESCAPE)
	check(app.current_layer == "game" and page.current_context.is_empty(), "35 Esc逐层退出正文与检查")
	# 第一章沿真实完成事件进入案发；不注入案件事实。
	enter("ENTRY_CH01_ENTER")
	enter("ENTRY_CH01_READ_E01")
	travel("SC02")
	for id in ["TALK_CH01_MAIN_1", "TALK_CH01_MAIN_2", "ENTRY_CH01_E05_READER"]: enter(id)
	travel("SC06")
	enter("TALK_CH01_MAIN_3")
	travel("SC08")
	await frames()
	var beds: Array = page.model.hotspots().filter(func(row): return row.object_ref == "OBJ_SC08_BED")
	await click(page.find_child(str(beds[0].hotspot_id), true, false))
	await click(button(game.narrative_page, "休息"))
	drain()
	await frames(12)
	check(app.session.mode == "investigation" and app.session.case_state.data.chapter == "CH02", "29 案发剧情结束进入调查")
	check(game.objective_hud.visible and game.objectives.hud_view().goal_id == "GOAL_CH02", "29 案发后不打开系统入口也显示最新目标")
	# 模拟旧检查窗口遗留以及空话题失效，两种状态都不得把目标藏住。
	page.current_context = {"kind": "inspection", "scene": "SC08", "view": "VIEW_SC08_MAIN"}
	game.refresh()
	await frames()
	check(page.current_context.is_empty() and game.objective_hud.visible, "29 场景迁移清理过期检查并恢复目标")
	page.current_context = {"kind": "topics", "scene": app.session.case_state.data.scene, "topics": ""}
	game.refresh()
	await frames()
	check(page.current_context.is_empty() and game.objective_hud.visible, "29 最后话题消失后恢复目标")
	check(app.session.force_travel("SC09"), "前往站长室画面夹具")
	await frames()
	check(app.session.background_path().contains("SC09_站长室_案后事件"), "31 使用正式配置中含遗体的站长室底图")
	check(image_paths(page).any(func(path): return path.contains("SC09_站长室_案后事件")), "31 调查画面实际创建案后底图纹理")
	await take("03-body-scene")
	await click(page.find_child("HS_SC09_CABINET", true, false))
	check(app.session.narrative.current_record().background_path.contains("SC09_近门资料柜"), "35 窄柜阅读使用配置局部图")
	drain()
	await frames()
	check(button(page, "返回调查") != null, "35 窄柜读完保留可点击的返回")
	await take("04-cabinet")
	await click(button(page, "返回调查"))
	check(game.objective_hud.visible and app.session.background_path().contains("案后事件"), "35 返回后恢复目标与遗体背景")
	await click(page.find_child("HS_SC09_BODY", true, false))
	await frames()
	check(image_paths(page).any(func(path): return path.contains("椅旁调查框景")), "31 遗体详情仅取配置底图，不被脸额伤处附图覆盖")
	await click(button(page, "返回调查"))
	for dimensions in [Vector2i(1100,720), Vector2i(1280,800), Vector2i(1920,1080)]:
		root.size = dimensions
		await frames()
		await click(page.find_child("HS_SC09_CABINET", true, false))
		await frames()
		var close := button(game.narrative_page, "返回调查") if app.session.mode == "narrative" else button(page, "返回调查")
		check(close != null and root.get_visible_rect().encloses(close.get_global_rect()), "35 各窗口尺寸返回按钮完整可见：%s mode=%s ctx=%s rect=%s viewport=%s" % [dimensions, app.session.mode, page.current_context, close.get_global_rect() if close != null else Rect2(), root.get_visible_rect()])
		await key(KEY_ESCAPE)
		if page.has_context(): await click(button(page, "返回调查"))
	app.queue_free()
	await frames(30)
	print("INVESTIGATION_BUG ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)
