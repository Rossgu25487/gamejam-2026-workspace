extends Control
## 音效库管理界面：浏览、搜索、按来源包与分类筛选全部备用音效，支持单条试听、多通道测试、
## 实时替换为当前游戏的按钮点击／确认／反馈音，以及一键复制供其他模块调用的 ID 与代码。
## 既可由 Main 作为子页面打开，也可在编辑器中直接打开 sfx_manager_page.tscn 按 F6 独立运行。

signal closed # 用户请求关闭音效管理界面并返回来源页面。

const AudioScript = preload("res://systems/audio/audio_service.gd")
const DEFAULT_UI_BINDINGS := {
	"SFX_UI_CLICK": "res://tests/fixtures/audio/ui_demo/ui_click.wav",
	"SFX_UI_CONFIRM": "res://tests/fixtures/audio/ui_demo/ui_confirm.wav",
	"SFX_UI_FEEDBACK": "res://tests/fixtures/audio/ui_demo/ui_feedback.wav",
}
const QUICK_FILTERS := [
	["全部", "", ""],
	["专项候选", "available_audios", ""],
	["书卷翻页", "", "book"],
	["卡牌操作", "", "card"],
	["门锁木门", "", "door"],
	["金属钱币", "", "coin_metal"],
	["脚步声", "", "footstep"],
	["钟铃轻击", "", "impact_bell"],
]

var audio_service: Node
var settings_service: Node
var panel: PanelContainer
var summary_label: Label
var count_label: Label
var pack_option: OptionButton
var category_option: OptionButton
var search_input: LineEdit
var clear_filter_button: Button
var auto_preview_check: CheckButton
var stop_button: Button
var close_button: Button
var list_scroll: ScrollContainer
var list_box: VBoxContainer
var selected_title: Label
var detail_label: Label
var code_label: Label
var binding_label: Label
var status_label: Label
var preview_selected_button: Button
var play_result_button: Button
var play_ui_button: Button
var bind_click_button: Button
var bind_confirm_button: Button
var bind_feedback_button: Button
var reset_binding_button: Button
var copy_id_button: Button
var copy_alias_button: Button
var copy_code_button: Button
var master_slider: HSlider
var master_value_label: Label
var effect_slider: HSlider
var effect_value_label: Label
var mute_check: CheckButton

var pack_ids: Array[String] = [""]
var category_ids: Array[String] = [""]
var current_pack := ""
var current_category := ""
var current_query := ""
var selected_id := ""
var visible_entries: Array = []
var button_by_id := {}
var last_action := "点击左侧任意音效即可试听并查看调用方式。"
var _syncing_controls := false
var _standalone := false


func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "settings")


func _ready() -> void:
	_build_page()
	if get_parent() == get_tree().root:
		# 在编辑器中按 F6 独立运行本场景时，自动创建并初始化声音服务。
		_standalone = true
		DisplayServer.window_set_title("音效库管理")
		var standalone_audio := AudioScript.new()
		add_child(standalone_audio)
		standalone_audio.setup()
		for key in DEFAULT_UI_BINDINGS:
			standalone_audio.bind_resource(key, String(DEFAULT_UI_BINDINGS[key]))
		standalone_audio.apply_settings({"master_volume": 100, "bgm_volume": 70, "ambient_volume": 60, "effect_volume": 80, "mute": false})
		standalone_audio.attach_ui_hook(get_tree())
		open(standalone_audio)
	else:
		hide()


func open(audio: Node, settings_srv: Node = null) -> void:
	audio_service = audio
	settings_service = settings_srv
	_populate_filter_options()
	_sync_volume_controls()
	_refresh_list()
	_refresh_binding_status()
	show()
	if is_instance_valid(search_input):
		search_input.grab_focus()


func close_page() -> void:
	if is_instance_valid(audio_service):
		audio_service.stop_preview()
	hide()


func _build_page() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.06, 0.08, 0.1, 0.94)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side_name in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side_name, 20)
	add_child(margin)

	panel = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(panel)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 10)
	panel.add_child(root_box)

	_build_header(root_box)
	_build_filter_bar(root_box)
	_build_quick_bar(root_box)
	_build_body(root_box)


