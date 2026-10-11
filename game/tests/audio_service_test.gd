extends SceneTree
## 声音播放服务回归：配置校验、音景衔接、音量公式、事件规则、暂停与失焦恢复、试听资格、试听曲目。
## 依据《声音播放系统策划案》2-6 节与配置表；EX 技术测试读取正式配置并叠加测试夹具。

const AudioScript = preload("res://systems/audio/audio_service.gd")
const FIXTURE_ROOT := "res://tests/fixtures/"
const EX_CONFIG := "res://tests/fixtures/audio/audio_ex_config.json"
const PULSE := "design/basic/test_assets/audio/ex_bgm_pulse.wav"
const PULSE_PATH := "res://tests/fixtures/design/basic/test_assets/audio/ex_bgm_pulse.wav"
const DEFAULTS := {"master_volume": 100, "bgm_volume": 70, "ambient_volume": 60, "effect_volume": 80, "mute": false}
# 叠加到测试服务上的第二套资源与音景：不同 BGM、环境循环、阶段行与缺失资源。
const EXTRA := {
	"resources": [
		{"id": "T_BGM_B", "bus": "bgm", "resource_ref": "", "resource_path": "music/dies_irae_chant.ogg"},
		{"id": "T_AMB", "bus": "ambient", "resource_ref": "", "resource_path": "music/ein_feste_burg.ogg"},
		{"id": "T_BGM_MISSING", "bus": "bgm", "resource_ref": "", "resource_path": "music/not_there.ogg"},
	],
	"soundscapes": [
		{"id": "T_SCAPE_B", "context_kind": "scene", "target_ref": "SC_B", "phase_ref": "", "bgm_key": "T_BGM_B", "ambient_key": "T_AMB"},
		{"id": "T_SCAPE_B_LATE", "context_kind": "scene", "target_ref": "SC_B", "phase_ref": "LATE", "bgm_key": "EX_AUDIO_BGM_PULSE", "ambient_key": ""},
		{"id": "T_SCAPE_MISSING", "context_kind": "scene", "target_ref": "SC_MISS", "phase_ref": "", "bgm_key": "T_BGM_MISSING", "ambient_key": ""},
	],
}

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		print("AUDIO_FAIL: " + label)


func approx(a: float, b: float, tolerance := 0.0005) -> bool:
	return absf(a - b) <= tolerance


func make_service(extra: Array = [EX_CONFIG], with_settings := true) -> Node:
	var service: Node = AudioScript.new()
	service.log_warnings = false # 本测试会故意请求缺失资源，制作错误只通过记录与信号检查，不写引擎警告
	root.add_child(service)
	var ok: bool = service.setup(AudioScript.DEFAULT_CONFIG, extra, FIXTURE_ROOT)
	check(ok, "配置加载：" + str(service.config_errors))
	if with_settings:
		service.apply_settings(DEFAULTS)
	return service


func finish(service: Node) -> void:
	service.shutdown()
	service.queue_free()
	await process_frame


func bind_ui(service: Node) -> void:
	# 测试里临时绑定三个 UI 效果资源；正式配置中它们仍为未绑定。
	for key in ["SFX_UI_CLICK", "SFX_UI_CONFIRM", "SFX_UI_FEEDBACK"]:
		service.bind_resource(key, PULSE)


func _run() -> void:
	test_config()
	await test_matching()
	test_formula()
	await test_startup_and_continuity()
	await test_crossfade_and_ambient()
	await test_menu_and_volumes()
	await test_mute_and_zero()
	await test_events()
	await test_pause_and_focus()
	await test_preview()
	await test_missing_and_unmatched()
	await test_ui_hook()
	await test_performance()
	test_streams_and_music()
	await process_frame
	# 音频服务器异步释放已停止的播放；多等一会儿再退出，避免退出时仍有占用中的资源。
	await create_timer(0.5).timeout
	if failures.is_empty():
		print("AUDIO_SERVICE_PASS: %d checks" % checks)
		quit(0)
	else:
		print("AUDIO_SERVICE_FAILED: %d of %d checks" % [failures.size(), checks])
		quit(1)


