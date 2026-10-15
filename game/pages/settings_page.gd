extends Control
## 图片布局由本页面的私有图片层消费，不交给Main摆放控件。

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "settings")

## 设置页只负责控件创建、焦点和设置值的即时提交。

signal closed # 用户请求返回来源页面。
signal sfx_manager_requested # 用户请求打开音效库管理界面。

const VOLUME_LABELS := { # 设置键 -> [功能文字 ID, 后备文字]
	"master_volume": ["UI_SETTINGS_MASTER", "总音量"],
	"bgm_volume": ["UI_SETTINGS_BGM", "背景音乐"],
	"ambient_volume": ["UI_SETTINGS_AMBIENT", "环境声音"],
	"effect_volume": ["UI_SETTINGS_EFFECT", "效果音"],
}

var settings_service: Node # 提供读取、写入和恢复默认设置的服务。
var audio_service: Node # 提供试听资格与试听播放；可为空。
var text_of: Callable # 功能文字查询，参数为功能文字 ID。
var preview_button: Button
var preview_reason: Label
var sfx_manager_button: Button
var panel: PanelContainer
var box: VBoxContainer
var controls_box: VBoxContainer
var close_button: Button
var rebuild_queued := false
var developer_tools_enabled := false

func set_developer_tools_enabled(enabled: bool) -> void:
	developer_tools_enabled = enabled
	if is_instance_valid(sfx_manager_button): sfx_manager_button.visible = enabled

func focus_sfx_manager() -> void:
	if is_instance_valid(sfx_manager_button) and sfx_manager_button.is_visible_in_tree(): sfx_manager_button.grab_focus()

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

func open(service: Node, audio: Node = null, texts: Callable = Callable()) -> void:
	# 每次打开都按当前服务值重建显示控件。
	settings_service = service
	audio_service = audio
	text_of = texts
	_rebuild_controls()
	show()
	var first_row := controls_box.get_child(0) as HBoxContainer
	if is_instance_valid(first_row) and first_row.get_child_count() > 1:
		(first_row.get_child(1) as Control).grab_focus()

func close_page() -> void:
	# 隐藏设置页，设置值已在操作时即时保存；离开设置时停止试听。
	if is_instance_valid(audio_service): audio_service.stop_preview()
	hide()

func _text(key: String, fallback: String) -> String:
	# 固定文字统一来自功能文字表；没有提供查询时使用后备文字。
	if text_of.is_valid():
		var value: String = text_of.call(key)
		if value != key: return value
	return fallback

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
		label.text = _text(VOLUME_LABELS[key][0], VOLUME_LABELS[key][1])
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
		check.text = _text("UI_SETTINGS_MUTE", "静音") if key == "mute" else _text("UI_SETTINGS_REDUCE_MOTION", "减弱动态")
		check.button_pressed = settings_service.get_value(key, false)
		check.toggled.connect(_set_value.bind(key))
		controls_box.add_child(check)
	# 试听复用反馈事件；条件不满足时只禁用试听并说明原因，其他设置保持可用。
	preview_button = Button.new()
	preview_button.text = _text("UI_SETTINGS_PREVIEW", "试听效果音")
	preview_button.set_meta("ui_sound", "none") # 试听不叠加普通点击音。
	preview_button.pressed.connect(_preview)
	controls_box.add_child(preview_button)
	preview_reason = Label.new()
	preview_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_box.add_child(preview_reason)
	_refresh_preview()
	sfx_manager_button = Button.new()
	sfx_manager_button.text = _text("UI_SETTINGS_SFX_MANAGER", "音效库管理")
	sfx_manager_button.pressed.connect(sfx_manager_requested.emit)
	sfx_manager_button.visible = developer_tools_enabled
	controls_box.add_child(sfx_manager_button)
	var reset := Button.new()
	reset.text = _text("UI_SETTINGS_RESET", "恢复默认")
	reset.pressed.connect(_restore_defaults)
	controls_box.add_child(reset)

func _set_value(value, key: String) -> void:
	# 控件变化立即交给设置服务校验、应用并保存。
	if is_instance_valid(settings_service): settings_service.set_value(key, value if key in ["mute", "reduce_motion"] else int(value))
	_refresh_preview()

func _refresh_preview() -> void:
	# 按音频服务给出的资格刷新试听按钮；没有音频服务时按素材未就绪处理。
	if not is_instance_valid(preview_button): return
	var state: Dictionary = audio_service.preview_state() if is_instance_valid(audio_service) else {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_UNREADY"}
	preview_button.disabled = not state["enabled"]
	preview_reason.text = "" if state["enabled"] else _text(String(state["reason"]), "试听素材未就绪")
	preview_reason.visible = not state["enabled"]

func _preview() -> void:
	if is_instance_valid(audio_service): audio_service.preview_effect()

func _restore_defaults() -> void:
	# 恢复默认需要延迟重建，避开 pressed 信号分发期间的节点锁定。
	if is_instance_valid(settings_service): settings_service.restore_defaults()
	# Button.pressed 仍在分发期间，延迟到本帧信号处理结束后重建控件。
	if not rebuild_queued:
		rebuild_queued = true
		call_deferred("_rebuild_controls")
