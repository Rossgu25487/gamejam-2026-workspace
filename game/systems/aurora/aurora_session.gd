extends Node
## 正式会话：组织入口、文案、案件事件与核查。界面只消费模型和提交玩家操作。
const ConfigScript = preload("res://systems/aurora/aurora_configuration.gd")
const StateScript = preload("res://systems/aurora/aurora_case_state.gd")
const NarrativeScript = preload("res://systems/aurora/aurora_narrative.gd")
signal changed
signal notice(message: String)
signal autosave_requested(snapshot: Dictionary)
signal protection_requested(snapshot: Dictionary)
signal music_requested(key: String)
signal media_requested(request: Dictionary)
signal result_presentation_requested(result: Dictionary)
signal returned(context: Dictionary)
signal initial_save_completed(run_id: String)
signal ending_checkpoint_requested
var config: RefCounted = ConfigScript.new()
var case_state: RefCounted = StateScript.new()
var narrative: Node
var mode := "investigation"
var active_entry := ""
var return_context := {}
var reader := {}
var question := ""
var selected_target := false
var slots: Array = ["", ""]
var pending_result := {}
var response_active := false
var response_after := {}
var call_stack: Array = []
var last_notice := ""
var paused := false
var processing := false
var initial_saved := false
var elapsed_seconds := 0.0
var activity_enabled := false
var run_id := ""
var last_bgm := ""
var seen_storage_path := "user://aurora_seen.json"
var ending_elapsed := 0.0
var save_writer: Callable
var stage_dirty := false
var save_due := false
var autosave_failed := false
var page_snapshot_provider: Callable
var page_snapshot := {}
var media_snapshot_provider: Callable
var ending_media := {}
# 由本包剧情明确要求的到达短场；资格直接引用原入口条件，不复制条件表达式。
const ARRIVAL_ENTRIES := {
	"SC02": ["ENTRY_CH01_RECEPTION", "ENTRY_CH01_HALL_RETURN", "ENTRY_CH04_HALL_RETURN", "ENTRY_CH06_PHONE"],
	"SC06": ["ENTRY_CH01_TEA"], "SC09": ["ENTRY_CH02_SC09_HANDOVER"], "SC04": ["ENTRY_CH02_ARCHIVE_FIRST"]}

func initialize(root: String = ConfigScript.DEFAULT_ROOT) -> bool:
	if not config.load_package(root): return false
	case_state.bind(config)
	case_state.commit_guard = _prepare_event_commit
	case_state.reset()
	narrative = NarrativeScript.new()
	add_child(narrative)
	narrative.configure_formal(self)
	narrative.load_seen_registry(seen_storage_path)
	narrative.notice.connect(_notice)
	return true

func new_game() -> bool:
	var nav: Array = config.rows("start", "导航总控")
	var start_id := str(nav[0].get("start_entry_id", "")) if nav.size() == 1 else ""
	if not config.entries.has(start_id) or not prepare_scene("SC01"): return false
	var old := export_snapshot() if not run_id.is_empty() else {}
	case_state.reset()
	narrative.state = {}
	active_entry = ""
	mode = "investigation"
	reader.clear()
	pending_result.clear()
	response_after.clear()
	call_stack.clear()
	response_active = false
	return_context.clear()
	question = ""
	slots = ["", ""]
	elapsed_seconds = 0
	initial_saved = false
	stage_dirty = false
	save_due = false
	autosave_failed = false
	page_snapshot.clear()
	ending_media.clear()
	run_id = "%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	last_bgm = ""
	# 起始人物结果有自己的事件身份，先建立初始状态，再进入唯一开始入口。
	if config.events.has("EV_CH01_OPENING_NPCS"): case_state.event("EV_CH01_OPENING_NPCS")
	var started := activate_entry(start_id, {"kind": "scene", "scene": "SC01", "view": "VIEW_SC01_MAIN"})
	if not started and not old.is_empty(): restore_snapshot(old)
	return started

func _prepare_event_commit(_id: String, before: Dictionary, candidate: Dictionary) -> bool:
	# 整组结果已在候选状态验证。阶段变化先保护旧世界，再准备目标资源；
	# 任一步失败均不暴露候选状态，也不留下半组材料或人物位置。
	if candidate.chapter == before.chapter: return true
	processing = true
	var saved := not save_writer.is_valid() or bool(save_writer.call(export_snapshot()))
	processing = false
	if not saved: return _notice("阶段前自动保存失败，当前阶段已保留，请重试本次操作。")
	for person in candidate.npc:
		if not prepare_scene(str(candidate.npc[person].get("scene_id", ""))): return _notice("阶段所需场景资源尚未就绪，当前阶段已保留。")
	stage_dirty = true
	return true

func _write_auto() -> bool:
	var first := not initial_saved
	processing = true
	var ok := bool(save_writer.call(export_snapshot())) if save_writer.is_valid() else true
	if not save_writer.is_valid(): autosave_requested.emit(export_snapshot())
	processing = false
	if ok:
		initial_saved = true
		stage_dirty = false
		save_due = false
		autosave_failed = false
		if first: initial_save_completed.emit(run_id)
		notice.emit("自动保存完成")
	else:
		autosave_failed = true
		_notice("自动保存失败，当前调查仍保留。请点击重试保存，或从暂停菜单手动保存。")
	changed.emit()
	return ok

func retry_autosave() -> bool:
	if not autosave_failed or not can_save(): return false
	return _write_auto()

func close_local_context() -> void:
	# 关闭观察本身不产生新保存；仅兑现已完成结果或阶段留下的待保存回执。
	return_context = {"kind": "scene", "scene": case_state.data.scene, "view": case_state.data.view}
	if (save_due or stage_dirty) and can_save(): _write_auto()

