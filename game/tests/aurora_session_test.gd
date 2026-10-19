extends SceneTree
## 正式首章沿实际路线回归；原件未读不成卡，床菜单未选休息不切场。
var failures: Array[String] = []
var session: Node
var checks := 0
func _init() -> void: call_deferred("_run")
func _check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr(message)
func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(),"正式配置应可载入")
	if not failures.is_empty(): quit(1); return
	_check(session.new_game(),"新游戏应可开始")
	_drain()
	_check(session.mode == "investigation" and session.case_state.data.scene == "SC01","开场应回到站外调查")
	_check(session.validate_snapshot(session.export_snapshot()),"初始自动档必须可校验")
	_call("ENTRY_CH01_SIGN")
	_move("SC02")
	_check(session.case_state.data.scene == "SC02","地图进站后留在大厅")
	_move("SC06")
	_check(not session.case_state.owns("E01_V1"),"尚未阅读清单不能获得E01")
	_check(session.activate_entry("ENTRY_CH01_READ_E01",_context()),"清单调查入口应可用")
	_drain(false)
	_check(session.mode == "material" and not session.case_state.owns("E01_V1"),"打开原件不能提前获卡")
	_check(session.material_read_complete(),"清单完成阅读回执")
	_drain()
	_check(session.case_state.owns("E01_V1"),"实际读完才取得清单")
	_move("SC02")
	_check(session.case_state.data.events.get("EV_T00_COMPLETED",false),"登记核对两轮均由主动出示完成")
	_check(session.case_state.owns("P06_V1"),"教程推论须主动收下")
	_check(session.case_state.data.events.get("EV_SHARED_MEAL_FINISHED",false),"登记货单及回信后应完成共餐")
	var model := preload("res://systems/aurora/aurora_investigation.gd").new()
	model.bind(session)
	# 最终第6节明确取消活人的地面小立绘；前景热区只在真实交谈显示。
	var ivan_layers: Array = model.image_layers().filter(func(row): return row.object_ref == "CHR04")
	_check(ivan_layers.is_empty(),"调查不能重新叠餐后伊万地面小立绘")
	_check(not model.hotspots().any(func(row): return row.object_kind == "foreground_character"),"未显示近景人物时不能生成空坐标前景热点")
	var ivan_texts: Array = session.narrative.state.history.filter(func(id): return session.config.texts.get(str(id),{}).get("character_id","") == "CHR04")
	_check(not ivan_texts.is_empty(),"共餐与接待必须实际读过伊万对白")
	_move("SC05")
	_check(session.case_state.data.events.get("EV_PLANNER_PHOTO_READ",false) or session.case_state.data.entries.get("ENTRY_PLANNER_PHOTO",false),"首次走廊应实际读照片短场")
	_move("SC08")
	_check(session.case_state.data.chapter == "CH01","走进房间不能自行推进案发")
	var beds: Array = model.hotspots().filter(func(row): return row.object_ref == "OBJ_SC08_BED")
	_check(beds.size() == 1,"艾琳房间应有唯一床热点")
	if beds.is_empty(): session.queue_free(); quit(1); return
	_check(model.inspect(beds[0]),"实际床热点应打开休息菜单")
	_check(session.mode == "narrative" and session.narrative.state.waiting_for_choice,"点击床应等待玩家选择")
	_check(session.case_state.data.scene == "SC08" and session.case_state.data.chapter == "CH01","未选休息不移动地点也不推进章节")
	_check(session.narrative.current_record().get("scene_id") == "SC08","床菜单舞台使用当前卧室")
	_check(str(session.narrative.current_record().get("background_path","")).contains("SC08_"),"床菜单背景不能保留大厅")
	_check(session.narrative.current_record().get("clear_positions",false),"床菜单清除上段对话人物")
	_check(session.narrative.current_text().is_empty() and "__CONTROL__" not in session.narrative.state.history,"控制菜单不展示入口名也不写已听原话")
	_check(session.validate_snapshot(session.export_snapshot()),"床菜单快照仍可校验")
	var wait_choice: int = session.narrative.available_choices.find_custom(func(row): return session.choice_label(row) == "再待一会儿")
	_check(wait_choice >= 0 and session.narrative.choose_transition(wait_choice),"再待一会儿应返回卧室")
	_check(session.mode == "investigation" and session.case_state.data.scene == "SC08","取消休息留在卧室")
	_check(model.inspect(beds[0]),"返回卧室后可再次点床")
	_drain()
	if session.case_state.data.chapter == "CH01" and session.case_state.data.scene == "SC08": _move("SC09")
	if session.case_state.data.chapter == "CH01" and session.case_state.data.scene == "SC09": _move("SC02")
	_check(session.case_state.data.chapter == "CH02","主动休息并完成报警后才推进案发调查")
	_check(session.case_state.errors.is_empty(),"正式事件不能含未支持动作")
	_check(session.validate_snapshot(session.export_snapshot()),"案发后快照通过完整性检查")
	print("AURORA_SESSION ",failures.is_empty()," chapter=",session.case_state.data.chapter," scene=",session.case_state.data.scene," checks=",checks)
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
func _context() -> Dictionary:
	return {"kind":"scene","scene":session.case_state.data.scene,"view":session.case_state.data.view}
func _call(id: String) -> void:
	_check(session.activate_entry(id,_context()),"入口不可用：" + id)
	_drain()
func _move(id: String) -> void:
	_check(session.travel(id),"前往失败：" + id)
	if session.mode == "investigation": session.arrive()
	_drain()
func _drain(read_material: bool = true) -> void:
	for step in range(2500):
		match str(session.mode):
			"material":
				if not read_material: return
				_check(session.material_read_complete(),"原件阅读回执失败")
			"narrative":
				session.narrative.tick(100)
				if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
				else: session.narrative.advance()
			"selection":
				var chosen := false
				for relation in session.config.relations:
					if relation.question_ref != session.question or not session.condition(str(relation.get("condition_ref",""))): continue
					if session.config.results[relation.result_ref].feedback_key not in ["support","exclude","inference"]: continue
					var refs: Array = []
					for key in ["a_content_ref","b_content_ref","basis_content_ref"]:
						if not str(relation.get(key,"")).is_empty(): refs.append(str(relation[key]))
					if not refs.all(func(ref): return session.case_state.owns(ref)): continue
					var target := str(relation.target_text_ref)
					if target != session.current_statement and not session.select_statement(target): continue
					session.clear_slot(0); session.clear_slot(1)
					if not session.select_target(): continue
					for key in ["a_content_ref","b_content_ref"]:
						if not str(relation.get(key,"")).is_empty(): session.select_content(str(relation[key]))
					chosen = session.present()
					if chosen: break
				if not chosen: _check(false,"当前问题无合法解：" + session.question); return
			"result":
				if session.pending_result.get("effect_pending",false): session.finish_result_effect(); continue
				var result: Dictionary = session.config.results.get(session.pending_result.get("result",""),{})
				if not session.pending_result.get("response_read",false):
					if not session.read_result_response(): _check(false,"回应不能开始：" + session.question); return
				elif not str(result.get("inference_content_ref","")).is_empty() and not session.pending_result.get("accepted",false):
					if not session.accept_inference(): _check(false,"推论不能收下"); return
				elif not session.continue_result(): _check(false,"结果不能继续"); return
			"investigation","credits": return
			_: _check(false,"非法会话状态：" + session.mode); return
	_check(false,"正式接续超过2500步：" + session.active_entry)
