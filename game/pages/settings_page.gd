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
var controls_scroll: ScrollContainer
var close_button: Button
var rebuild_queued := false
var developer_tools_enabled := false
var reset_button: Button
var retry_button: Button
var status_label: Label
var reset_confirmation: Control
var sliders := {}
var brightness_slider: HSlider
var brightness_number: Label
var volume_numbers := {}
var adjusting := false
var adjustment_key := ""
var tabs: HBoxContainer
var current_tab := "sound"
var tab_buttons := {}
var candidate_display := {}
var mode_option: OptionButton
var size_option: OptionButton
var aspect_option: OptionButton
var apply_display_button: Button
var display_confirm: Control
var display_confirmation_visible := false
var last_preview_second := -1
var window_presets: Array = []
var formal_layout: RefCounted
var formal_canvas: Control
var formal_panel: Panel
var formal_nodes := {}
var formal_dynamic: Array[Control] = []
var formal_title: Label
var legacy_host: Control
var sample_worlds: Array[Control] = []
var scene_preview_overlay: Control
var settings_texts := {}

func configure_formal(config: RefCounted) -> void:
	formal_layout = preload("res://pages/aurora/aurora_entry_layout.gd").new()
	formal_layout.bind(config)
	var source = JSON.parse_string(FileAccess.get_file_as_string(str(config.definition.root).path_join("design/basic/ui_layout/settings/ui_layout.json")))
	if source is Dictionary: formal_layout.records = source.get("records", [])
	settings_texts.clear()
	for row in config.rows("settings", "界面文本绑定"):
		if not str(row.get("display_text", "")).is_empty(): settings_texts[str(row.text_id)] = str(row.display_text)
	if is_instance_valid(formal_canvas) and is_instance_valid(formal_panel):
		formal_canvas.theme = formal_layout.theme
		_layout_panel()

func set_developer_tools_enabled(enabled: bool) -> void:
	developer_tools_enabled = enabled
	if is_instance_valid(sfx_manager_button): sfx_manager_button.visible = enabled

func focus_sfx_manager() -> void:
	if is_instance_valid(sfx_manager_button) and sfx_manager_button.is_visible_in_tree(): sfx_manager_button.grab_focus()

func _ready() -> void:
	# 页面基础容器只创建一次。
	_build_page()
	resized.connect(_layout_panel)
	_layout_panel()
	hide()

func _build_page() -> void:
	# 创建标题、说明、动态设置控件容器和关闭按钮。
	var host := CenterContainer.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(host)
	legacy_host = host
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 0)
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
	tabs = HBoxContainer.new()
	box.add_child(tabs)
	for pair in [["display", "显示"], ["sound", "声音"], ["presentation", "表现"], ["controls", "操作"]]:
		var tab := Button.new()
		tab.text = pair[1]
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(_switch_tab.bind(str(pair[0])))
		tabs.add_child(tab)
		tab_buttons[pair[0]] = tab
	controls_scroll = ScrollContainer.new()
	controls_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	controls_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(controls_scroll)
	controls_box = VBoxContainer.new()
	controls_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_box.add_theme_constant_override("separation", 8)
	controls_scroll.add_child(controls_box)
	close_button = Button.new()
	close_button.text = "关闭设置"
	close_button.pressed.connect(_request_close)
	box.add_child(close_button)
	# 旧容器只保存创建接口。实际控件沿正式布局放在独立高900参考层中。
	host.hide()
	formal_canvas = Control.new()
	formal_canvas.name = "SettingsLayout"
	formal_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(formal_canvas)
	if formal_layout == null: configure_formal(preload("res://systems/aurora/aurora_configuration.gd").new())
	formal_canvas.theme = formal_layout.theme
	formal_panel = formal_layout.panel(formal_canvas)
	formal_panel.name = "SettingsPaperPanel"
	formal_title = Label.new()
	formal_title.text = "游戏设置"
	formal_title.add_theme_font_size_override("font_size", 32)
	formal_canvas.add_child(formal_title)
	formal_nodes[formal_title] = "settings.text_ui_title_settings_1"
	for key in tab_buttons:
		var button: Button = tab_buttons[key]
		button.toggle_mode = true
		button.reparent(formal_canvas, false)
		formal_nodes[button] = "settings.tab_" + ("motion" if key == "presentation" else str(key))
		formal_layout.button_style(button)
	close_button.reparent(formal_canvas, false)
	close_button.text = "返回"
	formal_nodes[close_button] = "settings.back"
	formal_layout.button_style(close_button)
	# 共用确认组件作为设置页自己的子节点；取消默认聚焦且遮住下层输入。
	reset_confirmation = preload("res://pages/confirm_page.tscn").instantiate()
	add_child(reset_confirmation)
	reset_confirmation.cancelled.connect(_cancel_reset)
	reset_confirmation.accepted.connect(_confirm_reset)
	display_confirm = preload("res://pages/confirm_page.tscn").instantiate()
	add_child(display_confirm)
	display_confirm.cancelled.connect(_revert_display)
	display_confirm.accepted.connect(_keep_display)

