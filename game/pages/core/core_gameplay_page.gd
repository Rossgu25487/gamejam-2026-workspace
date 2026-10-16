extends Control
## 核心页面容器只连接自己的私有子页；Main 无需访问任何卡牌或阅读控件。

signal menu_requested
signal initial_save_retry_requested
const UI = preload("res://pages/core/page_controls.gd")
const ImageLayer = preload("res://pages/core/story_image_layer.gd")
const MARGIN_BASE := 24 # 调查页右侧默认边距；目标面板展开时按面板宽度加大
@onready var margin: MarginContainer = $Margin
@onready var investigation: VBoxContainer = $Margin/Layout/InvestigationPage
@onready var selection: VBoxContainer = $Margin/Layout/CardSelectionPage
@onready var result: VBoxContainer = $Margin/Layout/ResultPage
@onready var reader: PanelContainer = $MaterialReaderPage
@onready var inspection_reader: PanelContainer = $InspectionReaderPage
@onready var feedback: PanelContainer = $FeedbackPage
@onready var narrative_page: Control = $NarrativePage
@onready var map_page: Control = $MapNavigationPage
@onready var objective_hud: Control = $ObjectiveHudPage
@onready var objective_review: Control = $ObjectiveReviewPage
@onready var cat_page: Control = $CatPage
@onready var tools: HBoxContainer = $Margin/Layout/Tools
@onready var notice_label: Label = $Margin/Layout/Notice
var service: Node
var objectives: Node # 目标导航服务；未接入时为空，页面照常工作
var review_focus: WeakRef # 打开调查回顾前的焦点控件
var input_enabled := true
var refresh_queued := false
var image_layer: Control
var notice_timer: Timer
var initial_save_retry: Button

func _ready() -> void:
	notice_timer = Timer.new()
	notice_timer.one_shot = true
	add_child(notice_timer)
	notice_timer.timeout.connect(func(): notice_label.text = "")
	image_layer = ImageLayer.new()
	add_child(image_layer)
	move_child(image_layer, 0)
	$Margin.z_index = 100
	# 全屏布局容器不截住下层调查卡；实际按钮与正文仍接收自己的输入。
	for container in [$Margin, $Margin/Layout, investigation, selection, result]: container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for popup in [reader, inspection_reader, feedback]: popup.z_index = 200
	narrative_page.hide()
	map_page.hide()

func bind(core: Node, objective_service: Node = null) -> void:
	service = core
	investigation.refresh_requested.connect(_queue_refresh)
	var session := core.get_parent()
	if session != null and session.get("scene_interaction") != null:
		investigation.bind_scene_service(session.scene_interaction)
	service.changed.connect(_queue_refresh)
	service.notice.connect(show_notice)
	service.material_acquired.connect(show_feedback)
	service.presentation_requested.connect(feedback.play)
	feedback.completed.connect(core.finish_presentation)
	if core.get_parent().configuration != null:
		feedback.sound_timings = core.get_parent().configuration.definition.get("sound_timings", [])
		feedback.media_requested.connect(core.get_parent().media_requested.emit)
	selection.read_requested.connect(reader.open_material)
	result.basis_requested.connect(reader.open_basis)
	reader.bind(core)
	inspection_reader.bind(core)
	narrative_page.bind(core.get_parent().narrative)
	narrative_page.menu_requested.connect(menu_requested.emit)
	cat_page.bind(core.get_parent())
	cat_page.menu_requested.connect(menu_requested.emit)
	cat_page.closed.connect(_queue_refresh)
	core.get_parent().narrative.changed.connect(_on_narrative_state)
	core.get_parent().ending_configuration_required.connect(_show_ending_configuration)
	core.get_parent().investigation_entry_requested.connect(investigation.open_inspection_entry, CONNECT_DEFERRED)
	map_page.bind(core.get_parent().map_navigation)
	for cover in [narrative_page, map_page, cat_page]: cover.visibility_changed.connect(_sync_modal_visibility)
	map_page.closed.connect(_queue_refresh)
	reader.closed.connect(_queue_refresh)
	inspection_reader.closed.connect(_queue_refresh)
	UI.button(tools, "办案手册 / I", toggle_inspection)
	UI.button(tools, "菜单 / Esc", menu_requested.emit)
	initial_save_retry = UI.button(tools, "重试初次保存", initial_save_retry_requested.emit)
	initial_save_retry.hide()
	if objective_service != null: _bind_objectives(objective_service)

