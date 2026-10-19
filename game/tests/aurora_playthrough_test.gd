extends SceneTree
## 六章贯通仅使用当前画面热点、人物话题、公开前往和实际取得的卡牌。
var session: Node
var scene_page: Control
var attempted := {}
var signature := ""
var failures: Array[String] = []
var actions := 0
var visits := {}
var choice_visits := {}
var trace: Array[String] = []
var blocked_questions := {}
var movement_visits := {}
var service_topics := false
var defer_old_case := false
func _init() -> void: call_deferred("_run")
func _run() -> void:
	service_topics = OS.get_cmdline_user_args().has("--service-topics")
	defer_old_case = OS.get_cmdline_user_args().has("--defer-old-case")
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	if not session.initialize() or not session.new_game(): quit(1); return
	scene_page = preload("res://pages/aurora/aurora_scene_page.gd").new()
	scene_page.bind(session)
	for step in range(12000):
		if not _drain(): break
		if session.mode == "credits": break
		if session.mode != "investigation": _fail("未知停点：" + session.mode); break
		var current := JSON.stringify([session.case_state.data.chapter,session.case_state.data.events,session.case_state.data.materials,session.case_state.data.texts,session.case_state.data.completed_questions])
		if current != signature:
			signature = current
			attempted.clear()
			blocked_questions.clear()
		if not _investigate(): _fail("当前开放地点均无可推进入口：" + str(session.case_state.data.chapter)); break
	if session.mode != "credits": _fail("尚未走到正式片尾：" + session.last_notice)
	var diagnostic := FileAccess.open("res://../.local/aurora-%splaythrough-state.json" % ("service-" if service_topics else ""),FileAccess.WRITE)
	if diagnostic: diagnostic.store_string(JSON.stringify(session.export_snapshot()))
	var trace_file := FileAccess.open("res://../.local/aurora-%splaythrough-trace.txt" % ("service-" if service_topics else ""),FileAccess.WRITE)
	if trace_file: trace_file.store_string("\n".join(trace))
	print("PLAY_END ",("service" if service_topics else "visible")," ",failures.is_empty()," ",session.mode," ",session.case_state.data.chapter," questions=",session.case_state.data.completed_questions.keys()," actions=",actions)
	for error in failures: printerr(error)
	_write_blockers()
	scene_page.free()
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
func _record(message: String) -> void:
	trace.append(message)
	actions += 1
	print("PLAY ",actions," ",session.case_state.data.chapter," ",session.case_state.data.scene," ",message)
func _fail(message: String) -> void:
	if message not in failures: failures.append(message)
