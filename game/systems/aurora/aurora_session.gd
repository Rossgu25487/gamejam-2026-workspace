extends Node
## 正式会话：组织入口、文案、案件事件与核查。界面只消费模型和提交玩家操作。
const ConfigScript = preload("res://systems/aurora/aurora_configuration.gd")
const StateScript = preload("res://systems/aurora/aurora_case_state.gd")
const InvestigationScript = preload("res://systems/aurora/aurora_investigation.gd")
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
var current_statement := ""
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
var requested_destination := ""
var departure_ready_destination := ""
var departure_managed := false
var question_reading := {}
var arrival_pending := false
var active_slot := -1
var contextual_presentation := {}
# 由本包剧情明确要求的到达短场；资格直接引用原入口条件，不复制条件表达式。
const ARRIVAL_ENTRIES := {
	"SC02": ["ENTRY_CH01_RECEPTION", "ENTRY_CH01_HALL_RETURN", "ENTRY_CH04_HALL_RETURN", "ENTRY_CH06_PHONE"],
	"SC06": ["ENTRY_CH01_TEA"], "SC09": ["ENTRY_CH02_SC09_HANDOVER"], "SC04": ["ENTRY_CH02_ARCHIVE_FIRST"]}

func initialize(root: String = ConfigScript.DEFAULT_ROOT, shared_config: RefCounted = null) -> bool:
	# 调试快进的隔离会话复用已载入的只读配置，不再重复解析十一册工作簿。
	if shared_config != null: config = shared_config
	elif not config.load_package(root): return false
	case_state.bind(config)
	case_state.commit_guard = _prepare_event_commit
	case_state.content_updated.connect(_on_content_updated)
	case_state.reset()
	narrative = NarrativeScript.new()
	add_child(narrative)
	narrative.configure_formal(self)
	narrative.load_seen_registry(seen_storage_path)
	narrative.notice.connect(_notice)
	return true

func _on_content_updated(content_id: String) -> void:
	# 材料内容真正授予/更新后，把无头像“手册已更新”提示排入下方对白，等当前文本结束再显示。
	narrative.queue_manual_update(content_id)

func new_game() -> bool:
	var nav: Array = config.rows("start", "导航总控")
	var start_id := str(nav[0].get("start_entry_id", "")) if nav.size() == 1 else ""
	if not config.entries.has(start_id) or not prepare_scene("SC01"): return false
	var old := export_snapshot() if not run_id.is_empty() else {}
	case_state.reset()
	narrative.state = {}
	narrative.clear_manual_updates()
	active_entry = ""
	mode = "investigation"
	reader.clear()
	pending_result.clear()
	response_after.clear()
	call_stack.clear()
	response_active = false
	return_context.clear()
	question = ""
	current_statement = ""
	selected_target = false
	slots = ["", ""]
	elapsed_seconds = 0
	initial_saved = false
	stage_dirty = false
	save_due = false
	autosave_failed = false
	page_snapshot.clear()
	ending_media.clear()
	requested_destination = ""
	departure_ready_destination = ""
	departure_managed = false
	question_reading.clear()
	arrival_pending = false
	contextual_presentation.clear()
	active_slot = -1
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

func present_material_to(actor_id: String, content_id: String) -> bool:
	# 普通交谈的实物出示独立于核查题，必须核对人物、现场和准确内容版本。
	if mode != "investigation" or processing or not case_state.owns(content_id): return false
	if str(case_state.data.npc.get(actor_id, {}).get("scene_id", "")) != str(case_state.data.scene): return false
	for binding in config.narrative_bindings("material_presentation_bindings"):
		if str(binding.get("scene_id", "")) != str(case_state.data.scene): continue
		if str(binding.get("actor_id", "")) != actor_id or str(binding.get("content_id", "")) != content_id: continue
		if not condition(str(binding.get("condition_ref", ""))): continue
		var before := export_snapshot()
		contextual_presentation = binding.duplicate(true)
		if activate_entry(str(binding.get("response_entry_ref", "")), return_context): return true
		contextual_presentation.clear()
		restore_snapshot(before)
		return false
	return _notice("这份材料当前没有可向该人物出示的回应。")

func prepare_scene(id: String) -> bool:
	if not config.scenes.has(id): return false
	var ref := str(config.scenes[id].get("background_ref", ""))
	var path := str(config.resources.get(ref, {}).get("path", ""))
	# 最终地图表只维护空间与场景身份，调查背景归调查的资源需求表所有。
	# 空的旧版 background_ref 不能导致所有正式场景无法启动。
	if path.is_empty():
		var view_id := str(config.scenes[id].get("default_view_id", ""))
		for resource in config.rows("investigation", "资源需求"):
			if str(resource.get("view_id", "")) == view_id and resource.get("view_kind") in ["fixed_view", "scene_background"]:
				path = str(resource.get("resource_or_text_ref", ""))
				break
	# 成品保留导入资源映射，原 PNG 不一定作为普通文件存在。
	return not path.is_empty() and ResourceLoader.exists(path)

func condition(id: String) -> bool:
	return case_state.condition(id)

