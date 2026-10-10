extends Control
## 核心页面容器只连接自己的私有子页；Main 无需访问任何卡牌或阅读控件。

signal menu_requested
const UI = preload("res://pages/core/page_controls.gd")
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
	if service == null or service.state.is_empty(): return
	var mode: String = service.state.mode
	investigation.visible = mode in ["investigation", "dialogue"]
	selection.visible = mode == "selection"
	result.visible = mode in ["response", "pending", "collected", "failure"]
	if reader.visible or inspection_reader.visible: return
	if investigation.visible: investigation.render(service)
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
