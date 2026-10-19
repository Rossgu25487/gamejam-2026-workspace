extends SceneTree
## 真实读件、证言选择、单卡出示与逐句回应，验证L09不受旧口述阅读顺序锁死。
var session: Node
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("_run")
func _check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text); printerr(text)
func _context(scene: String) -> Dictionary:
	session.case_state.data.scene = scene
	session.case_state.data.view = str(session.config.scenes[scene].default_view_id)
	return {"kind": "scene", "scene": scene, "view": session.case_state.data.view}
func _drain() -> bool:
	for i in range(300):
		if session.mode == "investigation": return true
		if session.mode == "material":
			if not session.material_read_complete(): return false
		elif session.mode == "narrative":
			session.narrative.tick(100)
			if session.narrative.state.waiting_for_choice:
				if not session.narrative.choose_transition(0): return false
			elif not session.narrative.advance(): return false
		else: return false
	return false
func _read_documents() -> void:
	# 仅隔离夹具的已开案/已发现文书前置；文书本身必须真实打开与读完。
	session.case_state.data.events["EV_CASE_INVESTIGATION_OPEN"] = true
	session.case_state.data.events["EV_BAG_DOCUMENTS_VIEWED"] = true
	_check(session.activate_entry("ENTRY_CH03_READ_E13", _context("SC04")), "实际打开E13")
	_check(_drain(), "实际读完E13及艾琳观察")
	_check(session.activate_entry("ENTRY_CH03_READ_E17", _context("SC04")), "实际打开E17")
	_check(_drain(), "实际读完E17")
	_check(session.case_state.owns("E13_V1") and session.case_state.owns("E17_V1"), "文书阅读回执取得初版")
func _counter_topic_case() -> void:
	session.case_state.reset()
	session.narrative.end_reading()
	session.mode = "investigation"
	session.case_state.data.chapter = "CH02"
	session.case_state.data.events["EV_CASE_INVESTIGATION_OPEN"] = true
	session.case_state.data.npc["CHR04"] = {"scene_id": "SC02"}
	session.case_state.data.npc["CHR10"] = {"scene_id": "SC02"}
	var context := _context("SC02")
	context.merge({"kind": "topics", "object": "CHR04", "topics": "TOPICS_1000004_SC02"}, true)
	var investigation := preload("res://systems/aurora/aurora_investigation.gd").new()
	investigation.bind(session)
	var topics: Array = investigation.topics("TOPICS_1000004_SC02").filter(func(row): return row.entry_ref == "ENTRY_CH02_IVAN_T04_FIRST")
	_check(topics.size() == 1 and topics[0].public_name == "从厨房出来后在柜台对货单", "伊万真实话题显示柜台对单口述")
	session.case_state.data.npc["CHR10"] = {"scene_id": "SC10"}
	_check(investigation.topics("TOPICS_1000004_SC02").all(func(row): return row.entry_ref != "ENTRY_CH02_IVAN_T04_FIRST"), "基里尔不在大厅时不隔空接话")
	session.case_state.data.npc["CHR10"] = {"scene_id": "SC02"}
	_check(not session.case_state.event("EV_SIXTH_COUNTER_CLAIMS_HEARD", {}), "没有实际读完口述不能提前提交T04/T05")
	_check(not session.case_state.owns("T04_V1") and not session.case_state.owns("T05_V1"), "提前回执拒绝且不发卡")
	_check(session.activate_entry(str(topics[0].entry_ref), context), "实际选择公开话题打开已有正式正文")
	var actual_texts: Array[String] = []
	for i in range(20):
		if session.mode != "narrative": break
		var id: String = str(session.narrative.state.current_text_id)
		actual_texts.append(id)
		if id == "F7_CH02_IVAN_T04_FIRST_006":
			_check(not session.case_state.owns("T04_V1") and not session.case_state.owns("T05_V1"), "末句未读完不提前取得两份证言")
		session.narrative.tick(100)
		if not session.narrative.advance(): break
	_check(actual_texts == ["F7_CH02_IVAN_T04_FIRST_001", "F7_CH02_IVAN_T04_FIRST_002", "F7_CH02_IVAN_T04_FIRST_003", "F7_CH02_IVAN_T04_FIRST_004", "F7_CH02_IVAN_T04_FIRST_005", "F7_CH02_IVAN_T04_FIRST_006"], "实际逐句读完交付的六行口述")
	_check(session.case_state.owns("T04_V1") and session.case_state.owns("T05_V1"), "末句完成后原有事件取得T04/T05初版")
	_check(session.case_state.data.events.get("EV_T04_COUNTER_ACCOUNT_HEARD", false) and session.case_state.data.events.get("EV_T05_COUNTER_CLAIM_HEARD", false), "两人证言回执由实际末句提交")
	_check(investigation.topics("TOPICS_1000004_SC02").all(func(row): return row.entry_ref != "ENTRY_CH02_IVAN_T04_FIRST"), "已听完首次口述后收起首次话题")
	var count: int = session.case_state.data.materials.size()
	_check(session.case_state.event("EV_SIXTH_COUNTER_CLAIMS_HEARD", {}) and session.case_state.data.materials.size() == count, "重复完成不重复新增证言材料")
