extends VBoxContainer
## 调查页只负责显示热点和覆盖层；资格、观察提交和返回上下文由调查服务处理。

signal refresh_requested

const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var scene_service: Node
var focus_key := ""
var overlay: PopupPanel
var overlay_box: VBoxContainer
var overlay_request_id := ""
var overlay_hotspot_id := ""
var overlay_person_ref := ""
var topic_return := {}
var scene_frame: Control
var scene_canvas: Control

func _ready() -> void:
	# 场景坐标跟随整个窗口，工具栏、提示和目标面板改变布局时也要保持原位。
	item_rect_changed.connect(_layout_scene_canvas)
	get_viewport().size_changed.connect(_layout_scene_canvas)

func _layout_scene_canvas() -> void:
	if is_instance_valid(scene_frame) and scene_frame.is_inside_tree() and is_instance_valid(scene_canvas):
		_resize_canvas(scene_frame, scene_canvas)

func bind_scene_service(value: Node) -> void:
	scene_service = value
	if scene_service != null and not scene_service.changed.is_connected(_queue_scene_refresh): scene_service.changed.connect(_queue_scene_refresh)

func _queue_scene_refresh() -> void:
	# 由持有页同步重建图片层和文字层，避免覆盖页隐藏期间计算旧坐标。
	if service != null: refresh_requested.emit()

func render(core: Node, image_buttons: Dictionary = {}, image_bindings: Dictionary = {}) -> void:
	if not is_instance_valid(core) or core.state.is_empty(): return
	service = core
	UI.clear(self)
	var data: Dictionary = core.catalog.data
	var state: Dictionary = core.state
	UI.label(self, core.catalog.text(data.scenes[state.current_scene_id].name), 28)
	if core.get_parent().configuration == null: UI.label(self, core.catalog.text("package_note"), 16)
	if state.mode == "dialogue":
		var entry: Dictionary = data.entries[state.current_node_id]
		var character_id: String = entry.get("object_id", "")
		if data.characters.has(character_id): UI.label(self, core.catalog.text(data.characters[character_id].name), 22)
		UI.body(self, core.catalog.text(entry.text), 240)
		UI.button(self, core.ui("UI_RETURN_INVESTIGATION"), _finish_dialogue)
		return
	if scene_service != null and not scene_service.state.is_empty() and not scene_service.compatibility_mode:
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
	UI.button(list, "地图", _open_map)
	_cat_entries(list)
	if not image_buttons.is_empty():
		# 给按屏幕坐标摆放的图片卡留出空间；问题和移动按钮接着排在下方。
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		list.add_child(spacer)
		call_deferred("_reserve_image_space", spacer, image_buttons.values())
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

func _render_questions(list: Node, core: Node) -> void:
	UI.label(list, "待核问题", 24)
	for id in core.catalog.data.questions:
		var q: Dictionary = core.catalog.data.questions[id]
		if not str(q.get("scene_id", "")).is_empty() and q.scene_id != core.state.current_scene_id: continue
		UI.button(list, core.catalog.text(q.title) + (" · 回看" if id in core.state.completed_questions else ""), _question.bind(id), core.condition_met(q.condition))
	var condition := str(core.catalog.data.get("completion_condition", ""))
	if not condition.is_empty() and core.condition_met(condition):
		UI.label(list, core.catalog.text(core.catalog.data.completion_text), 22)
		if core.get_parent().configuration != null: UI.button(list, "确认结束交接演练", core.get_parent().start_closing)

