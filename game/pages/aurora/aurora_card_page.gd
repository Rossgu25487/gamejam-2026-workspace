extends Control
## 核查页只处理选材显示、草稿浏览和玩家操作。判定、来源冻结与结果时点由会话负责。
const UI = preload("res://pages/core/page_controls.gd")
const MaterialCard = preload("res://pages/aurora/aurora_material_card.gd")
const CoreStage = preload("res://pages/aurora/aurora_core_stage.gd")
signal menu_requested
signal material_requested(content_id: String)
signal handbook_requested
signal log_requested
signal action_requested(action: String, content_id: String)
var session: Node
var queued := false
var grid_mode := false
var page := 0
var category := "all"
var starred_only := false
var order_descending := false
var body: VBoxContainer
var card_scroll: ScrollContainer
var card_buttons: Array[Button] = []
var proof_time := 0.0
var current_question := ""
var scroll_positions := {}
var detail_overlay: Control
var detail_content := ""
var detail_scroll := 0
var hand_area: Control
var search_text := ""
var sort_name := false
var hand_page := 0
var library_page := 0
var slot_effect := {}
var reduced_motion := false
var core_stage: Control
var page_canvas: Control
var work_size := Vector2(1600, 900)
var hover_preview: Control
var hover_content := ""
var focus_content := ""
var library_focus := ""
var last_sound_identity := ""
var restoring_focus := false
var adopted_assets := {}
var preferences := {}

func library_capacity() -> int:
	return 4 if size.x / maxf(size.y, 1.0) <= 1.4 else 6

func hand_capacity() -> int:
	# 库存不截断；窄画面每页七张，常规画面每页十张，超出后继续翻页。
	return 7 if size.x / maxf(size.y, 1.0) <= 1.4 else 10

func bind(value: Node) -> void:
	session = value
	var adopted = JSON.parse_string(FileAccess.get_file_as_string(str(session.config.definition.root).path_join("design/ui_20261018/adopted_assets.json")))
	if adopted is Dictionary:
		for asset in adopted.get("assets", []):
			adopted_assets[str(asset.asset_id)] = session.config.resource_path(str(asset.get("runtime_path", "")))
	session.changed.connect(refresh)
	session.result_presentation_requested.connect(func(result): proof_time = float(result.get("duration_ms", 0)) / 1000)
	resized.connect(refresh)

func refresh() -> void:
	if not is_inside_tree() or queued: return
	queued = true
	call_deferred("_render")

func _render() -> void:
	queued = false
	if session == null or session.question.is_empty(): return
	if current_question != session.question:
		current_question = session.question
		var browse: Dictionary = session.browsing()
		grid_mode = bool(browse.get("grid", false))
		page = int(browse.get("page", 0))
		category = str(browse.get("category", "all"))
		starred_only = bool(browse.get("starred", false))
		order_descending = bool(browse.get("descending", false))
		search_text = str(browse.get("search", ""))
		sort_name = bool(browse.get("sort_name", false))
		hand_page = int(browse.get("hand_page", 0))
		library_page = int(browse.get("library_page", 0))
		focus_content = str(browse.get("focus_content", ""))
		library_focus = str(browse.get("library_focus", ""))
		scroll_positions = browse.get("positions", {}).duplicate(true)
	# 每次重绘先作废选材控件引用。结果/失败页不会再调用_selection，
	# 不能等下一次选材才清数组，否则延后焦点回调会访问已释放的手牌。
	card_buttons.clear()
	hand_area = null
	card_scroll = null
	for child in get_children():
		if child == core_stage: continue
		remove_child(child)
		child.queue_free()
	if not is_instance_valid(core_stage):
		core_stage = CoreStage.new()
		core_stage.z_index = -10 # 人物自身有相对层级，整体舞台仍必须位于纸面和模态层后方。
		core_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(core_stage)
		core_stage.bind(session)
		core_stage.set_preferences(preferences)
	core_stage.refresh()
	detail_overlay = null
	hover_preview = null
	theme = _paper_button_theme()
	var factor := maxf(0.1, size.y / 900.0)
	work_size = size / factor
	page_canvas = Control.new()
	page_canvas.name = "CoreCanvas"
	page_canvas.size = work_size
	page_canvas.scale = Vector2.ONE * factor
	page_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(page_canvas)
	var shade := ColorRect.new()
	shade.color = Color(0.035, 0.055, 0.07, 0.32)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page_canvas.add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 24 if edge != "bottom" else 80)
	page_canvas.add_child(margin)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	var top := HBoxContainer.new()
	top.custom_minimum_size.y = 44
	top.add_theme_constant_override("separation", 10)
	body.add_child(top)
	var heading := UI.label(top, str(session.config.scenes.get(session.case_state.data.scene, {}).get("name", "")), 24)
	# 顶部只放地点与所属页菜单，手册和记录使用右下独立入口。
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_action_icon(UI.button(top, "菜单", menu_requested.emit), "menu")
	if not core_stage.fixed_actor.is_empty():
		var actor_name := str(session.config.actors[core_stage.fixed_actor].get("name", ""))
		var identity := UI.label(page_canvas, actor_name, 24)
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		identity.position = Vector2(28, work_size.y - 54)
		identity.size = Vector2(220, 40)
		identity.autowrap_mode = TextServer.AUTOWRAP_OFF
	if session.mode == "selection": _selection()
	elif session.mode == "failure":
		UI.label(body, "本次复核次数已用完", 32)
		UI.button(body, "重试", session.retry_question)
		UI.button(body, "返回原入口", session.collapse_question)
	else: _result()
	var utilities := HBoxContainer.new()
	utilities.name = "CoreUtilities"
	utilities.position = Vector2(work_size.x - 384, work_size.y - 80)
	utilities.size = Vector2(352, 48)
	utilities.add_theme_constant_override("separation", 12)
	page_canvas.add_child(utilities)
	utilities.visible = not grid_mode
	var manual := UI.button(utilities, "办案手册", handbook_requested.emit)
	manual.custom_minimum_size = Vector2(170, 48)
	manual.tooltip_text = "I 打开办案手册"
	_apply_action_icon(manual, "open_record")
	var log_button := UI.button(utilities, "对白记录", log_requested.emit)
	log_button.custom_minimum_size = Vector2(170, 48)
	log_button.tooltip_text = "L 打开对白记录"
	_apply_action_icon(log_button, "dialogue_log")
	if not detail_content.is_empty(): _render_detail()
	elif session.mode == "selection" and not (library_focus if grid_mode else focus_content).is_empty(): call_deferred("_restore_card_focus")
	if session.mode == "selection" and grid_mode and detail_content.is_empty(): call_deferred("_restore_library_focus")

