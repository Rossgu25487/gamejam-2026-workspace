extends Control
## 正式手册与文书共用阅读页；只展示实际取得版本，材料入口读完回执由玩家在全文底部确认。
const UI = preload("res://pages/core/page_controls.gd")
const PaperTheme = preload("res://pages/aurora/aurora_paper_theme.gd")
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
var selected_material := ""
var library_pages := {}
var panel_size := Vector2.ZERO
var layout_records: Array = []
var assets := {}
var filters_open := false

func set_compact_mode(value: bool) -> void:
	# 保留旧调用接口。核查中的完整手册与其他模式共用模态阅读面板，关闭后回到原草稿。
	if compact_mode == value: return
	compact_mode = value
	if visible: _render()

func export_view() -> Dictionary:
	return {"visible": visible, "content": reading_content, "entry": reading_entry, "selectable": allow_selection,
		"sources": frozen_sources, "stack": return_stack.duplicate(true), "tab": tab, "category": category,
		"star": only_star, "sort": sort_by, "positions": read_positions.duplicate(true),
		"library_positions": library_positions.duplicate(true), "person": selected_person,
		"new_list": new_list.duplicate(), "new_index": new_index, "document": source_document.duplicate(true), "selected_material": selected_material,
		"library_pages": library_pages.duplicate(), "filters_open": filters_open}

func restore_view(data: Dictionary) -> void:
	if data.is_empty(): return
	reading_content = str(data.get("content", ""))
	reading_entry = bool(data.get("entry", false))
	# 核查里的完整手册始终只读；其他系统明确发起的情境调用沿原合同恢复。
	allow_selection = bool(data.get("selectable", false)) and not _core_read_only()
	frozen_sources = data.get("sources")
	return_stack = data.get("stack", []).duplicate(true)
	tab = str(data.get("tab", "materials"))
	category = str(data.get("category", "all"))
	only_star = bool(data.get("star", false))
	sort_by = str(data.get("sort", "order"))
	read_positions = data.get("positions", {}).duplicate(true)
	library_positions = data.get("library_positions", {}).duplicate(true)
	library_pages = data.get("library_pages", {}).duplicate()
	filters_open = bool(data.get("filters_open", false))
	selected_person = str(data.get("person", ""))
	selected_material = str(data.get("selected_material", ""))
	if not session.case_state.owns(selected_material): selected_material = ""
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
	library_pages.clear()
	read_positions.clear()
	return_stack.clear()
	selected_person = ""
	selected_material = ""
	new_list.clear()
	source_document.clear()
	reading_content = ""
	reading_entry = false
	compact_mode = false
	filters_open = false
	hide()

func bind(value: Node) -> void:
	session = value
	# 手册使用高900的文字参考空间；自己的主题也用参考字号，避免继承显示主题后再缩一次。
	theme = PaperTheme.build(session.config)
	var base := str(session.config.definition.root)
	var layout = JSON.parse_string(FileAccess.get_file_as_string(base.path_join("design/handbook/ui_layout.json")))
	if layout is Dictionary: layout_records = layout.get("records", [])
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(base.path_join("design/ui_20261018/adopted_assets.json")))
	if manifest is Dictionary:
		for row in manifest.get("assets", []): assets[str(row.asset_id)] = session.config.resource_path(str(row.get("runtime_path", "")))
	resized.connect(_request_render)
	hide()

func _request_render() -> void:
	if not visible or queued: return
	queued = true
	call_deferred("_render")

func open_library() -> void:
	reading_content = ""
	reading_entry = false
	return_stack.clear()
	allow_selection = false
	frozen_sources = null
	source_document.clear()
	show()
	_render()

func open_records() -> void:
	tab = "records"
	open_library()

func open_content(id: String, from_entry: bool = false, selectable: bool = false, sources = null) -> void:
	if not session.config.contents.has(id) or (not from_entry and not session.case_state.owns(id)): return
	reading_content = id
	source_document.clear()
	reading_entry = from_entry
	allow_selection = selectable and not _core_read_only()
	frozen_sources = sources.duplicate(true) if sources is Array else null
	show()
	_render()

