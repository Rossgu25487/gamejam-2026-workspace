extends SceneTree
## 用正式库存验证浅扇分页、选槽、就地旧版选择与手册只读；判定规则另由核心关系回归覆盖。
const Session = preload("res://systems/aurora/aurora_session.gd")
const CardPage = preload("res://pages/aurora/aurora_card_page.gd")
const Handbook = preload("res://pages/aurora/aurora_handbook_page.gd")
var failures: Array[String] = []
var checks := 0
var session: Node
var page: Control

func _initialize() -> void: call_deferred("_run")
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label); push_error(label)

func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	session = Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "最终包载入")
	session.case_state.reset()
	for id in session.config.materials.keys().slice(0, 14):
		for content in session.config.contents:
			if session.config.contents[content].material_id == id:
				session.case_state.grant(str(content), {"entry": "ENTRY_CH01_ENTER"})
	session.mode = "selection"
	session.question = "L15_R04"
	session.current_statement = str(session.config.questions[session.question].target_text_ref)
	session.selected_target = true
	session.slots = ["", ""]
	page = CardPage.new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session)
	page.refresh()
	await frames(4)
	await capture("final-card-ui-1600.png")
	check(page.hand_capacity() == 10 and page.card_buttons.size() == 10, "常规画面十张浅扇手牌")
	check(page.hand_area.name == "ShallowFan", "默认选材使用浅扇而非网格")
	check(page.card_buttons[0].rotation_degrees < 0 and page.card_buttons[-1].rotation_degrees > 0, "两侧卡面向内呈浅扇")
	check(button(page, "出示") != null and visible_rect(button(page, "出示")), "出示控件在窗口内")
	check(button(page, "收起对局") != null and visible_rect(button(page, "收起对局")), "收起控件在窗口内")
	for card in page.card_buttons: check(visible_rect(card), "浅扇牌面完整位于窗口")
	var empty: Button = page.find_child("EmptySlot1", true, false)
	empty.pressed.emit()
	await frames(3)
	check(session.active_slot == 1 and page.detail_content.is_empty(), "空槽只选定第二槽且不打开阅读")
	var selected_id := str(page.card_buttons[0].content_id)
	page.card_buttons[0].pressed.emit()
	await frames(3)
	check(session.slots == ["", selected_id] and session.mode == "selection", "点牌只入选定槽且不判定")
	check(session.pending_result.is_empty(), "选牌不产生结果")
	page._open_detail(selected_id)
	await frames(3)
	await capture("final-card-detail-1600.png")
	check(page.detail_overlay != null and page.detail_overlay.visible, "详情在核查页本地打开")
	check(visible_rect(page.detail_overlay.find_child("CardDetailPanel", true, false)), "本地详情面板在当前窗口内")
	check(button(page.detail_overlay, "请先撤下该材料") != null and button(page.detail_overlay, "请先撤下该材料").disabled, "同身份旧版不能重复入槽")
	check(page.handle_back() and page.detail_content.is_empty() and session.slots == ["", selected_id], "关闭详情恢复草稿")
	session.clear_slot(1)
	session.case_state.grant("E04_V1", {})
	session.case_state.grant("E04_V2", {})
	var current_before := str(session.case_state.data.materials.E04.current)
	page._open_detail("E04_V1")
	await frames(3)
	check(button(page.detail_overlay, "选用此记录") != null, "本地详情可选真实持有的旧记录")
	button(page.detail_overlay, "选用此记录").pressed.emit()
	await frames(3)
	check(session.slots == ["E04_V1", ""] and session.case_state.data.materials.E04.current == current_before, "旧记录选入保留精确版本且不改库存当前版本")
	session.clear_slot(0)
	page._change_page(1)
	await frames(3)
	check(page.page == 1 and page.card_buttons.size() == 4, "超出十张可继续浏览而不截断库存")
	page._toggle_grid()
	await frames(3)
	check(page.library_capacity() == 6 and page.card_buttons.size() == 6, "展开检索首页为六张")
	page._change_page(1)
	await frames(3)
	check(page.card_buttons.size() == 6, "展开检索下一页为另外六张已获身份")
	page._search("不存在的材料")
	await frames(3)
	check(page.card_buttons.is_empty() and session.slots == ["", ""], "搜索只筛选已获名称和简述且不改草稿")
	page._search("")
	await frames(3)
	page._toggle_grid()
	await frames(3)
	root.size = Vector2i(1200, 900)
	root.content_scale_size = Vector2i(1200, 900)
	page.refresh()
	await frames(4)
	check(page.hand_capacity() == 7 and page.card_buttons.size() == 7, "四比三画面采用七张容量")
	for card in page.card_buttons: check(visible_rect(card), "四比三牌面完整位于窗口")
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	page.refresh()
	await frames(4)
	check(visible_rect(button(page, "出示")), "720高出示按钮可见")
	check(visible_rect(button(page, "展开材料 Q")), "720高展开按钮可见")
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	page.refresh()
	await frames(4)
	await click(page.card_buttons[0])
	check(not str(session.slots[0]).is_empty(), "真实鼠标点牌可以选用")
	await frames(3)
	var old_slots: Array = session.slots.duplicate()
	page._open_detail(selected_id)
	await frames(3)
	# 背后底栏的空白区域仍有可选牌；模态详情必须阻断这次真实鼠标点击。
	var last_card: Control = page.card_buttons[-1]
	await click(last_card)
	check(session.slots == old_slots, "详情盖层阻断后方手牌输入")
	page._close_detail()
	var handbook := Handbook.new()
	root.add_child(handbook)
	handbook.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	handbook.bind(session)
	handbook.open_content(selected_id, false, true)
	await frames(3)
	check(not handbook.allow_selection and button(handbook, "选用当前版本") == null, "手册忽略旧选材参数并保持只读")
	check(button(handbook, "标为重点") == null and button(handbook, "取消重点") == null, "核心手册不修改身份重点")
	var restored: Dictionary = handbook.export_view()
	restored.selectable = true
	handbook.restore_view(restored)
	check(not handbook.allow_selection, "旧存档不能恢复手册选材模式")
	handbook.queue_free()
	page.queue_free()
	session.queue_free()
	await frames(2)
	print("FINAL_CARD_UI ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func frames(count: int) -> void:
	for index in range(count): await process_frame

func click(control: Control) -> void:
	var position := control.get_global_transform() * (control.size * Vector2(0.5, 0.5))
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
	if "--capture-card-ui" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	var output := ProjectSettings.globalize_path("res://../.local/" + filename)
	root.get_texture().get_image().save_png(output)

func button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and child.text == text: return child
		var found := button(child, text)
		if found != null: return found
	return null

func visible_rect(control: Control) -> bool:
	if control == null or not control.is_visible_in_tree(): return false
	var box := control.get_global_rect()
	var parent := control.get_parent()
	while parent is Control:
		if parent.clip_contents and not parent.get_global_rect().grow(1).encloses(box): return false
		parent = parent.get_parent()
	return box.position.x >= -1 and box.position.y >= -1 and box.end.x <= root.size.x + 1 and box.end.y <= root.size.y + 1