func activate_entry(id: String, context: Dictionary = {}, depth: int = 0) -> bool:
	if depth > 48 or not config.entries.has(id): return _notice("入口接续无效：" + id)
	if id == "ENTRY_T00_R02" and not _tutorial_pair_ready():
		if response_active:
			# 先按原结果时点完整结束上一轮回应，再在继续时恢复调查。
			pending_result["continuation"] = {"target_kind": "entry", "target_ref": id}
			return finish_response()
		_recover_missing_tutorial_materials()
		_notice("请先到二楼休息室读完撤站移交清单，再回大厅继续核对。")
		changed.emit()
		return true
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
			var enter_event := str(row.get("enter_event_id", ""))
			if not enter_event.is_empty() and not case_state.event(enter_event, source_context()): return false
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
		if not narrative.catalog.data.texts.has(first): return _notice("入口正文未就绪：" + first)
		var enter_event := str(row.get("enter_event_id", ""))
		if not enter_event.is_empty() and not case_state.event(enter_event, source_context()): return _notice("入口状态尚未就绪：" + enter_event)
		mode = "narrative"
		var started: bool = narrative.show_text(first)
		changed.emit()
		return started
	return resolve_source(id, depth + 1)

func _entry_condition(row: Dictionary) -> bool:
	for binding in config.narrative_bindings("material_presentation_bindings"):
		if str(binding.get("response_entry_ref", "")) == str(row.get("entry_id", "")) and contextual_presentation.is_empty(): return false
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
	if not question_reading.is_empty() and question_reading.get("kind") in ["statement", "hint"]:
		var refs: Array = question_reading.get("texts", [])
		var index := int(question_reading.get("index", 0)) + 1
		if index < refs.size():
			question_reading.index = index
			return narrative.show_text(str(refs[index]))
		return _finish_question_reading()
	return resolve_source(id)

func on_text_finished(id: String) -> bool:
	# 最终包的分页与证言绑定只在实际读完对应正文时提交完成事件。
	for group in config.narrative_bindings("text_page_groups"):
		if str(group.get("text_id", "")) == id and str(group.get("completion_text_ref", id)) != id:
			return true
	for binding in config.narrative_bindings("statement_bindings"):
		var pages: Array = binding.get("text_refs", [])
		if pages.is_empty() or str(pages.back()) != id: continue
		var event_id := str(binding.get("read_completion_event_ref", ""))
		if not event_id.is_empty() and not case_state.event(event_id, source_context()): return false
	for binding in config.narrative_bindings("arrival_bindings"):
		if str(binding.get("text_id", "")) != id: continue
		var arrival_event := str(binding.get("completion_event_ref", ""))
		if not arrival_event.is_empty() and not case_state.event(arrival_event, source_context()): return false
	return true

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
		if question_reading.get("kind") == "press": return _finish_question_reading()
		return return_to_context()
	var choices: Array = candidates.filter(func(row): return row.get("trigger") in ["choice", "question"])
	if not choices.is_empty():
		mode = "narrative"
		# 调查新开的入口菜单不能沿用已经结束或来自别处的旧对话。
		# 同一场对话继续进入选项时，仍保留刚读完的句子和人物。
		var new_context: bool = narrative.state.is_empty() or narrative.state.get("finished", false) or narrative.current_record().get("scene_id", "") != display_scene()
		if config.entries.has(source) and new_context: narrative.show_control_choices(choices)
		else: narrative.show_choices(choices)
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
	if not question_reading.is_empty() and question_reading.get("kind") == "press" and kind in ["return", "question"]:
		if not _complete_entry(): return false
		return _finish_question_reading()
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
	if question_reading.get("kind") == "press": return _finish_question_reading()
	if not contextual_presentation.is_empty():
		var event_id := str(contextual_presentation.get("completion_event_ref", ""))
		if not event_id.is_empty() and not case_state.event(event_id, source_context()): return false
		contextual_presentation.clear()
	# 固定回忆/短场临时使用其他画面，结束后恢复调用者的真实地点和视图。
	if config.scenes.has(str(return_context.get("scene", ""))):
		case_state.data.scene = str(return_context.scene)
		case_state.data.view = str(return_context.get("view", config.scenes[return_context.scene].default_view_id))
	# 离场短场完成后，沿玩家原先明确请求的目的地继续；短场中途取消时保留当前地点。
	if not requested_destination.is_empty() and not response_active:
		var destination := requested_destination
		requested_destination = ""
		if departure_managed:
			departure_managed = false
			departure_ready_destination = destination
			mode = "investigation"
			active_entry = ""
			narrative.end_reading()
			changed.emit()
			return true
		if scene_status(destination).available and set_scene(destination):
			return_context = {"kind": "scene", "scene": destination, "view": case_state.data.view}
			mode = "investigation"
			active_entry = ""
			narrative.end_reading()
			arrival_pending = true
			_continue_arrival()
			changed.emit()
			return true
	# 允许提前供述的路线中，家庭段可能先于旧案/餐食段完成。最后一项
	# 真实操作归还时重验全案条件；不在载表或恢复存档时自动执行结果。
	if condition("COND_CASE_REQUIRED_COMPLETE") and not case_state.data.events.get("EV_CH06_ENTER", false):
		if not case_state.event("EV_CH06_ENTER", source_context()): return false
		return activate_entry("ENTRY_CH06_TITLE")
	mode = "investigation"
	active_entry = ""
	reader.clear()
	narrative.end_reading()
	if arrival_pending and _continue_arrival(): return true
	changed.emit()
	returned.emit(return_context.duplicate(true))
	# 初档只在真正归还可操作调查时写；之后仅明确的完成操作发普通自动档。
	if (not initial_saved or stage_dirty or save_due) and return_context.get("kind", "scene") in ["scene", "reasoning"]: _write_auto()
	return true