func prepare_scene(id: String) -> bool:
	if not config.scenes.has(id): return false
	var ref := str(config.scenes[id].get("background_ref", ""))
	var path := str(config.resources.get(ref, {}).get("path", ""))
	return not path.is_empty() and FileAccess.file_exists(path)

func condition(id: String) -> bool:
	return case_state.condition(id)

func activate_entry(id: String, context: Dictionary = {}, depth: int = 0) -> bool:
	if depth > 48 or not config.entries.has(id): return _notice("入口接续无效：" + id)
	var row: Dictionary = config.entries[id]
	if not _entry_condition(row): return false
	var allowed: Array[String] = ConfigScript.ids(str(row.get("allowed_scene_ids", "")))
	if row.get("location_mode", "caller") == "caller" and not allowed.is_empty() and str(case_state.data.scene) not in allowed: return false
	# 六稿两个旧包目录漏挂“实际查看包中文书”结果。仅在玩家进入目录
	# 时提交容器状态，不将四份原件当作已读，更不批量授予其中材料。
	if id in ["ENTRY_BAG_SELECT_SC04", "ENTRY_BAG_SELECT_SC10", "ENTRY_CH03_DOCUMENTS"]:
		if not case_state.event("EV_BAG_DOCUMENTS_VIEWED", {"entry": id, "scene": case_state.data.scene}): return false
	if not context.is_empty(): return_context = context.duplicate(true)
	active_entry = id
	reader.clear()
	if row.get("location_mode") == "fixed":
		for link in config.rows("narrative", "片段地点关联"):
			if link.sequence_id == row.sequence_id and config.scenes.has(str(link.scene_id)):
				if not set_scene(str(link.scene_id)): return false
				break
	_apply_music(row)
	match str(row.get("call_kind", "")):
		"entry":
			call_stack.append({"entry": id, "context": return_context.duplicate(true)})
			return activate_entry(str(row.call_ref), {}, depth + 1)
		"material":
			mode = "material"
			reader = {"content": str(row.call_ref), "entry": id, "scroll": 0.0, "read_complete": false}
			narrative.end_reading()
			changed.emit()
			return true
		"question":
			if response_active:
				pending_result["continuation"] = {"target_kind": "entry", "target_ref": id}
				return finish_response()
			return open_question(str(row.call_ref))
	var first := str(row.get("first_text_id", ""))
	# 调查反馈按当前状态选同一观察的阶段差分；回访只读该差分的repeat_text。
	var variants: Array = []
	for feedback in config.rows("narrative", "调查文字关联"):
		if feedback.entry_id == id and condition(str(feedback.get("condition_id", ""))): variants.append(feedback)
	var explicit := variants.filter(func(item): return not str(item.get("condition_id", "")).is_empty())
	if not explicit.is_empty(): variants = explicit
	if row.get("feedback_entry", false) and variants.is_empty(): return false
	if not variants.is_empty() and first.is_empty() and not config.jumps.has(id):
		var feedback: Dictionary = variants.back()
		var initial := str(feedback.get("first_text_id", ""))
		var repeat_text := str(feedback.get("repeat_text_id", ""))
		if not initial.is_empty(): first = repeat_text if case_state.data.texts.get(initial, false) and not repeat_text.is_empty() else initial
	if not first.is_empty():
		mode = "narrative"
		var started: bool = narrative.show_text(first)
		changed.emit()
		return started
	return resolve_source(id, depth + 1)

func _entry_condition(row: Dictionary) -> bool:
	var gate := str(row.get("condition_id", ""))
	if condition(gate):
		# 原件必须在其完成事件可接受回执时才开放，避免能打开却永远读不完。
		if row.get("call_kind") == "material":
			for action in config.events.get(str(row.get("completion_event_id", "")), []):
				if not condition(str(action.get("condition_id", ""))): return false
		return true
	# 六稿L11回应入口误以自己的完成事件作前提。只对已命中该结果的
	# 专用回应校验候选条件；真实事实仍等完整回应结束，由文案提交。
	if response_active and question == "L11_R02" and row.get("entry_id") == "ENTRY_CH03_JOINT_ROUTE_RESPONSE":
		var old: Dictionary = case_state.data.duplicate(true)
		case_state.data.events["EV_CH03_L11_DOCUMENT_SCOPE_CONFIRMED"] = true
		var eligible := condition(gate)
		case_state.data = old
		return eligible
	return false

func _apply_music(row: Dictionary) -> void:
	var key := ""
	match str(row.get("bgm_mode", "inherit_chapter")):
		"specified": key = str(row.get("bgm_id", ""))
		"inherit_chapter": key = str(config.chapters.get(row.get("chapter_id", case_state.data.chapter), {}).get("default_bgm_id", ""))
	if key != last_bgm:
		last_bgm = key
		music_requested.emit(key)

func finish_text(id: String) -> bool:
	return resolve_source(id)

func valid_jumps(source: String, timing: String = "") -> Array:
	var candidates: Array = []
	for row in config.jumps.get(source, []):
		if not timing.is_empty() and row.get("timing", "") != timing: continue
		if condition(str(row.get("condition_id", ""))): candidates.append(row)
	# 有条件的分支先于同源无条件默认返回，空条件不是另一条同时执行的分支。
	var explicit: Array = candidates.filter(func(row): return not str(row.get("condition_id", "")).is_empty())
	if candidates.any(func(row): return row.get("trigger") == "choice"): return candidates
	return explicit if not explicit.is_empty() else candidates

