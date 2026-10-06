extends Control
## 主入口：连接计数演练，并管理标题、暂停、子页和离开确认。
## 设置与存档目前只有导航入口，尚未接入真实业务。

const ModelScript = preload("res://features/counter_demo/counter_model.gd")

@export var demo_config: Resource = preload("res://data/demo_config.tres")
@onready var counter_view: Control = $CounterView
@onready var title_page: Control = $TitlePage
var model: RefCounted
var navigation_layer: Control
var title_panel: PanelContainer
var pause_panel: PanelContainer
var confirm_panel: PanelContainer
var subpage_panel: PanelContainer
var status_label: Label
var title_continue: Button
var title_new: Button
var title_load: Button
var title_settings: Button
var title_exit: Button
var pause_resume: Button
var pause_save: Button
var pause_load: Button
var pause_settings: Button
var pause_title: Button
var pause_exit: Button
var confirm_cancel: Button
var confirm_direct: Button
var confirm_accept: Button
# 当前导航层决定 Esc 的处理对象；调查数据仍由 model 管理。
var current_layer := "title"
# 仅表示进入过调查，不代表已经成功保存了进度。
var has_progress := false
var transition_locked := false
# 记录子页和确认的实际调用来源，关闭时恢复页面及原按钮焦点。
var subpage_origin := "title"
var subpage_focus: Button
var confirm_origin := "title"
var confirm_focus: Button
var confirm_exits := false
var scan_complete := false

func _ready() -> void:
	# 配置模型后接通信号，再首次同步界面；界面不保存第二份计数。
	model = ModelScript.new()
	model.configure(demo_config.initial_value, demo_config.step)
	model.value_changed.connect(counter_view.show_value)
	counter_view.increment_requested.connect(_on_increment_requested)
	counter_view.reset_requested.connect(_on_reset_requested)
	counter_view.set_connected(true)
	counter_view.set_step(demo_config.step)
	counter_view.show_value(model.read_value())
	get_window().min_size = Vector2i(860, 560)
	_build_navigation()

func _button(parent: Control, text: String, callback: Callable) -> Button:
	# 动态面板共用按钮尺寸，并将点击连接到对应业务入口。
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(280, 48)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _panel(title: String, detail: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(330, 0)
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

func _build_navigation() -> void:
	# 标题控件来自可编辑场景；暂停、确认和子页仍在运行时创建。
	navigation_layer = Control.new()
	navigation_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	navigation_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(navigation_layer)
	title_panel = $TitlePage/PanelContainer
	status_label = $TitlePage/Status
	title_continue = $TitlePage/PanelContainer/VBoxContainer/Continue
	title_new = $TitlePage/PanelContainer/VBoxContainer/NewGame
	title_load = $TitlePage/PanelContainer/VBoxContainer/Load
	title_settings = $TitlePage/PanelContainer/VBoxContainer/Settings
	title_exit = $TitlePage/PanelContainer/VBoxContainer/Exit
	title_continue.pressed.connect(_on_continue)
	title_new.pressed.connect(_on_new_game)
	title_load.pressed.connect(_on_load)
	title_settings.pressed.connect(_on_settings)
	title_exit.pressed.connect(_on_title_exit)
	_build_pause()
	_build_confirm()
	_build_subpage()
	_show_title()
	call_deferred("_finish_scan")

func _finish_scan() -> void:
	# 当前用延时模拟空档案扫描，后续由存档系统回报真实结果。
	await get_tree().create_timer(0.2).timeout
	scan_complete = true
	status_label.text = "尚无可继续的进度"
	title_load.disabled = false
	if current_layer == "title":
		# 扫描结束时不抢走已打开子页或确认框的焦点。
		title_new.grab_focus()

func _center_panel(panel: PanelContainer) -> void:
	# 使用容器随窗口居中，避免固定像素坐标导致面板偏移。
	var center := CenterContainer.new()
	navigation_layer.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)

func _build_pause() -> void:
	pause_panel = _panel("暂停菜单", "当前调查与选择已保留")
	_center_panel(pause_panel)
	var box := pause_panel.get_child(0) as VBoxContainer
	pause_resume = _button(box, "继续调查", _on_resume)
	pause_save = _button(box, "保存游戏", _on_save)
	pause_load = _button(box, "读取存档", _on_load)
	pause_settings = _button(box, "游戏设置", _on_settings)
	pause_title = _button(box, "返回标题", _on_return_title)
	pause_exit = _button(box, "退出游戏", _on_pause_exit)
	pause_save.disabled = true
	pause_panel.hide()

func _build_confirm() -> void:
	confirm_panel = _panel("离开确认", "当前调查尚未保存。请选择离开方式。")
	_center_panel(confirm_panel)
	var box := confirm_panel.get_child(0) as VBoxContainer
	confirm_cancel = _button(box, "取消", _on_confirm_cancel)
	confirm_direct = _button(box, "直接返回", _on_confirm_direct)
	confirm_accept = _button(box, "保存并返回", _on_confirm_accept)
	confirm_panel.hide()

func _build_subpage() -> void:
	subpage_panel = _panel("游戏设置", "设置页由设置系统接管；本入口已接通。")
	_center_panel(subpage_panel)
	var box := subpage_panel.get_child(0) as VBoxContainer
	var close := _button(box, "关闭设置", _on_close_subpage)
	close.name = "CloseSettings"
	subpage_panel.hide()