func _selection() -> void:
	# 核查页分成上下两个明确区域：上方是当前问题和操作，下方固定保留牌区。
	# 不能让 VBoxContainer 按问题文字的长度把底部卡牌继续向下挤出窗口。
	var layout := Control.new()
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.custom_minimum_size.y = 0
	body.add_child(layout)
	var upper := VBoxContainer.new()
	upper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	upper.offset_left = minf(430, work_size.x * 0.30)
	upper.offset_bottom = -312
	upper.add_theme_constant_override("separation", 8)
	upper.clip_contents = true
	layout.add_child(upper)
	var question_head := HBoxContainer.new()
	upper.add_child(question_head)
	var question_title := UI.label(question_head, "核查 · 当前原话", 24)
	question_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var chances := UI.label(question_head, "复核机会：%d / 3" % int(session.case_state.data.chances.get(session.question, 3)), 22)
	chances.autowrap_mode = TextServer.AUTOWRAP_OFF
	chances.size_flags_horizontal = Control.SIZE_SHRINK_END
	var target_scroll := ScrollContainer.new()
	target_scroll.custom_minimum_size.y = 96
	target_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	upper.add_child(target_scroll)
	var target := UI.button(target_scroll, ("已选定：" if session.selected_target else "点击选定听过的原话：") + session.target_text(), session.select_target)
	target.set_meta("tutorial_target", str(session.current_statement))
	target.name = "TargetStatement"
	target.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	target.custom_minimum_size.y = 48
	target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.add_theme_font_size_override("font_size", 28)
	var statement_options: Array = session.statement_options()
	if not statement_options.is_empty():
		# 原句较长时放在独立滚动行，避免挤掉中央引用槽和下方操作。
		var statement_scroll := ScrollContainer.new()
		statement_scroll.custom_minimum_size.y = 46
		statement_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		upper.add_child(statement_scroll)
		var statement_bar := HBoxContainer.new()
		statement_bar.add_theme_constant_override("separation", 6)
		statement_scroll.add_child(statement_bar)
		for option in statement_options:
			var label := ("✓ " if option.selected else "") + "原话%d" % (statement_options.find(option) + 1)
			var statement_button := UI.button(statement_bar, label, session.select_statement.bind(str(option.id)) if option.heard else session.read_statement.bind(str(option.id)))
			statement_button.set_meta("tutorial_target", str(option.id))
			statement_button.custom_minimum_size = Vector2(136, 46)
			statement_button.add_theme_font_size_override("font_size", 24)
			statement_button.tooltip_text = str(option.text)
			statement_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var slots_box := HBoxContainer.new()
	upper.add_child(slots_box)
	slots_box.custom_minimum_size.y = 154
	slots_box.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_box.add_theme_constant_override("separation", 24)
	for index in range(2):
		var id := str(session.slots[index])
		var slot := HBoxContainer.new()
		slots_box.add_child(slot)
		if id.is_empty():
			var empty_slot := UI.button(slot, ("✓ " if session.active_slot == index else "") + "夹位%d" % (index + 1), session.select_slot.bind(index))
			empty_slot.name = "EmptySlot%d" % index
			empty_slot.custom_minimum_size = Vector2(slots_box.custom_minimum_size.y * 2.0 / 3.0, slots_box.custom_minimum_size.y)
			empty_slot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			empty_slot.tooltip_text = "选择第%d个引用夹位" % (index + 1)
		else:
			var face := MaterialCard.new()
			face.custom_minimum_size = Vector2(slots_box.custom_minimum_size.y * 2.0 / 3.0, slots_box.custom_minimum_size.y)
			slot.add_child(face)
			face.configure(session, id, true)
			face.name = "SelectedSlot%d" % index
			face.pressed.connect(_open_detail.bind(id))
			var remove := UI.button(slot, "", _withdraw.bind(index))
			remove.name = "WithdrawSlot%d" % index
			remove.custom_minimum_size = Vector2(64, 48)
			remove.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			remove.tooltip_text = "撤下"
			_apply_action_icon(remove, "remove")
	var action_scroll := ScrollContainer.new()
	action_scroll.name = "CoreActionScroll"
	action_scroll.custom_minimum_size.y = 56
	action_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	upper.add_child(action_scroll)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	action_scroll.add_child(actions)
	var can_present: bool = session.selected_target and not session.slots.all(func(id): return str(id).is_empty()) and session.question_binding().get("requires_actual_presentation", true)
	UI.button(actions, "出示", _present, can_present).name = "PresentMaterials"
	if not session.question_binding().get("press_entry_refs", []).is_empty(): UI.button(actions, "追问", session.press_statement).name = "PressStatement"
	if not session.question_binding().get("hint_text_refs", []).is_empty(): UI.button(actions, "思考提示", session.read_question_hint)
	if session.can_continue_question(): UI.button(actions, "继续询问", session.continue_question)
	UI.button(actions, "收起对局", session.collapse_question)
	var all := _material_items(grid_mode)
	# 牌区固定贴在页面底部；无论上方问题文本多长，牌面都留在可视窗口内。
	var card_area := PanelContainer.new()
	card_area.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	card_area.offset_top = -304
	card_area.offset_left = 252
	card_area.add_theme_stylebox_override("panel", _card_area_style())
	layout.add_child(card_area)
	var card_box := VBoxContainer.new()
	card_box.add_theme_constant_override("separation", 4)
	card_area.add_child(card_box)
	card_buttons.clear()
	var capacity := library_capacity() if grid_mode else hand_capacity()
	page = clampi(page, 0, maxi(0, ceili(all.size() / float(capacity)) - 1))
	if grid_mode:
		card_area.hide()
	else:
		hand_area = Control.new()
		hand_area.name = "ShallowFan"
		hand_area.custom_minimum_size.y = 240
		hand_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hand_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
		card_box.add_child(hand_area)
		var shown := all.slice(page * capacity, page * capacity + capacity)
		for item in shown:
			var id := str(item.record.current)
			var face := MaterialCard.new()
			hand_area.add_child(face)
			face.configure(session, id)
			face.pressed.connect(_select_card.bind(id))
			face.gui_input.connect(_card_secondary_input.bind(id))
			card_buttons.append(face)
		call_deferred("_layout_fan")
	if all.is_empty(): UI.label(card_box, "没有符合条件的已取得材料", 22)
	if not grid_mode:
		var pages := HBoxContainer.new()
		pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pages.custom_minimum_size.y = 36
		card_box.add_child(pages)
		UI.button(pages, "上一页", _change_page.bind(-1), page > 0)
		var pagination := UI.label(pages, "%d / %d · 点击选用，右键查看详情" % [page + 1, maxi(1, ceili(all.size() / float(capacity)))], 16)
		pagination.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pagination.autowrap_mode = TextServer.AUTOWRAP_OFF
		UI.button(pages, "下一页", _change_page.bind(1), (page + 1) * capacity < all.size())
		UI.button(pages, "展开材料 Q", _toggle_grid).name = "ExpandMaterials"
	if grid_mode: _render_library_overlay(all)
	if not slot_effect.is_empty(): call_deferred("_animate_slot")