func resolve_source(source: String, depth: int = 0) -> bool:
	if depth > 48: return _notice("配置入口形成无正文循环：" + source)
	var candidates := valid_jumps(source)
	if source == active_entry:
		candidates = candidates.filter(func(row): return row.get("timing") != "on_accept")
	if candidates.is_empty():
		var row: Dictionary = config.texts.get(source, {})
		var next := str(row.get("next_text_id", ""))
		if not next.is_empty(): return follow({"target_kind": "text", "target_ref": next}, depth + 1)
		if not _complete_entry(): return false
		return return_to_context()
	var choices: Array = candidates.filter(func(row): return row.get("trigger") in ["choice", "question"])
	if not choices.is_empty():
		mode = "narrative"
		# 无正文的操作菜单仍使用当前文本作为只读背景；没有上一句时显示入口名。
		if narrative.state.is_empty():
			var id := "__CONTROL__"
			narrative.catalog.data.texts[id] = {"text": entry_label(source), "text_id": id, "text_type": "narration", "read_version": 1, "font_color": "#FFFFFF"}
			narrative.start(id)
		narrative.show_choices(choices)
		changed.emit()
		return true
	# 真正不同目标同时成立时停止，不按文件排序猜剧情。
	var selected: Dictionary = candidates[0]
	for row in candidates:
		if row.target_kind != selected.target_kind or row.target_ref != selected.target_ref or row.get("event_id", "") != selected.get("event_id", ""):
			return _notice("同一入口存在冲突接续：" + source)
	return follow(selected, depth + 1)

func follow(jump: Dictionary, depth: int = 0) -> bool:
	if not condition(str(jump.get("condition_id", ""))): return false
	var kind := str(jump.get("target_kind", "return"))
	var ref := str(jump.get("target_ref", "context"))
	var event_id := str(jump.get("event_id", ""))
	# 回应末句的on_accept属于主动收下动作。读完只展示待收结果，
	# 事件和后续接续分别留给收下、继续；不能在翻过末句时先发推论。
	if response_active and jump.get("timing") == "on_accept":
		pending_result["accept_event"] = event_id
		pending_result["continuation"] = jump.duplicate(true)
		pending_result.continuation.erase("event_id")
		pending_result.continuation.erase("timing")
		if not _complete_entry(): return false
		return finish_response()
	if not event_id.is_empty() and not case_state.event(event_id, source_context()): return _notice("结果提交条件不满足：" + event_id)
	if jump.get("location_mode") == "fixed" and not str(jump.get("scene_id", "")).is_empty():
		if not set_scene(str(jump.scene_id)): return false
	# 连续供述可以直接接下一问或地图；先结束本次结果回执，玩家继续后才进入后继。
	if response_active and kind in ["question", "map", "ending"]:
		if not _complete_entry(): return false
		pending_result["continuation"] = jump.duplicate(true)
		pending_result.continuation.erase("event_id")
		return finish_response()
	match kind:
		"text":
			mode = "narrative"
			return narrative.show_text(ref)
		"entry":
			if not _complete_entry(): return false
			return activate_entry(ref, {}, depth + 1)
		"question": return open_question(ref)
		"map":
			if not _complete_entry(): return false
			if not set_scene(ref): return false
			return_context = {"kind": "scene", "scene": ref, "view": case_state.data.view}
			return return_to_context()
		"return":
			if not _complete_entry(): return false
			if response_active: return finish_response()
			return return_to_context()
		"ending":
			if not _complete_entry(): return false
			mode = "credits"
			case_state.data.ending_cursor = 0
			ending_elapsed = 0
			narrative.end_reading()
			ending_checkpoint_requested.emit()
			changed.emit()
			return true
	return _notice("未知接续类型：" + kind)

func _complete_entry() -> bool:
	if active_entry.is_empty(): return true
	var row: Dictionary = config.entries.get(active_entry, {})
	# 离开或取消原件不是读完；只有阅读器实际回执才执行完成事件。
	if row.get("call_kind") == "material" and (reader.get("entry") != active_entry or not reader.get("read_complete", false)): return true
	if not case_state.event(str(row.get("completion_event_id", "")), source_context()):
		return _notice("阅读完成结果未提交，请重试：" + str(row.get("completion_event_id", "")))
	case_state.data.entries[active_entry] = true
	return true

func source_context() -> Dictionary:
	return {"entry": active_entry, "text": narrative.state.get("current_text_id", ""), "scene": case_state.data.scene}

func return_to_context() -> bool:
	if not call_stack.is_empty():
		var frame: Dictionary = call_stack.pop_back()
		active_entry = str(frame.entry)
		return_context = frame.context.duplicate(true)
		return resolve_source(active_entry)
	# 固定回忆/短场临时使用其他画面，结束后恢复调用者的真实地点和视图。
	if config.scenes.has(str(return_context.get("scene", ""))):
		case_state.data.scene = str(return_context.scene)
		case_state.data.view = str(return_context.get("view", config.scenes[return_context.scene].default_view_id))
	# 允许提前供述的路线中，家庭段可能先于旧案/餐食段完成。最后一项
	# 真实操作归还时重验全案条件；不在载表或恢复存档时自动执行结果。
	if condition("COND_CASE_REQUIRED_COMPLETE") and not case_state.data.events.get("EV_CH06_ENTER", false):
		if not case_state.event("EV_CH06_ENTER", source_context()): return false
		return activate_entry("ENTRY_CH06_TITLE")
	mode = "investigation"
	active_entry = ""
	reader.clear()
	narrative.end_reading()
	changed.emit()
	returned.emit(return_context.duplicate(true))
	# 初档只在真正归还可操作调查时写；之后仅明确的完成操作发普通自动档。
	if (not initial_saved or stage_dirty or save_due) and return_context.get("kind", "scene") in ["scene", "reasoning"]: _write_auto()
	return true

