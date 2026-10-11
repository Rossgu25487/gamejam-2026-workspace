extends Control
## 核心页面容器只连接自己的私有子页；Main 无需访问任何卡牌或阅读控件。

signal menu_requested
const UI = preload("res://pages/core/page_controls.gd")
const ImageLayer = preload("res://pages/core/story_image_layer.gd")
@onready var investigation: VBoxContainer = $Margin/Layout/InvestigationPage
@onready var selection: VBoxContainer = $Margin/Layout/CardSelectionPage
@onready var result: VBoxContainer = $Margin/Layout/ResultPage
@onready var reader: PanelContainer = $MaterialReaderPage
@onready var inspection_reader: PanelContainer = $InspectionReaderPage
@onready var feedback: PanelContainer = $FeedbackPage
@onready var tools: HBoxContainer = $Margin/Layout/Tools
@onready var notice_label: Label = $Margin/Layout/Notice
var service: Node
var input_enabled := true
var refresh_queued := false
var image_layer: Control

func _ready() -> void:
	image_layer = ImageLayer.new()
	add_child(image_layer)
	move_child(image_layer, 0)
	$Margin.z_index = 100
	# 全屏布局容器不截住下层调查卡；实际按钮与正文仍接收自己的输入。
	for container in [$Margin, $Margin/Layout, investigation, selection, result]: container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for popup in [reader, inspection_reader, feedback]: popup.z_index = 200

func bind(core: Node) -> void:
	service = core
	service.changed.connect(_queue_refresh)
	service.notice.connect(func(message: String): notice_label.text = message)
	service.presentation_requested.connect(feedback.play)
	feedback.completed.connect(core.finish_presentation)
	selection.read_requested.connect(reader.open_material)
	result.basis_requested.connect(reader.open_basis)
	reader.bind(core)
	inspection_reader.bind(core)
	reader.closed.connect(_queue_refresh)
	inspection_reader.closed.connect(_queue_refresh)
	UI.button(tools, "办案手册 / I", toggle_inspection)
	UI.button(tools, "菜单 / Esc", menu_requested.emit)

func set_active(active: bool) -> void:
	input_enabled = active
	service.set_paused(not active)
	feedback.paused = not active
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE
	# 暂停期间资格会变化；恢复时重新计算出示与结果操作，不能沿用禁用按钮。
	if active: _queue_refresh()

func reset_page() -> void:
	reader.reset_reader()
	inspection_reader.reset_reader()
	feedback.cancel()
	_queue_refresh()

func set_preferences(values: Dictionary) -> void:
	feedback.reduce_motion = values.get("reduce_motion", false)

func _queue_refresh() -> void:
	# 避免在按钮发射回调中释放旧控件，同一帧多次状态变化合并成一次刷新。
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_refresh")

func _refresh() -> void:
	refresh_queued = false
	if service == null or service.state.is_empty() or not input_enabled: return
	var mode: String = service.state.mode
	investigation.visible = mode in ["investigation", "dialogue"]
	selection.visible = mode == "selection"
	result.visible = mode in ["response", "pending", "collected", "failure"]
	if reader.visible or inspection_reader.visible: return
	var page := "investigation" if mode == "investigation" else ("dialogue" if mode == "dialogue" else ("selection" if mode == "selection" else "result"))
	image_layer.render(service, page, investigation.activate_entry)
	if investigation.visible: investigation.render(service, image_layer.entry_buttons, image_layer.entry_bindings)
	if selection.visible: selection.render(service)
	if result.visible: result.render(service)

func toggle_inspection() -> void:
	if not input_enabled: return
	if inspection_reader.visible: inspection_reader.close_all()
	elif reader.visible and reader.root_kind == "library": reader.close_all()
	elif reader.visible: inspection_reader.open_library()
	else: reader.open_library()

func handle_escape() -> void:
	if inspection_reader.visible: inspection_reader.back()
	elif reader.visible: reader.back()
	elif service.state.mode == "selection" and not service.presenting:
		if service.state.card_ui_page == "grid": service.set_grid(false)
		else: service.fold_card_selection()
	else: menu_requested.emit()

func handle_window_focus_loss() -> void:
	# 下拉菜单也是 Window；先等焦点交接结束，不能在其打开途中隐藏父页面。
	call_deferred("_check_window_focus")

func _check_window_focus() -> void:
	if not input_enabled or not is_visible_in_tree() or get_window().has_focus(): return
	# 嵌入和原生弹窗都属于当前游戏。只有焦点离开全部游戏窗口才请求暂停。
	for window in get_window().find_children("*", "Window", true, false):
		if window.visible and window.has_focus(): return
	menu_requested.emit()

func _input(event: InputEvent) -> void:
	if not visible or not input_enabled or not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_I:
		toggle_inspection()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE:
		handle_escape()
		get_viewport().set_input_as_handled()
	elif not reader.visible and not inspection_reader.visible and selection.handle_card_key(event):
		get_viewport().set_input_as_handled()