func _render_library(parent: Control, items: Array) -> void:
	card_scroll = ScrollContainer.new()
	card_scroll.custom_minimum_size.y = 540
	card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(card_scroll)
	card_scroll.set_deferred("scroll_vertical", int(scroll_positions.get(category, 0)))
	card_scroll.get_v_scroll_bar().value_changed.connect(func(value): scroll_positions[category] = value; _remember())
	var grid := GridContainer.new()
	grid.columns = 2 if library_capacity() == 4 else 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	card_scroll.add_child(grid)
	var capacity := library_capacity()
	for item in items.slice(page * capacity, page * capacity + capacity):
		var id := str(item.record.current)
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(160, 266)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(box)
		var title := MaterialCard.new()
		title.custom_minimum_size = Vector2(140, 210)
		title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(title)
		title.configure(session, id, true)
		title.pressed.connect(_open_detail.bind(id))
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_child(row)
		UI.button(row, "★" if item.record.star else "☆", _toggle_star.bind(str(item.id))).tooltip_text = "切换重点"
		var select := UI.button(row, "已选用" if id in session.slots else "选用", _select_card.bind(id), id not in session.slots)
		select.set_meta("content_id", id)
		select.focus_entered.connect(func(): library_focus = id)
		card_buttons.append(select)
	var pages := HBoxContainer.new()
	parent.add_child(pages)
	UI.button(pages, "上一页", _change_page.bind(-1), page > 0)
	var pagination := UI.label(pages, "%d / %d" % [page + 1, maxi(1, ceili(items.size() / float(capacity)))], 18)
	pagination.autowrap_mode = TextServer.AUTOWRAP_OFF
	pagination.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pagination.add_theme_color_override("font_color", Color("34413f"))
	UI.button(pages, "下一页", _change_page.bind(1), (page + 1) * capacity < items.size())
	UI.button(pages, "返回手牌", _toggle_grid)