func _heard_yuri_before() -> void:
	# 读真实L07证言后提交其公开口述回执，绝不将所有事件设true。
	# 第二章的最后供述仍沿真实末句回执取得T03，不把供述完成直接写成true。
	session.case_state.data.events["EV_GUESTROOM_SEARCH_ALLOWED"] = true
	_check(session.activate_entry("ENTRY_CH02_HANDKERCHIEF", _context("SC07")) and _drain(), "实际发现手帕以满足当晚供述的材料前置")
	_check(session.case_state.data.events.get("EV_E11_FOUND", false), "手帕发现由调查正文回执确认")
	_check(session.activate_entry("F7_CH02_L01_BODY_RESPONSE", _context("SC07")), "实际读取尤里当晚收尾供述")
	_check(_drain(), "读完当晚供述取得后续关联前置")
	_check(session.case_state.data.events.get("EV_YURI_CURRENT_ACTIONS_CONFIRMED", false), "当晚行动由正文末句确认")
	_check(session.activate_entry("ENTRY_CH03_YURI_1957", _context("SC07")), "实际打开尤里旧案入口")
	for i in range(200):
		if session.mode == "selection": break
		if session.mode != "narrative": break
		session.narrative.tick(100)
		if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
		else: session.narrative.advance()
	_check(session.mode == "selection", "实际读完尤里首段到追问")
	# L07无需出示，只逐条追问并继续至后段。
	for step in range(2000):
		if session.mode == "investigation": break
		if session.mode == "selection":
			if session.can_continue_question():
				if not session.continue_question(): _check(false, "L07追问完成后无法接续：" + session.last_notice); break
				continue
			if session.question == "L07_R02":
				var solved := false
				for relation in session.config.relations:
					if relation.question_ref != session.question or not session.condition(str(relation.get("condition_ref", ""))): continue
					if session.config.results[relation.result_ref].feedback_key not in ["support", "exclude", "inference"]: continue
					var a := str(relation.get("a_content_ref", ""))
					var b := str(relation.get("b_content_ref", ""))
					if not session.case_state.owns(a) or not session.case_state.owns(b): continue
					session.select_statement(str(relation.target_text_ref)); session.select_target()
					session.select_content(a); session.select_content(b)
					if session.present(): solved = true; break
				if not solved: break
				continue
			var pressed := false
			for statement in session.statement_options():
				if not statement.heard or not session.select_statement(str(statement.id)): continue
				for press in session.config.narrative_bindings("statement_bindings"):
					if press.question_id != session.question or press.target_text_ref != statement.id: continue
					if session.case_state.data.events.get(str(press.get("press_completion_event_ref", "")), false): continue
					if session.press_statement(): pressed = true; break
				if pressed: break
			if not pressed: break
		elif session.mode == "narrative":
			session.narrative.tick(100)
			if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
			else: session.narrative.advance()
		elif session.mode == "material": session.material_read_complete()
		elif session.mode == "result":
			if session.pending_result.get("effect_pending", false): session.finish_result_effect()
			elif not session.pending_result.get("response_read", false): session.read_result_response()
			elif not session.pending_result.get("accepted", false) and not str(session.config.results[session.pending_result.result].get("inference_content_ref", "")).is_empty(): session.accept_inference()
			else: session.continue_result()
		else: break
	_check(session.case_state.data.events.get("EV_YURI_OLD_WAIT_ACCOUNT_HEARD", false), "实际尤里旧案口述链完成：" + str(session.question) + " / " + session.last_notice)
