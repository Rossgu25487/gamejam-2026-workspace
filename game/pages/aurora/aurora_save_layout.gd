extends RefCounted
## 存读档页共用的纯显示布局；栏位身份、写入与读取仍由调用页面处理。
const Layout = preload("res://pages/aurora/aurora_entry_layout.gd")
var rules: RefCounted
var owner: Control
var canvas: Control
var panel: PanelContainer
var title: Label
var close: Button
var previous: Button
var next: Button
var page_label: Label
var page_index := 0
var key := "save"
var slots: Array = []
var action: Button
var status: Label
var modal: Control
var modal_canvas: Control
var modal_title: Label
var modal_detail: Label

func bind(page: Control, page_key: String, paper: PanelContainer, old_box: VBoxContainer, close_button: Button) -> void:
	owner = page
	key = page_key
	rules = Layout.new()
	var config := preload("res://systems/aurora/aurora_configuration.gd").new()
	rules.bind(config)
	var data = JSON.parse_string(FileAccess.get_file_as_string(str(config.definition.root).path_join("design/basic/ui_layout/save/ui_layout.json")))
	if data is Dictionary: rules.records = data.get("records", [])
	canvas = Control.new()
	canvas.name = "ArchiveLayout"
	canvas.theme = rules.theme
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	owner.add_child(canvas)
	panel = paper
	panel.reparent(canvas, false)
	old_box.hide()
	title = Label.new()
	title.text = "保存存档" if key == "save" else "读取存档"
	title.add_theme_font_size_override("font_size", 32)
	canvas.add_child(title)
	close = close_button
	close.reparent(canvas, false)
	close.text = "返回"
	rules.button_style(close)
	previous = Button.new()
	previous.text = "上一页"
	previous.pressed.connect(func(): page_index -= 1; layout())
	canvas.add_child(previous)
	rules.button_style(previous)
	next = Button.new()
	next.text = "下一页"
	next.pressed.connect(func(): page_index += 1; layout())
	canvas.add_child(next)
	rules.button_style(next)
	page_label = Label.new()
	page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	page_label.add_theme_font_size_override("font_size", 22)
	canvas.add_child(page_label)
	owner.resized.connect(layout)
	layout()

func set_records(buttons: Array, primary: Button, information: Label) -> void:
	slots = buttons
	action = primary
	status = information
	for node in slots + [action, status]:
		if node.get_parent() != canvas: node.reparent(canvas, false)
		if node is Button: rules.button_style(node, node == action)
	status.add_theme_font_size_override("font_size", 20)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.clip_contents = true
	layout()

func reveal(index: int) -> void:
	page_index = maxi(0, index) / page_capacity()
	layout()

func page_capacity() -> int:
	return 3 if rules.ratio_for(canvas.size.x) == 3 else 6

func bind_confirmation(value: Control) -> void:
	modal = value
	modal_canvas = Control.new()
	modal_canvas.name = "ArchiveConfirmationLayout"
	modal_canvas.theme = rules.theme
	modal_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(modal_canvas)
	modal.panel.reparent(modal_canvas, false)
	modal.box.hide()
	modal_title = Label.new()
	modal_title.add_theme_font_size_override("font_size", 32)
	modal_canvas.add_child(modal_title)
	modal_detail = Label.new()
	modal_detail.add_theme_font_size_override("font_size", 24)
	modal_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_canvas.add_child(modal_detail)
	for button in [modal.cancel_button, modal.direct_button, modal.accept_button]:
		button.reparent(modal_canvas, false)
		rules.button_style(button, button == modal.accept_button)
	modal.visibility_changed.connect(layout_confirmation)
	layout_confirmation()

func decorate(button: Button, label: String, info: Dictionary, selected := false) -> void:
	button.text = label + "\n" + str(info.summary)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.tooltip_text = str(info.get("full_summary", info.summary))
	for child in button.get_children(): button.remove_child(child); child.queue_free()
	var thumb := Label.new()
	thumb.text = "暂无缩略图" if info.get("exists", false) else "空栏位"
	thumb.name = "ThumbnailPlaceholder"
	thumb.add_theme_font_size_override("font_size", 16)
	thumb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	thumb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumb.position = Vector2(24, 42)
	thumb.size = Vector2(112, 63)
	button.add_child(thumb)
	for color in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]: button.add_theme_color_override(color, Color.TRANSPARENT)
	var text := Label.new()
	text.text = ("✓ " if selected else "") + button.text
	text.add_theme_font_size_override("font_size", 22)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.max_lines_visible = 3
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.position = Vector2(156, 18)
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.offset_left = 156
	text.offset_top = 18
	text.offset_right = -26
	text.offset_bottom = -18
	button.add_child(text)
	if selected: button.add_theme_stylebox_override("normal", button.get_theme_stylebox("pressed"))
	else: rules.button_style(button)