func _material_items(library: bool) -> Array:
	var items: Array = []
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		var content: Dictionary = session.config.contents[str(record.current)]
		if library:
			if category != "all" and str(session.config.materials[id].type) != category: continue
			if starred_only and not record.star: continue
			var needle := search_text.strip_edges()
			if not needle.is_empty() and not (str(content.name).contains(needle) or str(content.description).contains(needle)): continue
		items.append({"id": id, "record": record})
	items.sort_custom(func(a, b):
		if library and sort_name:
			var left := str(session.config.contents[str(a.record.current)].name)
			var right := str(session.config.contents[str(b.record.current)].name)
			if left != right: return left.naturalnocasecmp_to(right) < 0
		return a.record.order > b.record.order if library and order_descending and not sort_name else a.record.order < b.record.order)
	return items

func _render_library_overlay(items: Array) -> void:
	var cover := ColorRect.new()
	cover.name = "MaterialLibrary"
	cover.color = Color(0.02, 0.035, 0.04, 0.88)
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page_canvas.add_child(cover)
	var panel := PanelContainer.new()
	panel.position = Vector2(maxf(24, (work_size.x - 1180) / 2), 24)
	panel.size = Vector2(minf(1180, work_size.x - 48), 852)
	panel.add_theme_stylebox_override("panel", _paper_panel_style())
	cover.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	var title := UI.label(heading, "展开材料", 28)
	title.add_theme_color_override("font_color", Color("34413f"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.button(heading, "关闭", _toggle_grid)
	var filters := HBoxContainer.new()
	column.add_child(filters)
	for pair in [["all", "全部"], ["evidence", "证据"], ["testimony", "证言"], ["inference", "推论"]]: UI.button(filters, pair[1], _set_category.bind(pair[0]))
	UI.button(filters, "仅重点 ✓" if starred_only else "仅重点", func(): starred_only = not starred_only; page = 0; _remember(); refresh())
	UI.button(filters, "最近取得" if order_descending else "取得顺序", func(): order_descending = not order_descending; sort_name = false; page = 0; _remember(); refresh())
	UI.button(filters, "名称排序 ✓" if sort_name else "名称排序", func(): sort_name = not sort_name; page = 0; _remember(); refresh())
	var search_row := HBoxContainer.new()
	column.add_child(search_row)
	var search := LineEdit.new()
	search.name = "MaterialSearch"
	search.placeholder_text = "搜索已获材料名称或简述"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.custom_minimum_size.y = 40
	search.text = search_text
	search_row.add_child(search)
	search.text_submitted.connect(_search)
	UI.button(search_row, "检索", func(): _search(search.text))
	UI.button(search_row, "清空搜索", _search.bind(""), not search_text.is_empty())
	_render_library(column, items)
	if items.is_empty(): UI.label(column, "没有符合条件的已取得材料", 24)

func _toggle_star(id: String) -> void:
	var record: Dictionary = session.case_state.data.materials[id]
	record.star = not record.star
	refresh()

func _layout_fan() -> void:
	if not is_instance_valid(hand_area) or not hand_area.is_inside_tree(): return
	var count := card_buttons.size()
	if count == 0: return
	var card_height := 204.0 if hand_capacity() == 7 else 219.0
	var card_width := card_height * 2.0 / 3.0
	var available := maxf(1.0, hand_area.size.x - card_width - 40)
	var spacing := minf(card_width + 18.0 if count <= 5 else card_width * 0.82, available / maxf(count - 1, 1))
	var start_x := (hand_area.size.x - card_width - spacing * (count - 1)) * 0.5
	for index in range(count):
		var card := card_buttons[index]
		card.size = Vector2(card_width, card_height)
		card.pivot_offset = Vector2(card_width * 0.5, card_height)
		var normalized := 0.0 if count == 1 else (float(index) / float(count - 1) * 2.0 - 1.0)
		var base := Vector2(start_x + spacing * index, 10 + absf(normalized) * 6)
		card.position = base
		card.rotation_degrees = normalized * (4.0 if count <= 5 else 2.5)
		card.z_index = 0
		card.set_meta("fan_base", base)
		card.set_meta("fan_index", index)
		card.mouse_entered.connect(_lift_card.bind(card, true))
		card.mouse_exited.connect(_lift_card.bind(card, false))
		card.focus_entered.connect(_lift_card.bind(card, true))
		card.focus_exited.connect(_lift_card.bind(card, false))
		card.focus_neighbor_left = card_buttons[(index - 1 + count) % count].get_path()
		card.focus_neighbor_right = card_buttons[(index + 1) % count].get_path()
		var detail := Button.new()
		detail.text = "详情"
		detail.position = Vector2(8, card_height - 34)
		detail.size = Vector2(card_width - 16, 28)
		detail.add_theme_font_size_override("font_size", 14)
		detail.pressed.connect(_open_detail.bind(card.content_id))
		card.add_child(detail)

func _lift_card(card: Button, raised: bool) -> void:
	if not is_instance_valid(card) or not card.is_inside_tree() or not is_instance_valid(hand_area) or not hand_area.is_inside_tree() or card.get_parent() != hand_area: return
	card.position = card.get_meta("fan_base") - (Vector2(0, 10) if raised else Vector2.ZERO)
	card.scale = Vector2.ONE * (1.05 if raised else 1.0)
	if raised:
		focus_content = str(card.content_id)
		var identity := str(session.config.contents[focus_content].material_id)
		if not restoring_focus and last_sound_identity != identity:
			last_sound_identity = identity
			action_requested.emit("hand_focus_changed", focus_content)
		_show_preview(str(card.content_id))
	elif hover_content == str(card.content_id):
		if card.has_focus() or card.is_hovered(): return
		if is_instance_valid(hover_preview): hover_preview.hide()
		hover_content = ""
	# 只调整扇牌内部子序；不使用跨页面z_index，避免手牌穿透办案手册。
	call_deferred("_reorder_fan", card, raised)

func _show_preview(id: String) -> void:
	if grid_mode or not detail_content.is_empty(): return
	if is_instance_valid(hover_preview):
		hover_preview.queue_free()
	hover_content = id
	hover_preview = MaterialCard.new()
	hover_preview.name = "FullCardPreview"
	page_canvas.add_child(hover_preview)
	hover_preview.configure(session, id, false)
	hover_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_preview.focus_mode = Control.FOCUS_NONE
	hover_preview.position = Vector2(36 + maxf(0, (work_size.x - 1600) / 2), 450)
	hover_preview.size = Vector2(220, 330)

func _restore_card_focus() -> void:
	# 本地详情独占焦点；重绘不能把键盘送回仍在后方的浅扇或展开层。
	if session.mode != "selection" or not is_visible_in_tree() or not detail_content.is_empty(): return
	for card in card_buttons:
		if not is_instance_valid(card) or card.is_queued_for_deletion() or not card.is_inside_tree(): continue
		var identity := str(card.get("content_id")) if not grid_mode else str(card.get_meta("content_id", ""))
		if identity == (library_focus if grid_mode else focus_content) and card.is_visible_in_tree() and not card.disabled:
			restoring_focus = true
			card.grab_focus()
			restoring_focus = false
			return

func _reorder_fan(card: Button, raised: bool) -> void:
	if not is_instance_valid(card) or not is_instance_valid(hand_area) or not hand_area.is_inside_tree() or card.get_parent() != hand_area: return
	if raised: hand_area.move_child(card, -1)
	else:
		for ordered in card_buttons:
			if is_instance_valid(ordered) and ordered.get_parent() == hand_area: hand_area.move_child(ordered, -1)

func _card_secondary_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_open_detail(id)
		get_viewport().set_input_as_handled()

func _open_detail(id: String) -> void:
	if not session.case_state.owns(id): return
	if detail_content.is_empty():
		# 旧版切换仍返回打开详情时的材料身份，不把旧版伪造成展开层库存条目。
		var current := str(session.case_state.data.materials[session.config.contents[id].material_id].current)
		if grid_mode: library_focus = current
		else: focus_content = current
	if is_instance_valid(hover_preview): hover_preview.hide()
	detail_content = id
	detail_scroll = 0
	_render_detail()

func _render_detail() -> void:
	if is_instance_valid(detail_overlay):
		remove_child(detail_overlay)
		detail_overlay.queue_free()
	if detail_content.is_empty() or not session.case_state.owns(detail_content): return
	var row: Dictionary = session.config.contents[detail_content]
	var record: Dictionary = session.case_state.data.materials[row.material_id]
	record.read[detail_content] = true
	detail_overlay = Control.new()
	detail_overlay.name = "LocalCardDetail"
	# 手牌有悬停前移层级，详情必须覆盖全部手牌及其命中区域。
	detail_overlay.z_index = 100
	detail_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	detail_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(detail_overlay)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.035, 0.82)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	detail_overlay.add_child(shade)
	var panel := PanelContainer.new()
	panel.name = "CardDetailPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var horizontal_margin := maxf(24, size.x * 0.10)
	panel.offset_left = horizontal_margin
	panel.offset_right = -horizontal_margin
	panel.offset_top = 36
	panel.offset_bottom = -36
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color("e8e3d4")
	paper.border_color = Color("a49f87")
	paper.set_border_width_all(2)
	paper.set_corner_radius_all(5)
	panel.add_theme_stylebox_override("panel", paper)
	panel.add_theme_color_override("font_color", Color("34413f"))
	detail_overlay.add_child(panel)
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 20)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	var title := UI.label(box, str(row.name), 26)
	title.add_theme_color_override("font_color", Color("34413f"))
	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 20)
	box.add_child(split)
	var face := MaterialCard.new()
	face.custom_minimum_size = Vector2(clampf(size.x * 0.14, 130, 210), 0)
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	split.add_child(face)
	face.custom_minimum_size.y = face.custom_minimum_size.x * 1.5
	face.configure(session, detail_content, false)
	var reading := VBoxContainer.new()
	reading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(reading)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	reading.add_child(scroll)
	var prose_box := VBoxContainer.new()
	prose_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(prose_box)
	var prose := RichTextLabel.new()
	prose.text = str(row.detail_text)
	prose.fit_content = true
	prose.scroll_active = false
	prose.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prose.add_theme_font_size_override("normal_font_size", 21)
	prose.add_theme_color_override("default_color", Color("34413f"))
	prose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prose_box.add_child(prose)
	for source in record.versions.get(detail_content, []):
		var source_text := str(source.get("text", ""))
		var source_label: Label
		if session.config.texts.has(source_text): source_label = UI.label(prose_box, "取得记录：" + session.config.text(source_text), 18)
		elif source.has("entry"): source_label = UI.label(prose_box, "取得记录：" + session.entry_label(str(source.entry)), 18)
		if source_label != null: source_label.add_theme_color_override("font_color", Color("34413f"))
	scroll.set_deferred("scroll_vertical", detail_scroll)
	scroll.get_v_scroll_bar().value_changed.connect(func(value): detail_scroll = int(value))
	var versions := HFlowContainer.new()
	reading.add_child(versions)
	var owned_versions: Array = record.versions.keys()
	owned_versions.sort_custom(func(a, b): return int(session.config.contents[a].version) > int(session.config.contents[b].version))
	for version in owned_versions:
		var label := ("当前 · " if version == record.current else "旧记录 · ") + str(session.config.contents[version].name)
		var button := UI.button(versions, label, _open_detail.bind(str(version)), str(version) != detail_content)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size.x = 160
	var actions := HBoxContainer.new()
	box.add_child(actions)
	var same_material: bool = session.slots.any(func(id): return not str(id).is_empty() and session.config.contents[id].material_id == row.material_id)
	if session.mode == "selection": UI.button(actions, "请先撤下该材料" if same_material else "选用此记录", _select_detail, not same_material)
	UI.button(actions, "取消重点" if record.star else "标为重点", func(): record.star = not record.star; _render_detail())
	UI.button(actions, "返回手牌", _close_detail)
	call_deferred("_restore_detail_focus")