func _build_header(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var title := Label.new()
	title.text = "音效库管理"
	title.add_theme_font_size_override("font_size", 24)
	row.add_child(title)

	summary_label = Label.new()
	summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_label.add_theme_color_override("font_color", Color(0.75, 0.84, 0.8))
	row.add_child(summary_label)

	stop_button = Button.new()
	stop_button.text = "停止试听"
	stop_button.set_meta("ui_sound", "none")
	stop_button.pressed.connect(_on_stop_pressed)
	row.add_child(stop_button)

	close_button = Button.new()
	close_button.text = "退出窗口" if get_parent() == get_tree().root else "关闭音效管理"
	close_button.pressed.connect(_on_close_pressed)
	row.add_child(close_button)


func _build_filter_bar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var pack_label := Label.new()
	pack_label.text = "来源包："
	row.add_child(pack_label)

	pack_option = OptionButton.new()
	pack_option.custom_minimum_size = Vector2(210, 34)
	pack_option.item_selected.connect(_on_pack_selected)
	row.add_child(pack_option)

	var cat_label := Label.new()
	cat_label.text = "分类："
	row.add_child(cat_label)

	category_option = OptionButton.new()
	category_option.custom_minimum_size = Vector2(180, 34)
	category_option.item_selected.connect(_on_category_selected)
	row.add_child(category_option)

	search_input = LineEdit.new()
	search_input.placeholder_text = "搜索中文名、ID、文件名（例：对白、书页、卡牌、door、bell、footstep）"
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.custom_minimum_size = Vector2(220, 34)
	search_input.text_changed.connect(_on_search_changed)
	row.add_child(search_input)

	clear_filter_button = Button.new()
	clear_filter_button.text = "重置筛选"
	clear_filter_button.pressed.connect(reset_filters)
	row.add_child(clear_filter_button)

	auto_preview_check = CheckButton.new()
	auto_preview_check.text = "点击即试听"
	auto_preview_check.button_pressed = true
	auto_preview_check.set_meta("ui_sound", "none")
	row.add_child(auto_preview_check)

	count_label = Label.new()
	count_label.custom_minimum_size = Vector2(120, 0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(count_label)


func _build_quick_bar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var hint := Label.new()
	hint.text = "快捷分类："
	hint.add_theme_color_override("font_color", Color(0.68, 0.76, 0.74))
	row.add_child(hint)

	for preset in QUICK_FILTERS:
		var btn := Button.new()
		btn.text = String(preset[0])
		btn.pressed.connect(_apply_quick_filter.bind(String(preset[1]), String(preset[2])))
		row.add_child(btn)


func _build_body(parent: VBoxContainer) -> void:
	var split := HBoxContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 14)
	parent.add_child(split)

	# 左栏：可滚动音效列表
	var left_box := VBoxContainer.new()
	left_box.custom_minimum_size = Vector2(520, 0)
	left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_box.size_flags_stretch_ratio = 1.05
	split.add_child(left_box)

	list_scroll = ScrollContainer.new()
	list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_box.add_child(list_scroll)

	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 4)
	list_scroll.add_child(list_box)

	# 右栏：选中音效详情、多通道测试、实时 UI 绑定与调用代码
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_stretch_ratio = 1.0
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(right_scroll)

	var inspector := VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.add_theme_constant_override("separation", 10)
	right_scroll.add_child(inspector)

	selected_title = Label.new()
	selected_title.text = "请选择一条音效"
	selected_title.add_theme_font_size_override("font_size", 20)
	selected_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector.add_child(selected_title)

	detail_label = Label.new()
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.add_child(detail_label)

	var play_row := HBoxContainer.new()
	play_row.add_theme_constant_override("separation", 8)
	inspector.add_child(play_row)

	preview_selected_button = Button.new()
	preview_selected_button.text = "试听当前音效"
	preview_selected_button.set_meta("ui_sound", "none")
	preview_selected_button.pressed.connect(func(): play_selected("preview"))
	play_row.add_child(preview_selected_button)

	play_result_button = Button.new()
	play_result_button.text = "按结果音播放 (Result)"
	play_result_button.set_meta("ui_sound", "none")
	play_result_button.pressed.connect(func(): play_selected("result"))
	play_row.add_child(play_result_button)

	play_ui_button = Button.new()
	play_ui_button.text = "按界面音播放 (UI)"
	play_ui_button.set_meta("ui_sound", "none")
	play_ui_button.pressed.connect(func(): play_selected("ui"))
	play_row.add_child(play_ui_button)

	var bind_header := Label.new()
	bind_header.text = "实时绑定为游戏操作音（立即体验按钮点击／确认／反馈效果）："
	bind_header.add_theme_color_override("font_color", Color(0.87, 0.78, 0.61))
	inspector.add_child(bind_header)

	var bind_row := HBoxContainer.new()
	bind_row.add_theme_constant_override("separation", 6)
	inspector.add_child(bind_row)

	bind_click_button = Button.new()
	bind_click_button.text = "设为点击音"
	bind_click_button.pressed.connect(func(): bind_selected_to_ui("SFX_UI_CLICK"))
	bind_row.add_child(bind_click_button)

	bind_confirm_button = Button.new()
	bind_confirm_button.text = "设为确认音"
	bind_confirm_button.set_meta("ui_sound", "confirm")
	bind_confirm_button.pressed.connect(func(): bind_selected_to_ui("SFX_UI_CONFIRM"))
	bind_row.add_child(bind_confirm_button)

	bind_feedback_button = Button.new()
	bind_feedback_button.text = "设为反馈/试听音"
	bind_feedback_button.set_meta("ui_sound", "none")
	bind_feedback_button.pressed.connect(func():
		bind_selected_to_ui("SFX_UI_FEEDBACK")
		if is_instance_valid(audio_service):
			audio_service.preview_effect())
	bind_row.add_child(bind_feedback_button)

	reset_binding_button = Button.new()
	reset_binding_button.text = "恢复默认操作音"
	reset_binding_button.pressed.connect(restore_default_ui_bindings)
	bind_row.add_child(reset_binding_button)

	binding_label = Label.new()
	binding_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	binding_label.add_theme_color_override("font_color", Color(0.68, 0.78, 0.75))
	inspector.add_child(binding_label)

	var code_header := Label.new()
	code_header.text = "其他模块调用方式（支持标准 ID、中文名或原文件名）："
	code_header.add_theme_color_override("font_color", Color(0.87, 0.78, 0.61))
	inspector.add_child(code_header)

	code_label = Label.new()
	code_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector.add_child(code_label)

	var copy_row := HBoxContainer.new()
	copy_row.add_theme_constant_override("separation", 8)
	inspector.add_child(copy_row)

	copy_id_button = Button.new()
	copy_id_button.text = "复制标准 ID"
	copy_id_button.pressed.connect(_copy_selected_id)
	copy_row.add_child(copy_id_button)

	copy_alias_button = Button.new()
	copy_alias_button.text = "复制文件名"
	copy_alias_button.pressed.connect(_copy_selected_stem)
	copy_row.add_child(copy_alias_button)

	copy_code_button = Button.new()
	copy_code_button.text = "复制调用代码"
	copy_code_button.pressed.connect(_copy_selected_code)
	copy_row.add_child(copy_code_button)

	var vol_header := Label.new()
	vol_header.text = "快速音量调节："
	vol_header.add_theme_color_override("font_color", Color(0.87, 0.78, 0.61))
	inspector.add_child(vol_header)

	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 8)
	inspector.add_child(vol_row)

	master_value_label = Label.new()
	master_value_label.custom_minimum_size = Vector2(96, 0)
	vol_row.add_child(master_value_label)

	master_slider = HSlider.new()
	master_slider.min_value = 0
	master_slider.max_value = 100
	master_slider.step = 5
	master_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	master_slider.value_changed.connect(_on_master_volume_changed)
	vol_row.add_child(master_slider)

	effect_value_label = Label.new()
	effect_value_label.custom_minimum_size = Vector2(96, 0)
	vol_row.add_child(effect_value_label)

	effect_slider = HSlider.new()
	effect_slider.min_value = 0
	effect_slider.max_value = 100
	effect_slider.step = 5
	effect_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	effect_slider.value_changed.connect(_on_effect_volume_changed)
	vol_row.add_child(effect_slider)

	mute_check = CheckButton.new()
	mute_check.text = "静音"
	mute_check.toggled.connect(_on_mute_toggled)
	vol_row.add_child(mute_check)

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.58, 0.85, 0.74))
	inspector.add_child(status_label)


