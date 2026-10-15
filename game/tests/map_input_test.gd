extends SceneTree
## 地图专项输入回归：通过实际 Control 鼠标分发验证地点预览、资格、前往和返回。
## 单地点主工程与多地点示例均使用隔离存档目录，不改动玩家数据。

var failures: Array[String] = []
var checks := 0
var scene: Control

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("MAP_INPUT_FAILED: " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func button(parent: Node, text: String) -> Button:
	for child in parent.get_children():
		if child is Button and child.text == text: return child
		var found := button(child, text)
		if found != null: return found
	return null

func location_button(parent: Node, scene_id: String, role: String = "node") -> Button:
	for child in parent.get_children():
		if child is Button and child.get_meta("scene_id", "") == scene_id and child.get_meta("map_role", "") == role: return child
		var found := location_button(child, scene_id, role)
		if found != null: return found
	return null

func click(control: Button, intercepted: bool = false) -> void:
	expect(is_instance_valid(control) and control.is_visible_in_tree() and not control.disabled, "点击目标存在并可用")
	if not is_instance_valid(control) or control.disabled: return
	var point := control.get_global_rect().get_center()
	expect(root.get_visible_rect().has_point(point), "点击目标位于视口内")
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	expect((root.gui_get_hovered_control() != control) if intercepted else (root.gui_get_hovered_control() == control), "地图正确隔离按钮点击：" + control.text)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
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
		await process_frame
	await frames()

func start_scene(path: String) -> void:
	scene = load(path).instantiate()
	scene.test_storage_path = "user://map-input/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await frames()
	await click(scene.title_page.new_game_button)
	await click(scene.confirm_page.accept_button)

func check_layout(page: Control) -> void:
	var rect: Rect2 = page.panel.get_global_rect()
	expect(root.get_visible_rect().encloses(rect), "地图面板完整位于视口内")
	expect(rect.get_center().distance_to(root.get_visible_rect().get_center()) < 1.0, "地图在当前分辨率居中")
	expect(page.get_child_count() == 1, "状态刷新后仅保留一套地图控件")

func _run() -> void:
	root.size = Vector2i(1280, 800)
	await start_scene("res://main/main.tscn")
	await click(button(scene.gameplay_page.investigation, "地图"))
	var page: Control = scene.gameplay_page.map_page
	var service: Node = scene.session_service.map_navigation
	check_layout(page)
	expect(service.available_transitions().is_empty(), "默认单地点故事没有伪造目的地")
	await click(location_button(page, service.current_scene_id()))
	expect(button(page, "前往").disabled and button(page, "前往").tooltip_text == "当前没有可前往的其他地点", "无目的地时明确解释前往禁用原因")
	await click(button(page, "返回调查"))
	expect(not page.visible and not service.state.open, "鼠标关闭地图并结束服务调用")
	scene.queue_free()
	await frames()
	await start_scene("res://examples/rainy_library.tscn")
	page = scene.gameplay_page.map_page
	service = scene.session_service.map_navigation
	var core: Node = scene.session_service.core
	expect(service.locations.has("DESK") and service.locations.has("ARCHIVE"), "地图保留故事真实地点，未被策划示例ID替换")
	for resolution in [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(1100, 720)]:
		root.size = resolution
		await frames()
		await click(button(scene.gameplay_page.investigation, "地图"))
		check_layout(page)
		var archive: Button = location_button(page, "ARCHIVE")
		expect(is_instance_valid(archive) and archive.text.contains("档案室"), "节点使用故事地点名称")
		expect(location_button(page, "EX_SCENE_A") == null, "未绑定的策划样例地点不暴露为目的地")
		await click(archive)
		expect(core.state.current_scene_id == "DESK" and service.state.selected_scene_id == "ARCHIVE", "锁定地点也能点击预览且不立即移动")
		expect(button(page, "前往").disabled and not button(page, "前往").tooltip_text.is_empty(), "锁定目的地禁用前往并解释原因")
		await click(location_button(page, "DESK", "list"))
		expect(service.state.selected_scene_id == "DESK", "地点列表和节点同步预览选择")
		await key(KEY_I)
		expect(not scene.gameplay_page.reader.visible and core.inspection_depth == 0, "地图期间I不打开底层手册")
		expect(not scene.gameplay_page.margin.visible and not scene.gameplay_page.image_layer.visible, "地图期间底层工具与图片卡不接收焦点")
		expect(scene.current_layer == "investigation", "地图外点击不会穿透打开暂停菜单")
		await key(KEY_ESCAPE)
		expect(not page.visible and not service.state.open, "Esc正常返回调查")
	# 夹具模拟完成首题这一合法剧情资格；本测试聚焦地图输入，不重复证明过程。
	root.size = Vector2i(1280, 800)
	core.state.completed_questions.append("CHECK_LENDING")
	expect(core.store.acquire("AFTER_SEVEN_1", {}), "夹具已获得首题推论")
	core.changed.emit()
	await frames()
	expect(core.condition_met("LENDING_DONE"), "示例已满足档案室开放条件")
	var before: Dictionary = core.export_card_state()
	var sequence: int = scene.save_service.sequence
	await click(button(scene.gameplay_page.investigation, "地图"))
	await click(location_button(page, "ARCHIVE", "list"))
	expect(service.state.selected_scene_id == "ARCHIVE" and not button(page, "前往").disabled, "点击可达地点列表启用前往")
	expect(core.state.current_scene_id == "DESK" and not scene.session_service.can_save(), "预览不移动且地图期间禁止保存")
	await click(button(page, "前往"))
	for i in range(450):
		if not page.visible: break
		await create_timer(0.01).timeout
	expect(core.state.current_scene_id == "ARCHIVE" and not page.visible and not service.state.open, "实际鼠标前往成功并关闭地图")
	expect(scene.audio_service.current_soundscape.get("target") == "ARCHIVE", "地图实际到达后同步目标地点音景")
	expect(core.state.drafts == before.drafts and core.state.facts == before.facts, "普通前往保留核心草稿和事实")
	expect(core.export_card_state().materials == before.materials, "普通前往保留材料")
	expect(scene.save_service.sequence == sequence, "地图普通前往不产生自动档")
	# PNG 调查卡由页面自己的图片层承载，文字入口才位于 investigation 子节点。
	expect(button(scene.gameplay_page, "检查归还凭条") != null and button(scene.gameplay_page, "检查柜台借阅簿") == null, "切换后调查卡刷新为目标地点并移除原地点入口")
	await click(button(scene.gameplay_page.investigation, "地图"))
	await click(location_button(page, "DESK"))
	await click(button(page, "前往"))
	for i in range(450):
		if not page.visible: break
		await create_timer(0.01).timeout
	expect(core.state.current_scene_id == "DESK" and not page.visible, "再次打开地图可返回原地点")
	expect(scene.audio_service.current_soundscape.get("target") == "DESK", "返回原地点同步原音景")
	scene.queue_free()
	await frames()
	if failures.is_empty(): print("MAP_INPUT_PASS: %d checks; dispatched map mouse/key events at three resolutions." % checks)
	else: printerr("MAP_INPUT_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
