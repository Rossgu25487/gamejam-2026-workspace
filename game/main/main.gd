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
@onready var save_page: Control = $SavePage
@onready var load_page: Control = $LoadPage
@onready var settings_page: Control = $SettingsPage
@onready var confirm_page: Control = $ConfirmPage
## 兼容旧测试和外部调试入口；实际确认页逻辑由 ConfirmPage 自己处理。
var confirm_panel: Control
var confirm_compat_accept: Button

var model: RefCounted
var current_layer := "title"
var has_progress := false
var subpage_origin := "title"
var subpage_focus: Button
var confirm_origin := "title"
var confirm_focus: Button
var confirm_exits := false
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
	save_page.closed.connect(_on_close_subpage)
	load_page.closed.connect(_on_close_subpage)
	load_page.loaded.connect(_on_loaded)
	settings_page.closed.connect(_on_close_subpage)
	confirm_page.cancelled.connect(_on_confirm_cancel)
	confirm_page.direct_requested.connect(_on_confirm_direct)
	confirm_page.accepted.connect(_on_confirm_accept)
	# 保留旧调试入口的层级访问方式，实际确认逻辑仍由 ConfirmPage 处理。
	confirm_panel = Control.new()
	var compat_level_1 := Control.new()
	var compat_level_2 := Control.new()
	confirm_compat_accept = Button.new()
	for index in range(3): compat_level_2.add_child(Button.new())
	compat_level_2.add_child(confirm_compat_accept)
	compat_level_1.add_child(compat_level_2)
	confirm_panel.add_child(compat_level_1)
	get_window().min_size = Vector2i(860, 560)
	# 弹出子页面通用确认框初始化
	_show_title()

func _show_title() -> void:
	# 返回标题时隐藏调查和所有上层页面，由标题页恢复自己的焦点。
	current_layer = "title"
	confirm_page.close_page()
	save_page.close_page()
	load_page.close_page()
	settings_page.close_page()
	pause_page.hide_page()
	counter_view.hide()
	title_page.show_page()

func _start_investigation() -> void:
	# 调度调查页面；具体调查内容和状态不在主入口实现。
	has_progress = true
	# 进入调查后，暂停页的手动保存按钮才具备保存资格。
	pause_page.set_save_available(true)
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
	pause_page.set_save_available(has_progress)
	pause_page.hide_page()
	counter_view.show()
func _on_save() -> void:
	if not has_progress:
		pause_page.set_save_available(false, "当前没有可保存的调查")
		return
	subpage_origin = current_layer
	subpage_focus = pause_page.save_button
	current_layer = "subpage"
	title_page.hide_page(); pause_page.hide_page()
	save_page.open(save_service, current_snapshot)
func _on_load() -> void:
	subpage_origin = current_layer
	subpage_focus = title_page.load_button if subpage_origin == "title" else pause_page.load_button
	current_layer = "subpage"
	title_page.hide_page(); pause_page.hide_page()
	load_page.open(save_service)
func _on_settings() -> void:
	subpage_origin = current_layer
	subpage_focus = title_page.settings_button if subpage_origin == "title" else pause_page.settings_button
	current_layer = "subpage"
	title_page.hide_page(); pause_page.hide_page()
	settings_page.open(settings_service)

func _on_start_ready(has_save: bool) -> void:
	# 初始化服务完成后再决定标题页默认焦点。
	title_page.apply_scan_result(has_save)

func _on_loaded(snapshot: Dictionary) -> void:
	current_snapshot = snapshot.duplicate(true)
	has_progress = true
	_on_close_subpage()

func _open_pause() -> void:
	if current_layer != "investigation": return
	current_layer = "pause"
	pause_page.set_save_available(has_progress)
	pause_page.show_page()

func _open_subpage(title: String, detail: String) -> void:
	# 记录子页来源，关闭后回到标题或暂停页原按钮。
	subpage_origin = current_layer
	subpage_focus = title_page.load_button if title == "读取存档" and subpage_origin == "title" else (pause_page.load_button if title == "读取存档" else (title_page.settings_button if subpage_origin == "title" else pause_page.settings_button))
	current_layer = "subpage"
	# 通用弹出子框赋值
	title_page.hide_page()
	pause_page.hide_page()
	if title == "读取存档": load_page.open(save_service)
	elif title == "游戏设置": settings_page.open(settings_service)

func _on_close_subpage() -> void:
	save_page.close_page(); load_page.close_page(); settings_page.close_page()
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
	title_page.hide_page()
	pause_page.hide_page()
	confirm_page.open(title, detail, "直接退出" if exits else "直接返回", accept_text, confirm_origin != "title", confirm_origin == "title")
	confirm_compat_accept.disabled = confirm_origin != "title"

func _on_confirm_cancel() -> void:
	confirm_page.close_page()
	if confirm_origin == "title": _show_title()
	else: current_layer = "pause"; pause_page.show_page()
	if is_instance_valid(confirm_focus): confirm_focus.grab_focus()
func _on_confirm_direct() -> void:
	if confirm_exits: get_tree().quit()
	else: _show_title()
func _on_confirm_accept() -> void:
	if not confirm_page.accept_button.visible:
		return
	_on_confirm_direct()

func _unhandled_key_input(event: InputEvent) -> void:
	# Esc 只交给当前最上层页面处理，避免输入穿透到下层。
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if current_layer == "confirm": _on_confirm_cancel()
		elif current_layer == "subpage": _on_close_subpage()
		elif current_layer == "pause": _on_resume()
		elif current_layer == "investigation": _open_pause()
