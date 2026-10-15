extends VBoxContainer
## 回顾内的单份依据阅读：依据 -> 来源逐层查看；上一级、关闭来源、返回调查回顾。
## 只读取并显示，不更新目标、不收下推论、不保存；Esc 退一层，I 不新开完整手册。

signal finished # 结束单份阅读，回到原回顾项

const Style = preload("res://pages/objective/objective_style.gd")
const ScrollListScript = preload("res://pages/objective/scroll_list.gd")
const KEY_UP_LEVEL := "UI_HANDBOOK_SOURCE_UP"
const KEY_CLOSE_SOURCE := "UI_HANDBOOK_SOURCE_CLOSE"
const KEY_RETURN_REVIEW := "UI_HANDBOOK_RETURN_REVIEW"
const KEY_SOURCE := "UI_HANDBOOK_SOURCE"
const KEY_SOURCE_NONE := "UI_HANDBOOK_SOURCE_NONE"
const ERROR_TINT := Color(0.97, 0.74, 0.62)

var service: Node
var review: Dictionary = {}
var stack: Array = [] # 层栈：{"kind": "doc" / "sources", "doc": 依据, "scroll": 阅读位置}
var header_box: HBoxContainer
var content: VBoxContainer
var error_label: Label
var up_button: Button
var close_button: Button
var return_button: Button
var body: RichTextLabel
var pending_id := ""
var error_id := ""
var title_px := 36
var meta_px := 27
var button_px := 28
var button_h := 62.0
var colors: Dictionary = {}


func setup(objective_service: Node) -> void:
	service = objective_service
	review = service.config.get("review", {})
	title_px = int(review.get("title_font_px", 40)) - 4
	meta_px = int(review.get("meta_font_px", 27))
	button_px = int(review.get("button_font_px", 28))
	button_h = float(review.get("button_height_px", 62))
	var hud: Dictionary = service.config.get("hud", {})
	colors = {"main": Style.color(String(hud.get("main_color", "#DDC89B"))), "body": Style.color(String(hud.get("body_color", "#EEE9DE"))), "reason": Style.color(String(hud.get("reason_color", "#D6CFC2")))}
	add_theme_constant_override("separation", 12)
	header_box = HBoxContainer.new()
	header_box.add_theme_constant_override("separation", 12)
	add_child(header_box)
	content = VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	add_child(content)
	error_label = Style.label(self, "", meta_px, ERROR_TINT)
	error_label.hide()
	service.read_completed.connect(_on_read_completed)
	hide()


func is_reading() -> bool:
	return visible


func open(doc: Dictionary, sources_first: bool) -> void:
	# 打开一份准确依据；“查看来源”入口直接进入来源层，上一级回到本次依据。
	stack = [{"kind": "doc", "doc": doc, "scroll": 0}]
	if sources_first and not (doc.get("sources", []) as Array).is_empty():
		stack.append({"kind": "sources", "doc": doc, "scroll": 0})
	error_id = ""
	pending_id = ""
	show()
	_render()


func reset() -> void:
	stack.clear()
	pending_id = ""
	error_id = ""
	hide()


func back() -> void:
	# Esc 与【上一级】：退一层来源；第一层回到本次单份依据，再退一层才结束阅读。
	if stack.size() > 1:
		_pop_to(stack.size() - 2)
	else:
		finish()


func close_source() -> void:
	# 【关闭来源】：回到打开来源的同一依据与阅读位置。
	if stack.size() > 1:
		_pop_to(0)


func finish() -> void:
	reset()
	finished.emit()


func _pop_to(index: int) -> void:
	_save_scroll()
	stack.resize(index + 1)
	error_id = ""
	_render()


func _push(level: Dictionary) -> void:
	_save_scroll()
	stack.append(level)
	error_id = ""
	_render()


func _save_scroll() -> void:
	if not stack.is_empty() and is_instance_valid(body):
		stack[-1]["scroll"] = int(body.get_v_scroll_bar().value)


