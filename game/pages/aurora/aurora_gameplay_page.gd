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

func bind(value: Node, map_service: Node) -> void:
	session = value
	scene_page = _page(ScenePage, "InvestigationPage")
	card_page = _page(CardPage, "CardPage")
	narrative_page = _page(NarrativePage, "NarrativePage")
	objective_page = _page(ObjectivePage, "ObjectivePage")
	objective_hud = _page(ObjectiveHUD, "ObjectiveHUD")
	map_page = _page(MapPage, "MapPage")
	cat_page = _page(CatPage, "CatPage")
	reader_page = _page(ReaderPage, "HandbookPage")
	ending_page = _page(EndingPage, "EndingPage")
	ending_page.bind(session)
	ending_page.menu_requested.connect(menu_requested.emit)
	ending_page.completed.connect(ending_completed.emit)
	result_effect = _page(ResultEffect, "ResultEffect")
	result_effect.bind(session)
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
	objective_hud.review_requested.connect(objectives.request_review)
	objectives.review_state_changed.connect(func(_state): refresh())
	objectives.refresh("initial")
	narrative_page.bind(session.narrative)
	map_page.bind(map_service)
	map_page.closed.connect(session.arrive)
	map_page.visibility_changed.connect(refresh)
	cat_page.visibility_changed.connect(refresh)
	scene_page.context_changed.connect(refresh)
	scene_page.menu_requested.connect(menu_requested.emit)
	scene_page.handbook_requested.connect(open_handbook)
	scene_page.map_requested.connect(map_page.open)
	scene_page.objectives_requested.connect(objectives.request_review)
	scene_page.cat_requested.connect(cat_page.open)
	card_page.menu_requested.connect(menu_requested.emit)
	card_page.handbook_requested.connect(open_handbook)
	card_page.material_requested.connect(_open_content)
	cat_page.menu_requested.connect(menu_requested.emit)
	cat_page.closed.connect(refresh)
	narrative_page.menu_requested.connect(menu_requested.emit)
	reader_page.closed.connect(_reader_closed)
	reader_page.content_selected.connect(session.select_content)
	session.changed.connect(refresh)
	session.narrative.changed.connect(refresh)
	session.page_snapshot_provider = _export_pages
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
	scene_page.visible = session.mode in ["investigation", "cat"]
	card_page.visible = session.mode in ["selection", "result", "failure"]
	narrative_page.visible = session.mode == "narrative"
	if session.mode == "material" and (not reader_page.visible or reader_page.reading_content != str(session.reader.content)): reader_page.open_content(str(session.reader.content), true)
	elif not handbook_overlay: reader_page.hide()
	if card_page.visible: card_page.refresh()
	if scene_page.visible: scene_page.refresh()
	objectives.set_display_allowed(active and session.mode == "investigation" and scene_page.current_context.is_empty() and not handbook_overlay and not map_page.visible and not cat_page.visible)
	if session.mode == "credits": ending_page.open()
	else: ending_page.hide()

func set_active(value: bool) -> void:
	active = value
	if session == null: return
	session.paused = not value
	session.activity_enabled = value
	objectives.set_paused(not value)
	visible = value
	process_mode = Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED

func set_preferences(values: Dictionary) -> void:
	if is_instance_valid(result_effect): result_effect.set_preferences(values)
	if is_instance_valid(cat_page): cat_page.set_preferences(values)
	if is_instance_valid(map_page): map_page.set_preferences(values)
	if is_instance_valid(narrative_page.stage): narrative_page.stage.reduced = bool(values.get("reduce_motion", false))
	if objectives != null: objectives.set_reduce_motion(bool(values.get("reduce_motion", false)))

func open_handbook() -> void:
	if session.processing or session.mode == "cat" or objective_page.visible: return
	handbook_overlay = true
	session.narrative.set_log_open(true)
	reader_page.open_library()
	refresh()

func _open_content(id: String) -> void:
	if id.is_empty(): return
	handbook_overlay = true
	session.narrative.set_log_open(true)
	reader_page.open_content(id, false, session.mode == "selection" and not objective_page.visible)

func _reader_closed() -> void:
	handbook_overlay = false
	session.narrative.set_log_open(false)
	refresh()

func reset_page() -> void:
	handbook_overlay = false
	result_effect.stop()
	ending_page.reset_page()
	cat_page.discard()
	reader_page.reset_session()
	card_page.reset_session()
	for page in [reader_page, objective_page, cat_page, map_page]: page.hide()
	narrative_page.reset_stage()
	scene_page.current_context = session.return_context.duplicate(true) if session.return_context.get("kind") in ["topics", "inspection", "scene_items", "reasoning"] else {}
	if not session.page_snapshot.is_empty():
		reader_page.restore_view(session.page_snapshot.get("reader", {}))
		handbook_overlay = reader_page.visible and session.mode != "material"
	objectives.reset()
	objectives.refresh("restore")
	refresh()

func _export_pages() -> Dictionary:
	return {"reader": reader_page.export_view()}

func can_save() -> bool:
	return session.can_save() and not handbook_overlay and not objective_page.visible and not cat_page.visible and scene_page.current_context.get("kind", "scene") not in ["inspection", "topics", "scene_items"]

func handle_window_focus_loss() -> void:
	if active:
		session.narrative.stop_fast_read()
		menu_requested.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if not active or not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_I:
		if objective_page.visible or map_page.visible: get_viewport().set_input_as_handled(); return
		if reader_page.visible: reader_page.close_page()
		else: open_handbook()
	elif event.keycode == KEY_ESCAPE:
		if reader_page.handle_escape(): pass
		elif objective_page.visible: objectives.close_review()
		elif map_page.visible: map_page.close()
		elif narrative_page.visible and narrative_page.handle_escape(): pass
		elif card_page.visible and card_page.handle_escape(): pass
		elif scene_page.visible and scene_page.handle_escape(): pass
		else: menu_requested.emit()
	else: return
	get_viewport().set_input_as_handled()
