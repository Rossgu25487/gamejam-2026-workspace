extends PanelContainer
## 共用只读阅读器。层栈保存精确材料、冻结来源和各层阅读位置。

signal closed
signal inspect_requested
const UI = preload("res://pages/core/page_controls.gd")
const Images = preload("res://pages/core/story_image_layer.gd")
const TalkPage = preload("res://pages/core/talk_records_page.gd")
var service: Node
var stack: Array = []
var box: VBoxContainer
var body: RichTextLabel
var root_kind := ""
var selection_mode := false
var read_only := true
var library_view := {"type": "all", "sort": "acquire", "important_only": false}
var library_tab := "materials"
var talk_view := {"object_id": "", "topic_id": "", "segment_id": ""}
var return_focus: WeakRef
var body_text_id := ""
var refresh_queued := false

func _ready() -> void:
	# 独立阅读层遮住下方控件文字，避免原话、归纳与选材界面相互叠印。
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.07, 0.08, 0.09, 1.0)
	paper.border_color = Color(0.28, 0.3, 0.32)
	paper.set_border_width_all(1)
	paper.set_content_margin_all(12)
	add_theme_stylebox_override("panel", paper)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	hide()

func bind(core: Node) -> void:
	service = core

func open_library() -> bool:
	if visible and root_kind == "library": close_all(); return true
	if not service.begin_inspection(): return false
	return_focus = weakref(get_viewport().gui_get_focus_owner())
	stack = [{"kind": "library", "tab": library_tab}]
	root_kind = "library"
	selection_mode = false
	show(); _render()
	return true

func open_material(ref: Dictionary, selection: bool = false) -> bool:
	if not service.store.owns(ref) or not service.begin_inspection(): return false
	return_focus = weakref(get_viewport().gui_get_focus_owner())
	stack = [{"kind": "material", "ref": ref.duplicate(true)}]
	root_kind = "detail"
	selection_mode = selection
	show(); _render()
	return true

func open_basis(sources: Array) -> bool:
	if not service.begin_inspection(): return false
	return_focus = weakref(get_viewport().gui_get_focus_owner())
	stack = [{"kind": "sources", "sources": sources.duplicate(true)}]
	root_kind = "sources"
	selection_mode = false
	show(); _render()
	return true

func _save_position() -> void:
	if not stack.is_empty() and is_instance_valid(body):
		stack[-1]["body_offset"] = body.get_v_scroll_bar().value
		# 从真实文字布局定位首行，再找该行第一个 Unicode 码点。
		# 不把像素偏移直接当字符索引，锚点只能应用于同一 text_id。
		var line := 0
		for i in range(body.get_line_count()):
			if body.get_line_offset(i) <= body.get_v_scroll_bar().value: line = i
		var low := 0
		var high := body.text.length()
		while low < high:
			var mid := (low + high) / 2
			if body.get_character_line(mid) < line: low = mid + 1
			else: high = mid
		stack[-1]["body_anchor"] = {"text_id": body_text_id, "character_index": low}

func _push(context: Dictionary) -> void:
	_save_position()
	stack.append(context.duplicate(true))
	_render()

func back() -> void:
	_save_position()
	if stack.size() <= 1: close_all(); return
	stack.pop_back()
	_render()

func close_all() -> void:
	if not visible: return
	hide()
	stack.clear()
	service.end_inspection()
	closed.emit()
	if return_focus != null:
		var focus = return_focus.get_ref()
		if is_instance_valid(focus) and focus is Control and focus.is_visible_in_tree(): focus.grab_focus()

func reset_reader() -> void:
	hide()
	stack.clear()
	root_kind = ""
	library_view = {"type": "all", "sort": "acquire", "important_only": false}
	library_tab = "materials"
	talk_view = {"object_id": "", "topic_id": "", "segment_id": ""}

func _render() -> void:
	UI.clear(box)
	body = null
	body_text_id = ""
	var ctx: Dictionary = stack[-1]
	var header := HBoxContainer.new()
	box.add_child(header)
	UI.label(header, service.ui("UI_HANDBOOK_ENTRY") if root_kind == "library" else "材料与来源", 26).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UI.button(header, service.ui("UI_HANDBOOK_SOURCE_UP"), back)
	UI.button(header, service.ui("UI_HANDBOOK_CLOSE") if root_kind == "library" else "关闭阅读", close_all).grab_focus()
	match ctx.kind:
		"library": _library(ctx)
		"material": _material(ctx)
		"sources": _sources(ctx)
		"record": _record(ctx)
		"text":
			body_text_id = ctx.text_id
			body = UI.body(box, service.catalog.text(ctx.text_id), 260)
	call_deferred("_restore_scroll", ctx.duplicate(true))