func _show_title() -> void:
	# 每次返回都恢复标题提示，隐藏调查界面及其他导航面板。
	current_layer = "title"
	status_label.text = "尚无可继续的进度" if scan_complete else "正在读取进度"
	title_page.show()
	counter_view.hide()
	title_panel.show()
	pause_panel.hide()
	confirm_panel.hide()
	subpage_panel.hide()
	title_new.grab_focus()

func _open_pause() -> void:
	# 打开过渡锁用于拦截重复打开请求；这里尚未暂停世界计时。
	if transition_locked or current_layer != "investigation":
		return
	transition_locked = true
	await get_tree().create_timer(0.2).timeout
	current_layer = "pause"
	pause_panel.show()
	pause_resume.grab_focus()
	transition_locked = false

func _close_pause() -> void:
	# 保留原调查节点和模型，仅在关闭延时后切回调查导航状态。
	transition_locked = true
	await get_tree().create_timer(0.15).timeout
	current_layer = "investigation"
	pause_panel.hide()
	transition_locked = false

func _unhandled_key_input(event: InputEvent) -> void:
	# 按当前层处理 Esc：确认、子页、暂停、调查依次对应不同动作。
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if current_layer == "confirm": _on_confirm_cancel()
		elif current_layer == "subpage": _on_close_subpage()
		elif current_layer == "pause": _on_resume()
		elif current_layer == "investigation": _open_pause()

func _on_continue() -> void:
	if not title_continue.disabled: _start_investigation()

func _on_new_game() -> void:
	_start_investigation()

func _start_investigation() -> void:
	# 当前进入的是计数演练；正式新调查的初始化由后续核心模块接入。
	has_progress = true
	current_layer = "investigation"
	title_page.hide()
	counter_view.show()
	title_panel.hide()
	status_label.text = "调查进行中 · 菜单或 Esc 打开暂停"

func _on_resume() -> void:
	if current_layer == "pause": _close_pause()

func _on_save() -> void:
	pause_save.tooltip_text = "当前演练未接入存档系统"

func _on_load() -> void:
	_open_subpage("读取存档", "读取列表由存档系统提供；当前没有可读取的有效档案。")

func _on_settings() -> void:
	_open_subpage("游戏设置", "设置页由设置系统接管；关闭后回到原入口。")

func _open_subpage(title: String, detail: String) -> void:
	# 在改写 current_layer 前保存来源，避免玩过调查后从标题误回暂停。
	subpage_origin = current_layer
	if title == "读取存档":
		subpage_focus = title_load if subpage_origin == "title" else pause_load
	else:
		subpage_focus = title_settings if subpage_origin == "title" else pause_settings
	current_layer = "subpage"
	var box := subpage_panel.get_child(0) as VBoxContainer
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	(box.get_node("CloseSettings") as Button).text = "关闭读取" if title == "读取存档" else "关闭设置"
	title_panel.hide()
	pause_panel.hide()
	subpage_panel.show()
	(box.get_node("CloseSettings") as Button).grab_focus()

func _on_close_subpage() -> void:
	# 按调用来源返回，并把键盘焦点交还给打开该子页的按钮。
	subpage_panel.hide()
	current_layer = subpage_origin
	if subpage_origin == "title":
		title_page.show()
		title_panel.show()
		counter_view.hide()
	else:
		pause_panel.show()
	if is_instance_valid(subpage_focus) and not subpage_focus.disabled:
		subpage_focus.grab_focus()

func _on_return_title() -> void:
	_open_confirm("返回标题", "保存当前调查后返回标题？", "保存并返回", false)

func _on_pause_exit() -> void:
	_open_confirm("退出游戏", "保存当前调查后退出游戏？", "保存并退出", true)

func _on_title_exit() -> void:
	_open_confirm("退出游戏", "确认退出游戏？", "确认退出", true)

func _open_confirm(title: String, detail: String, accept_text: String, exits: bool) -> void:
	# 同一确认框保存离开目标，直接离开时据此选择返回标题或退出。
	confirm_exits = exits
	confirm_origin = current_layer
	confirm_focus = title_exit if confirm_origin == "title" else (pause_exit if exits else pause_title)
	current_layer = "confirm"
	var box := confirm_panel.get_child(0) as VBoxContainer
	(box.get_child(0) as Label).text = title
	(box.get_child(1) as Label).text = detail
	confirm_direct.text = "直接退出" if exits else "直接返回"
	confirm_accept.text = accept_text
	confirm_direct.visible = confirm_origin != "title"
	# 标题只需取消/确认退出；调查的保存并离开等待存档系统接入。
	confirm_accept.disabled = confirm_origin != "title"
	confirm_accept.tooltip_text = "存档系统尚未接入" if confirm_accept.disabled else ""
	title_panel.hide()
	pause_panel.hide()
	confirm_panel.show()
	confirm_cancel.grab_focus()

func _on_confirm_cancel() -> void:
	# 取消不改变调查内容，也不执行离开目标。
	confirm_panel.hide()
	current_layer = confirm_origin
	if confirm_origin == "title":
		title_panel.show()
	else:
		pause_panel.show()
	if is_instance_valid(confirm_focus):
		confirm_focus.grab_focus()

func _on_confirm_direct() -> void:
	# 真正退出运行中的游戏进程；返回标题仅切换可见页面。
	if confirm_exits:
		get_tree().quit()
	else:
		_show_title()

func _on_confirm_accept() -> void:
	if confirm_accept.disabled:
		return
	_on_confirm_direct()

func _on_increment_requested() -> void:
	model.increment()

func _on_reset_requested() -> void:
	model.reset()
