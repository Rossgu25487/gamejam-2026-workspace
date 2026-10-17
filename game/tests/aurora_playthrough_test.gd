extends SceneTree
## 从正式公开入口探索可达内容；每个动作保留真实条件，遇到题目仅用实际取得的版本。
var session: Node
var attempted := {}
var signature := ""
var failures: Array[String] = []
var actions := 0
var visits := {}
var choice_visits := {}
var entry_scenes := {}
func _init() -> void: call_deferred("_run")
func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	if not session.initialize() or not session.new_game(): quit(1); return
	for step in range(20000):
		if not _drain(): break
		if session.mode == "credits": break
		if session.mode != "investigation": failures.append("未知停点：" + session.mode); break
		var current := "%s/%s/%s/%s" % [session.case_state.data.chapter, session.case_state.data.events, session.case_state.data.materials, session.case_state.data.texts.size()]
		if current != signature: signature = current; attempted.clear()
		var moved := false
		for id in _external():
			var row: Dictionary = session.config.entries[id]
			var scenes: Array = session.config.ids(str(row.get("allowed_scene_ids", "")))
			var scene: String = str(entry_scenes.get(id, scenes[0] if not scenes.is_empty() else str(session.case_state.data.scene)))
			var key := scene + "/" + str(id)
			if attempted.has(key) or not session.scene_status(scene).available: continue
			attempted[key] = true
			if scene != session.case_state.data.scene:
				if not session.travel(scene): continue
				if session.arrive(): moved = true; break
			if session.activate_entry(id, {"kind": "scene", "scene": scene, "view": session.case_state.data.view}):
				visits[id] = int(visits.get(id, 0)) + 1
				actions += 1
				print("PLAY ", actions, " ", session.case_state.data.chapter, " ", id)
				moved = true
				break
		if not moved:
			failures.append("无可推进入口：" + str(session.case_state.data.chapter))
			break
	if session.mode != "credits": failures.append("尚未走到正式片尾：" + session.last_notice)
	var diagnostic := FileAccess.open("res://../.local/aurora-playthrough-state.json", FileAccess.WRITE)
	if diagnostic: diagnostic.store_string(JSON.stringify(session.export_snapshot()))
	print("PLAY_END ", session.mode, " ", session.case_state.data.chapter, " completed=", session.case_state.data.completed_questions.keys(), " events=", session.case_state.data.events.keys(), " notice=", session.last_notice)
	for error in failures: printerr(error)
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

func _external() -> Array:
	var ids := {}
	entry_scenes.clear()
	var model := preload("res://systems/aurora/aurora_investigation.gd").new()
	model.bind(session)
	var old_scene: String = session.case_state.data.scene
	var old_view: String = session.case_state.data.view
	for scene in session.config.scenes:
		if not session.scene_status(scene).available: continue
		session.case_state.data.scene = scene
		session.case_state.data.view = session.config.scenes[scene].default_view_id
		for item in model.scene_options():
			ids[str(item.entry_ref)] = true
			entry_scenes[str(item.entry_ref)] = scene
		for hotspot in model.hotspots():
			var candidates: Array = model.observation_options(str(hotspot.object_ref)) if hotspot.object_kind != "character" else model.topics(str(hotspot.get("topic_entry_ref", "")))
			candidates.append({"entry_ref": hotspot.get("inspect_entry_ref", "")})
			for item in candidates:
				var id := str(item.entry_ref)
				if session.config.entries.has(id): ids[id] = true; entry_scenes[id] = scene
		for item in session.available_reasoning():
			ids[str(item.entry)] = true
			entry_scenes[str(item.entry)] = scene
		session.case_state.data.scene = old_scene
		session.case_state.data.view = old_view
	for row in session.config.rows("objective", "正式事项"):
		var goals: Array = session.config.rows("objective", "正式目标").filter(func(goal): return goal.goal_id == row.goal_id and session.condition(str(goal.get("condition_id", ""))))
		if goals.is_empty() or not session.condition(str(row.get("condition_id", ""))): continue
		if not str(row.get("completion_condition_id", "")).is_empty() and session.condition(str(row.completion_condition_id)): continue
		var id := str(row.get("target_ref", ""))
		if session.config.entries.has(id):
			ids[id] = true
			entry_scenes[id] = str(row.get("scene_id", ""))
	var ordered := ids.keys()
	ordered.sort_custom(func(a, b): return int(visits.get(a, 0)) < int(visits.get(b, 0)))
	return ordered

func _drain() -> bool:
	for step in range(2000):
		match str(session.mode):
			"narrative":
				session.narrative.tick(100)
				if session.narrative.state.waiting_for_choice:
					var choices: Array = session.narrative.available_choices
					var source: String = str(session.narrative.state.current_text_id) + session.active_entry
					var index := int(choice_visits.get(source, 0)) % choices.size()
					choice_visits[source] = int(choice_visits.get(source, 0)) + 1
					if not session.narrative.choose_transition(index): failures.append("选择无法接续：" + session.active_entry + " " + str(choices[index]) + " " + session.last_notice); return false
				else: session.narrative.advance()
			"material": if not session.material_read_complete(): return false
			"selection":
				var selected := false
				for row in session.config.relations:
					if row.question_ref != session.question or not session.condition(str(row.get("condition_ref", ""))): continue
					if session.config.results[row.result_ref].feedback_key == "insufficient": continue
					var refs: Array = []
					for field in ["a_content_ref", "b_content_ref", "basis_content_ref"]:
						if not str(row.get(field, "")).is_empty(): refs.append(str(row[field]))
					if not refs.all(func(id): return session.case_state.owns(id)): continue
					session.clear_slot(0); session.clear_slot(1)
					if not session.select_target(): continue
					for field in ["a_content_ref", "b_content_ref"]:
						if not str(row.get(field, "")).is_empty(): session.select_content(str(row[field]))
					if session.present(): selected = true; print("PROOF ", row.id); break
				if not selected: session.collapse_question(); return true
			"result":
				var result: Dictionary = session.config.results.get(session.pending_result.get("result", ""), {})
				if session.pending_result.get("response_after_accept", false) and not session.pending_result.get("accepted", false):
					if not session.accept_inference(): failures.append("收下后回应无法提交：" + session.question); return false
				elif not session.pending_result.get("response_read", false):
					if not session.read_result_response(): failures.append("回应无法开始：" + session.question); return false
				elif not str(result.get("inference_content_ref", "")).is_empty() and not session.pending_result.get("accepted", false):
					if not session.accept_inference(): failures.append("推论无法收下：" + session.question); return false
				elif not session.continue_result(): failures.append("结果无法继续：" + session.question); return false
			"investigation", "credits": return true
			_: return false
	failures.append("正文接续形成循环：" + session.active_entry + " " + str(session.narrative.state.get("current_text_id", "")) + " " + session.last_notice)
	return false
