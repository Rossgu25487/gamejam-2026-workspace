extends Button
## 核查的手牌、引用槽和结果共用同一张2:3卡面；装饰层不接收输入。
var session: Node
var content_id := ""
var compact := true

func configure(value: Node, id: String, hand: bool = true) -> void:
	session = value
	content_id = id
	compact = hand
	name = "Card_" + id
	clip_contents = false
	var row: Dictionary = session.config.contents[id]
	var kind := str(session.config.materials[row.material_id].type)
	tooltip_text = str(row.name) + "\n" + str(row.description)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_layer("core_cards/components/shadow_normal.png")
	_layer("core_cards/components/card_thickness.png")
	_layer("core_cards/components/card_face.png")
	_layer("art7/paper_v2/components/category_paper_" + kind + ".png")
	_layer("core_cards/components/state_normal.png")
	if kind == "inference" and not session.case_state.owns(id): _layer("core_cards/components/mark_pending.png")
	var chosen: bool = id in session.slots
	var border := _layer("core_cards/components/border_selected.png" if chosen else "core_cards/components/border_hover.png")
	if border != null:
		border.visible = chosen
		mouse_entered.connect(func(): if is_instance_valid(border): border.show())
		mouse_exited.connect(func(): if is_instance_valid(border): border.visible = chosen)
		focus_entered.connect(func(): if is_instance_valid(border): border.show())
		focus_exited.connect(func(): if is_instance_valid(border): border.visible = chosen)
	_label({"evidence": "证据", "testimony": "证言", "inference": "推论"}.get(kind, "材料"), Rect2(0.09, 0.045, 0.82, 0.05), 13)
	var title := _label(str(row.name), Rect2(0.09, 0.13, 0.82, 0.20), 16 if hand else 19)
	title.max_lines_visible = 2
	var image_path := str(row.get("image_ref", ""))
	if not image_path.is_empty() and ResourceLoader.exists(image_path):
		var image := TextureRect.new()
		image.texture = load(image_path)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rect(image, Rect2(0.095, 0.36 if hand else 0.34, 0.81, 0.30 if hand else 0.25))
		add_child(image)
	if not hand:
		var summary := _label(str(row.description), Rect2(0.09, 0.60, 0.82, 0.27), 17)
		summary.max_lines_visible = 4
	if not hand: _label("已选用" if chosen else "点击查看", Rect2(0.09, 0.88, 0.82, 0.05), 13)
	if chosen: modulate = Color(1.0, 0.99, 0.92)

func _layer(relative: String) -> TextureRect:
	var path := str(session.config.definition.root).path_join("assets/aurora/ui/" + relative)
	if not ResourceLoader.exists(path): return null
	var image := TextureRect.new()
	image.texture = load(path)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(image)
	return image

func _label(value: String, bounds: Rect2, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color("34413f"))
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect(label, bounds)
	add_child(label)
	return label

func _rect(control: Control, bounds: Rect2) -> void:
	control.anchor_left = bounds.position.x
	control.anchor_top = bounds.position.y
	control.anchor_right = bounds.end.x
	control.anchor_bottom = bounds.end.y
