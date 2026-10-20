extends Control
## 页面容器只连接各页面公开接口与可见状态；每页的控件和交互由自己的脚本维护。
const ScenePage = preload("res://pages/aurora/aurora_scene_page.gd")
const CardPage = preload("res://pages/aurora/aurora_card_page.gd")
const ReaderPage = preload("res://pages/aurora/aurora_handbook_page.gd")
const NarrativePage = preload("res://pages/narrative/narrative_page.gd")
const MapPage = preload("res://pages/map_navigation/map_navigation_page.gd")
const ObjectivePage = preload("res://pages/objective/objective_review_page.gd")
const ObjectiveHUD = preload("res://pages/objective/objective_hud_page.gd")
const ObjectiveService = preload("res://systems/objective/objective_service.gd")
const ObjectiveProvider = preload("res://systems/aurora/aurora_objective_provider.gd")
const CatPage = preload("res://pages/aurora/aurora_cat_page.gd")
const ResultEffect = preload("res://pages/aurora/aurora_result_effect.gd")
const EndingPage = preload("res://pages/aurora/aurora_ending_page.gd")
const ContextPresentPage = preload("res://pages/aurora/aurora_context_present_page.gd")
const TutorialService = preload("res://systems/aurora/aurora_tutorial.gd")
const TutorialPage = preload("res://pages/aurora/aurora_tutorial_page.gd")
const CardAudio = preload("res://systems/aurora/aurora_card_audio.gd")
const AcquisitionFeedback = preload("res://pages/aurora/aurora_acquisition_feedback.gd")
signal menu_requested
signal ending_completed
var session: Node
var scene_page: Control
var card_page: Control
var reader_page: Control
var narrative_page: Control
var map_page: Control
var objective_page: Control
var objective_hud: Control
var objectives: Node
var objective_provider: RefCounted
var cat_page: Control
var active := false
var handbook_overlay := false
var queued := false
var result_effect: Control
var ending_page: Control
var context_present_page: Control
var tutorial: Node
var tutorial_page: Control
var card_audio: Node
var acquisition_feedback: Control
var previous_mode := ""
var tool_kind := ""
var tool_views := {}

