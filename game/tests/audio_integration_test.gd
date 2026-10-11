extends SceneTree
## 声音接入回归：Main 创建与连线、标题与场景音景、暂停菜单、失焦两级恢复、读档重建、
## 文件反馈、全局按钮钩子、设置页试听、通用媒体入口与试听配置。
## 只使用公开页面接口、信号与真实鼠标事件；文件写入隔离目录。

const AudioScript = preload("res://systems/audio/audio_service.gd")
const DEMO_CONFIG := "res://tests/fixtures/audio/audio_demo_config.json"
const PULSE_PATH := "res://tests/fixtures/design/basic/test_assets/audio/ex_bgm_pulse.wav"
const CONFIRM_PATH := "res://tests/fixtures/music/mozart_k525.ogg"
const UI_KEYS := ["SFX_UI_CLICK", "SFX_UI_CONFIRM", "SFX_UI_FEEDBACK"]

var scene: Control
var audio: Node
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		print("AUDIO_INTEGRATION_FAIL: " + label)


func approx(a: float, b: float, tolerance := 0.002) -> bool:
	return absf(a - b) <= tolerance


func frames() -> void:
	await process_frame
	await process_frame


func click(button: Button) -> void:
	# 真实鼠标点击：先移动再按下抬起，页面按真实输入路径响应。
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event)
		await process_frame
	await frames()


func path_of(slot: String) -> String:
	return String(audio.track_state(slot).get("path", ""))


func slot_paused(slot: String) -> bool:
	return bool(audio.track_state(slot).get("paused", false))


func _run() -> void:
	root.size = Vector2i(1280, 800) # 与基准视口一致，真实鼠标坐标无需换算。
	scene = load("res://main/main.tscn").instantiate()
	scene.test_storage_path = "user://audio-integration/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await frames()
	audio = scene.audio_service
	test_wiring()
	test_demo_config()
	await test_soundscapes()
	await test_menu_and_focus()
	await test_session_and_media()
	await test_feedback_and_hook()
	await test_settings_preview()
	scene.queue_free()
	scene = null
	audio = null
	await frames()
	await create_timer(0.5).timeout # 等音频线程释放已停止的播放对象，避免退出时误报泄漏。
	if failures.is_empty():
		print("AUDIO_INTEGRATION_PASS: %d checks" % checks)
		quit(0)
	else:
		print("AUDIO_INTEGRATION_FAILED: %d of %d checks" % [failures.size(), checks])
		quit(1)


func test_wiring() -> void:
	check(audio != null and audio.get_parent() == scene, "声音服务由 Main 创建并持有")
	check(audio.catalog != null and audio.config_errors.is_empty(), "正式声音配置加载无错误：" + str(audio.config_errors))
	check(audio.settings_ready, "标题显示前声音已取得设置")
	check(scene.audio_demo and DisplayServer.get_name() == "headless", "试听开关默认开启并在无界面下自动失效")
	check(audio.catalog.soundscapes.is_empty(), "无界面运行不叠加试听音景")
	check(audio.live_track_count("bgm") == 0 and audio.live_track_count("ambient") == 0, "正式音景为 0 行时标题静音")
	check(scene.settings_service.changed.is_connected(audio.apply_settings), "设置变化直通声音服务")
	check(scene.session_service.core.presentation_requested.is_connected(scene._on_presentation), "核心表现接入结果音")
	scene.settings_service.set_value("bgm_volume", 35)
	check(int(audio.settings["bgm_volume"]) == 35, "设置变化即时生效")
	scene.settings_service.set_value("bgm_volume", 70)
	check(scene.confirm_page.accept_button.get_meta("ui_sound", "") == "confirm", "确认按钮使用确认音")
	var before: int = audio.start_counts["result"]
	scene._on_presentation({"kind": "collect"})
	check(audio.start_counts["result"] == before, "未提供声音引用的表现不建立声音")