func material_read_complete() -> bool:
	if mode != "material" or reader.is_empty(): return false
	reader.read_complete = true
	var entry_id := str(reader.entry)
	if not _complete_entry():
		reader.read_complete = false
		return false
	reader.clear()
	return resolve_source(entry_id)

func cancel_material() -> bool:
	if mode != "material": return false
	# 取消不提交阅读事件，仍采用该入口明确配置的未读返回分支。
	var id := str(reader.entry)
	reader.clear()
	return resolve_source(id)

func set_scene(id: String) -> bool:
	if not prepare_scene(id): return _notice("场景必需资源未就绪：" + id)
	case_state.data.scene = id
	case_state.data.view = str(config.scenes[id].default_view_id)
	case_state.data.revision = int(case_state.data.revision) + 1
	return true

func scene_status(id: String) -> Dictionary:
	var known := false
	var available := false
	if case_state.data.chapter != "CH01":
		known = true
		available = true
	else:
		known = id in ["SC01", "SC02", "SC06"] or case_state.data.events.get("EV_SHARED_MEAL_FINISHED", false)
		available = known
	if id == "SC04" and not case_state.data.events.get("EV_CASE_INVESTIGATION_OPEN", false):
		available = bool(case_state.data.events.get("EV_CH01_MAIN_1_DONE", false))
		known = known or available
	if id == "SC09" and not case_state.data.events.get("EV_CASE_INVESTIGATION_OPEN", false): available = false
	return {"known": known or id == case_state.data.scene, "available": available, "reason": "当前还不能进入" if not available else ""}

func travel(id: String) -> bool:
	if not can_save() or not scene_status(id).available: return false
	if not set_scene(id): return false
	return_context = {"kind": "scene", "scene": id, "view": case_state.data.view}
	_apply_music({"chapter_id": case_state.data.chapter})
	changed.emit()
	return true

func check_objective_route(row: Dictionary) -> Dictionary:
	var result := {"ok": false, "scene": str(row.get("scene_id", "")), "reason": str(row.get("public_reason", "当前还不能前往。"))}
	var kind := str(row.get("target_kind", ""))
	var id := str(row.get("target_ref", ""))
	var entry: Dictionary = config.entries.get(id, {}) if kind == "entry" else config.entries.get(str(config.questions.get(id, {}).get("entry_ref", "")), {})
	if entry.is_empty(): return result
	# 人物入口以其当前合法地点复核；不传送到表内初始位置留下的空房。
	var candidates := [result.scene]
	var people: Array = []
	for topic in config.rows("investigation", "话题显示"):
		if topic.get("entry_ref") == str(entry.get("entry_id", "")) and str(topic.get("person_ref", "")) not in people: people.append(str(topic.person_ref))
	if not people.is_empty():
		candidates.clear()
		for person in people:
			var place := str(case_state.data.npc.get(person, {}).get("scene_id", ""))
			if not place.is_empty() and place not in candidates: candidates.append(place)
	for place in config.ids(str(entry.get("allowed_scene_ids", ""))):
		if people.is_empty() and place not in candidates: candidates.append(place)
	var old: Dictionary = case_state.data.duplicate(true)
	for place in candidates:
		if not scene_status(str(place)).available or not prepare_scene(str(place)): continue
		case_state.data.scene = place
		case_state.data.view = str(config.scenes[place].default_view_id)
		var allowed: Array = config.ids(str(entry.get("allowed_scene_ids", "")))
		var valid: bool = _entry_condition(entry) and (entry.get("location_mode") == "fixed" or allowed.is_empty() or str(place) in allowed)
		if kind == "question":
			var q: Dictionary = config.questions.get(id, {})
			valid = valid and condition(str(q.get("condition_ref", "")))
			if q.get("interaction_kind") == "statement": valid = valid and case_state.data.texts.get(str(q.get("target_text_ref", "")), false)
		if valid:
			result.ok = true
			result.scene = place
			break
	case_state.data = old
	return result

func go_objective(row: Dictionary) -> bool:
	var route := check_objective_route(row)
	if not route.ok: return false
	var before := export_snapshot()
	if not set_scene(str(route.scene)): return false
	var context := {"kind": "scene", "scene": route.scene, "view": case_state.data.view}
	var ok := activate_entry(str(row.target_ref), context) if row.target_kind == "entry" else open_question(str(row.target_ref))
	if ok:
		return_context = context
		changed.emit()
	else: restore_snapshot(before)
	return ok

func arrive() -> bool:
	# 地图叠化结束才开放短场；读档、新游戏重建不调用此方法。
	if mode != "investigation" or paused: return false
	for id in ARRIVAL_ENTRIES.get(str(case_state.data.scene), []):
		var row: Dictionary = config.entries.get(id, {})
		if row.is_empty() or case_state.data.entries.get(id, false): continue
		if str(row.get("chapter_id", "")) != str(case_state.data.chapter): continue
		if condition(str(row.get("condition_id", ""))): return activate_entry(id, return_context)
	return false

func display_scene() -> String:
	return str(case_state.data.scene)

