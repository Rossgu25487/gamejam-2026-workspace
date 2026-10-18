extends Control
## 正式手册与文书共用阅读页；只展示实际取得版本，材料入口读完回执由玩家在全文底部确认。
const UI = preload("res://pages/core/page_controls.gd")
signal closed
signal content_selected(content_id: String)
var session: Node
var root_box: VBoxContainer
var reading_content := ""
var reading_entry := false
var return_stack: Array = []
var tab := "materials"
var queued := false
var read_positions := {}
var allow_selection := false
var frozen_sources = null
var category := "all"
var only_star := false
var sort_by := "order"
var library_positions := {}
var selected_person := ""
var new_list: Array = []
var new_index := 0
var source_document := {}
var canvas: Control
var library_scroll: ScrollContainer
var compact_mode := false

func set_compact_mode(value: bool) -> void:
	# 推理页打开手册时使用右侧紧凑抽屉，保留底部手牌和出示区。
	if compact_mode == value: return
	compact_mode = value
	if visible: _render()

func export_view() -> Dictionary:
	return {"visible": visible, "content": reading_content, "entry": reading_entry, "selectable": allow_selection,
		"sources": frozen_sources, "stack": return_stack.duplicate(true), "tab": tab, "category": category,
		"star": only_star, "sort": sort_by, "positions": read_positions.duplicate(true),
		"library_positions": library_positions.duplicate(true), "person": selected_person,
		"new_list": new_list.duplicate(), "new_index": new_index, "document": source_document.duplicate(true)}

func restore_view(data: Dictionary) -> void:
	if data.is_empty(): return
	reading_content = str(data.get("content", ""))
	reading_entry = bool(data.get("entry", false))
	allow_selection = bool(data.get("selectable", false))
	frozen_sources = data.get("sources")
	return_stack = data.get("stack", []).duplicate(true)
	tab = str(data.get("tab", "materials"))
	category = str(data.get("category", "all"))
	only_star = bool(data.get("star", false))
	sort_by = str(data.get("sort", "order"))
	read_positions = data.get("positions", {}).duplicate(true)
	library_positions = data.get("library_positions", {}).duplicate(true)
	selected_person = str(data.get("person", ""))
	new_list = data.get("new_list", []).duplicate()
	new_index = int(data.get("new_index", 0))
	source_document = data.get("document", {}).duplicate(true)
	visible = bool(data.get("visible", false))
	if visible: _render()

func reset_session() -> void:
	tab = "materials"
	category = "all"
	only_star = false
	sort_by = "order"
	library_positions.clear()
	read_positions.clear()
	return_stack.clear()
	selected_person = ""
	new_list.clear()
	source_document.clear()
	reading_content = ""
	reading_entry = false
	compact_mode = false
	hide()

func bind(value: Node) -> void:
	session = value
	resized.connect(func(): if visible: _render())
	hide()

func open_library() -> void:
	reading_content = ""
	reading_entry = false
	return_stack.clear()
	allow_selection = false
	frozen_sources = null
	source_document.clear()
	show()
	_render()

func open_content(id: String, from_entry: bool = false, selectable: bool = false, sources = null) -> void:
	if not session.config.contents.has(id) or (not from_entry and not session.case_state.owns(id)): return
	reading_content = id
	source_document.clear()
	reading_entry = from_entry
	allow_selection = selectable
	frozen_sources = sources.duplicate(true) if sources is Array else null
	show()
	_render()

func _render() -> void:
	UI.clear(self)
	mouse_filter = Control.MOUSE_FILTER_STOP if not compact_mode else Control.MOUSE_FILTER_IGNORE
	canvas = Control.new()
	if compact_mode:
		canvas.size = Vector2(520, 680)
		var compact_scale := minf(1.0, minf((size.x - 32.0) / canvas.size.x, (size.y - 32.0) / canvas.size.y))
		canvas.scale = Vector2.ONE * compact_scale
		canvas.position = Vector2(size.x - canvas.size.x * compact_scale - 16.0, 16.0)
	else:
		canvas.size = Vector2(1600, 900)
		canvas.scale = Vector2.ONE * minf(size.x / 1600, size.y / 900)
		canvas.position = (size - canvas.size * canvas.scale) / 2
	add_child(canvas)
	var color := ColorRect.new()
	color.color = Color(0.04, 0.06, 0.08, 0.98)
	color.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	color.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(color)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin_px := 18 if compact_mode else 32
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, margin_px)
	canvas.add_child(margin)
	root_box = VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 12)
	root_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root_box)
	var heading := HFlowContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.add_child(heading)
	var heading_text := UI.label(heading, str(source_document.get("title", "办案手册" if reading_content.is_empty() else str(session.config.contents[reading_content].name))), 22 if compact_mode else 28)
	heading_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not source_document.is_empty(): _source_reading()
	elif not reading_content.is_empty(): _reading()
	else: _library()