func _render_configured_canvas() -> void:
	# 图片与命中区分别来自调查表，同处1600×900逻辑坐标；页面只负责绘制。
	# Node2D不参与VBox排版，且随调查页一起隐藏。场景用完整窗口缩放，
	# 不让问题列表或目标面板把背景、人物和热点挤成中间的缩略图。
	var scene_layer := Node2D.new()
	scene_layer.z_as_relative = false
	scene_layer.z_index = -128 # 整组场景在共用UI之后，组内保留图片与热点的前后顺序。
	add_child(scene_layer)
	var frame := Control.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scene_layer.add_child(frame)
	scene_frame = frame
	var session := service.get_parent()
	var scene: Dictionary = session.map_navigation.locations.get(service.state.current_scene_id, {})
	var host: Dictionary = session.map_navigation.map_definition.get("resources", {}).get(scene.get("scene_resource_ref", ""), {})
	var canvas := Control.new()
	if not str(host.get("path", "")).is_empty():
		var packed = load(str(host.path))
		if packed is PackedScene:
			var instance: Node = packed.instantiate()
			if instance is Control:
				canvas.free()
				canvas = instance
			else: instance.free()
	canvas.size = Vector2(float(scene_service.display.canvas_width), float(scene_service.display.canvas_height))
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(canvas)
	scene_canvas = canvas
	call_deferred("_layout_scene_canvas")
	var resource: Dictionary = session.map_navigation.map_definition.get("resources", {}).get(scene.get("background_ref", ""), {})
	_canvas_image(canvas, str(resource.get("path", "")), Rect2(Vector2.ZERO, canvas.size), 0)
	for row in scene_service.object_images.values():
		if row.scene_id != service.state.current_scene_id or not scene_service.state.object_visibility.get(row.object_ref, true): continue
		_canvas_image(canvas, str(row.image_path), Rect2(float(row.image_x), float(row.image_y), float(row.image_w), float(row.image_h)), int(row.draw_layer))
	for item in scene_service.hotspots_for_scene():
		var button := Button.new()
		button.flat = true
		button.position = Vector2(item.x, item.y)
		button.size = Vector2(item.w, item.h)
		button.z_index = 20 + int(item.hit_priority)
		button.tooltip_text = str(item.public_name) + " · " + str(item.status)
		button.disabled = not item.interactive
		button.set_meta("hotspot_id", item.hotspot_id)
		canvas.add_child(button)
		button.pressed.connect(_activate_hotspot.bind(str(item.hotspot_id)))
		if item.hotspot_id == focus_key: _focus_overlay_control.call_deferred(button)
	if session.configuration != null:
		for binding in session.configuration.definition.get("canvas_objects", []):
			if binding.scene_id != service.state.current_scene_id: continue
			var rect := Rect2(float(binding.x), float(binding.y), float(binding.w), float(binding.h))
			var path: String = session.configuration.resource_path(str(binding.image_path))
			if binding.kind == "character":
				_canvas_image(canvas, path, rect, 10)
				continue
			if binding.kind != "cat": continue
			var entry := {}
			for candidate in session.cat_entries():
				if candidate.id == binding.target_ref: entry = candidate
			if entry.is_empty(): continue
			var cat_button := TextureButton.new()
			cat_button.texture_normal = load(path)
			cat_button.ignore_texture_size = true
			cat_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
			cat_button.position = rect.position
			cat_button.size = rect.size
			cat_button.tooltip_text = str(entry.title)
			cat_button.disabled = not entry.enabled
			canvas.add_child(cat_button)
			cat_button.pressed.connect(session.enter_cat.bind(str(entry.id)))

func _canvas_image(canvas: Control, path: String, rect: Rect2, layer: int) -> void:
	if path.is_empty() or not ResourceLoader.exists(path): return
	var image := TextureRect.new()
	image.texture = load(path)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.position = rect.position
	image.size = rect.size
	image.z_index = layer
	canvas.add_child(image)

func _resize_canvas(frame: Control, canvas: Control) -> void:
	if not is_instance_valid(frame) or not is_instance_valid(canvas): return
	# 与文案舞台采用相同的contain规则；非16:9窗口只在外缘留边。
	frame.size = get_viewport_rect().size
	frame.global_position = get_viewport_rect().position
	var factor := minf(frame.size.x / canvas.size.x, frame.size.y / canvas.size.y)
	canvas.scale = Vector2.ONE * factor
	canvas.position = (frame.size - canvas.size * factor) / 2

func _reserve_image_space(spacer: Control, buttons: Array) -> void:
	# Container 恢复显示后才有最终坐标；旧页的延迟回调不得影响新页。
	await get_tree().process_frame
	if not is_instance_valid(spacer) or not spacer.is_inside_tree() or not is_visible_in_tree(): return
	var bottom := spacer.get_global_rect().position.y
	for button in buttons:
		if is_instance_valid(button) and button.is_visible_in_tree(): bottom = maxf(bottom, button.get_global_rect().end.y)
	spacer.custom_minimum_size.y = maxf(0, bottom - spacer.get_global_rect().position.y + 12)

func _render_scene_hotspots(core: Node) -> void:
	if not scene_service.object_images.is_empty():
		_render_configured_canvas()
		var map_button := UI.button(self, "地图", _open_map)
		map_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		map_button.custom_minimum_size.x = 160
		# 问题只占左侧独立面板；长列表在面板内滚动，不移动调查画布。
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		panel.custom_minimum_size.x = minf(480.0, size.x)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.063, 0.106, 0.145, 0.9)
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]: style.set_content_margin(side, 12)
		panel.add_theme_stylebox_override("panel", style)
		add_child(panel)
		var question_scroll := ScrollContainer.new()
		question_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		panel.add_child(question_scroll)
		var questions := VBoxContainer.new()
		questions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		questions.add_theme_constant_override("separation", 10)
		question_scroll.add_child(questions)
		_render_questions(questions, core)
		call_deferred("_fit_questions", question_scroll, questions)
		return
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	UI.button(list, "地图", _open_map)
	_cat_entries(list)
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

func _fit_questions(scroll: ScrollContainer, questions: VBoxContainer) -> void:
	# 先取得面板实际宽度再量换行高度，避免把尚未排版的文字算成长列表。
	await get_tree().process_frame
	if is_instance_valid(scroll) and scroll.is_inside_tree() and is_instance_valid(questions):
		scroll.custom_minimum_size.y = minf(220.0, questions.get_combined_minimum_size().y)