func test_demo_config() -> void:
	var catalog = audio.catalog
	var ok: bool = catalog.load_file(DEMO_CONFIG, true)
	check(ok and catalog.errors.is_empty(), "试听配置通过校验：" + str(catalog.errors))
	var ready := 0
	var total := 0
	for id in catalog.resources.keys():
		if String(id).begins_with("DEMO_"):
			total += 1
			if catalog.resource_state(String(id))["state"] == catalog.STATE_READY:
				ready += 1
	check(total == 12 and ready == 12, "12 个试听资源文件全部就绪（%d/%d）" % [ready, total])
	check(String(catalog.match_soundscape("title", "", "")["id"]) == "DEMO_TITLE", "标题匹配试听音景")
	check(String(catalog.match_soundscape("scene", "ROOM", "")["id"]) == "DEMO_ROOM", "占位案件场景匹配试听音景")
	check(String(catalog.match_soundscape("scene", "DEMO_SC_VALKYRIE", "LATE")["id"]) == "DEMO_SC_VALKYRIE_LATE", "阶段行优先")
	check(String(catalog.match_soundscape("scene", "DEMO_SC_VALKYRIE", "EARLY")["id"]) == "DEMO_SC_VALKYRIE", "没有对应阶段时回落到通用行")
	var title_key: String = catalog.match_soundscape("title", "", "")["bgm_key"]
	check(catalog.match_soundscape("scene", "DEMO_SC_BACH_A", "")["bgm_key"] == title_key and catalog.match_soundscape("scene", "DEMO_SC_BACH_B", "")["bgm_key"] == title_key, "标题与两个场景共用同一首 BGM")


func test_soundscapes() -> void:
	scene._show_title()
	check(path_of("bgm").ends_with("bach_toccata.ogg"), "标题播放巴赫")
	check(audio.track_state("bgm")["bus"] == "BGM" and audio.track_state("bgm")["loop"], "标题 BGM 在 BGM 总线循环")
	# 同一首 BGM 跨标题与场景延续，不重启；环境层独立加入或停止。
	var bgm_starts: int = audio.start_counts["bgm"]
	var ambient_starts: int = audio.start_counts["ambient"]
	audio.set_soundscape("scene", "DEMO_SC_BACH_A")
	check(audio.start_counts["bgm"] == bgm_starts and audio.start_counts["ambient"] == ambient_starts + 1, "共用 BGM 延续且环境层加入")
	audio.set_soundscape("scene", "DEMO_SC_BACH_B")
	audio.advance(2000.0)
	check(audio.start_counts["bgm"] == bgm_starts and audio.live_track_count("ambient") == 0, "同一首 BGM 仍延续，空环境键淡出后停止")
	# 新调查：进入占位案件场景 ROOM，BGM 交叉淡化，环境层加入。
	var session_before: int = audio.session_id
	scene._on_new_game()
	await process_frame
	check(scene.current_layer == "investigation", "新游戏进入调查")
	check(audio.session_id == session_before + 1, "新调查开始新的声音会话")
	check(String(audio.current_soundscape["id"]) == "DEMO_ROOM", "场景 ROOM 匹配试听音景")
	check(audio.live_track_count("bgm") == 2, "BGM 交叉淡化期间两轨并存")
	audio.advance(2000.0)
	check(audio.live_track_count("bgm") == 1 and audio.live_track_count("ambient") == 1, "淡化结束后各一轨")
	check(path_of("bgm").ends_with("mozart_k525.ogg") and path_of("ambient").ends_with("dies_irae_chant.ogg"), "场景播放莫扎特与圣咏环境层")
	check(approx(audio.effective_linear("bgm"), audio.output_multiplier("bgm")), "BGM 实际输出与公式一致")


