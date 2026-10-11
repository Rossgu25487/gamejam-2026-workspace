extends Control
## 图片布局由本页面的私有图片层消费，不交给Main摆放控件。

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "settings")

## 设置页只负责控件创建、焦点和设置值的即时提交。

signal closed # 用户请求返回来源页面。

var settings_service: Node # 提供读取、写入和恢复默认设置的服务。
var panel: PanelContainer
var box: VBoxContainer
var controls_box: VBoxContainer
var close_button: Button
var rebuild_queued := false

func _ready() -> void:
	# 页面基础容器只创建一次。
	_build_page()
	hide()

func _build_page() -> void:
	# 创建标题、说明、动态设置控件容器和关闭按钮。
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
	controls_box = VBoxContainer.new()
	controls_box.add_theme_constant_override("separation", 8)
	box.add_child(controls_box)
	close_button = Button.new()
	close_button.text = "关闭设置"
	close_button.pressed.connect(closed.emit)
	box.add_child(close_button)

func open(service: Node) -> void:
	# 每次打开都按当前服务值重建显示控件。
	settings_service = service
	_rebuild_controls()
	show()
	var first_row := controls_box.get_child(0) as HBoxContainer
	if is_instance_valid(first_row) and first_row.get_child_count() > 1:
		(first_row.get_child(1) as Control).grab_focus()

func close_page() -> void:
	# 隐藏设置页，设置值已在操作时即时保存。
	hide()

func _rebuild_controls() -> void:
	# 先移除旧控件，再根据服务中的当前值创建滑条和开关。
	rebuild_queued = false
	# 先从父容器移除旧控件，再延迟释放它们，避免在 pressed/toggled 信号回调
	# 仍持有控件锁时直接 free()。
	while controls_box.get_child_count() > 0:
		var old_control := controls_box.get_child(0)
		controls_box.remove_child(old_control)
		old_control.queue_free()
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = key
		label.custom_minimum_size = Vector2(150, 0)
		row.add_child(label)
		var slider := HSlider.new()
		slider.custom_minimum_size = Vector2(240, 30)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.mouse_filter = Control.MOUSE_FILTER_STOP
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 5
		slider.value = settings_service.get_value(key, 0)
		slider.value_changed.connect(_set_value.bind(key))
		row.add_child(slider)
		controls_box.add_child(row)
	for key in ["mute", "reduce_motion"]:
		var check := CheckButton.new()
		check.text = "静音" if key == "mute" else "减弱动态"
		check.button_pressed = settings_service.get_value(key, false)
		check.toggled.connect(_set_value.bind(key))
		controls_box.add_child(check)
	var reset := Button.new()
	reset.text = "恢复默认"
	reset.pressed.connect(_restore_defaults)
	controls_box.add_child(reset)

func _set_value(value, key: String) -> void:
	# 控件变化立即交给设置服务校验、应用并保存。
	if is_instance_valid(settings_service): settings_service.set_value(key, value if key in ["mute", "reduce_motion"] else int(value))

func _restore_defaults() -> void:
	# 恢复默认需要延迟重建，避开 pressed 信号分发期间的节点锁定。
	if is_instance_valid(settings_service): settings_service.restore_defaults()
	# Button.pressed 仍在分发期间，延迟到本帧信号处理结束后重建控件。
	if not rebuild_queued:
		rebuild_queued = true
		call_deferred("_rebuild_controls")
