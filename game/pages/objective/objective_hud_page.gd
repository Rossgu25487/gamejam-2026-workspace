extends Control
## 当前目标 HUD：只读服务的 hud_view，提交开合与回顾请求；不保存进度，也不推进目标。
## 标题点击展开或收起；待核事项在面板内滚动；回顾入口附近持续显示打开失败的原因。

signal review_requested

const Layout = preload("res://pages/objective/objective_layout.gd")
const Style = preload("res://pages/objective/objective_style.gd")
const ScrollListScript = preload("res://pages/objective/scroll_list.gd")
const ARROW_OPEN := "\u25BE "
const ARROW_FOLDED := "\u25B8 "
const PAD := 10
const GLOW_FILL := Color(1.0, 0.94, 0.72)
const GLOW_PEAK_ALPHA := 0.24
const ERROR_TINT := Color(0.97, 0.74, 0.62)

var service: Node
var hud: Dictionary = {}
var viewport_override := Vector2.ZERO # 测试用：按指定窗口尺寸排版
var panel: PanelContainer
var header: Button
var tag: Label
var body: PanelContainer
var list: ScrollContainer
var review_button: Button
var error_label: Label
var main_label: Label
var blocks: Array[Control] = []
var block_styles: Array[StyleBoxFlat] = []
var colors: Dictionary = {}
var layout_info: Dictionary = {}
var max_height := 340.0
var rendered_revision := -1
var fit_key := ""
var rendered_fit_key := ""
var fit_queued := false
var scroll_target := {"mode": "keep", "item": ""}
var keep_scroll := 0
var first_offset := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()


func bind(objective_service: Node) -> void:
	service = objective_service
	hud = service.config.get("hud", {})
	_build()
	service.changed.connect(_refresh)
	get_viewport().size_changed.connect(_refresh)
	_refresh()


func _build() -> void:
	colors = {"main": Style.color(hud["main_color"]), "body": Style.color(hud["body_color"]), "reason": Style.color(hud["reason_color"])}
	var header_opacity := float(hud["header_opacity"])
	panel = PanelContainer.new() # 默认拦截鼠标：面板内的点击不会触发背后的场景
	panel.name = "Panel"
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	panel.add_child(column)
	header = Button.new()
	header.name = "Header"
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.custom_minimum_size.y = float(hud["header_height_px"])
	header.add_theme_font_size_override("font_size", int(hud["header_font_px"]))
	var header_fill := Color(0.09, 0.08, 0.07, header_opacity)
	var header_lit := Color(0.2, 0.17, 0.12, minf(1.0, header_opacity + 0.24))
	header.add_theme_stylebox_override("normal", Style.box(header_fill, PAD))
	header.add_theme_stylebox_override("hover", Style.box(header_lit, PAD))
	header.add_theme_stylebox_override("pressed", Style.box(header_lit, PAD))
	header.add_theme_stylebox_override("hover_pressed", Style.box(header_lit, PAD))
	header.add_theme_stylebox_override("focus", Style.box(Color.TRANSPARENT, PAD, 2, colors["main"]))
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		header.add_theme_color_override(key, colors["body"])
	header.pressed.connect(func(): service.toggle_expanded())
	column.add_child(header)
	tag = Label.new() # 收起时的“更新”标记与展开后的“已更新”短提示
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tag.offset_right = -PAD
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Style.style_text(tag, int(hud["reason_font_px"]), colors["main"])
	header.add_child(tag)
	body = PanelContainer.new()
	body.name = "Body"
	body.add_theme_stylebox_override("panel", Style.box(Color(0.05, 0.045, 0.04, float(hud["panel_opacity"])), PAD))
	column.add_child(body)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	body.add_child(inner)
	list = ScrollListScript.new()
	list.name = "List"
	list.line_px = int(hud["body_line_height_px"])
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.scrolled.connect(_report_first)
	inner.add_child(list)
	error_label = Style.label(inner, "", int(hud["reason_font_px"]), ERROR_TINT, int(hud["body_line_height_px"]) - 6)
	error_label.name = "Error"
	error_label.hide()
	review_button = Style.button(inner, "", int(hud["header_font_px"]), 32.0, func(): review_requested.emit())
	review_button.name = "ReviewButton"
	set_process(false)


func _viewport_size() -> Vector2:
	return viewport_override if viewport_override != Vector2.ZERO else get_viewport_rect().size


func reserved_width() -> float:
	# 展开且显示时，调查页右侧需要为面板让出的宽度；收起或隐藏后恢复原区域。
	if not visible or not bool(service.model.expanded):
		return 0.0
	return maxf(0.0, _viewport_size().x - panel.position.x + 12.0)


