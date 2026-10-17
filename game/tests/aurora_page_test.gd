extends SceneTree
## 正式入口的鼠标／键盘事件回归；隔离存储，不读写玩家档案。
var app: Control
var failures: Array[String] = []
var checks := 0
func _init() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("AURORA_PAGE_FAILED " + message)
func frames(count: int = 4) -> void:
	for i in range(count): await process_frame
func button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == text and node.is_visible_in_tree(): return node
	return null
func click(control: Control) -> void:
	check(is_instance_valid(control) and control.is_visible_in_tree(), "点击控件可见")
	if not is_instance_valid(control): return
	var parent := control.get_parent()
	while parent != null:
		if parent is ScrollContainer: parent.ensure_control_visible(control)
		parent = parent.get_parent()
	await frames(2)
	var point: Vector2 = control.get_global_transform() * (control.size / 2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event)
		await process_frame
	await frames()
func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = down
		root.push_input(event)
	await frames()
func drain() -> void:
	for i in range(1000):
		if app.session.mode != "narrative": return
		app.session.narrative.tick(100)
		if app.session.narrative.state.waiting_for_choice: app.session.narrative.choose_transition(0)
		else: app.session.narrative.advance()
func _run() -> void:
	root.size = Vector2i(1280, 800)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://aurora_page_test_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(6)
	check(app.current_layer == "title" and app.title_page.visible, "正式标题已建立")
	await click(app.title_page.new_game_button)
	await click(app.confirm_page.accept_button)
	check(app.current_layer == "game" and app.session.mode == "narrative", "鼠标开始正式开场")
	drain()
	await frames(8)
	var game: Control = app.gameplay_page
	check(app.session.mode == "investigation" and app.session.initial_saved, "开场后进入调查并写初档")
	check(game.objectives.integration_errors.is_empty(), "正式目标数据通过组件校验")
	await click(button(game.scene_page, "目标 / 回顾"))
	check(game.objective_page.visible, "点击打开正式回顾")
	check(not game.can_save(), "回顾禁止手动保存")
	await key(KEY_I)
	check(not game.reader_page.visible, "回顾内I不穿透")
	await key(KEY_ESCAPE)
	check(not game.objective_page.visible and app.current_layer == "game", "Esc只关闭回顾")
	await key(KEY_I)
	check(game.reader_page.visible and not game.can_save(), "I打开只读手册并禁存")
	await click(button(game.reader_page, "人物"))
	await click(button(game.reader_page, "交谈记录"))
	await key(KEY_I)
	check(not game.reader_page.visible, "I整体关闭手册")
	await click(button(game.scene_page, "地图"))
	check(game.map_page.visible, "正式地图可打开")
	await key(KEY_ESCAPE)
	check(not game.map_page.visible, "Esc关闭地图")
	await key(KEY_ESCAPE)
	check(app.current_layer == "pause", "Esc打开暂停")
	await click(app.pause_page.settings_button)
	check(app.settings_page.visible, "暂停设置可打开")
	if not app.settings_page.sliders.has("master_volume"): app.queue_free(); await frames(); quit(1); return
	var slider: HSlider = app.settings_page.sliders.master_volume
	slider.grab_focus()
	var before: float = slider.value
	await key(KEY_LEFT)
	check(slider.value < before, "正式设置滑杆接收键盘操作")
	await click(app.settings_page.close_button)
	check(app.current_layer == "pause", "设置关闭回原暂停")
	app._resume()
	await frames()
	# 业务夹具用来检验长文与选择模式边界；不冒称剧情取得路径。
	app.session.case_state.grant("E01_V1", {"entry": "ENTRY_CH01_READ_E01"})
	game.open_handbook()
	await frames()
	game.reader_page.open_content("E01_V1")
	await frames()
	var prose: Array = game.reader_page.find_children("*", "RichTextLabel", true, false)
	check(not prose.is_empty() and prose[0].fit_content and prose[0].size.y > 0, "原件全文参与滚动布局")
	check(button(game.reader_page, "选用当前版本") == null, "完整手册详情保持只读")
	await key(KEY_I)
	# 读取新档时，旧猫收尾不得覆盖目标mode和首见。
	var saved: Dictionary = app.session.export_snapshot()
	game.cat_page.cat.active = true
	game.cat_page.cat.first_seen = true
	app.session.mode = "cat"
	app._loaded(saved)
	await frames()
	check(app.session.mode == saved.mode and app.session.case_state.data.cat_first_seen == saved.case_state.cat_first_seen, "读取不写回旧猫状态")
	for dimensions in [Vector2i(1600,900), Vector2i(1920,1080)]:
		root.size = dimensions
		await frames(6)
		check(game.scene_page.canvas.scale.x == game.scene_page.canvas.scale.y, "调查画布等比显示")
	# 真实第一章留下大厅对话，随后移动到卧室并以鼠标点床，验证页面舞台而非只验scene状态。
	root.size = Vector2i(1280, 800)
	await frames(6)
	check(app.session.new_game(), "床菜单回归从新游戏建立真实状态")
	game.reset_page()
	app._resume()
	drain()
	for id in ["ENTRY_CH01_ENTER", "ENTRY_CH01_READ_E01"]: story_entry(id)
	story_move("SC02")
	for id in ["TALK_CH01_MAIN_1", "TALK_CH01_MAIN_2", "ENTRY_CH01_E05_READER"]: story_entry(id)
	story_move("SC06")
	story_entry("TALK_CH01_MAIN_3")
	story_move("SC02")
	await frames()
	await click(button(game.scene_page, "观察环境"))
	drain()
	check(game.narrative_page.stage.scene_id == "SC02", "点床前保留的是大厅对话舞台")
	story_move("SC08")
	await frames()
	var bed: Control = game.scene_page.find_child("HS_SC08_BED", true, false)
	if bed == null:
		for row in game.scene_page.model.hotspots():
			if row.object_ref == "OBJ_SC08_BED": bed = game.scene_page.find_child(str(row.hotspot_id), true, false)
	var bed_name := str(bed.name) if is_instance_valid(bed) else "HS_SC08_BED"
	await click(bed)
	check(app.session.mode == "narrative" and app.session.case_state.data.scene == "SC08", "鼠标点床仅打开卧室选项")
	check(game.narrative_page.stage.scene_id == "SC08" and game.narrative_page.stage.background.texture.resource_path.contains("SC08_"), "床菜单实际舞台显示卧室背景")
	check(game.narrative_page.stage.occupants.is_empty(), "床菜单没有残留上一段人物")
	check(button(game.narrative_page, "休息") != null and button(game.narrative_page, "再待一会儿") != null, "点床显示两项实际操作")
	await click(button(game.narrative_page, "再待一会儿"))
	check(app.session.mode == "investigation" and app.session.case_state.data.scene == "SC08", "鼠标取消休息回到卧室")
	await click(game.scene_page.find_child(bed_name, true, false))
	await click(button(game.narrative_page, "休息"))
	check(app.session.active_entry == "ENTRY_CH01_REST" and game.narrative_page.stage.scene_id == "SC08", "选择休息才在卧室开始休息正文")
	drain()
	check(app.session.case_state.data.chapter == "CH02" and app.session.case_state.data.scene == "SC02", "休息后仍按正式剧情经过案发和电话到大厅")
	app.queue_free()
	# 动态页面和主题资源在退出前需要至少一个完整空闲周期；多等几帧
	# 让 queue_free、信号断开和渲染资源释放完成，避免把测试收尾告警误判为业务错误。
	await frames(30)
	print("AURORA_PAGE ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func story_entry(id: String) -> void:
	check(app.session.activate_entry(id), "实际剧情入口可用：" + id)
	drain()
	if app.session.mode == "material":
		check(app.session.material_read_complete(), "原件实际读完：" + id)
		drain()

func story_move(id: String) -> void:
	check(app.session.travel(id), "实际地图前往：" + id)
	app.session.arrive()
	drain()
