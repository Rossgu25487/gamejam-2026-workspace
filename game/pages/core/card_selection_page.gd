extends VBoxContainer
## 临时选材页：固定槽、底栏和网格是私有节点，所有动作均交给玩法服务。

signal read_requested(ref: Dictionary, selection: bool)
const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var page_index := 0
var card_buttons: Array[Button] = []
var refs: Array = []
var focus_ref: Dictionary = {}
var grid_scroll: ScrollContainer
var handle_start := -1.0
var rendered_view := "bar"
var rendered_type := "all"

func render(core: Node) -> void:
	service = core
	_capture_position()
	UI.clear(self)
	card_buttons.clear()
	var d: Dictionary = core.draft()
	var q: Dictionary = core.catalog.data.questions[core.state.question_id]
	var header := HBoxContainer.new()
	add_child(header)
	UI.label(header, core.catalog.text(q.title), 26).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if q.has("parent") and core.catalog.data.characters.has(q.parent):
		var name_label := UI.label(header, core.catalog.text(core.catalog.data.characters[q.parent].name), 20)
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	var chances := UI.label(header, "%s %s  (%d/3)" % [core.ui("UI_CORE_CHANCES_LABEL"), "●".repeat(int(core.state.chances[core.state.question_id])) + "○".repeat(3 - int(core.state.chances[core.state.question_id])), int(core.state.chances[core.state.question_id])], 18)
	chances.autowrap_mode = TextServer.AUTOWRAP_OFF
	var target_text: String = core.catalog.text(d.target_ref.question_text_id) if d.target_ref.target_kind == "reasoning" else core.catalog.text(core.catalog.data.statements[d.target_ref.statement_ref.statement_id].text)
	# 自主推理入口已确定目标，这里仅展示问题；实际校验始终由“出示”提交。
	if d.target_ref.target_kind == "reasoning":
		var target_panel := PanelContainer.new()
		add_child(target_panel)
		UI.label(target_panel, "推理目标（已选定）：" + target_text, 20)
	else:
		var target := UI.button(self, ("✓ 核对目标已选定：" if d.target_selected else "点击选择目标：") + target_text, core.select_target)
		target.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.label(self, "点击材料的「%s」放入出示槽，再点击「%s」查看结果。" % [core.ui("UI_CORE_SELECT"), core.ui("UI_CORE_PRESENT")], 16)
	var slots := HBoxContainer.new()
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(slots)
	for i in range(2):
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(100, 150)
		slots.add_child(panel)
		var box := VBoxContainer.new()
		panel.add_child(box)
		var ref = d.slots[i]
		if ref == null: UI.label(box, "出示槽 %d\n未放入材料" % (i + 1), 16)
		else:
			var c: Dictionary = core.catalog.data.contents[ref.content_id]
			var read := UI.button(box, core.catalog.text(c.title) + " · v%d" % int(c.version), read_requested.emit.bind(ref, true))
			read.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			read.size_flags_vertical = Control.SIZE_EXPAND_FILL
			read.add_theme_font_size_override("font_size", 14)
			UI.button(box, core.ui("UI_CORE_REMOVE"), core.withdraw_material.bind(i))
	var actions := HBoxContainer.new()
	add_child(actions)
	UI.button(actions, core.ui("UI_CORE_PRESENT"), core.present_materials, core.can_present())
	UI.button(actions, "全部撤下", core.withdraw_material)
	UI.button(actions, "收起对局", core.fold_card_selection)
	if q.has("parent"):
		for id in core.catalog.data.entries:
			if core.catalog.data.entries[id].get("object_id", "") == q.parent:
				UI.button(actions, "直接问话", core.activate_entry.bind(id))
	UI.button(actions, "收起牌库" if core.state.card_ui_page == "grid" else "全部材料", core.set_grid.bind(core.state.card_ui_page != "grid"))
	var filters := HBoxContainer.new()
	add_child(filters)
	var view: Dictionary = core.current_view()
	rendered_view = "grid" if core.state.card_ui_page == "grid" else "bar"
	rendered_type = view.type
	var type_select := OptionButton.new()
	for key in ["UI_HANDBOOK_FILTER_ALL", "UI_HANDBOOK_EVIDENCE", "UI_HANDBOOK_TESTIMONY", "UI_HANDBOOK_INFERENCE"]: type_select.add_item(core.ui(key))
	type_select.selected = ["all", "evidence", "testimony", "inference"].find(view.type)
	type_select.item_selected.connect(_filter_type)
	filters.add_child(type_select)
	var sort_select := OptionButton.new()
	sort_select.add_item(core.ui("UI_HANDBOOK_ACQUIRED_ORDER")); sort_select.add_item(core.ui("UI_HANDBOOK_TYPE_ORDER"))
	sort_select.selected = 0 if view.sort == "acquire" else 1
	sort_select.item_selected.connect(_sort)
	filters.add_child(sort_select)
	var important := CheckButton.new()
	important.text = core.ui("UI_HANDBOOK_IMPORTANT")
	important.button_pressed = view.important_only
	important.toggled.connect(_important)
	filters.add_child(important)
	refs = core.store.list_refs(view)
	_restore_position(view)
	grid_scroll = ScrollContainer.new()
	grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(grid_scroll)
	var cards := GridContainer.new()
	cards.columns = 6 if core.state.card_ui_page == "grid" else 5
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("h_separation", 8)
	cards.add_theme_constant_override("v_separation", 8)
	grid_scroll.add_child(cards)
	if refs.is_empty(): UI.label(cards, "此筛选下没有材料；可以切换筛选或收起。", 18)
	var start := 0 if core.state.card_ui_page == "grid" else page_index * 5
	var end := refs.size() if core.state.card_ui_page == "grid" else mini(start + 5, refs.size())
	for index in range(start, end): _card(cards, refs[index], d)
	var pager := HBoxContainer.new()
	add_child(pager)
	if core.state.card_ui_page != "grid":
		UI.button(pager, "上一页", _page.bind(-1), page_index > 0)
		UI.label(pager, "%d / %d" % [page_index + 1, maxi(1, ceili(refs.size() / 5.0))], 18).autowrap_mode = TextServer.AUTOWRAP_OFF
		UI.button(pager, "下一页", _page.bind(1), (page_index + 1) * 5 < refs.size())
	else:
		var handle := UI.button(pager, "↓ 收起牌库（把手可向下拖动）", core.set_grid.bind(false))
		handle.gui_input.connect(_handle_input)
	call_deferred("_restore_card_focus", view)

