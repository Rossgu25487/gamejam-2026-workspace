extends Control
## 主入口只负责初始化模块、连接信号和在页面之间调度。
## 标题页、暂停页和计数界面各自处理自己的私有逻辑。

const ModelScript = preload("res://features/counter_demo/counter_model.gd")
const SettingsServiceScript = preload("res://systems/game_settings/settings_service.gd")
const SaveLoadServiceScript = preload("res://systems/save_load/save_load_service.gd")
const GameStartServiceScript = preload("res://systems/game_start/game_start_service.gd")
@export var demo_config: Resource = preload("res://data/demo_config.tres")
@onready var counter_view: Control = $CounterView
@onready var title_page: Control = $TitlePage
@onready var pause_page: Control = $PausePage

var model: RefCounted
var current_layer := "title"
var has_progress := false
var subpage_origin := "title"
var subpage_focus: Button
var confirm_origin := "title"
var confirm_focus: Button
var confirm_exits := false
var confirm_panel: PanelContainer
var subpage_panel: PanelContainer
var confirm_cancel: Button
var confirm_direct: Button
var confirm_accept: Button
var settings_service: Node
var save_service: Node
var game_start_service: Node
var current_snapshot: Dictionary = {}

func _ready() -> void:
	# 主程序只创建模型、连接子页面信号，再决定当前显示哪一页。
	# 初始化外部计数器单例
	model = ModelScript.new()
	settings_service = SettingsServiceScript.new()
	save_service = SaveLoadServiceScript.new()
	game_start_service = GameStartServiceScript.new()
	add_child(settings_service)
	add_child(save_service)
	add_child(game_start_service)
	game_start_service.ready_for_title.connect(_on_start_ready)
	game_start_service.initialize(settings_service, save_service)
	model.configure(demo_config.initial_value, demo_config.step)
	model.value_changed.connect(counter_view.show_value)
	# 计数器demo页面初始化
	counter_view.increment_requested.connect(model.increment)
	counter_view.reset_requested.connect(model.reset)
	counter_view.set_connected(true)
	counter_view.set_step(demo_config.step)
	counter_view.show_value(model.read_value())
	# 标题页初始化
	title_page.continue_requested.connect(_on_continue)
	title_page.new_game_requested.connect(_on_new_game)
	title_page.load_requested.connect(_on_load)
	title_page.settings_requested.connect(_on_settings)
	title_page.exit_requested.connect(_on_title_exit)
	# 暂停页面初始化
	pause_page.resume_requested.connect(_on_resume)
	pause_page.save_requested.connect(_on_save)
	pause_page.load_requested.connect(_on_load)
	pause_page.settings_requested.connect(_on_settings)
	pause_page.return_title_requested.connect(_on_return_title)
	pause_page.exit_requested.connect(_on_pause_exit)
	get_window().min_size = Vector2i(860, 560)
	# 弹出子页面通用确认框初始化
	_build_shared_pages()
	_show_title()

func _build_shared_pages() -> void:
	# 分为弹出通用的确认框和提示子框，是跨标题/暂停共用的导航容器。
	confirm_panel = _make_panel("离开确认", "当前调查尚未保存。请选择离开方式。")
	# 确认按钮只初始化一次；重复打开时复用，避免 box 中不断累积按钮。
	var confirm_box := confirm_panel.get_child(0) as VBoxContainer
	confirm_cancel = Button.new()
	confirm_cancel.text = "取消"
	confirm_cancel.pressed.connect(_on_confirm_cancel)
	confirm_box.add_child(confirm_cancel)
	confirm_direct = Button.new()
	confirm_direct.pressed.connect(_on_confirm_direct)
	confirm_box.add_child(confirm_direct)
	confirm_accept = Button.new()
	confirm_accept.pressed.connect(_on_confirm_accept)
	confirm_box.add_child(confirm_accept)
	subpage_panel = _make_panel("游戏设置", "设置页由设置系统接管；本入口已接通。")
	var close := Button.new()
	close.text = "关闭设置"
	close.pressed.connect(_on_close_subpage)
	subpage_panel.get_child(0).add_child(close)
	confirm_panel.hide()
	subpage_panel.hide()

func _make_panel(title: String, detail: String) -> PanelContainer:
	# 面板放入全屏 CenterContainer，确保读取、设置和确认页始终居中。
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(330, 0)
	var host := CenterContainer.new()
	# host始终铺满窗口；面板隐藏后，host不能截住下层按钮点击。
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(host)
	host.add_child(panel)
	# 垂直容器，自动编排内部的节点
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 28)
	box.add_child(heading)
	var subtitle := Label.new()
	subtitle.text = detail
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(subtitle)
	return panel

func _show_title() -> void:
	# 返回标题时隐藏调查和所有上层页面，由标题页恢复自己的焦点。
	current_layer = "title"
	confirm_panel.hide()
	subpage_panel.hide()
	pause_page.hide_page()
	counter_view.hide()
	title_page.show_page()

func _start_investigation() -> void:
	# 调度调查页面；具体调查内容和状态不在主入口实现。
	has_progress = true
	if current_snapshot.is_empty():
		current_snapshot = game_start_service.create_new_game()
		# 新游戏初始化完成后才建立普通自动档。
		save_service.save_snapshot("auto", 0, current_snapshot)
	current_layer = "investigation"
	title_page.hide_page()
	pause_page.hide_page()
	counter_view.show()

func _on_continue() -> void: _start_investigation()
func _on_new_game() -> void:
	current_snapshot = game_start_service.create_new_game()
	_start_investigation()
func _on_resume() -> void:
	current_layer = "investigation"
	pause_page.hide_page()
	counter_view.show()