func test_config() -> void:
	var service := make_service()
	var catalog = service.catalog
	check(int(catalog.control["bgm_crossfade_ms"]) == 800 and int(catalog.control["ambient_fade_ms"]) == 300, "总控淡化初值 800/300")
	check(approx(float(catalog.control["menu_bgm_factor"]), 0.5), "暂停 BGM 倍率 0.5")
	check(catalog.events.size() == 8, "8 个正式事件")
	check(catalog.resources.size() == 4, "3 个 UI 资源加 EX 脉冲资源")
	check(catalog.soundscapes.size() == 2, "正式 0 行加 EX 2 行")
	for key in ["SFX_UI_CLICK", "SFX_UI_CONFIRM", "SFX_UI_FEEDBACK"]:
		check(catalog.resource_state(key)["state"] == catalog.STATE_UNBOUND, key + " 保持未绑定")
	check(catalog.resource_state("EX_AUDIO_BGM_PULSE")["state"] == catalog.STATE_READY, "EX 脉冲资源就绪")
	check(catalog.resource_state("NOPE")["state"] == catalog.STATE_MISSING, "未知资源键按缺失处理")
	var before: int = catalog.resources.size()
	var bad_cases := {
		"重复资源 id": {"resources": [{"id": "SFX_UI_CLICK", "bus": "ui"}]},
		"非法类别": {"resources": [{"id": "X1", "bus": "music"}]},
		"引用与路径同时填写": {"resources": [{"id": "X2", "bus": "bgm", "resource_ref": "a", "resource_path": "b"}]},
		"BGM 淡化超范围": {"control": {"bgm_crossfade_ms": 6000}},
		"菜单倍率超范围": {"control": {"menu_bgm_factor": 1.5}},
		"标题音景组合重复": {"soundscapes": [{"id": "D1", "context_kind": "title", "bgm_key": "EX_AUDIO_BGM_PULSE"}]},
		"场景音景缺目标": {"soundscapes": [{"id": "D2", "context_kind": "scene", "target_ref": "", "bgm_key": ""}]},
		"音景轨道类别不符": {"soundscapes": [{"id": "D3", "context_kind": "scene", "target_ref": "S", "bgm_key": "SFX_UI_CLICK"}]},
		"固定事件引用不存在资源": {"events": [{"id": "E1", "bus": "ui", "source_kind": "fixed", "resource_key": "NOPE", "loop": false, "event_gain": 1.0}]},
		"动态事件填写资源键": {"events": [{"id": "E2", "bus": "result", "source_kind": "node_sound", "resource_key": "SFX_UI_CLICK", "loop": false, "event_gain": 1.0}]},
		"事件增益超范围": {"events": [{"id": "E3", "bus": "ui", "source_kind": "fixed", "resource_key": "SFX_UI_CLICK", "loop": false, "event_gain": 2.0}]},
	}
	for label in bad_cases.keys():
		check(not catalog.configure(bad_cases[label], true), "校验拒绝：" + label)
	check(catalog.resources.size() == before and catalog.soundscapes.size() == 2, "校验失败不改变已有配置")
	check(not catalog.errors.is_empty(), "校验失败记录错误原因")
	var formal := make_service([], false)
	check(formal.catalog.soundscapes.is_empty(), "只读正式配置时音景为 0 行")
	formal.free()
	service.free()


