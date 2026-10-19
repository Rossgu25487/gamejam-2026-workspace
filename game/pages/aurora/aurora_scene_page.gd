extends Control
## 调查页持有自己的视图栈、镜头和控件；父场景与局部从不同时接收输入。
const UI = preload("res://pages/core/page_controls.gd")
const Investigation = preload("res://systems/aurora/aurora_investigation.gd")
const ConversationView = preload("res://pages/aurora/aurora_conversation_view.gd")
signal menu_requested
signal map_requested
signal handbook_requested
signal records_requested
signal material_presentation_requested(actor_id: String)
signal objectives_requested
signal cat_requested
signal context_changed

class HotspotButton extends Button:
	var hit_test: Callable
	func _has_point(point: Vector2) -> bool:
		return not disabled and (hit_test.call(point) if hit_test.is_valid() else Rect2(Vector2.ZERO, size).has_point(point))

var session: Node
var model: RefCounted = Investigation.new()
var canvas: Control
var world: Control
var overlay: Control
var queued := false
var current_context := {}
var texture_cache := {}
var alpha_cache := {}
var notified_context := {}
var view_offsets := {}
var view_offset_x := 0.0
var view_transform := {}
var hotspot_buttons := {}
var render_hotspots: Array = []
var render_layers: Array = []
var preferences := {"aspect_ratio": 0}
var pending_focus := ""
var last_completed_text := ""
var conversation_view: Control

func bind(value: Node) -> void:
	session = value
	model.bind(value)
	session.changed.connect(refresh)
	session.returned.connect(_on_returned)
	# 完成与取消同样会返回调查；只接受真正走完当前入口的回执才打开容器。
	session.narrative.text_started.connect(func(_row): last_completed_text = "")
	session.narrative.text_finished.connect(func(row): last_completed_text = str(row.get("text_id", "")))
	resized.connect(refresh)
	visibility_changed.connect(func():
		if visible: refresh())
	refresh()

func set_preferences(values: Dictionary) -> void:
	preferences = values.duplicate(true)
	refresh()

func refresh() -> void:
	if queued or not is_inside_tree(): return
	queued = true
	call_deferred("_render")

func _effective_area() -> Rect2:
	var ratio := int(preferences.get("aspect_ratio", 0))
	var ratios := {1: 16.0 / 9.0, 2: 16.0 / 10.0, 3: 4.0 / 3.0, 4: 21.0 / 9.0}
	if not ratios.has(ratio): return Rect2(Vector2.ZERO, size)
	var width := minf(size.x, size.y * float(ratios[ratio]))
	var area := Vector2(width, width / float(ratios[ratio]))
	return Rect2((size - area) / 2, area)

func _render() -> void:
	queued = false
	if session == null or size.x <= 0 or size.y <= 0: return
	_prune_context()
	UI.clear(self)
	overlay = null
	conversation_view = null
	hotspot_buttons.clear()
	var area := _effective_area()
	var screen_scale := area.size.y / 900.0
	canvas = Control.new()
	canvas.size = area.size / screen_scale
	canvas.scale = Vector2.ONE * screen_scale
	canvas.position = area.position
	canvas.clip_contents = true
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(canvas)
	world = Control.new()
	world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var brightness := clampf(float(preferences.get("brightness", 100)) / 100.0, 0.5, 1.5)
	world.modulate = Color(brightness, brightness, brightness, 1)
	canvas.add_child(world)
	var view := str(session.case_state.data.view)
	var saved_offset: float = float(current_context.get("view_offset_x", view_offsets.get(view, -1)))
	view_transform = model.view_transform(view, canvas.size, saved_offset)
	_apply_transform()
	var candidates: Array = model.conversation_candidates()
	var talking := bool(current_context.get("conversation_view", false)) and not candidates.is_empty()
	if talking:
		var actor := str(current_context.get("conversation_actor", ""))
		if not candidates.any(func(row): return str(row.object_ref) == actor):
			actor = str(candidates[0].object_ref)
			current_context["conversation_actor"] = actor
		render_layers = model.conversation_layers(actor)
	else:
		current_context.erase("conversation_view")
		current_context.erase("conversation_actor")
		render_layers = model.image_layers(view)
	_draw_view(view)
	render_hotspots = [] if talking else model.hotspots(view)
	# 最高目标最后绘制，同时每个按钮仍向统一拾取器确认归属，避免重叠穿透。
	for index in range(render_hotspots.size() - 1, -1, -1): _hotspot(render_hotspots[index])
	_link_keyboard_focus()
	if talking: _draw_conversation_view(candidates)
	_draw_tools()
	_draw_view_switches(view)
	if not talking: _draw_pan_controls()
	if not candidates.is_empty():
		_screen_button("返回调查视角" if talking else "交谈视角", Rect2(32, 100, 260, 56), _toggle_conversation_view).name = "ConversationViewSwitch"
	if _is_local():
		var back := _screen_button("返回上一视图", Rect2(32, 28, 280, 56), _back_view)
		back.name = "ReturnPreviousView"
		if pending_focus.is_empty(): pending_focus = "ReturnPreviousView"
	if current_context.get("kind") in ["topics", "reasoning"]: _show_context(current_context)
	if not pending_focus.is_empty(): call_deferred("_restore_focus", pending_focus)
	pending_focus = ""
	if notified_context != current_context:
		notified_context = current_context.duplicate(true)
		context_changed.emit()
	# 只在真实可见且已经绘出的调查页确认背景人物，后台选图不发布位置。
	if is_visible_in_tree(): call_deferred("_confirm_visible_actors", str(session.run_id), str(session.case_state.data.scene), view)