func bind(value: Node, map_service: Node) -> void:
	session = value
	scene_page = _page(ScenePage, "InvestigationPage")
	card_page = _page(CardPage, "CardPage")
	narrative_page = _page(NarrativePage, "NarrativePage")
	narrative_page.shared_tools_managed = true
	objective_page = _page(ObjectivePage, "ObjectivePage")
	objective_page.shared_tools_managed = true
	objective_hud = _page(ObjectiveHUD, "ObjectiveHUD")
	map_page = _page(MapPage, "MapPage")
	cat_page = _page(CatPage, "CatPage")
	reader_page = _page(ReaderPage, "HandbookPage")
	# 手册是全局模态工具，必须盖在对白页内部的舞台/对话框之上。
	# 对话页使用独立逻辑画布（z_index=20），仅依靠兄弟节点顺序无法保证
	# 后打开的手册可见，因此给手册容器明确的最高层级。
	# 关闭相对层级后，手册的层级直接相对于当前画布计算，不会被对白页
	# 或其他页面容器的局部 z_index 抵消。
	reader_page.z_as_relative = false
	reader_page.z_index = 1000
	ending_page = _page(EndingPage, "EndingPage")
	ending_page.bind(session)
	ending_page.menu_requested.connect(menu_requested.emit)
	ending_page.completed.connect(ending_completed.emit)
	result_effect = _page(ResultEffect, "ResultEffect")
	result_effect.bind(session)
	result_effect.menu_requested.connect(menu_requested.emit)
	result_effect.media_requested.connect(session.media_requested.emit)
	card_audio = CardAudio.new()
	add_child(card_audio)
	card_audio.bind(session)
	card_audio.media_requested.connect(session.media_requested.emit)
	context_present_page = _page(ContextPresentPage, "ContextPresentationPage")
	context_present_page.bind(session)
	context_present_page.closed.connect(refresh)
	for page in [scene_page, card_page, reader_page, cat_page]: page.bind(session)
	objectives = ObjectiveService.new()
	add_child(objectives)
	objectives.configure(session.config.objective_definition())
	objectives.text_source = session.config.text
	objective_provider = ObjectiveProvider.new()
	objective_provider.bind(session)
	objectives.bind_provider(objective_provider)
	objective_hud.bind(objectives)
	objective_page.bind(objectives)
	objective_hud.review_requested.connect(open_objectives)
	objectives.review_state_changed.connect(_review_changed)
	# 机位按钮与目标HUD共享右侧区域：HUD展开/收起时调查页同步重排机位按钮避让。
	scene_page.hud_reserve = Callable(objective_hud, "reserved_width")
	objectives.changed.connect(scene_page.refresh)
	objectives.refresh("initial")
	narrative_page.bind(session.narrative)
	map_page.bind(map_service)
	map_page.closed.connect(session.arrive)
	map_page.visibility_changed.connect(refresh)
	cat_page.visibility_changed.connect(refresh)
	scene_page.context_changed.connect(refresh)
	scene_page.menu_requested.connect(menu_requested.emit)
	scene_page.handbook_requested.connect(open_handbook)
	scene_page.records_requested.connect(open_records)
	scene_page.material_presentation_requested.connect(context_present_page.open_for_actor)
	scene_page.map_requested.connect(_open_map)
	scene_page.objectives_requested.connect(open_objectives)
	scene_page.cat_requested.connect(cat_page.open)
	card_page.menu_requested.connect(menu_requested.emit)
	card_page.handbook_requested.connect(open_handbook)
	card_page.log_requested.connect(open_records)
	card_page.action_requested.connect(card_audio.trigger)
	card_page.material_requested.connect(_open_content)
	cat_page.menu_requested.connect(menu_requested.emit)
	cat_page.closed.connect(refresh)
	narrative_page.menu_requested.connect(menu_requested.emit)
	narrative_page.handbook_requested.connect(open_handbook)
	narrative_page.records_requested.connect(open_records)
	narrative_page.inspection_close_requested.connect(session.cancel_inspection)
	reader_page.closed.connect(_reader_closed)
	reader_page.content_selected.connect(session.select_content)
	session.changed.connect(refresh)
	session.narrative.changed.connect(refresh)
	session.page_snapshot_provider = _export_pages
	acquisition_feedback = _page(AcquisitionFeedback, "AcquisitionFeedback")
	acquisition_feedback.bind(session)
	acquisition_feedback.media_requested.connect(session.media_requested.emit)
	for modal in [objective_page, cat_page, context_present_page]:
		modal.visibility_changed.connect(func():
			if modal.visible: acquisition_feedback.cancel())
	# 引导观察真实页面及状态，覆盖层最后添加，以便先过滤非法输入。
	tutorial = TutorialService.new()
	add_child(tutorial)
	tutorial_page = _page(TutorialPage, "JointTutorial")
	tutorial_page.bind(tutorial)
	tutorial.bind(session, self, map_service)
	refresh()

func _page(script: Script, label: String) -> Control:
	var page: Control = script.new()
	page.name = label
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(page)
	page.hide()
	return page

func refresh() -> void:
	if queued: return
	queued = true
	call_deferred("_refresh")

func _refresh() -> void:
	queued = false
	if session == null: return
	if previous_mode != session.mode:
		card_audio.leave_page()
		previous_mode = str(session.mode)
	scene_page.visible = session.mode in ["investigation", "cat"]
	card_page.visible = session.mode in ["selection", "result", "failure"]
	narrative_page.visible = session.mode == "narrative"
	narrative_page.set_inspection_close_available(session.can_cancel_inspection())
	if reader_page.visible: reader_page.set_compact_mode(session.mode in ["selection", "result", "failure"])
	if session.mode == "material" and tool_kind.is_empty() and (not reader_page.visible or reader_page.reading_content != str(session.reader.content)): reader_page.open_content(str(session.reader.content), true)
	elif not handbook_overlay: reader_page.hide()
	if card_page.visible: card_page.refresh()
	if scene_page.visible: scene_page.refresh()
	objectives.set_display_allowed(active and session.mode == "investigation" and not scene_page.has_context() and not handbook_overlay and not map_page.visible and not cat_page.visible)
	if session.mode == "credits": ending_page.open()
	else: ending_page.hide()

func set_active(value: bool) -> void:
	active = value
	if session == null: return
	session.paused = not value
	if not value and is_instance_valid(acquisition_feedback): acquisition_feedback.cancel()
	session.activity_enabled = value
	objectives.set_paused(not value)
	visible = value
	process_mode = Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED

func set_preferences(values: Dictionary) -> void:
	if is_instance_valid(card_page): card_page.set_preferences(values)
	if is_instance_valid(tutorial_page): tutorial_page.set_preferences(values)
	if is_instance_valid(result_effect): result_effect.set_preferences(values)
	if is_instance_valid(cat_page): cat_page.set_preferences(values)
	if is_instance_valid(map_page): map_page.set_preferences(values)
	if is_instance_valid(narrative_page): narrative_page.set_preferences(values)
	if is_instance_valid(card_audio): card_audio.set_preferences(values)
	if is_instance_valid(acquisition_feedback): acquisition_feedback.set_preferences(values)
	# 主显示容器已经应用有效区域，调查页以该区域为客户端，避免再次缩窄。
	var local_values := values.duplicate()
	local_values["aspect_ratio"] = 0
	if is_instance_valid(scene_page): scene_page.set_preferences(local_values)
	if objectives != null: objectives.set_reduce_motion(bool(values.get("reduce_motion", false)))

func open_handbook() -> void:
	if not _prepare_tool("handbook"): return
	reader_page.set_compact_mode(session.mode in ["selection", "result", "failure"])
	if tool_views.has("handbook"): reader_page.restore_view(tool_views.handbook)
	else:
		reader_page.tab = "materials"
		reader_page.open_library()
	refresh()

func open_records() -> void:
	if not _prepare_tool("records"): return
	reader_page.set_compact_mode(false)
	if tool_views.has("records"): reader_page.restore_view(tool_views.records)
	else: reader_page.open_records()
	refresh()

func open_objectives() -> void:
	if not _prepare_tool("objectives"): return
	if objectives.review_state == "open": objective_page.show()
	elif objectives.request_review() != "opened": _finish_tool()
	refresh()

func _tools_allowed() -> bool:
	if not active or session.processing or session.mode not in ["investigation", "selection", "narrative", "result", "failure", "material"]: return false
	if cat_page.visible or context_present_page.visible or result_effect.active: return false
	if is_instance_valid(narrative_page.cutin) and narrative_page.cutin.is_blocking(): return false
	if map_page.visible and map_page.service.state.get("phase", "") not in ["browsing", "failure"]: return false
	return true

func _prepare_tool(kind: String) -> bool:
	if not _tools_allowed(): return false
	if tool_kind in ["handbook", "records"] and reader_page.visible:
		tool_views[tool_kind] = reader_page.export_view()
		reader_page.hide()
	if objective_page.visible: objective_page.hide() # 同父状态内切工具保留回顾的子页和滚动。
	if map_page.visible:
		map_page.close()
		if map_page.visible: return false
	acquisition_feedback.cancel()
	tool_kind = kind
	handbook_overlay = kind in ["handbook", "records"]
	session.narrative.set_log_open(true)
	return true

func _review_changed(state: String) -> void:
	if state == "closed" and tool_kind == "objectives": _finish_tool()
	refresh()

func _finish_tool() -> void:
	tool_kind = ""
	handbook_overlay = false
	if objectives.review_state == "open": objectives.close_review()
	session.narrative.set_log_open(false)
	# 目标回顾/手册关闭后，对白页可能因 reading_log 提前返回过渲染；
	# 明确恢复舞台并在下一帧重绘，避免快速前往入口后出现黑屏。
	if is_instance_valid(narrative_page) and narrative_page.has_method("resume_after_shared_tool"):
		narrative_page.resume_after_shared_tool()
	refresh()

func _open_content(id: String) -> void:
	if id.is_empty(): return
	if not _prepare_tool("handbook"): return
	reader_page.set_compact_mode(session.mode in ["selection", "result", "failure"])
	reader_page.open_content(id, false, session.mode == "selection" and not objective_page.visible)

func _reader_closed() -> void:
	if tool_kind in ["handbook", "records"]:
		var view: Dictionary = reader_page.export_view()
		view.visible = true
		tool_views[tool_kind] = view
	_finish_tool()

func _open_map() -> void:
	if session.mode != "investigation" or scene_page.has_context() or not _tools_allowed(): return
	if tool_kind in ["handbook", "records"] and reader_page.visible:
		tool_views[tool_kind] = reader_page.export_view()
		reader_page.hide()
	if objectives.review_state == "open": objectives.close_review()
	tool_kind = ""
	handbook_overlay = false
	session.narrative.set_log_open(false)
	acquisition_feedback.cancel()
	map_page.open()