func material_read_complete() -> bool:
	if mode != "material" or reader.is_empty(): return false
	var previous_reader := reader.duplicate(true)
	reader.read_complete = true
	var entry_id := str(reader.entry)
	if not _complete_entry():
		reader.read_complete = false
		return false
	reader.clear()
	if resolve_source(entry_id): return true
	# 读后接续失败也保留可操作阅读器；已经提交的材料由事件幂等保证不会重复获得。
	if mode == "material" and reader.is_empty():
		reader = previous_reader
		changed.emit()
	return false

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
	if not config.scenes.has(id): return {"known": false, "available": false, "reason": "地点不存在"}
	if case_state.data.chapter == "CH01" and not config.rows("map", "首章可达绑定").is_empty():
		var permitted := id == str(case_state.data.scene)
		for binding in config.rows("map", "首章可达绑定"):
			if str(binding.get("chapter_ref", "")) != "CH01" or str(binding.get("source_scene_ref", "")) != str(case_state.data.scene): continue
			if str(binding.get("destination_scene_ref", "")) == id and condition(str(binding.get("condition_ref", ""))): permitted = true
		return {"known": true, "available": permitted, "reason": "当前路线尚未开放" if not permitted else ""}
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
	if not prepare_scene(id): return _notice("目的地资源未就绪，已保留原地点。")
	# 正式离场绑定要求先完成离场对白；目的地只保存为玩家请求，不在对白开始时传送。
	for binding in config.narrative_bindings("scene_exit_bindings"):
		if str(binding.get("scene_ref", "")) != str(case_state.data.scene): continue
		if not condition(str(binding.get("condition_ref", ""))): continue
		var exit_entry := str(binding.get("entry_ref", ""))
		if exit_entry.is_empty(): continue
		requested_destination = id
		if activate_entry(exit_entry, {"kind": "scene", "scene": case_state.data.scene, "view": case_state.data.view}): return true
		requested_destination = ""
		return false
	if not set_scene(id): return false
	return_context = {"kind": "scene", "scene": id, "view": case_state.data.view}
	_apply_music({"chapter_id": case_state.data.chapter})
	changed.emit()
	return true

func prepare_departure(id: String) -> String:
	# 地图准备先播放离场对白；实际地点与棋子只在对白完成并移动成功后提交。
	if not can_save() or not scene_status(id).available or not prepare_scene(id): return "failed"
	departure_ready_destination = ""
	for binding in config.narrative_bindings("scene_exit_bindings"):
		if str(binding.get("scene_ref", "")) != str(case_state.data.scene) or not condition(str(binding.get("condition_ref", ""))): continue
		var exit_entry := str(binding.get("entry_ref", ""))
		if exit_entry.is_empty(): continue
		requested_destination = id
		departure_managed = true
		if activate_entry(exit_entry, {"kind": "scene", "scene": case_state.data.scene, "view": case_state.data.view}): return "waiting"
		requested_destination = ""
		departure_managed = false
		return "failed"
	return "ready"

func cancel_departure() -> bool:
	if requested_destination.is_empty() or processing or response_active: return false
	requested_destination = ""
	departure_ready_destination = ""
	departure_managed = false
	call_stack.clear()
	return return_to_context()

func commit_prepared_departure(id: String) -> bool:
	if departure_ready_destination != id or not can_save() or not scene_status(id).available: return false
	if not set_scene(id): return false
	departure_ready_destination = ""
	return_context = {"kind": "scene", "scene": id, "view": case_state.data.view}
	_apply_music({"chapter_id": case_state.data.chapter})
	changed.emit()
	return true

func force_travel(id: String) -> bool:
	# 调试与测试用：跳过地点资格和保存条件直接前往，只在可操作调查中生效；不触发到达短场。
	if mode != "investigation" or not set_scene(id): return false
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
	# 只有实际到达才启动队列，地图预览、读档和局部返回不算到达。
	if mode != "investigation" or paused: return false
	arrival_pending = true
	return _continue_arrival()