func _populate_filter_options() -> void:
	pack_option.clear()
	category_option.clear()
	pack_ids = [""]
	category_ids = [""]
	if not is_instance_valid(audio_service) or audio_service.catalog == null:
		pack_option.add_item("全部来源包 (0)")
		category_option.add_item("全部分类 (0)")
		return
	var summary: Dictionary = audio_service.sfx_summary()
	var total := int(summary.get("total", 0))
	var ready := int(summary.get("ready", 0))
	var packs: Array = summary.get("packs", [])
	var categories: Array = summary.get("categories", [])
	summary_label.text = "共 %d 条备用音效 | 就绪 %d/%d | %d 个来源包 | %d 个分类" % [
		total, ready, total, packs.size(), categories.size()
	]
	pack_option.add_item("全部来源包 (%d)" % total)
	for pack in packs:
		pack_ids.append(String(pack.get("id", "")))
		pack_option.add_item("%s (%d)" % [String(pack.get("label", "")), int(pack.get("count", 0))])
	category_option.add_item("全部分类 (%d)" % total)
	for cat in categories:
		category_ids.append(String(cat.get("id", "")))
		category_option.add_item("%s (%d)" % [String(cat.get("label", "")), int(cat.get("count", 0))])
	_select_option_by_value(pack_option, pack_ids, current_pack)
	_select_option_by_value(category_option, category_ids, current_category)