func _apply_transform() -> void:
	view_offset_x = float(view_transform.offset)
	view_offsets[str(session.case_state.data.view)] = view_offset_x
	world.position = view_transform.origin
	world.scale = Vector2.ONE * float(view_transform.scale)
	world.size = view_transform.content
	if not current_context.is_empty(): current_context["view_offset_x"] = view_offset_x
	if str(session.return_context.get("scene", "")) == str(session.case_state.data.scene) and str(session.return_context.get("view", "")) == str(session.case_state.data.view):
		session.return_context["view_offset_x"] = view_offset_x

func _draw_view(view: String) -> void:
	var resource: Dictionary = model.view_resource(view)
	var background: Dictionary = {}
	for row in render_layers:
		if str(row.get("image_role", "")) == "background" or int(row.get("draw_layer", 0)) <= 0: background = row
	if background.is_empty():
		if str(resource.get("view_kind", "")) in ["container_view", "object_detail"]:
			# 容器只继承父底图，不重绘父物件。透明包图按自己的矩形独立画。
			var parent := _parent_frame()
			var parent_resource: Dictionary = model.view_resource(str(parent.get("view", session.config.scenes[session.case_state.data.scene].default_view_id)))
			var parent_backgrounds: Array = model.image_layers(str(parent.get("view", ""))).filter(func(row): return str(row.get("image_role", "")) == "background" or int(row.get("draw_layer", 0)) <= 0)
			if not parent_backgrounds.is_empty(): _image_row(parent_backgrounds.back())
			else: _image(str(parent_resource.get("resource_or_text_ref", "")), Rect2(0, 0, 1600, 900))
		_image(str(resource.get("resource_or_text_ref", "")), _resource_rect(resource))
	for row in render_layers: _image_row(row)

func _resource_rect(row: Dictionary) -> Rect2:
	return Rect2(float(row.get("display_x", 0)), float(row.get("display_y", 0)), float(row.get("display_w", 1600)), float(row.get("display_h", 900)))

func _image_row(row: Dictionary) -> void:
	_image(str(row.get("image_path", "")), Rect2(float(row.get("image_x", 0)), float(row.get("image_y", 0)), float(row.get("image_w", 1600)), float(row.get("image_h", 900))), bool(row.get("flip_h", false)))
	if not str(row.get("visible_caption", "")).is_empty():
		var caption := UI.label(canvas, str(row.visible_caption), int(26 * world.scale.x))
		caption.position = world.position + Vector2(float(row.get("caption_x", 0)), float(row.get("caption_y", 0))) * world.scale
		caption.size = Vector2(float(row.get("caption_w", 280)), 50) * world.scale
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_color_override("font_color", Color("34413f"))
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _texture(path: String) -> Texture2D:
	if not texture_cache.has(path): texture_cache[path] = load(path) if not path.is_empty() and ResourceLoader.exists(path) else null
	return texture_cache[path] as Texture2D