func _continue_arrival() -> bool:
	# 同一到达先播放时地，再按优先级完成地点短场，不丢掉后续剧情。
	for binding in config.narrative_bindings("arrival_bindings"):
		if str(binding.get("scene_id", "")) != str(case_state.data.scene): continue
		if not condition(str(binding.get("condition_ref", ""))): continue
		var arrival_entry := str(binding.get("entry_ref", ""))
		if arrival_entry.is_empty() or case_state.data.texts.get(str(binding.get("text_id", "")), false): continue
		return activate_entry(arrival_entry, return_context)
	var scene_entries: Array = config.narrative_bindings("scene_entry_bindings")
	scene_entries.sort_custom(func(a, b): return int(a.get("priority", 100)) < int(b.get("priority", 100)))
	for binding in scene_entries:
		if str(binding.get("scene_ref", "")) != str(case_state.data.scene): continue
		var scene_entry := str(binding.get("entry_ref", ""))
		if scene_entry.is_empty() or case_state.data.entries.get(scene_entry, false): continue
		if not condition(str(binding.get("condition_ref", ""))): continue
		var entry_event := str(binding.get("event_ref", ""))
		if not entry_event.is_empty() and not case_state.event(entry_event, source_context()): return false
		return activate_entry(scene_entry, return_context)
	for id in ARRIVAL_ENTRIES.get(str(case_state.data.scene), []):
		var row: Dictionary = config.entries.get(id, {})
		if row.is_empty() or case_state.data.entries.get(id, false): continue
		if str(row.get("chapter_id", "")) != str(case_state.data.chapter): continue
		if condition(str(row.get("condition_id", ""))): return activate_entry(id, return_context)
	arrival_pending = false
	return false

func display_scene() -> String:
	return str(case_state.data.scene)

func investigation_view() -> String:
	# 局部图是当前检查的表现，不改变真实地点与存档中的主视图。
	var entry: Dictionary = config.entries.get(active_entry, {})
	if entry.get("location_mode") != "fixed" and return_context.get("kind") == "inspection" and return_context.get("scene") == case_state.data.scene:
		var detail := str(return_context.get("detail", ""))
		if not detail.is_empty(): return detail
	return str(case_state.data.view)

func can_cancel_inspection() -> bool:
	return not processing and not response_active and mode == "narrative" and (not requested_destination.is_empty() or (return_context.get("kind") == "inspection" and config.entries.get(active_entry, {}).get("location_mode", "caller") == "caller"))

func cancel_inspection() -> bool:
	# 提前返回只结束阅读，不执行入口完成事件，也不把未读完的观察记成已查。
	if not can_cancel_inspection(): return false
	if not requested_destination.is_empty(): return cancel_departure()
	call_stack.clear()
	return return_to_context()

func background_path() -> String:
	var entry: Dictionary = config.entries.get(active_entry, {})
	if entry.get("location_mode") == "fixed":
		for link in config.rows("narrative", "片段地点关联"):
			if link.sequence_id == entry.get("sequence_id") and not str(link.get("background_path", "")).is_empty(): return str(link.background_path)
	var model := InvestigationScript.new()
	model.bind(self)
	var view := investigation_view()
	var layers: Array = model.image_layers(view)
	var backgrounds: Array = layers.filter(func(row): return int(row.get("draw_layer", 0)) == 0)
	if not backgrounds.is_empty(): return str(backgrounds.back().image_path)
	var resource: Dictionary = model.view_resource(view)
	if resource.get("view_kind") in ["fixed_view", "scene_background"]: return str(resource.resource_or_text_ref)
	# 独立物件图保持其配置矩形，仍以当前场景为底，不把透明物件拉成整屏。
	var ref := str(config.scenes.get(case_state.data.scene, {}).get("background_ref", ""))
	return str(config.resources.get(ref, {}).get("path", ""))

func entry_label(id: String) -> String:
	for row in config.rows("investigation", "观察引用"):
		if row.entry_ref == id and not str(row.get("display_name", "")).is_empty(): return str(row.display_name)
	for row in config.rows("investigation", "话题显示"):
		if row.entry_ref == id: return str(row.public_name)
	var label := str(config.entries.get(id, {}).get("name", id))
	return "继续" if label.begins_with("ENTRY_") or label.begins_with("SEQ_") else label

func scene_name(scene_id: String) -> String:
	# 共用地点名称解析：有效 name_text_id 优先，空 ID 或未解析时回退 display_name；
	# 两者都缺时记录校验错误并给出玩家可理解文案，不显示内部 ID。
	var scene: Dictionary = config.scenes.get(scene_id, {})
	var name_ref := str(scene.get("name_text_id", ""))
	if not name_ref.is_empty():
		var translated: String = config.text(name_ref)
		if translated != name_ref: return translated
	var display := str(scene.get("display_name", ""))
	if not display.is_empty(): return display
	config.errors.append("场景名称缺失：" + scene_id)
	return "未知地点"

