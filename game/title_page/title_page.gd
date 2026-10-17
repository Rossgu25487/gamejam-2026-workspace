extends Control
## 标题页负责扫描提示、标题按钮和自身焦点，不直接调度其他页面。
# 标题页只报告用户选择，页面跳转由 Main 统一调度。
signal continue_requested
signal new_game_requested
signal load_requested
signal settings_requested
signal sfx_manager_requested
signal exit_requested
@onready var status: Label = $Status
@onready var heading: Label = $PanelContainer/VBoxContainer/Heading
@onready var panel: PanelContainer = $PanelContainer
@onready var continue_button: Button = $PanelContainer/VBoxContainer/Continue
@onready var new_game_button: Button = $PanelContainer/VBoxContainer/NewGame
@onready var load_button: Button = $PanelContainer/VBoxContainer/Load
@onready var settings_button: Button = $PanelContainer/VBoxContainer/Settings
@onready var sfx_button: Button = $PanelContainer/VBoxContainer/SfxManager
@onready var exit_button: Button = $PanelContainer/VBoxContainer/Exit
@onready var detail: Label = $PanelContainer/VBoxContainer/Detail
var scan_complete := false # 存档扫描是否完成。
var has_progress := false # 是否存在可以继续的有效存档。
func bind_images(core: Node) -> void:
	preload("res://pages/core/story_image_layer.gd").bind_page(self, core, "title")
	var buttons := {"new_game": new_game_button, "continue": continue_button, "load": load_button, "settings": settings_button, "exit": exit_button}
	var index := 1
	for row in core.catalog.get_meta("navigation_buttons", []):
		if row.page != "title" or not buttons.has(row.action): continue
		var button: Button = buttons[row.action]
		button.text = core.ui(str(row.label_key))
		button.get_parent().move_child(button, index)
		index += 1

func apply_story_title(title: String) -> void:
	# 标题页管理自己的文本和换行，调度层仅传入配置中的案件标题。
	heading.text = title
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	heading.custom_minimum_size.x = 280

func apply_navigation(rows: Array, text_of: Callable) -> void:
	var buttons := {"new_game": new_game_button, "continue": continue_button, "load": load_button, "settings": settings_button, "exit": exit_button}
	var index := 1
	for row in rows:
		if row.page != "title" or not buttons.has(row.action): continue
		var button: Button = buttons[row.action]
		button.text = str(text_of.call(str(row.label_key)))
		button.get_parent().move_child(button, index)
		index += 1

func set_developer_tools_enabled(enabled: bool) -> void:
	# 工具入口与正式五项导航分开；隐藏的入口不参与焦点顺序。
	sfx_button.visible = enabled

func _ready() -> void:
	# 按钮只发出动作请求，由 Main 决定页面跳转。
	continue_button.pressed.connect(continue_requested.emit)
	new_game_button.pressed.connect(new_game_requested.emit)
	load_button.pressed.connect(load_requested.emit) 
	settings_button.pressed.connect(settings_requested.emit)
	sfx_button.pressed.connect(sfx_manager_requested.emit)
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
	# 兜底完成标题页自身的异步状态；正式结果由初始化服务注入。
	await get_tree().create_timer(0.2).timeout
	if scan_complete:
		return
	scan_complete = true
	status.text = "尚无可继续的进度"
	load_button.disabled = false
	if visible and is_instance_valid(new_game_button): 
		new_game_button.grab_focus()

func apply_scan_result(has_progress: bool) -> void:
	# 初始化服务完成后由主程序注入扫描结果，标题页只更新自身显示。
	scan_complete = true
	self.has_progress = has_progress
	status.text = "已有可继续的调查" if has_progress else "尚无可继续的进度"
	if not has_progress:
		detail.text = "最近有效进度：尚无可继续的进度"
	continue_button.disabled = not has_progress
	load_button.disabled = not has_progress
	if visible:
		(continue_button if has_progress else new_game_button).grab_focus()

func apply_latest_summary(summary: String) -> void:
	# 标题页只负责显示存档服务提供的最新有效进度摘要。
	detail.text = "最近有效进度：" + summary

func show_configuration_error(messages: Array[String]) -> void:
	# 错误页面属于标题节点自身：保留完整错误正文，阻止开始无效案件。
	scan_complete = true
	status.text = "故事配置错误"
	detail.text = "请修正配置表后重新运行。"
	for button in [continue_button, new_game_button, load_button, settings_button, sfx_button]:
		button.disabled = true
		button.hide()
	# 错误正文占用独立滚动区，保持标题节点内居中且退出按钮始终可见。
	panel.offset_left = -330
	panel.offset_right = 330
	panel.offset_top = -250
	panel.offset_bottom = 250
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 300)
	panel.get_child(0).add_child(scroll)
	var error_text := Label.new()
	error_text.text = "\n".join(messages)
	error_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(error_text)
	show()
	exit_button.grab_focus()
func show_page() -> void:
	# 页面恢复时由自身恢复默认焦点。
	show()
	status.text = ("已有可继续的调查" if has_progress else "尚无可继续的进度") if scan_complete else "正在读取进度"
	if is_instance_valid(new_game_button): 
		(continue_button if has_progress else new_game_button).grab_focus()
func hide_page() -> void: 
	# 隐藏标题页，避免标题按钮在调查期间接收输入。
	hide()
