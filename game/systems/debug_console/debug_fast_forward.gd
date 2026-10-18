extends RefCounted
## 隔离快进：在临时会话里沿真实玩家动作推进剧情，命中目标后交出存档快照。
## 不触碰正在运行的会话、界面和存档；动作选择沿用 tests/aurora_playthrough_test.gd，
## 事件、材料、人物位置全部由游戏自己的规则产生，不强改章节或事件。
const SessionScript = preload("res://systems/aurora/aurora_session.gd")
const InvestigationScript = preload("res://systems/aurora/aurora_investigation.gd")
const MAX_ACTIONS := 6000
const MAX_MILLISECONDS := 120000
const FRAME_BUDGET_MS := 14
const DRAIN_OK := 0
const DRAIN_FAILED := 1
const DRAIN_REACHED := 2

var host: Node
var shared_config: RefCounted
var progress: Callable
var cancelled := false
var session: Node
var failure := ""
var actions := 0
var _model: RefCounted
var _attempted := {}
var _signature := ""
var _visits := {}
var _choice_visits := {}
var _entry_scenes := {}

func cancel() -> void:
	cancelled = true

## 目标形如 {"kind": "chapter", "chapter": "CH03"}、{"kind": "ending"}、{"kind": "level", "question": "L07_R02"}。
func run(goal: Dictionary) -> Dictionary:
	_reset()
	var result := {"ok": false, "message": "", "actions": 0, "snapshot": {}}
	session = SessionScript.new()
	host.add_child(session)
	session.seen_storage_path = ""
	if not session.initialize(str(shared_config.definition.root), shared_config) or not session.new_game():
		result.message = "临时会话无法开始新游戏。" + str(session.last_notice)
		_dispose()
		return result
	_model = InvestigationScript.new()
	_model.bind(session)
	var started := Time.get_ticks_msec()
	var frame_start := started
	var tree := host.get_tree()
	var last_report := 0
	for step in range(MAX_ACTIONS):
		var state := _drain(goal)
		if state == DRAIN_FAILED: break
		if state == DRAIN_REACHED or _reached(goal): return _finish(result)
		if session.mode == "credits":
			failure = "已经走到片尾，仍没有遇到目标：" + str(goal.get("label", goal.kind))
			break
		if session.mode != "investigation":
			failure = "快进停在未知状态：" + str(session.mode)
			break
		if not _act():
			failure = "当前章节没有可继续推进的入口：" + str(session.case_state.data.chapter)
			break
		var now := Time.get_ticks_msec()
		if progress.is_valid() and now - last_report >= 120:
			last_report = now
			progress.call("%s  已执行 %d 步" % [session.case_state.data.chapter, actions])
		if now - frame_start >= FRAME_BUDGET_MS:
			await tree.process_frame
			frame_start = Time.get_ticks_msec()
			if cancelled:
				failure = "快进已取消。"
				break
			if frame_start - started > MAX_MILLISECONDS:
				failure = "快进超过 %d 秒仍未到达目标，已停止。" % (MAX_MILLISECONDS / 1000)
				break
	if failure.is_empty(): failure = "快进步数超过上限 %d，已停止。" % MAX_ACTIONS
	result.message = failure
	result.actions = actions
	_dispose()
	return result

func _finish(result: Dictionary) -> Dictionary:
	var snapshot: Dictionary = session.export_snapshot()
	if not session.validate_snapshot(snapshot):
		result.message = "快进到达目标，但得到的存档未通过完整性校验。"
		_dispose()
		return result
	result.ok = true
	result.snapshot = snapshot
	result.actions = actions
	result.chapter = str(session.case_state.data.chapter)
	result.scene = str(session.case_state.data.scene)
	result.mode = str(session.mode)
	_dispose()
	return result

func _reset() -> void:
	cancelled = false
	failure = ""
	actions = 0
	_attempted.clear()
	_signature = ""
	_visits.clear()
	_choice_visits.clear()
	_entry_scenes.clear()

func _dispose() -> void:
	if is_instance_valid(session): session.queue_free()
	session = null
	_model = null

