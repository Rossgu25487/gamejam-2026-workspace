extends Control
## 调查回顾：1600x900 逻辑画布等比缩放居中。读取服务的同一份目标，主目标、待核与进展各自滚动，
## 单份依据在本页内阅读；不推进目标、不收下推论、不保存。返回时恢复原回顾项、滚动位置与有效焦点。

const Layout = preload("res://pages/objective/objective_layout.gd")
const Style = preload("res://pages/objective/objective_style.gd")
const Data = preload("res://systems/objective/objective_data.gd")
const ScrollListScript = preload("res://pages/objective/scroll_list.gd")
const ReadingScript = preload("res://pages/objective/objective_reading_view.gd")
const ERROR_TINT := Color(0.97, 0.74, 0.62)
const PENDING_TINT := Color(0.87, 0.78, 0.61)
const CHECKED_TINT := Color(0.66, 0.72, 0.66)
const RETURN_RECT := Rect2(68, 700, 300, 62)

var service: Node
var review: Dictionary = {}
var hud: Dictionary = {}
var viewport_override := Vector2.ZERO # 测试用：按指定窗口尺寸排版
var colors: Dictionary = {}
var canvas: Control
var title: Label
var caption: Label
var main_list: ScrollContainer
var pending_title: Label
var pending_list: ScrollContainer
var progress_title: Label
var progress_list: ScrollContainer
var return_button: Button
var message_label: Label
var reading: VBoxContainer
var reading_cover: ColorRect
var focus_key := "" # 打开单份阅读或前往核对前所在的控件键
var last_ids := {"pending": [], "progress": []}
var message_id := "" # 持续显示的原因（功能文字 ID）
var message_text := "" # 持续显示的公开原因（来自提供方的原文）
var pending_read := {}
var rebuild_queued := false
var dirty := false
var restore := {}


func bind(objective_service: Node) -> void:
	service = objective_service
	review = service.config.get("review", {})
	hud = service.config.get("hud", {})
	_build()
	service.review_state_changed.connect(_on_state)
	service.changed.connect(_on_changed)
	service.read_completed.connect(_on_read_completed)
	get_viewport().size_changed.connect(_apply_transform)
	hide()


func _build() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP # 回顾期间不操作背后的调查画面
	colors = {"main": Style.color(hud["main_color"]), "body": Style.color(hud["body_color"]), "reason": Style.color(hud["reason_color"])}
	var dim := ColorRect.new()
	dim.color = Color(0.035, 0.04, 0.055, 0.97)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	canvas = Control.new()
	canvas.name = "Canvas"
	canvas.size = Layout.vec(review["viewport"])
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(canvas)
	var button_px := int(review["button_font_px"])
	var button_h := float(review["button_height_px"])
	# 先建返回按钮，使 Tab 顺序从【返回调查】开始。
	return_button = Style.button(canvas, service.label("action_return"), button_px, button_h, func(): service.close_review())
	return_button.name = "ReturnButton"
	return_button.position = RETURN_RECT.position
	return_button.size = RETURN_RECT.size
	title = _place(Style.label(canvas, service.label("label_review"), int(review["title_font_px"]), colors["main"]), Rect2(68, 60, 700, 60))
	caption = _place(Style.label(canvas, service.label("label_current_goal"), int(review["item_font_px"]), colors["reason"]), Rect2(68, 196, 430, 44))
	main_list = _make_list("MainList", _rect(review["main_rect"]), int(review["main_line_height_px"]))
	pending_title = _place(Style.label(canvas, service.label("label_pending"), int(review["item_font_px"]), colors["reason"]), Rect2(558, 240, 945, 44))
	pending_list = _make_list("PendingList", _rect(review["pending_rect"]), int(review["item_line_height_px"]))
	progress_title = _place(Style.label(canvas, service.label("label_progress"), int(review["item_font_px"]), colors["reason"]), Rect2(558, 522, 945, 44))
	progress_list = _make_list("ProgressList", _rect(review["progress_rect"]), int(review["item_line_height_px"]))
	message_label = _place(Style.label(canvas, "", int(review["meta_font_px"]), ERROR_TINT), Rect2(558, 822, 945, 70))
	message_label.name = "Message"
	message_label.hide()
	reading_cover = ColorRect.new() # 单份阅读期间遮住并停用回顾列表
	reading_cover.name = "ReadingCover"
	reading_cover.color = Color(0.035, 0.04, 0.055, 1.0)
	reading_cover.size = canvas.size
	reading_cover.hide()
	canvas.add_child(reading_cover)
	reading = ReadingScript.new()
	reading.name = "Reading"
	reading.position = Vector2(68, 60)
	reading.size = Vector2(1464, 780)
	canvas.add_child(reading)
	reading.setup(service)
	reading.finished.connect(_on_reading_finished)
	reading.visibility_changed.connect(func(): reading_cover.visible = reading.visible)
	_apply_transform()