func _layout_panel() -> void:
	if not is_instance_valid(formal_canvas) or formal_layout == null or size.y <= 0: return
	var factor := size.y / 900.0
	formal_canvas.scale = Vector2.ONE * factor
	formal_canvas.size = size / factor
	var ratio: int = formal_layout.ratio_for(formal_canvas.size.x)
	var state := "motion" if current_tab == "presentation" else current_tab
	formal_layout.place(formal_panel, formal_layout.row_for("settings.panel_surface_1", state, ratio), formal_canvas.size)
	for node in formal_nodes:
		if not is_instance_valid(node): continue
		var node_state := "motion" if node.get_meta("settings_tab", current_tab) == "presentation" else str(node.get_meta("settings_tab", current_tab))
		var row: Dictionary = formal_layout.row_for(str(formal_nodes[node]), node_state, ratio)
		formal_layout.place(node, row, formal_canvas.size)
		if node is Button and not row.is_empty():
			var skin := str(row.get("asset_id", ""))
			if skin.ends_with("_pressed"): node.add_theme_stylebox_override("normal", node.get_theme_stylebox("pressed"))
			elif node.has_theme_stylebox_override("normal"):
				formal_layout.button_style(node, skin.contains("primary"))
		if node.has_meta("settings_tab"): node.visible = str(node.get_meta("settings_tab")) == current_tab
		if str(formal_nodes[node]) == "settings.scene_frame.2" or str(formal_nodes[node]) == "settings.preview":
			node.visible = node.visible and not row.is_empty()
		if node is Label and str(formal_nodes[node]).begins_with("settings.text_ui_settings_motion_"):
			node.size.x = minf(node.size.x, 600 if ratio != 3 else node.size.x)
	for world in sample_worlds:
		if not is_instance_valid(world): continue
		var sample: Control = world.get_parent()
		var host: Control = sample.get_parent()
		if sample.has_meta("sample_size"):
			var original: Vector2 = sample.get_meta("sample_size")
			var factor_sample := minf(host.size.x / original.x, host.size.y / original.y)
			sample.scale = Vector2.ONE * factor_sample
	# 标签所在正式行覆盖整个内容带；实际文字区域截到其右侧控件前，避免挡住滑杆输入。
	for pair in [["master_volume", "settings."], ["bgm_volume", "settings._2"], ["ambient_volume", "settings._3"], ["effect_volume", "settings._4"]]:
		var label: Control = formal_canvas.get_node_or_null("VolumeLabel_" + str(pair[0]))
		if label != null and sliders.has(pair[0]): label.size.x = maxf(1, sliders[pair[0]].position.x - label.position.x - 24)
	for node in formal_dynamic:
		if not is_instance_valid(node) or not node.has_meta("label_for"): continue
		var target: Control = node.get_meta("label_for")
		if is_instance_valid(target): node.size.x = maxf(1, target.position.x - node.position.x - 24)
	if is_instance_valid(status_label):
		status_label.position = Vector2(formal_panel.position.x + 64, formal_panel.position.y + formal_panel.size.y - 146)
		status_label.size = Vector2(formal_panel.size.x - 128, 38)
	if is_instance_valid(retry_button):
		retry_button.position = Vector2(formal_panel.position.x + formal_panel.size.x - 180, formal_panel.position.y + formal_panel.size.y - 146)
		retry_button.size = Vector2(116, 38)
	if is_instance_valid(preview_reason):
		preview_reason.position = Vector2(preview_button.position.x, preview_button.position.y + 60)
		preview_reason.size = Vector2(preview_button.size.x, 42)
	if is_instance_valid(sfx_manager_button):
		sfx_manager_button.visible = developer_tools_enabled
		sfx_manager_button.position = Vector2(formal_panel.position.x + 64, formal_panel.position.y + formal_panel.size.y - 190)
		sfx_manager_button.size = Vector2(230, 48)