func _image(path: String, rect: Rect2, flip: bool = false) -> void:
	var texture := _texture(path)
	if texture == null: return
	var image := TextureRect.new()
	image.texture = texture
	image.set_meta("image_path", path)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.flip_h = flip
	image.position = rect.position
	image.size = rect.size
	world.add_child(image)

func _hotspot(row: Dictionary) -> void:
	var button := HotspotButton.new()
	button.flat = true
	button.text = ""
	button.tooltip_text = ""
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.position = Vector2(float(row.x), float(row.y))
	button.size = Vector2(float(row.w), float(row.h))
	button.name = str(row.hotspot_id)
	button.hit_test = func(point: Vector2): return _picked_hotspot(point + button.position) == str(row.hotspot_id)
	var empty := StyleBoxEmpty.new()
	button.add_theme_stylebox_override("normal", empty)
	button.add_theme_stylebox_override("hover", empty)
	button.add_theme_stylebox_override("pressed", empty)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = Color("d0aa64")
	focus.set_border_width_all(2)
	button.add_theme_stylebox_override("focus", focus)
	button.pressed.connect(_inspect.bind(row))
	button.focus_entered.connect(_focus_hotspot.bind(row))
	button.mouse_entered.connect(_cursor.bind(row))
	world.add_child(button)
	hotspot_buttons[str(row.hotspot_id)] = button

func _picked_hotspot(point: Vector2) -> String:
	if session.mode != "investigation" or current_context.get("kind") in ["topics", "reasoning"]: return ""
	for row in render_hotspots:
		if model.contains_point(row, point) and not _occluded(row, point): return str(row.hotspot_id)
	return ""

func _occluded(hotspot: Dictionary, point: Vector2) -> bool:
	var target_layer: int = model.hotspot_layer(hotspot, str(session.case_state.data.view))
	for layer in render_layers:
		if str(layer.get("image_role", "")) == "background" or int(layer.get("draw_layer", 0)) <= target_layer: continue
		if str(layer.get("object_ref", "")) == str(hotspot.get("object_ref", "")): continue
		var rect := Rect2(float(layer.image_x), float(layer.image_y), float(layer.image_w), float(layer.image_h))
		if not rect.has_point(point): continue
		var path := str(layer.image_path)
		var texture := _texture(path)
		if texture == null: continue
		if not alpha_cache.has(path): alpha_cache[path] = texture.get_image()
		var image: Image = alpha_cache[path]
		if image == null or image.is_empty(): continue
		var uv := (point - rect.position) / rect.size
		if bool(layer.get("flip_h", false)): uv.x = 1.0 - uv.x
		var pixel := Vector2i(clampi(int(uv.x * image.get_width()), 0, image.get_width() - 1), clampi(int(uv.y * image.get_height()), 0, image.get_height() - 1))
		if image.get_pixelv(pixel).a > 0.1: return true
	return false

func _cursor(row: Dictionary) -> void:
	var status: String = model.observation_status(str(row.object_ref))
	var id := "ART7_cursor_%s_32" % ("checked" if status == "已查" else "recheck" if status == "可补查" else "inspect")
	for resource in session.config.rows("investigation", "资源需求"):
		if resource.get("id") != id: continue
		var texture := _texture(str(resource.resource_or_text_ref))
		if texture != null: Input.set_custom_mouse_cursor(texture, Input.CURSOR_POINTING_HAND, Vector2(float(resource.cursor_hotspot_x), float(resource.cursor_hotspot_y)))
		return

func _link_keyboard_focus() -> void:
	var ordered := render_hotspots.duplicate()
	ordered.sort_custom(func(a, b): return int(a.get("focus_order", 0)) < int(b.get("focus_order", 0)))
	for i in range(ordered.size()):
		var button: Button = hotspot_buttons[str(ordered[i].hotspot_id)]
		button.focus_next = button.get_path_to(hotspot_buttons[str(ordered[(i + 1) % ordered.size()].hotspot_id)])
		button.focus_previous = button.get_path_to(hotspot_buttons[str(ordered[(i - 1 + ordered.size()) % ordered.size()].hotspot_id)])

