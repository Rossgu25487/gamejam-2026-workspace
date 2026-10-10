extends Control
## Main 只初始化模块、连接公开接口和调度页面；玩法与存档字段交给会话服务。

const SessionScript = preload("res://systems/core_gameplay/game_session_service.gd")
const SettingsScript = preload("res://systems/game_settings/settings_service.gd")
const SaveScript = preload("res://systems/save_load/save_load_service.gd")
const StartScript = preload("res://systems/game_start/game_start_service.gd")
@onready var gameplay_page: Control = $CoreGameplayPage
@onready var title_page: Control = $TitlePage
@onready var pause_page: Control = $PausePage
@onready var save_page: Control = $SavePage
@onready var load_page: Control = $LoadPage
@onready var settings_page: Control = $SettingsPage
@onready var confirm_page: Control = $ConfirmPage
var session_service: Node
var settings_service: Node
var save_service: Node
var game_start_service: Node
var current_layer := "title"
var subpage_origin := "title"
var subpage_focus: Button
var confirm_origin := "title"
var confirm_focus: Button
var confirm_exits := false
var has_progress := false
var pending_leave := false
@export var test_storage_path := "" # 测试注入独立目录，避免改写玩家存档与设置。

func _ready() -> void:
	session_service = SessionScript.new()
	settings_service = SettingsScript.new()
	save_service = SaveScript.new()
	game_start_service = StartScript.new()
	for service in [session_service, settings_service, save_service, game_start_service]: add_child(service)
	if not test_storage_path.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(test_storage_path))
		save_service.storage_path = test_storage_path.path_join("saves")
		settings_service.storage_path = test_storage_path.path_join("settings.json")
	if not session_service.initialize():
		push_error("核心配置无效：" + str(session_service.core.catalog.errors))
		return
	save_service.snapshot_validator = session_service.validate_snapshot
	session_service.autosave_requested.connect(save_service.save_auto)
	gameplay_page.bind(session_service.core)
	gameplay_page.menu_requested.connect(_open_pause)
	settings_service.changed.connect(gameplay_page.set_preferences)
	title_page.continue_requested.connect(_on_continue)
	title_page.new_game_requested.connect(_on_new_game)
	title_page.load_requested.connect(_on_load)
	title_page.settings_requested.connect(_on_settings)
	title_page.exit_requested.connect(_on_title_exit)
	pause_page.resume_requested.connect(_on_resume)
	pause_page.save_requested.connect(_on_save)
	pause_page.load_requested.connect(_on_load)
	pause_page.settings_requested.connect(_on_settings)
	pause_page.return_title_requested.connect(_on_return_title)
	pause_page.exit_requested.connect(_on_pause_exit)
	save_page.closed.connect(_on_close_subpage)
	save_page.saved.connect(_on_saved)
	load_page.closed.connect(_on_close_subpage)
	load_page.loaded.connect(_on_loaded)
	settings_page.closed.connect(_on_close_subpage)
	confirm_page.cancelled.connect(_on_confirm_cancel)
	confirm_page.direct_requested.connect(_on_confirm_direct)
	confirm_page.accepted.connect(_on_confirm_accept)
	game_start_service.ready_for_title.connect(_on_start_ready)
	game_start_service.initialize(settings_service, save_service)
	gameplay_page.set_preferences(settings_service.values)
	get_window().min_size = Vector2i(1100, 720)
	get_window().focus_exited.connect(_open_pause)
	_show_title()

func _show_title() -> void:
	current_layer = "title"
	for page in [save_page, load_page, settings_page, confirm_page]: page.close_page()
	pause_page.hide_page()
	gameplay_page.set_active(false)
	gameplay_page.hide()
	title_page.apply_latest_summary(save_service.latest_summary())
	title_page.apply_scan_result(save_service.has_valid_record())
	title_page.show_page()

func _start_investigation() -> void:
	has_progress = true
	current_layer = "investigation"
	title_page.hide_page()
	pause_page.hide_page()
	gameplay_page.show()
	gameplay_page.set_active(true)

func _on_new_game() -> void:
	gameplay_page.reset_page()
	var snapshot: Dictionary = session_service.start_new_game()
	_start_investigation()
	save_service.save_auto(snapshot)

func _on_continue() -> void:
	var snapshot: Dictionary = save_service.load_latest()
	if snapshot.is_empty() or not session_service.restore_snapshot(snapshot): return
	gameplay_page.reset_page()
	_start_investigation()

func _open_pause() -> void:
	if current_layer != "investigation" or not session_service.core.can_menu(): return
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
	settings_page.open(settings_service)

func _on_start_ready(has_save: bool) -> void:
	title_page.apply_scan_result(has_save)
	title_page.apply_latest_summary(save_service.latest_summary())

func _on_loaded(snapshot: Dictionary) -> void:
	if not session_service.restore_snapshot(snapshot): return
	pending_leave = false
	load_page.close_page()
	gameplay_page.reset_page()
	_start_investigation()

func _on_close_subpage() -> void:
	pending_leave = false
	for page in [save_page, load_page, settings_page]: page.close_page()
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
	if current_layer == "confirm": _on_confirm_cancel()
	elif current_layer == "subpage": _on_close_subpage()
	elif current_layer == "pause": _on_resume()
	else: return
	get_viewport().set_input_as_handled()
