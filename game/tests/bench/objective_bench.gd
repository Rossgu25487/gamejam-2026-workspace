extends Control
## 目标导航试玩台：不依赖案件内容，用 TEST00-TEST10 测试组逐项操作 HUD 与调查回顾。
## 在 Godot 编辑器中打开本场景后按 F6 运行；右侧为真实 HUD，左侧为测试操作，右上角灰框是用来验证“点击不穿透”的场景物件。

const ServiceScript = preload("res://systems/objective/objective_service.gd")
const ProviderScript = preload("res://tests/support/objective_test_provider.gd")

@onready var hud: Control = $HudPage
@onready var review: Control = $ReviewPage
@onready var side: VBoxContainer = $Side/Scroll/Box
var service: Node
var provider: RefCounted
var scene_clicks := 0
var scene_wheels := 0
var allowed_check: CheckButton
var status_label: Label
var step_label: Label
var operation_picker: OptionButton
var scene_button: Button
var step_index := 0
var current_group := ""
var allowed_by_review := true


func _ready() -> void:
	DisplayServer.window_set_title("目标导航试玩台")
	service = ServiceScript.new()
	add_child(service)
	service.setup()
	provider = ProviderScript.new()
	provider.load_data()
	service.bind_provider(provider)
	hud.bind(service)
	review.bind(service)
	hud.review_requested.connect(service.request_review)
	service.review_state_changed.connect(_on_review_state)
	service.changed.connect(_update_status)
	_build_side()
	_apply_group("TEST01", "initial")


func _on_review_state(_state: String) -> void:
	_sync_allowed()


func _sync_allowed() -> void:
	# 回顾打开时目标隐藏并停用，关闭后按“允许显示”开关恢复。
	service.set_display_allowed(allowed_check.button_pressed and service.review_state != "open")


func _build_side() -> void:
	_title("目标导航试玩台")
	_note("右侧的目标面板和回顾页面是正式页面；下面的按钮只提供测试数据。")
	_title("测试组（按配置表 TEST00-TEST10）")
	var grid := GridContainer.new()
	grid.columns = 4
	side.add_child(grid)
	for id in provider.data["groups"].keys():
		var button := Button.new()
		button.text = id
		button.tooltip_text = String(provider.group(id)["goal_text"]) if not String(provider.group(id)["goal_id"]).is_empty() else "无目标"
		button.pressed.connect(_apply_group.bind(id, ""))
		grid.add_child(button)
	var restore := Button.new()
	restore.text = "以当前组读档重建（restore）"
	restore.pressed.connect(func(): _apply_group(current_group, "restore"))
	side.add_child(restore)
	_title("显示与状态")
	allowed_check = _check("允许显示（对白、手册等覆盖时取消）", true, func(_on: bool): _sync_allowed())
	_check("暂停计时", false, func(on: bool): service.set_paused(on))
	_check("减弱动态", false, func(on: bool): service.set_reduce_motion(on))
	_title("失败与异步")
	_check("回顾准备失败", false, func(on: bool): provider.fail_prepare = on)
	_check("依据读取失败", false, func(on: bool): provider.fail_read = on)
	_check("回顾准备异步（点下面按钮完成）", false, func(on: bool): provider.async_prepare = on)
	_button("完成异步准备（成功）", func(): service.complete_review(true))
	_button("完成异步准备（失败）", func(): service.complete_review(false))
	_check("复查 TEST_ENTRY_02 为不可用", false, func(on: bool): _set_recheck(on))
	_title("配置表测试操作（逐步演练）")
	operation_picker = OptionButton.new()
	for operation in provider.data["operations"]:
		operation_picker.add_item("%s  %s" % [operation["id"], " > ".join(operation["groups"])])
	operation_picker.item_selected.connect(func(_index: int): _reset_steps())
	side.add_child(operation_picker)
	_button("下一步（依次送入该操作的测试组）", _next_step)
	step_label = _note("")
	_title("当前状态")
	status_label = _note("")
	scene_button = Button.new()
	scene_button.text = "场景物件（点击计数 0）"
	scene_button.set_anchors_preset(Control.PRESET_TOP_LEFT)
	scene_button.position = Vector2(860, 90)
	scene_button.size = Vector2(380, 420)
	scene_button.focus_mode = Control.FOCUS_NONE
	scene_button.modulate = Color(1, 1, 1, 0.35)
	scene_button.pressed.connect(func():
		scene_clicks += 1
		scene_button.text = "场景物件（点击计数 %d）" % scene_clicks)
	scene_button.gui_input.connect(func(event: InputEvent):
		# 滚轮不应穿透面板或列表到达背后的场景物件。
		if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			scene_wheels += 1)
	add_child(scene_button)
	move_child(scene_button, hud.get_index()) # 放在目标面板之下，用来检查点击是否穿透
	_reset_steps()


func _title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.87, 0.78, 0.61))
	side.add_child(label)
	return label


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 300
	side.add_child(label)
	return label


func _check(text: String, value: bool, action: Callable) -> CheckButton:
	var check := CheckButton.new()
	check.text = text
	check.button_pressed = value
	check.toggled.connect(action)
	side.add_child(check)
	return check


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	side.add_child(button)
	return button


func _set_recheck(unavailable: bool) -> void:
	if unavailable:
		provider.entry_recheck["TEST_ENTRY_02"] = {"available": false, "reason": "对方暂时无法交谈"}
	else:
		provider.entry_recheck.erase("TEST_ENTRY_02")


func _apply_group(id: String, origin: String) -> void:
	current_group = id
	provider.use_group(id)
	service.refresh(origin if not origin.is_empty() else String(provider.group(id)["origin"]))
	_update_status()


func _reset_steps() -> void:
	step_index = 0
	var operation: Dictionary = provider.data["operations"][operation_picker.selected]
	step_label.text = "操作：%s\n预期：%s" % [operation["operation"], operation["expected"]]


func _next_step() -> void:
	var operation: Dictionary = provider.data["operations"][operation_picker.selected]
	var groups: Array = operation["groups"]
	if step_index < groups.size():
		var id := String(groups[step_index])
		var origin := "initial" if step_index == 0 and String(provider.group(id)["origin"]) == "initial" else String(provider.group(id)["origin"])
		_apply_group(id, origin)
		step_index += 1
	step_label.text = "操作：%s\n预期：%s\n已送入：%d / %d" % [operation["operation"], operation["expected"], step_index, groups.size()]


func _update_status() -> void:
	if status_label == null:
		return
	var view: Dictionary = service.hud_view()
	status_label.text = "测试组 %s | 显示 %s | 展开 %s | 标记 %s | 已更新 %s | 回顾 %s | 待核 %d 项" % [current_group, view["shown"], view["expanded"], view["marker"], view["notice"], service.review_state, view["items"].size()]