func _on_save() -> void:
	if not has_progress:
		pause_page.set_save_available(false, "当前没有可保存的调查")
		return
	_open_subpage("保存存档", "请选择手动存档栏位（共3栏）。")
	_build_save_buttons()
func _on_load() -> void:
	var records: Array = save_service.scan()
	_open_subpage("读取存档", "请选择要读取的有效存档；读取失败会保留当前会话。")
	_build_load_buttons(records)
func _on_settings() -> void:
	_open_subpage("游戏设置", "设置会独立保存，不会被调查存档覆盖。")
	_build_settings_controls()

func _on_start_ready(has_save: bool) -> void:
	# 初始化服务完成后再决定标题页默认焦点。
	title_page.apply_scan_result(has_save)

func _clear_subpage_content() -> VBoxContainer:
	var box := subpage_panel.get_child(0) as VBoxContainer
	while box.get_child_count() > 3:
		box.get_child(3).queue_free()
	return box

func _build_save_buttons() -> void:
	var box := _clear_subpage_content()
	for i in range(3):
		var button := Button.new()
		button.text = "手动存档 %d" % (i + 1)
		button.pressed.connect(func() -> void:
			if save_service.save_snapshot("manual", i, current_snapshot):
				_on_close_subpage())
		box.add_child(button)

func _build_load_buttons(records: Array) -> void:
	var box := _clear_subpage_content()
	for record in records:
		var button := Button.new()
		var kind := str(record.get("slot_kind", "manual"))
		var index := int(record.get("slot_index", 0))
		button.text = "%s %d  |  序号 %s" % [kind, index + 1, str(record.get("save_sequence", "-"))]
		button.pressed.connect(func() -> void:
			var loaded: Dictionary = save_service.load_snapshot(kind, index)
			if not loaded.is_empty():
				current_snapshot = loaded
				has_progress = true
				_on_close_subpage())
		box.add_child(button)
	if records.is_empty():
		var empty := Label.new()
		empty.text = "没有可读取的有效存档"
		box.add_child(empty)

func _build_settings_controls() -> void:
	var box := _clear_subpage_content()
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
		slider.value_changed.connect(func(value: float) -> void: settings_service.set_value(key, int(value)))
		row.add_child(slider)
		box.add_child(row)
	for key in ["mute", "reduce_motion"]:
		var check := CheckButton.new()
		check.text = "静音" if key == "mute" else "减弱动态"
		check.button_pressed = settings_service.get_value(key, false)
		check.toggled.connect(func(value: bool) -> void: settings_service.set_value(key, value))
		box.add_child(check)
	var reset := Button.new()
	reset.text = "恢复默认"
	reset.pressed.connect(func() -> void:
		settings_service.restore_defaults()
		_build_settings_controls())
	box.add_child(reset)

func _open_pause() -> void:
	if current_layer != "investigation": return
	current_layer = "pause"
	pause_page.show_page()

func _open_subpage(title: String, detail: String) -> void:
	# 记录子页来源，关闭后回到标题或暂停页原按钮。
	subpage_origin = current_layer
	subpage_focus = title_page.load_button if title == "读取存档" and subpage_origin == "title" else (pause_page.load_button if title == "读取存档" else (title_page.settings_button if subpage_origin == "title" else pause_page.settings_button))
	current_layer = "subpage"
	# 通用弹出子框赋值
	var box := subpage_panel.get_child(0) as VBoxContainer
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	title_page.hide_page()
	pause_page.hide_page()
	subpage_panel.show()
	(box.get_child(2) as Button).grab_focus()

func _on_close_subpage() -> void:
	subpage_panel.hide()
	if subpage_origin == "title": _show_title()
	else: current_layer = "pause"; pause_page.show_page()
	if is_instance_valid(subpage_focus): subpage_focus.grab_focus()

func _on_return_title() -> void: _open_confirm("返回标题", "保存当前调查后返回标题？", "保存并返回", false)
func _on_pause_exit() -> void: _open_confirm("退出游戏", "保存当前调查后退出游戏？", "保存并退出", true)
func _on_title_exit() -> void: _open_confirm("退出游戏", "确认退出游戏？", "确认退出", true)

func _open_confirm(title: String, detail: String, accept_text: String, exits: bool) -> void:
	# 共用确认框只负责离开选择，保存业务仍交给存档系统。
	confirm_exits = exits
	confirm_origin = current_layer
	confirm_focus = title_page.exit_button if confirm_origin == "title" else pause_page.exit_button
	current_layer = "confirm"
	var box := confirm_panel.get_child(0) as VBoxContainer
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	# 只更新已有按钮，不在每次打开时创建新节点或重复连接信号。
	confirm_direct.text = "直接退出" if exits else "直接返回"
	confirm_direct.visible = confirm_origin != "title"
	confirm_accept.text = accept_text
	confirm_accept.disabled = confirm_origin != "title"
	title_page.hide_page()
	pause_page.hide_page()
	confirm_panel.show()
	confirm_cancel.grab_focus()

func _on_confirm_cancel() -> void:
	confirm_panel.hide()
	if confirm_origin == "title": _show_title()
	else: current_layer = "pause"; pause_page.show_page()
	if is_instance_valid(confirm_focus): confirm_focus.grab_focus()
func _on_confirm_direct() -> void:
	if confirm_exits: get_tree().quit()
	else: _show_title()
func _on_confirm_accept() -> void:
	if confirm_accept.disabled:
		return
	_on_confirm_direct()

func _unhandled_key_input(event: InputEvent) -> void:
	# Esc 只交给当前最上层页面处理，避免输入穿透到下层。
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if current_layer == "confirm": _on_confirm_cancel()
		elif current_layer == "subpage": _on_close_subpage()
		elif current_layer == "pause": _on_resume()
		elif current_layer == "investigation": _open_pause()
