extends Control
## 设置页只负责控件创建、焦点和设置值的即时提交。

signal closed

var settings_service: Node
var panel: PanelContainer
var box: VBoxContainer

func _ready() -> void:
	_build_page()
	hide()

func _build_page() -> void:
	var host := CenterContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	host.add_child(panel)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "游戏设置"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)
	var detail := Label.new()
	detail.text = "设置会独立保存，不会被调查存档覆盖。"
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(detail)
	var close := Button.new()
	close.text = "关闭设置"
	close.pressed.connect(closed.emit)
	box.add_child(close)

func open(service: Node) -> void:
	settings_service = service
	_rebuild_controls()
	show()
	var first_row := box.get_child(3) as HBoxContainer
	if is_instance_valid(first_row) and first_row.get_child_count() > 1:
		(first_row.get_child(1) as Control).grab_focus()

func close_page() -> void:
	hide()

func _rebuild_controls() -> void:
	while box.get_child_count() > 3:
		box.get_child(3).queue_free()
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = key
		row.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 5
		slider.value = settings_service.get_value(key, 0)
		slider.value_changed.connect(_set_value.bind(key))
		row.add_child(slider)
		box.add_child(row)
	for key in ["mute", "reduce_motion"]:
		var check := CheckButton.new()
		check.text = "静音" if key == "mute" else "减弱动态"
		check.button_pressed = settings_service.get_value(key, false)
		check.toggled.connect(_set_value.bind(key))
		box.add_child(check)
	var reset := Button.new()
	reset.text = "恢复默认"
	reset.pressed.connect(_restore_defaults)
	box.add_child(reset)
	var close := box.get_child(2) as Button
	box.move_child(close, box.get_child_count() - 1)

func _set_value(value, key: String) -> void:
	if is_instance_valid(settings_service): settings_service.set_value(key, value if key in ["mute", "reduce_motion"] else int(value))

func _restore_defaults() -> void:
	if is_instance_valid(settings_service): settings_service.restore_defaults()
	_rebuild_controls()
