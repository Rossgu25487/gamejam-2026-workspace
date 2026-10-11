extends VBoxContainer
## 调查入口和普通会话各自管理私有控件，不由 Main 生成热点或台词。

const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var focus_key := ""

func render(core: Node, image_buttons: Dictionary = {}, image_bindings: Dictionary = {}) -> void:
	service = core
	UI.clear(self)
	var data: Dictionary = core.catalog.data
	var state: Dictionary = core.state
	UI.label(self, core.catalog.text(data.scenes[state.current_scene_id].name), 28)
	UI.label(self, core.catalog.text("package_note"), 16)
	if state.mode == "dialogue":
		var entry: Dictionary = data.entries[state.current_node_id]
		var character_id: String = entry.get("object_id", "")
		if data.characters.has(character_id): UI.label(self, core.catalog.text(data.characters[character_id].name), 22)
		UI.body(self, core.catalog.text(entry.text), 240)
		UI.button(self, core.ui("UI_RETURN_INVESTIGATION"), core.finish_dialogue)
		return
	var scroll := ScrollContainer.new()
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var list := VBoxContainer.new()
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 12)
	scroll.add_child(list)
	if not image_buttons.is_empty():
		# 给按屏幕坐标摆放的图片卡留出空间；问题和移动按钮接着排在下方。
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bottom := 0.0
		for b in image_buttons.values(): bottom = maxf(bottom, b.get_global_rect().end.y)
		spacer.custom_minimum_size.y = maxf(0, bottom - get_global_rect().position.y - 65)
		list.add_child(spacer)
	for id in data.entries:
		var entry: Dictionary = data.entries[id]
		if not str(entry.get("scene_id", "")).is_empty() and entry.scene_id != state.current_scene_id: continue
		if image_bindings.has(id): continue
		var b := UI.button(list, core.catalog.text(entry.title), _activate.bind(id), core.condition_met(entry.condition))
		b.set_meta("focus_key", id)
	UI.label(list, "待核问题", 24)
	for id in data.questions:
		var q: Dictionary = data.questions[id]
		if not str(q.get("scene_id", "")).is_empty() and q.scene_id != state.current_scene_id: continue
		var completed: bool = id in state.completed_questions
		var b := UI.button(list, core.catalog.text(q.title) + (" · 回看" if completed else ""), _question.bind(id), core.condition_met(q.condition))
		b.set_meta("focus_key", id)
	for id in data.get("scene_links", {}):
		var link: Dictionary = data.scene_links[id]
		if link.from_scene != state.current_scene_id: continue
		var b := UI.button(list, core.catalog.text(link.title), core.move_scene.bind(id), core.condition_met(link.condition))
		b.set_meta("focus_key", id)
	var completion: String = data.get("completion_condition", "")
	if not completion.is_empty() and core.condition_met(completion): UI.label(list, core.catalog.text(data.completion_text), 22)
	_restore_focus(list)
	if image_buttons.has(focus_key) and not image_buttons[focus_key].disabled: image_buttons[focus_key].grab_focus()

func activate_entry(id: String) -> void:
	# 图片入口和文字入口共用同一个页面动作，业务由服务再次校验。
	_activate(id)

func _activate(id: String) -> void:
	focus_key = id
	service.activate_entry(id)

func _question(id: String) -> void:
	focus_key = id
	service.open_card_session(id, {"page": "investigation", "focus_key": id, "scene_id": service.state.current_scene_id})

func _restore_focus(list: Node) -> void:
	for node in list.get_children():
		if node is Button and not node.disabled and node.get_meta("focus_key", "") == focus_key:
			node.grab_focus()