func _focus_hotspot(row: Dictionary) -> void:
	var scale_value: float = float(view_transform.scale)
	var left := float(row.x)
	var right := left + float(row.w)
	var visible_width := canvas.size.x / maxf(0.001, scale_value)
	var next := view_offset_x
	if left < next: next = left
	elif right > next + visible_width: next = right - visible_width
	view_transform = model.view_transform(str(session.case_state.data.view), canvas.size, next)
	_apply_transform()
	current_context["focus"] = str(row.hotspot_id)
	if not session.return_context.is_empty(): session.return_context["focus"] = str(row.hotspot_id)

func _screen_button(text: String, rect: Rect2, action: Callable) -> Button:
	var button := UI.button(canvas, text, action)
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", 24)
	button.add_theme_color_override("font_color", Color("34413f"))
	_paper_button(button)
	return button

func _draw_tools() -> void:
	var name_label := UI.label(canvas, session.config.text(str(session.config.scenes[session.case_state.data.scene].name_text_id)), 24)
	name_label.add_theme_stylebox_override("normal", _paper_style("small_paper"))
	name_label.position = Vector2(32, 28 if not _is_local() else 96)
	name_label.size = Vector2(480, 48)
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	name_label.add_theme_color_override("font_color", Color("3f6b4c"))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var right := canvas.size.x - 32
	_screen_button("手册 I", Rect2(right - 352, 820, 170, 48), handbook_requested.emit).name = "HandbookEntry"
	_screen_button("对白记录", Rect2(right - 170, 820, 170, 48), records_requested.emit).name = "DialogueRecordsEntry"
	_screen_button("地图 M", Rect2(right - 534, 820, 170, 48), map_requested.emit).name = "MapEntry"
	_screen_button("目标 / 回顾", Rect2(right - 352, 760, 170, 48), objectives_requested.emit)
	_screen_button("菜单 Esc", Rect2(right - 170, 760, 170, 48), menu_requested.emit)
	if session.autosave_failed:
		_screen_button("重试自动保存", Rect2(32, 820, 240, 48), session.retry_autosave)

func _draw_view_switches(view: String) -> void:
	for row in model.interface_layout.get("view_switch_controls", []):
		if str(row.scene_id) != str(session.case_state.data.scene) or str(row.view_id) != view: continue
		var rect: Array = row.get("rect_default_px", [1408, 28, 160, 64])
		var width := float(rect[2])
		_screen_button(str(row.label), Rect2(canvas.size.x - 32 - width, float(rect[1]), width, float(rect[3])), func(): _open_view(str(row.target_view_ref), str(row.get("target_focus_ref", ""))))

func _draw_pan_controls() -> void:
	if float(view_transform.maximum) <= 0: return
	var left := _screen_button("‹", Rect2(20, 426, 64, 48), _pan.bind(-1))
	var right := _screen_button("›", Rect2(canvas.size.x - 84, 426, 64, 48), _pan.bind(1))
	left.name = "PanLeft"
	right.name = "PanRight"
	left.disabled = view_offset_x <= 0.01
	right.disabled = view_offset_x >= float(view_transform.maximum) - 0.01

func _pan(direction: int) -> void:
	var next := view_offset_x + direction * canvas.size.x * 0.5 / float(view_transform.scale)
	view_offsets[str(session.case_state.data.view)] = clampf(next, 0, float(view_transform.maximum))
	current_context["view_offset_x"] = view_offsets[str(session.case_state.data.view)]
	if not session.return_context.is_empty(): session.return_context["view_offset_x"] = current_context.view_offset_x
	refresh()

func _caller_context() -> Dictionary:
	var context := current_context.duplicate(true)
	context.merge({"kind": "inspection" if _is_local() else "scene", "scene": str(session.case_state.data.scene), "view": str(session.case_state.data.view), "view_offset_x": view_offset_x}, true)
	return context