func _render() -> void:
	Style.clear(header_box)
	Style.clear(content)
	body = null
	var level: Dictionary = stack[-1]
	var doc: Dictionary = level["doc"]
	var title := Style.label(header_box, String(doc.get("title", "")), title_px, colors["main"])
	title.name = "Title"
	if level["kind"] == "sources":
		title.text = service.resolve(KEY_SOURCE)
	up_button = Style.button(header_box, service.resolve(KEY_UP_LEVEL), button_px, button_h, back)
	up_button.name = "UpButton"
	up_button.visible = stack.size() > 1
	close_button = Style.button(header_box, service.resolve(KEY_CLOSE_SOURCE), button_px, button_h, close_source)
	close_button.name = "CloseSourceButton"
	close_button.visible = stack.size() > 1
	return_button = Style.button(header_box, service.resolve(KEY_RETURN_REVIEW), button_px, button_h, finish)
	return_button.name = "ReturnReviewButton"
	if level["kind"] == "sources":
		_render_sources(doc)
	else:
		_render_doc(doc)
	_refresh_error()
	Style.next_frame(self, _restore.bind(int(level["scroll"])))


func _render_doc(doc: Dictionary) -> void:
	var version := String(doc.get("version_text", ""))
	if not version.is_empty():
		Style.label(content, version, meta_px, colors["reason"])
	body = RichTextLabel.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.custom_minimum_size.y = 300.0
	body.focus_mode = Control.FOCUS_ALL
	body.text = String(doc.get("body", ""))
	Style.style_text(body, button_px, colors["body"])
	content.add_child(body)
	var sources: Array = doc.get("sources", [])
	var source_button := Style.button(content, service.resolve(KEY_SOURCE), button_px, button_h, _open_sources.bind(doc), not sources.is_empty())
	source_button.name = "SourceButton"
	if sources.is_empty():
		source_button.tooltip_text = service.resolve(KEY_SOURCE_NONE)
		Style.label(content, service.resolve(KEY_SOURCE_NONE), meta_px, colors["reason"])
	return_button.grab_focus()


func _render_sources(doc: Dictionary) -> void:
	var sources: Array = doc.get("sources", [])
	var list := ScrollListScript.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.custom_minimum_size.y = 300.0
	list.line_px = int(review.get("item_line_height_px", 42))
	content.add_child(list)
	list.content.add_theme_constant_override("separation", 12)
	var first: Button
	for source in sources:
		var button := Style.button(list.content, String(source["title"]), button_px, button_h, _open_source.bind(String(source["id"])))
		button.name = "Source_" + String(source["id"])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if first == null:
			first = button
	if sources.is_empty():
		Style.label(list.content, service.resolve(KEY_SOURCE_NONE), meta_px, colors["reason"])
	if first != null:
		first.grab_focus()
	else:
		return_button.grab_focus()


func _open_sources(doc: Dictionary) -> void:
	_push({"kind": "sources", "doc": doc, "scroll": 0})


func _open_source(source_id: String) -> void:
	# 读取该来源的内容；失败时留在原层并持续显示原因，重试开始或离开时清除。
	error_id = ""
	_refresh_error()
	var result: Dictionary = service.request_read(source_id)
	_handle_result(source_id, result)


func _on_read_completed(basis_id: String, result: Dictionary) -> void:
	if visible and pending_id == basis_id:
		_handle_result(basis_id, result)


func _handle_result(source_id: String, result: Dictionary) -> void:
	match String(result.get("status", "")):
		"ok":
			pending_id = ""
			_push({"kind": "doc", "doc": result["doc"], "scroll": 0})
		"failed":
			pending_id = ""
			error_id = String(result.get("error", ""))
			_refresh_error()
		"preparing":
			pending_id = source_id # 准备成功后才切层，同一请求只处理一次


func _refresh_error() -> void:
	var text: String = service.resolve(error_id)
	error_label.text = text
	error_label.visible = not text.is_empty()


func _restore(scroll: int) -> void:
	if is_instance_valid(body):
		body.get_v_scroll_bar().value = float(scroll)
