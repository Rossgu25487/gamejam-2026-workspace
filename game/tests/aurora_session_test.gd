extends SceneTree
## 用正式表沿玩家动作走第一章；不直接造事件或跳过原件阅读。
var failures: Array[String] = []
var session: Node
func _init() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); printerr(message)

func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "正式配置应可载入")
	if not failures.is_empty(): quit(1); return
	_check(session.new_game(), "新游戏应可开始")
	_drain()
	_check(session.mode == "investigation" and session.case_state.data.scene == "SC01", "开场应回到站外调查")
	_check(session.validate_snapshot(session.export_snapshot()), "初始自动档必须可校验")
	_call("ENTRY_CH01_ENTER")
	_check(session.case_state.data.scene == "SC06", "接待后选择去休息室")
	_check(not session.case_state.owns("E01_V1"), "尚未阅读清单不能获得E01")
	_check(session.activate_entry("ENTRY_CH01_READ_E01"), "清单调查入口应可用")
	_drain(false)
	_check(session.mode == "material" and not session.case_state.owns("E01_V1"), "打开原件不能提前获卡")
	_check(session.material_read_complete(), "清单完成阅读回执")
	_drain()
	_check(session.case_state.owns("E01_V1"), "实际读完才取得清单")
	_move("SC02")
	_check(session.case_state.data.events.get("EV_SHARED_MEAL_FINISHED", false), "返回大厅应接上共餐")
	_call("TALK_CH01_MAIN_1")
	_call("TALK_CH01_MAIN_2")
	_call("ENTRY_CH01_E05_READER")
	_check(session.case_state.data.events.get("EV_CH01_MAIN_2_DONE", false), "交接登记阅读后的交谈应完成第二主要话题")
	_move("SC06")
	_call("TALK_CH01_MAIN_3")
	_check(session.condition("COND_CH01_REST_AVAILABLE"), "三项主要交谈完成才允许休息")
	# 先在大厅实际读一句，再到卧室点床；菜单舞台不能继承上一段大厅对话。
	_move("SC02")
	for row in session.config.rows("investigation", "入口绑定"):
		if row.get("scene_id") == "SC02" and row.get("purpose") == "scene_observation":
			_call(str(row.entry_ref))
			break
	_check(session.narrative.current_record().get("scene_id") == "SC02", "回归前应留下大厅对话舞台")
	_move("SC08")
	_check(session.case_state.data.chapter == "CH01", "走进房间不能自行推进案发")
	var model := preload("res://systems/aurora/aurora_investigation.gd").new()
	model.bind(session)
	var beds: Array = model.hotspots().filter(func(row): return row.object_ref == "OBJ_SC08_BED")
	_check(beds.size() == 1, "艾琳房间应有唯一床热点")
	if beds.is_empty(): session.queue_free(); quit(1); return
	_check(model.inspect(beds[0]), "实际床热点应打开休息菜单")
	_check(session.mode == "narrative" and session.narrative.state.waiting_for_choice, "点击床应等待玩家选择")
	_check(session.case_state.data.scene == "SC08" and session.case_state.data.chapter == "CH01", "未选休息不移动地点也不推进章节")
	_check(session.narrative.current_record().get("scene_id") == "SC08", "床菜单舞台必须使用当前卧室")
	_check(str(session.narrative.current_record().get("background_path", "")).contains("SC08_"), "床菜单背景不能保留大厅图片")
	_check(session.narrative.current_record().get("clear_positions", false), "床菜单清除上段对话人物")
	_check(session.narrative.current_text().is_empty() and "__CONTROL__" not in session.narrative.state.history, "控制菜单不展示入口名也不写入已听原话")
	_check(session.validate_snapshot(session.export_snapshot()), "床菜单快照应仍可校验")
	var wait_choice: int = session.narrative.available_choices.find_custom(func(row): return session.choice_label(row) == "再待一会儿")
	_check(wait_choice >= 0 and session.narrative.choose_transition(wait_choice), "再待一会儿应返回卧室")
	_check(session.mode == "investigation" and session.case_state.data.scene == "SC08", "取消休息留在卧室调查")
	_check(model.inspect(beds[0]), "返回卧室后可再次点床")
	_drain()
	_check(session.case_state.data.chapter == "CH02", "主动休息后推进案发并开放调查")
	_check(session.case_state.errors.is_empty(), "正式事件不能含未支持动作")
	_check(session.validate_snapshot(session.export_snapshot()), "案发后快照必须通过完整性检查")
	print("AURORA_SESSION ", failures.is_empty(), " chapter=", session.case_state.data.chapter, " scene=", session.case_state.data.scene)
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _call(id: String) -> void:
	_check(session.activate_entry(id), "入口不可用：" + id)
	_drain()

func _move(id: String) -> void:
	_check(session.travel(id), "前往失败：" + id)
	session.arrive()
	_drain()

func _drain(read_material: bool = true) -> void:
	for i in range(1000):
		if session.mode == "material":
			if not read_material: return
			_check(session.material_read_complete(), "原件阅读回执失败")
			continue
		if session.mode != "narrative": return
		session.narrative.tick(100)
		if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
		else: session.narrative.advance()
	failures.append("正式接续超过1000步，可能形成循环：" + session.active_entry)
