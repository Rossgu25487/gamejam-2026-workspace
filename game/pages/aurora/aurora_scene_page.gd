extends Control
## 调查页面自行创建背景、人物物件、热点和检查目录；返回时只恢复原对象与合法话题。
const UI = preload("res://pages/core/page_controls.gd")
const Investigation = preload("res://systems/aurora/aurora_investigation.gd")
signal menu_requested
signal map_requested
signal handbook_requested
signal objectives_requested
signal cat_requested
signal context_changed
var session: Node
var model: RefCounted = Investigation.new()
var canvas: Control
var overlay: Control
var hint: Label
var queued := false
var current_context := {}
var texture_cache := {}
var notified_context := {}

func bind(value: Node) -> void:
	session = value
	model.bind(value)
	session.changed.connect(refresh)
	session.returned.connect(_on_returned)
	resized.connect(refresh)
	refresh()

func refresh() -> void:
	if queued or not is_inside_tree(): return
	queued = true
	call_deferred("_render")

func _render() -> void:
	queued = false
	if session == null: return
	UI.clear(self)
	canvas = Control.new()
	canvas.size = Vector2(1600, 900)
	canvas.scale = Vector2.ONE * minf(size.x / 1600, size.y / 900)
	canvas.position = (size - canvas.size * canvas.scale) / 2
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(canvas)
	var layers: Array = model.image_layers()
	var backgrounds: Array = layers.filter(func(row): return int(row.get("draw_layer", 0)) == 0)
	_image(session.background_path() if backgrounds.is_empty() else str(backgrounds.back().image_path), Rect2(0, 0, 1600, 900))
	for row in layers:
		if int(row.get("draw_layer", 0)) == 0: continue
		_image(str(row.image_path), Rect2(float(row.image_x), float(row.image_y), float(row.image_w), float(row.image_h)), bool(row.get("flip_h", false)))
	if not current_context.is_empty() and current_context.get("scene") == session.case_state.data.scene:
		var detail := str(current_context.get("detail", ""))
		for row in session.config.rows("investigation", "资源需求"):
			if not detail.is_empty() and row.get("view_id") == detail:
				_image(str(row.resource_or_text_ref), Rect2(0, 0, 1600, 900))
	for row in model.hotspots():
		var button := Button.new()
		button.flat = true
		button.tooltip_text = _hotspot_label(row)
		button.position = Vector2(float(row.x), float(row.y))
		button.size = Vector2(float(row.w), float(row.h))
		button.name = str(row.hotspot_id)
		button.pressed.connect(_inspect.bind(row))
		button.mouse_entered.connect(func(): if is_instance_valid(hint): hint.text = _hotspot_label(row))
		button.mouse_exited.connect(func(): if is_instance_valid(hint): hint.text = "")
		button.focus_entered.connect(func(): if is_instance_valid(hint): hint.text = _hotspot_label(row))
		canvas.add_child(button)
	var top := HBoxContainer.new()
	canvas.add_child(top)
	top.position = Vector2(28, 20)
	UI.label(top, session.config.text(str(session.config.scenes[session.case_state.data.scene].name_text_id)), 26)
	UI.button(top, "观察环境", _observe_scene)
	UI.button(top, "检查物件", func(): current_context = {"kind": "scene_items", "scene": session.case_state.data.scene, "view": session.case_state.data.view}; refresh())
	UI.button(top, "推理问题", func(): current_context = {"kind": "reasoning", "scene": session.case_state.data.scene, "view": session.case_state.data.view}; refresh())
	UI.button(top, "目标 / 回顾", objectives_requested.emit)
	UI.button(top, "办案手册 I", handbook_requested.emit)
	UI.button(top, "地图", map_requested.emit)
	UI.button(top, "菜单 Esc", menu_requested.emit)
	if str(session.case_state.data.scene) == "SC02": UI.button(top, "摸猫", cat_requested.emit)
	if session.autosave_failed:
		var retry := UI.button(top, "重试自动保存", session.retry_autosave)
		retry.tooltip_text = "初始或阶段自动保存失败；重试成功后才会清除旧保护记录。"
	hint = UI.label(canvas, "", 26)
	hint.position = Vector2(40, 820)
	if not current_context.is_empty(): _show_context(current_context)
	if notified_context != current_context:
		notified_context = current_context.duplicate(true)
		context_changed.emit()

func _inspect(row: Dictionary) -> void:
	current_context.clear()
	model.inspect(row)

func _hotspot_label(row: Dictionary) -> String:
	if row.object_kind == "character": return str(session.config.actors.get(row.object_ref, {}).get("name", "交谈"))
	var options: Array = model.observation_options(str(row.object_ref))
	if not options.is_empty(): return str(options[0].get("display_name", "检查")) + " " + model.observation_status(str(row.object_ref))
	return session.entry_label(str(row.get("inspect_entry_ref", "")))

func _observe_scene() -> void:
	for row in session.config.rows("investigation", "入口绑定"):
		if row.get("scene_id") == session.case_state.data.scene and row.get("purpose") == "scene_observation":
			session.activate_entry(str(row.entry_ref), {"kind": "scene", "scene": session.case_state.data.scene, "view": session.case_state.data.view})
			return

func _image(path: String, rect: Rect2, flip: bool = false) -> void:
	if path.is_empty(): return
	if not texture_cache.has(path): texture_cache[path] = load(path) if ResourceLoader.exists(path) else null
	if not texture_cache[path] is Texture2D: return
	var image := TextureRect.new()
	image.texture = texture_cache[path]
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.flip_h = flip
	image.position = rect.position
	image.size = rect.size
	canvas.add_child(image)

func _on_returned(context: Dictionary) -> void:
	current_context = context.duplicate(true) if context.get("kind") in ["topics", "inspection", "scene_items", "reasoning"] else {}
	refresh()

func _show_context(context: Dictionary) -> void:
	if context.get("scene") != session.case_state.data.scene or session.mode != "investigation": return
	var options: Array = []
	if context.get("kind") == "topics":
		options = model.topics(str(context.get("topics", "")))
		if options.is_empty(): current_context.clear(); return
	elif context.get("kind") == "inspection":
		options = model.observation_options(str(context.get("object", "")))
		if options.size() <= 1:
			# 单一观察对象读完直接回到“检查物件”目录，而不是清空回主场景（反馈#18）。
			current_context = {"kind": "scene_items", "scene": context.get("scene", ""), "view": context.get("view", "")}
			_show_context(current_context)
			return
	elif context.get("kind") == "scene_items": options = model.scene_options()
	elif context.get("kind") == "reasoning":
		for item in session.available_reasoning(): options.append({"entry_ref": item.entry, "display_name": item.text})
	else: return
	# 整屏拦截层包含透明区域；局部观察和话题列表都不向原热点透传。
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(blocker)
	for node in canvas.get_children():
		if node == blocker: continue
		for button in node.find_children("*", "BaseButton", true, false): button.disabled = true
		if node is BaseButton: node.disabled = true
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.add_child(center)
	overlay = center
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(680, 280)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	UI.label(box, "交谈" if context.kind == "topics" else "检查", 30)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 250)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for row in options:
		var entry := str(row.entry_ref)
		UI.button(list, str(row.get("public_name", row.get("display_name", "检查"))), func():
			current_context.clear()
			session.activate_entry(entry, context))
	var close := UI.button(box, "返回调查", _close_context)
	close.call_deferred("grab_focus")

func _close_context() -> void:
	current_context.clear()
	refresh()

func handle_escape() -> bool:
	if current_context.get("kind") in ["topics", "inspection", "scene_items", "reasoning"]: _close_context(); return true
	return false
