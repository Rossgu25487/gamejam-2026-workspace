extends SceneTree
## 实际 Control 事件分发与布局回归；可加 -- --capture 导出白模画面。
## 这是注入鼠标／键盘事件的程序测试，不代替人工键鼠验收。

var failures: Array[String] = []
var scene: Control
var checks := 0
var capture := false
var folder := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/core-captures")

func _initialize() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("INPUT_FAILED: " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func click(button: Button) -> void:
	expect(is_instance_valid(button) and button.is_visible_in_tree(), "点击目标存在且可见")
	if not is_instance_valid(button): return
	var point := button.get_global_rect().get_center()
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

func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)
	await frames()

func options(parent: Node) -> Array[OptionButton]:
	var found: Array[OptionButton] = []
	for child in parent.get_children():
		if child is OptionButton: found.append(child)
		found.append_array(options(child))
	return found

func choose(parent: Node, index: int, filter_index: int = 0) -> void:
	# 经过真实 PopupMenu 的打开、选中和关闭，不能仅发 item_selected 跳过焦点生命周期。
	var option := options(parent)[filter_index]
	var popup := option.get_popup()
	await click(option)
	expect(is_instance_valid(popup) and popup.visible, "筛选下拉菜单实际打开")
	if not is_instance_valid(popup) or not popup.visible: return
	popup.set_focused_item(index)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	root.push_input(event)
	await process_frame
	event = InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = false
	root.push_input(event)
	await frames()
	expect(scene.current_layer == "investigation", "筛选不误触发暂停")

func button(parent: Node, label: String) -> Button:
	for child in parent.get_children():
		if child is Button and child.text == label: return child
		var found := button(child, label)
		if found != null: return found
	return null

func label(parent: Node, text: String) -> Label:
	for child in parent.get_children():
		if child is Label and child.text == text: return child
		var found := label(child, text)
		if found != null: return found
	return null

func take(name: String) -> void:
	if not capture: return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(folder)
	root.get_texture().get_image().save_png(folder.path_join(name + ".png"))

func within(control: Control) -> bool:
	var rect := control.get_global_rect()
	var area := root.get_visible_rect()
	return area.encloses(rect) and rect.size.x > 0 and rect.size.y > 0