func _inspect(row: Dictionary) -> void:
	if session.mode != "investigation": return
	var context := _caller_context()
	context["focus"] = str(row.hotspot_id)
	_disable_world()
	var target_view := str(row.get("target_view_ref", ""))
	if row.object_kind == "exit" and not target_view.is_empty():
		if str(row.get("target_scene_ref", "")) == str(session.case_state.data.scene): _open_view(target_view, str(row.get("target_focus_ref", "")))
		else:
			session.notice.emit("请打开地图，选择地点后前往。")
			refresh()
		return
	var entry := str(row.get("inspect_entry_ref", ""))
	var detail := str(row.get("detail_view_ref", ""))
	last_completed_text = ""
	if row.object_kind == "cat" and (entry.is_empty() or not model.entry_available(entry) or session.case_state.data.entries.get(entry, false)):
		session.return_context = context
		cat_requested.emit()
		return
	if entry.is_empty() and not detail.is_empty():
		_open_view(detail, str(row.hotspot_id))
		return
	current_context.clear()
	if not model.inspect(row, context):
		current_context = context
		refresh()

func _disable_world() -> void:
	# 信号中的原按钮仍存在到帧尾，立即关闭整组焦点和鼠标，消耗这次点击。
	for button in hotspot_buttons.values():
		if is_instance_valid(button): button.disabled = true; button.release_focus(); button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(conversation_view): conversation_view.disable_input()

func _draw_conversation_view(candidates: Array) -> void:
	conversation_view = ConversationView.new()
	conversation_view.size = canvas.size
	canvas.add_child(conversation_view)
	conversation_view.actor_pressed.connect(_inspect_conversation_actor)
	conversation_view.actor_switched.connect(_switch_conversation_actor)
	conversation_view.build(candidates, str(current_context.get("conversation_actor", "")), model.actor_layout, session.config, float(preferences.get("brightness", 100)))

func _toggle_conversation_view() -> void:
	if session.mode != "investigation" or current_context.get("kind") in ["topics", "reasoning"]: return
	_disable_world()
	if current_context.get("conversation_view", false):
		current_context.erase("conversation_view")
		current_context.erase("conversation_actor")
	else:
		var candidates: Array = model.conversation_candidates()
		if candidates.is_empty(): return
		current_context = _caller_context()
		current_context["conversation_view"] = true
		current_context["conversation_actor"] = str(candidates[0].object_ref)
	current_context["kind"] = "scene"
	current_context["focus"] = "ConversationViewSwitch"
	session.return_context = current_context.duplicate(true)
	pending_focus = "ConversationViewSwitch"
	refresh()

func _switch_conversation_actor(actor: String) -> void:
	if session.mode != "investigation" or current_context.get("kind") in ["topics", "reasoning"]: return
	_disable_world()
	current_context["conversation_actor"] = actor
	current_context["focus"] = "ConversationActor_" + actor
	session.return_context = current_context.duplicate(true)
	pending_focus = str(current_context.focus)
	refresh()

func _inspect_conversation_actor(row: Dictionary) -> void:
	if not current_context.get("conversation_view", false): return
	_inspect(row)

func _open_view(view: String, focus: String = "") -> bool:
	var resource: Dictionary = model.view_resource(view)
	if resource.is_empty() or _texture(str(resource.get("resource_or_text_ref", ""))) == null:
		session.notice.emit("局部画面暂时无法打开，原调查已保留。")
		refresh()
		return false
	var scene := str(resource.get("scene_id", ""))
	if not scene.is_empty() and scene != str(session.case_state.data.scene):
		refresh()
		return false
	var prior := _parent_frame()
	if _is_local() and str(prior.get("view", "")) == view:
		_back_view()
		return true
	_disable_world()
	var parent := _caller_context()
	parent.erase("pending_detail")
	parent.erase("inspection_entry")
	var stack: Array = parent.get("parent_views", []).duplicate(true)
	parent.erase("parent_views")
	stack.append(parent)
	session.case_state.data.view = view
	current_context = {"kind": "inspection", "scene": str(session.case_state.data.scene), "view": view,
		"view_offset_x": float(resource.get("initial_offset_x", 0)), "parent_views": stack, "focus": focus}
	session.return_context = current_context.duplicate(true)
	pending_focus = focus
	refresh()
	return true

func _is_local() -> bool:
	return not current_context.get("parent_views", []).is_empty() or str(session.case_state.data.view) != str(session.config.scenes[session.case_state.data.scene].default_view_id)