func _rect(values: Array) -> Rect2:
	return Rect2(float(values[0]), float(values[1]), float(values[2]), float(values[3]))


func _place(node: Control, rect: Rect2) -> Control:
	node.position = rect.position
	node.size = rect.size
	return node


func _make_list(node_name: String, rect: Rect2, line_px: int) -> ScrollContainer:
	var list := ScrollListScript.new()
	list.name = node_name
	list.line_px = line_px
	_place(list, rect)
	canvas.add_child(list)
	list.content.add_theme_constant_override("separation", 14)
	return list


func _viewport_size() -> Vector2:
	return viewport_override if viewport_override != Vector2.ZERO else get_viewport_rect().size


func _apply_transform() -> void:
	if canvas == null:
		return
	var placed := Layout.review_transform(_viewport_size(), Layout.vec(review["viewport"]))
	canvas.scale = Vector2.ONE * float(placed["scale"])
	canvas.position = placed["origin"]


func _on_state(state: String) -> void:
	if state == "open":
		reading.reset()
		message_id = ""
		message_text = ""
		pending_read = {}
		restore = {}
		focus_key = ""
		show()
		_apply_transform()
		_rebuild(true)
		Style.next_frame(self, _focus_return)
	elif visible:
		hide()
		reading.reset()
		message_id = ""
		message_text = ""
		pending_read = {}
		for list in [main_list, pending_list, progress_list]:
			Style.clear(list.content)


func _focus_return() -> void:
	if visible and not reading.visible:
		return_button.grab_focus()


func _on_changed() -> void:
	if not visible or service.review_state != "open":
		return
	if reading.visible:
		dirty = true # 阅读结束后再按最新内容刷新
		return
	if not rebuild_queued:
		rebuild_queued = true
		call_deferred("_rebuild", false)


func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		handle_escape()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_I:
		get_viewport().set_input_as_handled() # 不从回顾另开完整手册，也不穿透回原调查


func handle_escape() -> void:
	# 回顾没有子页时等同【返回调查】；单份阅读中先退一层。
	if reading.visible:
		reading.back()
	else:
		service.close_review()


# ---------- 内容 ----------

func _rebuild(first_open: bool) -> void:
	rebuild_queued = false
	dirty = false
	if not visible or service.review_state != "open":
		return
	var view: Dictionary = service.review_view()
	var before := _capture()
	var content_ids := {"pending": [], "progress": []}
	for list in [main_list, pending_list, progress_list]:
		Style.clear(list.content)
	if view["invalid"]:
		message_id = service.text_id("error_review") # 数据无效：清掉内容与动作，保留返回并提示失败
	elif message_id == service.text_id("error_review"):
		message_id = ""
	if view["invalid"] or view["empty"]:
		# 没有可显示的目标：三个分区各自显示空状态，仍保留返回调查。
		Style.label(main_list.content, service.label("empty_goal"), int(review["main_font_px"]), colors["reason"], int(review["main_line_height_px"]))
		_fill(pending_list, [], "empty_pending", content_ids["pending"])
		_fill(progress_list, [], "empty_progress", content_ids["progress"])
	else:
		Style.label(main_list.content, String(view["goal_text"]), int(review["main_font_px"]), colors["main"], int(review["main_line_height_px"]))
		_fill(pending_list, view["pending"], "empty_pending", content_ids["pending"])
		_fill(progress_list, view["progress"], "empty_progress", content_ids["progress"])
	last_ids = content_ids
	_refresh_message()
	if not first_open:
		restore = before
		restore["new_ids"] = content_ids
	Style.next_frame(self, _apply_restore)


func _fill(list: ScrollContainer, rows: Array, empty_key: String, ids: Array) -> void:
	if rows.is_empty():
		Style.label(list.content, service.label(empty_key), int(review["item_font_px"]), colors["reason"], int(review["item_line_height_px"]))
		return
	for row in rows:
		ids.append(String(row["id"]))
		_build_item(list, row)


