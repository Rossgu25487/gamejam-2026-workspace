extends Control
## 地图页面私有逻辑：显示当前地点、可达节点和前往/取消操作。

const UI = preload("res://pages/core/page_controls.gd")
var service: Node

func bind(value: Node) -> void:
	service = value
	if service != null and not service.changed.is_connected(_render): service.changed.connect(_render)
	_render()

func open() -> void:
	if service != null and service.open():
		show()
		_render()

func close() -> void:
	if service != null: service.cancel()
	hide()

func _ready() -> void:
	hide()
	mouse_filter = Control.MOUSE_FILTER_STOP

func _render() -> void:
	if not is_inside_tree() or service == null or not visible: return
	for child in get_children(): child.queue_free()
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 560)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	UI.label(box, "地图", 30)
	UI.label(box, "当前地点：" + service.current_scene_id(), 18)
	var list := VBoxContainer.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list)
	for item in service.available_transitions():
		var title := str(item.get("title", item.get("to_scene", "前往")))
		if not bool(item.get("available", false)): title += "（" + str(item.reason) + "）"
		var button := UI.button(list, title, service.select_transition.bind(str(item.transition_id)), bool(item.available))
		if item.selected: button.grab_focus()
	var travel_button := UI.button(box, "前往", service.travel)
	travel_button.disabled = str(service.state.get("selected_transition_id", "")).is_empty()
	UI.button(box, "返回调查", close)