func _render() -> void:
	queued = false
	if not is_instance_valid(session) or size.x <= 0 or size.y <= 0: return
	UI.clear(self)
	# 完整工具层独占输入，包括纸面之外；不能穿透到后方手牌、场景与常驻入口。
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.name = "HandbookInputShield"
	shade.color = Color(0.08, 0.10, 0.09, 0.68)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	canvas = Control.new()
	canvas.name = "HandbookCanvas"
	# 字号只随有效高度适配，窄比例减少缩略项数量，不把整页按宽度继续压小。
	canvas.clip_contents = true
	var factor := size.y / 900.0
	canvas.size = Vector2(size.x / factor, 900)
	canvas.scale = Vector2.ONE * factor
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.name = "HandbookPaperPanel"
	var frame := _layout_rect("UI_DETAIL_PAGE" if not reading_content.is_empty() or not source_document.is_empty() else "UI_RECORD")
	panel.position = frame.position
	panel.size = frame.size
	panel_size = frame.size
	# 纸面保留原图边缘，正文使用交付规格48/40/48/44安全区。
	panel.add_theme_stylebox_override("panel", PaperTheme.surface(assets, "PAPER_V2_panel_paper", [32, 32, 32, 36], [0, 0, 0, 0], 1.0))
	canvas.add_child(panel)
	var margin := MarginContainer.new()
	for edge in ["left", "right"]: margin.add_theme_constant_override("margin_" + edge, 48)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 44)
	panel.add_child(margin)
	root_box = VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 12)
	root_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root_box)
	var heading := HBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.add_child(heading)
	var heading_text := UI.label(heading, str(source_document.get("title", "办案手册" if reading_content.is_empty() else str(session.config.contents[reading_content].name))), 28)
	heading_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_text.max_lines_visible = 2
	if not source_document.is_empty(): _source_reading()
	elif not reading_content.is_empty(): _reading()
	else: _library()

func _layout_rect(control_id: String) -> Rect2:
	var reference_width := canvas.size.x
	var aspect := 1
	var distance := INF
	for pair in [[1, 1600.0], [2, 1440.0], [3, 1200.0], [4, 2100.0]]:
		if absf(reference_width - pair[1]) < distance:
			aspect = pair[0]
			distance = absf(reference_width - pair[1])
	for row in layout_records:
		if str(row.get("control_id", "")) == control_id and int(row.get("aspect_ratio", 0)) == aspect:
			var width := minf(float(row.width), reference_width - 64.0)
			var height := minf(float(row.height), 812.0)
			return Rect2(Vector2((reference_width - width) / 2.0 + float(row.offset_x), (900.0 - height) / 2.0 + float(row.offset_y)), Vector2(width, height))
	return Rect2(Vector2(32, 48), Vector2(reference_width - 64, 804))