func open(service: Node, audio: Node = null, texts: Callable = Callable()) -> void:
	# 每次打开都按当前服务值重建显示控件。
	settings_service = service
	if not service.persistence_changed.is_connected(_refresh_status): service.persistence_changed.connect(_refresh_status)
	candidate_display = service.runtime_display.duplicate(true) if not service.runtime_display.is_empty() else service.confirmed_display()
	audio_service = audio
	text_of = texts
	_rebuild_controls()
	show()
	_focus_tab_control()

func close_page() -> void:
	# 隐藏设置页，设置值已在操作时即时保存；离开设置时停止试听。
	if is_instance_valid(audio_service): audio_service.stop_preview()
	_close_scene_sample()
	reset_confirmation.close_page()
	if is_instance_valid(display_confirm): display_confirm.close_page()
	display_confirmation_visible = false
	if is_instance_valid(settings_service) and settings_service.display_preview_active: settings_service.cancel_display_preview()
	candidate_display.clear()
	adjusting = false
	hide()

func _text(key: String, fallback: String) -> String:
	# 固定文字统一来自功能文字表；没有提供查询时使用后备文字。
	if settings_texts.has(key): return str(settings_texts[key])
	if text_of.is_valid():
		var value: String = text_of.call(key)
		if value != key: return value
	return fallback

func _rebuild_controls() -> void:
	# 先移除旧控件，再根据服务中的当前值创建滑条和开关。
	var restore_reset_focus := rebuild_queued
	_close_scene_sample()
	rebuild_queued = false
	sliders.clear()
	volume_numbers.clear()
	for node in formal_dynamic:
		if not is_instance_valid(node): continue
		formal_nodes.erase(node)
		node.get_parent().remove_child(node)
		node.queue_free()
	formal_dynamic.clear()
	sample_worlds.clear()
	scene_preview_overlay = null
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
		slider.step = 1 # 鼠标精确到整数；键盘按独立配置步长调整。
		slider.value = settings_service.get_value(key, 0)
		slider.value_changed.connect(_set_value.bind(key))
		slider.drag_started.connect(_begin_adjustment.bind(key))
		slider.drag_ended.connect(_end_drag)
		slider.gui_input.connect(_slider_input.bind(key))
		slider.focus_exited.connect(_commit_adjustment)
		row.add_child(slider)
		sliders[key] = slider
		var number := Label.new()
		number.custom_minimum_size.x = 54
		row.add_child(number)
		volume_numbers[key] = number
		row.set_meta("settings_tab", "sound")
		controls_box.add_child(row)
	_add_brightness()
	for key in ["mute", "reduce_motion"]:
		var check := CheckButton.new()
		check.text = _text("UI_SETTINGS_MUTE", "静音") if key == "mute" else _text("UI_SETTINGS_REDUCE_MOTION", "减弱动态")
		check.button_pressed = settings_service.get_value(key, false)
		check.toggled.connect(_set_value.bind(key))
		check.set_meta("settings_tab", "sound" if key == "mute" else "presentation")
		controls_box.add_child(check)
	_build_display_controls()
	_build_text_speed()
	_build_controls_help()
	# 试听复用反馈事件；条件不满足时只禁用试听并说明原因，其他设置保持可用。
	preview_button = Button.new()
	preview_button.text = _text("UI_SETTINGS_PREVIEW", "试听效果音")
	preview_button.set_meta("ui_sound", "none") # 试听不叠加普通点击音。
	preview_button.pressed.connect(_preview)
	preview_button.set_meta("settings_tab", "sound")
	controls_box.add_child(preview_button)
	preview_reason = Label.new()
	preview_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_reason.set_meta("settings_tab", "sound")
	controls_box.add_child(preview_reason)
	_refresh_preview()
	sfx_manager_button = Button.new()
	sfx_manager_button.text = _text("UI_SETTINGS_SFX_MANAGER", "音效库管理")
	sfx_manager_button.pressed.connect(sfx_manager_requested.emit)
	sfx_manager_button.visible = developer_tools_enabled
	controls_box.add_child(sfx_manager_button)
	reset_button = Button.new()
	reset_button.text = _text("UI_SETTINGS_RESET", "恢复默认")
	reset_button.pressed.connect(_restore_defaults)
	controls_box.add_child(reset_button)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	controls_box.add_child(status_label)
	retry_button = Button.new()
	retry_button.text = "重试"
	retry_button.pressed.connect(settings_service.save)
	controls_box.add_child(retry_button)
	_apply_tab()
	_formalize_controls()
	_refresh_status()
	if restore_reset_focus and is_visible_in_tree(): reset_button.grab_focus()

func _set_value(value, key: String) -> void:
	# 控件变化立即交给设置服务校验、应用并保存。
	if is_instance_valid(settings_service): settings_service.set_value(key, value if key in ["mute", "reduce_motion"] else int(value), not adjusting)
	_refresh_preview()
	_refresh_status()