func background_path() -> String:
	var entry: Dictionary = config.entries.get(active_entry, {})
	if entry.get("location_mode") == "fixed":
		for link in config.rows("narrative", "片段地点关联"):
			if link.sequence_id == entry.get("sequence_id") and not str(link.get("background_path", "")).is_empty(): return str(link.background_path)
	var view := str(case_state.data.view)
	for row in config.rows("investigation", "资源需求"):
		if row.get("view_id") == view and row.get("view_kind") == "fixed_view": return str(row.resource_or_text_ref)
	var ref := str(config.scenes.get(case_state.data.scene, {}).get("background_ref", ""))
	return str(config.resources.get(ref, {}).get("path", ""))

func entry_label(id: String) -> String:
	for row in config.rows("investigation", "观察引用"):
		if row.entry_ref == id and not str(row.get("display_name", "")).is_empty(): return str(row.display_name)
	for row in config.rows("investigation", "话题显示"):
		if row.entry_ref == id: return str(row.public_name)
	var label := str(config.entries.get(id, {}).get("name", id))
	return "继续" if label.begins_with("ENTRY_") or label.begins_with("SEQ_") else label

func choice_label(row: Dictionary) -> String:
	var label := str(row.get("option_text", ""))
	if label.is_empty(): label = str(row.get("operation_id", ""))
	if label.begins_with("ENTRY_") or label.is_empty(): label = entry_label(str(row.get("target_ref", "")))
	return label

func can_save() -> bool:
	return not processing and mode in ["investigation", "selection"] and not response_active and pending_result.is_empty()

func save_disabled_reason() -> String:
	return "" if can_save() else "完成当前阅读或回应并返回调查后可以保存。"

func _process(delta: float) -> void:
	if activity_enabled and not paused and not processing: elapsed_seconds += delta

func _notice(message: String) -> bool:
	last_notice = message
	notice.emit(message)
	return false

func open_question(id: String) -> bool:
	if not config.questions.has(id): return false
	question = id
	narrative.end_reading()
	var round: Dictionary = config.questions[id]
	var draft: Dictionary = case_state.data.drafts.get(id, {})
	pending_result.clear()
	selected_target = draft.get("target", round.get("interaction_kind") == "reasoning") == true
	slots = draft.get("slots", ["", ""]).duplicate()
	if not case_state.data.chances.has(id): case_state.data.chances[id] = 3
	mode = "failure" if int(case_state.data.chances[id]) == 0 else "selection"
	if case_state.data.results.has(id):
		pending_result = case_state.data.results[id].duplicate(true)
		mode = "result"
	changed.emit()
	return true

func available_reasoning() -> Array:
	# 只公开配置的自主推理入口；说法质询仍在实际问话中进入。
	var found := {}
	var result: Array = []
	for row in config.rows("core", "关卡轮次"):
		var id := str(row.get("question_ref", ""))
		if row.get("interaction_kind") != "reasoning" or id.is_empty() or found.has(id): continue
		if case_state.data.completed_questions.has(id) or not condition(str(row.get("condition_ref", ""))): continue
		var entry := str(row.get("entry_ref", ""))
		var trigger := str(row.get("trigger_text_ref", ""))
		if not config.entries.has(entry) or config.entries[entry].get("call_kind") != "question": continue
		var places: Array = config.ids(str(config.entries[entry].get("allowed_scene_ids", "")))
		if not places.is_empty() and str(case_state.data.scene) not in places: continue
		# 续问入口可无地点，但配置的人物回应仍有地点约束；入口与结果须同场可完成。
		var response: Dictionary = config.entries.get(str(row.get("response_entry_ref", "")), {})
		var response_places: Array = config.ids(str(response.get("allowed_scene_ids", "")))
		if response.get("location_mode") == "caller" and not response_places.is_empty() and str(case_state.data.scene) not in response_places: continue
		if not trigger.is_empty() and not case_state.data.texts.get(trigger, false): continue
		found[id] = true
		result.append({"question": id, "entry": entry, "text": config.text(str(row.target_text_ref))})
	return result

func browsing() -> Dictionary:
	return case_state.data.drafts.get(question, {}).get("browse", {})

func store_browsing(value: Dictionary) -> void:
	if question.is_empty(): return
	_store_draft()
	case_state.data.drafts[question]["browse"] = value.duplicate(true)

func target_text() -> String:
	var row: Dictionary = config.questions.get(question, {})
	return config.text(str(row.get("target_text_ref", "")))

func select_target() -> bool:
	if mode != "selection": return false
	var id := str(config.questions[question].get("target_text_ref", ""))
	if config.questions[question].interaction_kind == "statement" and not case_state.data.texts.get(id, false): return _notice("只能选定实际听过的原话。")
	selected_target = true
	_store_draft()
	changed.emit()
	return true

func select_content(id: String, slot: int = -1) -> bool:
	if mode != "selection" or not case_state.owns(id): return false
	var material := str(config.contents[id].material_id)
	for i in range(slots.size()):
		if not str(slots[i]).is_empty() and config.contents[slots[i]].material_id == material:
			return _notice("这份材料已入槽，请先撤下再切换版本。")
	if slot < 0: slot = slots.find("")
	if slot < 0 or slot > 1: return _notice("两处引用夹位已满，请先撤下一张。")
	slots[slot] = id
	_store_draft()
	changed.emit()
	return true

func clear_slot(index: int) -> void:
	if mode != "selection" or index < 0 or index > 1: return
	slots[index] = ""
	_store_draft()
	changed.emit()

func _store_draft() -> void:
	if question.is_empty(): return
	var draft: Dictionary = case_state.data.drafts.get(question, {})
	draft.merge({"target": selected_target, "slots": slots.duplicate()}, true)
	case_state.data.drafts[question] = draft

func collapse_question() -> bool:
	if mode not in ["selection", "failure"]: return false
	_store_draft()
	return return_to_context()