func layout() -> void:
	if canvas == null or owner.size.y <= 0: return
	var scale := owner.size.y / 900.0
	canvas.scale = Vector2.ONE * scale
	canvas.size = owner.size / scale
	var ratio: int = rules.ratio_for(canvas.size.x)
	var state := "selected"
	rules.place(panel, rules.row_for(key + ".panel_surface_1", state, ratio), canvas.size)
	rules.place(title, rules.row_for(key + (".text_ui_pause_save_1" if key == "save" else ".text_ui_title_load_1"), state, ratio), canvas.size)
	rules.place(close, rules.row_for(key + ".back", state, ratio), canvas.size)
	var capacity := page_capacity()
	var page_count := maxi(1, ceili(float(slots.size()) / capacity))
	page_index = clampi(page_index, 0, page_count - 1)
	for index in range(slots.size()):
		var slot: Button = slots[index]
		slot.visible = index / capacity == page_index
		if not slot.visible: continue
		var row := slot_row(index % capacity, ratio)
		rules.place(slot, row, canvas.size)
	if is_instance_valid(action): rules.place(action, rules.row_for(key + "." + key, state, ratio), canvas.size)
	if is_instance_valid(status):
		status.position = Vector2(84, 714)
		status.size = Vector2(canvas.size.x - 168, 54)
	for pair in [[previous, Vector2(90, 790), Vector2(160, 56)], [page_label, Vector2(260, 790), Vector2(100, 56)], [next, Vector2(370, 790), Vector2(160, 56)]]:
		pair[0].position = pair[1]
		pair[0].size = pair[2]
		pair[0].visible = page_count > 1
	page_label.text = "%d / %d" % [page_index + 1, page_count]
	previous.disabled = page_index == 0
	next.disabled = page_index + 1 == page_count
	layout_confirmation()

func slot_row(index: int, ratio: int) -> Dictionary:
	var id := ".panel_surface_" + str(index + 2)
	var row: Dictionary = rules.row_for(key + id, "selected", ratio)
	if not row.is_empty(): return row
	# 正式SAVE展示前三栏、LOAD展示前五栏；扩展手动栏复用同一正式网格。
	row = rules.row_for("load" + id, "selected", ratio)
	if not row.is_empty(): return row
	row = rules.row_for("load.panel_surface_6", "selected", ratio).duplicate()
	row.anchor = 6
	row.offset_x = -80
	return row

func layout_confirmation() -> void:
	if not is_instance_valid(modal_canvas) or canvas.size.y <= 0: return
	modal_canvas.scale = canvas.scale
	modal_canvas.size = canvas.size
	modal_title.text = modal.box.get_child(0).text
	modal_detail.text = modal.box.get_child(1).text
	var ratio: int = rules.ratio_for(canvas.size.x)
	var prefix := "overwrite_confirm" if key == "save" else "load_confirm"
	var state := "normal" if key == "save" or modal.accept_button.visible else "save_blocked"
	rules.place(modal.panel, rules.row_for(prefix + ".panel_surface_1", state, ratio), canvas.size)
	rules.place(modal_title, rules.row_for(prefix + (".text_region_2" if key == "save" else ".text_ui_title_load_1"), state, ratio), canvas.size)
	rules.place(modal_detail, rules.row_for(prefix + (".text_region_3" if key == "save" else ".text_ui_load_replace_1"), state, ratio), canvas.size)
	modal_detail.size.y = 210
	rules.place(modal.cancel_button, rules.row_for(prefix + ".cancel", state, ratio), canvas.size)
	if key == "save":
		rules.place(modal.accept_button, rules.row_for(prefix + ".confirm", state, ratio), canvas.size)
	else:
		rules.place(modal.direct_button, rules.row_for(prefix + ".confirm", state, ratio), canvas.size)
		if modal.accept_button.visible: rules.place(modal.accept_button, rules.row_for(prefix + ".confirm_2", state, ratio), canvas.size)
