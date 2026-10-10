extends RefCounted
## 纯控件工厂；具体节点生命周期和动作绑定由各页面负责。

static func label(parent: Node, text: String, size: int = 20) -> Label:
	var node := Label.new()
	node.text = text
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_theme_font_size_override("font_size", size)
	parent.add_child(node)
	return node

static func button(parent: Node, text: String, action: Callable, enabled: bool = true) -> Button:
	var node := Button.new()
	node.text = text
	node.disabled = not enabled
	node.custom_minimum_size.y = 36
	node.pressed.connect(action)
	parent.add_child(node)
	return node

static func clear(parent: Node) -> void:
	# 信号发射中的按钮不能立即 free；先脱离容器，再在帧尾释放。
	for node in parent.get_children():
		parent.remove_child(node)
		node.queue_free()

static func body(parent: Node, text: String, minimum_height: float = 140) -> RichTextLabel:
	var node := RichTextLabel.new()
	node.text = text
	node.custom_minimum_size.y = minimum_height
	node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	node.add_theme_font_size_override("normal_font_size", 20)
	node.focus_mode = Control.FOCUS_ALL
	parent.add_child(node)
	return node
