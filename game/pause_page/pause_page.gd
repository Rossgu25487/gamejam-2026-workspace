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
var formal_layout: RefCounted
var formal_canvas: Control
var formal_menu: Panel
var formal_heading: Label
var formal_detail: Label

func configure_formal(config: RefCounted) -> void:
	formal_layout = preload("res://pages/aurora/aurora_entry_layout.gd").new()
	formal_layout.bind(config)
	formal_canvas = Control.new()
	formal_canvas.name = "PauseLayout"
	formal_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	formal_canvas.theme = formal_layout.theme
	add_child(formal_canvas)
	formal_menu = formal_layout.panel(formal_canvas)
	formal_heading = $PanelContainer/VBoxContainer/Heading
	formal_detail = $PanelContainer/VBoxContainer/Detail
	for node in [formal_heading, formal_detail, resume_button, save_button, load_button, settings_button, return_title_button, exit_button]: node.reparent(formal_canvas, false)
	$PanelContainer.hide()
	formal_heading.add_theme_font_size_override("font_size", 36)
	formal_detail.add_theme_font_size_override("font_size", 24)
	formal_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for button in [resume_button, save_button, load_button, settings_button, return_title_button, exit_button]: formal_layout.button_style(button, button == resume_button)
	resized.connect(_layout_formal)
	_layout_formal()

func _layout_formal() -> void:
	if not is_instance_valid(formal_canvas) or size.y <= 0: return
	var factor := size.y / 900.0
	formal_canvas.scale = Vector2.ONE * factor
	formal_canvas.size = size / factor
	var ratio: int = formal_layout.ratio_for(formal_canvas.size.x)
	var state := "reading" if save_button.disabled else "investigation"
	for pair in [[formal_menu, "pause.menu_surface_1"], [formal_heading, "pause.text_ui_pause_heading_1"], [formal_detail, "pause.text_ui_pause_retained_1"], [resume_button, "pause.resume"], [save_button, "pause.save"], [load_button, "pause.load"], [settings_button, "pause.settings"], [return_title_button, "pause.leave"], [exit_button, "pause.exit"]]:
		formal_layout.place(pair[0], formal_layout.row_for(pair[1], state, ratio), formal_canvas.size)

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
	var buttons := {"resume": resume_button, "save": save_button, "load": load_button, "settings": settings_button, "return_title": return_title_button, "exit": exit_button}
	var index := 1
	for row in core.catalog.get_meta("navigation_buttons", []):
		if row.page != "pause" or not buttons.has(row.action) or str(row.id) in ["NAV_PAUSE_RESUME_CAT", "NAV_PAUSE_RESUME_ENDING"]: continue
		var button: Button = buttons[row.action]
		button.text = core.ui(str(row.label_key))
		button.get_parent().move_child(button, index)
		index += 1

func set_developer_tools_enabled(enabled: bool) -> void:
	# 正式暂停菜单固定六项；制作工具需显式开启。
	sfx_button.visible = enabled

func apply_navigation(rows: Array, text_of: Callable) -> void:
	var buttons := {"resume": resume_button, "save": save_button, "load": load_button, "settings": settings_button, "return_title": return_title_button, "exit": exit_button}
	var index := 1
	for row in rows:
		if row.page != "pause" or not buttons.has(row.action) or str(row.id) in ["NAV_PAUSE_RESUME_CAT", "NAV_PAUSE_RESUME_ENDING"]: continue
		var button: Button = buttons[row.action]
		button.text = str(text_of.call(str(row.label_key)))
		button.get_parent().move_child(button, index)
		index += 1
	
func show_page() -> void:
	# 页面恢复时由自身恢复默认焦点。
	show()
	_layout_formal()
	if is_instance_valid(resume_button): 
		resume_button.grab_focus()
func hide_page() -> void: 
	hide()
func set_save_available(enabled: bool, reason: String = "") -> void:
	# 主程序根据当前调查资格开启或禁用手动保存。
	save_button.disabled = not enabled
	save_button.tooltip_text = reason
	_layout_formal()

func set_resume_context(title: String) -> void:
	resume_button.text = title
