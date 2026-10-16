extends SceneTree
## 直接读取用户实际工作簿的集成回归，不预制已完成进度。
var failures: Array[String] = []
var checks := 0
var session: Node
var core: Node
const P := "TEST_1014_"

func read_until(stop_id: String = "") -> void:
	for i in range(500):
		if session.narrative.state.get("finished", false) or session.narrative.state.get("waiting_for_choice", false) or session.narrative.state.get("current_text_id", "") == stop_id: break
		session.narrative.tick(1000)
		session.narrative.advance()
		await process_frame

func inspect(suffix: String, cancel: bool = false) -> void:
	var found := ""
	for id in session.scene_interaction.hotspots:
		if str(session.scene_interaction.hotspots[id].get("inspect_entry_ref", "")) == P + "ENTRY_" + suffix: found = id
	var request: Dictionary = session.scene_interaction.begin_inspection(found)
	check(request.get("ok", false), "开始检查 " + suffix)
	if not request.get("ok", false): return
	check(not session.can_save(), "检查中禁存")
	var result: Dictionary = session.scene_interaction.commit_inspection(request.request_id, not cancel)
	check(result.get("ok", false), "完成检查 " + suffix)

func select(suffix: String) -> void:
	check(core.select_material(core.catalog.material_ref(P + "C_" + suffix)), "选取准确版 " + suffix)

func solve(suffix: String, materials: Array, target: bool = false) -> Dictionary:
	check(core.open_card_session(P + suffix), "进入问题 " + suffix)
	if target: check(core.select_target(), "选择准确说法")
	for material in materials: select(material)
	var result: Dictionary = core.present_materials()
	check(not result.is_empty(), "出示有回应 " + suffix)
	core.finish_presentation()
	return result