func _investigate() -> bool:
	var scene := str(session.case_state.data.scene)
	var view := str(session.case_state.data.view)
	var model: RefCounted = scene_page.model
	var options: Array = []
	var visible_hotspots: Array = model.hotspots()
	# 明确切换到交谈视角，使用该视角实际绘出的近景对象；不恢复调查小人图。
	var conversation: Array = model.conversation_candidates()
	for actor in conversation:
		if not visible_hotspots.any(func(row): return str(row.get("object_ref", "")) == str(actor.object_ref)):
			visible_hotspots.append(actor)
	for hotspot in visible_hotspots:
		if str(hotspot.object_kind) in ["character","embedded_character","foreground_character"]:
			for topic in model.topics(str(hotspot.get("topic_entry_ref",""))):
				if topic.get("interactive",true): options.append({"kind":"topic","id":str(topic.entry_ref),"row":hotspot})
			for binding in session.config.narrative_bindings("material_presentation_bindings"):
				if binding.get("actor_id") == hotspot.object_ref and binding.get("scene_id") == scene and session.condition(str(binding.get("condition_ref",""))) and session.case_state.owns(str(binding.get("content_id",""))):
					options.append({"kind":"offer","id":str(binding.id),"row":binding})
		if hotspot.object_kind == "exit" and not str(hotspot.get("target_scene_ref","" )).is_empty() and hotspot.target_scene_ref != scene: continue
		if not str(hotspot.get("inspect_entry_ref","" )).is_empty() or not str(hotspot.get("detail_view_ref","" )).is_empty() or (hotspot.object_kind == "exit" and str(hotspot.get("target_scene_ref","")) == scene):
			options.append({"kind":"hotspot","id":str(hotspot.hotspot_id),"row":hotspot})
	# 显式服务贯通选项用于隔离人物表现缺口；默认回归始终要求实际可见热点。
	if service_topics:
		for hotspot in session.config.rows("investigation","热点映射"):
			if hotspot.scene_id != scene or hotspot.object_kind != "foreground_character": continue
			if str(session.case_state.data.npc.get(str(hotspot.object_ref),{}).get("scene_id","")) != scene: continue
			for topic in model.topics(str(hotspot.get("topic_entry_ref",""))):
				if topic.get("interactive",true) and not options.any(func(item): return item.id == topic.entry_ref): options.append({"kind":"topic","id":str(topic.entry_ref),"row":hotspot})
	for control in model.interface_layout.get("view_switch_controls",[]):
		if control.scene_id == scene and control.view_id == view: options.append({"kind":"view_switch","id":str(control.id),"row":control})
	for item in session.available_reasoning():
		if not blocked_questions.has(str(item.question)): options.append({"kind":"reasoning","id":str(item.entry)})
	options.sort_custom(func(a,b): return int(visits.get(str(a.id),0)) < int(visits.get(str(b.id),0)))
	for action in options:
		# 可选保守路线仅推迟旧案话题；不修改资格或进度，用于找出独立的前两章阻塞。
		if defer_old_case and str(session.case_state.data.chapter) in ["CH01","CH02"] and str(session.config.entries.get(str(action.id),{}).get("chapter_id","")) in ["CH03","CH04","CH05","CH06"]: continue
		var key := scene + "/" + view + "/" + str(action.kind) + "/" + str(action.id)
		if attempted.has(key): continue
		attempted[key] = true
		visits[str(action.id)] = int(visits.get(str(action.id),0)) + 1
		_record(str(action.kind) + " " + str(action.id))
		match str(action.kind):
			"hotspot":
				if str(action.row.get("object_kind", "")) == "foreground_character":
					if not scene_page.current_context.get("conversation_view", false): scene_page._toggle_conversation_view()
					scene_page._switch_conversation_actor(str(action.row.object_ref))
					scene_page._inspect_conversation_actor(action.row)
				else: scene_page._inspect(action.row)
			"topic":
				var context := {"kind":"topics","scene":scene,"view":view,"object":str(action.row.object_ref),"topics":str(action.row.get("topic_entry_ref","")),"hotspot":str(action.row.hotspot_id)}
				if str(action.row.get("object_kind", "")) == "foreground_character":
					context["conversation_view"] = true
					context["conversation_actor"] = str(action.row.object_ref)
				scene_page.current_context.clear()
				if not session.activate_entry(str(action.id),context): continue
			"reasoning":
				if not session.activate_entry(str(action.id),{"kind":"reasoning","scene":scene,"view":view}): continue
			"view_switch":
				if not scene_page._open_view(str(action.row.target_view_ref),str(action.row.get("target_focus_ref",""))): continue
			"offer":
				if not session.present_material_to(str(action.row.actor_id),str(action.row.content_id)): continue
		return true
	if scene_page._is_local(): scene_page._back_view(); _record("BACK_VIEW"); return true
	var destinations: Array = session.config.scenes.keys().filter(func(id): return id != scene and session.scene_status(id).available)
	destinations.sort_custom(func(a,b): return int(movement_visits.get(str(a),0)) < int(movement_visits.get(str(b),0)))
	for destination in destinations:
		var key := "MOVE/" + scene + "/" + str(destination)
		if attempted.has(key): continue
		attempted[key] = true
		if not session.travel(str(destination)): continue
		movement_visits[str(destination)] = int(movement_visits.get(str(destination),0)) + 1
		_record("MOVE " + str(destination))
		if session.mode == "investigation": session.arrive()
		return true
	return false