func _refresh() -> void:
	if service == null or header == null:
		return
	var view: Dictionary = service.hud_view()
	visible = bool(view["shown"])
	if not visible:
		set_process(false)
		return
	var expanded := bool(view["expanded"])
	layout_info = Layout.hud_layout(_viewport_size(), hud)
	max_height = float(layout_info["max_height"])
	panel.position = Vector2(float(layout_info["left"]), float(layout_info["top"]))
	panel.custom_minimum_size.x = float(layout_info["width"]) if expanded else float(hud["fold_width_px"])
	header.text = (ARROW_OPEN if expanded else ARROW_FOLDED) + service.label("label_current_goal")
	if bool(view["marker"]):
		tag.text = service.label("label_update")
	elif bool(view["notice"]):
		tag.text = service.label("label_updated")
	else:
		tag.text = ""
	tag.visible = not tag.text.is_empty()
	body.visible = expanded
	review_button.text = service.label("label_review")
	var error_text: String = service.resolve(String(view["error"]))
	error_label.text = error_text
	error_label.visible = not error_text.is_empty()
	if expanded:
		if int(view["content_revision"]) != rendered_revision:
			_rebuild(view)
		fit_key = "%s|%s|%s|%s" % [panel.custom_minimum_size.x, max_height, view["content_revision"], error_text]
		if fit_key != rendered_fit_key:
			_queue_fit()
	panel.reset_size()
	_apply_glow(float(view["glow"]))
	set_process(float(view["glow"]) > 0.0)


func _rebuild(view: Dictionary) -> void:
	rendered_revision = int(view["content_revision"])
	scroll_target = service.take_scroll()
	keep_scroll = list.scroll_vertical
	var content: VBoxContainer = list.content
	Style.clear(content)
	blocks.clear()
	block_styles.clear()
	content.add_theme_constant_override("separation", 8)
	main_label = Style.label(content, String(view["goal_text"]), int(hud["main_font_px"]), colors["main"], int(hud["main_line_height_px"]))
	for item in view["items"]:
		var block := PanelContainer.new() # 条目提亮用底色变化表现，不影响文字布局
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := Style.box(Color(GLOW_FILL, 0.0), 3)
		block.add_theme_stylebox_override("panel", fill)
		block.set_meta("item_id", item["id"])
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 2)
		block.add_child(column)
		Style.label(column, String(item["text"]), int(hud["body_font_px"]), colors["body"], int(hud["body_line_height_px"]))
		if not String(item["reason"]).is_empty():
			Style.label(column, String(item["reason"]), int(hud["reason_font_px"]), colors["reason"], int(hud["body_line_height_px"]) - 6)
		content.add_child(block)
		blocks.append(block)
		block_styles.append(fill)
	fit_key = ""
	rendered_fit_key = ""


func _queue_fit() -> void:
	# 等布局完成后再按真实内容高度设定列表高度；用一次性帧信号，页面被释放时自动失效。
	if fit_queued:
		return
	fit_queued = true
	Style.next_frame(self, _fit)


func _fit() -> void:
	fit_queued = false
	if not visible or not body.visible:
		rendered_fit_key = ""
		return
	rendered_fit_key = fit_key
	var chrome := body.get_combined_minimum_size().y - list.get_combined_minimum_size().y
	var room := maxf(float(hud["body_line_height_px"]), max_height - header.get_combined_minimum_size().y - chrome)
	var wanted: float = list.content.get_combined_minimum_size().y
	var limit := int(hud["visible_item_limit"])
	if blocks.size() > limit:
		# 同屏最多显示 limit 条：以第 limit 条的下沿为界，其余通过滚动查看；长项换行后同屏自然更少。
		var last: Control = blocks[limit - 1]
		wanted = minf(wanted, last.position.y + last.size.y)
	list.custom_minimum_size.y = minf(wanted, room)
	panel.reset_size()
	Style.next_frame(self, _apply_scroll)


func _apply_scroll() -> void:
	# 列表高度生效后再落位：置顶、定位到后一项（沿用原第一条可见项的位置）或保持原位置。
	match String(scroll_target["mode"]):
		"top":
			list.scroll_to(0)
		"item":
			var block := _block_for(String(scroll_target["item"]))
			list.scroll_to(int(block.position.y - first_offset) if block != null else keep_scroll)
		_:
			list.scroll_to(keep_scroll)
	scroll_target = {"mode": "keep", "item": ""}
	_report_first()


func _block_for(item_id: String) -> Control:
	for block in blocks:
		if block.get_meta("item_id") == item_id:
			return block
	return null


func _report_first() -> void:
	# 回报第一条可见的待核事项与它距列表顶部的位置，供下次内容变化时定位。
	if service == null or not body.visible:
		return
	var top := float(list.scroll_vertical)
	var first := ""
	for block in blocks:
		if block.position.y + block.size.y > top + 1.0:
			first = String(block.get_meta("item_id"))
			first_offset = block.position.y - top
			break
	service.report_scroll(first)


func _apply_glow(fraction: float) -> void:
	for style in block_styles:
		style.bg_color = Color(GLOW_FILL, GLOW_PEAK_ALPHA * fraction)


func _process(_delta: float) -> void:
	# 只在 0.3 秒提亮期间逐帧运行。
	var fraction: float = service.glow_fraction()
	_apply_glow(fraction)
	if fraction <= 0.0:
		set_process(false)