func retry_question() -> bool:
	if mode != "failure": return false
	case_state.data.chances[question] = 3
	case_state.data.drafts.erase(question)
	return open_question(question)

func present() -> bool:
	if processing or mode != "selection" or not selected_target or slots.all(func(id): return str(id).is_empty()): return false
	var selected: Array = slots.filter(func(id): return not str(id).is_empty())
	var matches: Array = []
	for row in config.relations:
		if row.question_ref != question or not condition(str(row.get("condition_ref", ""))): continue
		var refs: Array = []
		for key in ["a_content_ref", "b_content_ref"]:
			if not str(row.get(key, "")).is_empty(): refs.append(str(row[key]))
		if refs.is_empty() or not refs.all(func(id): return id in selected): continue
		if row.get("match_scope") == "exact_set" and refs.size() != selected.size(): continue
		var basis := str(row.get("basis_content_ref", ""))
		if not basis.is_empty() and not case_state.owns(basis): continue
		var result: Dictionary = config.results[row.result_ref]
		var feedback := str(result.feedback_key)
		var rank := (0 if refs.size() == 2 else 1) if feedback in ["support", "exclude", "inference"] else (2 if feedback in ["partial", "counter", "limit"] else (3 if feedback == "incorrect" else 4))
		matches.append({"row": row, "refs": refs, "rank": rank, "priority": int(row.get("priority", 100))})
	matches.sort_custom(func(a, b): return a.rank < b.rank or (a.rank == b.rank and a.priority < b.priority))
	if matches.is_empty():
		pending_result = {"feedback": "insufficient", "text": config.text("UI_CORE_INSUFFICIENT"), "refs": selected.duplicate(), "question": question, "accepted": false}
		# 明确错误单独配置，禁用模板已由读表器剔除；默认不足不扣次数。
		for error in config.rows("core", "错误出示"):
			if str(error.get("question_ref", "")) != question or not condition(str(error.get("condition_ref", ""))): continue
			var refs: Array = []
			for key in ["a_content_ref", "b_content_ref"]:
				if not str(error.get(key, "")).is_empty(): refs.append(str(error[key]))
			if refs.is_empty() or not refs.all(func(id): return id in selected): continue
			if error.get("match_scope") == "exact_set" and refs.size() != selected.size(): continue
			pending_result.feedback = "incorrect"
			pending_result.text = config.text(str(error.get("reason_text_ref", "UI_CORE_INSUFFICIENT")))
			case_state.data.chances[question] = maxi(0, int(case_state.data.chances[question]) - 1)
			break
	else:
		var best: Dictionary = matches[0]
		for other in matches:
			if other.rank == best.rank and other.priority == best.priority and (other.row.result_ref != best.row.result_ref or other.row.response_entry_ref != best.row.response_entry_ref): return _notice("出示关系的同档优先级冲突，请修正配置。")
		var relation: Dictionary = best.row
		var result: Dictionary = config.results[relation.result_ref]
		pending_result = {"question": question, "relation": relation.id, "result": result.id, "feedback": result.feedback_key,
			"refs": best.refs.duplicate(), "response": relation.get("response_entry_ref", ""), "accepted": false,
			"sources": _freeze_sources(best.refs), "complete": result.feedback_key in ["support", "exclude", "inference", "limit"]}
		# 回应入口以本次收下事件为前提时，先待收；不提前授卡来强行开放对白。
		var response: Dictionary = config.entries.get(str(pending_result.response), {})
		pending_result["response_after_accept"] = result.get("timing") == "on_accept" and not str(result.get("inference_content_ref", "")).is_empty() and not condition(str(response.get("condition_id", "")))
		if result.feedback_key == "incorrect": case_state.data.chances[question] = maxi(0, int(case_state.data.chances[question]) - 1)
		# 首次成果与等价解法共享同一高潮；不足关系永远不触发B05或业务结果。
		var climax := str(result.get("climax_key", ""))
		if pending_result.complete and not case_state.data.completed_questions.has(question) and (climax.is_empty() or not case_state.data.climaxes.has(climax)):
			pending_result["presentation"] = config.presentation(result)
			result_presentation_requested.emit(pending_result.presentation)
	mode = "result"
	_store_draft()
	changed.emit()
	return true

func _freeze_sources(refs: Array) -> Array:
	var result: Array = []
	for id in refs:
		var material := str(config.contents[id].material_id)
		result.append({"content_id": id, "material_id": material, "sources": case_state.data.materials[material].versions[id].duplicate(true)})
	return result

func read_result_response() -> bool:
	if mode != "result" or pending_result.is_empty(): return false
	if pending_result.get("response_after_accept", false) and not pending_result.get("accepted", false): return false
	var entry := str(pending_result.get("response", ""))
	if entry.is_empty(): return finish_response()
	response_after = {"entry": active_entry, "context": return_context.duplicate(true)}
	response_active = true
	return activate_entry(entry)

func finish_response() -> bool:
	response_active = false
	active_entry = str(response_after.get("entry", active_entry))
	return_context = response_after.get("context", return_context).duplicate(true)
	response_after.clear()
	if pending_result.get("complete", false):
		var result: Dictionary = config.results.get(pending_result.get("result", ""), {})
		if result.get("timing") != "on_accept":
			if not _commit_result(result): return false
	pending_result["response_read"] = true
	if case_state.data.results.has(question): case_state.data.results[question] = pending_result.duplicate(true)
	mode = "result"
	narrative.end_reading()
	changed.emit()
	return true