func choice_label(row: Dictionary) -> String:
	var label := str(row.get("option_text", ""))
	if not label.is_empty(): return label
	var operation := str(row.get("operation_id", ""))
	# 操作入口可以与地图目标不同；优先沿操作入口取正式名称，不能显示SC编号。
	if config.entries.has(operation): return entry_label(operation)
	if not operation.is_empty() and not operation.begins_with("ENTRY_"): return operation
	var target := str(row.get("target_ref", ""))
	if config.scenes.has(target): return scene_name(target)
	return entry_label(target)

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
	if not question_reading.is_empty() and question_reading.get("kind") == "press" and id == question:
		return _finish_question_reading()
	if not config.questions.has(id): return false
	if id == "T00_R02" and not _tutorial_pair_ready():
		_recover_missing_tutorial_materials()
		changed.emit()
		return _notice("请先到二楼休息室读完撤站移交清单，再回大厅核对登记册。")
	question = id
	current_statement = ""
	narrative.end_reading()
	var round: Dictionary = config.questions[id]
	var draft: Dictionary = case_state.data.drafts.get(id, {})
	current_statement = str(draft.get("current_statement", ""))
	if current_statement.is_empty():
		var binding := question_binding(id)
		current_statement = str(round.get("target_text_ref", binding.get("target_text_ref", "")))
	pending_result.clear()
	selected_target = draft.get("target", round.get("interaction_kind") == "reasoning") == true
	slots = draft.get("slots", ["", ""]).duplicate()
	if not case_state.data.chances.has(id): case_state.data.chances[id] = 3
	mode = "failure" if int(case_state.data.chances[id]) == 0 else "selection"
	if case_state.data.results.has(id):
		pending_result = case_state.data.results[id].duplicate(true)
		mode = "result"
	if mode == "selection":
		var targets: Array = question_binding().get("statement_refs", []).duplicate()
		if targets.is_empty() and round.get("interaction_kind") == "statement": targets.append(current_statement)
		if targets.any(func(ref): return not case_state.data.texts.get(str(ref), false)):
			return _read_question_texts(targets, "statement")
	changed.emit()
	return true

func _tutorial_pair_ready() -> bool:
	return case_state.owns("E01_V1") and case_state.owns("E28_V1") and case_state.data.events.get("EV_E01_READ", false)

func _recover_missing_tutorial_materials() -> void:
	# 兼容旧版提前进入双卡核对的存档：只退出缺牌的操作，不伪造材料或完成回执。
	if not question.is_empty(): _store_draft()
	mode = "investigation"
	active_entry = ""
	reader.clear()
	question_reading.clear()
	call_stack.clear()
	response_active = false
	response_after.clear()
	pending_result.clear()
	return_context = {"kind": "scene", "scene": case_state.data.scene, "view": case_state.data.view}
	narrative.end_reading()

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
	var ref := current_statement
	if ref.is_empty():
		var row: Dictionary = config.questions.get(question, {})
		ref = str(row.get("target_text_ref", ""))
	return config.text(ref)

func question_binding(id: String = "") -> Dictionary:
	if id.is_empty(): id = question
	for row in config.narrative_bindings("question_bindings"):
		if str(row.get("question_id", "")) == id: return row
	return {}

func statement_options() -> Array:
	var result: Array = []
	var binding := question_binding()
	for ref in binding.get("statement_refs", []):
		var id := str(ref)
		if id.is_empty() or not config.texts.has(id): continue
		result.append({"id": id, "text": config.text(id), "heard": bool(case_state.data.texts.get(id, false)), "selected": id == current_statement})
	return result

func select_statement(id: String) -> bool:
	if mode != "selection" or not question_binding().get("statement_refs", []).has(id): return false
	if not case_state.data.texts.get(id, false): return _notice("只能选定实际听过的原话。")
	current_statement = id
	selected_target = false
	_store_draft()
	changed.emit()
	return true

func read_statement(id: String) -> bool:
	var targets: Array = question_binding().get("statement_refs", []).duplicate()
	if targets.is_empty(): targets.append(str(config.questions.get(question, {}).get("target_text_ref", "")))
	if mode != "selection" or id not in targets: return false
	current_statement = id
	selected_target = false
	return _read_question_texts([id], "statement")

func _read_question_texts(targets: Array, kind: String) -> bool:
	# 证言按配置逐句、逐页播放；原句并非只显示在按钮上便算实际听过。
	var refs: Array = []
	for target in targets:
		var pages: Array = [target]
		if kind == "statement":
			for binding in config.narrative_bindings("statement_bindings"):
				if binding.get("question_id") == question and binding.get("target_text_ref") == target:
					pages = binding.get("text_refs", [target])
					break
		for page_ref in pages:
			if not config.texts.has(str(page_ref)): return _notice("证言正文缺失：" + str(page_ref))
			if page_ref not in refs: refs.append(page_ref)
	if refs.is_empty(): return false
	_store_draft()
	question_reading = {"kind": kind, "texts": refs, "index": 0, "entry": active_entry, "context": return_context.duplicate(true)}
	mode = "narrative"
	var ok: bool = narrative.show_text(str(refs[0]))
	changed.emit()
	return ok

func read_question_hint() -> bool:
	if mode != "selection": return false
	return _read_question_texts(question_binding().get("hint_text_refs", []), "hint")