func _build_item(list: ScrollContainer, row: Dictionary) -> void:
	var item_px := int(review["item_font_px"])
	var item_line := int(review["item_line_height_px"])
	var meta_px := int(review["meta_font_px"])
	var meta_line := int(review["meta_line_height_px"])
	var button_px := int(review["button_font_px"])
	var button_h := float(review["button_height_px"])
	var item_id := String(row["id"])
	var block := PanelContainer.new()
	block.name = "Item_" + item_id
	block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block.add_theme_stylebox_override("panel", Style.box(Color(1, 1, 1, 0.05), 12))
	block.set_meta("item_id", item_id)
	list.content.add_child(block)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	block.add_child(column)
	# 事项先显示全文与状态，再显示已公开原因、关联依据及可前往的入口。
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	column.add_child(head)
	var checked: bool = row["status"] == "checked"
	var status := Style.label(head, service.label("status_checked" if checked else "status_pending"), meta_px, CHECKED_TINT if checked else PENDING_TINT)
	status.name = "Status"
	status.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	status.custom_minimum_size = Vector2(100, 0)
	status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var text := Style.label(head, String(row["text"]), item_px, colors["body"], item_line)
	text.name = "Text"
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var entry: Dictionary = row["entry"]
	var routed: bool = not entry.is_empty() and bool(entry["available"])
	var go := Style.button(head, service.label("action_investigate"), button_px, button_h, _go.bind(String(entry.get("id", "")), "go:" + item_id), routed)
	go.name = "Go"
	go.set_meta("focus_key", "go:" + item_id)
	go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var notes: Array[String] = []
	var reason := String(row["reason"])
	if not reason.is_empty():
		notes.append(reason)
	if not routed:
		# 暂时无法前往：原因取入口的公开原因，没有时用统一提示；与事项已公开原因相同时不重复显示。
		var route_reason := String(entry.get("reason", "")) if not entry.is_empty() else ""
		var shown: String = route_reason if not route_reason.is_empty() else service.label("no_route")
		go.tooltip_text = shown
		if not notes.has(shown):
			notes.append(shown)
	for note in notes:
		var note_label := Style.label(column, note, meta_px, colors["reason"], meta_line)
		note_label.name = "Note"
	for base in row["bases"]:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 12)
		column.add_child(line)
		var info := Style.label(line, "%s · %s" % [base["name"], base["version_text"]], meta_px, colors["reason"], meta_line)
		info.name = "Basis"
		info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var original := Style.button(line, service.label("action_read"), button_px, button_h, _read.bind(String(base["id"]), false, "orig:%s:%s" % [item_id, base["id"]]), bool(base["has_original"]))
		original.name = "Original_" + String(base["id"])
		original.set_meta("focus_key", "orig:%s:%s" % [item_id, base["id"]])
		var source := Style.button(line, service.label("action_source"), button_px, button_h, _read.bind(String(base["id"]), true, "src:%s:%s" % [item_id, base["id"]]), bool(base["has_source"]))
		source.name = "Source_" + String(base["id"])
		source.set_meta("focus_key", "src:%s:%s" % [item_id, base["id"]])
		if not bool(base["has_original"]):
			original.tooltip_text = service.label("no_basis")
		if not bool(base["has_source"]):
			source.tooltip_text = service.label("no_source")
			var missing := Style.label(column, service.label("no_source"), meta_px, colors["reason"], meta_line)
			missing.name = "NoSource"
	if row["bases"].is_empty():
		var none := Style.label(column, service.label("no_basis"), meta_px, colors["reason"], meta_line)
		none.name = "NoBasis"


# ---------- 动作 ----------

func _go(entry_id: String, key: String) -> void:
	focus_key = key
	message_id = ""
	message_text = ""
	_refresh_message() # 重试开始即清除上一次原因
	var result: Dictionary = service.request_go(entry_id)
	match String(result.get("status", "")):
		"unavailable", "failed":
			var reason := String(result.get("reason", ""))
			message_text = reason if not reason.is_empty() else service.label("no_route")
			_refresh_message()


func _read(basis_id: String, sources_first: bool, key: String) -> void:
	focus_key = key
	message_id = ""
	message_text = ""
	_refresh_message()
	var result: Dictionary = service.request_read(basis_id)
	_handle_read(basis_id, sources_first, key, result)