func _cat_entries(list: Node) -> void:
	var session := service.get_parent()
	if session == null or not session.has_method("cat_entries"): return
	for entry in session.cat_entries():
		var button := UI.button(list, str(entry.title), session.enter_cat.bind(str(entry.id)), entry.enabled)
		button.tooltip_text = str(entry.reason)

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
	var confirm := UI.button(actions, "确认检查结果", _commit_inspection)
	UI.button(actions, "返回调查", _cancel_inspection)
	call_deferred("_focus_overlay_control", confirm)

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
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 260
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	overlay_box.add_child(scroll)
	scroll.add_child(list)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var items: Array = scene_service.topics_for_person(person_ref)
	if items.is_empty():
		for entry_id in service.catalog.data.entries:
			var entry: Dictionary = service.catalog.data.entries[entry_id]
			if entry.get("object_id", "") != person_ref: continue
			items.append({"topic_ref": entry_id, "public_name": service.catalog.text(entry.title), "entry_ref": entry_id, "interactive": service.condition_met(entry.condition), "public_reason": "当前无法回答"})
	for item in items:
		var enabled := bool(item.get("interactive", false)) and (not str(item.get("entry_ref", "")).is_empty() or not str(item.get("question_ref", "")).is_empty())
		var b := UI.button(list, str(item.get("public_name", "话题")) + ("（" + str(item.get("public_reason", "")) + "）" if not enabled else ""), _choose_topic.bind(item), enabled)
		b.tooltip_text = str(item.get("public_reason", ""))
		b.set_meta("topic_ref", str(item.get("topic_ref", "")))
	var close := UI.button(overlay_box, "返回调查", _close_overlay)
	call_deferred("_focus_overlay_control", close)

func _focus_overlay_control(control: Control) -> void:
	# Popup 的子节点要等加入场景树后才能可靠获取焦点；同时防止
	# 关闭弹层的同帧回调把按钮释放后仍继续调用 grab_focus。
	if is_instance_valid(control) and control.is_inside_tree() and control.visible and not control.disabled:
		control.grab_focus()

func _choose_topic(item: Dictionary) -> void:
	var question_ref := str(item.get("question_ref", ""))
	if not question_ref.is_empty():
		if service.open_card_session(question_ref, {"page": "investigation", "scene_id": service.state.current_scene_id}): _close_overlay()
		return
	var entry_ref := str(item.get("entry_ref", ""))
	if entry_ref.is_empty(): return
	var context := {"person_ref": overlay_person_ref, "hotspot_id": overlay_hotspot_id, "topic_ref": str(item.get("topic_ref", ""))}
	if scene_service.topics.has(context.topic_ref):
		if not scene_service.open_topic(context.topic_ref, context).get("ok", false): return
	# 准备和资格失败留在原话题页；成功后才关闭列表。
	if not service.get_parent().activate_entry(entry_ref): return
	topic_return = context
	_close_overlay()

func _finish_dialogue() -> void:
	service.finish_dialogue()
	if not topic_return.is_empty() and service.state.mode == "investigation":
		var context := topic_return.duplicate(true)
		topic_return = {}
		call_deferred("_restore_topics", context)

func _restore_topics(context: Dictionary) -> void:
	if not is_inside_tree() or service.state.mode != "investigation": return
	_open_topics(context.person_ref, context.hotspot_id)
	for button in overlay_box.find_children("*", "Button", true, false):
		if button.get_meta("topic_ref", "") == context.topic_ref: _focus_overlay_control(button)

func _close_overlay() -> void:
	overlay_request_id = ""
	if is_instance_valid(overlay):
		overlay.hide()
		overlay.queue_free()
		overlay = null
	if scene_service != null and is_instance_valid(service):
		scene_service.set_focus(overlay_hotspot_id)
		refresh_requested.emit()

func activate_entry(id: String) -> void:
	# 图片入口和文字入口共用同一个页面动作，业务由服务再次校验。
	_activate(id)

func open_inspection_entry(id: String) -> void:
	if scene_service == null: return
	for row in scene_service.hotspots.values():
		if row.get("inspect_entry_ref", "") == id:
			_activate_hotspot(str(row.hotspot_id))
			return

func reset_overlay() -> void:
	topic_return = {}
	if scene_service != null and not overlay_request_id.is_empty(): scene_service.cancel_inspection(overlay_request_id)
	_close_overlay()

func _exit_tree() -> void:
	# Popup 是独立窗口，生命周期必须随持有页结束。
	if is_instance_valid(overlay): overlay.queue_free()

func _activate(id: String) -> void:
	focus_key = id
	service.activate_entry(id)

func _question(id: String) -> void:
	focus_key = id
	service.open_card_session(id, {"page": "investigation", "focus_key": id, "scene_id": service.state.current_scene_id})

func _open_map() -> void:
	if service == null: return
	var page := get_parent().get_parent().get_parent()
	if page != null and page.has_method("open_map"): page.open_map()

func _restore_focus(list: Node) -> void:
	for node in list.get_children():
		if node is Button and not node.disabled and node.get_meta("focus_key", "") == focus_key:
			node.grab_focus()