func reset_page() -> void:
	handbook_overlay = false
	tool_kind = ""
	tool_views.clear()
	result_effect.stop(false)
	ending_page.reset_page()
	cat_page.discard()
	reader_page.reset_session()
	card_page.reset_session()
	card_audio.reset()
	acquisition_feedback.reset()
	previous_mode = str(session.mode)
	for page in [reader_page, objective_page, cat_page, map_page, context_present_page]: page.hide()
	narrative_page.reset_stage()
	scene_page.current_context = session.return_context.duplicate(true) if session.return_context.get("kind") in ["topics", "inspection", "scene_items", "reasoning"] else {}
	if not session.page_snapshot.is_empty():
		reader_page.set_compact_mode(session.mode in ["selection", "result", "failure"])
		reader_page.restore_view(session.page_snapshot.get("reader", {}))
		handbook_overlay = reader_page.visible and session.mode != "material"
		if handbook_overlay: tool_kind = "records" if reader_page.tab == "records" else "handbook"
	session.narrative.set_log_open(handbook_overlay)
	objectives.reset()
	objectives.refresh("restore")
	refresh()

func _export_pages() -> Dictionary:
	return {"reader": reader_page.export_view()}

func can_save() -> bool:
	# 选材页允许保存稳定草稿；材料详情是临时阅读层，交给卡牌页拒绝写盘。
	var card_ready := true
	if session.mode == "selection" and card_page != null and card_page.has_method("can_save"):
		card_ready = bool(card_page.can_save())
	return session.can_save() and card_ready and tutorial.feedback_left <= 0 and not handbook_overlay and not objective_page.visible and not cat_page.visible and not context_present_page.visible and scene_page.current_context.get("kind", "scene") not in ["inspection", "topics", "scene_items"]

func can_pause() -> bool:
	# 数据写入是同步事务，纯视觉演出可以暂停并原位继续。
	return not session.processing or result_effect.active

func handle_window_focus_loss() -> void:
	if active:
		session.narrative.stop_fast_read()
		menu_requested.emit()

func _input(event: InputEvent) -> void:
	# 工具键由容器统一分发，页面只处理自己的推进、选择和返回。
	if not active or not is_visible_in_tree(): return
	# 引导遮罩使用 _input 过滤真实点击；页面自身不能在同一事件上先行吞掉它。
	if event is InputEventMouse and is_instance_valid(tutorial):
		if not tutorial.input_allowed(event):
			get_viewport().set_input_as_handled()
			return
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode not in [KEY_I, KEY_L, KEY_J, KEY_M]: return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return
	if not _tools_allowed(): get_viewport().set_input_as_handled(); return
	if event.keycode == KEY_I:
		if tool_kind == "handbook" and reader_page.visible: reader_page.close_page()
		else: open_handbook()
	elif event.keycode == KEY_L:
		if tool_kind == "records" and reader_page.visible: reader_page.close_page()
		else: open_records()
	elif event.keycode == KEY_J:
		if tool_kind == "objectives" and objective_page.visible: objectives.close_review()
		else: open_objectives()
	elif event.keycode == KEY_M:
		if map_page.visible: map_page.close()
		else: _open_map()
	get_viewport().set_input_as_handled()

func _unhandled_key_input(event: InputEvent) -> void:
	if not active or not event is InputEventKey or not event.pressed or event.echo: return
	if get_viewport().gui_get_focus_owner() is LineEdit and event.keycode != KEY_ESCAPE: return
	if event.keycode == KEY_Q:
		if not handbook_overlay and not objective_page.visible and not map_page.visible and not context_present_page.visible and card_page.visible: card_page.toggle_library()
	elif event.keycode == KEY_BACKSPACE:
		if reader_page.visible: reader_page.handle_escape()
		elif objective_page.visible: objective_page.handle_escape()
		elif context_present_page.visible: context_present_page.handle_escape()
		elif map_page.visible: map_page.close()
		elif card_page.visible: card_page.handle_back()
		elif scene_page.visible: scene_page.handle_escape()
	elif event.keycode == KEY_ESCAPE:
		if context_present_page.handle_escape(): pass
		elif reader_page.handle_escape(): pass
		elif objective_page.visible: objectives.close_review()
		elif map_page.visible: map_page.close()
		elif narrative_page.visible and narrative_page.handle_escape(): pass
		elif narrative_page.visible and session.can_cancel_inspection(): session.cancel_inspection()
		elif card_page.visible and card_page.handle_escape(): pass
		elif scene_page.visible and scene_page.handle_escape(): pass
		else: menu_requested.emit()
	else: return
	get_viewport().set_input_as_handled()