func _restore_detail_focus() -> void:
	if not is_instance_valid(detail_overlay) or not detail_overlay.is_inside_tree(): return
	var buttons: Array[Button] = []
	for node in detail_overlay.find_children("*", "Button", true, false):
		if node.is_visible_in_tree() and not node.disabled: buttons.append(node)
	if buttons.is_empty(): return
	# 键盘循环留在当前详情内；关闭后才恢复原材料焦点。
	for index in range(buttons.size()):
		var previous := buttons[posmod(index - 1, buttons.size())].get_path()
		var following := buttons[(index + 1) % buttons.size()].get_path()
		buttons[index].focus_previous = previous
		buttons[index].focus_next = following
		buttons[index].focus_neighbor_left = previous
		buttons[index].focus_neighbor_top = previous
		buttons[index].focus_neighbor_right = following
		buttons[index].focus_neighbor_bottom = following
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null or not detail_overlay.is_ancestor_of(owner): buttons[-1].grab_focus()

func _restore_library_focus() -> void:
	if session.mode != "selection" or not is_visible_in_tree() or not grid_mode or not detail_content.is_empty() or not is_instance_valid(page_canvas): return
	var overlay := page_canvas.find_child("MaterialLibrary", true, false)
	if overlay == null: return
	var controls: Array[Control] = []
	for node in overlay.find_children("*", "Control", true, false):
		if node.focus_mode == Control.FOCUS_NONE or not node.is_visible_in_tree(): continue
		if node is BaseButton and node.disabled: continue
		controls.append(node)
	if controls.is_empty(): return
	for index in range(controls.size()):
		var previous := controls[posmod(index - 1, controls.size())].get_path()
		var following := controls[(index + 1) % controls.size()].get_path()
		controls[index].focus_previous = previous
		controls[index].focus_next = following
		controls[index].focus_neighbor_left = previous
		controls[index].focus_neighbor_top = previous
		controls[index].focus_neighbor_right = following
		controls[index].focus_neighbor_bottom = following
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null or not overlay.is_ancestor_of(owner): controls[0].grab_focus()