func _reached(goal: Dictionary) -> bool:
	match str(goal.kind):
		# 部分章节（如第五章）剧情直接衔接下一章，没有稳定的调查画面；
		# 取该章或其后第一个可操作点。
		"chapter": return session.mode == "investigation" and chapter_index(session.config, str(session.case_state.data.chapter)) >= chapter_index(session.config, str(goal.chapter))
		"ending": return session.mode == "credits"
		"level": return session.mode == "investigation" and level_open(session, str(goal.question)) and not solvable_rows(session, str(goal.question)).is_empty()
	return false

static func chapter_index(config: RefCounted, chapter_id: String) -> int:
	return config.chapters.keys().find(chapter_id)

## 关卡的入口已开放：关卡条件、入口条件和触发原话都已满足，且尚未完成。
static func level_open(target: Node, question_id: String) -> bool:
	var config: RefCounted = target.config
	var row: Dictionary = config.questions.get(question_id, {})
	if row.is_empty() or target.case_state.data.completed_questions.has(question_id): return false
	var entry: Dictionary = config.entries.get(str(row.get("entry_ref", "")), {})
	if entry.is_empty() or not target.condition(str(row.get("condition_ref", ""))) or not target.condition(str(entry.get("condition_id", ""))): return false
	var trigger := str(row.get("trigger_text_ref", ""))
	return trigger.is_empty() or bool(target.case_state.data.texts.get(trigger, false))

## 出示关系用到的全部内容版本（A、B 与依据）。
static func relation_refs(row: Dictionary) -> Array:
	var refs: Array = []
	for field in ["a_content_ref", "b_content_ref", "basis_content_ref"]:
		if not str(row.get(field, "")).is_empty(): refs.append(str(row[field]))
	return refs

## 当前状态下能让该关卡过关的出示关系：条件成立、非"不足"结果、所需材料版本都已持有。
static func solvable_rows(target: Node, question_id: String) -> Array:
	var found: Array = []
	for row in target.config.relations:
		if row.question_ref != question_id or not target.condition(str(row.get("condition_ref", ""))): continue
		if target.config.results[row.result_ref].feedback_key == "insufficient": continue
		if relation_refs(row).all(func(id): return target.case_state.owns(id)): found.append(row)
	return found

func _fail(message: String) -> int:
	failure = message
	return DRAIN_FAILED

func _drain(goal: Dictionary) -> int:
	for step in range(2000):
		# 实际走进目标关卡的选材界面，且已持有可过关的材料时立即停下，不替玩家作答。
		if str(goal.kind) == "level" and session.mode == "selection" and str(session.question) == str(goal.question) and not solvable_rows(session, str(goal.question)).is_empty(): return DRAIN_REACHED
		match str(session.mode):
			"narrative":
				session.narrative.tick(100)
				if session.narrative.state.waiting_for_choice:
					var choices: Array = session.narrative.available_choices
					if choices.is_empty(): return _fail("选项为空：" + str(session.active_entry))
					var source: String = str(session.narrative.state.current_text_id) + str(session.active_entry)
					var index := int(_choice_visits.get(source, 0)) % choices.size()
					_choice_visits[source] = int(_choice_visits.get(source, 0)) + 1
					if not session.narrative.choose_transition(index): return _fail("选择无法接续：" + str(session.active_entry) + " " + str(session.last_notice))
				else: session.narrative.advance()
			"material":
				if not session.material_read_complete(): return _fail("原件无法读完：" + str(session.active_entry))
			"selection":
				if not _solve_selection(): session.collapse_question(); return DRAIN_OK
			"result":
				if not _advance_result(): return DRAIN_FAILED
			"investigation", "credits": return DRAIN_OK
			_: return _fail("快进停在未知状态：" + str(session.mode))
	return _fail("正文接续形成循环：" + str(session.active_entry) + " " + str(session.last_notice))

## 用实际取得的版本逐条尝试出示关系；找不到可行关系就收起问题，留待后续章节条件成熟。
func _solve_selection() -> bool:
	for row in solvable_rows(session, str(session.question)):
		session.clear_slot(0)
		session.clear_slot(1)
		if not session.select_target(): continue
		for field in ["a_content_ref", "b_content_ref"]:
			if not str(row.get(field, "")).is_empty(): session.select_content(str(row[field]))
		if session.present(): return true
	return false

