extends Control
## 现场实物出示与核查草稿分离；只显示实际拥有的准确版本。
const UI = preload("res://pages/core/page_controls.gd")
signal closed
var session: Node
var actor_id := ""

func bind(value: Node) -> void:
	session = value
	mouse_filter = Control.MOUSE_FILTER_STOP
	hide()

func open_for_actor(id: String) -> void:
	if session.mode != "investigation" or session.processing: return
	actor_id = id
	UI.clear(self)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.035, 0.045, 0.9)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 480)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	UI.label(box, "选择要出示的材料", 28)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 340)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for material in session.case_state.data.materials.values():
		for content_id in material.versions:
			var content: Dictionary = session.config.contents[content_id]
			UI.button(list, str(content.name) + " · 第%d版" % int(content.version), _present.bind(str(content_id)))
	UI.button(box, "返回交谈", close)
	show()

func _present(content_id: String) -> void:
	if session.present_material_to(actor_id, content_id): close()

func close() -> void:
	hide()
	closed.emit()

func handle_escape() -> bool:
	if not visible: return false
	close()
	return true