func _drain() -> bool:
	for step in range(5000):
		match str(session.mode):
			"narrative":
				session.narrative.tick(100)
				if session.narrative.state.waiting_for_choice:
					var choices: Array = session.narrative.available_choices
					if choices.is_empty(): _fail("等待选择但无选项：" + session.active_entry); return false
					var source: String = str(session.narrative.state.current_text_id) + str(session.active_entry)
					var index := int(choice_visits.get(source,0)) % choices.size()
					choice_visits[source] = int(choice_visits.get(source,0)) + 1
					if not session.narrative.choose_transition(index): _fail("选择无法接续：" + session.active_entry + " " + session.last_notice); return false
				elif not session.narrative.advance(): _fail("正文无法继续：" + str(session.narrative.state.get("current_text_id","")) + " " + session.last_notice); return false
			"material":
				if not session.material_read_complete(): _fail("原件读完失败：" + session.active_entry + " " + session.last_notice); return false
			"selection":
				if not _solve_question():
					blocked_questions[session.question] = true
					_record("NEEDS_CONTENT " + session.question)
					session.collapse_question()
					return true
			"result":
				if session.pending_result.get("effect_pending",false): session.finish_result_effect(); continue
				var result: Dictionary = session.config.results.get(session.pending_result.get("result",""),{})
				if session.pending_result.get("response_after_accept",false) and not session.pending_result.get("accepted",false):
					if not session.accept_inference(): _fail("收下后回应无法提交：" + session.question); return false
				elif not session.pending_result.get("response_read",false):
					if not session.read_result_response(): _fail("回应无法开始：" + session.question + " " + session.last_notice); return false
				elif not str(result.get("inference_content_ref","")).is_empty() and not session.pending_result.get("accepted",false):
					if not session.accept_inference(): _fail("推论无法收下：" + session.question); return false
				elif not session.continue_result(): _fail("结果无法继续：" + session.question); return false
			"investigation","credits": return true
			_: _fail("未知会话状态：" + session.mode); return false
	_fail("接续循环：" + session.active_entry + " " + str(session.narrative.state.get("current_text_id","")))
	return false
func _solve_question() -> bool:
	var binding: Dictionary = session.question_binding()
	if binding.get("requires_actual_presentation",true) == false:
		if session.can_continue_question(): return session.continue_question()
		for statement in session.statement_options():
			if not statement.heard or not session.select_statement(str(statement.id)): continue
			var found := false
			for press in session.config.narrative_bindings("statement_bindings"):
				if press.question_id == session.question and press.target_text_ref == statement.id:
					found = bool(session.case_state.data.events.get(str(press.get("press_completion_event_ref","")),false))
			if not found and session.press_statement(): _record("PRESS " + session.question + " " + str(statement.id)); return true
	for relation in session.config.relations:
		if relation.question_ref != session.question or not session.condition(str(relation.get("condition_ref",""))): continue
		if session.config.results[relation.result_ref].feedback_key not in ["support","exclude","inference"]: continue
		var refs: Array = []
		for field in ["a_content_ref","b_content_ref","basis_content_ref"]:
			if not str(relation.get(field,"")).is_empty(): refs.append(str(relation[field]))
		if not refs.all(func(id): return session.case_state.owns(id)): continue
		var target := str(relation.get("target_text_ref",""))
		if not target.is_empty() and target != session.current_statement:
			if not session.select_statement(target): continue
		session.clear_slot(0); session.clear_slot(1)
		if not session.select_target(): continue
		for field in ["a_content_ref","b_content_ref"]:
			if not str(relation.get(field,"")).is_empty(): session.select_content(str(relation[field]))
		if session.present():
			# 出示返回true只代表展示了结果；不足/错误不能算作证明成功。
			if not session.pending_result.get("complete", false) or session.pending_result.get("feedback", "") not in ["support", "exclude", "inference"]:
				_fail("有效关系未兑现：%s 实际=%s" % [str(relation.id), JSON.stringify(session.pending_result)])
				return false
			_record("PROOF " + str(session.pending_result.get("relation", "")))
			return true
	# 某些后续核查需先完成逐句追问，追问获得的事实与出示分开提交。
	for statement in session.statement_options():
		if not statement.heard or not session.select_statement(str(statement.id)): continue
		for press in session.config.narrative_bindings("statement_bindings"):
			if press.question_id != session.question or press.target_text_ref != statement.id: continue
			var event_id := str(press.get("press_completion_event_ref",""))
			if not event_id.is_empty() and session.case_state.data.events.get(event_id,false): continue
			var key: String = "PRESS/" + str(session.question) + "/" + str(statement.id)
			if attempted.has(key): continue
			attempted[key] = true
			if session.press_statement(): _record("PRESS " + session.question + " " + str(statement.id)); return true
	return false
func _write_blockers() -> void:
	var file := FileAccess.open("res://../.local/fullflow-blockers.md",FileAccess.WRITE)
	if file: file.store_string("# 六章实际流程回归\n\n当前：%s / %s / %s；入口：%s；文本：%s；问题：%s\n\n%s\n\n完整状态：`.local/aurora-playthrough-state.json`；动作：`.local/aurora-playthrough-trace.txt`。\n" % [session.mode,session.case_state.data.chapter,session.case_state.data.scene,session.active_entry,str(session.narrative.state.get("current_text_id","")),session.question,"\n".join(failures)])
