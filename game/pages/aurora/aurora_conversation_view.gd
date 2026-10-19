extends Control
## 交谈视角只负责近景排布和实际图片命中；剧情入口仍由调查规则处理。
signal actor_pressed(row: Dictionary)
signal actor_switched(actor_id: String)

class PortraitButton extends Button:
	var alpha_image: Image
	var image_rect := Rect2()
	func _has_point(point: Vector2) -> bool:
		if disabled or alpha_image == null or image_rect.size.x <= 0 or image_rect.size.y <= 0: return false
		var uv := (point + position - image_rect.position) / image_rect.size
		if uv.x < 0 or uv.y < 0 or uv.x >= 1 or uv.y >= 1: return false
		return alpha_image.get_pixel(clampi(int(uv.x * alpha_image.get_width()), 0, alpha_image.get_width() - 1), clampi(int(uv.y * alpha_image.get_height()), 0, alpha_image.get_height() - 1)).a > 0.1

var selected_row: Dictionary = {}
var portrait_rect := Rect2()
var visible_rect := Rect2()
var actor_button: BaseButton

func build(candidates: Array, actor_id: String, layout: Dictionary, config: RefCounted, brightness_percent: float = 100) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	if candidates.is_empty(): return
	var index := 0
	for i in range(candidates.size()):
		if str(candidates[i].object_ref) == actor_id: index = i; break
	selected_row = candidates[index]
	var asset: Dictionary = selected_row.actor_asset
	var texture := load(str(selected_row.portrait_path)) as Texture2D
	if texture == null: return
	var head := float(asset.get("visible_head_top_y_px", 0))
	var anchor: Array = asset.get("dialogue_anchor_px", [texture.get_width() / 2.0, texture.get_height()])
	var top := 900.0 * float(layout.get("head_top_ratio", 250.0 / 900.0))
	var bottom := 900.0 * float(layout.get("bottom_cut_ratio", 1))
	var factor := (bottom - top) / maxf(1, float(anchor[1]) - head)
	var facing := str(asset.get("facing_direction", "front"))
	var slot := "left" if facing == "right" else "right" if facing == "left" else "center"
	var center := size.x * float(layout.get("slot_center_x_ratio", {}).get(slot, 0.5))
	portrait_rect = Rect2(Vector2(center - float(anchor[0]) * factor, top - head * factor), texture.get_size() * factor)
	var image := TextureRect.new()
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var brightness := clampf(brightness_percent / 100.0, 0.5, 1.5)
	image.modulate = Color(brightness, brightness, brightness, 1)
	image.position = portrait_rect.position
	image.size = portrait_rect.size
	image.set_meta("conversation_actor", str(selected_row.object_ref))
	add_child(image)
	var alpha_image := texture.get_image()
	var bbox: Array = asset.get("alpha_16_bbox", [0, 0, texture.get_width(), texture.get_height()])
	visible_rect = Rect2(portrait_rect.position + Vector2(float(bbox[0]), float(bbox[1])) * factor, Vector2(float(bbox[2]) - float(bbox[0]), float(bbox[3]) - float(bbox[1])) * factor).intersection(Rect2(Vector2.ZERO, size))
	var button := PortraitButton.new()
	button.name = "ConversationActor_" + str(selected_row.object_ref)
	button.flat = true
	button.position = visible_rect.position
	button.size = visible_rect.size
	button.alpha_image = alpha_image
	button.image_rect = portrait_rect
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed"]: button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.pressed.connect(func(): actor_pressed.emit(selected_row))
	add_child(button)
	actor_button = button
	var name_label := Label.new()
	name_label.text = str(config.actors.get(str(selected_row.object_ref), {}).get("name", "交谈对象")) + "　点击人物交谈"
	name_label.add_theme_font_size_override("font_size", 26)
	name_label.add_theme_color_override("font_color", Color("f6edda"))
	name_label.add_theme_color_override("font_shadow_color", Color("292820"))
	name_label.add_theme_constant_override("shadow_offset_x", 2)
	name_label.add_theme_constant_override("shadow_offset_y", 2)
	name_label.position = Vector2(32, 172)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_label)
	if candidates.size() > 1:
		var next := Button.new()
		next.name = "NextConversationActor"
		next.text = "切换交谈对象　›　%d / %d" % [index + 1, candidates.size()]
		next.position = Vector2(size.x - 372, 100)
		next.size = Vector2(340, 56)
		next.add_theme_font_size_override("font_size", 24)
		next.pressed.connect(func(): actor_switched.emit(str(candidates[(index + 1) % candidates.size()].object_ref)))
		add_child(next)

func disable_input() -> void:
	for button in find_children("*", "BaseButton", true, false):
		button.disabled = true
		button.release_focus()
		button.mouse_filter = Control.MOUSE_FILTER_IGNORE
