extends SceneTree
## 关系单元回归：按正式条件构建独立夹具；流程贯通另由session测试验证。
const Session = preload("res://systems/aurora/aurora_session.gd")
var failures: Array[String] = []
var session: Node
func _init() -> void: call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); printerr(message)

func _run() -> void:
	session = Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "正式配置载入")
	var count := 0
	for relation in session.config.relations:
		session.case_state.reset()
		session.pending_result.clear()
		session.response_active = false
		session.question = ""
		session.question_reading.clear()
		session.active_slot = -1
		session.narrative.state = {}
		_condition(str(relation.get("condition_ref", "")))
		var q := str(relation.question_ref)
		var round: Dictionary = session.config.questions[q]
		var scene := str(session.case_state.data.scene)
		var response: Dictionary = session.config.entries.get(relation.get("response_entry_ref", ""), {})
		var scenes := str(response.get("allowed_scene_ids", "")).split(";", false)
		if not scenes.is_empty(): scene = scenes[0]
		session.set_scene(scene)
		session.return_context = {"kind": "scene", "scene": scene, "view": session.case_state.data.view}
		session.active_entry = str(round.entry_ref)
		session.case_state.data.texts[str(round.target_text_ref)] = true
		for ref in session.question_binding(q).get("statement_refs", []): session.case_state.data.texts[str(ref)] = true
		_check(session.open_question(q), "打开问题" + q)
		# 最终轮次可包含多个原句；每条关系必须选择其明确声明的目标，不能沿用轮次首句。
		var target := str(relation.get("target_text_ref", round.target_text_ref))
		session.case_state.data.texts[target] = true
		session.current_statement = target
		_check(session.select_target(), "选择目标" + q)
		for field in ["a_content_ref", "b_content_ref", "basis_content_ref"]:
			var content := str(relation.get(field, ""))
			if content.is_empty(): continue
			session.case_state.grant(content, {"fixture": relation.id})
			if field != "basis_content_ref": _check(session.select_content(content), "选材" + content)
		var before: Dictionary = session.case_state.data.duplicate(true)
		_check(session.present(), "出示" + str(relation.id))
		_check(session.pending_result.get("result") == relation.result_ref, "关系命中错误：" + str(relation.id) + " -> " + str(session.pending_result))
		_check(session.case_state.data.completed_questions == before.completed_questions, "出示不能提前提交成果")
		_check(session.case_state.data.chances.get(q, 3) == 3, "正式充分/不足关系不扣容错")
		count += 1
	# 明确禁止同一材料不同版本同时占两槽；拒绝尚未取得内容。
	session.case_state.reset()
	session.question_reading.clear()
	for ref in session.question_binding("L15_R04").get("statement_refs", []): session.case_state.data.texts[str(ref)] = true
	session.open_question("L15_R04")
	session.case_state.grant("E04_V1", {})
	session.case_state.grant("E04_V2", {})
	_check(session.select_content("E04_V1"), "历史版本可选用")
	_check(not session.select_content("E04_V2") and session.slots == ["E04_V1", ""], "同一材料已入槽必须先撤下")
	session.clear_slot(0)
	_check(session.select_content("E04_V2") and session.slots == ["E04_V2", ""], "撤下后可选用另一已获版本")
	_check(not session.select_content("E24_V1"), "未取得材料不能选用")
	print("AURORA_CORE ", failures.is_empty(), " relations=", count, " questions=", session.config.questions.size())
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _condition(id: String) -> void:
	if id.is_empty(): return
	var groups: Dictionary = session.config.conditions[id]
	for term in groups.values()[0]:
		var expected: bool = term.expected
		var ref := str(term.ref)
		match str(term.kind):
			"event": session.case_state.data.events[ref] = expected
			"text": session.case_state.data.texts[ref] = expected
			"content": if expected: session.case_state.grant(ref, {"fixture": id})
			"entry": session.case_state.data.entries[ref] = expected
			"chapter": if expected: session.case_state.data.chapter = ref
			"current_scene": if expected: session.case_state.data.scene = ref
			"npc_scene": session.case_state.data.npc[ref] = {"scene_id": term.scene_id if expected else "SC01"}