func _begin_adjustment(key: String) -> void:
	adjusting = true
	adjustment_key = key

func _end_drag(_changed: bool) -> void:
	_commit_adjustment()

func _commit_adjustment() -> void:
	if not adjusting: return
	adjusting = false
	adjustment_key = ""
	if settings_service.unsaved and not settings_service.busy: settings_service.save()

func _slider_input(event: InputEvent, key: String) -> void:
	if not event is InputEventKey or event.keycode not in [KEY_LEFT, KEY_RIGHT]: return
	if event.pressed and not settings_service.busy:
		_begin_adjustment(key)
		var direction := -1 if event.keycode == KEY_LEFT else 1
		sliders[key].value = clampi(int(sliders[key].value) + direction * settings_service.volume_step, 0, 100)
	elif not event.pressed:
		_commit_adjustment()
	get_viewport().set_input_as_handled()

func _refresh_status() -> void:
	if not is_instance_valid(settings_service) or not is_instance_valid(status_label): return
	if is_instance_valid(brightness_number): brightness_number.text = "%d%%" % int(settings_service.get_value("brightness", 100))
	for world in sample_worlds:
		if is_instance_valid(world):
			var brightness := float(settings_service.get_value("brightness", 100)) / 100.0
			world.modulate = Color(brightness, brightness, brightness, 1)
	var locked: bool = settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active
	for button in controls_box.find_children("*", "BaseButton", true, false): button.disabled = locked
	for node in formal_dynamic:
		if node is BaseButton: node.disabled = locked
	if is_instance_valid(brightness_slider): brightness_slider.editable = not locked
	for key in sliders:
		sliders[key].editable = not locked
		if volume_numbers.has(key): volume_numbers[key].text = "%d%%" % int(settings_service.get_value(key))
	close_button.disabled = locked
	for tab in tab_buttons.values(): tab.disabled = locked
	if is_instance_valid(apply_display_button): apply_display_button.disabled = locked or (candidate_display == settings_service.runtime_display and settings_service.display_adaptation_notice.is_empty())
	if is_instance_valid(mode_option): mode_option.disabled = locked
	if is_instance_valid(size_option): size_option.disabled = locked or int(candidate_display.get("display_mode", 1)) == 2
	if is_instance_valid(aspect_option): aspect_option.disabled = locked
	status_label.text = "写入中" if settings_service.busy else (("未保存：" + settings_service.last_error) if not settings_service.last_error.is_empty() else ("未保存" if settings_service.unsaved else ""))
	if not settings_service.display_adaptation_notice.is_empty() and not locked:
		status_label.text = settings_service.display_adaptation_notice
	status_label.tooltip_text = status_label.text
	retry_button.visible = settings_service.unsaved and not settings_service.last_error.is_empty()
	_refresh_preview()

