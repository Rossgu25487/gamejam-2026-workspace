extends Control
## 标题页负责扫描提示、标题按钮和自身焦点，不直接调度其他页面。
signal continue_requested
signal new_game_requested
signal load_requested
signal settings_requested
signal exit_requested
@onready var status: Label = $Status
@onready var panel: PanelContainer = $PanelContainer
@onready var continue_button: Button = $PanelContainer/VBoxContainer/Continue
@onready var new_game_button: Button = $PanelContainer/VBoxContainer/NewGame
@onready var load_button: Button = $PanelContainer/VBoxContainer/Load
@onready var settings_button: Button = $PanelContainer/VBoxContainer/Settings
@onready var exit_button: Button = $PanelContainer/VBoxContainer/Exit
var scan_complete := false
func _ready() -> void:
	# 按钮只发出动作请求，由 Main 决定页面跳转。
	continue_button.pressed.connect(continue_requested.emit)
	new_game_button.pressed.connect(new_game_requested.emit)
	load_button.pressed.connect(load_requested.emit) 
	settings_button.pressed.connect(settings_requested.emit)
	exit_button.pressed.connect(exit_requested.emit)
	begin_scan()
func begin_scan() -> void:
	# 扫描期间继续和读取禁用；真实档案结果由存档系统替换。
	scan_complete = false
	status.text = "正在读取进度"
	continue_button.disabled = true
	load_button.disabled = true
	call_deferred("_finish_scan")
func _finish_scan() -> void:
	await get_tree().create_timer(0.2).timeout
	scan_complete = true
	status.text = "尚无可继续的进度"
	load_button.disabled = false
	if visible and is_instance_valid(new_game_button): 
		new_game_button.grab_focus()
func show_page() -> void:
	# 页面恢复时由自身恢复默认焦点。
	show()
	status.text = "尚无可继续的进度" if scan_complete else "正在读取进度"
	if is_instance_valid(new_game_button): 
		new_game_button.grab_focus()
func hide_page() -> void: 
	hide()
