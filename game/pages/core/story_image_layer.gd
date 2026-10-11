extends Control
## 页面私有图片层。1280×800坐标映射到实际显示区，图片和点击区域一同缩放。
## 装饰不接收输入，调查卡仍调用原入口，材料卡面复用各页面原有操作按钮。

const BASE_SIZE := Vector2(1280, 800)
var service: Node
var placed: Array[Control] = []
var entry_buttons: Dictionary = {}
var entry_bindings: Dictionary = {}
var page_key := ""
var refresh_queued := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_layout)

func render(core: Node, page: String, activate: Callable = Callable()) -> void:
	service = core
	for child in get_children(): remove_child(child); child.queue_free()
	placed.clear()
	entry_buttons.clear()
	entry_bindings.clear()
	for id in core.catalog.data.get("image_layouts", {}):
		var row: Dictionary = core.catalog.data.image_layouts[id]
		if row.page != page or row.kind == "material": continue
		if not row.scene_id.is_empty() and row.scene_id != core.state.get("current_scene_id", ""): continue
		if row.kind == "entry": entry_bindings[row.ref] = true
		if not row.condition.is_empty() and (core.state.is_empty() or not core.condition_met(row.condition)): continue
		if row.kind == "portrait" and row.ref != _character(core): continue
		if row.kind == "entry" and (not activate.is_valid() or not core._in_current_scene(core.catalog.data.entries[row.ref])): continue
		var host := Control.new()
		host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		host.set_meta("layout_id", id)
		host.set_meta("layout_row", row)
		# Z只排序图片之间，页面工具、文字、弹窗始终在图片上方。
		host.z_index = int(row.layer)
		add_child(host)
		placed.append(host)
		if row.kind == "entry":
			var entry: Dictionary = core.catalog.data.entries[row.ref]
			var title: String = core.catalog.text(entry.title)
			var b := Button.new()
			b.text = title
			b.tooltip_text = title
			b.set_meta("focus_key", row.ref)
			b.set_meta("entry_id", row.ref)
			b.disabled = not core.condition_met(entry.condition)
			b.pressed.connect(activate.bind(row.ref))
			host.add_child(b)
			b.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			attach_image(b, row)
			# 显示图与按钮同一矩形；透明像素仍属于整张卡的点击范围。
			if b.disabled: host.modulate = Color(0.45, 0.45, 0.45)
			entry_buttons[row.ref] = b
		else: attach_image(host, row)
	_layout()

static func bind_page(page: Control, core: Node, key: String) -> void:
	# 通用页面也由自己的图片子节点处理显示，Main只调用页面的绑定接口。
	var script := load("res://pages/core/story_image_layer.gd")
	var layer: Control = script.new()
	page.add_child(layer)
	page.move_child(layer, 0)
	layer.service = core
	layer.page_key = key
	for child in page.get_children():
		if child != layer and child is CanvasItem: child.z_index = 100
	core.changed.connect(layer.request_refresh)
	page.visibility_changed.connect(layer.request_refresh)
	layer.request_refresh()

func request_refresh() -> void:
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_refresh_page")

func _refresh_page() -> void:
	refresh_queued = false
	if is_instance_valid(service): render(service, page_key)

func _character(core: Node) -> String:
	if core.state.is_empty(): return ""
	if core.state.get("mode") == "dialogue": return core.catalog.data.entries[core.state.current_node_id].get("object_id", "")
	return core.catalog.data.questions.get(core.state.get("question_id", ""), {}).get("parent", "")

func _layout() -> void:
	var scale_xy := size / BASE_SIZE
	for host in placed:
		if not is_instance_valid(host): continue
		var row: Dictionary = host.get_meta("layout_row")
		host.position = Vector2(row.x, row.y) * scale_xy
		host.size = Vector2(row.width, row.height) * scale_xy

static func material_layout(core: Node, content_id: String) -> Dictionary:
	for row in core.catalog.data.get("image_layouts", {}).values():
		if row.kind == "material" and row.ref == content_id: return row
	return {}

static func attach_image(parent: Control, row: Dictionary) -> TextureRect:
	if row.is_empty(): return null
	var texture := load(str(row.image)) as Texture2D
	if texture == null: return null
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = {"contain": TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "cover": TextureRect.STRETCH_KEEP_ASPECT_COVERED, "stretch": TextureRect.STRETCH_SCALE}[row.fit]
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.set_meta("image_path", row.image)
	# 图片置于按钮文本下，保留名称、焦点和原业务动作。
	if parent is Button:
		# Button.text 仍保留给焦点恢复、自动化测试和无障碍查询；绘制时隐藏原生文字，
		# 避免它与图片上的说明标签重复。没有图片时不会进入这里，仍使用普通按钮文字。
		for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]:
			parent.add_theme_color_override(color_name, Color(0, 0, 0, 0))
		var caption := Label.new()
		caption.text = parent.text
		caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		caption.add_theme_font_size_override("font_size", 14)
		caption.add_theme_color_override("font_color", Color.WHITE)
		caption.add_theme_color_override("font_shadow_color", Color.BLACK)
		caption.add_theme_constant_override("shadow_offset_x", 1)
		caption.add_theme_constant_override("shadow_offset_y", 1)
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(caption)
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.offset_left = 4
		caption.offset_right = -4
		caption.offset_bottom = -6
	return rect