func press_statement() -> bool:
	if mode != "selection" or not case_state.data.texts.get(current_statement, false): return false
	var binding := question_binding()
	var refs: Array = binding.get("statement_refs", [])
	var presses: Array = binding.get("press_entry_refs", [])
	var index := refs.find(current_statement)
	if index < 0 or index >= presses.size(): return false
	_store_draft()
	var old_entry := active_entry
	var old_context := return_context.duplicate(true)
	question_reading = {"kind": "press", "entry": old_entry, "context": old_context, "statement": current_statement, "press_entry": str(presses[index])}
	if activate_entry(str(presses[index])): return true
	question_reading.clear()
	active_entry = old_entry
	return_context = old_context
	mode = "selection"
	return false

func _finish_question_reading() -> bool:
	var reading := question_reading.duplicate(true)
	if reading.get("kind") == "press":
		for binding in config.narrative_bindings("statement_bindings"):
			if binding.get("question_id") != question or binding.get("target_text_ref") != reading.get("statement"): continue
			var event_id := str(binding.get("press_completion_event_ref", ""))
			if not event_id.is_empty() and not case_state.event(event_id, source_context()): return false
	question_reading.clear()
	active_entry = str(reading.get("entry", active_entry))
	return_context = reading.get("context", return_context).duplicate(true)
	mode = "selection"
	narrative.end_reading()
	_store_draft()
	changed.emit()
	return true

func can_continue_question() -> bool:
	var binding := question_binding()
	return mode == "selection" and not str(binding.get("continue_entry_ref", "")).is_empty() and condition(str(binding.get("continue_condition_ref", "")))

func continue_question() -> bool:
	if not can_continue_question(): return false
	return activate_entry(str(question_binding().continue_entry_ref))

func complete_cat_interaction() -> bool:
	var binding: Dictionary = config.narrative_data.get("cat_reward_binding", {})
	var key := str(binding.get("count_state_key", "cat_pet_completed_count"))
	var count := mini(int(binding.get("count_cap", 5)), int(case_state.data.get(key, 0)) + 1)
	case_state.data[key] = count
	if count < int(binding.get("threshold", 5)): return false
	var entry_id := str(binding.get("reward_entry_ref", ""))
	if not entry_id.is_empty() and config.entries.has(entry_id) and not case_state.data.entries.get(entry_id, false):
		return activate_entry(entry_id, {"kind": "scene", "scene": case_state.data.scene, "view": case_state.data.view})
	return true

func select_target() -> bool:
	if mode != "selection": return false
	var id := current_statement if not current_statement.is_empty() else str(config.questions[question].get("target_text_ref", ""))
	if config.questions[question].interaction_kind == "statement" and not case_state.data.texts.get(id, false): return _notice("只能选定实际听过的原话。")
	selected_target = true
	_store_draft()
	changed.emit()
	return true

func select_slot(index: int) -> bool:
	if mode != "selection" or index not in [0, 1]: return false
	active_slot = index
	changed.emit()
	return true

func select_content(id: String, slot: int = -1) -> bool:
	if mode != "selection" or not case_state.owns(id): return false
	var material := str(config.contents[id].material_id)
	for i in range(slots.size()):
		if not str(slots[i]).is_empty() and config.contents[slots[i]].material_id == material:
			return _notice("这份材料已入槽，请先撤下再切换版本。")
	if slot < 0 and active_slot in [0, 1]: slot = active_slot
	if slot < 0: slot = slots.find("")
	if slot < 0 or slot > 1: return _notice("两处引用夹位已满，请先撤下一张。")
	slots[slot] = id
	active_slot = -1
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
	draft.merge({"target": selected_target, "current_statement": current_statement, "slots": slots.duplicate()}, true)
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
	if processing or mode != "selection" or not selected_target: return false
	if not question_binding().get("requires_actual_presentation", true) or slots.all(func(id): return str(id).is_empty()): return false
	var selected: Array = slots.filter(func(id): return not str(id).is_empty())
	var matches: Array = []
	for row in config.relations:
		if row.question_ref != question or not condition(str(row.get("condition_ref", ""))): continue
		if not current_statement.is_empty() and str(row.get("target_text_ref", "")) != current_statement: continue
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
			if not str(error.get("target_text_ref", "")).is_empty() and str(error.get("target_text_ref")) != current_statement: continue
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
			# B07必须先听完承认知情，再碎屏，最后进入共同供述。
			if climax != "B07": _play_result_effect(pending_result.presentation)
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
	if processing or mode != "result" or pending_result.is_empty() or pending_result.get("effect_pending", false): return false
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
	var completed_result: Dictionary = config.results.get(pending_result.get("result", ""), {})
	if completed_result.get("climax_key") == "B07" and not pending_result.get("effect_played", false):
		_play_result_effect(config.presentation(completed_result))
	changed.emit()
	# 先播完的演出也要在回应末尾兑现接续，不额外停在已经完成的结果页。
	if not pending_result.get("effect_pending", false) and not str(completed_result.get("after_effect_entry_ref", "")).is_empty():
		continue_result()
	return true

func _play_result_effect(data: Dictionary) -> void:
	pending_result["effect_pending"] = true
	pending_result["effect_played"] = true
	result_presentation_requested.emit(data)