func test_matching() -> void:
	var service := make_service()
	var catalog = service.catalog
	check(catalog.match_soundscape("title")["id"] == "EX_SOUNDSCAPE_TITLE", "标题音景匹配")
	check(catalog.match_soundscape("title", "ANY")["id"] == "EX_SOUNDSCAPE_TITLE", "标题不使用目标")
	check(catalog.match_soundscape("scene", "EX_SC_HALL")["id"] == "EX_SOUNDSCAPE_HALL", "场景音景匹配")
	check(catalog.match_soundscape("scene", "NOPE").is_empty(), "无匹配返回空")
	check(catalog.match_soundscape("ending", "EX_SC_HALL").is_empty(), "结局不会匹配场景行")
	check(catalog.configure(EXTRA, true), "叠加第二套资源与音景：" + str(catalog.errors))
	check(catalog.match_soundscape("scene", "SC_B", "LATE")["id"] == "T_SCAPE_B_LATE", "准确阶段行优先")
	check(catalog.match_soundscape("scene", "SC_B", "OTHER")["id"] == "T_SCAPE_B", "未知阶段回落到同场景通用行")
	check(catalog.match_soundscape("scene", "SC_B")["id"] == "T_SCAPE_B", "无阶段取通用行")
	await finish(service)


func test_formula() -> void:
	var v := {"master_volume": 100, "bgm_volume": 40, "ambient_volume": 60, "effect_volume": 80, "mute": false}
	check(approx(AudioScript.final_multiplier(v, "bgm", 1.0, 1.0), 0.4), "BGM 40%")
	check(approx(AudioScript.final_multiplier(v, "bgm", 1.0, 0.5), 0.2), "菜单 BGM 20%")
	check(approx(AudioScript.final_multiplier(v, "ambient", 1.0, 1.0), 0.6), "环境取环境声音")
	for kind in ["ui", "result", "voice"]:
		check(approx(AudioScript.final_multiplier(v, kind, 1.0, 1.0), 0.8), kind + " 取效果音")
	v["master_volume"] = 50
	check(approx(AudioScript.final_multiplier(v, "bgm", 0.5, 1.0), 0.1), "事件增益×总音量×分项")
	check(approx(AudioScript.final_multiplier(v, "voice", 1.0, 0.5), 0.2), "操作结果配音不受菜单系数以外影响")
	v["effect_volume"] = 0
	check(AudioScript.final_multiplier(v, "ui", 1.0, 1.0) == 0.0, "效果音为 0 时最终为 0")
	check(AudioScript.final_multiplier(v, "bgm", 1.0, 1.0) > 0.0, "效果音为 0 不影响 BGM")
	v["mute"] = true
	check(AudioScript.final_multiplier(v, "bgm", 1.0, 1.0) == 0.0, "静音时最终为 0")


func test_startup_and_continuity() -> void:
	var service := make_service([EX_CONFIG], false)
	var pending: Dictionary = service.set_soundscape("title")
	check(pending["status"] == "pending", "设置未就绪时音景只记录不播放")
	check(service.total_live_tracks() == 0, "设置就绪前没有任何轨道")
	service.apply_settings(DEFAULTS)
	check(service.live_track_count("bgm") == 1, "设置就绪后标题音景开始")
	check(service.track_state("bgm")["path"] == PULSE_PATH and service.track_state("bgm")["loop"], "标题播放 EX 脉冲且循环")
	check(service.track_state("bgm")["bus"] == "BGM", "BGM 走 BGM 总线")
	check(service.current_soundscape["id"] == "EX_SOUNDSCAPE_TITLE", "当前音景摘要")
	service.advance(800)
	var hall: Dictionary = service.set_soundscape("scene", "EX_SC_HALL")
	check(hall["bgm"] == "same" and hall["soundscape"] == "EX_SOUNDSCAPE_HALL", "标题到场景共用同一资源：不重启")
	service.set_soundscape("scene", "EX_SC_HALL")
	check(service.start_counts["bgm"] == 1 and service.live_track_count("bgm") == 1, "重复请求与从 UI 返回都不重置循环")
	var rebuilt: Dictionary = service.set_soundscape("scene", "EX_SC_HALL", "", true)
	check(rebuilt["bgm"] == "started" and service.start_counts["bgm"] == 2, "读档重建从头重新播放")
	await finish(service)


