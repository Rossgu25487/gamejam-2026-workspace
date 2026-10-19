extends RefCounted
## 目标导航页面共用的控件工厂与样式：文字不透明、不加描边，行高按配置折算为字体行距。


static func color(hex: String, alpha := 1.0) -> Color:
	var value := Color.html(hex)
	value.a = alpha
	return value


static func box(fill: Color, margin := 0, border := 0, border_color := Color.TRANSPARENT) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.set_content_margin_all(margin)
	if border > 0:
		style.set_border_width_all(border)
		style.border_color = border_color
	return style


static func style_text(node: Control, size: int, tint: Color, line_height := 0) -> void:
	# 统一文字样式：不透明、无描边；line_height 大于 0 时折算为字体行距使行高等于配置值。
	var key := "normal_font_size" if node is RichTextLabel else "font_size"
	var color_key := "default_color" if node is RichTextLabel else "font_color"
	node.add_theme_font_size_override(key, size)
	node.add_theme_color_override(color_key, tint)
	if node is Label:
		node.add_theme_constant_override("outline_size", 0)
		node.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
		if line_height > 0:
			var font: Font = node.get_theme_font("font")
			node.add_theme_constant_override("line_spacing", line_height - int(ceil(font.get_height(size))))


static func label(parent: Node, text: String, size: int, tint: Color, line_height := 0) -> Label:
	var node := Label.new()
	node.text = text
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_text(node, size, tint, line_height)
	parent.add_child(node)
	return node


static func button(parent: Node, text: String, size: int, minimum_height: float, action: Callable, enabled := true) -> Button:
	var node := Button.new()
	node.text = text
	node.disabled = not enabled
	node.custom_minimum_size.y = minimum_height
	node.add_theme_font_size_override("font_size", size)
	node.pressed.connect(action)
	parent.add_child(node)
	return node

static func paper(assets: Dictionary, key: String, margin := 20) -> StyleBox:
	var path := str(assets.get(key, ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var style := StyleBoxTexture.new()
		style.texture = load(path)
		style.set_texture_margin_all(16)
		style.set_content_margin_all(margin)
		return style
	return box(Color("eee6cf"), margin)

static func paper_button(node: Button, assets: Dictionary, primary := false) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]: node.add_theme_stylebox_override(state, paper(assets, ("action_" if primary else "secondary_") + state, 12))
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]: node.add_theme_color_override(key, Color("34413f"))
	node.add_theme_color_override("font_disabled_color", Color("7f8580"))
	node.add_theme_stylebox_override("focus", box(Color.TRANSPARENT, 0, 2, Color("7b4830")))
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


static func next_frame(node: Node, action: Callable) -> void:
	# 下一帧执行一次；同一动作在同一帧内只登记一次，节点被释放后连接自动失效。
	var frame := node.get_tree().process_frame
	if not frame.is_connected(action):
		frame.connect(action, CONNECT_ONE_SHOT)


static func clear(parent: Node) -> void:
	# 信号发射中的按钮不能立即释放；先脱离容器，再在帧尾释放。
	for node in parent.get_children():
		parent.remove_child(node)
		node.queue_free()