func _bind_objectives(objective_service: Node) -> void:
	# 目标 HUD 与调查回顾是本页的私有子页；服务只提供数据，其余连接都收在这里。
	if objective_service.config.is_empty():
		push_warning("目标导航配置缺失，已跳过目标显示")
		return
	objectives = objective_service
	objective_hud.bind(objectives)
	objective_review.bind(objectives)
	objective_hud.review_requested.connect(_open_review)
	objectives.changed.connect(_update_reserve)
	objectives.review_state_changed.connect(_on_review_state)
	get_viewport().size_changed.connect(_update_reserve)
	# 阅读、结果反馈等覆盖界面出现或消失时重新判断目标是否显示，避免相互叠放。
	for cover in [reader, inspection_reader, feedback, narrative_page, map_page, cat_page]:
		cover.visibility_changed.connect(_sync_objective)

func set_active(active: bool) -> void:
	input_enabled = active
	service.get_parent().set_activity_enabled(active)
	service.set_paused(not active)
	if not active: service.get_parent().narrative.stop_fast_read()
	notice_timer.paused = not active
	cat_page.set_paused(not active)
	feedback.paused = not active
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	mouse_filter = Control.MOUSE_FILTER_STOP if active else Control.MOUSE_FILTER_IGNORE
	if objectives != null:
		objectives.set_paused(not active) # 暂停或离开时目标的提示与提亮计时一同暂停
		_sync_objective()
	# 暂停期间资格会变化；恢复时重新计算出示与结果操作，不能沿用禁用按钮。
	if active: _queue_refresh()

func show_feedback(message: String, duration_ms: int = 2000) -> void:
	# 取得／更新反馈只改变显示，不代替收下或触发存档；暂停期间冻结剩余时长。
	notice_label.text = message
	var control: Dictionary = service.catalog.get_meta("navigation_control", {})
	notice_timer.start(float(control.get("ui_feedback_ms", duration_ms)) / 1000.0)

func show_notice(message: String) -> void:
	# 错误与资格原因持续显示，不能被上一条取得提示的计时器清掉。
	notice_timer.stop()
	notice_label.text = message

func set_initial_save_failed(failed: bool) -> void:
	initial_save_retry.visible = failed
	if failed: show_notice("初次保存失败，当前调查和原存档已保留。返回可操作调查后可重试。")
	elif notice_label.text.begins_with("初次保存失败"): show_notice("")

func start_narrative(definition: Dictionary, start_text_id: String = "") -> bool:
	if service == null or service.get_parent() == null: return false
	var session := service.get_parent()
	if not session.start_narrative(definition, start_text_id): return false
	narrative_page.show()
	investigation.hide()
	selection.hide()
	result.hide()
	return true

func _sync_modal_visibility() -> void:
	# 全屏子页期间底层热点、工具按钮和图片卡不参与 Tab 与快捷键。
	var covered: bool = narrative_page.visible or map_page.visible or cat_page.visible or _review_open()
	margin.visible = not covered
	image_layer.visible = not covered

func _on_narrative_state() -> void:
	var state: Dictionary = service.get_parent().narrative.state
	if not state.is_empty() and not state.get("finished", false): narrative_page.show()
	# 文案明确结束才归还调查输入；等待本句与选择期间持续保留模态层。
	if narrative_page.visible and bool(service.get_parent().narrative.state.get("finished", false)):
		narrative_page.hide()
		_queue_refresh()

func _show_ending_configuration() -> void:
	# 当前测试包未交付片尾步骤，留在独立页面，阻止回落调查后反复提交结束。
	narrative_page.show_pending_ending()
	margin.hide()
	image_layer.hide()

func reset_page() -> void:
	investigation.reset_overlay()
	notice_timer.stop()
	notice_label.text = ""
	if is_instance_valid(initial_save_retry): initial_save_retry.hide()
	reader.reset_reader()
	inspection_reader.reset_reader()
	feedback.cancel()
	narrative_page.hide()
	narrative_page.reset_stage()
	map_page.hide()
	cat_page.reset_page()
	if objectives != null:
		objectives.reset()
		margin.show()
	_queue_refresh()

func set_preferences(values: Dictionary) -> void:
	if is_instance_valid(narrative_page.stage): narrative_page.stage.reduced = bool(values.get("reduce_motion", false))
	feedback.reduce_motion = values.get("reduce_motion", false)
	cat_page.set_preferences(values)
	map_page.set_preferences(values)
	if objectives != null: objectives.set_reduce_motion(feedback.reduce_motion)

func _queue_refresh() -> void:
	# 避免在按钮发射回调中释放旧控件，同一帧多次状态变化合并成一次刷新。
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_refresh")

func _refresh() -> void:
	refresh_queued = false
	if service == null or service.state.is_empty() or not input_enabled: return
	_sync_objective()
	var mode: String = service.state.mode
	investigation.visible = mode in ["investigation", "dialogue"]
	selection.visible = mode == "selection"
	result.visible = mode in ["response", "pending", "collected", "failure"]
	if reader.visible or inspection_reader.visible or _review_open() or narrative_page.visible or map_page.visible or cat_page.visible: return
	var page := "investigation" if mode == "investigation" else ("dialogue" if mode == "dialogue" else ("selection" if mode == "selection" else "result"))
	if investigation.scene_service != null and not investigation.scene_service.compatibility_mode and page == "investigation": image_layer.hide()
	else: image_layer.show(); image_layer.render(service, page, investigation.activate_entry)
	if investigation.visible: investigation.render(service, image_layer.entry_buttons, image_layer.entry_bindings)
	if selection.visible: selection.render(service)
	if result.visible: result.render(service)