func accept_inference() -> bool:
	if processing or mode != "result" or pending_result.is_empty() or pending_result.get("accepted", false): return false
	var result: Dictionary = config.results.get(pending_result.get("result", ""), {})
	if str(result.get("inference_content_ref", "")).is_empty() or (not pending_result.get("response_read", false) and not pending_result.get("response_after_accept", false)): return false
	var before: Dictionary = case_state.data.duplicate(true)
	if not _commit_result(result): return false
	var deferred := str(pending_result.get("accept_event", ""))
	if not deferred.is_empty() and deferred != str(result.get("event_ref", "")):
		if not case_state.event(deferred, {"question": question, "sources": pending_result.get("sources", [])}):
			case_state.data = before
			return false
	pending_result.accepted = true
	case_state.data.results[question] = pending_result.duplicate(true)
	result_presentation_requested.emit({"feedback_key": "collect", "duration_ms": 900, "effect_level": "collect", "content_id": str(result.get("inference_content_ref", ""))})
	changed.emit()
	return true

func _commit_result(result: Dictionary) -> bool:
	if result.is_empty() or not pending_result.get("complete", false): return true
	var key := str(result.id)
	if case_state.data.completed_questions.has(question): return true
	var before: Dictionary = case_state.data.duplicate(true)
	var event_id := str(result.get("event_ref", ""))
	# narrative结果的提交方是实际文本跳转；核心只确认其已提交，不能代替或再执行一遍。
	if result.get("event_owner") == "narrative":
		if not event_id.is_empty() and not case_state.data.events.get(event_id, false): return _notice("指定回应尚未完成：" + event_id)
	elif not event_id.is_empty() and not case_state.event(event_id, {"question": question, "result": key, "sources": pending_result.get("sources", [])}): return _notice("核查结果尚未满足提交条件：" + event_id)
	var inference := str(result.get("inference_content_ref", ""))
	if not inference.is_empty() and not case_state.grant(inference, {"question": question, "result": key, "sources": pending_result.get("sources", [])}):
		case_state.data = before
		return false
	case_state.data.completed_questions[question] = key
	case_state.data.results[question] = pending_result.duplicate(true)
	var climax := str(result.get("climax_key", ""))
	if not climax.is_empty(): case_state.data.climaxes[climax] = true
	return true

func continue_result() -> bool:
	if processing or mode != "result" or pending_result.is_empty(): return false
	var result: Dictionary = config.results.get(pending_result.get("result", ""), {})
	if pending_result.get("complete", false):
		if pending_result.get("response_after_accept", false) and not pending_result.get("accepted", false): return false
		if not pending_result.get("response_read", false): return read_result_response()
		if not str(result.get("inference_content_ref", "")).is_empty() and not pending_result.get("accepted", false): return false
		var continuation: Dictionary = pending_result.get("continuation", {}).duplicate(true)
		var accepted := not str(result.get("inference_content_ref", "")).is_empty()
		save_due = true
		pending_result.clear()
		slots = ["", ""]
		selected_target = false
		case_state.data.drafts.erase(question)
		if not continuation.is_empty(): return follow(continuation)
		if accepted:
			var candidates := valid_jumps(active_entry, "on_accept")
			if not candidates.is_empty(): return follow(candidates[0])
		var after := valid_jumps(active_entry, "after_response")
		if not after.is_empty(): return follow(after[0])
		var return_id := str(result.get("return_ref", "caller"))
		if return_id != "caller" and config.entries.has(return_id): return activate_entry(return_id)
		var finished := return_to_context()
		return finished
	# 不足／局部／错误的专用回应可看完再选材，原目标和精确版本不丢失。
	if not str(pending_result.get("response", "")).is_empty() and not pending_result.get("response_read", false): return read_result_response()
	pending_result.clear()
	mode = "failure" if int(case_state.data.chances.get(question, 3)) == 0 else "selection"
	changed.emit()
	return true

