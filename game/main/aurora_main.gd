extends Control
## 正式入口只创建服务、连接信号和调度页面。剧情、玩法和控件私有逻辑分别在所属模块。
const SessionScript = preload("res://systems/aurora/aurora_session.gd")
const SettingsScript = preload("res://systems/game_settings/settings_service.gd")
const SaveScript = preload("res://systems/save_load/save_load_service.gd")
const AudioScript = preload("res://systems/audio/audio_service.gd")
const MapScript = preload("res://systems/map_navigation/map_navigation_service.gd")
const MapBridge = preload("res://systems/aurora/aurora_map_bridge.gd")
const DebugConsole = preload("res://systems/debug_console/debug_console.gd")
@onready var title_page: Control = $TitlePage
@onready var pause_page: Control = $PausePage
@onready var save_page: Control = $SavePage
@onready var load_page: Control = $LoadPage
@onready var settings_page: Control = $SettingsPage
@onready var confirm_page: Control = $ConfirmPage
@onready var gameplay_page: Control = $GameplayPage
var session: Node
var settings_service: Node
var save_service: Node
var audio_service: Node
var map_service: Node
var map_bridge: Node
var debug_console: CanvasLayer
var current_layer := "title"
var subpage_origin := "title"
var confirmation_action := ""
var pending_leave := ""
var pending_load := false
@export var test_storage_path := ""

func _ready() -> void:
	session = SessionScript.new()
	settings_service = SettingsScript.new()
	save_service = SaveScript.new()
	audio_service = AudioScript.new()
	map_service = MapScript.new()
	map_bridge = MapBridge.new()
	for service in [session, settings_service, save_service, audio_service, map_bridge, map_service]: add_child(service)
	if not test_storage_path.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(test_storage_path))
		save_service.storage_path = test_storage_path.path_join("saves")
		settings_service.storage_path = test_storage_path.path_join("settings.json")
		session.seen_storage_path = test_storage_path.path_join("seen.json")
	else: save_service.storage_path = "user://aurora_saves"
	if not session.initialize():
		title_page.show_configuration_error(session.config.errors)
		title_page.exit_requested.connect(get_tree().quit)
		return
	settings_service.configure_defaults(session.config.rows("settings", "设置初值")[0])
	save_service.configure(session.config.rows("save", "存档总控")[0])
	save_service.snapshot_validator = session.validate_snapshot
	if not audio_service.setup_package(session.config):
		title_page.show_configuration_error(audio_service.config_errors)
		return
	audio_service.attach_ui_hook(get_tree())
	map_bridge.bind(session)
	map_service.bind_core(map_bridge)
	map_service.configure(map_bridge.definition())
	map_service.initialize("SC01")
	gameplay_page.bind(session, map_service)
	title_page.apply_story_title("极光")
	title_page.apply_navigation(session.config.rows("start", "导航按钮"), session.config.text)
	pause_page.apply_navigation(session.config.rows("start", "导航按钮"), session.config.text)
	for page in [title_page, pause_page, settings_page]: page.set_developer_tools_enabled(false)
	settings_service.changed.connect(gameplay_page.set_preferences)
	settings_service.changed.connect(audio_service.apply_settings)
	session.music_requested.connect(audio_service.set_narrative_soundscape)
	session.media_requested.connect(audio_service.request_media)
	map_service.media_requested.connect(audio_service.request_media)
	session.save_writer = save_service.save_auto
	session.media_snapshot_provider = func(): return audio_service.export_narrative_media(session.last_bgm)
	session.ending_checkpoint_requested.connect(_save_ending)
	session.initial_save_completed.connect(save_service.clear_previous_run_protection)
	save_service.processing_changed.connect(func(value): session.processing = value)
	gameplay_page.menu_requested.connect(_open_pause)
	gameplay_page.ending_completed.connect(_show_title)
	title_page.new_game_requested.connect(_request_new_game)
	title_page.continue_requested.connect(_continue)
	title_page.load_requested.connect(_open_load)
	title_page.settings_requested.connect(_open_settings)
	title_page.exit_requested.connect(_request_exit.bind("title"))
	pause_page.resume_requested.connect(_resume)
	pause_page.save_requested.connect(_open_save)
	pause_page.load_requested.connect(_open_load)
	pause_page.settings_requested.connect(_open_settings)
	pause_page.return_title_requested.connect(_request_exit.bind("return_title"))
	pause_page.exit_requested.connect(_request_exit.bind("exit"))
	save_page.bind_session(session)
	save_page.eligibility = _can_save
	save_page.closed.connect(_close_subpage)
	save_page.saved.connect(_saved)
	load_page.closed.connect(_close_subpage)
	load_page.loaded.connect(_loaded)
	load_page.save_first_requested.connect(_save_first)
	settings_page.closed.connect(_close_subpage)
	confirm_page.cancelled.connect(_cancel_confirm)
	confirm_page.accepted.connect(_accept_confirm)
	confirm_page.direct_requested.connect(_direct_leave)
	settings_service.initialize()
	audio_service.apply_settings(settings_service.values)
	gameplay_page.set_preferences(settings_service.values)
	get_window().min_size = Vector2i(1100, 720)
	get_tree().auto_accept_quit = false
	get_window().close_requested.connect(_window_close)
	get_window().focus_exited.connect(gameplay_page.handle_window_focus_loss)
	get_window().focus_exited.connect(audio_service.notify_window_focus.bind(false))
	get_window().focus_entered.connect(audio_service.notify_window_focus.bind(true))
	# 测试用调试控制台：最后加入场景树，任何界面按 ~ 键都由它先收到。
	debug_console = DebugConsole.new()
	add_child(debug_console)
	debug_console.bind(self)
	_show_title()