func _select_detail() -> void:
	if _select_card(detail_content): _close_detail()

func _select_card(id: String) -> bool:
	var before: Array = session.slots.duplicate()
	if not session.select_content(id): return false
	action_requested.emit("hand_selection_accepted", id)
	for index in range(2):
		if session.slots[index] != before[index]: slot_effect = {"slot": index, "content": id}
	if grid_mode:
		library_page = page
		grid_mode = false
		# 浅扇固定取得顺序，展开层搜索、分类和名称排序不影响同身份页定位。
		var ids: Array = _material_items(false).map(func(item): return str(item.id))
		page = floori(float(maxi(0, ids.find(str(session.config.contents[id].material_id)))) / hand_capacity())
		hand_page = page
		focus_content = str(session.case_state.data.materials[session.config.contents[id].material_id].current)
		refresh()
	_remember()
	return true

func _withdraw(index: int) -> void:
	var id := str(session.slots[index])
	if id.is_empty(): return
	session.clear_slot(index)
	if str(session.slots[index]).is_empty(): action_requested.emit("withdraw_material", id)

func _present() -> void:
	if session.present(): action_requested.emit("present_materials", "")

func _animate_slot() -> void:
	var index := int(slot_effect.get("slot", -1))
	var card := find_child("SelectedSlot%d" % index, true, false) as Control
	slot_effect.clear()
	if card == null or reduced_motion: return
	card.pivot_offset = card.size / 2
	card.scale = Vector2.ONE * 0.85
	card.modulate.a = 0.35
	var tween := create_tween().set_parallel(true)
	tween.tween_property(card, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate:a", 1.0, 0.2)

func set_preferences(values: Dictionary) -> void:
	preferences = values.duplicate(true)
	reduced_motion = bool(values.get("reduce_motion", false))
	if is_instance_valid(core_stage): core_stage.set_preferences(values)

func _search(value: String) -> void:
	search_text = value
	page = 0
	_remember()
	refresh()

func _close_detail() -> void:
	detail_content = ""
	if is_instance_valid(detail_overlay):
		remove_child(detail_overlay)
		detail_overlay.queue_free()
	detail_overlay = null
	refresh()

func _paper_button_theme() -> Theme:
	var result := Theme.new()
	var font_path := str(adopted_assets.get("A03_DreamHanSansCN-W16", ""))
	if ResourceLoader.exists(font_path): result.default_font = load(font_path)
	result.set_font_size("font_size", "Button", 24)
	result.set_color("font_color", "Button", Color("34413f"))
	result.set_color("font_hover_color", "Button", Color("34413f"))
	result.set_color("font_pressed_color", "Button", Color("34413f"))
	result.set_color("font_focus_color", "Button", Color("34413f"))
	result.set_color("font_disabled_color", "Button", Color("737b70"))
	for state in ["normal", "hover", "pressed", "disabled"]:
		var path := str(session.config.definition.root).path_join("assets/aurora/ui/art7/paper_v2/controls/button_secondary_" + state + ".png")
		if not ResourceLoader.exists(path): continue
		var style := StyleBoxTexture.new()
		style.texture = load(path)
		style.texture_margin_left = 16
		style.texture_margin_right = 16
		style.texture_margin_top = 12
		style.texture_margin_bottom = 16
		style.content_margin_left = 20
		style.content_margin_right = 20
		style.content_margin_top = 9
		style.content_margin_bottom = 9
		result.set_stylebox(state, "Button", style)
	return result

func _apply_action_icon(button: Button, state: String) -> void:
	# 图标沿核心资源表的实际采用项解析，不用路径名猜测或替代缺项。
	for binding in session.config.rows("core", "核心界面资源"):
		if binding.get("data_scope") != "runtime" or binding.get("component") != "action_icon" or binding.get("state") != state: continue
		var path := str(adopted_assets.get(str(binding.get("asset_ref", "")), ""))
		if not ResourceLoader.exists(path): return
		button.icon = load(path)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 24)
		button.add_theme_constant_override("h_separation", 10)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if button.text.is_empty() else HORIZONTAL_ALIGNMENT_LEFT
		if button.text.is_empty():
			for style_state in ["normal", "hover", "pressed", "disabled"]:
				var skin := button.get_theme_stylebox(style_state).duplicate() as StyleBox
				skin.content_margin_top = 12
				skin.content_margin_bottom = 12
				button.add_theme_stylebox_override(style_state, skin)
		return

