extends Control
## 核查页只处理选材显示、草稿浏览和玩家操作。判定、来源冻结与结果时点由会话负责。
const UI = preload("res://pages/core/page_controls.gd")
signal menu_requested
signal material_requested(content_id: String)
signal handbook_requested
var session: Node
var queued := false
var grid_mode := false
var page := 0
var category := "all"
var starred_only := false
var order_descending := false
var body: VBoxContainer
var proof_time := 0.0
var current_question := ""
var scroll_positions := {}

func bind(value: Node) -> void:
	session = value
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
		scroll_positions = browse.get("positions", {}).duplicate(true)
	UI.clear(self)
	var shade := ColorRect.new()
	shade.color = Color(0.035, 0.055, 0.07, 0.97)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 24)
	add_child(margin)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	margin.add_child(body)
	var top := HBoxContainer.new()
	body.add_child(top)
	UI.label(top, "核查 · " + session.question, 28)
	UI.button(top, "办案手册", handbook_requested.emit)
	UI.button(top, "菜单", menu_requested.emit)
	if session.mode == "selection": _selection()
	elif session.mode == "failure":
		UI.label(body, "本次复核次数已用完", 32)
		UI.button(body, "重试", session.retry_question)
		UI.button(body, "返回原入口", session.collapse_question)
	else: _result()

func _selection() -> void:
	var target := UI.button(body, ("已选定：" if session.selected_target else "点击选定听过的原话：") + session.target_text(), session.select_target)
	target.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.label(body, "容错：%d / 3" % int(session.case_state.data.chances.get(session.question, 3)), 22)
	var slots_box := HBoxContainer.new()
	body.add_child(slots_box)
	for index in range(2):
		var id := str(session.slots[index])
		var slot := VBoxContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slots_box.add_child(slot)
		UI.button(slot, "空引用夹位" if id.is_empty() else str(session.config.contents[id].name), material_requested.emit.bind(id), not id.is_empty())
		UI.button(slot, "撤下", session.clear_slot.bind(index), not id.is_empty())
	var actions := HBoxContainer.new()
	body.add_child(actions)
	UI.button(actions, "出示", session.present, session.selected_target and not session.slots.all(func(id): return str(id).is_empty()))
	UI.button(actions, "全部撤下", func(): session.clear_slot(0); session.clear_slot(1))
	UI.button(actions, "收起对局", session.collapse_question)
	UI.button(actions, "收起牌库" if grid_mode else "全部材料", _toggle_grid)
	UI.button(actions, "新推论", _new_inference, _has_new_inference())
	var filter_bar := HBoxContainer.new()
	body.add_child(filter_bar)
	for pair in [["all", "全部"], ["evidence", "证据"], ["testimony", "证言"], ["inference", "推论"]]:
		UI.button(filter_bar, pair[1], _set_category.bind(pair[0]))
	UI.button(filter_bar, "仅重点 ✓" if starred_only else "仅重点", func(): starred_only = not starred_only; page = 0; _remember(); refresh())
	UI.button(filter_bar, "获得顺序 ↓" if order_descending else "获得顺序 ↑", func(): order_descending = not order_descending; page = 0; _remember(); refresh())
	var all: Array = []
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if category != "all" and session.config.materials[id].type != category: continue
		if starred_only and not record.star: continue
		all.append({"id": id, "record": record})
	all.sort_custom(func(a, b): return a.record.order > b.record.order if order_descending else a.record.order < b.record.order)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	scroll.set_deferred("scroll_vertical", int(scroll_positions.get(category, 0)))
	scroll.get_v_scroll_bar().value_changed.connect(func(value): scroll_positions[category] = value; _remember())
	var grid := GridContainer.new()
	grid.columns = 6 if grid_mode else 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	scroll.add_child(grid)
	page = clampi(page, 0, maxi(0, ceili(all.size() / 5.0) - 1))
	var shown := all if grid_mode else all.slice(page * 5, page * 5 + 5)
	for item in shown:
		var content_id := str(item.record.current)
		var row: Dictionary = session.config.contents[content_id]
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(150, 225)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(box)
		var title := UI.button(box, str(row.name), material_requested.emit.bind(content_id))
		title.custom_minimum_size.y = 66
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var detail := UI.label(box, str(row.description), 18)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.custom_minimum_size.y = 70
		detail.max_lines_visible = 3
		UI.button(box, "已选用" if content_id in session.slots else "选用", session.select_content.bind(content_id), content_id not in session.slots)
	if all.is_empty(): UI.label(body, "没有符合条件的已取得材料", 22)
	if not grid_mode:
		var pages := HBoxContainer.new()
		body.add_child(pages)
		UI.button(pages, "上一页", _change_page.bind(-1), page > 0)
		UI.label(pages, "%d / %d" % [page + 1, maxi(1, ceili(all.size() / 5.0))], 20)
		UI.button(pages, "下一页", _change_page.bind(1), (page + 1) * 5 < all.size())

func _result() -> void:
	var pending: Dictionary = session.pending_result
	var result: Dictionary = session.config.results.get(pending.get("result", ""), {})
	UI.label(body, {"support": "得到支持", "exclude": "排除原说法", "inference": "发现新的关联", "insufficient": "材料尚不足", "incorrect": "这项出示有误"}.get(pending.get("feedback", ""), "核查结果"), 34)
	UI.body(body, session.target_text(), 90)
	var sources := HBoxContainer.new()
	body.add_child(sources)
	for id in pending.get("refs", []): UI.button(sources, "回看依据 · " + str(session.config.contents[id].name), material_requested.emit.bind(str(id)))
	if pending.has("text"): UI.body(body, str(pending.text), 120)
	if not pending.get("response_read", false) and not str(pending.get("response", "")).is_empty() and (not pending.get("response_after_accept", false) or pending.get("accepted", false)): UI.button(body, "阅读完整回应", session.read_result_response)
	elif pending.get("complete", false):
		var inference := str(result.get("inference_content_ref", ""))
		if not inference.is_empty():
			var row: Dictionary = session.config.contents[inference]
			UI.label(body, str(row.name), 28)
			UI.body(body, str(row.detail_text), 240)
			UI.button(body, "收下推论" if not pending.get("accepted", false) else "已收下", session.accept_inference, not pending.get("accepted", false))
		UI.button(body, "继续", session.continue_result, inference.is_empty() or pending.get("accepted", false))
	else:
		UI.button(body, "重新选材", session.continue_result)
		UI.button(body, "稍后核对", func(): session.pending_result.clear(); session.mode = "selection"; session.collapse_question())

func _toggle_grid() -> void:
	grid_mode = not grid_mode
	_remember()
	refresh()
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
	if session.mode != "selection": return false
	if grid_mode: grid_mode = false; refresh()
	else: session.collapse_question()
	return true

func _remember() -> void:
	session.store_browsing({"grid": grid_mode, "page": page, "category": category, "starred": starred_only, "descending": order_descending, "positions": scroll_positions})

func reset_session() -> void:
	current_question = ""
	grid_mode = false
	page = 0
	category = "all"
	starred_only = false
	order_descending = false
	scroll_positions.clear()

func _has_new_inference() -> bool:
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if session.config.materials[id].type == "inference" and not record.read.get(record.current, false): return true
	return false

func _new_inference() -> void:
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if session.config.materials[id].type == "inference" and not record.read.get(record.current, false): material_requested.emit(str(record.current)); return
