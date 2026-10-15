extends Control
## Main 只初始化模块、连接公开接口和调度页面；玩法与存档字段交给会话服务。

const SessionScript = preload("res://systems/core_gameplay/game_session_service.gd")
const SettingsScript = preload("res://systems/game_settings/settings_service.gd")
const SaveScript = preload("res://systems/save_load/save_load_service.gd")
const StartScript = preload("res://systems/game_start/game_start_service.gd")
const AudioScript = preload("res://systems/audio/audio_service.gd")
const ObjectiveScript = preload("res://systems/objective/objective_service.gd")
const CaseObjectiveScript = preload("res://systems/objective/case_objective_provider.gd")
const AUDIO_DEMO_CONFIG := "res://tests/fixtures/audio/audio_demo_config.json" # 试听古典乐音景，仅开发运行叠加。
const AUDIO_DEMO_UI := { # 开发运行临时绑定的操作音；正式配置中这三个资源仍未采用素材。
	"SFX_UI_CLICK": "res://tests/fixtures/audio/ui_demo/ui_click.wav",
	"SFX_UI_CONFIRM": "res://tests/fixtures/audio/ui_demo/ui_confirm.wav",
	"SFX_UI_FEEDBACK": "res://tests/fixtures/audio/ui_demo/ui_feedback.wav",
}
@onready var gameplay_page: Control = $CoreGameplayPage
@onready var title_page: Control = $TitlePage
@onready var pause_page: Control = $PausePage
@onready var save_page: Control = $SavePage
@onready var load_page: Control = $LoadPage
@onready var settings_page: Control = $SettingsPage
@onready var sfx_manager_page: Control = $SfxManagerPage
@onready var confirm_page: Control = $ConfirmPage
var session_service: Node
var settings_service: Node
var save_service: Node
var game_start_service: Node
var audio_service: Node
var objective_service: Node
var objective_provider: RefCounted
var current_layer := "title"
var subpage_origin := "title"
var subpage_focus: Button
var confirm_origin := "title"
var confirm_focus: Button
var confirm_exits := false
var has_progress := false
var pending_leave := false
var file_feedback_muted := false # 自动存档静默进行，不发文件反馈音。
var media_serial := 0 # 核心表现声音的实例序号。
@export var test_storage_path := "" # 测试注入独立目录，避免改写玩家存档与设置。
@export var audio_demo := true # 有界面的开发运行叠加试听古典乐音景；无界面回归与导出包自动关闭。
@export_file("*.xlsx") var story_workbook_path := "res://data/story/outputs/story-images-20261011/故事配置表.xlsx" # 场景选择内容表，故事规则仍由核心服务处理。

func _ready() -> void:
	session_service = SessionScript.new()
	settings_service = SettingsScript.new()
	save_service = SaveScript.new()
	game_start_service = StartScript.new()
	audio_service = AudioScript.new()
	objective_service = ObjectiveScript.new()
	for service in [session_service, settings_service, save_service, game_start_service, audio_service, objective_service]: add_child(service)
	if not test_storage_path.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(test_storage_path))
		save_service.storage_path = test_storage_path.path_join("saves")
		settings_service.storage_path = test_storage_path.path_join("settings.json")
	if not session_service.initialize(story_workbook_path):
		push_error("核心配置无效：" + str(session_service.core.catalog.errors))
		gameplay_page.hide()
		title_page.show_configuration_error(session_service.core.catalog.errors)
		title_page.exit_requested.connect(get_tree().quit)
		return
	title_page.apply_story_title(session_service.story_title())
	for page in [title_page, pause_page, save_page, load_page, settings_page, sfx_manager_page, confirm_page]: page.bind_images(session_service.core)
	_setup_audio()
	save_service.snapshot_validator = session_service.validate_snapshot
	session_service.autosave_requested.connect(_save_auto)
	save_service.operation_completed.connect(_on_file_operation)
	_setup_objectives()
	gameplay_page.bind(session_service.core, objective_service)
	gameplay_page.menu_requested.connect(_open_pause)
	session_service.core.presentation_requested.connect(_on_presentation)
	_wire_media(session_service.core)
	settings_service.changed.connect(gameplay_page.set_preferences)
	settings_service.changed.connect(audio_service.apply_settings)
	title_page.continue_requested.connect(_on_continue)
	title_page.new_game_requested.connect(_on_new_game)
	title_page.load_requested.connect(_on_load)
	title_page.settings_requested.connect(_on_settings)
	title_page.sfx_manager_requested.connect(_on_sfx_manager)
	title_page.exit_requested.connect(_on_title_exit)
	pause_page.resume_requested.connect(_on_resume)
	pause_page.save_requested.connect(_on_save)
	pause_page.load_requested.connect(_on_load)
	pause_page.settings_requested.connect(_on_settings)
	pause_page.sfx_manager_requested.connect(_on_sfx_manager)
	pause_page.return_title_requested.connect(_on_return_title)
	pause_page.exit_requested.connect(_on_pause_exit)
	save_page.closed.connect(_on_close_subpage)
	save_page.saved.connect(_on_saved)
	load_page.closed.connect(_on_close_subpage)
	load_page.loaded.connect(_on_loaded)
	settings_page.closed.connect(_on_close_subpage)
	settings_page.sfx_manager_requested.connect(_on_sfx_manager_from_settings)
	sfx_manager_page.closed.connect(_on_close_subpage)
	confirm_page.cancelled.connect(_on_confirm_cancel)
	confirm_page.direct_requested.connect(_on_confirm_direct)
	confirm_page.accepted.connect(_on_confirm_accept)
	game_start_service.ready_for_title.connect(_on_start_ready)
	game_start_service.initialize(settings_service, save_service)
	gameplay_page.set_preferences(settings_service.values)
	get_window().min_size = Vector2i(1100, 720)
	# 先通知声音冻结，再由玩法页请求暂停菜单。
	get_window().focus_exited.connect(audio_service.notify_window_focus.bind(false))
	get_window().focus_entered.connect(audio_service.notify_window_focus.bind(true))
	get_window().focus_exited.connect(gameplay_page.handle_window_focus_loss)
	confirm_page.accept_button.set_meta("ui_sound", "confirm")
	_show_title()