func _library() -> void:
	var tabs := HFlowContainer.new()
	root_box.add_child(tabs)
	for pair in [["materials", "材料"], ["records", "交谈记录"], ["people", "人物"]]: _reading_button(tabs, pair[1], func(): tab = pair[0]; _render())
	if tab == "materials":
		_reading_button(tabs, "收起筛选" if filters_open else "筛选与排序", func(): filters_open = not filters_open; _render())
		_reading_button(tabs, "新推论", _open_new, not _new_contents().is_empty())
	var scroll := ScrollContainer.new()
	scroll.name = "HandbookLibraryScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)
	library_scroll = scroll
	var scroll_key := tab + "/" + category
	scroll.set_deferred("scroll_vertical", int(library_positions.get(scroll_key, 0)))
	scroll.get_v_scroll_bar().value_changed.connect(func(value): library_positions[scroll_key] = value)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.x = _reading_content_width()
	list.add_theme_constant_override("separation", 12)
	scroll.add_child(list)
	if tab == "materials":
		if filters_open: _filters(list)
		var ids := _material_ids()
		if not ids.is_empty() and not _selection_in(ids): selected_material = str(session.case_state.data.materials[ids[0]].current)
		if not ids.is_empty(): _material_preview(list)
		var grid := GridContainer.new()
		grid.name = "MaterialThumbnails"
		grid.columns = material_page_capacity()
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		list.add_child(grid)
		var page_count := maxi(1, ceili(float(ids.size()) / material_page_capacity()))
		var current_page := clampi(int(library_pages.get(category, 0)), 0, page_count - 1)
		library_pages[category] = current_page
		for id in ids.slice(current_page * material_page_capacity(), (current_page + 1) * material_page_capacity()):
			var record: Dictionary = session.case_state.data.materials[id]
			var content_id := str(record.current)
			var row: Dictionary = session.config.contents[content_id]
			var button := UI.button(grid, "", _select_library_content.bind(content_id))
			button.name = "Material_" + content_id
			button.custom_minimum_size = Vector2(_thumbnail_width(), 140)
			button.set_meta("tutorial_target", content_id)
			button.tooltip_text = str(row.description)
			var thumb := VBoxContainer.new()
			thumb.position = Vector2(8, 7)
			thumb.size = Vector2(_thumbnail_width() - 16, 126)
			thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			button.add_child(thumb)
			_picture(thumb, str(row.get("image_ref", "")), Vector2(0, 64))
			var title := UI.label(thumb, ("✓ " if selected_material == content_id else "") + str(row.name), 18)
			title.max_lines_visible = 2
			title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			title.mouse_filter = Control.MOUSE_FILTER_IGNORE
			if selected_material == content_id: button.add_theme_stylebox_override("normal", button.get_theme_stylebox("pressed"))
		if ids.is_empty(): UI.label(list, "尚未取得材料" if session.case_state.data.materials.is_empty() else "没有符合筛选的材料 · 0/0", 24)
		var paging := HBoxContainer.new()
		root_box.add_child(paging)
		_reading_button(paging, "上一页", _move_library_page.bind(-1), current_page > 0)
		var page_label := UI.label(paging, "%d / %d" % [current_page + 1, page_count], 22)
		page_label.custom_minimum_size = Vector2(80, 48)
		page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_reading_button(paging, "下一页", _move_library_page.bind(1), current_page + 1 < page_count)
		var detail := _reading_button(paging, "详察当前材料", _open_library_content.bind(selected_material), session.case_state.owns(selected_material))
		detail.set_meta("tutorial_target", "handbook.current_detail")
		_reading_button(paging, "关闭手册", close_page)
	elif tab == "people":
		_people(list)
		_reading_button(root_box, "关闭手册", close_page)
	else:
		_reading_button(root_box, "回到最新", func(): scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value)), not session.narrative.visible_history().is_empty())
		for row in session.narrative.visible_history():
			if str(row.get("text", "")).is_empty(): continue
			UI.label(list, str(row.get("speaker_name", "")), 22)
			_prose(list, str(row.text))
		# 交谈记录默认定位到最新段落，而不是停在最早处（反馈#19）。
		if not library_positions.has(scroll_key): _scroll_records_to_latest()
		_reading_button(root_box, "关闭手册", close_page)

func material_page_capacity() -> int:
	return clampi(int((_reading_content_width() + 10.0) / 124.0), 4, 10)

func _thumbnail_width() -> float:
	return floorf((_reading_content_width() - (material_page_capacity() - 1) * 10.0) / material_page_capacity())

func _selection_in(ids: Array) -> bool:
	for id in ids:
		if session.case_state.data.materials[id].current == selected_material: return true
	return false

func _move_library_page(delta: int) -> void:
	library_pages[category] = int(library_pages.get(category, 0)) + delta
	_render()

func _material_preview(parent: Control) -> void:
	var row: Dictionary = session.config.contents[selected_material]
	var record: Dictionary = session.case_state.data.materials[row.material_id]
	var preview := HBoxContainer.new()
	preview.name = "SelectedMaterialPreview"
	preview.add_theme_constant_override("separation", 24)
	preview.custom_minimum_size.y = 176
	parent.add_child(preview)
	_picture(preview, str(row.get("image_ref", "")), Vector2(168, 160))
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview.add_child(detail)
	var name_label := UI.label(detail, str(row.name), 28)
	name_label.max_lines_visible = 2
	var mark := "已读" if record.read.get(selected_material, false) else ("更新" if record.read.values().has(true) else "新")
	var types := {"evidence": "证据", "testimony": "证言", "inference": "推论"}
	UI.label(detail, "%s · 第%d版 · %s" % [types.get(session.config.materials[row.material_id].type, "材料"), int(row.version), mark], 20)
	var summary := UI.label(detail, str(row.description), 23)
	summary.max_lines_visible = 3
	# 浏览缩略项和预览不会把原件标已读；明确详察才进入阅读。
	if not _core_read_only(): _reading_button(detail, "★ 重点" if record.star else "☆ 标为重点", _star.bind(str(row.material_id)))