func test_menu_and_focus() -> void:
	var base: float = audio.output_multiplier("bgm")
	check(base > 0.0, "调查中 BGM 有输出")
	scene._open_pause()
	check(scene.current_layer == "pause" and audio.menu_open, "暂停菜单同步通知声音")
	check(approx(audio.output_multiplier("bgm"), base * 0.5) and approx(audio.effective_linear("bgm"), base * 0.5), "暂停菜单中 BGM 为 50%")
	check(slot_paused("ambient") and not slot_paused("bgm"), "菜单中环境冻结、BGM 继续")
	scene._on_resume()
	check(not audio.menu_open and approx(audio.output_multiplier("bgm"), base) and not slot_paused("ambient"), "继续调查后倍率与环境恢复")

	# 失焦：窗口信号先冻结声音，随后请求暂停菜单；回焦后等待有效输入。
	scene.get_window().focus_exited.emit()
	await process_frame
	check(audio.focus_state == AudioScript.Focus.FROZEN and slot_paused("bgm") and slot_paused("ambient"), "失焦冻结全部声音")
	if scene.current_layer == "investigation":
		scene._open_pause() # 与玩法页的延迟窗口检查等效。
	check(scene.current_layer == "pause", "失焦后进入暂停菜单")
	check(audio.play_ui("click")["status"] == "frozen", "失焦期间新请求不排队")
	scene.get_window().focus_entered.emit()
	check(audio.focus_state == AudioScript.Focus.AWAITING_INPUT and slot_paused("bgm"), "回焦后等待有效输入")
	# 第一级恢复：在暂停菜单内接受按钮操作，只恢复 BGM 与界面声音。
	scene.pause_page.settings_button.pressed.emit()
	check(audio.focus_state == AudioScript.Focus.UI_RESTORED and not slot_paused("bgm") and slot_paused("ambient"), "菜单内有效输入只恢复 BGM")
	scene._on_close_subpage()
	scene.pause_page.resume_button.pressed.emit()
	check(audio.focus_state == AudioScript.Focus.ACTIVE and not audio.menu_open and not slot_paused("ambient"), "继续调查后完成第二级恢复")

	# 另一种顺序：回焦后直接按 Esc 继续，同次完成两级恢复。
	scene.get_window().focus_exited.emit()
	await process_frame
	if scene.current_layer == "investigation":
		scene._open_pause()
	scene.get_window().focus_entered.emit()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	await frames()
	check(scene.current_layer == "investigation" and audio.focus_state == AudioScript.Focus.ACTIVE and not slot_paused("bgm") and not slot_paused("ambient"), "回焦后 Esc 同次完成两级恢复")


func test_session_and_media() -> void:
	# 结果声沿既有通道播放一次，离开会话时停止。
	var played: Dictionary = audio.play_result("t/1", PULSE_PATH)
	check(played["status"] == "played" and not audio.track_state("result").is_empty(), "结果声播放一次")
	check(audio.play_result("t/1", PULSE_PATH)["status"] == "duplicate", "同一实例只处理一次")
	var results: int = audio.start_counts["result"]
	scene._on_presentation({"kind": "collect", "sound": PULSE_PATH})
	check(audio.start_counts["result"] == results + 1, "表现提供声音引用时沿结果通道发声")
	# 通用媒体入口：任何声明 media_requested 信号的模块都能直接接入。
	var source := Node.new()
	source.add_user_signal("media_requested", [{"name": "request", "type": TYPE_DICTIONARY}])
	scene._wire_media(source)
	results = audio.start_counts["result"]
	source.emit_signal("media_requested", {"event": "SND_NODE_SOUND", "instance": "n/1", "ref": PULSE_PATH, "session": audio.session_id})
	check(audio.start_counts["result"] == results + 1, "媒体请求经 Main 到达声音服务")
	source.emit_signal("media_requested", {"event": "SND_NODE_SOUND", "instance": "n/2", "ref": PULSE_PATH, "session": audio.session_id - 1})
	check(audio.start_counts["result"] == results + 1, "过期会话的媒体请求被拒绝")
	var plain := Node.new()
	scene._wire_media(plain) # 没有该信号的对象被忽略且不报错。
	plain.free()
	source.free()

	# 返回标题：停止节点声音，标题音景恢复，菜单倍率移除。
	scene._open_pause()
	scene._on_return_title()
	scene._on_confirm_direct()
	check(scene.current_layer == "title" and audio.track_state("result").is_empty(), "返回标题停止结果声")
	check(not audio.menu_open and String(audio.current_soundscape["id"]) == "DEMO_TITLE", "返回标题恢复标题音景")
	audio.advance(2000.0)
	check(path_of("bgm").ends_with("bach_toccata.ogg"), "标题 BGM 恢复为巴赫")

	# 继续游戏：读档成功开始新会话，并从头重建 BGM 与环境循环。
	var bgm_starts: int = audio.start_counts["bgm"]
	var ambient_starts: int = audio.start_counts["ambient"]
	var session_before: int = audio.session_id
	scene._on_continue()
	check(scene.current_layer == "investigation" and audio.session_id == session_before + 1, "继续游戏开始新会话")
	check(audio.start_counts["bgm"] == bgm_starts + 1 and audio.start_counts["ambient"] == ambient_starts + 1, "读档后重建 BGM 与环境")
	audio.advance(2000.0)
	check(path_of("bgm").ends_with("mozart_k525.ogg"), "读档后场景 BGM 就位")
	bgm_starts = audio.start_counts["bgm"]
	scene._on_continue()
	check(audio.start_counts["bgm"] == bgm_starts + 1, "同一音景读档仍从头重建")
	audio.advance(2000.0)


