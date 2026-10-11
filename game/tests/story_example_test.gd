extends SceneTree
## 使用真实控件输入走完示例，验证错误、补材、推论、地点与磁盘存读档。
## 测试每次使用独立目录，不改玩家与示例试玩的已有存档。

var scene: Control
var failures: Array[String] = []
var checks := 0
var capture := false
var folder := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/story-example-captures")

func _initialize() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("EXAMPLE_FAILED: " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func button(parent: Node, title: String, prefix: bool = false) -> Button:
	for child in parent.get_children():
		if child is Button and (child.text.begins_with(title) if prefix else child.text == title): return child
		var found := button(child, title, prefix)
		if found != null: return found
	return null

func has_label(parent: Node, text: String) -> bool:
	for child in parent.get_children():
		if child is Label and child.text == text: return true
		if has_label(child, text): return true
	return false

func click(control: Button) -> void:
	expect(is_instance_valid(control) and control.is_visible_in_tree() and not control.disabled, "按钮可点击：" + (control.text if is_instance_valid(control) else "缺失"))
	if not is_instance_valid(control) or control.disabled: return
	var point := control.get_global_rect().get_center()
	expect(root.get_visible_rect().has_point(point), "按钮中心位于窗口内：" + control.text)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event)
		await process_frame
	await frames()

func take(name: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder.path_join(name + ".png"))

func investigate(title: String) -> void:
	await click(button(scene.gameplay_page.investigation, title))
	expect(scene.session_service.core.state.mode == "dialogue", "调查显示正文：" + title)
	await click(button(scene.gameplay_page.investigation, scene.session_service.core.ui("UI_RETURN_INVESTIGATION")))

func select_card(title: String) -> void:
	await click(button(scene.gameplay_page.selection, title))
	expect(scene.gameplay_page.reader.visible, "阅读卡牌：" + title)
	await click(button(scene.gameplay_page.reader, scene.session_service.core.ui("UI_CORE_SELECT")))

func skip_effect() -> void:
	await click(button(scene.gameplay_page.feedback, "跳过表现"))

func load_manual() -> void:
	await click(button(scene.gameplay_page, "菜单 / Esc"))
	await click(scene.pause_page.load_button)
	await click(button(scene.load_page, "manual 1", true))