func _library() -> void:
	var tabs := HBoxContainer.new()
	root_box.add_child(tabs)
	for pair in [["materials", "材料"], ["records", "交谈记录"], ["people", "人物"]]: UI.button(tabs, pair[1], func(): tab = pair[0]; _render())
	if tab == "materials": _filters()
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)
	library_scroll = scroll
	var scroll_key := tab + "/" + category
	scroll.set_deferred("scroll_vertical", int(library_positions.get(scroll_key, 0)))
	scroll.get_v_scroll_bar().value_changed.connect(func(value): library_positions[scroll_key] = value)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 12)
	scroll.add_child(list)
	if tab == "materials":
		var ids := _material_ids()
		var grid := GridContainer.new()
		grid.columns = 2 if compact_mode else 6
		grid.add_theme_constant_override("h_separation", 10 if compact_mode else 14)
		grid.add_theme_constant_override("v_separation", 10 if compact_mode else 14)
		list.add_child(grid)
		for id in ids:
			var record: Dictionary = session.case_state.data.materials[id]
			var content_id := str(record.current)
			var row: Dictionary = session.config.contents[content_id]
			var box := VBoxContainer.new()
			box.custom_minimum_size = Vector2(220, 270) if compact_mode else Vector2(238, 357)
			grid.add_child(box)
			var mark := "" if record.read.get(content_id, false) else ("更新" if record.read.values().has(true) else "新")
			_picture(box, str(row.get("image_ref", "")), Vector2(220, 112) if compact_mode else Vector2(238, 160))
			var button := UI.button(box, str(row.name), _open_library_content.bind(content_id))
			button.custom_minimum_size.y = 54 if compact_mode else 70
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.add_theme_font_size_override("font_size", 18 if compact_mode else 24)
			button.tooltip_text = str(row.description)
			UI.label(box, "%s · 第%d版 · %s" % [session.config.materials[id].type, int(row.version), mark], 16 if compact_mode else 20)
			var summary := UI.label(box, str(row.description), 16 if compact_mode else 20)
			summary.max_lines_visible = 2
			UI.button(box, "★ 重点" if record.star else "☆ 标为重点", _star.bind(id))
		if ids.is_empty(): UI.label(list, "尚未取得材料" if session.case_state.data.materials.is_empty() else "没有符合筛选的材料 · 0/0", 18 if compact_mode else 24)
	elif tab == "people":
		_people(list)
	else:
		UI.button(root_box, "回到最新", func(): scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value)), not session.narrative.visible_history().is_empty())
		for row in session.narrative.visible_history():
			if str(row.get("text", "")).is_empty(): continue
			UI.label(list, str(row.get("speaker_name", "")), 22)
			_prose(list, str(row.text))
	UI.button(root_box, "关闭手册", close_page)

