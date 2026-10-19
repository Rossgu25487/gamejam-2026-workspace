extends SceneTree
## 最终首章按实际入口贯通，材料、原话与推论均走公开回执。
var s: Node
var failures: Array[String] = []
var trace: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); printerr(message + " / " + s.last_notice)
func run() -> void:
	s = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(s)
	s.seen_storage_path = ""
	check(s.initialize(), "载入最终包")
	check(s.new_game(), "开始新游戏")
	drain()
	check(s.case_state.data.scene == "SC01", "开场站外")
	check(not s.case_state.data.events.get("EV_CH01_RECEPTION_DONE", false), "开场不自动进站")
	entry("ENTRY_CH01_SIGN")
	move("SC02")
	move("SC06")
	entry("ENTRY_CH01_READ_E01")
	check(s.case_state.owns("E01_V1"), "实际读清单后取得")
	move("SC02")
	check(s.case_state.data.events.get("EV_T00_COMPLETED", false), "完成两轮T00")
	check(s.case_state.owns("P06_V1"), "主动收下教程推论")
	check(s.case_state.data.events.get("EV_SHARED_MEAL_FINISHED", false), "核档货单及回信后共餐")
	move("SC05")
	move("SC08")
	check(s.case_state.data.chapter == "CH01", "走进房间不自动休息")
	entry("ENTRY_CH01_REST")
	if s.case_state.data.chapter == "CH01" and s.case_state.data.scene == "SC08": move("SC09")
	if s.case_state.data.chapter == "CH01" and s.case_state.data.scene == "SC09": move("SC02")
	check(s.case_state.data.chapter == "CH02", "主动休息与报警后进入第二章")
	check(s.case_state.errors.is_empty(), "条件及事件枚举受支持")
	check(s.validate_snapshot(s.export_snapshot()), "贯通后快照有效")
	print("FINAL_CHAPTER ", failures.is_empty(), " ", s.case_state.data.chapter, " / ", s.case_state.data.scene)
	if not failures.is_empty(): print("TRACE ", trace)
	s.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
func entry(id: String) -> void:
	trace.append("ENTRY " + id)
	check(s.activate_entry(id, {"kind":"scene", "scene":s.case_state.data.scene, "view":s.case_state.data.view}), "打开 " + id)
	drain()
func move(id: String) -> void:
	trace.append("MOVE " + id)
	check(s.travel(id), "前往 " + id)
	if s.mode == "investigation": s.arrive()
	drain()
func drain() -> void:
	for step in range(2500):
		match str(s.mode):
			"narrative":
				var id := str(s.narrative.state.get("current_text_id", ""))
				if trace.is_empty() or trace.back() != id: trace.append(id)
				s.narrative.tick(100)
				if s.narrative.state.waiting_for_choice:
					if not s.narrative.choose_transition(0): check(false,"选项不能继续"); return
				else: s.narrative.advance()
			"material":
				if not s.material_read_complete(): check(false,"原件读完失败"); return
			"selection":
				var chosen := false
				for relation in s.config.relations:
					if relation.question_ref != s.question or not s.condition(str(relation.get("condition_ref", ""))): continue
					if s.config.results[relation.result_ref].feedback_key not in ["support","exclude","inference"]: continue
					var refs: Array = []
					for key in ["a_content_ref","b_content_ref","basis_content_ref"]:
						if not str(relation.get(key, "")).is_empty(): refs.append(str(relation[key]))
					if not refs.all(func(ref): return s.case_state.owns(ref)): continue
					s.current_statement = str(relation.target_text_ref)
					s.clear_slot(0); s.clear_slot(1)
					if not s.select_target(): continue
					for key in ["a_content_ref","b_content_ref"]:
						if not str(relation.get(key, "")).is_empty(): s.select_content(str(relation[key]))
					chosen = s.present()
					if chosen: break
				if not chosen: check(false,"当前问题无合法解 " + s.question); return
			"result":
				if s.pending_result.get("effect_pending",false): s.finish_result_effect(); continue
				var result: Dictionary = s.config.results.get(s.pending_result.get("result",""),{})
				if not s.pending_result.get("response_read",false):
					if not s.read_result_response(): check(false,"回应不能开始 " + s.question); return
				elif not str(result.get("inference_content_ref","")).is_empty() and not s.pending_result.get("accepted",false):
					if not s.accept_inference(): check(false,"推论不能收下"); return
				elif not s.continue_result(): check(false,"结果不能继续"); return
			"investigation","credits": return
			_: check(false,"非法状态 " + s.mode); return
	check(false,"接续循环 " + s.active_entry)