func _show_title() -> void:
	current_layer = "title"
	gameplay_page.set_active(false)
	pause_page.hide_page()
	for page in [save_page, load_page, settings_page, confirm_page]: page.close_page()
	save_service.scan()
	title_page.apply_latest_summary(save_service.latest_summary())
	title_page.apply_scan_result(save_service.has_valid_record())
	title_page.show_page()
	audio_service.set_menu_open(false)
	audio_service.set_soundscape("title")

func _save_ending() -> bool:
	var ok: bool = bool(save_service.save_ending(session.export_snapshot()))
	if not ok: session._notice("结局续播保存失败，当前播放保留，可在离开确认中重试。")
	return ok

func _request_new_game() -> void:
	confirmation_action = "new_game"
	current_layer = "confirm"
	title_page.hide_page()
	confirm_page.open("新游戏", "开始新的调查？保留手动存档，进入首个自由调查节点后更新自动档。", "", "开始", false, true)

func _accept_confirm() -> void:
	if confirmation_action == "new_game":
		if not session.new_game(): confirm_page.show_error("开场必需内容未就绪。请修正后重试。"); return
		confirm_page.close_page()
		gameplay_page.reset_page()
		audio_service.begin_session()
		_resume()
	elif confirmation_action == "title": get_tree().quit()
	elif session.case_state.data.ending_started and not session.case_state.data.ending_completed:
		if _save_ending(): confirm_page.close_page(); _direct_leave()
		else: confirm_page.show_error("结局续播保存失败，请重试或取消返回播放。")
	elif _can_save():
		pending_leave = confirmation_action
		confirm_page.close_page()
		_open_save()

func _continue() -> void:
	var snapshot: Dictionary = save_service.load_latest()
	if not snapshot.is_empty(): _loaded(snapshot)

func _loaded(snapshot: Dictionary) -> void:
	if not session.restore_snapshot(snapshot): load_page.show_restore_failure(); return
	if snapshot.get("ending_status", "") == "": save_service.abandon_ending()
	load_page.close_page()
	gameplay_page.reset_page()
	map_service.initialize(str(session.case_state.data.scene))
	audio_service.begin_session()
	if not session.ending_media.is_empty(): audio_service.restore_narrative_media(session.ending_media)
	else: audio_service.set_narrative_soundscape(session.last_bgm, true)
	_resume()

## 调试控制台的换档入口：先收起所有子页面和待办流程，再沿普通读档路径换入快照。
func debug_load_snapshot(snapshot: Dictionary) -> bool:
	if not session.validate_snapshot(snapshot) or not session.prepare_scene(str(snapshot.case_state.scene)): return false
	pending_leave = ""
	pending_load = false
	confirmation_action = ""
	gameplay_page.set_active(false)
	title_page.hide_page()
	pause_page.hide_page()
	for page in [save_page, load_page, settings_page, confirm_page]: page.close_page()
	_loaded(snapshot)
	return current_layer == "game"