func _refresh_preview() -> void:
	# 按音频服务给出的资格刷新试听按钮；没有音频服务时按素材未就绪处理。
	if not is_instance_valid(preview_button): return
	var state: Dictionary = audio_service.preview_state() if is_instance_valid(audio_service) else {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_UNREADY"}
	preview_button.disabled = not state["enabled"] or settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active
	preview_reason.text = "" if state["enabled"] else _text(String(state["reason"]), "试听素材未就绪")
	preview_reason.visible = not state["enabled"] and current_tab == "sound"

func _preview() -> void:
	if is_instance_valid(audio_service): audio_service.preview_effect()

func _restore_defaults() -> void:
	if settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active: return
	_commit_adjustment()
	var values: Dictionary = settings_service.defaults
	reset_confirmation.open("恢复全部默认", "显示：窗口 %d×%d、自动比例、亮度%d%%\n声音：%d%%／%d%%／%d%%／%d%%，静音%s\n表现：文字速度标准、减弱动态%s" % [values.window_width, values.window_height, values.brightness, values.master_volume, values.bgm_volume, values.ambient_volume, values.effect_volume, "开启" if values.mute else "关闭", "开启" if values.reduce_motion else "关闭"], "", "恢复默认", false, true)
	_refresh_status()

func _cancel_reset() -> void:
	reset_confirmation.close_page()
	_refresh_status()
	reset_button.grab_focus()

func _confirm_reset() -> void:
	if not reset_confirmation.visible or settings_service.busy: return
	reset_confirmation.close_page()
	var default_display: Dictionary = {}
	for key in settings_service.DISPLAY_KEYS: default_display[key] = settings_service.defaults[key]
	if default_display != settings_service.runtime_display:
		settings_service.display_candidate = candidate_display.duplicate(true)
		if settings_service.begin_display_preview(default_display, true): _show_display_confirmation()
		return
	settings_service.restore_defaults()
	candidate_display = settings_service.confirmed_display()
	# 信号处理结束后才更换控件，避免释放正在发射 pressed 的对象。
	if not rebuild_queued:
		rebuild_queued = true
		call_deferred("_rebuild_controls")

func _request_close() -> void:
	if settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active: return
	if adjusting:
		_commit_adjustment()
		return
	candidate_display.clear()
	closed.emit()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey or not event.pressed or event.echo or event.keycode != KEY_ESCAPE: return
	if is_instance_valid(scene_preview_overlay):
		_close_scene_sample()
		get_viewport().set_input_as_handled()
		return
	if _close_option_popup():
		get_viewport().set_input_as_handled()
		return
	if settings_service.display_preview_active: _revert_display()
	elif reset_confirmation.visible: _cancel_reset()
	else: _request_close()
	get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_visible_in_tree(): _commit_adjustment()

func _switch_tab(value: String) -> void:
	if settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active: return
	_commit_adjustment()
	current_tab = value
	_apply_tab()
	_refresh_status()
	_focus_tab_control()

func _apply_tab() -> void:
	for child in controls_box.get_children():
		if child.has_meta("settings_tab"): child.visible = child.get_meta("settings_tab") == current_tab
	for key in tab_buttons: tab_buttons[key].button_pressed = key == current_tab
	for node in formal_dynamic:
		if node.has_meta("settings_tab"): node.visible = str(node.get_meta("settings_tab")) == current_tab
	_layout_panel()

func _option_row(label_text: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.set_meta("settings_tab", "display")
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 150
	row.add_child(label)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(option)
	controls_box.add_child(row)
	return option

func _formal_node(node: Control, id: String, tab_name := "") -> void:
	if node.get_parent() != formal_canvas: node.reparent(formal_canvas, false)
	formal_dynamic.append(node)
	if not id.is_empty(): formal_nodes[node] = id
	if not tab_name.is_empty(): node.set_meta("settings_tab", tab_name)
	if node is BaseButton: formal_layout.button_style(node)
	if node is Label:
		node.add_theme_font_size_override("font_size", 24)
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _formalize_controls() -> void:
	# 从原业务创建方法中取出真实控件；动态行的逻辑与信号保持原样，几何只消费正式JSON。
	var volume_keys := ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]
	for index in range(volume_keys.size()):
		var key: String = volume_keys[index]
		var slider: HSlider = sliders[key]
		var label: Label = slider.get_parent().get_child(0)
		label.name = "VolumeLabel_" + key
		_formal_node(label, "settings.text_ui_settings_%s_1" % ["master", "bgm", "ambient", "effect"][index], "sound")
		_formal_node(slider, "settings." if index == 0 else "settings._" + str(index + 1), "sound")
		_formal_node(volume_numbers[key], "settings.text_region_" + str(index + 1), "sound")
		# 轨道绘制不变，实际可拖动控件保留整行56px的命中高度。
		slider.custom_minimum_size = Vector2.ZERO
	for pair in [[mode_option, "settings.mode", "settings.text_ui_settings_display_mode_1"], [size_option, "settings.size", "settings.text_ui_settings_window_size_1"], [aspect_option, "settings.aspect", "settings.text_ui_settings_aspect_ratio_1"], [brightness_slider, "settings.brightness", "settings.text_ui_settings_brightness_1"]]:
		var target: Control = pair[0]
		var label: Label = target.get_parent().get_child(0)
		_formal_node(label, pair[2], "display")
		label.set_meta("label_for", target)
		_formal_node(target, pair[1], "display")
	_formal_node(brightness_number, "settings.text_region_1", "display")
	for child in controls_box.get_children():
		if child is CheckButton:
			var tab_name: String = str(child.get_meta("settings_tab"))
			var label := Label.new()
			label.text = child.text
			formal_canvas.add_child(label)
			_formal_node(label, "settings.text_ui_settings_mute_1" if tab_name == "sound" else "settings.text_ui_settings_reduce_motion_1", tab_name)
			_formal_node(child, "settings.mute" if tab_name == "sound" else "settings.reduce_motion", tab_name)
			label.set_meta("label_for", child)
			child.text = "开启" if child.button_pressed else "关闭"
			child.toggled.connect(func(value): child.text = "开启" if value else "关闭")
		elif child is HBoxContainer and child.get_meta("settings_tab", "") == "presentation":
			var label: Label = child.get_child(0)
			var option: OptionButton = child.get_child(1)
			_formal_node(label, "settings.text_ui_settings_text_speed_1", "presentation")
			_formal_node(option, "settings.text_speed", "presentation")
			label.set_meta("label_for", option)
		elif child is Label and child.get_meta("settings_tab", "") == "controls":
			# 使用正式九行帮助，不让大段字符串通过左对齐挤进窄列。
			child.hide()
	_formal_node(preview_button, "settings.audition", "sound")
	_formal_node(preview_reason, "", "sound")
	_formal_node(reset_button, "settings.reset")
	_formal_node(status_label, "")
	_formal_node(retry_button, "")
	_formal_node(apply_display_button, "settings.apply", "display")
	_formal_node(sfx_manager_button, "")
	_add_scene_sample("display")
	_add_scene_sample("presentation")
	var preview_open := Button.new()
	preview_open.text = _text("UI_SETTINGS_PREVIEW_OPEN", "画面预览")
	preview_open.pressed.connect(_open_scene_sample)
	formal_canvas.add_child(preview_open)
	_formal_node(preview_open, "settings.preview", "display")
	_add_formal_help()
	for pair in [["UI_SETTINGS_MOTION_HINT", "减弱动态会减少震屏、闪光和移动效果。", "settings.text_ui_settings_motion_hint_1", "presentation"], ["UI_SETTINGS_MOTION_RESULT_HINT", "结果与剧情照常完成，不改变核查结果。", "settings.text_ui_settings_motion_result_hint_1", "presentation"], ["UI_SETTINGS_MOTION_RESTORE_HINT", "该偏好独立保存，不随调查存档回退。", "settings.text_ui_settings_motion_restore_hint_1", "presentation"], ["UI_SETTINGS_UI_BRIGHTNESS_HINT", "亮度仅影响场景、人物和物件，纸面与正文不变。", "settings.text_region_3", "display"]]:
		var hint := Label.new()
		hint.text = _text(pair[0], pair[1])
		formal_canvas.add_child(hint)
		_formal_node(hint, pair[2], pair[3])
	_layout_panel()

func _add_formal_help() -> void:
	var path := str(formal_layout.config.definition.root).path_join("design/basic/input_bindings.json")
	var source = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not source is Dictionary: return
	var binding_index := {}
	for row in source.get("bindings", []): binding_index[str(row.id)] = row
	var row_index := 0
	for group in source.get("help_groups", []):
		row_index += 1
		var keys: Array[String] = []
		for id in group.get("binding_ids", []):
			if binding_index.has(id): keys.append(str(binding_index[id].key))
		var label := Label.new()
		var label_id := str(group.get("label_text_id", ""))
		var help_id := str(group.get("help_text_id", ""))
		label.text = " / ".join(keys) + "　" + _text(label_id, str(source.get("texts", {}).get(label_id, ""))) + "　" + _text(help_id, str(source.get("texts", {}).get(help_id, "")))
		label.add_theme_font_size_override("font_size", 20)
		formal_canvas.add_child(label)
		_formal_node(label, "settings.text_region_" + str(row_index), "controls")
		label.add_theme_font_size_override("font_size", 20)

func _sample_texture(parent: Control, path: String, target: Rect2) -> TextureRect:
	var resolved: String = formal_layout.config.resource_path(path)
	if not ResourceLoader.exists(resolved): return null
	var picture := TextureRect.new()
	picture.texture = load(resolved)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	picture.position = target.position
	picture.size = target.size
	parent.add_child(picture)
	return picture

func _scene_sample(parent: Control, dimensions: Vector2) -> Control:
	# 正式夜景和v3艾琳仅作亮度取样，不执行文本、阅读或剧情回执。
	var sample := Control.new()
	sample.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sample.size = dimensions
	sample.set_meta("sample_size", dimensions)
	parent.add_child(sample)
	var world := Control.new()
	world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sample.add_child(world)
	world.size = dimensions
	_sample_texture(world, "res://assets/aurora/scenes/backgrounds/SC02_大厅_厨房无人.png", Rect2(Vector2.ZERO, dimensions))
	_sample_texture(world, "res://assets/aurora/characters/1000001/erin_neutral.png", Rect2(Vector2(dimensions.x * 0.05, dimensions.y * 0.12), Vector2(dimensions.x * 0.5, dimensions.y * 0.96)))
	sample_worlds.append(world)
	var reading := PanelContainer.new()
	sample.add_child(reading)
	reading.position = Vector2(12, dimensions.y * 0.75)
	reading.size = Vector2(dimensions.x - 24, dimensions.y * 0.22)
	reading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = "艾琳　移交时间：明早撤站装车前。"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 20)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reading.add_child(label)
	return world