func _select_option_by_value(option: OptionButton, ids: Array[String], target: String) -> void:
	var idx := ids.find(target)
	option.selected = idx if idx >= 0 else 0


func _sync_volume_controls() -> void:
	if not is_instance_valid(audio_service):
		return
	_syncing_controls = true
	var master_val := int(audio_service.settings.get("master_volume", 100))
	var effect_val := int(audio_service.settings.get("effect_volume", 80))
	var muted := bool(audio_service.settings.get("mute", false))
	master_slider.value = master_val
	effect_slider.value = effect_val
	mute_check.button_pressed = muted
	master_value_label.text = "总音量 %d" % master_val
	effect_value_label.text = "效果音 %d" % effect_val
	_syncing_controls = false


func _refresh_list() -> void:
	while list_box.get_child_count() > 0:
		var child := list_box.get_child(0)
		list_box.remove_child(child)
		child.queue_free()
	button_by_id.clear()
	visible_entries = audio_service.list_sfx(current_pack, current_category, current_query) if is_instance_valid(audio_service) else []
	var total := int(audio_service.catalog.sfx_entries.size()) if is_instance_valid(audio_service) and audio_service.catalog != null else 0
	count_label.text = "显示 %d / %d 条" % [visible_entries.size(), total]

	for entry in visible_entries:
		var sfx_id := String(entry.get("id", ""))
		var btn := Button.new()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.custom_minimum_size = Vector2(0, 38)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.set_meta("ui_sound", "none") # 避免普通点击音盖住试听音效
		btn.set_meta("sfx_id", sfx_id)
		btn.text = "[%s] %s  (%.2fs · %s)  —  %s" % [
			String(entry.get("category_label", "")),
			String(entry.get("name", "")),
			float(entry.get("duration_sec", 0.0)),
			String(entry.get("format", "")).to_upper(),
			sfx_id,
		]
		btn.pressed.connect(_on_entry_clicked.bind(sfx_id))
		list_box.add_child(btn)
		button_by_id[sfx_id] = btn

	if visible_entries.is_empty():
		var empty_label := Label.new()
		empty_label.text = "没有匹配的备用音效，请调整筛选条件或搜索关键词。"
		list_box.add_child(empty_label)
		selected_id = ""
		_refresh_inspector()
		return

	if selected_id.is_empty() or not button_by_id.has(selected_id):
		selected_id = String(visible_entries[0].get("id", ""))
	_refresh_inspector()


func _on_entry_clicked(sfx_id: String) -> void:
	select_sfx(sfx_id, auto_preview_check.button_pressed)


func select_sfx(sfx_id: String, preview_now := false) -> void:
	selected_id = sfx_id
	_refresh_inspector()
	if preview_now:
		play_selected("preview")


