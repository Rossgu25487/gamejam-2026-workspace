extends VBoxContainer
## 调查页只负责显示热点和覆盖层；资格、观察提交和返回上下文由调查服务处理。

const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var scene_service: Node
var focus_key := ""
var overlay: PopupPanel
var overlay_box: VBoxContainer
var overlay_request_id := ""
var overlay_hotspot_id := ""
var overlay_person_ref := ""

func bind_scene_service(value: Node) -> void:
	scene_service = value
	if scene_service != null and not scene_service.changed.is_connected(_queue_scene_refresh): scene_service.changed.connect(_queue_scene_refresh)

func _queue_scene_refresh() -> void:
	if service != null: call_deferred("render", service)

func render(core: Node, image_buttons: Dictionary = {}, image_bindings: Dictionary = {}) -> void:
	service = core
	UI.clear(self)
	var data: Dictionary = core.catalog.data
	var state: Dictionary = core.state
	UI.label(self, core.catalog.text(data.scenes[state.current_scene_id].name), 28)
	UI.label(self, core.catalog.text("package_note"), 16)
	if state.mode == "dialogue":
		var entry: Dictionary = data.entries[state.current_node_id]
		var character_id: String = entry.get("object_id", "")
		if data.characters.has(character_id): UI.label(self, core.catalog.text(data.characters[character_id].name), 22)
		UI.body(self, core.catalog.text(entry.text), 240)
		UI.button(self, core.ui("UI_RETURN_INVESTIGATION"), core.finish_dialogue)
		return
	if scene_service != null and not scene_service.state.is_empty():
		_render_scene_hotspots(core)
		return
	var scroll := ScrollContainer.new()
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var list := VBoxContainer.new()
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 12)
	scroll.add_child(list)
	if not image_buttons.is_empty():
		# 给按屏幕坐标摆放的图片卡留出空间；问题和移动按钮接着排在下方。
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bottom := 0.0
		for b in image_buttons.values(): bottom = maxf(bottom, b.get_global_rect().end.y)
		spacer.custom_minimum_size.y = maxf(0, bottom - get_global_rect().position.y - 65)
		list.add_child(spacer)
	for id in data.entries:
		var entry: Dictionary = data.entries[id]
		if not str(entry.get("scene_id", "")).is_empty() and entry.scene_id != state.current_scene_id: continue
		if image_bindings.has(id): continue
		var b := UI.button(list, core.catalog.text(entry.title), _activate.bind(id), core.condition_met(entry.condition))
		b.set_meta("focus_key", id)
	UI.label(list, "待核问题", 24)
	for id in data.questions:
		var q: Dictionary = data.questions[id]
		if not str(q.get("scene_id", "")).is_empty() and q.scene_id != state.current_scene_id: continue
		var completed: bool = id in state.completed_questions
		var b := UI.button(list, core.catalog.text(q.title) + (" · 回看" if completed else ""), _question.bind(id), core.condition_met(q.condition))
		b.set_meta("focus_key", id)
	for id in data.get("scene_links", {}):
		var link: Dictionary = data.scene_links[id]
		if link.from_scene != state.current_scene_id: continue
		var b := UI.button(list, core.catalog.text(link.title), core.move_scene.bind(id), core.condition_met(link.condition))
		b.set_meta("focus_key", id)
	var completion: String = data.get("completion_condition", "")
	if not completion.is_empty() and core.condition_met(completion): UI.label(list, core.catalog.text(data.completion_text), 22)
	_restore_focus(list)
	if image_buttons.has(focus_key) and not image_buttons[focus_key].disabled: image_buttons[focus_key].grab_focus()

func _render_scene_hotspots(core: Node) -> void:
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	add_child(list)
	var hotspots: Array = scene_service.hotspots_for_scene(str(core.state.get("current_scene_id", "")))
	if hotspots.is_empty():
		UI.label(list, "当前场景暂无可调查对象。", 20)
	else:
		UI.label(list, "场景对象", 24)
		for item in hotspots:
			var text := "%s · %s" % [str(item.public_name), str(item.status)]
			if not item.interactive: text += "（" + str(item.public_reason) + "）"
			var button := UI.button(list, text, _activate_hotspot.bind(str(item.hotspot_id)), bool(item.interactive))
			button.tooltip_text = text
			button.focus_mode = Control.FOCUS_ALL
			button.set_meta("focus_key", item.hotspot_id)
			if item.hotspot_id == scene_service.state.get("focus_ref", ""): button.grab_focus()
	UI.label(list, "待核问题", 24)
	for id in core.catalog.data.questions:
		var q: Dictionary = core.catalog.data.questions[id]
		if not str(q.get("scene_id", "")).is_empty() and q.scene_id != core.state.current_scene_id: continue
		var completed: bool = id in core.state.completed_questions
		var b := UI.button(list, core.catalog.text(q.title) + (" · 回看" if completed else ""), _question.bind(id), core.condition_met(q.condition))
		b.set_meta("focus_key", id)
	for id in core.catalog.data.get("scene_links", {}):
		var link: Dictionary = core.catalog.data.scene_links[id]
		if link.from_scene != core.state.current_scene_id: continue
		UI.button(list, core.catalog.text(link.title), core.move_scene.bind(id), core.condition_met(link.condition))
	_restore_focus(list)