func _card(parent: Node, ref: Dictionary, d: Dictionary) -> void:
	var panel := PanelContainer.new()
	# 卡片独立保持2:3；布局变化只调整展示尺寸，不改材料或出示数量。
	panel.custom_minimum_size = Vector2(96, 144) if service.state.card_ui_page == "grid" else Vector2(152, 228)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var read_ref := ref.duplicate(true)
	var chosen: bool = false
	for old in d.slots:
		if old != null and old.material_id == ref.material_id:
			chosen = true
			read_ref = old.duplicate(true)
	var content: Dictionary = service.catalog.data.contents[read_ref.content_id]
	UI.label(box, service.store.marker(ref.material_id) + (" · 已放入" if chosen else ""), 14)
	var read := UI.button(box, service.catalog.text(content.title), read_requested.emit.bind(read_ref, true))
	read.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	read.tooltip_text = service.catalog.text(content.title)
	read.add_theme_font_size_override("font_size", 14)
	read.focus_entered.connect(_focused.bind(ref))
	read.set_meta("material_ref", ref)
	card_buttons.append(read)
	var summary := UI.label(box, service.catalog.text(content.summary), 16)
	summary.visible = service.state.card_ui_page != "grid"
	summary.max_lines_visible = 2
	summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	summary.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var select := UI.button(box, service.ui("UI_CORE_SELECT"), service.select_material.bind(ref), not chosen and null in d.slots)
	select.custom_minimum_size.y = 28
	select.add_theme_font_size_override("font_size", 14)
	var star := UI.button(box, "★" if service.store.entities[ref.material_id].important else "☆", service.toggle_important.bind(ref.material_id))
	star.custom_minimum_size.y = 28
	star.add_theme_font_size_override("font_size", 14)
	if chosen: panel.modulate = Color(0.65, 0.65, 0.65)