func test_crossfade_and_ambient() -> void:
	var service := make_service()
	service.catalog.configure(EXTRA, true)
	service.set_soundscape("title")
	service.advance(800)
	check(approx(service.track_state("bgm")["fade"], 1.0), "首个 BGM 淡入完成")
	var result: Dictionary = service.set_soundscape("scene", "SC_B")
	check(result["bgm"] == "started" and service.live_track_count("bgm") == 2, "不同资源交叉淡化，最多 2 轨")
	check(approx(service.track_state("bgm")["fade"], 0.0) and approx(service.track_state("bgm", true)["fade"], 1.0), "新轨从 0 淡入，旧轨从满音量淡出")
	check(service.is_processing(), "淡化期间才逐帧推进")
	service.advance(400)
	check(approx(service.track_state("bgm")["fade"], sin(PI / 4.0)) and approx(service.track_state("bgm", true)["fade"], cos(PI / 4.0)), "等功率曲线中点")
	service.advance(400)
	check(service.live_track_count("bgm") == 1 and approx(service.track_state("bgm")["fade"], 1.0), "淡化完成后旧轨停止")
	check(service.live_track_count("ambient") == 1 and service.track_state("ambient")["bus"] == "Ambient", "环境循环走 Ambient 总线")
	service.advance(300)
	check(not service.is_processing(), "没有淡化时关闭逐帧处理")
	# 淡化途中再次切换：不会出现第三条 BGM 轨。
	service.set_soundscape("scene", "SC_B", "LATE")
	service.advance(100)
	service.set_soundscape("scene", "SC_B")
	check(service.live_track_count("bgm") <= 2, "连续切换仍不超过 2 轨")
	service.advance(1000)
	check(service.live_track_count("bgm") == 1, "最终只剩 1 轨")
	# 阶段行没有环境键：环境声淡出后停止。
	service.set_soundscape("scene", "SC_B", "LATE")
	check(service.live_track_count("ambient") == 1, "环境淡出期间仍占 1 轨")
	service.advance(300)
	check(service.live_track_count("ambient") == 0, "空环境键淡出后停止环境轨")
	# 淡化时长为 0：直接切换。
	service.catalog.control["bgm_crossfade_ms"] = 0
	service.set_soundscape("scene", "SC_B")
	check(service.live_track_count("bgm") == 1 and approx(service.track_state("bgm")["fade"], 1.0), "淡化为 0 时直接切换")
	await finish(service)


func test_menu_and_volumes() -> void:
	var service := make_service()
	service.catalog.configure(EXTRA, true)
	service.apply_settings({"bgm_volume": 40, "ambient_volume": 60})
	service.set_soundscape("scene", "SC_B")
	service.advance(1000)
	check(approx(service.output_multiplier("bgm"), 0.4) and approx(service.output_multiplier("ambient"), 0.6), "BGM 40%、环境 60%")
	check(approx(service.effective_linear("bgm"), 0.4, 0.002), "播放器与总线反算的真实输出一致")
	service.set_menu_open(true)
	check(approx(service.output_multiplier("bgm"), 0.2), "菜单中 BGM 20%")
	check(not service.track_state("bgm")["paused"] and service.track_state("ambient")["paused"], "菜单中 BGM 继续，环境冻结")
	service.apply_settings({"bgm_volume": 80})
	check(approx(service.output_multiplier("bgm"), 0.4) and approx(service.effective_linear("bgm"), 0.4, 0.002), "菜单中调整 BGM 立即生效并保持倍率")
	service.apply_settings({"bgm_volume": 40, "master_volume": 50})
	check(approx(service.effective_linear("bgm"), 0.1, 0.002), "总音量与菜单倍率叠乘")
	service.apply_settings({"master_volume": 100})
	service.set_menu_open(false)
	check(approx(service.output_multiplier("bgm"), 0.4) and not service.track_state("ambient")["paused"], "继续后移除倍率并恢复环境")
	# 菜单打开时环境淡化保持原位。
	service.set_soundscape("scene", "SC_B", "LATE")
	service.set_menu_open(true)
	service.advance(300)
	check(service.live_track_count("ambient") == 1, "菜单中环境淡化冻结")
	service.set_menu_open(false)
	service.advance(300)
	check(service.live_track_count("ambient") == 0, "继续后环境淡化接续完成")
	await finish(service)


