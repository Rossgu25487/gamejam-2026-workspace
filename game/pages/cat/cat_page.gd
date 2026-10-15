extends Control
## 猫页面持有自己的视觉载体、头部触区与按钮；首见和时钟由互动服务维护。
signal menu_requested
signal closed
const UI = preload("res://pages/core/page_controls.gd")
var session: Node
var model: RefCounted
var definition := {}
var visual: Node
var slot: Control
var touch_button: Button
var head_button: Button
var return_button: Button
var caption: Label
var reduced := false
var action_key := ""
var focus_before: WeakRef
var visual_generation := 0
var rendered_generation := -1

func _ready() -> void:
	hide()
	resized.connect(_layout)

func bind(value: Node) -> void:
	session = value
	model = value.cat
	value.cat_requested.connect(open)
	model.changed.connect(_refresh)
	model.finished.connect(_finish)

func open(data: Dictionary) -> void:
	definition = data.duplicate(true)
	action_key = ""
	var focus := get_viewport().gui_get_focus_owner()
	focus_before = weakref(focus) if focus != null else null
	UI.clear(self)
	# 上一回载体已从页面移除，不能再向新 slot 移除旧节点。
	visual = null
	var background := ColorRect.new()
	background.color = Color(0.06, 0.07, 0.08)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	slot = Control.new()
	add_child(slot)
	head_button = UI.button(self, "猫头", _touch)
	head_button.flat = true
	head_button.modulate.a = 0.05
	touch_button = UI.button(self, session.cat_catalog.ui("CAT_TOUCH"), _touch)
	return_button = UI.button(self, session.cat_catalog.ui("CAT_RETURN"), _finish)
	var menu := UI.button(self, "菜单 / Esc", menu_requested.emit)
	menu.position = Vector2(24, 24)
	caption = UI.label(self, "", 24)
	show()
	_layout()
	_refresh()
	touch_button.grab_focus()

func _layout() -> void:
	if not is_instance_valid(slot) or definition.is_empty(): return
	var view: Dictionary = definition.view
	slot.position = Vector2(float(view.screen_x), float(view.screen_y)) * size
	slot.size = Vector2(float(view.screen_w), float(view.screen_h)) * size
	# 图片的 contain 矩形作为头区坐标系，留白不纳入可点击区域；镜像一起转换。
	var rect := Rect2(slot.position, slot.size)
	if visual is TextureRect and visual.texture != null:
		var texture_size: Vector2 = visual.texture.get_size()
		var scale_factor: float = minf(slot.size.x / texture_size.x, slot.size.y / texture_size.y) * float(view.display_scale)
		rect.size = texture_size * scale_factor
		rect.position = slot.position + (slot.size - rect.size) * Vector2(float(view.anchor_x), float(view.anchor_y))
		visual.position = rect.position - slot.position
		visual.size = rect.size
	var head_x := float(view.head_x)
	if view.get("flip_horizontal", false): head_x = 1.0 - head_x - float(view.head_w)
	head_button.position = rect.position + Vector2(head_x, float(view.head_y)) * rect.size
	head_button.size = Vector2(float(view.head_w), float(view.head_h)) * rect.size
	touch_button.position = Vector2(size.x * 0.1, size.y - 90)
	return_button.position = touch_button.position + Vector2(180, 0)
	caption.position = Vector2(size.x * 0.1, size.y - 135)

func _refresh() -> void:
	if not visible or definition.is_empty(): return
	var waiting: bool = model.phase == "waiting"
	touch_button.disabled = not waiting
	head_button.disabled = not waiting
	if not waiting and get_viewport().gui_get_focus_owner() in [touch_button, head_button]: return_button.grab_focus()
	caption.text = session.core.ui(model.caption_text_id()) if not model.caption_text_id().is_empty() else ""
	var key: String = model.current_action_kind()
	if key == action_key: return
	action_key = key
	visual_generation += 1
	rendered_generation = -1
	if is_instance_valid(visual):
		slot.remove_child(visual)
		visual.queue_free()
		visual = null
	var path: String = definition.actions.get(key, {}).get("visual_ref", "")
	if path.is_empty(): return
	var resource = load(path) if ResourceLoader.exists(path) else null
	if resource is Texture2D:
		var image := TextureRect.new()
		image.texture = resource
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_SCALE
		image.flip_h = definition.view.get("flip_horizontal", false)
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual = image
	elif resource is PackedScene:
		visual = resource.instantiate()
		if visual.has_signal("stable_frame_displayed"): visual.connect("stable_frame_displayed", model.notify_stable_displayed)
	if visual == null:
		caption.text = "互动素材未就绪，请返回调查"
		return
	slot.add_child(visual)
	if DisplayServer.get_name() != "headless": _wait_for_visual_frame(visual_generation)
	if visual.has_method("play_action"): visual.call("play_action", key)
	_layout()

func _touch() -> void:
	model.begin_touch(reduced)

func _wait_for_visual_frame(generation: int) -> void:
	# 渲染完成信号是实际画面证据，创建节点或无界面推进时钟都不登记首见。
	await RenderingServer.frame_post_draw
	if is_inside_tree() and generation == visual_generation and is_visible_in_tree(): rendered_generation = generation

func _process(delta: float) -> void:
	if not is_visible_in_tree() or model == null or not model.is_active(): return
	# 稳定PNG至少实际渲染一帧才登记首见；无界面回归不把创建节点当看到画面。
	if visual is TextureRect and visual.is_visible_in_tree() and rendered_generation == visual_generation:
		if model.reduce_motion or model.phase == "response":
			var stable_point := float(definition.actions.get(action_key, {}).get("stable_point", 0.0))
			var elapsed: float = 1.0 - model.remaining_ms() / float(definition.interaction.response_ms)
			if model.reduce_motion or elapsed >= stable_point: model.notify_stable_displayed()
	model.advance(delta * 1000.0)

func set_paused(paused: bool) -> void:
	if model == null: return
	if paused: model.pause()
	else: model.resume()
	if is_instance_valid(visual) and visual.has_method("set_paused"): visual.call("set_paused", paused)

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))
	if model != null: model.set_reduce_motion(reduced)

func reset_page() -> void:
	hide()
	if session != null and model.is_active(): session.finish_cat()
	definition = {}
	action_key = ""
	visual_generation += 1
	if is_instance_valid(visual): visual.queue_free()
	visual = null

func _finish() -> void:
	if not visible: return
	session.finish_cat()
	hide()
	closed.emit()
	var previous = focus_before.get_ref() if focus_before != null else null
	if previous is Control and previous.is_visible_in_tree(): previous.grab_focus()