func _parent_frame() -> Dictionary:
	var stack: Array = current_context.get("parent_views", [])
	if not stack.is_empty(): return stack.back()
	return {"scene": session.case_state.data.scene, "view": session.config.scenes[session.case_state.data.scene].default_view_id, "view_offset_x": 0}

func _back_view() -> void:
	_disable_world()
	var stack: Array = current_context.get("parent_views", []).duplicate(true)
	var parent: Dictionary
	if not stack.is_empty(): parent = stack.pop_back()
	else:
		var resource: Dictionary = model.view_resource(str(session.case_state.data.view))
		var view := str(resource.get("default_parent_view_ref", ""))
		if view.is_empty(): view = str(session.config.scenes[session.case_state.data.scene].default_view_id)
		parent = {"kind": "scene", "scene": session.case_state.data.scene, "view": view, "view_offset_x": 0}
	if not stack.is_empty(): parent["parent_views"] = stack
	session.case_state.data.view = str(parent.view)
	current_context = parent
	session.return_context = parent.duplicate(true)
	pending_focus = str(parent.get("focus", ""))
	refresh()

func _on_returned(context: Dictionary) -> void:
	current_context = context.duplicate(true) if str(context.get("scene", "")) == str(session.case_state.data.scene) else {}
	if not current_context.is_empty(): session.case_state.data.view = str(current_context.get("view", session.case_state.data.view))
	var detail := str(current_context.get("pending_detail", ""))
	var entry := str(current_context.get("inspection_entry", ""))
	if not detail.is_empty():
		current_context.erase("pending_detail")
		current_context.erase("inspection_entry")
		# 取消中的入口没有当次完成回执，不能把容器当成已打开。
		if not entry.is_empty() and session.case_state.data.entries.get(entry, false) and not last_completed_text.is_empty() and last_completed_text == str(session.narrative.state.get("current_text_id", "")):
			_open_view(detail, str(context.get("focus", "")))
			return
	if str(current_context.get("interaction", "")) == "cat_stove_head" and session.mode == "investigation" and not last_completed_text.is_empty() and last_completed_text == str(session.narrative.state.get("current_text_id", "")):
		current_context.erase("interaction")
		session.return_context = current_context.duplicate(true)
		cat_requested.emit()
		return
	pending_focus = str(current_context.get("focus", ""))
	refresh()

func _show_context(context: Dictionary) -> void:
	if context.get("scene") != session.case_state.data.scene or session.mode != "investigation": return
	var options: Array = []
	if context.get("kind") == "topics": options = model.topics(str(context.get("topics", "")))
	elif context.get("kind") == "reasoning":
		for item in session.available_reasoning(): options.append({"entry_ref": item.entry, "display_name": item.text})
	else: return
	var actor_id := str(context.get("object", ""))
	var can_offer := false
	for binding in session.config.narrative_bindings("material_presentation_bindings"):
		if binding.get("actor_id") == actor_id and binding.get("scene_id") == session.case_state.data.scene and session.condition(str(binding.get("condition_ref", ""))): can_offer = true
	if options.is_empty() and not can_offer: current_context["kind"] = "inspection" if _is_local() else "scene"; return
	_disable_world()
	var blocker := Control.new()
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(blocker)
	var panel := PanelContainer.new()
	panel.position = Vector2(maxf(32, canvas.size.x - 552), 220)
	panel.size = Vector2(520, 324)
	blocker.add_child(panel)
	panel.add_theme_stylebox_override("panel", _paper_style("panel_paper"))
	overlay = panel
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var heading := UI.label(box, "交谈" if context.kind == "topics" else "推理", 24)
	heading.add_theme_color_override("font_color", Color("3f6b4c"))
	if can_offer: UI.button(box, "出示材料", material_presentation_requested.emit.bind(actor_id))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(480, 180)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for row in options:
		var entry := str(row.entry_ref)
		var interactive: bool = row.get("interactive", true)
		var topic := UI.button(list, str(row.get("public_name", row.get("display_name", "交谈"))), func():
			if not interactive:
				session.notice.emit(str(row.get("public_reason", "当前无法交谈。")))
				return
			current_context.clear()
			session.activate_entry(entry, context))
		_paper_button(topic)
	var close := UI.button(box, "返回调查", _close_context)
	_paper_button(close)
	close.name = "CloseTopics"
	pending_focus = "CloseTopics"