func test_mute_and_zero() -> void:
	var service := make_service()
	bind_ui(service)
	service.set_soundscape("title")
	service.advance(800)
	service.apply_settings({"mute": true})
	check(approx(service.output_multiplier("bgm"), 0.0), "静音时 BGM 输出为 0")
	check(service.live_track_count("bgm") == 1, "静音保留当前轨道")
	var muted: Dictionary = service.request_event("SND_UI_CLICK", "inst-mute")
	check(muted["status"] == "silent" and service.start_counts["ui"] == 0, "静音时一次性声音不播放")
	service.apply_settings({"mute": false})
	check(approx(service.output_multiplier("bgm"), 0.7), "解除静音恢复原音量值")
	check(service.request_event("SND_UI_CLICK", "inst-mute")["status"] == "duplicate", "解除静音不补播过去实例")
	service.apply_settings({"effect_volume": 0})
	check(service.request_event("SND_UI_CLICK", "inst-zero")["status"] == "silent", "效果音为 0 时一次性声音不播放")
	check(approx(service.output_multiplier("bgm"), 0.7), "效果音为 0 不影响 BGM")
	service.apply_settings({"master_volume": 0})
	check(approx(service.output_multiplier("bgm"), 0.0) and service.live_track_count("bgm") == 1, "总音量为 0 时输出为 0 且轨道保留")
	await finish(service)


func test_events() -> void:
	var service := make_service()
	var unbound: Dictionary = service.play_ui("click")
	check(unbound["status"] == "unbound" and service.production_errors.is_empty(), "UI 效果未绑定：不发声也不记制作错误")
	check(service.play_ui("nope")["status"] == "unknown" and service.request_event("NOPE")["status"] == "unknown", "未知事件键被忽略")
	check(not service.bind_resource("SFX_NOPE", PULSE) and service.play_ui("click")["status"] == "unbound", "绑定不存在的资源键被拒绝且不影响现有事件")
	check(service.bind_resource("SFX_UI_CLICK", "design/none/missing.ogg") and service.catalog.resource_state("SFX_UI_CLICK")["state"] == "missing", "绑定到不存在的文件按缺失处理")
	bind_ui(service)
	check(service.catalog.resource_state("SFX_UI_CLICK")["state"] == "ready", "绑定到真实文件后资源就绪")
	check(service.play_ui("click", "u-1")["status"] == "played" and service.start_counts["ui"] == 1, "点击音播放一次")
	check(service.play_ui("click", "u-1")["status"] == "duplicate" and service.start_counts["ui"] == 1, "同实例重复派发只处理一次")
	check(service.track_state("ui")["bus"] == "Effect", "操作音走效果音总线")
	service.play_ui("confirm", "u-2")
	check(service.live_track_count("ui") == 1 and service.start_counts["ui"] == 2, "同轨新声音替换旧声音")
	var ref := PULSE
	check(service.play_result("r-1", ref)["status"] == "played", "结果音播放")
	check(service.play_voice("v-1", ref)["status"] == "played", "配音播放")
	check(service.live_track_count("ui") == 1 and service.live_track_count("result") == 1 and service.live_track_count("voice") == 1, "操作、结果、配音分别占轨可同时播放")
	check(service.play_node_sound("r-1", ref)["status"] == "duplicate", "同一次 sound 经另一入口不另建实例")
	check(service.play_result("r-2", "")["status"] == "empty" and service.production_errors.is_empty(), "空引用不建立声音也不算错误")
	check(service.play_voice("v-2", "design/none/missing.ogg")["status"] == "missing" and service.production_errors.size() == 1, "非空缺失记录制作错误且不替换曲目")
	check(service.live_track_count("voice") == 1 and service.track_state("voice")["path"] == FIXTURE_ROOT + PULSE, "缺失请求不替换现有配音")
	check(service.play_result("r-3", ref, {"session": 0})["status"] == "stale", "失效会话请求被拒绝")
	service.stop_node_media()
	check(service.live_track_count("result") == 0 and service.live_track_count("voice") == 0, "换节点停止结果与配音")
	check(service.live_track_count("ui") == 1, "停止节点声音不影响操作音")
	var old_session: int = service.session_id
	service.begin_session()
	check(service.session_id == old_session + 1 and service.play_result("r-1", ref)["status"] == "played", "新会话清空去重表并允许同名实例")
	check(service.play_result("r-4", ref, {"session": old_session})["status"] == "stale", "旧会话请求在新会话中被拒绝")
	var media: Dictionary = service.request_media({"event": "SND_RESULT", "instance": "m-1", "ref": ref, "session": service.session_id})
	check(media["status"] == "played", "统一媒体入口播放结果音")
	# 自然结束后继续时不补播：一次性轨道在 finished 后被回收。
	await create_timer(2.4).timeout
	check(service.live_track_count("result") == 0, "自然结束后清理轨道")
	await finish(service)