func _scroll_records_to_latest() -> void:
	# 滚动条 max_value 要等本帧布局完成后才正确；call_deferred 仍可能早于容器排序，等到下一帧再读。
	if is_instance_valid(library_scroll) and library_scroll.is_inside_tree():
		library_scroll.get_tree().process_frame.connect(_apply_records_latest, CONNECT_ONE_SHOT)

func _apply_records_latest() -> void:
	if is_instance_valid(library_scroll):
		library_scroll.scroll_vertical = int(library_scroll.get_v_scroll_bar().max_value)

func _reading() -> void:
	var row: Dictionary = session.config.contents[reading_content]
	# 详情使用单一内容流：图片、正文、版本、来源和操作都在同一个滚动区域内。
	# 这样不会出现图片在上一页、按钮被挤到下一页的断裂布局。
	var scroll := ScrollContainer.new()
	scroll.name = "HandbookReadingScroll"
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
		picture.custom_minimum_size = Vector2(0, 170)
		picture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pages.add_child(picture)
	_prose(pages, str(row.detail_text))
	# 回执位于全文下面。未阅读就返回不会触发completion_event或发卡。
	var content_actions := HFlowContainer.new()
	content_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_actions.custom_minimum_size.x = _reading_content_width()
	content_actions.add_theme_constant_override("h_separation", 6)
	content_actions.add_theme_constant_override("v_separation", 4)
	pages.add_child(content_actions)
	if reading_entry: _reading_button(pages, "已读完这份原件", _complete_reading)
	else:
		var id := str(row.material_id)
		var record: Dictionary = session.case_state.data.materials[id]
		record.read[reading_content] = true
		if not _core_read_only(): _reading_button(content_actions, "取消重点" if record.star else "标为重点", func(): record.star = not record.star; _render())
		if allow_selection and not _core_read_only():
			_reading_button(content_actions, "选择这份材料", func(): content_selected.emit(reading_content); close_page())
		var versions_title := UI.label(pages, "实际取得的版本", 22)
		versions_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var versions: Array = record.versions.keys()
		versions.sort_custom(func(a, b): return int(session.config.contents[a].version) > int(session.config.contents[b].version))
		var version_actions := HFlowContainer.new()
		version_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		version_actions.custom_minimum_size.x = _reading_content_width()
		version_actions.add_theme_constant_override("h_separation", 6)
		version_actions.add_theme_constant_override("v_separation", 4)
		pages.add_child(version_actions)
		for version in versions:
			_reading_button(version_actions, str(session.config.contents[version].name) + " · 第%d版" % int(session.config.contents[version].version), _push_content.bind(str(version)), versions.size() > 1 and version != reading_content)
		var sources_title := UI.label(pages, "来源", 22)
		sources_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var source_actions := HFlowContainer.new()
		source_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		source_actions.custom_minimum_size.x = _reading_content_width()
		source_actions.add_theme_constant_override("h_separation", 6)
		source_actions.add_theme_constant_override("v_separation", 4)
		pages.add_child(source_actions)
		for source in (frozen_sources if frozen_sources is Array else record.versions[reading_content]): _source(source_actions, source)
	scroll.set_deferred("scroll_vertical", int(read_positions.get(reading_content, 0)))
	scroll.get_v_scroll_bar().value_changed.connect(func(value): read_positions[reading_content] = value)
	var actions := HFlowContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.custom_minimum_size.x = _reading_content_width()
	actions.add_theme_constant_override("h_separation", 6)
	actions.add_theme_constant_override("v_separation", 4)
	# 返回与关闭固定在滚动区外，长原文、长来源和大图不能把退出入口推到屏外。
	root_box.add_child(actions)
	_reading_button(actions, "取消阅读" if reading_entry else ("上一级" if not return_stack.is_empty() else "返回"), _back)
	if not reading_entry: _reading_button(actions, "关闭阅读", close_page)
	if not new_list.is_empty() and reading_content in new_list:
		var controls := HFlowContainer.new()
		controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		controls.custom_minimum_size.x = _reading_content_width()
		controls.add_theme_constant_override("h_separation", 6)
		pages.add_child(controls)
		_reading_button(controls, "前一项", _new_move.bind(-1), new_index > 0)
		UI.label(controls, "%d / %d" % [new_index + 1, new_list.size()])
		_reading_button(controls, "后一项", _new_move.bind(1), new_index + 1 < new_list.size())