## 推进一次结果界面：先提交待收推论或读回应，再收下推论，最后继续；失败时记录原因。
func _advance_result() -> bool:
	var result: Dictionary = session.config.results.get(session.pending_result.get("result", ""), {})
	var step := ""
	var ok := true
	if session.pending_result.get("response_after_accept", false) and not session.pending_result.get("accepted", false):
		step = "收下后回应无法提交："
		ok = session.accept_inference()
	elif not session.pending_result.get("response_read", false):
		step = "回应无法开始："
		ok = session.read_result_response()
	elif not str(result.get("inference_content_ref", "")).is_empty() and not session.pending_result.get("accepted", false):
		step = "推论无法收下："
		ok = session.accept_inference()
	else:
		step = "结果无法继续："
		ok = session.continue_result()
	if not ok: failure = step + str(session.question)
	return ok

## 从当前可达入口中挑访问次数最少者执行一次；返回是否有动作被执行。
func _act() -> bool:
	var current := "%s/%s/%s/%s" % [session.case_state.data.chapter, session.case_state.data.events, session.case_state.data.materials, session.case_state.data.texts.size()]
	if current != _signature:
		_signature = current
		_attempted.clear()
	for id in _external():
		var row: Dictionary = session.config.entries[id]
		var scenes: Array = session.config.ids(str(row.get("allowed_scene_ids", "")))
		var scene: String = str(_entry_scenes.get(id, scenes[0] if not scenes.is_empty() else str(session.case_state.data.scene)))
		var key := scene + "/" + str(id)
		if _attempted.has(key) or not session.scene_status(scene).available: continue
		_attempted[key] = true
		if scene != session.case_state.data.scene:
			if not session.travel(scene): continue
			if session.arrive(): return true
		if session.activate_entry(id, {"kind": "scene", "scene": scene, "view": session.case_state.data.view}):
			_visits[id] = int(_visits.get(id, 0)) + 1
			actions += 1
			return true
	return false

func _external() -> Array:
	var ids := {}
	_entry_scenes.clear()
	var old_scene: String = session.case_state.data.scene
	var old_view: String = session.case_state.data.view
	for scene in session.config.scenes:
		if not session.scene_status(scene).available: continue
		session.case_state.data.scene = scene
		session.case_state.data.view = session.config.scenes[scene].default_view_id
		for item in _model.scene_options():
			ids[str(item.entry_ref)] = true
			_entry_scenes[str(item.entry_ref)] = scene
		for hotspot in _model.hotspots():
			var candidates: Array = _model.observation_options(str(hotspot.object_ref)) if hotspot.object_kind != "character" else _model.topics(str(hotspot.get("topic_entry_ref", "")))
			candidates.append({"entry_ref": hotspot.get("inspect_entry_ref", "")})
			for item in candidates:
				var id := str(item.entry_ref)
				if session.config.entries.has(id):
					ids[id] = true
					_entry_scenes[id] = scene
		for item in session.available_reasoning():
			ids[str(item.entry)] = true
			_entry_scenes[str(item.entry)] = scene
		session.case_state.data.scene = old_scene
		session.case_state.data.view = old_view
	for row in session.config.rows("objective", "正式事项"):
		var goals: Array = session.config.rows("objective", "正式目标").filter(func(goal): return goal.goal_id == row.goal_id and session.condition(str(goal.get("condition_id", ""))))
		if goals.is_empty() or not session.condition(str(row.get("condition_id", ""))): continue
		if not str(row.get("completion_condition_id", "")).is_empty() and session.condition(str(row.completion_condition_id)): continue
		var id := str(row.get("target_ref", ""))
		if session.config.entries.has(id):
			ids[id] = true
			_entry_scenes[id] = str(row.get("scene_id", ""))
	var ordered := ids.keys()
	ordered.sort_custom(func(a, b): return int(_visits.get(a, 0)) < int(_visits.get(b, 0)))
	return ordered