func test_pause_and_focus() -> void:
	var service := make_service()
	bind_ui(service)
	service.set_soundscape("title")
	service.advance(800)
	service.play_result("r-1", PULSE)
	service.play_voice("v-1", PULSE)
	service.play_ui("click", "u-1")
	# 菜单：世界声音停在原位置，BGM 与 UI 保持。
	service.set_menu_open(true)
	check(service.track_state("result")["paused"] and service.track_state("voice")["paused"], "菜单中结果与配音停在原位置")
	check(not service.track_state("bgm")["paused"] and not service.track_state("ui")["paused"], "菜单中 BGM 与 UI 声继续")
	check(service.play_result("r-9", PULSE)["status"] == "held" and service.live_track_count("result") == 1, "菜单中不建立新的世界声音且不排队")
	check(service.play_ui("click", "u-9")["status"] == "played", "菜单中的有效 UI 声可播放")
	service.set_menu_open(false)
	check(not service.track_state("result")["paused"] and service.live_track_count("result") == 1, "对应继续后从原位置接续，不重复建立实例")
	# 失焦：全部冻结，回焦仍等待有效输入。
	service.notify_window_focus(false)
	var all_paused := true
	for slot in ["bgm", "result", "voice", "ui"]:
		all_paused = all_paused and service.track_state(slot)["paused"]
	check(all_paused, "窗口失焦冻结全部声音")
	check(service.play_ui("click", "u-f")["status"] == "frozen", "冻结期间新请求不排队")
	service.notify_window_focus(true)
	check(service.track_state("bgm")["paused"], "回焦后仍等待有效输入")
	service.notify_valid_input()
	var none_paused := true
	for slot in ["bgm", "result", "voice", "ui"]:
		none_paused = none_paused and not service.track_state(slot)["paused"]
	check(none_paused and service.focus_state == AudioScript.Focus.ACTIVE, "非菜单状态下有效输入同次完成两级恢复")
	# 失焦发生在暂停菜单中：第一步恢复 BGM 与 UI，第二步等继续。
	service.set_menu_open(true)
	service.notify_window_focus(false)
	service.notify_window_focus(true)
	service.notify_valid_input()
	check(not service.track_state("bgm")["paused"] and service.track_state("result")["paused"], "菜单中第一步只恢复 BGM 与界面声")
	check(service.play_ui("click", "u-r")["status"] == "played", "第一步后新界面声音可播放")
	service.set_menu_open(false)
	check(not service.track_state("result")["paused"] and service.focus_state == AudioScript.Focus.ACTIVE, "对应继续后第二步恢复世界声音")
	# 回焦后的有效输入本身就是菜单继续：同次完成两级恢复（继续先于输入通知）。
	service.set_menu_open(true)
	service.notify_window_focus(false)
	service.notify_window_focus(true)
	service.set_menu_open(false)
	check(service.track_state("bgm")["paused"], "有效输入前仍然冻结")
	service.notify_valid_input()
	check(not service.track_state("result")["paused"] and not service.track_state("bgm")["paused"], "继续与有效输入同次完成两级恢复")
	# 失焦冻结淡化。
	service.set_soundscape("scene", "EX_SC_HALL", "", true)
	service.notify_window_focus(false)
	service.advance(500)
	check(approx(service.track_state("bgm")["fade"], 0.0), "失焦期间淡化不推进")
	check(not service.is_processing(), "冻结时关闭逐帧处理")
	service.notify_window_focus(true)
	service.notify_valid_input()
	service.advance(800)
	check(approx(service.track_state("bgm")["fade"], 1.0), "恢复后淡化继续")
	await finish(service)


