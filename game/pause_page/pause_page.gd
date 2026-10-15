extends Control
## 暂停页负责自己的按钮连接、可用状态和焦点，不直接修改主场景。
# 页面只发出动作请求，具体业务由 Main 调度对应服务或页面。
signal resume_requested
signal save_requested
signal load_requested
signal settings_requested
signal sfx_manager_requested
signal return_title_requested
signal exit_requested
@onready var resume_button: Button = $PanelContainer/VBoxContainer/Resume
@onready var save_button: Button = $PanelContainer/VBoxContainer/Save
@onready var load_button: Button = $PanelContainer/VBoxContainer/Load
@onready var settings_button: Button = $PanelContainer/VBoxContainer/Settings
@onready var sfx_button: Button = $PanelContainer/VBoxContainer/SfxManager
@onready var return_title_button: Button = $PanelContainer/VBoxContainer/ReturnTitle
@onready var exit_button: Button = $PanelContainer/VBoxContainer/Exit

func _ready() -> void:
	# 按钮只发出动作请求，由 Main 决定页面跳转。
	resume_button.pressed.connect(resume_requested.emit)
	save_button.pressed.connect(save_requested.emit)
	load_button.pressed.connect(load_requested.emit)
	settings_button.pressed.connect(settings_requested.emit)
	sfx_button.pressed.connect(sfx_manager_requested.emit)
	return_title_button.pressed.connect(return_title_requested.emit)
	exit_button.pressed.connect(exit_requested.emit) 
	# 初始处于标题页，没有调查会话，因此暂时不能保存。
	save_button.disabled = true
	hide()

func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "pause")

func set_developer_tools_enabled(enabled: bool) -> void:
	# 正式暂停菜单固定六项；制作工具需显式开启。
	sfx_button.visible = enabled
	
func show_page() -> void:
	# 页面恢复时由自身恢复默认焦点。
	show()
	if is_instance_valid(resume_button): 
		resume_button.grab_focus()
func hide_page() -> void: 
	hide()
func set_save_available(enabled: bool, reason: String = "") -> void: 
	# 主程序根据当前调查资格开启或禁用手动保存。
	save_button.disabled = not enabled
	save_button.tooltip_text = reason