func _library(ctx: Dictionary) -> void:
	var tabs := HBoxContainer.new()
	box.add_child(tabs)
	UI.button(tabs, service.ui("UI_HANDBOOK_MATERIALS"), _tab.bind("materials"))
	UI.button(tabs, service.ui("UI_HANDBOOK_RECORDS"), _tab.bind("talk"))
	if ctx.tab == "talk":
		var talk := TalkPage.new()
		talk.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(talk)
		talk.basis_requested.connect(_push_talk_sources)
		talk.render(service, talk_view)
		return
	var filters := HBoxContainer.new()
	box.add_child(filters)
	var types := OptionButton.new()
	for key in ["UI_HANDBOOK_FILTER_ALL", "UI_HANDBOOK_EVIDENCE", "UI_HANDBOOK_TESTIMONY", "UI_HANDBOOK_INFERENCE"]: types.add_item(service.ui(key))
	types.selected = ["all", "evidence", "testimony", "inference"].find(library_view.type)
	types.item_selected.connect(_type)
	filters.add_child(types)
	var sorting := OptionButton.new()
	sorting.add_item(service.ui("UI_HANDBOOK_ACQUIRED_ORDER")); sorting.add_item(service.ui("UI_HANDBOOK_NAME_ORDER")); sorting.add_item(service.ui("UI_HANDBOOK_TYPE_ORDER"))
	sorting.selected = {"acquire": 0, "name": 1, "type": 2}.get(library_view.sort, 0)
	sorting.item_selected.connect(_sort)
	filters.add_child(sorting)
	var important := CheckButton.new()
	important.text = service.ui("UI_HANDBOOK_IMPORTANT")
	important.button_pressed = library_view.important_only
	important.toggled.connect(_important)
	filters.add_child(important)
	UI.button(filters, service.ui("UI_HANDBOOK_NEW_INFERENCE"), _new_inferences, not _unread_inferences().is_empty())
	UI.button(filters, service.ui("UI_HANDBOOK_CLEAR"), _clear_filters)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 6
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	var refs: Array = service.store.list_refs(library_view)
	for ref in refs:
		var card := VBoxContainer.new()
		card.custom_minimum_size = Vector2(125, 188)
		grid.add_child(card)
		UI.label(card, service.store.marker(ref.material_id), 16)
		var title := UI.button(card, service.catalog.text(service.catalog.data.contents[ref.content_id].title), _push.bind({"kind": "material", "ref": ref}))
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var art := Images.material_layout(service, ref.content_id)
		if not art.is_empty():
			title.custom_minimum_size = Vector2(100, 150)
			Images.attach_image(title, art)
		UI.button(card, "★" if service.store.entities[ref.material_id].important else "☆", _star.bind(ref.material_id))
	if refs.is_empty(): UI.label(grid, "没有符合筛选的已取得材料。", 20)

func _material(ctx: Dictionary) -> void:
	var ref: Dictionary = ctx.ref
	var content: Dictionary = service.catalog.data.contents[ref.content_id]
	UI.label(box, service.catalog.text(content.title) + " · v%d" % int(content.version), 24)
	body_text_id = content.body
	var art := Images.material_layout(service, ref.content_id)
	if art.is_empty(): body = UI.body(box, service.catalog.text(content.body), 230)
	else:
		# 观察图与全文并排，正文保留独立滚动和原来的字符锚点。
		var row := HBoxContainer.new()
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(row)
		var image_host := Control.new()
		image_host.custom_minimum_size = Vector2(260, 230)
		image_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(image_host)
		Images.attach_image(image_host, art)
		body = UI.body(row, service.catalog.text(content.body), 230)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	service.mark_read(ref)
	var versions := HBoxContainer.new()
	box.add_child(versions)
	if not ctx.has("frozen_sources"):
		# 只列实际已获版本，按版本倒序；单一版本保留标识但禁用切换。
		var known: Array = service.store.entities[ref.material_id].acquired_content_ids.duplicate()
		known.sort_custom(func(a: String, b: String): return int(service.catalog.data.contents[a].version) > int(service.catalog.data.contents[b].version))
		for id in known:
			UI.button(versions, "v%d" % int(service.catalog.data.contents[id].version), _version.bind(id), known.size() > 1)
	var sources: Array = ctx.get("frozen_sources", service.store.sources(ref))
	UI.button(box, "回看来源", _push.bind({"kind": "sources", "sources": sources}), not sources.is_empty())
	if root_kind == "detail" and selection_mode:
		var slots: Array = service.draft().get("slots", [])
		var slot := -1
		for i in range(slots.size()):
			if slots[i] != null and slots[i].material_id == ref.material_id: slot = i
		if slot >= 0: UI.button(box, service.ui("UI_CORE_REMOVE"), _withdraw.bind(slot))
		else: UI.button(box, service.ui("UI_CORE_SELECT"), _select.bind(ref), null in slots)
		UI.label(box, "已入槽的材料需先撤下，才可更换所选版本。", 16)
	if ctx.has("new_inference_refs"):
		var navigation := HBoxContainer.new()
		box.add_child(navigation)
		UI.button(navigation, service.ui("UI_HANDBOOK_PREVIOUS"), _step_inference.bind(-1), int(ctx.entry_index) > 0)
		UI.label(navigation, "%d / %d" % [int(ctx.entry_index) + 1, ctx.new_inference_refs.size()], 18)
		UI.button(navigation, service.ui("UI_HANDBOOK_NEXT"), _step_inference.bind(1), int(ctx.entry_index) + 1 < ctx.new_inference_refs.size())