func toggle_inspection() -> void:
	if not input_enabled or map_page.visible or _review_open() or narrative_page.visible or cat_page.visible: return
	if inspection_reader.visible: inspection_reader.close_all()
	elif reader.visible and reader.root_kind == "library": reader.close_all()
	elif reader.visible: inspection_reader.open_library()
	else: reader.open_library()

func open_map() -> void:
	if not input_enabled or map_page.visible or reader.visible or inspection_reader.visible or narrative_page.visible or cat_page.visible or _review_open(): return
	map_page.open()

func handle_escape() -> void:
	if map_page.visible: map_page.close()
	elif inspection_reader.visible: inspection_reader.back()
	elif reader.visible: reader.back()
	elif _review_open(): objective_review.handle_escape()
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
	if cat_page.visible:
		if event.keycode == KEY_ESCAPE: menu_requested.emit()
		if event.keycode in [KEY_ESCAPE, KEY_I]: get_viewport().set_input_as_handled()
		return
	# 地图打开时只把 Esc 交给地图；I 和选材快捷键不能操作被覆盖的调查页。
	if map_page.visible:
		if event.keycode == KEY_ESCAPE: map_page.close()
		if event.keycode in [KEY_ESCAPE, KEY_I]: get_viewport().set_input_as_handled()
		return
	if narrative_page.visible:
		if event.keycode == KEY_ESCAPE and not narrative_page.handle_escape(): menu_requested.emit()
		if event.keycode in [KEY_ESCAPE, KEY_I]: get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_I:
		toggle_inspection()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE:
		handle_escape()
		get_viewport().set_input_as_handled()
	elif not reader.visible and not inspection_reader.visible and not _review_open() and selection.handle_card_key(event):
		get_viewport().set_input_as_handled()

# ---------- 目标导航 ----------

func _review_open() -> bool:
	return objectives != null and objectives.review_state == "open"

func _objective_allowed() -> bool:
	# 目标只在调查画面上显示；阅读、选材、结果反馈、暂停与回顾期间都不显示，也不计时。
	return objectives != null and input_enabled and not service.state.is_empty() and service.state.mode == "investigation" \
		and not service.presenting and not service.processing and not reader.visible and not inspection_reader.visible \
		and not feedback.visible and not _review_open() and not map_page.visible and not narrative_page.visible and not cat_page.visible

func _sync_objective() -> void:
	if objectives == null: return
	objectives.set_display_allowed(_objective_allowed())
	_update_reserve()

func _update_reserve() -> void:
	# 展开的目标面板占用右侧区域时，调查页让出同样宽度；收起或隐藏后恢复。
	var reserve := int(ceil(objective_hud.reserved_width())) if objective_hud.visible else 0
	var right := maxi(MARGIN_BASE, reserve)
	if margin.get_theme_constant("margin_right") != right:
		margin.add_theme_constant_override("margin_right", right)

func _open_review() -> void:
	if objectives == null or not _objective_allowed(): return
	var owner_control := get_viewport().gui_get_focus_owner()
	review_focus = weakref(owner_control) if owner_control != null else null
	objectives.request_review()

func _on_review_state(state: String) -> void:
	# 回顾打开期间隐藏调查页，Tab 不会越过回顾走到背后的按钮；关闭后恢复刷新与焦点。
	_sync_modal_visibility()
	_sync_objective()
	if state == "closed":
		_queue_refresh()
		call_deferred("_restore_review_focus")

func _restore_review_focus() -> void:
	# 归还检视占用也会让调查服务排队重建热点；等这些刷新结束后再还焦点，
	# 避免刚还给回顾入口的焦点被旧热点的恢复逻辑覆盖。
	await get_tree().process_frame
	if not is_inside_tree() or _review_open() or not input_enabled: return
	# 优先回到打开回顾前的控件；它已不存在或不可见（如前往入口后进入对白）时，
	# 只在没有焦点时回到目标面板的回顾入口，不抢走新界面自己设置的焦点。
	var previous = review_focus.get_ref() if review_focus != null else null
	review_focus = null
	if previous is Control and previous.is_visible_in_tree() and previous.focus_mode != Control.FOCUS_NONE:
		previous.grab_focus()
		return
	var owner_control := get_viewport().gui_get_focus_owner()
	if owner_control != null and owner_control.is_visible_in_tree(): return
	if objective_hud.visible and objective_hud.review_button.is_visible_in_tree():
		objective_hud.review_button.grab_focus()