func finish_result_effect() -> void:
	# 表现结束只兑现已经成立的接续；未收下的推论绝不在这里取得。
	processing = false
	if pending_result.is_empty() or not pending_result.get("effect_pending", false): return
	pending_result["effect_pending"] = false
	var result: Dictionary = config.results.get(pending_result.get("result", ""), {})
	var after_accept := str(result.get("after_accept_entry_ref", ""))
	var after_effect := str(result.get("after_effect_entry_ref", ""))
	if pending_result.get("response_read", false) and ((pending_result.get("accepted", false) and not after_accept.is_empty()) or not after_effect.is_empty()):
		continue_result()

func accept_inference() -> bool:
	if processing or mode != "result" or pending_result.is_empty() or pending_result.get("effect_pending", false) or pending_result.get("accepted", false): return false
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
	_play_result_effect({"feedback_key": "collect", "duration_ms": 900.0 / 0.75, "effect_level": "collect", "content_id": str(result.get("inference_content_ref", ""))})
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
	if processing or mode != "result" or pending_result.is_empty() or pending_result.get("effect_pending", false): return false
	var result: Dictionary = config.results.get(pending_result.get("result", ""), {})
	if pending_result.get("complete", false):
		if pending_result.get("response_after_accept", false) and not pending_result.get("accepted", false): return false
		if not pending_result.get("response_read", false): return read_result_response()
		if not str(result.get("inference_content_ref", "")).is_empty() and not pending_result.get("accepted", false): return false
		var continuation: Dictionary = pending_result.get("continuation", {}).duplicate(true)
		var accepted := not str(result.get("inference_content_ref", "")).is_empty()
		var explicit_after := str(result.get("after_accept_entry_ref", "")) if accepted else ""
		if explicit_after.is_empty(): explicit_after = str(result.get("after_effect_entry_ref", ""))
		# 后续入口也可能因资源或条件暂时不可用；失败时保留已读回应与待继续结果。
		# 不能先清空结果再返回false，否则会留下无法继续、也无法存读的空结果页。
		var before := export_snapshot() if not explicit_after.is_empty() else {}
		save_due = true
		pending_result.clear()
		slots = ["", ""]
		selected_target = false
		case_state.data.drafts.erase(question)
		if not explicit_after.is_empty():
			if activate_entry(explicit_after): return true
			var reason := last_notice
			restore_snapshot(before)
			return _notice(reason if not reason.is_empty() else "后续内容尚未就绪，当前核查结果已保留。")
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
		"question": question, "current_statement": current_statement, "selected_target": selected_target, "slots": slots.duplicate(), "pending_result": pending_result.duplicate(true),
		"response_active": response_active, "response_after": response_after.duplicate(true), "call_stack": call_stack.duplicate(true),
		"question_reading": question_reading.duplicate(true), "arrival_pending": arrival_pending,
		"contextual_presentation": contextual_presentation.duplicate(true), "active_slot": active_slot,
		"narrative": narrative.export_snapshot() if not narrative.state.is_empty() else {}, "bgm": last_bgm,
		"stage_dirty": stage_dirty, "save_due": save_due, "page_snapshot": page_snapshot.duplicate(true),
		"ending_media": ending_media.duplicate(true), "requested_destination": requested_destination, "ending_status": "completed" if state.ending_completed else ("active" if state.ending_started else ""),
		"progress_summary": {"scene": scene_name(str(state.scene)), "phase": str(config.chapters[state.chapter].name), "question": target_text() if not question.is_empty() else ""}}

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
	var statement := str(snapshot.get("current_statement", ""))
	if not statement.is_empty() and not config.texts.has(statement): return false
	var reading = snapshot.get("question_reading", {})
	if not reading is Dictionary: return false
	if not reading.is_empty():
		if reading.get("kind") not in ["statement", "hint", "press"] or q.is_empty(): return false
		if not config.entries.has(str(reading.get("entry", ""))) or not _valid_context(reading.get("context", {})): return false
		if snapshot.mode != "narrative": return false
		if reading.kind == "press":
			if not config.texts.has(str(reading.get("statement", ""))) or not config.entries.has(str(reading.get("press_entry", ""))): return false
			var binding := question_binding(q)
			var statements: Array = binding.get("statement_refs", [])
			var presses: Array = binding.get("press_entry_refs", [])
			var press_index := statements.find(str(reading.statement))
			if press_index < 0 or press_index >= presses.size() or str(presses[press_index]) != str(reading.press_entry): return false
		else:
			var refs = reading.get("texts")
			var read_index = reading.get("index")
			if not refs is Array or refs.is_empty(): return false
			if not (read_index is int or read_index is float) or not is_finite(float(read_index)) or float(read_index) != floorf(float(read_index)): return false
			if int(read_index) < 0 or int(read_index) >= refs.size(): return false
			for text_id in refs:
				if not text_id is String or not config.texts.has(text_id): return false
	var slot_index = snapshot.get("active_slot", -1)
	if not (slot_index is int or slot_index is float) or not is_finite(float(slot_index)) or float(slot_index) != floorf(float(slot_index)) or int(slot_index) not in [-1, 0, 1]: return false
	if not snapshot.get("arrival_pending", false) is bool: return false
	var presentation = snapshot.get("contextual_presentation", {})
	if not presentation is Dictionary: return false
	if not presentation.is_empty():
		if not config.actors.has(str(presentation.get("actor_id", ""))) or not case_state._incoming_owns(snapshot.case_state, str(presentation.get("content_id", ""))): return false
		if not config.events.has(str(presentation.get("completion_event_ref", ""))): return false
	if not snapshot.get("slots") is Array or snapshot.slots.size() != 2: return false
	if not snapshot.get("selected_target") is bool or not snapshot.get("response_active") is bool: return false
	if not snapshot.get("run_id") is String or str(snapshot.run_id).is_empty(): return false
	if not snapshot.get("requested_destination", "") is String or (not str(snapshot.get("requested_destination", "")).is_empty() and not config.scenes.has(str(snapshot.requested_destination))): return false
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
	if not statement.is_empty() and q.is_empty(): return false
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
	if not _valid_page_snapshot(snapshot.get("page_snapshot", {}), snapshot.case_state): return false
	if not snapshot.get("ending_media", {}) is Dictionary: return false
	if not _valid_sources(pending.get("sources", []), snapshot.case_state): return false
	return true

