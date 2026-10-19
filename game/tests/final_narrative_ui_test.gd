extends SceneTree
## 使用正式配置检查时地页、心声及普通对白的实际阅读节点。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Page = preload("res://pages/narrative/narrative_page.gd")
const Narrative = preload("res://systems/narrative/narrative_service.gd")
var checks := 0
var failures: Array[String] = []

func _init() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		printerr("FINAL_NARRATIVE_UI_FAILED: " + message)

func frames() -> void:
	for index in range(6): await process_frame

func _run() -> void:
	root.size = Vector2i(1600, 900)
	var session := Session.new()
	root.add_child(session)
	session.seen_storage_path = "user://final_narrative_ui_seen_%d.json" % Time.get_ticks_usec()
	check(session.initialize(), "正式配置加载")
	if not failures.is_empty(): quit(1); return
	var page := Page.new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session.narrative)
	page.set_process(false) # 此测试手动推进时钟，避免帧耗时影响字速与快显断言。
	var time_id := ""
	var inner_id := ""
	var dialogue_id := ""
	for id in session.config.texts:
		var row: Dictionary = session.config.texts[id]
		if time_id.is_empty() and row.get("text_kind") == "time_caption": time_id = id
		if inner_id.is_empty() and row.get("text_kind") in ["inner", "内心"] and row.get("character_id") == "CHR01": inner_id = id
		if dialogue_id.is_empty() and row.get("text_kind") in ["dialogue", "对白"] and not str(row.get("avatar_ref", "")).is_empty(): dialogue_id = id
	check(not time_id.is_empty() and not inner_id.is_empty() and not dialogue_id.is_empty(), "正式表提供时地、心声及带头像对白")
	for id in [dialogue_id, inner_id, time_id, dialogue_id]:
		check(session.narrative.show_text(id), "播放正式文本：" + id)
		await frames()
		check(page.find_child("DialoguePaper", true, false) != null, "深墨正文显示在浅色纸面")
		check(is_equal_approx(page.text_label.position.y, 736.667), "正文保持下方阅读位置")
		check(page.text_label.get_theme_color("default_color") == Color(str(session.config.texts[id].font_color)), "实际正文消费本行颜色")
		var avatar := page.find_child("DialogueAvatar", true, false)
		if id == dialogue_id:
			check(avatar != null and page.name_label.visible, "普通对白恢复本句头像与姓名")
		elif id == inner_id:
			check(avatar == null and page.name_label.visible and is_equal_approx(page.text_label.position.x, 96), "艾琳心声清空头像并使用无头像正文宽度")
			check(page.name_label.text == "艾琳（心声）", "心声使用明确显示名")
		else:
			check(avatar == null and not page.name_label.visible, "时地页没有头像或残留姓名")
		check(page.find_child("SceneInformation", true, false) != null, "阅读期间左上地点常驻")
		if "--capture" in OS.get_cmdline_user_args():
			session.narrative.advance()
			await frames()
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final_narrative_%s.png" % str(session.config.texts[id].text_kind)))
	# Tab直接走完整输入分发，只改变焦点，不切换快读。
	session.narrative.state.seen_at_start = true
	var text_before := str(session.narrative.state.current_text_id)
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	Input.parse_input_event(tab)
	await frames()
	check(session.narrative.fast_mode.is_empty() and session.narrative.state.current_text_id == text_before, "Tab只移动焦点不跳剧情")
	tab.shift_pressed = true
	Input.parse_input_event(tab)
	await frames()
	check(session.narrative.fast_mode.is_empty(), "Shift+Tab不进入跳过")
	check(page.skip_button.text == "跳过", "跳过保留独立点击入口")
	var key_l := InputEventKey.new()
	key_l.keycode = KEY_L
	key_l.pressed = true
	Input.parse_input_event(key_l)
	await frames()
	check(session.narrative.reading_log and page.find_child("DialogueSkip", true, false) == null, "L打开记录并撤销后方阅读按钮")
	Input.parse_input_event(key_l)
	await frames()
	check(not session.narrative.reading_log, "L关闭记录恢复当前正文")
	page.set_preferences({"text_speed": 1})
	check(is_equal_approx(session.narrative.typewriter_speed, 15), "慢速实际消费30字每秒的一半")
	page.set_preferences({"text_speed": 3})
	check(is_equal_approx(session.narrative.typewriter_speed, 45), "快速实际消费30字每秒的1.5倍")
	session.narrative.set_log_open(true)
	await frames()
	check(page.find_child("DialogueLogScroll", true, false) != null and not page.stage.visible, "正式对白记录独占阅读层")
	session.narrative.set_log_open(false)
	await frames()
	# 正式站位使用实际朝向与人体锚点，不镜像资源。
	var actor_row: Dictionary = session.narrative.catalog.data.texts[dialogue_id].duplicate(true)
	for id in session.config.texts:
		if session.config.texts[id].get("character_id") == "CHR04" and not str(session.config.texts[id].get("portrait_path", "")).is_empty():
			actor_row = session.narrative.catalog.data.texts[id].duplicate(true)
			break
	actor_row["scene_layers"] = []
	actor_row["clear_positions"] = true
	actor_row["position"] = "left"
	page.stage.apply_record(actor_row, session.narrative.catalog)
	check(page.stage.occupants.has(3) and not page.stage.occupants[3].node.flip_h, "实际朝左的伊万放右侧且不镜像")
	var occupant: Dictionary = page.stage.occupants.get(3, {})
	if not occupant.is_empty():
		var asset: Dictionary = page.stage.actor_assets[occupant.path]
		var image_scale: float = occupant.node.size.y / occupant.node.texture.get_size().y
		var scale_factor: float = minf(page.stage.size.x / 1600.0, page.stage.size.y / 900.0)
		var offset: Vector2 = (page.stage.size - Vector2(1600, 900) * scale_factor) / 2.0
		check(is_equal_approx(occupant.node.position.y + float(asset.visible_head_top_y_px) * image_scale, offset.y + 250 * scale_factor), "按实际头顶定位250而非透明画布")
		check(is_equal_approx(occupant.node.position.y + float(asset.dialogue_anchor_px[1]) * image_scale, offset.y + 900 * scale_factor), "膝上锚点贴有效画面底边")
	var inner_row: Dictionary = session.narrative.catalog.data.texts[inner_id].duplicate(true)
	inner_row["scene_layers"] = []
	inner_row["clear_positions"] = true
	inner_row["position"] = "center"
	page.stage.apply_record(inner_row, session.narrative.catalog)
	check(page.stage.occupants.is_empty(), "心声即使误填制作路径也不调出前景人物")
	await check_playback()
	page.queue_free()
	session.queue_free()
	await frames()
	print("FINAL_NARRATIVE_UI_PASS: %d checks" % checks if failures.is_empty() else "FINAL_NARRATIVE_UI_FAIL: %d / %d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)

func check_playback() -> void:
	var service := Narrative.new()
	root.add_child(service)
	var sounds: Array[String] = []
	var finishes: Array[String] = []
	service.typing_sound_requested.connect(func(id): sounds.append(id))
	service.text_finished.connect(func(row): finishes.append(str(row.text_id)))
	check(service.initialize({"texts": {"A": {"text_id": "A", "text": "甲乙丙丁戊己", "text_kind": "dialogue", "read_version": 1}, "B": {"text_id": "B", "text": "冬夜\n大厅", "text_kind": "time_caption", "read_version": 1}}, "transitions": {}}), "独立文案节奏夹具")
	check(service.start("A"), "逐字测试起句")
	service.set_page_ends([3, 6])
	service.tick(0.034)
	check(service.visible_text() == "甲" and sounds == ["SFX_TEXT_DIALOGUE"], "仅真实新增字符请求对白字音")
	check(service.advance() and service.visible_text() == "甲乙丙" and finishes.is_empty() and sounds.size() == 1, "点击仅快显当前页，无补声与完成回执")
	check(service.advance() and service.state.page_start == 3 and service.visible_text().is_empty(), "再次点击才翻页")
	service.advance()
	check(finishes.is_empty() and service.visible_text() == "丁戊己", "末页快显仍未完成")
	service.advance()
	check(finishes == ["A"], "离开末页只提交一次完成")
	service.start("B")
	service.tick(0.034)
	check(sounds.back() == "SFX_TEXT_TIME_LOCATION", "时地字符消费独立声音ID")
	var count := sounds.size()
	service.set_hidden(true)
	service.tick(1)
	check(sounds.size() == count, "隐藏不新增声音")
	service.set_hidden(false)
	service.state.seen_at_start = true
	service.begin_fast_read("skip")
	service.tick(0.04)
	check(sounds.size() == count, "跳过不补播整句声音")
	service.queue_free()
	await process_frame