func _sources(ctx: Dictionary) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for source in ctx.sources:
		match source.get("kind", ""):
			"material":
				var c: Dictionary = service.catalog.data.contents[source.ref.content_id]
				UI.button(list, service.catalog.text(c.title) + " · v%d" % int(c.version), _push.bind({"kind": "material", "ref": source.ref, "frozen_sources": source.sources}))
			"confirmed": UI.button(list, "前次确认 · " + str(source.record.confirmed_scope), _push.bind({"kind": "record", "record": source.record}))
			"acquisition": UI.button(list, service.catalog.text(source.get("text_id", "")), _push.bind({"kind": "text", "text_id": source.get("text_id", "")}))
	if ctx.sources.is_empty(): UI.label(list, "此内容没有额外的来源路径。", 20)

func _record(ctx: Dictionary) -> void:
	UI.label(box, str(ctx.record.confirmed_scope), 24)
	body_text_id = service.catalog.data.nodes[ctx.record.node].text
	body = UI.body(box, service.catalog.text(service.catalog.data.nodes[ctx.record.node].text), 230)
	UI.button(box, "实际依据", _push.bind({"kind": "sources", "sources": ctx.record.used_sources}))

func _version(id: String) -> void:
	_save_position()
	var ctx: Dictionary = stack[-1]
	ctx.ref = service.catalog.material_ref(id)
	ctx.erase("frozen_sources")
	ctx.body_offset = 0
	ctx.erase("body_anchor")
	_render()

func _select(ref: Dictionary) -> void:
	# 阅读结束后才恢复选材资格；服务再次验证容量和精确版本。
	close_all()
	service.select_material(ref)

func _withdraw(index: int) -> void:
	close_all()
	service.withdraw_material(index)

func _tab(tab: String) -> void:
	library_tab = tab
	stack[-1].tab = tab
	_render()

func _push_talk_sources(sources: Array) -> void:
	_push({"kind": "sources", "sources": sources})

func _type(index: int) -> void:
	library_view.type = ["all", "evidence", "testimony", "inference"][index]
	_queue_refresh()

func _clear_filters() -> void:
	library_view = {"type": "all", "sort": "acquire", "important_only": false}
	_queue_refresh()

func _important(value: bool) -> void:
	library_view.important_only = value
	_queue_refresh()

func _sort(index: int) -> void:
	library_view.sort = ["acquire", "name", "type"][index]
	_queue_refresh()

func _queue_refresh() -> void:
	# 让 PopupMenu 先完成选中及关闭，再替换筛选控件，避免销毁正在交接焦点的窗口。
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_refresh")

func _refresh() -> void:
	refresh_queued = false
	if is_visible_in_tree() and not stack.is_empty(): _render()

func _star(id: String) -> void:
	service.toggle_important(id)
	_render()

func _unread_inferences() -> Array:
	var refs: Array = []
	for ref in service.store.list_refs({"type": "inference"}):
		if service.store.entities[ref.material_id].viewed_content_ids.is_empty(): refs.append(ref)
	return refs

func _new_inferences() -> void:
	var refs := _unread_inferences()
	if not refs.is_empty(): _push({"kind": "material", "ref": refs[0], "new_inference_refs": refs, "entry_index": 0})

func _step_inference(delta: int) -> void:
	var ctx: Dictionary = stack[-1]
	var next := int(ctx.entry_index) + delta
	if next < 0 or next >= ctx.new_inference_refs.size(): return
	# 本次进入时冻结的名单不会随已读标记缩短，首尾停止且允许回读。
	ctx.entry_index = next
	ctx.ref = ctx.new_inference_refs[ctx.entry_index]
	ctx.body_offset = 0
	ctx.erase("body_anchor")
	_render()

func _restore_scroll(ctx: Dictionary) -> void:
	if not is_instance_valid(body): return
	var anchor: Dictionary = ctx.get("body_anchor", {})
	if anchor.get("text_id", "") == body_text_id and anchor.has("character_index"):
		var index := clampi(int(anchor.character_index), 0, maxi(0, body.text.length() - 1))
		body.scroll_to_line(body.get_character_line(index))
	else: body.get_v_scroll_bar().value = float(ctx.get("body_offset", 0))