func _resume() -> void:
	current_layer = "game"
	title_page.hide_page()
	pause_page.hide_page()
	gameplay_page.set_active(true)
	map_bridge.refresh()
	audio_service.set_menu_open(false)
	session.music_requested.emit(session.last_bgm)
	gameplay_page.refresh()

func _open_pause() -> void:
	if current_layer != "game" or session.processing: return
	current_layer = "pause"
	gameplay_page.set_active(false)
	map_bridge.refresh()
	pause_page.set_save_available(_can_save(), "关闭阅读、回顾、局部查看或完成当前回应后可以保存。")
	pause_page.set_resume_context("继续摸猫" if session.mode == "cat" else "继续调查")
	pause_page.show_page()
	audio_service.set_menu_open(true)

func _open_save() -> void:
	if not _can_save(): return
	subpage_origin = "pause"
	current_layer = "subpage"
	pause_page.hide_page()
	save_page.open(save_service, session.export_snapshot())

func _open_load() -> void:
	subpage_origin = current_layer
	current_layer = "subpage"
	title_page.hide_page()
	pause_page.hide_page()
	load_page.open(save_service, subpage_origin != "title", subpage_origin != "title" and _can_save())

func _open_settings() -> void:
	subpage_origin = current_layer
	current_layer = "subpage"
	title_page.hide_page()
	pause_page.hide_page()
	settings_page.open(settings_service, audio_service, session.config.text)

func _close_subpage() -> void:
	if pending_load:
		pending_load = false
		save_page.close_page()
		load_page.resume_confirmation()
		return
	if not pending_leave.is_empty():
		pending_leave = ""
		save_page.close_page()
		current_layer = "confirm"
		confirm_page.show()
		return
	for page in [save_page, load_page, settings_page]: page.close_page()
	if subpage_origin == "title": _show_title()
	else: current_layer = "pause"; pause_page.show_page()

func _save_first(target: Dictionary) -> void:
	if not _can_save(): return
	pending_load = true
	load_page.hide()
	subpage_origin = "pause"
	current_layer = "subpage"
	pause_page.hide_page()
	var excluded := int(target.slot_index) if target.slot_kind == "manual" else -1
	save_page.open(save_service, session.export_snapshot(), excluded)

func _saved() -> void:
	if pending_load:
		pending_load = false
		save_page.close_page()
		load_page.complete_save_first()
	elif not pending_leave.is_empty():
		confirmation_action = pending_leave
		pending_leave = ""
		_direct_leave()

func _request_exit(action: String) -> void:
	confirmation_action = action
	current_layer = "confirm"
	title_page.hide_page()
	pause_page.hide_page()
	var ending: bool = session.case_state.data.ending_started and not session.case_state.data.ending_completed
	confirm_page.open("返回标题" if action == "return_title" else "退出游戏", save_service.latest_summary(), "直接返回" if action == "return_title" else "直接退出", "确认退出" if action == "title" else ("保存续播并离开" if ending else "选择存档并离开"), action != "title", action == "title" or ending or _can_save())

func _can_save() -> bool:
	return gameplay_page.can_save() and map_service.can_save()

func _cancel_confirm() -> void:
	confirm_page.close_page()
	if confirmation_action in ["title", "new_game"]: _show_title()
	else: current_layer = "pause"; pause_page.show_page()

func _direct_leave() -> void:
	if confirmation_action in ["title", "exit"]: get_tree().quit()
	else: gameplay_page.reset_page(); _show_title()

func _window_close() -> void:
	if save_service.busy or settings_service.busy: return
	if current_layer == "game": _open_pause()
	_request_exit("title" if current_layer == "title" else "exit")

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or event.keycode != KEY_ESCAPE: return
	if current_layer == "pause": _resume()
	elif current_layer == "subpage": _close_subpage()
	elif current_layer == "confirm": _cancel_confirm()
	else: return
	get_viewport().set_input_as_handled()