func _close_context() -> void:
	current_context["kind"] = "inspection" if _is_local() else "scene"
	current_context.erase("topics")
	session.return_context = current_context.duplicate(true)
	pending_focus = str(current_context.get("focus", ""))
	refresh()

func _prune_context() -> void:
	if current_context.is_empty() and str(session.return_context.get("scene", "")) == str(session.case_state.data.scene) and str(session.return_context.get("view", "")) == str(session.case_state.data.view):
		current_context = session.return_context.duplicate(true)
	if not current_context.is_empty() and str(current_context.get("scene", "")) != str(session.case_state.data.scene): current_context.clear()

func has_context() -> bool:
	_prune_context()
	return _is_local() or current_context.get("kind") in ["topics", "reasoning"] or current_context.get("conversation_view", false)

func handle_escape() -> bool:
	if current_context.get("kind") in ["topics", "reasoning"]: _close_context(); return true
	if current_context.get("conversation_view", false): _toggle_conversation_view(); return true
	if _is_local(): _back_view(); return true
	return false

func _restore_focus(id: String) -> void:
	var button := find_child(id, true, false) as BaseButton
	if button != null and button.is_inside_tree() and button.is_visible_in_tree() and not button.disabled: button.grab_focus()

func _confirm_visible_actors(run: String, scene: String, view: String) -> void:
	# 只有实际绘制后的可见人物才成为公开位置；无图形测试不模拟玩家目击。
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	if not is_visible_in_tree() or session.run_id != run or str(session.case_state.data.scene) != scene or str(session.case_state.data.view) != view or session.mode != "investigation": return
	if not session.case_state.has_method("set_confirmed_actor_location"): return
	if is_instance_valid(conversation_view) and conversation_view.is_visible_in_tree() and conversation_view.visible_rect.has_area():
		var actor := str(conversation_view.selected_row.get("object_ref", ""))
		if str(session.case_state.data.npc.get(actor, {}).get("scene_id", "")) == scene: session.case_state.set_confirmed_actor_location(actor, scene)
	for layer in render_layers:
		var texture := _texture(str(layer.get("image_path", "")))
		if texture == null: continue
		for actor in layer.get("embedded_actor_refs", []):
			if _actor_on_screen(str(actor)): session.case_state.set_confirmed_actor_location(str(actor), scene)
		var visible_actor := str(layer.get("actor_location_ref", ""))
		if not visible_actor.is_empty() and layer.get("location_matches", true) == true and _actor_on_screen(visible_actor):
			session.case_state.set_confirmed_actor_location(visible_actor, str(layer.get("expected_scene_ref", scene)))

func _actor_on_screen(actor: String) -> bool:
	for hotspot in render_hotspots:
		if str(hotspot.get("object_ref", "")) != actor: continue
		var rect := Rect2(Vector2(float(hotspot.x), float(hotspot.y)) * world.scale + world.position, Vector2(float(hotspot.w), float(hotspot.h)) * world.scale)
		if rect.intersects(Rect2(Vector2.ZERO, canvas.size)): return true
	return false

func _paper_style(kind: String) -> StyleBox:
	var path: String = session.config.resource_path("res://assets/aurora/ui/art7/paper_v2/controls/" + kind + ".png")
	var texture := _texture(path)
	if texture == null:
		var fallback := StyleBoxFlat.new()
		fallback.bg_color = Color("eee6cf")
		fallback.set_content_margin_all(16)
		return fallback
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.texture_margin_left = 16
	style.texture_margin_top = 12
	style.texture_margin_right = 16
	style.texture_margin_bottom = 16
	style.content_margin_left = 20
	style.content_margin_top = 9
	style.content_margin_right = 20
	style.content_margin_bottom = 9
	return style

func _paper_button(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(state, _paper_style("button_secondary_" + state))
	button.add_theme_color_override("font_color", Color("34413f"))
	button.add_theme_color_override("font_hover_color", Color("34413f"))
	button.add_theme_color_override("font_pressed_color", Color("34413f"))
	button.add_theme_color_override("font_focus_color", Color("34413f"))
	button.add_theme_color_override("font_disabled_color", Color("737b70"))
	button.add_theme_font_size_override("font_size", 24)