func test_preview() -> void:
	var service := make_service()
	check(service.preview_state() == {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_UNREADY"}, "素材未绑定：试听禁用并给出未就绪原因")
	check(service.preview_effect()["status"] == "disabled", "禁用时点击试听不发声")
	service.apply_settings({"mute": true})
	check(service.preview_state()["reason"] == "UI_SETTINGS_PREVIEW_MUTED", "静音原因优先")
	service.apply_settings({"mute": false, "master_volume": 0, "effect_volume": 0})
	check(service.preview_state()["reason"] == "UI_SETTINGS_PREVIEW_MASTER_ZERO", "总音量为 0 先于效果音为 0")
	service.apply_settings({"master_volume": 100})
	check(service.preview_state()["reason"] == "UI_SETTINGS_PREVIEW_EFFECT_ZERO", "效果音为 0 原因")
	service.apply_settings({"effect_volume": 80})
	bind_ui(service)
	check(service.preview_state()["enabled"], "素材就绪且音量正常时可试听")
	check(service.preview_effect()["status"] == "played" and service.start_counts["preview"] == 1, "试听播放一次反馈事件")
	check(service.start_counts["ui"] == 0, "试听不叠加普通点击音")
	service.preview_effect()
	check(service.live_track_count("preview") == 1 and service.start_counts["preview"] == 2, "新试听替换旧试听")
	service.stop_preview()
	check(service.live_track_count("preview") == 0, "离开设置停止试听")
	await finish(service)


func test_missing_and_unmatched() -> void:
	var service := make_service()
	service.catalog.configure(EXTRA, true)
	service.set_soundscape("title")
	service.advance(800)
	var missing: Dictionary = service.set_soundscape("scene", "SC_MISS")
	check(missing["bgm"] == "missing" and service.production_errors.size() == 1, "音景资源缺失记录制作错误")
	check(service.live_track_count("bgm") == 1 and service.track_state("bgm")["path"] == PULSE_PATH, "缺失时保留原 BGM，不替换曲目")
	var none: Dictionary = service.set_soundscape("scene", "UNKNOWN_SCENE")
	check(none["status"] == "unmatched" and service.live_track_count("bgm") == 1, "无匹配音景：停止 BGM（淡出中）")
	service.advance(800)
	check(service.live_track_count("bgm") == 0, "无匹配音景淡出后静音")
	service.stop_soundscape()
	check(service.current_soundscape.is_empty(), "停止音景清空摘要")
	await finish(service)


func test_ui_hook() -> void:
	var service := make_service()
	bind_ui(service)
	service.attach_ui_hook(self)
	var button := Button.new()
	root.add_child(button)
	button.pressed.emit()
	check(service.start_counts["ui"] == 1 and service.track_state("ui")["instance"].begins_with("ui/"), "被接受的按钮操作播放点击音")
	button.set_meta("ui_sound", "none")
	button.pressed.emit()
	check(service.start_counts["ui"] == 1, "ui_sound=none 不发点击音")
	button.set_meta("ui_sound", "confirm")
	button.pressed.emit()
	check(service.start_counts["ui"] == 2, "ui_sound=confirm 发确认音")
	service.notify_window_focus(false)
	service.notify_window_focus(true)
	check(service.focus_state == AudioScript.Focus.AWAITING_INPUT, "回焦后等待有效输入")
	button.pressed.emit()
	check(service.focus_state == AudioScript.Focus.ACTIVE and service.start_counts["ui"] == 3, "被接受的按钮操作完成恢复并发声")
	var late := Button.new() # 钩子之后新增的按钮也会被接入。
	root.add_child(late)
	late.pressed.emit()
	check(service.start_counts["ui"] == 4, "后加入的按钮同样触发点击音")
	button.queue_free()
	late.queue_free()
	await finish(service)


func test_performance() -> void:
	var service := make_service()
	bind_ui(service)
	var started := Time.get_ticks_usec()
	for index in 2000:
		service.play_ui("click")
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("AUDIO_PERF: 2000 次点击请求 %.1f ms" % elapsed_ms)
	check(elapsed_ms < 2000.0, "2000 次点击请求耗时合理（%.0f ms）" % elapsed_ms)
	check(service.get_child_count() <= AudioScript.POOL_LIMIT + 1, "播放器节点复用，不随请求增长")
	check(service._handled.size() <= AudioScript.HANDLED_LIMIT, "实例去重表有上限")
	check(service.total_live_tracks() == 1, "同轨替换后只保留 1 条操作轨")
	check(not service.is_processing(), "没有淡化时不逐帧处理")
	await finish(service)


func test_streams_and_music() -> void:
	var catalog = AudioScript.CatalogScript.new()
	catalog.asset_root = FIXTURE_ROOT
	var wav: AudioStreamWAV = catalog.get_stream(PULSE_PATH, true)
	check(wav.loop_mode == AudioStreamWAV.LOOP_FORWARD and wav.loop_end == 96000, "WAV 循环终点按时长×采样率计算")
	var original: AudioStreamWAV = load(PULSE_PATH)
	check(original.loop_mode == AudioStreamWAV.LOOP_DISABLED, "循环副本不污染共享原始资源")
	check(catalog.get_stream(PULSE_PATH, true) == wav, "循环流被缓存")
	var file := FileAccess.open("res://tests/fixtures/music/manifest.json", FileAccess.READ)
	check(file != null, "试听曲目清单存在")
	if file == null:
		return
	var manifest = JSON.parse_string(file.get_as_text())
	var tracks: Array = manifest["tracks"]
	check(tracks.size() == 10, "十首试听曲目")
	var longest := 0.0
	for item in tracks:
		check(String(item["license"]) != "" and String(item["page_url"]).begins_with("https://commons.wikimedia.org/"), "%s 带授权与来源页" % item["id"])
		var path: String = "res://tests/fixtures/music/" + String(item["file"])
		check(ResourceLoader.exists(path), "%s 已导入" % item["id"])
		var began := Time.get_ticks_usec()
		var stream: AudioStream = catalog.get_stream(path, true)
		longest = maxf(longest, float(Time.get_ticks_usec() - began) / 1000.0)
		check(stream != null and stream.get_length() > 20.0, "%s 可加载且时长充足" % item["id"])
		if stream != null:
			check(bool(stream.get("loop")), "%s 循环副本带循环标记" % item["id"])
	print("AUDIO_PERF: 十首试听曲目最长单次同步加载 %.1f ms" % longest)
	catalog.clear_cache()
	wav = null
	original = null
	catalog = null