func test_feedback_and_hook() -> void:
	for key in UI_KEYS:
		audio.catalog.resources[key]["resource_path"] = CONFIRM_PATH if key == "SFX_UI_CONFIRM" else PULSE_PATH
		check(audio.catalog.resource_state(key)["state"] == audio.catalog.STATE_READY, key + " 绑定后就绪")
	var snapshot: Dictionary = scene.session_service.export_snapshot()
	var ui_starts: int = audio.start_counts["ui"]
	scene._save_auto(snapshot)
	check(audio.start_counts["ui"] == ui_starts, "自动存档静默")
	check(scene.save_service.save_snapshot("manual", 0, snapshot), "手动存档成功")
	check(audio.start_counts["ui"] == ui_starts + 1, "手动存档成功发一次反馈音")
	check(not scene.save_service.save_snapshot("manual", 99, snapshot), "无效栏位存档失败")
	check(audio.start_counts["ui"] == ui_starts + 2, "存档失败也发一次反馈音")

	# 全局按钮钩子：真实点击标题按钮发一次普通点击音。
	scene._on_return_title()
	scene._on_confirm_direct()
	await frames()
	ui_starts = audio.start_counts["ui"]
	await click(scene.title_page.settings_button)
	check(scene.current_layer == "subpage" and audio.start_counts["ui"] == ui_starts + 1, "真实点击标题按钮发一次普通点击音")
	scene._on_close_subpage()
	ui_starts = audio.start_counts["ui"]
	scene.title_page.settings_button.set_meta("ui_sound", "none")
	scene.title_page.settings_button.pressed.emit()
	check(audio.start_counts["ui"] == ui_starts, "meta ui_sound=none 的按钮不发点击音")
	scene.title_page.settings_button.remove_meta("ui_sound")
	scene._on_close_subpage()
	check(path_of("ui") == PULSE_PATH, "普通按钮使用点击音资源")
	# 运行时新增的按钮同样被钩住；meta ui_sound=confirm 使用确认音资源。
	var probe := Button.new()
	probe.set_meta("ui_sound", "confirm")
	scene.add_child(probe)
	ui_starts = audio.start_counts["ui"]
	probe.pressed.emit()
	check(audio.start_counts["ui"] == ui_starts + 1 and path_of("ui") == CONFIRM_PATH, "运行时新增的确认按钮发确认音")
	probe.queue_free()
	await process_frame


func test_settings_preview() -> void:
	scene._on_settings()
	await frames()
	var page = scene.settings_page
	var core = scene.session_service.core
	check(page.visible and not page.preview_button.disabled and not page.preview_reason.visible, "设置页试听按钮可用")
	check(page.preview_button.text == core.ui("UI_SETTINGS_PREVIEW"), "试听按钮文字来自功能文字表")
	var preview_starts: int = audio.start_counts["preview"]
	var ui_starts: int = audio.start_counts["ui"]
	await click(page.preview_button)
	check(audio.start_counts["preview"] == preview_starts + 1, "真实点击试听发一次反馈效果音")
	check(audio.start_counts["ui"] == ui_starts, "试听不叠加普通点击音")
	check(not audio.track_state("preview").is_empty(), "试听播放中")
	# 条件不满足时只禁用试听并给出原因，其余设置保持可用。
	var cases := [
		["mute", true, "UI_SETTINGS_PREVIEW_MUTED"],
		["master_volume", 0, "UI_SETTINGS_PREVIEW_MASTER_ZERO"],
		["effect_volume", 0, "UI_SETTINGS_PREVIEW_EFFECT_ZERO"],
	]
	for item in cases:
		page._set_value(item[1], item[0])
		check(page.preview_button.disabled and page.preview_reason.visible and page.preview_reason.text == core.ui(item[2]), "%s 时禁用试听并说明原因" % item[0])
		scene.settings_service.restore_defaults()
		page._rebuild_controls()
		check(not page.preview_button.disabled and not page.preview_reason.visible, "恢复默认后试听重新可用")
	check(not page.close_button.disabled, "试听不可用时设置页其他控件保持可用")
	scene._on_close_subpage()
	check(audio.track_state("preview").is_empty(), "离开设置页停止试听")
	check(scene.current_layer == "title", "设置页返回标题")
