extends SceneTree
## 正式卡牌浏览契约：展开层与浅扇状态隔离，真实预览/朝向，长原话与有效区域回归。
var checks := 0
var failures: Array[String] = []
var session: Node
var page: Control
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FINAL_CARD_BROWSER_FAIL: " + message)
func frames(count := 5) -> void:
	for i in range(count): await process_frame
func button(text: String) -> Button:
	for item in page.find_children("*", "Button", true, false):
		if item.text == text: return item
	return null
func capture(name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture"): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://../.local/" + name + ".png")
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = root.size
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式包载入")
	session.case_state.reset()
	for id in session.config.materials.keys().slice(0, 17):
		for content in session.config.contents:
			if session.config.contents[content].material_id == id: session.case_state.grant(str(content), {})
	session.mode = "selection"
	session.question = "L15_R04"
	session.current_statement = str(session.config.questions[session.question].target_text_ref)
	session.selected_target = true
	session.slots = ["", ""]
	session.return_context = {"kind": "topics", "object": "CHR02", "scene": "SC06"}
	page = preload("res://pages/aurora/aurora_card_page.gd").new()
	page.set_preferences({"brightness": 125})
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session)
	page.refresh()
	await frames()
	check(page.core_stage.fixed_actor == "CHR02" and not page.core_stage.portrait_path.is_empty(), "实际会话对象洛恩固定且有合适真实立绘")
	check(page.core_stage.stage.modulate == Color(1.25,1.25,1.25,1) and page.modulate == Color.WHITE and page.page_canvas.modulate == Color.WHITE, "舞台首建应用亮度而卡面和文字保持原色")
	page.set_preferences({"brightness": 75})
	page.refresh()
	await frames()
	check(page.core_stage.stage.modulate == Color(0.75,0.75,0.75,1) and page.card_buttons[0].modulate.a == 1, "设置亮度即时作用图片并在重绘后保留")
	page.set_preferences({"brightness": 100})
	check(button("办案手册").icon != null and button("对白记录").icon != null, "右下按钮读取真实核心资源表图标")
	var original_stage: Control = page.core_stage
	session.return_context.object = "CHR05"
	page.refresh()
	await frames()
	check(page.core_stage == original_stage and page.core_stage.fixed_actor == "CHR02", "同题页面重建及插话不改变固定对象")
	page._change_page(1)
	await frames()
	var original_hand: int = page.page
	page.toggle_library()
	await frames()
	check(page.grid_mode and page.library_capacity() == 6 and page.card_buttons.size() == 6, "常规展开每页六张")
	var library: Control = page.page_canvas.find_child("MaterialLibrary", true, false)
	check(root.gui_get_focus_owner() != null and library.is_ancestor_of(root.gui_get_focus_owner()), "初次展开焦点停留在模态内")
	var all_inside := true
	for focusable in library.find_children("*", "Control", true, false):
		if focusable.focus_mode == Control.FOCUS_NONE or not focusable.is_visible_in_tree() or (focusable is BaseButton and focusable.disabled): continue
		all_inside = all_inside and library.is_ancestor_of(focusable.get_node(focusable.focus_next)) and library.is_ancestor_of(focusable.get_node(focusable.focus_previous))
	check(all_inside, "展开层键盘遍历不进入后方原话或菜单")
	page._change_page(1)
	page.sort_name = true
	page.order_descending = true
	page.category = "evidence"
	page._remember()
	page.refresh()
	await frames()
	var saved_library: int = page.page
	page.handle_back()
	await frames()
	check(not page.grid_mode and page.page == original_hand, "关闭展开恢复原手牌页")
	var hand_order: Array = page._material_items(false).map(func(item): return str(item.id))
	check(hand_order == session.case_state.data.materials.keys(), "展开名称排序和过滤不污染浅扇取得顺序")
	page.toggle_library()
	await frames()
	check(page.page == saved_library and page.sort_name and page.order_descending and page.category == "evidence", "重开展开保留页码分类排序")
	var chosen: String = page.card_buttons[0].get_meta("content_id")
	page.focus_content = ""
	page.library_focus = chosen
	page.refresh()
	await frames()
	var library_owner := root.gui_get_focus_owner()
	check(library_owner != null and library_owner.get_meta("content_id", "") == chosen, "没有浅扇焦点时仍恢复独立展开焦点")
	page._open_detail(chosen)
	await frames()
	check(root.gui_get_focus_owner() != null and page.detail_overlay.is_ancestor_of(root.gui_get_focus_owner()), "展开详情取得键盘焦点")
	page.refresh()
	await frames()
	check(root.gui_get_focus_owner() != null and page.detail_overlay.is_ancestor_of(root.gui_get_focus_owner()), "详情重绘不把焦点送回后方材料")
	check(page.handle_back(), "Backspace先关闭就地详情")
	await frames()
	check(page.grid_mode and page.page == saved_library and page.sort_name, "详情返回同一展开条件")
	check(root.gui_get_focus_owner() != null and root.gui_get_focus_owner().get_meta("content_id", "") == chosen, "关闭详情恢复原材料焦点")
	check(page._select_card(chosen), "展开选用合法材料")
	await frames()
	var identity := str(session.config.contents[chosen].material_id)
	check(not page.grid_mode and page.page == floori(float(hand_order.find(identity)) / page.hand_capacity()), "展开选用回浅扇同身份页")
	check(page.card_buttons.any(func(card): return card.content_id == chosen), "浅扇实际显示选用身份")
	check(not page.handle_escape(), "Esc交给外层暂停，不退出核心或详情")
	var actions: Array = []
	page.action_requested.connect(func(action, content): actions.append([action, content]))
	var live: Button = page.card_buttons[0]
	page._lift_card(live, true)
	page._lift_card(live, true)
	check(actions.filter(func(item): return item[0] == "hand_focus_changed").size() <= 1, "同身份重复悬停不重播焦点音")
	var focus_sounds := actions.filter(func(item): return item[0] == "hand_focus_changed").size()
	page.refresh()
	await frames()
	check(actions.filter(func(item): return item[0] == "hand_focus_changed").size() == focus_sounds, "重绘恢复材料焦点不重播动作音")
	session.clear_slot(0)
	session.clear_slot(1)
	await frames()
	var sound_id := str(page.card_buttons[0].content_id)
	check(page._select_card(sound_id), "测试实际点选成功")
	check(actions.filter(func(item): return item[0] == "hand_selection_accepted").size() == 1, "成功点选只发一次动作音")
	await frames()
	var remove: Button = page.find_child("WithdrawSlot0", true, false)
	check(remove != null and remove.icon != null and remove.text.is_empty() and remove.custom_minimum_size == Vector2(64,48) and remove.tooltip_text == "撤下", "撤下为已交图标按钮并保留动作说明")
	page._select_card(sound_id)
	check(actions.filter(func(item): return item[0] == "hand_selection_accepted").size() == 1, "拒绝重复选材不播动作音")
	page._withdraw(0)
	page._withdraw(0)
	check(actions.filter(func(item): return item[0] == "withdraw_material").size() == 1, "真实撤下只发一次动作音，空槽不播")
	await frames()
	for extent in [Vector2i(1600,900), Vector2i(1200,900), Vector2i(960,540)]:
		root.size = extent
		root.content_scale_size = extent
		page.page = 0
		page.refresh()
		await frames()
		var current: Button = page.card_buttons[0]
		page._lift_card(current, true)
		await frames()
		check(is_equal_approx(current.scale.x, 1.05) and is_equal_approx(current.position.y, current.get_meta("fan_base").y - 10), "悬停上抬10并放大1.05")
		check(page.hover_preview != null and page.hover_preview.size == Vector2(220,330), "独立完整预览为220×330")
		var preview: Rect2 = page.hover_preview.get_global_rect()
		var target: Rect2 = page.find_child("TargetStatement", true, false).get_global_rect()
		var present: Rect2 = page.find_child("PresentMaterials", true, false).get_global_rect()
		check(not preview.intersects(target) and not preview.intersects(present), "预览避开原话及出示操作")
		check(Rect2(Vector2.ZERO, extent).encloses(preview), "预览位于有效区域")
		var actual_head := Vector2(extent.x * 0.2, extent.y * 250.0 / 900.0)
		check(not preview.has_point(actual_head), "预览不遮人物头部")
		check(page.find_child("PresentMaterials", true, false).is_visible_in_tree() and present.end.y < page.hand_area.get_global_rect().position.y, "实际出示按钮位于手牌上方且不被遮挡")
		check(button("办案手册").get_global_rect().position.y > extent.y * 0.9, "手册记录固定右下")
		var target_ref := str(session.current_statement)
		var original: String = session.config.texts[target_ref].text
		session.config.texts[target_ref].text = original.repeat(12)
		page.refresh()
		await frames()
		check(page.find_child("PresentMaterials", true, false).get_global_rect().end.y < page.hand_area.get_global_rect().position.y, "最长原话在原区滚动且不挤走出示")
		session.config.texts[target_ref].text = original
		page.refresh()
		await frames()
		await capture("final-card-browser-%d" % extent.x)
		page.toggle_library()
		await frames()
		check(page.card_buttons.size() == (4 if extent.x == 1200 else 6), "展开容量按真实比例为四或六")
		await capture("final-card-library-%d" % extent.x)
		page.handle_back()
		await frames()
	session.question = "L01_R01"
	session.return_context = {"kind":"reasoning"}
	page.refresh()
	await frames()
	check(page.core_stage.fixed_actor.is_empty() and page.core_stage.stage.occupants.is_empty(), "无会话推理不从材料或原话署名猜立绘")
	session.question = "L02_R01"
	session.return_context = {"kind":"topics", "object":"CHR04"}
	page.refresh()
	await frames()
	check(page.core_stage.fixed_actor == "CHR04" and page.core_stage.portrait_missing and page.core_stage.stage.occupants.is_empty(), "缺合适朝向不镜像或加载朝外人物")
	print("FINAL_CARD_BROWSER: %d checks, %d failures" % [checks, failures.size()])
	page.free()
	session.free()
	quit(0 if failures.is_empty() else 1)
