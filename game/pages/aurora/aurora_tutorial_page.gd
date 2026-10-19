extends Control
## 引导覆盖层不建立替代热区；它只在输入分发前过滤，并实时描绘原节点的轮廓。
const MaterialCard = preload("res://pages/aurora/aurora_material_card.gd")
const SHADE_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec2 points[32];
uniform int point_count = 0;
uniform float strength = 0.55;
uniform float blur_px = 6.0;
void fragment() {
	vec2 pixel = SCREEN_UV / SCREEN_PIXEL_SIZE;
	bool inside = false;
	int prior = point_count - 1;
	for (int index = 0; index < 32; index++) {
		if (index >= point_count) { break; }
		vec2 a = points[index]; vec2 b = points[prior];
		if (((a.y > pixel.y) != (b.y > pixel.y)) && (pixel.x < (b.x-a.x)*(pixel.y-a.y)/(b.y-a.y+0.00001)+a.x)) { inside = !inside; }
		prior = index;
	}
	vec2 spread = SCREEN_PIXEL_SIZE * blur_px;
	vec3 blurred = texture(screen_texture, SCREEN_UV).rgb * 0.25;
	blurred += texture(screen_texture, SCREEN_UV + vec2(spread.x, 0.0)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV - vec2(spread.x, 0.0)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV + vec2(0.0, spread.y)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV - vec2(0.0, spread.y)).rgb * 0.125;
	blurred += texture(screen_texture, SCREEN_UV + spread).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV - spread).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV + vec2(spread.x, -spread.y)).rgb * 0.0625;
	blurred += texture(screen_texture, SCREEN_UV + vec2(-spread.x, spread.y)).rgb * 0.0625;
	COLOR = inside ? vec4(0.0) : vec4(blurred * (1.0-strength), 1.0);
}
"""
var service: Node
var shade: ColorRect
var decoration: Control
var paper: PanelContainer
var text: Label
var target_polygon := PackedVector2Array()
var target_screen_polygon := PackedVector2Array()
var step_id := ""
var elapsed := 0.0
var typing_elapsed := 0.0
var reduce_motion := false
var text_speed := 30.0
var feedback: Control
var feedback_card: Control
var feedback_animation_ms := 400.0
var feedback_elapsed := 0.0
var transition_mouse_button := 0
var contour_segments: Array[PackedVector2Array] = []

func bind(value: Node) -> void:
	service = value
	service.changed.connect(_refresh)
	service.first_card_feedback_requested.connect(_show_first_card)
	_refresh()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 200 # 高于核查局部详情的100；暂停页仍由外层主导航盖住。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade = ColorRect.new()
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADE_SHADER
	material.shader = shader
	shade.material = material
	add_child(shade)
	decoration = Control.new()
	decoration.mouse_filter = Control.MOUSE_FILTER_IGNORE
	decoration.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	decoration.draw.connect(_draw_decoration)
	add_child(decoration)
	paper = PanelContainer.new()
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("eee6cf")
	style.border_color = Color("b99b5e")
	style.set_border_width_all(2)
	style.set_corner_radius_all(7)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	paper.add_theme_stylebox_override("panel", style)
	add_child(paper)
	text = Label.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_theme_color_override("font_color", Color("34413f"))
	paper.add_child(text)
	hide()
	_refresh()

func set_preferences(values: Dictionary) -> void:
	reduce_motion = bool(values.get("reduce_motion", false))
	text_speed = 30.0 * {1: 0.5, 2: 1.0, 3: 1.5}.get(int(values.get("text_speed", 2)), 1.0)

func _refresh() -> void:
	if service == null or not is_instance_valid(shade): return
	var show_guide: bool = not service.current_step.is_empty()
	visible = show_guide or service.feedback_left > 0
	shade.visible = show_guide
	decoration.visible = show_guide
	paper.visible = show_guide
	if is_instance_valid(feedback): feedback.visible = service.feedback_left > 0
	var key: String = service.step_key(service.current_step)
	if key != step_id:
		step_id = key
		elapsed = 0
		typing_elapsed = 0
		text.text = service.tutorial_text()
		text.visible_characters = 0
	_recompute_geometry()

func _process(delta: float) -> void:
	if service == null or not is_visible_in_tree() or service.session.paused: return
	elapsed += delta
	typing_elapsed += delta
	if paper.visible: text.visible_characters = mini(text.text.length(), int(typing_elapsed * text_speed))
	_recompute_geometry()
	if is_instance_valid(feedback_card) and service.feedback_left > 0:
		feedback_elapsed += delta * 1000
		var amount := clampf(feedback_elapsed / maxf(1, feedback_animation_ms), 0, 1)
		feedback_card.modulate.a = 1 if reduce_motion else amount
		var dimensions := Vector2(192, 288) * _scale()
		feedback_card.size = dimensions
		var start := Vector2(size.x * 0.5 - dimensions.x * 0.5, size.y * 0.38 - dimensions.y * 0.5)
		var finish := Vector2(size.x - dimensions.x - 44 * _scale(), size.y - dimensions.y - 100 * _scale())
		# 普通材料取得不要求收下：纸面显露后沿轻弧线归向手册入口，再停留名称。
		feedback_card.position = start.lerp(finish, amount) + Vector2(0, -sin(amount * PI) * 58 * _scale()) if not reduce_motion else finish
	queue_redraw()
	decoration.queue_redraw()

func _scale() -> float:
	return maxf(0.5, size.y / 900.0)

func _recompute_geometry() -> void:
	if service == null or not is_instance_valid(shade): return
	target_polygon.clear()
	target_screen_polygon.clear()
	contour_segments.clear()
	var target: Control = service.target_control()
	if is_instance_valid(target):
		var source := _original_contour(target)
		var transform := target.get_global_transform_with_canvas()
		var inverse := get_global_transform_with_canvas().affine_inverse()
		for point in source:
			var screen := transform * point
			target_screen_polygon.append(screen)
			target_polygon.append(inverse * screen)
		_clip_to_visible_parent(target)
		_visible_segments(target)
	var shader_points := PackedVector2Array()
	for index in range(32): shader_points.append(target_screen_polygon[index] if index < target_screen_polygon.size() else Vector2.ZERO)
	shade.material.set_shader_parameter("points", shader_points)
	shade.material.set_shader_parameter("point_count", mini(32, target_screen_polygon.size()))
	shade.material.set_shader_parameter("strength", float(service.definition.get("presentation", {}).get("shade_opacity", 0.55)))
	shade.material.set_shader_parameter("blur_px", 6.0 * _scale())
	shade.modulate.a = 1.0 if reduce_motion else clampf(elapsed / 0.18, 0, 1)
	if target_polygon.size() >= 3: _position_paper()
	else:
		paper.position = Vector2(24, 24) * _scale()
		paper.size = Vector2(minf(size.x - 48, 460 * _scale()), 0)
	text.add_theme_font_size_override("font_size", maxi(18, int(24 * _scale())))
	queue_redraw()
	decoration.queue_redraw()

func _clip_to_visible_parent(target: Control) -> void:
	var ancestor := target.get_parent()
	var inverse := get_global_transform_with_canvas().affine_inverse()
	while ancestor != null and target_screen_polygon.size() >= 3:
		if ancestor is Control and ancestor.clip_contents:
			var transform: Transform2D = ancestor.get_global_transform_with_canvas()
			var clip := PackedVector2Array([transform * Vector2.ZERO, transform * Vector2(ancestor.size.x, 0), transform * ancestor.size, transform * Vector2(0, ancestor.size.y)])
			var intersections := Geometry2D.intersect_polygons(target_screen_polygon, clip)
			target_screen_polygon = intersections[0] if not intersections.is_empty() else PackedVector2Array()
		ancestor = ancestor.get_parent()
	target_polygon.clear()
	for point in target_screen_polygon: target_polygon.append(inverse * point)

func _visible_segments(target: Control) -> void:
	# 扇牌重叠部分仍属于上层卡，不把被挡住的边画成可点的亮框。
	if target_polygon.size() < 3: return
	var transform := get_global_transform_with_canvas()
	for index in range(target_polygon.size()):
		var begin := target_polygon[index]
		var end := target_polygon[(index + 1) % target_polygon.size()]
		var count := maxi(1, ceili(begin.distance_to(end) / (6 * _scale())))
		var segment := PackedVector2Array()
		for part in range(count + 1):
			var point := begin.lerp(end, float(part) / count)
			var inward := point.lerp(_polygon_center(), 0.02)
			var picked: Control = service.actual_hit_control(service.gameplay, transform * inward)
			var exposed := picked == target or (picked != null and target.is_ancestor_of(picked))
			if exposed: segment.append(point)
			elif segment.size() > 1:
				contour_segments.append(segment)
				segment = PackedVector2Array()
			else: segment = PackedVector2Array()
		if segment.size() > 1: contour_segments.append(segment)

func _polygon_center() -> Vector2:
	var center := Vector2.ZERO
	for point in target_polygon: center += point
	return center / maxf(1, target_polygon.size())

func _original_contour(target: Control) -> PackedVector2Array:
	# 地图采用自己的多边形，调查采用正式多边形；旋转手牌采用真实节点四角。
	for property in target.get_property_list():
		if property.name == "hit_polygon":
			var polygon: PackedVector2Array = target.get("hit_polygon")
			if polygon.size() >= 3: return polygon
	if service.current_step.get("target_kind") == "hotspot":
		var scene: Control = service.gameplay.get("scene_page")
		for row in scene.get("render_hotspots"):
			if str(row.get("hotspot_id", "")) != str(target.name): continue
			var polygon: PackedVector2Array = scene.model.hotspot_polygon(row)
			for index in range(polygon.size()): polygon[index] -= target.position
			if polygon.size() >= 3: return polygon
	return PackedVector2Array([Vector2.ZERO, Vector2(target.size.x, 0), target.size, Vector2(0, target.size.y)])

func _position_paper() -> void:
	var bounds := Rect2(target_polygon[0], Vector2.ZERO)
	for point in target_polygon: bounds = bounds.expand(point)
	var width := minf(460 * _scale(), size.x - 48 * _scale())
	paper.size = Vector2(width, 0)
	text.custom_minimum_size.x = maxf(1, width - 36)
	# Label始终测量整段文字；逐字只改visible_characters，不改变纸签大小。
	var height := maxf(88 * _scale(), paper.get_combined_minimum_size().y)
	var x := bounds.end.x + 32 * _scale()
	if x + width > size.x - 24 * _scale(): x = bounds.position.x - width - 32 * _scale()
	if x < 24 * _scale(): x = clampf(bounds.get_center().x - width / 2, 24 * _scale(), size.x - width - 24 * _scale())
	var y := bounds.get_center().y - height / 2
	if Rect2(Vector2(x, y), Vector2(width, height)).intersects(bounds.grow(16 * _scale())):
		y = bounds.position.y - height - 32 * _scale()
		if y < 24 * _scale(): y = bounds.end.y + 32 * _scale()
	paper.position = Vector2(x, clampf(y, 24 * _scale(), maxf(24 * _scale(), size.y - height - 24 * _scale())))
	paper.size.y = height

func _draw_decoration() -> void:
	if service == null or service.current_step.is_empty() or target_polygon.size() < 3: return
	var gold := Color("e5c16f")
	gold.a = 0.92 if reduce_motion else 0.82 + 0.18 * sin(elapsed * TAU / 1.2)
	# 10px光晕为纯绘制，不参与original_hit。
	for contour in contour_segments:
		decoration.draw_polyline(contour, Color(gold, 0.12), 20 * _scale(), true)
		decoration.draw_polyline(contour, gold, 2 * _scale(), true)
	var center := _polygon_center()
	var bounds := Rect2(target_polygon[0], Vector2.ZERO)
	for point in target_polygon: bounds = bounds.expand(point)
	var tip := Vector2(center.x, bounds.position.y + 2 * _scale())
	var tail := tip - Vector2(0, 42 * _scale())
	if tail.y < 10 * _scale():
		tip = Vector2(bounds.end.x - 2 * _scale(), center.y)
		tail = tip + Vector2(42 * _scale(), 0)
	var direction := (tip - tail).normalized()
	var normal := Vector2(-direction.y, direction.x)
	gold.a = 1 if reduce_motion else 0.7 + 0.3 * (0.5 + 0.5 * sin(elapsed * TAU / 0.9))
	# 参照原示例的126px箭杆、36px箭头和6px线宽全部使用1/3比例。
	decoration.draw_line(tail, tip, gold, 2 * _scale(), true)
	decoration.draw_line(tip, tip - direction * 12 * _scale() + normal * 6 * _scale(), gold, 2 * _scale(), true)
	decoration.draw_line(tip, tip - direction * 12 * _scale() - normal * 6 * _scale(), gold, 2 * _scale(), true)

func _input(event: InputEvent) -> void:
	if service == null or not is_visible_in_tree() or service.session.paused: return
	# 完成操作所在的鼠标按下与释放是一笔输入，不穿透到下一步骤。
	if event is InputEventMouseButton and not event.pressed and transition_mouse_button == event.button_index:
		transition_mouse_button = 0
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE and (service.feedback_left > 0 or not service.current_step.get("allow_cancel", false)):
		service.gameplay.menu_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		var target: Control = service.target_control()
		if is_instance_valid(target): target.grab_focus()
		get_viewport().set_input_as_handled()
		return
	if not service.input_allowed(event): get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# BaseButton的正常释放仍须送达；业务完成后才在下一帧消费迟到释放。
		pass

func _show_first_card(content_id: String, animation_ms: int, _hold_ms: int, message: String) -> void:
	if is_instance_valid(feedback): feedback.queue_free()
	feedback = Control.new()
	feedback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feedback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(feedback)
	feedback_card = MaterialCard.new()
	feedback_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feedback.add_child(feedback_card)
	feedback_card.configure(service.session, content_id, false)
	feedback_card.focus_mode = Control.FOCUS_NONE
	feedback_animation_ms = animation_ms
	feedback_elapsed = 0
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", maxi(18, int(24 * _scale())))
	label.add_theme_color_override("font_color", Color("34413f"))
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("eee6cf")
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(size.x * 0.5 - 230 * _scale(), size.y * 0.72)
	panel.size = Vector2(460, 110) * _scale()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feedback.add_child(panel)
	panel.add_child(label)
	_refresh()