func _refresh_inspector() -> void:
	var has_selection := not selected_id.is_empty() and is_instance_valid(audio_service)
	for btn in [
		preview_selected_button, play_result_button, play_ui_button,
		bind_click_button, bind_confirm_button, bind_feedback_button,
		copy_id_button, copy_alias_button, copy_code_button,
	]:
		btn.disabled = not has_selection
	if not has_selection:
		selected_title.text = "未选择音效"
		detail_label.text = "请在左侧列表中选择一条备用音效。"
		code_label.text = ""
		status_label.text = "状态：" + last_action
		return

	var info: Dictionary = audio_service.sfx_info(selected_id)
	var name_text := String(info.get("name", selected_id))
	var stem_text := String(info.get("stem", ""))
	var state_text := "已就绪" if String(info.get("state", "")) == "ready" else ("缺失：" + String(info.get("state", "")))
	var aliases: Array = info.get("aliases", [])
	var alias_str := "、".join(aliases) if not aliases.is_empty() else "（使用标准 ID）"

	selected_title.text = "%s  [%s]" % [name_text, selected_id]
	detail_label.text = "\n".join([
		"标准调用 ID：%s" % selected_id,
		"原文件名／简写：%s  （别名：%s）" % [stem_text, alias_str],
		"来源包：%s    |    分类：%s" % [String(info.get("pack_label", "")), String(info.get("category_label", ""))],
		"推荐通道：%s    |    状态：%s" % [String(info.get("bus", "result")), state_text],
		"规格：%s · %.3f 秒 · %d Hz · %d 声道 · %d 字节" % [
			String(info.get("format", "")).to_upper(),
			float(info.get("duration_sec", 0.0)),
			int(info.get("sample_rate", 0)),
			int(info.get("channels", 0)),
			int(info.get("size_bytes", 0)),
		],
		"项目路径：%s" % String(info.get("path", "")),
		"授权说明：%s" % String(info.get("license", "")),
	])
	var short_ref := String(aliases[0]) if not aliases.is_empty() else selected_id
	code_label.text = "\n".join([
		"1) 直接调用 AudioService（按推荐通道播放）：",
		"   audio_service.play_sfx(\"%s\")" % selected_id,
		"   audio_service.play_sfx(\"%s\")" % short_ref,
		"2) 通过模块 media_requested 信号请求：",
		"   media_requested.emit({\"sfx\": \"%s\"})" % selected_id,
		"3) 在结果音／表现字典中引用：",
		"   audio_service.play_result(\"instance_1\", \"%s\")" % selected_id,
	])
	status_label.text = "状态：" + last_action


func play_selected(mode: String) -> Dictionary:
	if selected_id.is_empty() or not is_instance_valid(audio_service):
		return {"status": "empty"}
	audio_service.notify_valid_input()
	var result: Dictionary
	if mode == "preview":
		result = audio_service.preview_sfx(selected_id)
	elif mode == "ui":
		result = audio_service.play_sfx(selected_id, "ui")
	else:
		# 在音效管理界面内测试 result 通道时，若处于暂停菜单打开状态则临时借用 preview 或直接用 ui/result
		if audio_service.menu_open:
			result = audio_service.preview_sfx(selected_id)
			result["note"] = "暂停菜单打开中，已改走试听通道发声"
		else:
			result = audio_service.play_sfx(selected_id, "result")
	last_action = "播放 %s [%s] -> %s" % [selected_id, mode, str(result.get("status", ""))]
	status_label.text = "状态：" + last_action
	return result


func bind_selected_to_ui(ui_resource_key: String) -> bool:
	if selected_id.is_empty() or not is_instance_valid(audio_service):
		return false
	var ok: bool = audio_service.bind_resource(ui_resource_key, selected_id)
	last_action = "已将 %s 绑定到 %s" % [ui_resource_key, selected_id]
	_refresh_binding_status()
	status_label.text = "状态：" + last_action
	return ok


func restore_default_ui_bindings() -> void:
	if not is_instance_valid(audio_service):
		return
	for key in DEFAULT_UI_BINDINGS:
		audio_service.bind_resource(key, String(DEFAULT_UI_BINDINGS[key]))
	last_action = "已恢复默认试听操作音"
	_refresh_binding_status()
	status_label.text = "状态：" + last_action