func _focused(ref: Dictionary) -> void:
	focus_ref = ref.duplicate(true)
	service.record_view_position(rendered_view, rendered_type, {}, ref)

func _filter_type(index: int) -> void:
	_save_position()
	service.update_view({"type": ["all", "evidence", "testimony", "inference"][index]})

func _sort(index: int) -> void:
	_save_position()
	service.update_view({"sort": "acquire" if index == 0 else "type"})

func _important(value: bool) -> void:
	_save_position()
	var view: Dictionary = service.current_view()
	var p: Dictionary = view.positions_by_type.get(view.type, {})
	if value: p["full_anchor_id"] = p.get("anchor_id", "")
	elif p.has("full_anchor_id"): p.anchor_id = p.full_anchor_id
	view.positions_by_type[view.type] = p
	service.update_view({"important_only": value, "positions_by_type": view.positions_by_type})

func _page(delta: int) -> void:
	page_index = clampi(page_index + delta, 0, maxi(0, ceili(refs.size() / 5.0) - 1))
	_save_position()
	service.changed.emit()

func _capture_position() -> void:
	if is_instance_valid(grid_scroll) and is_instance_valid(service) and not refs.is_empty() and rendered_view == "grid":
		_save_position(rendered_view, rendered_type)

func _save_position(view_name: String = "", type_name: String = "") -> void:
	if refs.is_empty(): return
	if view_name.is_empty(): view_name = "grid" if service.state.card_ui_page == "grid" else "bar"
	var view: Dictionary = (service.state.grid_view if view_name == "grid" else service.state.bar_view).duplicate(true)
	if type_name.is_empty(): type_name = view.type
	var anchor := mini(page_index * 5, refs.size() - 1)
	var offset := 0
	if view_name == "grid" and is_instance_valid(grid_scroll):
		offset = grid_scroll.scroll_vertical
		anchor = mini((offset / 152) * 6, refs.size() - 1)
	var old: Dictionary = view.positions_by_type.get(type_name, {})
	old.merge({"anchor_id": refs[anchor].material_id, "page": page_index, "offset": offset}, true)
	service.record_view_position(view_name, type_name, old)

func _restore_position(view: Dictionary) -> void:
	var p: Dictionary = view.positions_by_type.get(view.type, {})
	page_index = int(p.get("page", 0))
	var id: String = p.get("anchor_id", "")
	for i in range(refs.size()):
		if refs[i].material_id == id: page_index = i / 5; break
	page_index = clampi(page_index, 0, maxi(0, ceili(refs.size() / 5.0) - 1))

func _restore_card_focus(view: Dictionary) -> void:
	if not visible: return
	if service.state.card_ui_page == "grid": grid_scroll.scroll_vertical = int(view.positions_by_type.get(view.type, {}).get("offset", 0))
	for b in card_buttons:
		if b.get_meta("material_ref") == view.focus_ref: b.grab_focus(); return

func _handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		handle_start = event.position.y if event.pressed else -1.0
	elif event is InputEventMouseMotion and handle_start >= 0 and event.position.y - handle_start >= 24:
		handle_start = -1
		service.set_grid(false)
		accept_event()

func handle_card_key(event: InputEventKey) -> bool:
	if not visible or not event.pressed or event.echo or refs.is_empty(): return false
	if event.keycode not in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]: return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus not in card_buttons: return false
	var index := refs.find(focus.get_meta("material_ref"))
	var delta := -1 if event.keycode == KEY_LEFT else 1
	if event.keycode in [KEY_UP, KEY_DOWN]:
		if service.state.card_ui_page != "grid": return true
		delta = -6 if event.keycode == KEY_UP else 6
	var next := clampi(index + delta, 0, refs.size() - 1)
	if event.keycode == KEY_DOWN and index + 6 >= refs.size(): next = index
	focus_ref = refs[next]
	service.record_view_position(rendered_view, rendered_type, {}, focus_ref)
	if service.state.card_ui_page != "grid" and next / 5 != page_index:
		page_index = next / 5
		_save_position()
		service.changed.emit()
	else:
		for b in card_buttons:
			if b.get_meta("material_ref") == focus_ref: b.grab_focus(); grid_scroll.ensure_control_visible(b); break
	return true