func travel(suffix: String) -> void:
	check(session.map_navigation.open(), "打开地图")
	check(session.map_navigation.select_scene(P + suffix), "预览地点 " + suffix)
	check(session.map_navigation.travel(), "确认移动 " + suffix)
	check(core.state.current_scene_id == P + suffix, "成功切换 " + suffix)

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message); print("FAIL: ", message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	session = preload("res://systems/core_gameplay/game_session_service.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	var ok: bool = session.initialize_profile("res://data/system_test/profile.json")
	core = session.core
	check(ok, "配置包初始化：" + str(session.core.catalog.errors))
	if ok:
		session.start_new_game()
		check(session.scene_interaction.hotspots.size() == 6, "实际表6个调查热点")
		check(session.map_navigation.locations.size() == 2, "两地点绑定")
		check(session.prepare_new_game().ok, "真实载体就绪")
		check(session.cat_entries().size() == 1 and session.cat_entries()[0].enabled, "猫动作实际资源可读取")
		print("NARRATIVE: ", session.narrative.catalog.data.texts.size())
		# 开头从真实未读状态推进，同ID再读不得由测试写入seen。
		session.begin_opening()
		await read_until()
		check(session.narrative.state.waiting_for_choice and session.narrative.state.current_text_id == "5002097", "原三场与专用演示接到选择")
		check(session.narrative.choose_transition(0), "选择再读")
		check(session.narrative.state.current_text_id == "5002096" and session.narrative.fast_read_available(), "真实完整已读可加速")
		await read_until()
		session.narrative.choose_transition(1)
		check(session.narrative.state.get("finished", false), "主动开始交接")
		await process_frame
		check(session.can_save(), "调查输入交还")
		check(session.activate_entry(P + "ENTRY_TALK"), "普通交谈进入文案")
		check(not core.store.owns(core.catalog.material_ref(P + "C_HANDOFF_1")), "半句前不发材料")
		await read_until()
		await process_frame
		check(core.store.owns(core.catalog.material_ref(P + "C_HANDOFF_1")), "完整交谈才取得交接单")
		check(core.store.owns(core.catalog.material_ref(P + "C_WITNESS_1")), "交谈取得原话材料")
		await inspect("RECEIPT", true)
		check(session.scene_interaction.state.observations.is_empty(), "取消检查不提交")
		await inspect("RECEIPT")
		await inspect("RECEIPT") # 显式补查，取得第二版。
		await inspect("DOORLOG")
		await inspect("RED")
		check(core.store.owns(core.catalog.material_ref(P + "C_HANDOFF_2")), "主动补查取得第二版")
		var result: Dictionary = solve("Q01", ["HANDOFF_1"])
		check(result.get("feedback") == "full" and P + "Q01" not in core.state.completed_questions, "Q01支持尚待继续")
		check(core.continue_result(), "Q01正常继续提交")
		check(P + "Q01" in core.state.completed_questions, "Q01确认")
		check(session.map_navigation.open(), "地图可打开")
		session.map_navigation.select_scene(P + "BACK")
		check(not session.map_navigation.travel_disabled_reason().is_empty() and not session.map_navigation.travel(), "后室已知不可达")
		session.map_navigation.close()
		result = solve("Q02", ["WITNESS_1"], true)
		check(result.get("feedback") == "insufficient", "原话本身不足且不扣次")
		core.continue_result("reselect")
		core.withdraw_material()
		select("DOORLOG_1")
		select("HANDOFF_1")
		result = core.present_materials()
		check(result.get("feedback") == "full" and P + "Q02" in core.state.completed_questions, "Q02进入更正时确认")
		check(result.get("used_sources", []).size() == 1, "Q02只以门禁为实际依据")
		core.finish_presentation()
		check(core.continue_result(), "Q02继续解锁移动")
		check(session.activate_entry(P + "ENTRY_CORRECTION"), "补谈可进入")
		await read_until()
		await process_frame
		check(core.store.owns(core.catalog.material_ref(P + "C_WITNESS_2")), "补谈保留证言第二版")
		travel("BACK")
		await inspect("ROUTE")
		await inspect("BLUEBOX")
		check(not session.scene_interaction.state.object_visibility.get(P + "BLUEBOX_OBJECT", true), "蓝盒成功取走隐藏")
		travel("FRONT")
		travel("BACK")
		check(not session.scene_interaction.state.object_visibility.get(P + "BLUEBOX_OBJECT", true), "重访蓝盒保持取走")
		check(core.open_card_session(P + "Q03"), "进入Q03稳定选材")
		select("HANDOFF_1")
		select("ROUTE_1")
		var saver := preload("res://systems/save_load/save_load_service.gd").new()
		root.add_child(saver)
		saver.storage_path = "user://system-test-regression/%d" % Time.get_ticks_usec()
		saver.snapshot_validator = session.validate_snapshot
		check(session.can_save() and saver.save_snapshot("manual", 0, session.export_snapshot()), "S0真实写入磁盘")
		core.withdraw_material(0)
		select("HANDOFF_2")
		var s0: Dictionary = saver.load_snapshot("manual", 0)
		check(session.restore_snapshot(s0), "S0实际读回")
		check(core.draft().slots[0].content_id == P + "C_HANDOFF_1", "读回准确初版槽位")
		core.withdraw_material(0)
		result = core.present_materials()
		core.finish_presentation()
		check(result.get("feedback") == "partial", "流转单独局部成立")
		result = core.supplement_source(P + "C_HANDOFF_2")
		core.finish_presentation()
		check(core.state.mode == "pending" and not core.store.owns(core.catalog.material_ref(P + "C_INFERENCE_1")), "共同充分进入未收推论")
		check(not session.can_save(), "未收禁存")
		check(core.collect_inference(result.get("result_id", ""), P + "C_INFERENCE_1"), "主动收下")
		core.finish_presentation()
		check(core.store.entities.size() == 6 and not session.can_save(), "仅6身份，已收未继续禁存")
		check(core.continue_result(), "推论继续回调查")
		check(session.can_save() and saver.save_auto(session.export_snapshot()), "稳定调查自动档真实写入")
		check(session.restore_snapshot(saver.load_snapshot("auto", 0)) and core.store.entities.size() == 6, "自动档完整恢复不重收")
		check(session.restore_snapshot(s0), "恢复S0执行失败支线")
		core.withdraw_material()
		select("RED_1")
		for expected in [2, 1, 0]:
			result = core.present_materials()
			core.finish_presentation()
			check(core.state.chances.get(P + "Q03") == expected and result.get("feedback") == "incorrect", "明确错误扣次到%d" % expected)
			if expected > 0: core.continue_result("reselect")
		check(not session.can_save() and core.state.mode == "failure", "归零失败禁存")
		core.continue_result("defer")
		core.open_card_session(P + "Q03")
		check(core.state.mode == "failure" and core.state.chances[P + "Q03"] == 0, "重进不补容错")
		check(core.retry_question(), "主动重试恢复3次")
		core.finish_presentation()
		select("HANDOFF_2")
		select("ROUTE_1")
		result = core.present_materials()
		core.finish_presentation()
		core.collect_inference(result.get("result_id", ""), P + "C_INFERENCE_1")
		core.finish_presentation()
		core.continue_result()
		check(session.start_closing(), "达成条件主动收束")
		await read_until()
		await process_frame
		check(session.narrative.state.get("return_action") == "ending", "原结尾接至片尾待配边界")
		saver.queue_free()
	session.queue_free()
	await process_frame
	print("System test package: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