func export_snapshot() -> Dictionary:
	var state: Dictionary = case_state.data.duplicate(true)
	_store_draft()
	state = case_state.data.duplicate(true)
	if page_snapshot_provider.is_valid(): page_snapshot = page_snapshot_provider.call()
	if case_state.data.ending_started and media_snapshot_provider.is_valid(): ending_media = media_snapshot_provider.call()
	return {"format": "aurora_session_v1", "content_revision": config.content_revision, "state_revision": state.revision,
		"run_id": run_id, "elapsed_seconds": elapsed_seconds, "case_state": state,
		"mode": mode, "active_entry": active_entry, "return_context": return_context.duplicate(true), "reader": reader.duplicate(true),
		"question": question, "selected_target": selected_target, "slots": slots.duplicate(), "pending_result": pending_result.duplicate(true),
		"response_active": response_active, "response_after": response_after.duplicate(true), "call_stack": call_stack.duplicate(true),
		"narrative": narrative.export_snapshot() if not narrative.state.is_empty() else {}, "bgm": last_bgm,
		"stage_dirty": stage_dirty, "save_due": save_due, "page_snapshot": page_snapshot.duplicate(true),
		"ending_media": ending_media.duplicate(true), "ending_status": "completed" if state.ending_completed else ("active" if state.ending_started else ""),
		"progress_summary": {"scene": config.text(str(config.scenes[state.scene].name_text_id)), "phase": str(config.chapters[state.chapter].name), "question": target_text() if not question.is_empty() else ""}}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if snapshot.get("format") != "aurora_session_v1" or snapshot.get("content_revision") != config.content_revision: return false
	if not snapshot.get("case_state") is Dictionary or not case_state.validate(snapshot.case_state): return false
	if snapshot.get("state_revision") != snapshot.case_state.revision: return false
	if snapshot.get("mode") not in ["investigation", "selection", "result", "failure", "narrative", "material", "credits"]: return false
	for key in ["return_context", "reader", "pending_result", "response_after", "narrative"]:
		if not snapshot.get(key) is Dictionary: return false
	var entry := str(snapshot.get("active_entry", ""))
	if not entry.is_empty() and not config.entries.has(entry): return false
	var q := str(snapshot.get("question", ""))
	if not q.is_empty() and not config.questions.has(q): return false
	if not snapshot.get("slots") is Array or snapshot.slots.size() != 2: return false
	if not snapshot.get("selected_target") is bool or not snapshot.get("response_active") is bool: return false
	if not snapshot.get("run_id") is String or str(snapshot.run_id).is_empty(): return false
	if not snapshot.get("call_stack", []) is Array: return false
	for frame in snapshot.get("call_stack", []):
		if not frame is Dictionary or not config.entries.has(str(frame.get("entry", ""))) or not _valid_context(frame.get("context")): return false
	var context: Dictionary = snapshot.return_context
	if not str(context.get("scene", "")).is_empty() and not config.scenes.has(str(context.scene)): return false
	if not _valid_context(context): return false
	if not snapshot.response_after.is_empty() and (not config.entries.has(str(snapshot.response_after.get("entry", ""))) or not _valid_context(snapshot.response_after.get("context"))): return false
	for id in snapshot.slots:
		if not id is String or (not id.is_empty() and not case_state._incoming_owns(snapshot.case_state, id)): return false
	if not str(snapshot.slots[0]).is_empty() and not str(snapshot.slots[1]).is_empty() and config.contents[snapshot.slots[0]].material_id == config.contents[snapshot.slots[1]].material_id: return false
	var duration = snapshot.get("elapsed_seconds")
	if not (duration is int or duration is float) or not is_finite(float(duration)) or duration < 0: return false
	if not snapshot.get("narrative", {}).is_empty() and not narrative.validate_snapshot(snapshot.narrative): return false
	if snapshot.mode == "narrative" and snapshot.narrative.is_empty(): return false
	if snapshot.mode in ["selection", "result", "failure"] and q.is_empty(): return false
	if not snapshot.reader.is_empty() and (not config.contents.has(snapshot.reader.get("content", "")) or not config.entries.has(snapshot.reader.get("entry", ""))): return false
	var pending: Dictionary = snapshot.pending_result
	if snapshot.mode == "result" and pending.is_empty(): return false
	if not pending.is_empty():
		if pending.get("question") != q: return false
		if pending.has("result") and not config.results.has(pending.result): return false
		if not pending.get("refs", []) is Array: return false
		for id in pending.get("refs", []):
			if not case_state._incoming_owns(snapshot.case_state, str(id)): return false
		if pending.has("relation") and not config.relations.any(func(row): return row.id == pending.relation and row.question_ref == q): return false
	if not _valid_sources(snapshot.get("page_snapshot", {}), snapshot.case_state): return false
	if not snapshot.get("ending_media", {}) is Dictionary: return false
	if not _valid_sources(pending.get("sources", []), snapshot.case_state): return false
	return true

func _valid_context(value) -> bool:
	if not value is Dictionary: return false
	if value.is_empty(): return true
	if value.get("kind", "scene") not in ["scene", "topics", "inspection", "scene_items", "reasoning"]: return false
	if not config.scenes.has(str(value.get("scene", ""))): return false
	return str(value.get("view", "")) == str(config.scenes[value.scene].default_view_id)

func _valid_sources(value, incoming: Dictionary, depth: int = 0) -> bool:
	# 冻结来源与页面栈只保存数据；拒绝坏引用、对象和过深递归，避免半恢复。
	if depth > 40: return false
	if value is Dictionary:
		for key in value:
			var item = value[key]
			if key in ["content_id", "content", "reading_content"] and item is String and not item.is_empty():
				if not config.contents.has(item): return false
			if key == "text" and item is String and not item.is_empty() and not config.texts.has(item): return false
			if not _valid_sources(item, incoming, depth + 1): return false
	elif value is Array:
		for item in value:
			if not _valid_sources(item, incoming, depth + 1): return false
	elif value is float:
		return is_finite(value)
	elif not (value == null or value is String or value is bool or value is int): return false
	return true

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot) or not prepare_scene(str(snapshot.case_state.scene)): return _notice("档案版本或完整性不符，当前调查已保留。")
	case_state.data = snapshot.case_state.duplicate(true)
	mode = str(snapshot.mode)
	active_entry = str(snapshot.active_entry)
	return_context = snapshot.return_context.duplicate(true)
	reader = snapshot.reader.duplicate(true)
	question = str(snapshot.question)
	selected_target = bool(snapshot.selected_target)
	slots = snapshot.slots.duplicate()
	pending_result = snapshot.pending_result.duplicate(true)
	response_active = bool(snapshot.response_active)
	response_after = snapshot.response_after.duplicate(true)
	call_stack = snapshot.get("call_stack", []).duplicate(true)
	elapsed_seconds = float(snapshot.elapsed_seconds)
	run_id = str(snapshot.run_id)
	initial_saved = true
	stage_dirty = bool(snapshot.get("stage_dirty", false))
	save_due = bool(snapshot.get("save_due", false))
	autosave_failed = false
	page_snapshot = snapshot.get("page_snapshot", {}).duplicate(true)
	ending_media = snapshot.get("ending_media", {}).duplicate(true)
	if snapshot.narrative.is_empty(): narrative.state = {}
	else: narrative.restore_snapshot(snapshot.narrative)
	last_bgm = str(snapshot.get("bgm", ""))
	music_requested.emit(last_bgm)
	changed.emit()
	return true