func _add_scene_sample(tab_name: String) -> void:
	var host := Control.new()
	host.name = "BrightnessSample_" + tab_name
	host.clip_contents = true
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	formal_canvas.add_child(host)
	_formal_node(host, "settings.scene_frame.2", tab_name)
	_layout_panel()
	# 即使首次在4:3收起预览，也先建立相同采样；之后换宽比例能够恢复完整图层。
	_scene_sample(host, Vector2(626, 352.125) if tab_name == "display" else Vector2(480, 270))
	_layout_panel()
	# 窄比例正式布局收起预览，以独立入口替代。
	if host.size == Vector2.ZERO: host.hide()

func _open_scene_sample() -> void:
	if settings_service.busy or reset_confirmation.visible or settings_service.display_preview_active: return
	if is_instance_valid(scene_preview_overlay): return
	scene_preview_overlay = Control.new()
	scene_preview_overlay.name = "SettingsScenePreview"
	scene_preview_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	scene_preview_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	formal_canvas.add_child(scene_preview_overlay)
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.07, 0.06, 0.95)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	scene_preview_overlay.add_child(shade)
	var dimensions := Vector2(minf(1000, formal_canvas.size.x - 120), 560)
	var sample := Control.new()
	sample.position = (formal_canvas.size - dimensions) / 2
	sample.size = dimensions
	scene_preview_overlay.add_child(sample)
	_scene_sample(sample, dimensions)
	var close := Button.new()
	close.text = "返回设置"
	formal_layout.button_style(close)
	close.position = Vector2(formal_canvas.size.x / 2 - 120, sample.position.y + dimensions.y + 18)
	close.size = Vector2(240, 56)
	scene_preview_overlay.add_child(close)
	close.pressed.connect(_close_scene_sample)
	_refresh_status()
	close.grab_focus()

