extends SceneTree
## 最终新增接口的行为边界；夹具只准备本题世界，阅读与结果使用真实回执。
var s: Node
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FINAL_BEHAVIOR: " + message)
func fresh(scene := "SC02", chapter := "CH02") -> void:
	s.case_state.reset()
	s.case_state.data.chapter = chapter
	s.set_scene(scene)
	s.run_id = "final-behavior"
	s.mode = "investigation"
	s.processing = false
	s.pending_result.clear(); s.response_after.clear(); s.call_stack.clear(); s.question_reading.clear()
	s.contextual_presentation.clear(); s.question = ""; s.current_statement = ""
	s.response_active = false; s.arrival_pending = false
	s.requested_destination = ""; s.departure_ready_destination = ""; s.departure_managed = false
	s.active_entry = ""
	s.return_context = {"kind":"scene", "scene":scene, "view":s.case_state.data.view}
	s.narrative.state = {}; s.narrative.seen_versions.clear()
func drain() -> void:
	for i in range(1200):
		if s.mode != "narrative": return
		s.narrative.tick(100)
		if s.narrative.state.waiting_for_choice: s.narrative.choose_transition(0)
		else: s.narrative.advance()
	check(false, "阅读形成循环 " + s.active_entry)
func run() -> void:
	s = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(s); s.seen_storage_path = ""
	check(s.initialize(), "读取最终包")
	if not failures.is_empty(): quit(1); return
	fresh("SC07")
	s.active_entry = str(s.config.questions.L01_R01.entry_ref)
	check(s.open_question("L01_R01") and s.mode == "narrative", "未听证言必须逐句阅读")
	check(not s.select_target(), "阅读中不能先选原话")
	drain()
	var refs: Array = s.question_binding().statement_refs
	check(s.mode == "selection" and refs.all(func(id): return s.case_state.data.texts.get(id,false)), "实际读完全部原句后才选材")
	s.case_state.grant("E01_V1", {})
	check(s.select_content("E01_V1") and s.select_statement(str(refs[2])) and s.select_target(), "选择第三句和真实材料")
	var draft: Array = s.slots.duplicate()
	var chances: int = s.case_state.data.chances[s.question]
	check(s.press_statement(), "启动该句实际追问")
	check(not s.case_state.data.events.get("EV_F7_CH02_L01_R01_PRESS_3",false), "追问未读完不提交")
	drain()
	check(s.mode == "selection" and s.current_statement == refs[2] and s.slots == draft and s.selected_target, "追问回同句并保留草稿")
	check(s.case_state.data.events.get("EV_F7_CH02_L01_R01_PRESS_3",false) and s.case_state.data.chances[s.question] == chances, "追问和出示容错分开记账")
	check(s.validate_snapshot(s.export_snapshot()), "逐句及草稿快照有效")
	fresh("SC02", "CH03")
	s.active_entry = str(s.config.questions.L11_R03.entry_ref)
	check(s.open_question("L11_R03"), "打开刀与钱原句")
	check(not s.case_state.owns("T11_V2_KNIFE"), "尚未听完不能更新T11")
	drain()
	check(s.case_state.owns("T11_V2_KNIFE") and s.case_state.data.materials.has("T11"), "读到摆放关系才更新同一T11")
	fresh()
	var group: Dictionary = s.config.narrative_bindings("text_page_groups")[0]
	var owner := str(group.text_id)
	s.mode = "narrative"
	s.narrative.show_text(owner)
	s.narrative.tick(100); s.narrative.advance()
	check(not s.case_state.data.texts.get(owner,false) and not s.narrative.seen_versions.has(owner), "分页第一段不提前登记原身份已读")
	for i in range(60):
		if s.case_state.data.texts.get(owner,false): break
		s.narrative.tick(100); s.narrative.advance()
	check(s.case_state.data.texts.get(owner,false) and s.narrative.seen_versions.has(owner), "分页末页提交原身份已读")
	fresh("SC02", "CH03")
	for i in range(4): check(not s.complete_cat_interaction(), "前四次无奖励观察")
	check(s.case_state.data.cat_pet_completed_count == 4 and not s.case_state.owns("E27_V1"), "四次没有奖励材料")
	check(s.complete_cat_interaction() and s.case_state.data.cat_pet_completed_count == 5 and s.mode == "narrative", "第五次接观察")
	check(not s.case_state.owns("E27_V1"), "第五次计数不提前发卡")
	drain()
	check(s.case_state.owns("E27_V1") and s.mode == "investigation", "三页观察实际读完取得E27")
	check(s.case_state.data.cat_pet_completed_count == 5, "计数封顶五次")
	fresh("SC09")
	s.case_state.data.events.EV_CH02_HANDOVER_FINISHED = true
	var bridge := preload("res://systems/aurora/aurora_map_bridge.gd").new()
	root.add_child(bridge); bridge.bind(s)
	var map := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(map); map.bind_core(bridge); map.configure(bridge.definition()); map.initialize("SC09"); map.bind_visual_controller()
	check(map.open() and map.select_scene("SC02") and map.travel(), "建立有离场对白的地图请求")
	map.complete_preparation(str(map.state.active_request.request_id))
	check(map.state.phase == "departure" and not map.state.open and s.case_state.data.scene == "SC09", "地图挂起呈现原地对白，不提前传送")
	check(s.cancel_inspection() and map.state.phase == "failure" and s.case_state.data.scene == "SC09", "取消离场保持原上下文")
	check(map.open() and map.select_scene("SC02") and map.travel(), "取消后可重新前往")
	map.complete_preparation(str(map.state.active_request.request_id)); drain()
	check(map.state.phase == "moving" and map.state.open and s.case_state.data.scene == "SC09", "离场完整结束才继续棋子移动")
	check(map.finish_movement() and s.case_state.data.scene == "SC02", "棋子移动成功后才落目的地")
	map.begin_transition(); map.finish_transition()
	map.queue_free(); bridge.queue_free()
	fresh("SC02", "CH06")
	var offer: Dictionary = s.config.narrative_bindings("material_presentation_bindings")[0]
	check(not s.activate_entry(str(offer.response_entry_ref)), "普通话题不能绕过实际出示")
	s.case_state.data.npc[str(offer.actor_id)] = {"scene_id":"SC02"}
	s.case_state.grant(str(offer.content_id), {})
	# 仅准备该情境明确要求的事件，不伪造完成回执。
	for terms in s.config.conditions[str(offer.condition_ref)].values():
		for term in terms:
			if term.kind == "event": s.case_state.data.events[str(term.ref)] = term.expected
	check(s.present_material_to(str(offer.actor_id), str(offer.content_id)), "现场实际出示准确E22版本可进入回应")
	check(not s.case_state.data.events.get(str(offer.completion_event_ref),false), "出示回应未读完不完成")
	drain()
	check(s.case_state.data.events.get(str(offer.completion_event_ref),false), "完整读完医院回应才提交完成")
	print("FINAL_BEHAVIOR ", failures.is_empty(), " checks=", checks)
	s.queue_free(); await process_frame
	quit(0 if failures.is_empty() else 1)