func _source(parent: Control, source: Dictionary) -> void:
	var label := str(source.get("entry", source.get("question", "实际调查")))
	if source.has("text"): label = session.config.text(str(source.text))
	_reading_button(parent, label, _push_source.bind(source))
	for item in source.get("sources", []):
		var id := str(item.get("content_id", ""))
		if session.case_state.owns(id): _reading_button(parent, "依据 · " + str(session.config.contents[id].name), _push_content.bind(id, item.get("sources", [])))

func _reading_button(parent: Control, text: String, action: Callable, enabled: bool = true) -> Button:
	# 详情页按钮统一限制在内容列内，长文案自动换行，不能撑出手册面板。
	var node := UI.button(parent, text, action, enabled)
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 自动换行按钮的固有宽度只有最短词宽；用整条标签测量，保证普通操作保持横排。
	var text_width := node.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	node.custom_minimum_size = Vector2(minf(_reading_content_width(), maxf(120, text_width + 44)), 48)
	node.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	node.add_theme_font_size_override("font_size", 22)
	return node

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
	if reading_content.is_empty() and source_document.is_empty(): close_page()
	else: _back()
	return true

func _prose(parent: Control, text: String) -> RichTextLabel:
	var label := UI.body(parent, text, 0)
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	label.custom_minimum_size = Vector2(1, 0)
	label.add_theme_font_size_override("normal_font_size", 24)
	return label

func _reading_content_width() -> float:
	# ScrollContainer 的子节点必须明确小于视口宽度，否则长文会把
	# RichTextLabel 和 HFlowContainer 撑宽，产生屏幕外文案或横向溢出。
	return maxf(1.0, panel_size.x - 48.0 * 2.0 - 24.0)

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

func _filters(parent: Control) -> void:
	var filters := HFlowContainer.new()
	filters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(filters)
	for pair in [["all", "全部"], ["evidence", "证据"], ["testimony", "证言"], ["inference", "推论"]]: _reading_button(filters, pair[1], func(): category = pair[0]; _render())
	for pair in [["order", "获得顺序"], ["name", "名称"], ["type", "类型"]]: _reading_button(filters, pair[1], func(): sort_by = pair[0]; _render())
	_reading_button(filters, "仅重点 ✓" if only_star else "仅重点", func(): only_star = not only_star; _render())
	_reading_button(filters, "重置筛选", func(): category = "all"; sort_by = "order"; only_star = false; library_positions.clear(); library_pages.clear(); _render())

func _star(id: String) -> void:
	if _core_read_only(): return
	var record: Dictionary = session.case_state.data.materials[id]
	record.star = not record.star
	_render()

func _core_read_only() -> bool:
	return session.mode in ["selection", "result", "failure"]

func _open_library_content(id: String) -> void:
	return_stack.clear()
	new_list.clear()
	open_content(id)

func _select_library_content(id: String) -> void:
	if not session.case_state.owns(id): return
	selected_material = id
	_render()

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
	var detail := HBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 24)
	parent.add_child(detail)
	var selected: Dictionary = session.config.profiles[session.case_state.data.profiles[selected_person]]
	_picture(detail, str(selected.portrait_ref), Vector2(200, 220))
	var biography := VBoxContainer.new()
	biography.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_child(biography)
	UI.label(biography, str(selected.display_name), 30)
	UI.label(biography, str(selected.identity_text), 24)
	_prose(biography, str(selected.bio_text))
	var grid := GridContainer.new()
	grid.name = "PeopleThumbnails"
	grid.columns = clampi(int((_reading_content_width() + 12.0) / 190.0), 2, 6)
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	parent.add_child(grid)
	for person in people:
		var profile: Dictionary = session.config.profiles[session.case_state.data.profiles[person]]
		var card := VBoxContainer.new()
		card.custom_minimum_size = Vector2(floorf((_reading_content_width() - (grid.columns - 1) * 12) / grid.columns), 170)
		grid.add_child(card)
		_picture(card, str(profile.avatar_ref), Vector2(96, 112))
		_reading_button(card, ("✓ " if person == selected_person else "") + str(profile.display_name), func(): selected_person = person; _render())

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
		if session.case_state.owns(id): _reading_button(box, str(session.config.contents[id].name), _push_content.bind(id, item.get("sources", [])))
	var actions := HFlowContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.custom_minimum_size.x = _reading_content_width()
	root_box.add_child(actions)
	_reading_button(actions, "上一级", _back)
	_reading_button(actions, "关闭来源与阅读", close_page)
