extends SceneTree
## 正式手册以长原文、长来源和公开人物覆盖多比例阅读、明确详察与模态输入。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Handbook = preload("res://pages/aurora/aurora_handbook_page.gd")
var failures: Array[String] = []
var checks := 0
var under_clicks := 0
var session: Node
var page: Control

func _initialize() -> void: call_deferred("run")

func check(value: bool, text: String) -> void:
	checks += 1
	if not value: failures.append(text); push_error(text)

func run() -> void:
	session = Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式配置载入")
	session.case_state.reset()
	session.mode = "investigation"
	for id in session.config.contents: session.case_state.grant(str(id), {"entry": "ENTRY_CH01_ENTER"})
	for id in session.config.profiles:
		var row: Dictionary = session.config.profiles[id]
		session.case_state.data.profiles[row.person_id] = id
	var blocker := Button.new()
	blocker.position = Vector2(0, 0)
	blocker.size = Vector2(64, 64)
	blocker.pressed.connect(func(): under_clicks += 1)
	root.add_child(blocker)
	page = Handbook.new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session)
	for dimensions in [Vector2i(1600, 900), Vector2i(1200, 900), Vector2i(960, 540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		page.tab = "materials"
		page.open_library()
		await frames()
		var paper := page.find_child("HandbookPaperPanel", true, false)
		check(inside(paper), str(dimensions) + " 纸面保持有效显示区内")
		check(inside(button("关闭手册")) and inside(button("详察当前材料")), str(dimensions) + " 材料退出与详察始终可见")
		check(page.canvas.size.x >= 1199 and is_equal_approx(page.canvas.scale.x, float(dimensions.y) / 900), str(dimensions) + " 按高度适配正文且窄画面不继续压字")
		check(page.material_page_capacity() == (8 if dimensions.x == 1200 else 10), str(dimensions) + " 缩略分页按可用宽重排")
		check(page.find_child("SelectedMaterialPreview", true, false) != null, "选择预览与缩略项同时存在")
		var first_id: String = page.selected_material
		check(not session.case_state.data.materials[session.config.contents[first_id].material_id].read.get(first_id, false), "预览没有提前标记已读")
		var thumbnail: Control = page.find_child("Material_" + first_id, true, false)
		await click(thumbnail.get_global_transform() * (thumbnail.size / 2))
		await frames()
		check(page.reading_content.is_empty() and page.selected_material == first_id, "实际点缩略项只选中预览")
		await click(Vector2(20, 20))
		check(under_clicks == 0 and page.visible, "纸面外模态遮罩阻断后方输入")
		await capture("handbook-library-%dx%d.png" % [dimensions.x, dimensions.y])
		page._move_library_page(1)
		await frames()
		check(int(page.library_pages.all) == 1, "缩略项可翻到真实库存第二页")
		var saved: Dictionary = page.export_view()
		page.close_page()
		page.restore_view(saved)
		await frames()
		check(int(page.library_pages.all) == 1 and page.selected_material == first_id, "恢复保留选中身份和页码")
		var content: Dictionary = session.config.contents[first_id]
		var original: String = str(content.detail_text)
		content.detail_text = ("洛恩的死因判断需要结合实际记录。长原文在纸面内容区内自动换行，不能把按钮或正文推到屏幕之外。\n").repeat(30)
		page.open_content(first_id)
		await frames()
		check(inside(button("关闭阅读")) and inside(button("返回")), str(dimensions) + " 长原文固定退出可见")
		var reading: ScrollContainer = page.find_child("HandbookReadingScroll", true, false)
		check(reading != null and reading.get_h_scroll_bar().max_value <= reading.get_h_scroll_bar().page + 1, "原文没有横向滚动需求")
		await capture("handbook-detail-%dx%d.png" % [dimensions.x, dimensions.y])
		page.read_positions.erase(first_id)
		page.open_content(first_id, true)
		await frames()
		reading = page.find_child("HandbookReadingScroll", true, false)
		var hint: Label = page.find_child("OriginalReadingHint", true, false)
		check(inside(hint) and hint.text.contains("请用滚轮向下阅读"), str(dimensions) + " 长原件固定提示下滑及确认按钮位置")
		check(not reading.is_ancestor_of(hint) and button("已读完这份原件") != null, "阅读提示位于滚动区外且保留原件底部明确确认")
		check(button("已读完这份原件").get_global_rect().position.y > reading.get_global_rect().end.y, "长原件确认位于全文后且不会提前提交阅读")
		await capture("handbook-original-hint-%dx%d.png" % [dimensions.x, dimensions.y])
		reading.scroll_vertical = int(reading.get_v_scroll_bar().max_value)
		await frames()
		check(hint.text.contains("已到原件底部") and inside(hint), "读到末尾后提示改为明确确认阅读")
		check(reading.get_global_rect().encloses(button("已读完这份原件").get_global_rect()), "滚到末尾后原件确认按钮完整可见")
		reading.scroll_vertical = 0
		await frames()
		check(hint.text.contains("请用滚轮向下阅读"), "向上翻回正文后恢复下滑提示")
		content.detail_text = "短原件。"
		page.open_content(first_id, true)
		await frames()
		hint = page.find_child("OriginalReadingHint", true, false)
		check(inside(hint) and hint.text.contains("已到原件底部"), "短原件无需滚动时直接提示确认阅读")
		content.detail_text = original
		page.open_content(first_id)
		page._push_source({"entry": "ENTRY_CH01_ENTER", "sources": [{"content_id": first_id, "sources": []}]})
		await frames()
		check(inside(button("关闭来源与阅读")) and inside(button("上一级")), "来源逐层返回与关闭可见")
		page._back()
		await frames()
		check(page.reading_content == first_id and page.source_document.is_empty(), "来源返回原精确版本")
		page.tab = "people"
		page.open_library()
		await frames()
		check(inside(button("关闭手册")) and page.find_child("PeopleThumbnails", true, false) != null, str(dimensions) + " 人物重排并保持关闭可见")
		await capture("handbook-people-%dx%d.png" % [dimensions.x, dimensions.y])
		page.tab = "materials"
		page.library_pages.clear()
		# 下一次比例循环的“预览未读”使用新档，不受刚才确实打开原文的阅读影响。
		for record in session.case_state.data.materials.values(): record.read.clear()
	session.mode = "selection"
	session.slots = ["E01_V1", ""]
	var before: Dictionary = session.case_state.data.duplicate(true)
	page.set_compact_mode(true)
	page.open_content("E01_V1", false, true)
	await frames()
	check(not page.allow_selection and button("选择这份材料") == null and button("标为重点") == null, "核心手册没有选入与重点修改入口")
	await click(Vector2(20, 20))
	check(under_clicks == 0 and session.slots == ["E01_V1", ""], "紧凑旧接口也阻断背后选牌并保持草稿")
	check(session.case_state.data.materials.E01.current == before.materials.E01.current, "只读查看不修改当前材料版本")
	page.close_page()
	await click(Vector2(20, 20))
	check(under_clicks == 1, "关闭后下层正常恢复输入")
	page.open_library()
	await frames()
	check(page.handle_escape() and not page.visible, "Esc从手册顶层关闭并返回父状态")
	page.queue_free()
	blocker.queue_free()
	session.queue_free()
	await frames()
	print("FINAL_HANDBOOK_UI ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func frames() -> void:
	for i in range(5): await process_frame

func button(text: String, node: Node = page) -> Button:
	for child in node.get_children():
		if child is Button and child.text == text: return child
		var found := button(text, child)
		if found != null: return found
	return null

func inside(control: Control) -> bool:
	if control == null or not control.is_visible_in_tree(): return false
	var points := [control.get_global_transform() * Vector2.ZERO, control.get_global_transform() * control.size]
	return points[0].x >= -1 and points[0].y >= -1 and points[1].x <= root.size.x + 1 and points[1].y <= root.size.y + 1

func click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	Input.parse_input_event(motion)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame

func capture(filename: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/" + filename))