func _reading() -> void:
	var row: Dictionary = session.config.contents[reading_content]
	# 详情使用单一内容流：图片、正文、版本、来源和操作都在同一个滚动区域内。
	# 这样不会出现图片在上一页、按钮被挤到下一页的断裂布局。
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages.custom_minimum_size.x = _reading_content_width()
	pages.clip_contents = true
	pages.add_theme_constant_override("separation", 6)
	scroll.add_child(pages)
	var path := str(row.get("image_ref", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var picture := TextureRect.new()
		picture.texture = load(path)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# 图片只占详情页顶部的一段固定高度，避免把操作按钮整体推到下一屏。
		picture.custom_minimum_size = Vector2(0, 112 if compact_mode else 170)
		picture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pages.add_child(picture)
	_prose(pages, str(row.detail_text))
	# 回执位于全文下面。未阅读就返回不会触发completion_event或发卡。
	var content_actions := HFlowContainer.new()
	content_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_actions.add_theme_constant_override("h_separation", 6)
	content_actions.add_theme_constant_override("v_separation", 4)
	pages.add_child(content_actions)
	if reading_entry: UI.button(pages, "已读完这份原件", _complete_reading)
	else:
		var id := str(row.material_id)
		var record: Dictionary = session.case_state.data.materials[id]
		record.read[reading_content] = true
		UI.button(content_actions, "取消重点" if record.star else "标为重点", func(): record.star = not record.star; _render())
		if session.mode == "selection" and allow_selection:
			var same_material: bool = session.slots.any(func(value): return not str(value).is_empty() and session.config.contents[value].material_id == id)
			UI.button(content_actions, "请先撤下已入槽的同一材料" if same_material else "选用当前版本", func(): content_selected.emit(reading_content); close_page(), not same_material)
		var versions_title := UI.label(pages, "实际取得的版本", 19 if compact_mode else 22)
		versions_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var versions: Array = record.versions.keys()
		versions.sort_custom(func(a, b): return int(session.config.contents[a].version) > int(session.config.contents[b].version))
		var version_actions := HFlowContainer.new()
		version_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		version_actions.add_theme_constant_override("h_separation", 6)
		version_actions.add_theme_constant_override("v_separation", 4)
		pages.add_child(version_actions)
		for version in versions:
			UI.button(version_actions, str(session.config.contents[version].name) + " · 第%d版" % int(session.config.contents[version].version), _push_content.bind(str(version)), versions.size() > 1 and version != reading_content)
		var sources_title := UI.label(pages, "来源", 19 if compact_mode else 22)
		sources_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var source_actions := HFlowContainer.new()
		source_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		source_actions.add_theme_constant_override("h_separation", 6)
		source_actions.add_theme_constant_override("v_separation", 4)
		pages.add_child(source_actions)
		for source in (frozen_sources if frozen_sources is Array else record.versions[reading_content]): _source(source_actions, source)
	scroll.set_deferred("scroll_vertical", int(read_positions.get(reading_content, 0)))
	scroll.get_v_scroll_bar().value_changed.connect(func(value): read_positions[reading_content] = value)
	var actions := HFlowContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_theme_constant_override("h_separation", 6)
	actions.add_theme_constant_override("v_separation", 4)
	pages.add_child(actions)
	UI.button(actions, "取消阅读" if reading_entry else ("上一级" if not return_stack.is_empty() else "返回"), _back)
	if not reading_entry: UI.button(actions, "关闭阅读", close_page)
	if not new_list.is_empty() and reading_content in new_list:
		var controls := HFlowContainer.new()
		controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		controls.add_theme_constant_override("h_separation", 6)
		pages.add_child(controls)
		UI.button(controls, "前一项", _new_move.bind(-1), new_index > 0)
		UI.label(controls, "%d / %d" % [new_index + 1, new_list.size()])
		UI.button(controls, "后一项", _new_move.bind(1), new_index + 1 < new_list.size())

func _source(parent: Control, source: Dictionary) -> void:
	var label := str(source.get("entry", source.get("question", "实际调查")))
	if source.has("text"): label = session.config.text(str(source.text))
	UI.button(parent, label, _push_source.bind(source))
	for item in source.get("sources", []):
		var id := str(item.get("content_id", ""))
		if session.case_state.owns(id): UI.button(parent, "依据 · " + str(session.config.contents[id].name), _push_content.bind(id, item.get("sources", [])))

func _push_content(id: String, sources = null) -> void:
	return_stack.append({"content": reading_content, "sources": frozen_sources, "selectable": allow_selection, "document": source_document.duplicate(true)})
	open_content(id, false, allow_selection, sources)

func _complete_reading() -> void:
	if session.material_read_complete():
		hide()
		closed.emit()

func _back() -> void:
	if reading_entry:
		session.cancel_material()
		hide()
		closed.emit()
	elif not return_stack.is_empty():
		var frame: Dictionary = return_stack.pop_back()
		open_content(str(frame.content), false, bool(frame.selectable), frame.sources)
		source_document = frame.get("document", {}).duplicate(true)
		_render()
	else: open_library()

func close_page() -> void:
	if reading_entry: session.cancel_material()
	hide()
	closed.emit()

func handle_escape() -> bool:
	if not visible: return false
	_back()
	return true

func _prose(parent: Control, text: String) -> RichTextLabel:
	var label := UI.body(parent, text, 0)
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	label.custom_minimum_size = Vector2(1, 0)
	label.add_theme_font_size_override("normal_font_size", 19 if compact_mode else 23)
	return label

func _reading_content_width() -> float:
	# ScrollContainer 的子节点必须明确小于视口宽度，否则长文会把
	# RichTextLabel 和 HFlowContainer 撑宽，产生屏幕外文案或横向溢出。
	var margin_px := 18.0 if compact_mode else 32.0
	return maxf(1.0, canvas.size.x - margin_px * 2.0 - 24.0)

func _picture(parent: Control, path: String, minimum: Vector2) -> void:
	if path.is_empty() or not ResourceLoader.exists(path): return
	var image := TextureRect.new()
	image.texture = load(path)
	image.custom_minimum_size = minimum
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(image)

func _material_ids() -> Array:
	var ids: Array = []
	for id in session.case_state.data.materials:
		if category != "all" and session.config.materials[id].type != category: continue
		if only_star and not session.case_state.data.materials[id].star: continue
		ids.append(id)
	ids.sort_custom(func(a, b):
		if sort_by == "name": return str(session.config.contents[session.case_state.data.materials[a].current].name).naturalnocasecmp_to(str(session.config.contents[session.case_state.data.materials[b].current].name)) < 0
		if sort_by == "type" and session.config.materials[a].type != session.config.materials[b].type: return str(session.config.materials[a].type) < str(session.config.materials[b].type)
		return session.case_state.data.materials[a].order < session.case_state.data.materials[b].order)
	return ids

func _filters() -> void:
	var filters := HBoxContainer.new()
	root_box.add_child(filters)
	for pair in [["all", "全部"], ["evidence", "证据"], ["testimony", "证言"], ["inference", "推论"]]: UI.button(filters, pair[1], func(): category = pair[0]; _render())
	for pair in [["order", "获得顺序"], ["name", "名称"], ["type", "类型"]]: UI.button(filters, pair[1], func(): sort_by = pair[0]; _render())
	UI.button(filters, "仅重点 ✓" if only_star else "仅重点", func(): only_star = not only_star; _render())
	UI.button(filters, "重置筛选", func(): category = "all"; sort_by = "order"; only_star = false; library_positions.clear(); _render())
	UI.button(filters, "新推论", _open_new, not _new_contents().is_empty())

func _star(id: String) -> void:
	var record: Dictionary = session.case_state.data.materials[id]
	record.star = not record.star
	_render()

func _open_library_content(id: String) -> void:
	return_stack.clear()
	new_list.clear()
	open_content(id)

func _new_contents() -> Array:
	var result: Array = []
	for id in session.case_state.data.materials:
		var record: Dictionary = session.case_state.data.materials[id]
		if session.config.materials[id].type == "inference" and not record.read.get(record.current, false): result.append(str(record.current))
	result.sort_custom(func(a, b): return session.case_state.data.materials[session.config.contents[a].material_id].order < session.case_state.data.materials[session.config.contents[b].material_id].order)
	return result

func _open_new() -> void:
	new_list = _new_contents()
	new_index = 0
	if not new_list.is_empty(): open_content(str(new_list[0]))

func _new_move(delta: int) -> void:
	new_index = clampi(new_index + delta, 0, new_list.size() - 1)
	open_content(str(new_list[new_index]))

func _people(parent: Control) -> void:
	var people: Array = session.case_state.data.profiles.keys()
	if people.is_empty(): UI.label(parent, "尚无已公开人物资料", 24); return
	if selected_person not in people: selected_person = str(people[0])
	var split := HBoxContainer.new()
	parent.add_child(split)
	var grid := GridContainer.new()
	grid.columns = 2
	split.add_child(grid)
	for person in people:
		var profile: Dictionary = session.config.profiles[session.case_state.data.profiles[person]]
		var card := VBoxContainer.new()
		card.custom_minimum_size = Vector2(256, 180)
		grid.add_child(card)
		_picture(card, str(profile.avatar_ref), Vector2(96, 112))
		UI.button(card, ("✓ " if person == selected_person else "") + str(profile.display_name), func(): selected_person = person; _render())
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(detail)
	var selected: Dictionary = session.config.profiles[session.case_state.data.profiles[selected_person]]
	_picture(detail, str(selected.portrait_ref), Vector2(320, 300))
	UI.label(detail, str(selected.display_name), 32)
	UI.label(detail, str(selected.identity_text), 28)
	_prose(detail, str(selected.bio_text))

func _push_source(source: Dictionary) -> void:
	return_stack.append({"content": reading_content, "sources": frozen_sources, "selectable": allow_selection, "document": source_document.duplicate(true)})
	source_document = source.duplicate(true)
	source_document["title"] = "取得来源"
	_render()

func _source_reading() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.custom_minimum_size.x = _reading_content_width()
	box.clip_contents = true
	scroll.add_child(box)
	var text_id := str(source_document.get("text", ""))
	_prose(box, session.config.text(text_id) if session.config.texts.has(text_id) else session.entry_label(str(source_document.get("entry", ""))))
	for item in source_document.get("sources", []):
		var id := str(item.get("content_id", ""))
		if session.case_state.owns(id): UI.button(box, str(session.config.contents[id].name), _push_content.bind(id, item.get("sources", [])))
	var actions := HFlowContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.add_child(actions)
	UI.button(actions, "上一级", _back)
	UI.button(actions, "关闭来源与阅读", close_page)