func _handle_read(basis_id: String, sources_first: bool, key: String, result: Dictionary) -> void:
	match String(result.get("status", "")):
		"ok":
			pending_read = {}
			_remember_position()
			reading.open(result["doc"], sources_first)
		"failed":
			pending_read = {}
			message_id = String(result.get("error", ""))
			_refresh_message()
		"preparing":
			pending_read = {"id": basis_id, "sources_first": sources_first, "key": key}


func _on_read_completed(basis_id: String, result: Dictionary) -> void:
	if visible and not pending_read.is_empty() and pending_read["id"] == basis_id:
		_handle_read(basis_id, bool(pending_read["sources_first"]), String(pending_read["key"]), result)


func _remember_position() -> void:
	restore = _capture()
	restore["focus"] = focus_key


func _on_reading_finished() -> void:
	# 结束单份阅读：回原回顾项，恢复滚动位置与焦点；阅读期间目标变化时按最新内容定位该事项。
	if not visible:
		return
	var state := restore
	restore = {}
	_rebuild(true)
	restore = state
	restore["new_ids"] = last_ids
	Style.next_frame(self, _apply_restore)


func _refresh_message() -> void:
	var text: String = message_text if not message_text.is_empty() else service.resolve(message_id)
	message_label.text = text
	message_label.visible = not text.is_empty()


# ---------- 位置与焦点 ----------

func _capture() -> Dictionary:
	var key := focus_key
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and canvas.is_ancestor_of(focused) and focused.has_meta("focus_key"):
		key = String(focused.get_meta("focus_key"))
	return {"main": main_list.scroll_vertical, "pending": pending_list.scroll_vertical, "progress": progress_list.scroll_vertical, "focus": key, "old_ids": last_ids.duplicate(true)}


func _item_of(key: String) -> String:
	var parts := key.split(":")
	return parts[1] if parts.size() >= 2 else ""


func _list_of(item_id: String, ids: Dictionary) -> String:
	for kind in ["pending", "progress"]:
		if (ids.get(kind, []) as Array).has(item_id):
			return kind
	return ""


func _block_in(list: ScrollContainer, item_id: String) -> Control:
	for child in list.content.get_children():
		if child.has_meta("item_id") and child.get_meta("item_id") == item_id:
			return child
	return null


func _first_button(block: Control) -> Button:
	for node in block.find_children("*", "Button", true, false):
		if not (node as Button).disabled:
			return node
	return null


func find_button(key: String) -> Button:
	for node in canvas.find_children("*", "Button", true, false):
		if node.has_meta("focus_key") and node.get_meta("focus_key") == key:
			return node
	return null


func list_of(kind: String) -> ScrollContainer:
	return pending_list if kind == "pending" else progress_list


func _apply_restore() -> void:
	# 列表布局完成后才能落位：先恢复各区位置，再定位当前事项与焦点。
	if restore.is_empty() or not visible or service.review_state != "open" or reading.visible:
		return
	var state := restore
	restore = {}
	main_list.scroll_to(int(state["main"]))
	pending_list.scroll_to(int(state["pending"]))
	progress_list.scroll_to(int(state["progress"]))
	var key := String(state["focus"])
	var item_id := _item_of(key)
	var target: Button
	if not item_id.is_empty():
		var old_kind := _list_of(item_id, state["old_ids"])
		var new_kind := _list_of(item_id, state["new_ids"])
		if not new_kind.is_empty():
			var list := list_of(new_kind)
			var block := _block_in(list, item_id)
			if new_kind != old_kind and block != null:
				list.scroll_to(int(block.position.y)) # 同一事项移入另一区：在新区定位
			target = find_button(key)
			if target == null and block != null:
				target = _first_button(block)
		elif not old_kind.is_empty():
			# 当前事项被移除：定位原顺序的后一项，没有则前一项。
			var neighbor := Data.neighbor_id(state["old_ids"][old_kind], item_id, state["new_ids"][old_kind])
			if not neighbor.is_empty():
				var list := list_of(old_kind)
				var block := _block_in(list, neighbor)
				if block != null:
					list.scroll_to(int(block.position.y))
					target = _first_button(block)
	elif not key.is_empty():
		target = find_button(key)
	if target != null:
		target.grab_focus()
	else:
		return_button.grab_focus() # 本区为空或原控件已失效时，焦点回【返回调查】