func _setup_audio() -> void:
	# 读取正式声音配置；有界面的开发运行叠加试听古典乐音景，无界面回归与导出包不读取它。
	var extra: Array = []
	var demo: bool = audio_demo and DisplayServer.get_name() != "headless" and FileAccess.file_exists(AUDIO_DEMO_CONFIG)
	if demo:
		extra.append(AUDIO_DEMO_CONFIG)
	if not audio_service.setup(AudioScript.DEFAULT_CONFIG, extra):
		push_warning("声音配置存在问题：" + str(audio_service.config_errors))
	if demo:
		for key in AUDIO_DEMO_UI: # 点击、确认、文件反馈与设置页试听在开发运行中也能听到
			audio_service.bind_resource(key, String(AUDIO_DEMO_UI[key]))
	audio_service.attach_ui_hook(get_tree())

func _setup_objectives() -> void:
	# 目标导航只通过提供方读取案件目标；后续案件模块替换提供方即可，导航与页面无需改动。
	if not objective_service.setup():
		push_warning("目标导航配置缺失，目标显示不可用")
	objective_service.text_source = Callable(session_service.core, "ui")
	objective_provider = CaseObjectiveScript.new()
	objective_provider.bind_core(session_service.core)
	objective_service.bind_provider(objective_provider)

func _wire_media(source: Object) -> void:
	# 玩法、剧情、猫互动、结局等模块只需声明 media_requested(request) 信号，就能在这里接入声音。
	if source.has_signal("media_requested"): source.connect("media_requested", audio_service.request_media)

func _on_presentation(display: Dictionary) -> void:
	# 核心表现的声音沿本次表现发一次；占位案件尚未提供 sound 引用，空引用不建立声音。
	media_serial += 1
	audio_service.play_result("presentation/%d" % media_serial, String(display.get("sound", "")))

func _save_auto(snapshot: Dictionary) -> void:
	# 普通自动存档静默进行，不发文件反馈音。
	file_feedback_muted = true
	save_service.save_auto(snapshot)
	file_feedback_muted = false

func _on_file_operation(_success: bool, _message: String) -> void:
	# 文件反馈：实际提交返回成功或失败时按本次结果发一次；自动存档不发声。
	if not file_feedback_muted: audio_service.play_ui("feedback")

func _show_title() -> void:
	current_layer = "title"
	audio_service.set_menu_open(false)
	audio_service.stop_node_media()
	audio_service.set_soundscape("title")
	for page in [save_page, load_page, settings_page, sfx_manager_page, confirm_page]: page.close_page()
	pause_page.hide_page()
	gameplay_page.set_active(false)
	gameplay_page.hide()
	title_page.apply_latest_summary(save_service.latest_summary())
	title_page.apply_scan_result(save_service.has_valid_record())
	title_page.show_page()

func _start_investigation(rebuild_audio := false) -> void:
	has_progress = true
	current_layer = "investigation"
	# 继续原调查移除菜单倍率；读取调查档成功时按目标音景从头重建循环。
	audio_service.set_menu_open(false)
	audio_service.set_soundscape("scene", String(session_service.core.state.get("current_scene_id", "")), "", rebuild_audio)
	title_page.hide_page()
	pause_page.hide_page()
	gameplay_page.show()
	gameplay_page.set_active(true)

func _on_new_game() -> void:
	gameplay_page.reset_page()
	var snapshot: Dictionary = session_service.start_new_game()
	objective_service.refresh("initial") # 新调查按初始目标建立，不弹更新提示
	audio_service.begin_session()
	_start_investigation()
	_save_auto(snapshot)

func _on_continue() -> void:
	var snapshot: Dictionary = save_service.load_latest()
	if snapshot.is_empty() or not session_service.restore_snapshot(snapshot): return
	gameplay_page.reset_page()
	objective_service.refresh("restore") # 读档成功后按已有进度显示目标，不补播更新提示
	audio_service.begin_session()
	_start_investigation(true)