func _activate_hotspot(hotspot_id: String) -> void:
	if scene_service == null: return
	focus_key = hotspot_id
	scene_service.set_focus(hotspot_id)
	var item: Dictionary = scene_service.hotspot_state(hotspot_id)
	if item.is_empty() or not item.interactive: return
	if item.object_kind == "character" and not str(item.topic_entry_ref).is_empty():
		_open_topics(str(item.object_ref), hotspot_id)
	else:
		_open_inspection(hotspot_id)

func _popup(title: String) -> void:
	if is_instance_valid(overlay): overlay.queue_free()
	overlay = PopupPanel.new()
	overlay.name = "InvestigationOverlay"
	overlay.exclusive = true
	overlay.size = Vector2i(720, 520)
	overlay_box = VBoxContainer.new()
	overlay_box.add_theme_constant_override("separation", 12)
	overlay.add_child(overlay_box)
	get_tree().root.add_child(overlay)
	overlay.popup_centered()

func _open_inspection(hotspot_id: String) -> void:
	var result: Dictionary = scene_service.begin_inspection(hotspot_id, {"scene_id": service.state.current_scene_id, "focus_ref": hotspot_id})
	if not result.get("ok", false): return
	overlay_request_id = str(result.request_id)
	overlay_hotspot_id = hotspot_id
	_popup("检查")
	UI.label(overlay_box, str(result.hotspot.public_name), 28)
	var entry: Dictionary = service.catalog.data.entries.get(str(result.entry_ref), {})
	UI.body(overlay_box, service.catalog.text(entry.get("text", "暂无观察正文。")), 220)
	var actions := HBoxContainer.new()
	overlay_box.add_child(actions)
	UI.button(actions, "确认检查结果", _commit_inspection)
	UI.button(actions, "返回调查", _cancel_inspection)
	if overlay_box.get_child_count() > 1: overlay_box.get_child(1).get_child(0).grab_focus()

func _commit_inspection() -> void:
	if scene_service == null or overlay_request_id.is_empty(): return
	var result: Dictionary = scene_service.commit_inspection(overlay_request_id, true)
	if result.get("ok", false): _close_overlay()

func _cancel_inspection() -> void:
	if scene_service != null and not overlay_request_id.is_empty(): scene_service.cancel_inspection(overlay_request_id)
	_close_overlay()

func _open_topics(person_ref: String, hotspot_id: String) -> void:
	overlay_person_ref = person_ref
	overlay_hotspot_id = hotspot_id
	_popup("人物话题")
	var title := person_ref
	if service.catalog.data.characters.has(person_ref): title = service.catalog.text(service.catalog.data.characters[person_ref].name)
	UI.label(overlay_box, title, 28)
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	overlay_box.add_child(list)
	var items: Array = scene_service.topics_for_person(person_ref)
	if items.is_empty():
		for entry_id in service.catalog.data.entries:
			var entry: Dictionary = service.catalog.data.entries[entry_id]
			if entry.get("object_id", "") != person_ref: continue
			items.append({"topic_ref": entry_id, "public_name": service.catalog.text(entry.title), "entry_ref": entry_id, "interactive": service.condition_met(entry.condition), "public_reason": "当前无法回答"})
	var visible_rows := int(scene_service.display.get("topic_visible_rows", 5))
	var shown := 0
	for item in items:
		if shown >= visible_rows: break
		var enabled := bool(item.get("interactive", false)) and not str(item.get("entry_ref", "")).is_empty()
		var b := UI.button(list, str(item.get("public_name", "话题")) + ("（" + str(item.get("public_reason", "")) + "）" if not enabled else ""), _choose_topic.bind(item), enabled)
		b.tooltip_text = str(item.get("public_reason", ""))
		shown += 1
	var close := UI.button(overlay_box, "返回调查", _close_overlay)
	close.grab_focus()

func _choose_topic(item: Dictionary) -> void:
	var entry_ref := str(item.get("entry_ref", ""))
	if entry_ref.is_empty(): return
	_close_overlay()
	service.activate_entry(entry_ref)

func _close_overlay() -> void:
	overlay_request_id = ""
	if is_instance_valid(overlay):
		overlay.hide()
		overlay.queue_free()
		overlay = null
	if scene_service != null:
		scene_service.set_focus(overlay_hotspot_id)
		call_deferred("render", service)

func activate_entry(id: String) -> void:
	# 图片入口和文字入口共用同一个页面动作，业务由服务再次校验。
	_activate(id)

func _activate(id: String) -> void:
	focus_key = id
	service.activate_entry(id)

func _question(id: String) -> void:
	focus_key = id
	service.open_card_session(id, {"page": "investigation", "focus_key": id, "scene_id": service.state.current_scene_id})

func _restore_focus(list: Node) -> void:
	for node in list.get_children():
		if node is Button and not node.disabled and node.get_meta("focus_key", "") == focus_key:
			node.grab_focus()