func _close_scene_sample() -> void:
	if not is_instance_valid(scene_preview_overlay): return
	formal_canvas.remove_child(scene_preview_overlay)
	scene_preview_overlay.queue_free()
	scene_preview_overlay = null

func _build_display_controls() -> void:
	mode_option = _option_row("显示模式")
	mode_option.add_item("窗口", 1); mode_option.add_item("全屏", 2)
	mode_option.select(mode_option.get_item_index(int(candidate_display.get("display_mode", 1))))
	mode_option.item_selected.connect(func(index): candidate_display.display_mode = mode_option.get_item_id(index); _refresh_status())
	size_option = _option_row("窗口尺寸")
	window_presets = settings_service.available_window_sizes()
	for preset in window_presets: size_option.add_item("%d × %d" % [preset.x, preset.y])
	var selected := window_presets.find(Vector2i(int(candidate_display.get("window_width", 1600)), int(candidate_display.get("window_height", 900))))
	if selected >= 0: size_option.select(selected)
	size_option.item_selected.connect(func(index): candidate_display.window_width = window_presets[index].x; candidate_display.window_height = window_presets[index].y; _refresh_status())
	aspect_option = _option_row("画面比例")
	for text in ["自动", "16:9", "16:10", "4:3", "21:9"]: aspect_option.add_item(text)
	aspect_option.select(int(candidate_display.get("aspect_ratio", 0)))
	aspect_option.item_selected.connect(func(index): candidate_display.aspect_ratio = index; _refresh_status())
	apply_display_button = Button.new()
	apply_display_button.text = "应用显示"
	apply_display_button.set_meta("settings_tab", "display")
	apply_display_button.pressed.connect(_apply_display)
	controls_box.add_child(apply_display_button)

func _add_brightness() -> void:
	var row := HBoxContainer.new()
	row.set_meta("settings_tab", "display")
	var label := Label.new(); label.text = "画面亮度"; label.custom_minimum_size.x = 150; row.add_child(label)
	var slider := HSlider.new(); slider.min_value = 50; slider.max_value = 150; slider.step = 1
	slider.value = settings_service.get_value("brightness", 100)
	slider.custom_minimum_size = Vector2(240, 30); slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(_set_value.bind("brightness")); slider.drag_started.connect(_begin_adjustment.bind("brightness")); slider.drag_ended.connect(_end_drag); slider.focus_exited.connect(_commit_adjustment)
	slider.gui_input.connect(_brightness_input)
	row.add_child(slider); brightness_slider = slider
	var number := Label.new(); number.custom_minimum_size.x = 54; row.add_child(number); brightness_number = number
	controls_box.add_child(row)