func _run() -> void:
	root.size = Vector2i(1280, 800)
	scene = load("res://examples/rainy_library.tscn").instantiate()
	scene.test_storage_path = "user://story-example-tests/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await frames()
	var core: Node = scene.session_service.core
	expect(core.catalog.errors.is_empty(), "示例工作簿合法：" + str(core.catalog.errors))
	if not core.catalog.errors.is_empty(): scene.queue_free(); quit(1); return
	expect(scene.title_page.heading.text == "雨夜借阅单", "标题来自示例配置")
	expect(scene.save_service.scan().is_empty(), "测试存档目录隔离")
	await click(scene.title_page.new_game_button)
	expect(scene.current_layer == "investigation" and core.state.current_scene_id == "DESK", "新游戏进入柜台")
	expect(scene.save_service.load_latest().card_snapshot.current_scene_id == "DESK" and scene.save_service.sequence == 1, "第一次新游戏生成初始自动档")
	expect(button(scene.gameplay_page.investigation, "进入档案室").disabled, "档案室尚未开放")
	expect(not core.move_scene("TO_ARCHIVE"), "核心同时拒绝提前移动")
	# 这次拒绝是测试直接调用服务，正式界面的禁用按钮不会产生该提示。
	scene.gameplay_page.notice_label.text = ""
	await take("01-investigation")
	for title in ["检查柜台借阅簿", "查看书架标签", "查看招领夹", "询问管理员林岚"]: await investigate(title)
	await click(button(scene.gameplay_page.investigation, "核对晚间借阅说法"))
	await click(button(scene.gameplay_page.selection, "点击选择目标：七点以后，没有人借走A-17。"))
	await select_card("A-71招领单")
	await click(button(scene.gameplay_page.selection, core.ui("UI_CORE_PRESENT")))
	expect(core.state.current_result.feedback == "incorrect" and core.state.chances.CHECK_LENDING == 2, "错误编号扣一次容错")
	await skip_effect()
	await take("02-wrong-number")
	await click(button(scene.gameplay_page.result, core.ui("UI_CORE_RESELECT")))
	await click(button(scene.gameplay_page.selection, "全部撤下"))
	await select_card("晚间借阅簿")
	await click(button(scene.gameplay_page.selection, core.ui("UI_CORE_PRESENT")))
	expect(core.state.current_result.feedback == "partial" and core.state.chances.CHECK_LENDING == 2, "单份借阅簿局部成立且不扣次")
	await skip_effect()
	await click(button(scene.gameplay_page.result, "补入 A-17书架标签"))
	expect(core.state.mode == "pending" and not core.store.owns(core.catalog.material_ref("AFTER_SEVEN_1")), "共同证明生成待收推论")
	expect(not core.can_save() and not core.condition_met("LENDING_DONE"), "尚未收下时不解锁或保存")
	await skip_effect()
	await take("03-inference")
	await click(button(scene.gameplay_page.result, core.ui("UI_CORE_COLLECT_INFERENCE")))
	expect(core.store.owns(core.catalog.material_ref("AFTER_SEVEN_1")) and core.state.current_statements.CHECK_LENDING == "CLAIM_2", "主动收下提交推论和说法更正")
	await skip_effect()
	await click(button(scene.gameplay_page.result, core.ui("UI_TITLE_CONTINUE")))
	expect(core.state.mode == "investigation" and core.condition_met("LENDING_DONE"), "正常返回后开放档案室")
	await click(button(scene.gameplay_page.investigation, "进入档案室"))
	expect(core.state.current_scene_id == "ARCHIVE" and scene.save_service.load_latest().card_snapshot.current_scene_id == "ARCHIVE", "移动后自动档记录新地点")
	expect(button(scene.gameplay_page.investigation, "检查柜台借阅簿") == null, "异地入口不显示")
	await take("04-archive")
	await investigate("检查归还凭条")
	await click(button(scene.gameplay_page.investigation, "确认A-17的去向"))
	expect(core.draft().target_selected, "自主推理自动选定问题")
	await click(button(scene.gameplay_page.selection, "全部材料"))
	await select_card("七点后的借阅")
	await select_card("A-17归还凭条")
	await take("05-final-selection")
	await click(button(scene.gameplay_page.selection, core.ui("UI_CORE_PRESENT")))
	expect(core.state.current_result.feedback == "full" and "FIND_FILE" not in core.state.completed_questions, "前次确认与归还凭条充分，但需继续提交")
	await skip_effect()
	await click(button(scene.gameplay_page.result, core.ui("UI_TITLE_CONTINUE")))
	expect(core.condition_met("CASE_DONE") and core.state.completed_questions.size() == 2, "完整故事完成")
	expect(has_label(scene.gameplay_page.investigation, core.catalog.text(core.catalog.data.completion_text)), "完成提示来自表格")
	await take("06-complete")
	# 通过页面写入手动档，开新局后两次读回，验证来源快照可递归恢复。
	await click(button(scene.gameplay_page, "菜单 / Esc"))
	await click(scene.pause_page.save_button)
	await click(button(scene.save_page, "手动存档 1"))
	var saved: Dictionary = scene.save_service.load_snapshot("manual", 0)
	expect(not saved.is_empty() and saved.card_snapshot.completed_questions.size() == 2, "手动档写入两题完成和真实材料来源")
	await click(scene.pause_page.resume_button)
	core.start_new_game()
	await frames()
	await load_manual()
	expect(core.state.current_scene_id == "ARCHIVE" and core.condition_met("CASE_DONE") and core.state.chances.CHECK_LENDING == 2, "新局后读取恢复地点、完成和容错")
	await load_manual()
	expect(core.condition_met("CASE_DONE"), "重复读取同一存档稳定")
	await click(button(scene.gameplay_page, "菜单 / Esc"))
	await click(scene.pause_page.return_title_button)
	await click(scene.confirm_page.direct_button)
	expect(scene.current_layer == "title" and not scene.gameplay_page.visible, "返回标题隐藏调查页面")
	await click(scene.title_page.continue_button)
	expect(core.condition_met("CASE_DONE") and core.state.current_scene_id == "ARCHIVE", "继续调查恢复最新手动存档")
	# 更换内容版本时拒绝旧快照；恢复原版本后继续保持可玩。
	var revision: String = core.catalog.data.content_revision
	core.catalog.data.content_revision = "rainy-library-xlsx-2"
	expect(not scene.session_service.validate_snapshot(saved), "故事内容版本隔离")
	core.catalog.data.content_revision = revision
	scene.queue_free()
	await frames()
	if failures.is_empty(): print("STORY_EXAMPLE_PASS: %d checks; XLSX story, dispatched input, proof, scene navigation, save/load and continue." % checks)
	else: printerr("STORY_EXAMPLE_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