func _refresh_binding_status() -> void:
	if not is_instance_valid(audio_service) or audio_service.catalog == null:
		binding_label.text = ""
		return
	var parts: Array[String] = []
	var labels := {
		"SFX_UI_CLICK": "点击音",
		"SFX_UI_CONFIRM": "确认音",
		"SFX_UI_FEEDBACK": "反馈/试听音",
	}
	for key in ["SFX_UI_CLICK", "SFX_UI_CONFIRM", "SFX_UI_FEEDBACK"]:
		var rec: Dictionary = audio_service.catalog.resources.get(key, {})
		var path := String(rec.get("resource_path", ""))
		var entry: Dictionary = audio_service.catalog.sfx_entry(path)
		var display := String(entry.get("name", path.get_file())) if not path.is_empty() else "（未绑定）"
		parts.append("%s=%s" % [labels[key], display])
	binding_label.text = "当前操作音绑定：" + "  |  ".join(parts)


func reset_filters() -> void:
	current_pack = ""
	current_category = ""
	current_query = ""
	if is_instance_valid(pack_option):
		pack_option.selected = 0
	if is_instance_valid(category_option):
		category_option.selected = 0
	if is_instance_valid(search_input):
		search_input.text = ""
	_refresh_list()


func _apply_quick_filter(pack_key: String, category_key: String) -> void:
	current_pack = pack_key
	current_category = category_key
	_select_option_by_value(pack_option, pack_ids, current_pack)
	_select_option_by_value(category_option, category_ids, current_category)
	_refresh_list()


func _on_pack_selected(index: int) -> void:
	current_pack = pack_ids[index] if index >= 0 and index < pack_ids.size() else ""
	_refresh_list()


func _on_category_selected(index: int) -> void:
	current_category = category_ids[index] if index >= 0 and index < category_ids.size() else ""
	_refresh_list()


func _on_search_changed(new_text: String) -> void:
	current_query = new_text
	_refresh_list()


func _copy_selected_id() -> void:
	if selected_id.is_empty():
		return
	DisplayServer.clipboard_set(selected_id)
	last_action = "已复制标准 ID：" + selected_id
	status_label.text = "状态：" + last_action


func _copy_selected_stem() -> void:
	if selected_id.is_empty() or not is_instance_valid(audio_service):
		return
	var info: Dictionary = audio_service.sfx_info(selected_id)
	var text := String(info.get("stem", selected_id))
	DisplayServer.clipboard_set(text)
	last_action = "已复制文件名：" + text
	status_label.text = "状态：" + last_action


func _copy_selected_code() -> void:
	if selected_id.is_empty():
		return
	var snippet := "audio_service.play_sfx(\"%s\")" % selected_id
	DisplayServer.clipboard_set(snippet)
	last_action = "已复制调用代码：" + snippet
	status_label.text = "状态：" + last_action


func _on_master_volume_changed(value: float) -> void:
	if _syncing_controls:
		return
	var v := int(value)
	master_value_label.text = "总音量 %d" % v
	if is_instance_valid(settings_service):
		settings_service.set_value("master_volume", v)
	elif is_instance_valid(audio_service):
		audio_service.apply_settings({"master_volume": v})


func _on_effect_volume_changed(value: float) -> void:
	if _syncing_controls:
		return
	var v := int(value)
	effect_value_label.text = "效果音 %d" % v
	if is_instance_valid(settings_service):
		settings_service.set_value("effect_volume", v)
	elif is_instance_valid(audio_service):
		audio_service.apply_settings({"effect_volume": v})


func _on_mute_toggled(muted: bool) -> void:
	if _syncing_controls:
		return
	if is_instance_valid(settings_service):
		settings_service.set_value("mute", muted)
	elif is_instance_valid(audio_service):
		audio_service.apply_settings({"mute": muted})


func _on_stop_pressed() -> void:
	if is_instance_valid(audio_service):
		audio_service.stop_preview()
		audio_service.stop_node_media()
	last_action = "已停止当前试听与效果音"
	status_label.text = "状态：" + last_action


func _on_close_pressed() -> void:
	if _standalone:
		get_tree().quit()
		return
	closed.emit()