func _valid_page_snapshot(value, incoming: Dictionary) -> bool:
	# 页面状态来自存档文件，先完整检查形状，再调用页面的强类型恢复接口。
	if not value is Dictionary or not _valid_sources(value, incoming): return false
	if not value.has("reader"): return true
	var page = value.reader
	if not page is Dictionary: return false
	for key in ["visible", "entry", "selectable", "star", "filters_open"]:
		if page.has(key) and not page[key] is bool: return false
	for key in ["content", "person", "selected_material", "tab", "category", "sort"]:
		if page.has(key) and not page[key] is String: return false
	for key in ["positions", "library_positions", "library_pages"]:
		if not page.get(key, {}) is Dictionary: return false
		for amount in page.get(key, {}).values():
			if not (amount is int or amount is float) or not is_finite(float(amount)) or float(amount) < 0: return false
	if not page.get("document", {}) is Dictionary or not page.get("stack", []) is Array or not page.get("new_list", []) is Array: return false
	var index = page.get("new_index", 0)
	if not (index is int or index is float) or not is_finite(float(index)) or float(index) != floorf(float(index)) or float(index) < 0: return false
	for content_id in page.get("new_list", []):
		if not content_id is String or not case_state._incoming_owns(incoming, content_id): return false
	var selected = page.get("selected_material", "")
	if not str(selected).is_empty() and not case_state._incoming_owns(incoming, selected): return false
	for frame in page.get("stack", []):
		if not frame is Dictionary or not frame.get("content", "") is String or not frame.get("selectable", false) is bool or not frame.get("document", {}) is Dictionary: return false
	return true

func _valid_context(value) -> bool:
	if not value is Dictionary: return false
	if value.is_empty(): return true
	if value.get("kind", "scene") not in ["scene", "topics", "inspection", "scene_items", "reasoning"]: return false
	if not config.scenes.has(str(value.get("scene", ""))): return false
	var view_id := str(value.get("view", ""))
	if view_id == str(config.scenes[value.scene].default_view_id): return true
	for resource in config.rows("investigation", "资源需求"):
		if str(resource.get("scene_id", "")) in ["", str(value.scene)] and str(resource.get("view_id", "")) == view_id: return true
	return false

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
	current_statement = str(snapshot.get("current_statement", ""))
	selected_target = bool(snapshot.selected_target)
	slots = snapshot.slots.duplicate()
	pending_result = snapshot.pending_result.duplicate(true)
	response_active = bool(snapshot.response_active)
	response_after = snapshot.response_after.duplicate(true)
	question_reading = snapshot.get("question_reading", {}).duplicate(true)
	arrival_pending = bool(snapshot.get("arrival_pending", false))
	contextual_presentation = snapshot.get("contextual_presentation", {}).duplicate(true)
	active_slot = int(snapshot.get("active_slot", -1))
	call_stack = snapshot.get("call_stack", []).duplicate(true)
	elapsed_seconds = float(snapshot.elapsed_seconds)
	run_id = str(snapshot.run_id)
	initial_saved = true
	stage_dirty = bool(snapshot.get("stage_dirty", false))
	save_due = bool(snapshot.get("save_due", false))
	autosave_failed = false
	page_snapshot = snapshot.get("page_snapshot", {}).duplicate(true)
	ending_media = snapshot.get("ending_media", {}).duplicate(true)
	requested_destination = str(snapshot.get("requested_destination", ""))
	departure_ready_destination = ""
	departure_managed = false
	if snapshot.narrative.is_empty(): narrative.state = {}
	else: narrative.restore_snapshot(snapshot.narrative)
	if mode == "selection" and question == "T00_R02" and not _tutorial_pair_ready():
		_recover_missing_tutorial_materials()
		_notice("请先到二楼休息室读完撤站移交清单，再回大厅继续核对。")
	last_bgm = str(snapshot.get("bgm", ""))
	music_requested.emit(last_bgm)
	changed.emit()
	return true
