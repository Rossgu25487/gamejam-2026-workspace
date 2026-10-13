extends VBoxContainer
## 手册的交谈记录子页；筛选和正文滚动由本节点维护，阅读进度交回核心服务。

signal basis_requested(sources: Array)
const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var view: Dictionary
var segments: Array = []
var refreshing := false
var original: RichTextLabel
var summary: RichTextLabel
var list_scroll: ScrollContainer

func render(core: Node, saved_view: Dictionary) -> void:
	service = core
	view = saved_view
	_build()

func _build() -> void:
	# 先释放旧正文引用，空筛选不保留可被延迟调用写回的旧控件。
	original = null
	summary = null
	UI.clear(self)
	segments = service.talk_segments()
	var objects: Array = []
	for segment in segments:
		if not str(segment.object_id).is_empty() and segment.object_id not in objects: objects.append(segment.object_id)
	var topics: Array = []
	for segment in segments:
		if not str(view.object_id).is_empty() and segment.object_id != view.object_id: continue
		if segment.topic_id not in topics: topics.append(segment.topic_id)
	if not str(view.topic_id).is_empty() and view.topic_id not in topics: view.topic_id = ""
	var filters := HBoxContainer.new()
	add_child(filters)
	_option(filters, service.ui("UI_HANDBOOK_PERSON_ALL"), objects, "object_id")
	_option(filters, service.ui("UI_HANDBOOK_TOPIC_ALL"), topics, "topic_id")
	UI.button(filters, service.ui("UI_HANDBOOK_CLEAR"), _clear_filters, not segments.is_empty())
	var filtered: Array = []
	for segment in segments:
		if not str(view.object_id).is_empty() and segment.object_id != view.object_id: continue
		if not str(view.topic_id).is_empty() and segment.topic_id != view.topic_id: continue
		filtered.append(segment)
	if filtered.is_empty():
		view.segment_id = ""
		UI.label(self, service.ui("UI_HANDBOOK_EMPTY_RECORDS" if segments.is_empty() else "UI_HANDBOOK_RECORD_FILTER_EMPTY"), 20)
		return
	var selected: Dictionary = filtered[0]
	for segment in filtered:
		if segment.id == view.segment_id: selected = segment; break
	view.segment_id = selected.id
	for id in selected.record_ids: service.mark_talk_read(id)
	list_scroll = ScrollContainer.new()
	list_scroll.custom_minimum_size.y = 112
	add_child(list_scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(list)
	for segment in filtered:
		var marker: String = service.ui("UI_HANDBOOK_UNREAD" if segment.unread and segment.id != selected.id else "UI_HANDBOOK_READ")
		var title := "%s · %s · %s" % [_object_name(segment.object_id), service.catalog.text(segment.title_id), marker]
		var item := UI.button(list, title, _select_segment.bind(segment.id))
		item.tooltip_text = title
		item.set_meta("segment_id", segment.id)
	UI.label(self, service.ui("UI_HANDBOOK_ORIGINAL"), 22)
	var lines: Array[String] = []
	for record in selected.statements:
		lines.append("%s：%s" % [_object_name(record.speaker), service.catalog.text(record.text_id)])
	original = UI.body(self, "\n\n".join(lines), 105)
	original.get_v_scroll_bar().value_changed.connect(_remember_original.bind(selected.id))
	UI.label(self, service.ui("UI_HANDBOOK_SUMMARY") + " · " + service.ui("UI_HANDBOOK_CORRECTION"), 22)
	lines.clear()
	for record in selected.corrections:
		lines.append(service.catalog.text(record.text_id))
	for record in selected.corrected_statements:
		lines.append("%s · %s：%s" % [service.ui("UI_HANDBOOK_EFFECTIVE_CORRECTION"), _object_name(record.speaker), service.catalog.text(record.text_id)])
	summary = UI.body(self, "\n\n".join(lines), 75)
	summary.get_v_scroll_bar().value_changed.connect(_remember_summary.bind(selected.id))
	for record in selected.corrections:
		var sources: Array = record.get("record", {}).get("used_sources", [])
		UI.button(self, service.ui("UI_HANDBOOK_RECORD_SOURCE"), basis_requested.emit.bind(sources), not sources.is_empty())
	# 只有本段实际展示正文才记已读；列表预览和筛选不批量标记其他段。
	call_deferred("_restore_positions", selected.id)

func _option(parent: Node, all_text: String, ids: Array, key: String) -> void:
	var option := OptionButton.new()
	option.add_item(all_text)
	option.set_item_metadata(0, "")
	for id in ids:
		var name := _object_name(id) if key == "object_id" else _topic_name(id)
		option.add_item(name)
		option.set_item_metadata(option.item_count - 1, id)
	for i in range(option.item_count):
		if option.get_item_metadata(i) == view[key]: option.selected = i; break
	option.disabled = segments.is_empty()
	option.item_selected.connect(_filter.bind(option, key))
	parent.add_child(option)

func _filter(index: int, option: OptionButton, key: String) -> void:
	view[key] = str(option.get_item_metadata(index))
	_queue_refresh()

func _clear_filters() -> void:
	view.object_id = ""
	view.topic_id = ""
	_queue_refresh()

func _select_segment(id: String) -> void:
	view.segment_id = id
	_queue_refresh()

func _queue_refresh() -> void:
	# PopupMenu 的选中与焦点交接完成后再释放旧筛选控件。
	if refreshing: return
	refreshing = true
	call_deferred("_refresh")

func _refresh() -> void:
	refreshing = false
	if is_inside_tree(): _build()

func _object_name(id: String) -> String:
	return service.catalog.text(service.catalog.data.characters[id].name) if service.catalog.data.characters.has(id) else ""

func _topic_name(id: String) -> String:
	for segment in segments:
		if segment.topic_id == id: return service.catalog.text(segment.title_id)
	return ""

func _remember_original(value: float, id: String) -> void:
	view["original/" + id] = value

func _remember_summary(value: float, id: String) -> void:
	view["summary/" + id] = value

func _restore_positions(id: String) -> void:
	if not is_instance_valid(original) or id != view.segment_id: return
	original.get_v_scroll_bar().value = float(view.get("original/" + id, 0))
	summary.get_v_scroll_bar().value = float(view.get("summary/" + id, 0))