func _l09_case(yuri_first: bool) -> void:
	session.case_state.reset()
	session.narrative.end_reading()
	session.mode = "investigation"
	session.processing = false
	session.pending_result.clear()
	session.response_after.clear()
	session.call_stack.clear()
	session.question_reading.clear()
	session.contextual_presentation.clear()
	session.question = ""
	session.current_statement = ""
	session.active_entry = ""
	session.response_active = false
	session.arrival_pending = false
	session.slots = ["", ""]
	session.active_slot = -1
	session.selected_target = false
	session.case_state.data.chapter = "CH03"
	session.case_state.data.npc["CHR03"] = {"scene_id": "SC03"}
	session.case_state.data.npc["CHR04"] = {"scene_id": "SC02"}
	_read_documents()
	_check(session.activate_entry("ENTRY_CH03_READ_E18", _context("SC04")) and _drain(), "实际读完E18以验证后续调卷门槛")
	_context("SC02")
	_check(not session.condition("COND_TOPIC_IVAN_LATER_FILES"), "E18已读但登记未核实时不开放L10")
	_check(not session.case_state.event("EV_F7_CH03_REGISTER", {}), "没有真实证言和回应不可提前提交L09")
	_check(not session.case_state.owns("T18_V1") and not session.case_state.owns("E17_V2"), "提前提交失败不发卡")
	if yuri_first: _heard_yuri_before()
	_check(session.activate_entry("ENTRY_CH03_REGISTER_WRITER", _context("SC03")), "实际向尼娜问登记")
	for i in range(200):
		if session.mode != "narrative": break
		session.narrative.tick(100)
		if not session.narrative.advance(): break
	_check(session.mode == "selection", "实际读完三句证言到选材")
	_check(session.select_statement("TXT_F7_CH03_ENTRY_F7_CH03_L09_R01_S3_001") and session.select_target() and session.select_content("E13_V1"), "选中第三句并放E13单卡")
	_check(session.present(), "E13单卡真实出示成功")
	_check(not session.case_state.owns("T18_V1") and not session.case_state.owns("E17_V2"), "出示后回应未读不发卡")
	session.finish_result_effect()
	_check(not session.pending_result.get("effect_pending", false), "完成实际结果表现回执")
	_check(session.read_result_response(), "打开九句回应")
	for i in range(100):
		if session.mode != "narrative" or session.narrative.state.current_text_id == "TXT_F7_CH03_ENTRY_F7_CH03_L09_RESPONSE_009": break
		session.narrative.tick(100)
		if not session.narrative.advance(): break
	_check(not session.case_state.owns("T18_V1") and not session.case_state.owns("E17_V2"), "末句尚未读完不发卡")
	var saved_scene: String = str(session.case_state.data.scene)
	_context("SC02")
	_check(not session.condition("COND_TOPIC_IVAN_LATER_FILES"), "回应末句未读完仍不能跳到L10")
	_context(saved_scene)
	session.narrative.tick(100)
	_check(session.narrative.advance(), "末句完成可提交登记原子事件")
	_check(session.case_state.owns("T18_V1") and session.case_state.owns("E17_V2"), "实际回应结束取得T18更新E17")
	_check(session.case_state.data.events.get("EV_REGISTER_ACCOUNT_CONFIRMED", false), "真实登记确认已完成")
	_check(bool(session.case_state.data.events.get("EV_YURI_OLD_WAIT_ACCOUNT_HEARD", false)) == yuri_first, "L09不会虚构听过尤里")
	if session.mode == "result": session.continue_result()
	_context("SC02")
	_check(session.condition("COND_TOPIC_IVAN_LATER_FILES"), "完成L09后伊万调卷话题开放")
	var count: int = session.case_state.data.materials.size()
	_check(session.case_state.event("EV_F7_CH03_REGISTER", {}) and session.case_state.data.materials.size() == count, "重复完成幂等")
func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "正式十二册初始化")
	_counter_topic_case()
	_l09_case(false)
	_l09_case(true)
	print("FINAL_EVENT_CHAIN ", failures.is_empty(), " checks=", checks)
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