func _run() -> void:
	root.size = Vector2i(1280,800)
	scene = load("res://main/main.tscn").instantiate()
	scene.test_storage_path = "user://core-input/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await frames()
	await click(scene.title_page.settings_button)
	expect(scene.current_layer == "subpage", "鼠标打开设置")
	await click(button(scene.settings_page, "关闭设置"))
	expect(scene.current_layer == "title", "鼠标关闭设置返回标题")
	await click(scene.title_page.new_game_button)
	expect(scene.current_layer == "investigation", "鼠标开始新游戏")
	await take("1280-investigation")
	await click(button(scene.gameplay_page.investigation, "检查占位资料"))
	expect(scene.session_service.core.state.mode == "dialogue", "鼠标调查取得材料")
	await click(button(scene.gameplay_page.investigation, scene.session_service.core.ui("UI_RETURN_INVESTIGATION")))
	await click(button(scene.gameplay_page.investigation, "与占位人物交谈"))
	await click(button(scene.gameplay_page.investigation, scene.session_service.core.ui("UI_RETURN_INVESTIGATION")))
	await click(button(scene.gameplay_page.investigation, "核对占位说法"))
	var core: Node = scene.session_service.core
	expect(core.state.mode == "selection", "鼠标进入说法选材")
	var page: Control = scene.gameplay_page.selection
	await click(button(page, "点击选择目标：这份记录始终没有变化。"))
	await click(button(page, "占位证据甲"))
	expect(scene.gameplay_page.reader.visible, "材料详情鼠标可点击")
	await click(button(scene.gameplay_page.reader, core.ui("UI_CORE_SELECT")))
	expect(core.draft().slots[0] == core.catalog.material_ref("A1"), "详情选用动作接入服务")
	await click(button(page, "占位证据乙"))
	await click(button(scene.gameplay_page.reader, core.ui("UI_CORE_SELECT")))
	await take("1280-selection")
	for b in page.card_buttons: expect(within(b), "1280底栏按钮完整在窗口内")
	for b in page.card_buttons:
		var card: Control = b.get_parent().get_parent()
		expect(absf(card.size.x / card.size.y - 2.0/3.0) < 0.03, "底栏竖卡保持2:3")
	await click(button(page,"全部材料"))
	expect(core.state.card_ui_page == "grid" and page.card_buttons.size() == 7, "网格点击显示全部七份材料")
	var grid: GridContainer = page.grid_scroll.get_child(0)
	for card in grid.get_children(): expect(within(card), "紧凑网格前两行完整可见")
	await take("1280-grid")
	await key(KEY_ESCAPE)
	expect(core.state.card_ui_page == "selection", "键盘Esc只收网格")
	await key(KEY_I)
	expect(scene.gameplay_page.reader.visible and scene.gameplay_page.reader.root_kind == "library", "I打开只读手册")
	var held: Dictionary = core.draft()
	await key(KEY_I)
	expect(not scene.gameplay_page.reader.visible and core.draft() == held, "I关闭整次检视且保留出示槽")
	await click(button(page,core.ui("UI_CORE_PRESENT")))
	expect(core.state.mode == "pending" and scene.gameplay_page.feedback.active, "鼠标出示进入待收表现")
	await key(KEY_ESCAPE)
	expect(scene.current_layer == "pause", "演出中Esc打开共用暂停")
	await click(scene.pause_page.resume_button)
	await click(button(scene.gameplay_page.feedback, "跳过表现"))
	expect(not core.presenting and not core.store.owns(core.catalog.material_ref("I1")), "鼠标跳过不替代收下")
	await take("1280-pending")
	await click(button(scene.gameplay_page.result,core.ui("UI_CORE_COLLECT_INFERENCE")))
	await click(button(scene.gameplay_page.feedback, "跳过表现"))
	await click(button(scene.gameplay_page.result,core.ui("UI_TITLE_CONTINUE")))
	expect(core.state.mode == "investigation" and "Q1" in core.state.completed_questions, "鼠标收下与继续形成完整闭环")
	await click(button(scene.gameplay_page.investigation,"核明后续占位问题"))
	await frames()
	expect(core.draft().target_selected, "后续推理入口自动选择目标")
	var target_text: String = "推理目标（已选定）：" + core.catalog.text("q2_text")
	expect(label(page, target_text) != null and button(page, target_text) == null, "自动选定的推理目标明确展示为问题文本")
	expect(button(page, core.ui("UI_CORE_PRESENT")).disabled, "推理目标自动选定仍需选用材料才能出示")
	await choose(page, 3)
	expect(core.current_view().type == "inference", "选材切换推论筛选")
	await choose(page, 0)
	expect(core.current_view().type == "all", "推论筛选返回全部")
	await click(button(page, "全部材料"))
	expect(core.state.card_ui_page == "grid", "后续问题展开全部材料")
	await choose(page, 3)
	await choose(page, 0)
	expect(core.current_view().type == "all" and page.card_buttons.size() == 8, "网格全部恢复所有材料")
	await key(KEY_I)
	var reader: Control = scene.gameplay_page.reader
	await choose(reader, 3)
	expect(reader.library_view.type == "inference", "手册切换推论筛选")
	await choose(reader, 0)
	expect(reader.library_view.type == "all", "手册推论筛选返回全部")
	await choose(reader, 1, 1)
	expect(reader.library_view.sort == "type", "手册排序下拉菜单安全刷新")
	await key(KEY_I)
	expect(core.inspection_depth == 0 and not core.paused and core.can_save(), "关闭手册恢复校验资格")
	await click(button(page, "占位推论"))
	await click(button(reader, core.ui("UI_CORE_SELECT")))
	await click(button(page, "占位证据乙"))
	await click(button(reader, core.ui("UI_CORE_SELECT")))
	await take("1280-q2-selection")
	for b in page.card_buttons: expect(within(b), "1280后续问题卡牌按钮完整在窗口内")
	expect(core.can_present() and not button(page, core.ui("UI_CORE_PRESENT")).disabled, "两份材料入槽后校验按钮可用")
	# 模拟一次状态刷新尚未执行就打开暂停；恢复时必须重算按钮资格。
	core.select_target()
	scene._open_pause()
	await frames()
	await click(scene.pause_page.resume_button)
	expect(core.can_present() and not button(page, core.ui("UI_CORE_PRESENT")).disabled, "暂停期间刷新后恢复仍可校验")
	await click(button(page, core.ui("UI_CORE_PRESENT")))
	expect(core.state.mode == "response" and core.state.current_result.feedback == "full", "筛选与检视后鼠标校验产生充分结果")
	# 限时等待显示时钟自然结束，验证不点击跳过也能得到可继续的完整结果。
	var deadline := Time.get_ticks_msec() + 5000
	while scene.gameplay_page.feedback.active and Time.get_ticks_msec() < deadline:
		await process_frame
	expect(scene.gameplay_page.result.visible and not core.presenting, "后续推理显示完整结果并解锁")
	await take("1280-q2-result")
	await click(button(scene.gameplay_page.result, core.ui("UI_TITLE_CONTINUE")))
	expect("Q2" in core.state.completed_questions and core.state.mode == "investigation", "后续问题确认并正常返回")
	await click(button(scene.gameplay_page.investigation, "核对占位说法 · 回看"))
	await click(button(scene.gameplay_page.result, core.ui("UI_TITLE_CONTINUE")))
	await click(button(scene.gameplay_page.investigation, "核明后续占位问题 · 回看"))
	await click(button(scene.gameplay_page.result, core.ui("UI_TITLE_CONTINUE")))
	expect(core.state.mode == "investigation", "两个已完成结果均能重复回看和继续")
	core.start_new_game()
	core.activate_entry("INSPECT"); core.finish_dialogue()
	core.activate_entry("TALK"); core.finish_dialogue()
	core.open_card_session("Q1")
	await frames()
	root.size = Vector2i(1920,1080)
	await frames()
	await take("1920-selection")
	for b in page.card_buttons: expect(within(b), "1920底栏按钮完整在窗口内")
	scene.queue_free()
	await frames()
	if failures.is_empty(): print("CORE_INPUT_PASS: %d checks; dispatched mouse/key events at 1280x800 and 1920x1080." % checks)
	else: printerr("CORE_INPUT_FAIL: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