func _card_area_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.08, 0.1, 0.98)
	style.border_color = Color(0.22, 0.34, 0.38, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 4
	return style

func _paper_panel_style() -> StyleBox:
	var path := str(session.config.definition.root).path_join("assets/aurora/ui/art7/paper_v2/controls/panel_paper.png")
	if ResourceLoader.exists(path):
		var style := StyleBoxTexture.new()
		style.texture = load(path)
		style.set_texture_margin_all(32)
		style.texture_margin_bottom = 36
		style.set_content_margin_all(24)
		return style
	var fallback := StyleBoxFlat.new()
	fallback.bg_color = Color("eee6cf")
	fallback.set_content_margin_all(24)
	return fallback

func _result() -> void:
	var pending: Dictionary = session.pending_result
	var result: Dictionary = session.config.results.get(pending.get("result", ""), {})
	var result_scroll := ScrollContainer.new()
	result_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	result_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(result_scroll)
	var result_box := VBoxContainer.new()
	result_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 结果正文必须锁定在核查页的实际可视宽度内；否则长按钮或长文会
	# 把 VBoxContainer 撑宽，RichTextLabel 即使禁用横向滚动也会画到屏幕外。
	result_box.custom_minimum_size.x = maxf(1.0, work_size.x - 48.0)
	result_box.add_theme_constant_override("separation", 8)
	result_box.clip_contents = true
	result_scroll.add_child(result_box)
	var feedback_label := UI.label(result_box, {"support": "得到支持", "exclude": "排除原说法", "inference": "发现新的关联", "insufficient": "材料尚不足", "incorrect": "这项出示有误"}.get(pending.get("feedback", ""), "核查结果"), 28)
	feedback_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result_prose(result_box, session.target_text())
	var sources := HFlowContainer.new()
	sources.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sources.custom_minimum_size.x = result_box.custom_minimum_size.x
	sources.add_theme_constant_override("h_separation", 6)
	sources.add_theme_constant_override("v_separation", 4)
	result_box.add_child(sources)
	for id in pending.get("refs", []): UI.button(sources, "回看依据 · " + str(session.config.contents[id].name), _open_detail.bind(str(id)))
	if pending.has("text"): _result_prose(result_box, str(pending.text))
	if not pending.get("response_read", false) and not str(pending.get("response", "")).is_empty() and (not pending.get("response_after_accept", false) or pending.get("accepted", false)): UI.button(result_box, "阅读完整回应", session.read_result_response)
	elif pending.get("complete", false):
		var inference := str(result.get("inference_content_ref", ""))
		if not inference.is_empty():
			var row: Dictionary = session.config.contents[inference]
			var card := MaterialCard.new()
			card.custom_minimum_size = Vector2(180, 270)
			card.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			result_box.add_child(card)
			card.configure(session, inference, false)
			UI.label(result_box, str(row.name), 24)
			_result_prose(result_box, str(row.detail_text))
			UI.button(result_box, "收下推论" if not pending.get("accepted", false) else "已收下", session.accept_inference, not pending.get("accepted", false)).name = "AcceptInference"
		UI.button(result_box, "继续", session.continue_result, inference.is_empty() or pending.get("accepted", false)).name = "ContinueResult"
	else:
		UI.button(result_box, "重新选材", session.continue_result)
		UI.button(result_box, "稍后核对", func(): session.pending_result.clear(); session.mode = "selection"; session.collapse_question())

func _result_prose(parent: Control, text: String) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.text = text
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	label.custom_minimum_size = Vector2(maxf(1.0, work_size.x - 48.0), 0)
	label.add_theme_font_size_override("normal_font_size", 19)
	parent.add_child(label)
	return label

func _toggle_grid() -> void:
	if not detail_content.is_empty(): return
	if grid_mode: library_page = page; page = hand_page
	else: hand_page = page; page = library_page
	grid_mode = not grid_mode
	_remember()
	refresh()
func toggle_library() -> bool:
	if session.mode != "selection" or not detail_content.is_empty(): return false
	_toggle_grid()
	return true
func _set_category(value: String) -> void:
	category = value
	page = 0
	_remember()
	refresh()
func _change_page(amount: int) -> void:
	page += amount
	_remember()
	refresh()
func handle_escape() -> bool:
	# Esc由外层统一打开暂停；逐层返回使用Backspace或本页返回按钮。
	return false
func handle_back() -> bool:
	if not detail_content.is_empty(): _close_detail(); return true
	if session.mode != "selection": return false
	if grid_mode: _toggle_grid()
	else: session.collapse_question()
	return true

func _remember() -> void:
	if grid_mode: library_page = page
	else: hand_page = page
	session.store_browsing({"grid": grid_mode, "page": page, "category": category, "starred": starred_only, "descending": order_descending, "positions": scroll_positions, "search": search_text, "sort_name": sort_name, "hand_page": hand_page, "library_page": library_page, "focus_content": focus_content, "library_focus": library_focus})

func reset_session() -> void:
	_close_detail()
	current_question = ""
	grid_mode = false
	page = 0
	category = "all"
	starred_only = false
	order_descending = false
	search_text = ""
	sort_name = false
	hand_page = 0
	library_page = 0
	slot_effect.clear()
	scroll_positions.clear()
	focus_content = ""
	library_focus = ""
	last_sound_identity = ""
	if is_instance_valid(core_stage): core_stage.reset()

func _has_new_inference() -> bool:
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if session.config.materials[id].type == "inference" and not record.read.get(record.current, false): return true
	return false

func _new_inference() -> void:
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if session.config.materials[id].type == "inference" and not record.read.get(record.current, false): _open_detail(str(record.current)); return