func _open_pause() -> void:
	if current_layer != "investigation" or not session_service.core.can_menu(): return
	audio_service.notify_valid_input() # 用户操作触发暂停时，先完成失焦后的第一级恢复。
	audio_service.set_menu_open(true)
	current_layer = "pause"
	gameplay_page.set_active(false)
	gameplay_page.hide()
	pause_page.set_save_available(session_service.can_save(), session_service.core.save_disabled_reason())
	pause_page.show_page()

func _on_resume() -> void:
	_start_investigation()

func _on_save() -> void:
	if not session_service.can_save(): return
	subpage_origin = current_layer
	subpage_focus = pause_page.save_button
	current_layer = "subpage"
	pause_page.hide_page()
	save_page.open(save_service, session_service.export_snapshot())

func _on_load() -> void:
	subpage_origin = current_layer
	subpage_focus = title_page.load_button if subpage_origin == "title" else pause_page.load_button
	current_layer = "subpage"
	title_page.hide_page()
	pause_page.hide_page()
	load_page.open(save_service)

func _on_settings() -> void:
	subpage_origin = current_layer
	subpage_focus = title_page.settings_button if subpage_origin == "title" else pause_page.settings_button
	current_layer = "subpage"
	title_page.hide_page()
	pause_page.hide_page()
	settings_page.open(settings_service, audio_service, Callable(session_service.core, "ui"))

func _on_sfx_manager() -> void:
	subpage_origin = current_layer
	subpage_focus = title_page.sfx_button if subpage_origin == "title" else pause_page.sfx_button
	current_layer = "subpage"
	title_page.hide_page()
	pause_page.hide_page()
	sfx_manager_page.open(audio_service, settings_service)

func _on_sfx_manager_from_settings() -> void:
	settings_page.close_page()
	current_layer = "subpage"
	sfx_manager_page.open(audio_service, settings_service)

func _on_start_ready(has_save: bool) -> void:
	# 设置初始化完成后才把已生效的设置交给声音，标题音景随后在 _show_title 播放。
	audio_service.apply_settings(settings_service.values)
	title_page.apply_scan_result(has_save)
	title_page.apply_latest_summary(save_service.latest_summary())

func _on_loaded(snapshot: Dictionary) -> void:
	if not session_service.restore_snapshot(snapshot): return
	pending_leave = false
	load_page.close_page()
	gameplay_page.reset_page()
	objective_service.refresh("restore")
	audio_service.begin_session()
	_start_investigation(true)

func _on_close_subpage() -> void:
	pending_leave = false
	for page in [save_page, load_page, settings_page, sfx_manager_page]: page.close_page()
	if subpage_origin == "title": _show_title()
	else:
		current_layer = "pause"
		pause_page.show_page()
	if is_instance_valid(subpage_focus): subpage_focus.grab_focus()

func _on_saved() -> void:
	if pending_leave:
		pending_leave = false
		_on_confirm_direct()
	else: _on_close_subpage()

func _on_return_title() -> void:
	_open_confirm(false, false)

func _on_pause_exit() -> void:
	_open_confirm(true, false)

func _on_title_exit() -> void:
	_open_confirm(true, true)

func _open_confirm(exits: bool, from_title: bool) -> void:
	confirm_exits = exits
	confirm_origin = current_layer
	confirm_focus = title_page.exit_button if from_title else (pause_page.exit_button if exits else pause_page.return_title_button)
	current_layer = "confirm"
	title_page.hide_page()
	pause_page.hide_page()
	var can_save: bool = not from_title and session_service.can_save()
	var detail: String = ("确认退出游戏？" if exits else "返回标题？") + "\n" + save_service.latest_summary()
	if not from_title and not can_save: detail += "\n" + session_service.core.save_disabled_reason()
	confirm_page.open("退出游戏" if exits else "返回标题", detail, "直接退出" if exits else "直接返回", "确认退出" if from_title else "选择存档并离开", not from_title, from_title or can_save)

func _on_confirm_cancel() -> void:
	confirm_page.close_page()
	if confirm_origin == "title": _show_title()
	else:
		current_layer = "pause"
		pause_page.show_page()
	if is_instance_valid(confirm_focus): confirm_focus.grab_focus()

func _on_confirm_direct() -> void:
	# 直接离开不请求保存，不提交尚未收下或尚未继续的结果。
	if confirm_exits: get_tree().quit()
	else:
		gameplay_page.reset_page()
		_show_title()

func _on_confirm_accept() -> void:
	if not confirm_page.accept_button.visible: return
	if confirm_origin == "title": _on_confirm_direct(); return
	if not session_service.can_save(): return
	confirm_page.close_page()
	pending_leave = true
	subpage_origin = "pause"
	current_layer = "subpage"
	save_page.open(save_service, session_service.export_snapshot())

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or event.keycode != KEY_ESCAPE: return
	if current_layer in ["confirm", "subpage", "pause"]: audio_service.notify_valid_input()
	if current_layer == "confirm": _on_confirm_cancel()
	elif current_layer == "subpage": _on_close_subpage()
	elif current_layer == "pause": _on_resume()
	else: return
	get_viewport().set_input_as_handled()
