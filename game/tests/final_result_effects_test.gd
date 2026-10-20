extends SceneTree
## 正式数据下检查反馈时序、主动收下边界、暂停/取消和四比例几何。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Effect = preload("res://pages/aurora/aurora_result_effect.gd")
var checks := 0
var failures: Array[String] = []
var completions := 0
var menu_requests := 0
var sound_requests: Array[Dictionary] = []

func _initialize() -> void: call_deferred("_run")
func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func frames(count: int = 3) -> void:
	for index in range(count): await process_frame

func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	var session := Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式最终包成功初始化")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset()
	session.question = "T00_R01"
	session.current_statement = str(session.config.questions.T00_R01.target_text_ref)
	session.pending_result = {"result": "RESULT_T00_R01", "refs": ["E28_V1"], "text": "登记年份已核对。", "effect_pending": true}
	var page := Effect.new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session)
	page.set_process(false)
	page.finished.connect(func(): completions += 1)
	page.menu_requested.connect(func(): menu_requests += 1)
	page.media_requested.connect(func(request): sound_requests.append(request))
	page.collection_geometry_provider = func(_id): return Rect2(980, 600, 146, 219)
	var state_before: Dictionary = session.case_state.data.duplicate(true)
	var first_break: Dictionary = session.config.presentation(session.config.results.RESULT_T00_R01)
	page.play(first_break)
	await frames()
	check(page.kind == "break" and is_equal_approx(page.duration_ms, 5600), "首次击破消费正式5600ms表现规则")
	check(page.active and session.processing and not page.skippable and not page.skip_button.visible, "首次教学击破输入锁且不能跳过")
	check(page._shards.size() >= 40 and page._quote_viewport != null, "断言纸面分割成实际纹理裂片")
	check(sound_requests.size() == 1 and sound_requests.back().ref == "SFX_CORE_BREAKTHROUGH", "主演出开始仅请求一次正式击破声音")
	var background := Button.new()
	background.name = "BackgroundAccept"
	root.add_child(background)
	background.grab_focus()
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	page._input(tab)
	check(root.gui_get_focus_owner() == page.menu_button, "反馈Tab拦截并重新聚焦当前层")
	background.queue_free()
	page.skip()
	check(page.active and completions == 0, "首次跳过请求不提前结束")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	page._input(escape)
	check(menu_requests == 1 and page.active, "Esc只请求暂停，不结束表现")
	session.paused = true
	page._process(2.0)
	check(is_zero_approx(page.elapsed_ms), "暂停冻结反馈时轴")
	session.paused = false
	page._process(1.70)
	check(page.active and is_equal_approx(page.elapsed_ms, 1700), "正常反馈推进到碎裂阶段")
	if "--capture" in OS.get_cmdline_user_args():
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-effect-glass.png"))
	page._process(3.899)
	check(page.active and completions == 0, "首次反馈在完整5600ms前保持输入锁")
	page._process(0.002)
	check(not page.active and completions == 1 and not session.processing, "完整表现后只回执一次")
	check(session.case_state.data == state_before, "击破动画没有知识、事件或取得副作用")
	page.stop()
	check(completions == 1, "重复stop不再次发完成")
	session.question = "T00_R02"
	session.current_statement = str(session.config.questions.T00_R02.target_text_ref)
	session.pending_result = {"result": "RESULT_T00_R02", "refs": ["E01_V1", "E28_V1"], "text": "清单与登记册对应。", "effect_pending": true}
	var insight: Dictionary = session.config.presentation(session.config.results.RESULT_T00_R02)
	page.play(insight)
	page._process(3.0)
	await frames()
	check(page.kind == "insight" and is_equal_approx(page.duration_ms, 6800) and not page.skippable, "首次涌现完整6800ms且不跳过")
	check(page._effect_art.get("fx_flying_pages_01") != null and page._effect_art.get("fx_stamp_inspiration") != null, "采用已交ArtB飞页和无字字标底")
	check(page.source_cards.size() == 2, "正式双卡关系展示两份实际依据")
	check(not session.case_state.owns("P06_V1"), "涌现预览不提前取得待收推论")
	if "--capture" in OS.get_cmdline_user_args():
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-effect-insight.png"))
	page.stop(false)
	check(completions == 1 and not session.case_state.owns("P06_V1"), "取消反馈不完成、不发卡")
	session.question = "L02_R02"
	session.pending_result = {"result": "RESULT_L02_R02", "refs": [], "effect_pending": true}
	page.play(session.config.presentation(session.config.results.RESULT_L02_R02))
	check(page.skippable, "后续非教学关键表现可跳过")
	var result_before: Dictionary = session.case_state.data.duplicate(true)
	page.skip()
	check(completions == 2 and session.case_state.data == result_before, "跳过仅退回既有结果，不收下或提交")
	page.set_preferences({"reduce_motion": true})
	page.play(insight)
	var stale_generation: int = page.generation
	await frames()
	check(page.active and is_equal_approx(page.paper.modulate.a, 1.0) and is_equal_approx(page.title.modulate.a, 1.0), "低动态模式立即显示同一结果信息且不闪动")
	page.stop(false)
	page.play({"effect_level": "progress", "duration_ms": 3200})
	page._finish_generation(stale_generation)
	check(page.active, "旧低动态回执不能结束新表现")
	page.set_preferences({"reduce_motion": false})
	page.elapsed_ms = 2600
	page._update_visuals()
	if "--capture" in OS.get_cmdline_user_args():
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-effect-progress.png"))
	for viewport in [Vector2i(1600, 900), Vector2i(1440, 900), Vector2i(1200, 900), Vector2i(2100, 900)]:
		root.size = viewport
		root.content_scale_size = viewport
		await frames()
		page._layout()
		var bounds := Rect2(Vector2.ZERO, Vector2(viewport))
		var actual := Rect2(page.stage.global_position, page.stage.size * page.stage.scale)
		check(bounds.encloses(actual), "效果舞台在有效窗口中：" + str(viewport))
		for name in ["ResultInformation", "ResultEffectTitle", "ResultEffectMenu", "SkipResultEffect"]:
			var node := page.find_child(name, true, false) as Control
			check(node != null and bounds.encloses(node.get_global_rect()), "反馈正文/标题/操作完整可见：" + str(viewport) + "/" + name)
	page.stop(false)
	check(not page.play_acquisition("E01_V1"), "未取得内容不能假播成卡")
	session.case_state.grant("E01_V1", {"entry": "ENTRY_CH01_READ_E01"})
	check(page.play_acquisition("E01_V1", 2000), "实际已取得E01可以播放普通成卡")
	check(page.kind == "acquire" and is_equal_approx(page.duration_ms, 400.0 / 0.75 + 2000.0) and not page.skippable, "首次取得400ms/0.75成卡加2000ms提示，无确认")
	var acquisition_hint := page.find_child("AcquisitionHint", true, false) as Label
	check(acquisition_hint != null and not acquisition_hint.text.is_empty(), "首次材料提示读取公共功能文案")
	var acquired_before: Dictionary = session.case_state.data.duplicate(true)
	page._process(2.5334)
	check(session.case_state.data == acquired_before, "普通成卡不再次入库")
	page.play({"effect_level": "collect", "duration_ms": 900, "content_id": "P06_V1"})
	var expected_center := page._to_reference(Vector2(1053, 709.5))
	check(page.collection_target.is_equal_approx(expected_center), "收卡消费宿主实际手牌几何，不匹配到动画本身")
	page._process(0.5)
	check(page.result_card.position.x > 670, "收卡实际向手牌移动")
	if "--capture" in OS.get_cmdline_user_args():
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-effect-collection.png"))
	page.elapsed_ms = 0
	page._process(0.899)
	check(page.active and page.result_card != null, "收卡持续900ms并实际显示卡面")
	page._process(0.002)
	check(not page.active and not session.case_state.owns("P06_V1"), "收卡表现自身没有取得副作用")
	page.queue_free()
	session.queue_free()
	await frames()
	print("FINAL_RESULT_EFFECTS_PASS %d checks" % checks if failures.is_empty() else "FINAL_RESULT_EFFECTS_FAIL %d/%d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
