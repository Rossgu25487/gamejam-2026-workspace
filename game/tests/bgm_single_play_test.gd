extends SceneTree
## 调查BGM单次播放、按真实曲目键记录完成、同路径不同策略不被same短路、读档恢复、环境循环不变。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Audio = preload("res://systems/audio/audio_service.gd")
var checks := 0
var failures: Array[String] = []

func _init() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func finish_bgm(audio) -> void:
	# headless Dummy 不推进音频时钟，沿真实 finished 回执模拟自然播完。
	for track in audio._track_of.values().duplicate():
		if track.slot == "bgm" and not track.loop:
			audio._on_player_finished(track.player)
			return

func reset_audio(audio) -> void:
	audio.stop_soundscape()
	audio.advance(5000.0)
	audio.begin_session()

func run() -> void:
	var session := Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式配置成功载入")
	if not failures.is_empty(): session.queue_free(); quit(1); return
	var audio := Audio.new()
	root.add_child(audio)
	audio.log_warnings = false
	check(audio.setup_package(session.config), "正式声音工作簿可用")
	audio.apply_settings({"master_volume": 100, "effect_volume": 80, "mute": false})

	# 动态找就绪的调查BGM资源键，避免硬编码内容ID。
	var bgm_key := ""
	for id in audio.catalog.resources:
		var rec: Dictionary = audio.catalog.resources[id]
		var info: Dictionary = audio.catalog.resource_state(str(id))
		if info.state != "ready": continue
		if str(rec.get("bus", "")) == "bgm" and str(id).begins_with("BGM_PHASE_") and bgm_key.is_empty():
			bgm_key = str(id)
	check(not bgm_key.is_empty(), "存在就绪的调查BGM资源：" + bgm_key)
	var finale := "BGM_FINALE_CREDITS_ENTRY"
	check(audio.catalog.resource_state(finale).state == "ready", "片尾BGM资源就绪")

	# 1. 调查BGM单次播放（不循环）。
	reset_audio(audio)
	var starts: int = audio.start_counts["bgm"]
	audio.set_narrative_soundscape(bgm_key)
	check(audio.start_counts["bgm"] == starts + 1, "调查BGM实际启动一次")
	check(bool(audio.track_state("bgm").loop) == false, "调查BGM为单次播放（不循环）")
	check(audio.track_state("bgm").path != "", "调查BGM路径非空")

	# 2. 自然结束后按真实曲目键记录完成，不误记片尾。
	finish_bgm(audio)
	check(audio.track_state("bgm").is_empty(), "自然结束后BGM轨道释放")
	check(bool(audio.export_narrative_media(bgm_key).completed) == true, "按真实曲目键记录完成：" + bgm_key)
	check(bool(audio.export_narrative_media(finale).completed) == false, "调查曲结束不误记片尾完成")

	# 3. 已播完的同阶段不重起。
	starts = audio.start_counts["bgm"]
	audio.set_narrative_soundscape(bgm_key)
	check(audio.start_counts["bgm"] == starts and audio.track_state("bgm").is_empty(), "已播完的同阶段不重起")

	# 4. 同路径不同策略不被same短路。
	reset_audio(audio)
	check(audio._set_loop("bgm", bgm_key, false, true) == "started" and bool(audio.track_state("bgm").loop) == true, "同路径以循环策略启动")
	check(audio._set_loop("bgm", bgm_key, false, false) == "started" and bool(audio.track_state("bgm").loop) == false, "同路径改单次不被same短路")

	# 5. 片尾BGM单次播放，完成记到自己的键。
	reset_audio(audio)
	audio.set_narrative_soundscape(finale)
	check(bool(audio.track_state("bgm").loop) == false, "片尾BGM单次播放")
	finish_bgm(audio)
	check(bool(audio.export_narrative_media(finale).completed) == true, "片尾完成记到片尾键")
	check(bool(audio.export_narrative_media(bgm_key).completed) == false, "片尾完成不误记调查键")

	# 6. 读档恢复：已完成不重播，未完成按位置续播单次。
	reset_audio(audio)
	audio.restore_narrative_media({"key": bgm_key, "completed": true})
	check(audio.track_state("bgm").is_empty() and bool(audio.export_narrative_media(bgm_key).completed) == true, "已完成读档恢复不重播")
	reset_audio(audio)
	audio.restore_narrative_media({"key": bgm_key, "completed": false, "position": 0.0})
	check(not audio.track_state("bgm").is_empty() and bool(audio.track_state("bgm").loop) == false, "未完成读档按位置续播单次")
	check(bool(audio.export_narrative_media(bgm_key).completed) == false, "未完成续播不标完成")

	# 7. 环境循环不变：环境槽默认仍是循环；环境声事件配置保持循环（不随本次改动变化）。
	check(bool(audio.catalog.events.get("SND_SCENE_AMBIENT", {}).get("loop", false)) == true, "环境声事件保持循环配置")
	audio.catalog.configure({"resources": [{"id": "TEST_AMBIENT_LOOP", "bus": "ambient", "resource_ref": "", "resource_path": str(audio.catalog.resource_state(bgm_key).path)}]}, true)
	audio._set_loop("ambient", "TEST_AMBIENT_LOOP", false)
	check(bool(audio.track_state("ambient").loop) == true, "环境槽默认仍为循环")

	check(audio.production_errors.is_empty(), "声音接入无缺失或空路径警告：" + str(audio.production_errors))

	audio.shutdown()
	audio.queue_free()
	session.queue_free()
	await process_frame
	print("BGM_SINGLE_PLAY_PASS %d checks" % checks if failures.is_empty() else "BGM_SINGLE_PLAY_FAIL %d/%d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