func _brightness_input(event: InputEvent) -> void:
	if not event is InputEventKey or event.keycode not in [KEY_LEFT, KEY_RIGHT]: return
	if event.pressed and not settings_service.busy and not settings_service.display_preview_active and not reset_confirmation.visible:
		_begin_adjustment("brightness")
		brightness_slider.value = clampi(int(brightness_slider.value) + (-5 if event.keycode == KEY_LEFT else 5), 50, 150)
	elif not event.pressed: _commit_adjustment()
	get_viewport().set_input_as_handled()

func _build_text_speed() -> void:
	var row := HBoxContainer.new(); row.set_meta("settings_tab", "presentation")
	var label := Label.new(); label.text = "文字速度"; label.custom_minimum_size.x = 150; row.add_child(label)
	var option := OptionButton.new()
	for text in ["慢速", "标准", "快速"]: option.add_item(text)
	option.select(int(settings_service.get_value("text_speed", 2)) - 1)
	option.item_selected.connect(func(index): settings_service.set_value("text_speed", index + 1))
	row.add_child(option); controls_box.add_child(row)

func _build_controls_help() -> void:
	var help := Label.new()
	help.text = "M 地图　I 办案手册　L 对白记录\nJ 目标回顾　H 隐藏或恢复正文\n按住 Ctrl 加速已读　Esc 返回或暂停\nTab / Shift+Tab 移动焦点　Enter / Space 确认"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.set_meta("settings_tab", "controls"); controls_box.add_child(help)

func _apply_display() -> void:
	_commit_adjustment()
	if settings_service.begin_display_preview(candidate_display): _show_display_confirmation()

func _show_display_confirmation() -> void:
	display_confirmation_visible = true
	last_preview_second = -1
	display_confirm.open("保留当前显示设置", _display_confirmation_text(15), "", "保留显示", false, true)
	display_confirm.cancel_button.text = "恢复原显示"
	_refresh_status()

func _display_confirmation_text(seconds: int) -> String:
	var before: Dictionary = settings_service.display_restore_values
	var after: Dictionary = settings_service.display_candidate
	return "原显示：%s %d×%d，比例%d\n当前：%s %d×%d，比例%d\n剩余%d秒，倒计时结束后恢复原显示。" % ["窗口" if before.display_mode == 1 else "全屏", before.window_width, before.window_height, before.aspect_ratio, "窗口" if after.display_mode == 1 else "全屏", after.window_width, after.window_height, after.aspect_ratio, seconds]

func _keep_display() -> void:
	if not settings_service.display_preview_active: return
	settings_service.keep_display_preview()
	display_confirm.close_page(); display_confirmation_visible = false
	candidate_display = settings_service.runtime_display.duplicate(true)
	_queue_rebuild()

func _revert_display() -> void:
	settings_service.cancel_display_preview()
	display_confirm.close_page(); display_confirmation_visible = false
	candidate_display = settings_service.display_candidate.duplicate(true) if not settings_service.display_candidate.is_empty() else settings_service.runtime_display.duplicate(true)
	_queue_rebuild()

func _queue_rebuild() -> void:
	if not rebuild_queued:
		rebuild_queued = true
		call_deferred("_rebuild_controls")

func _process(_delta: float) -> void:
	if not is_visible_in_tree() or not is_instance_valid(settings_service): return
	if display_confirmation_visible and not settings_service.display_preview_active:
		_revert_display()
	elif settings_service.display_preview_active:
		var seconds := ceili(settings_service.display_preview_seconds)
		if seconds != last_preview_second:
			last_preview_second = seconds
			(display_confirm.box.get_child(1) as Label).text = _display_confirmation_text(seconds)

func _focus_tab_control() -> void:
	for control in formal_dynamic:
		if control is BaseButton or control is Slider:
			if control.is_visible_in_tree() and control.focus_mode != Control.FOCUS_NONE:
				control.grab_focus()
				return
	for control in controls_box.find_children("*", "Control", true, false):
		if control is BaseButton or control is Slider:
			if control.is_visible_in_tree() and control.focus_mode != Control.FOCUS_NONE:
				control.grab_focus()
				return

func _close_option_popup() -> bool:
	for option in formal_dynamic:
		if option is OptionButton and option.get_popup().visible:
			option.get_popup().hide()
			option.grab_focus()
			return true
	for option in controls_box.find_children("*", "OptionButton", true, false):
		if option.get_popup().visible:
			option.get_popup().hide()
			option.grab_focus()
			return true
	return false
