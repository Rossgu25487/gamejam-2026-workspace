extends RefCounted
## 自动推进引擎：沿真实玩家动作推进剧情直到目标，可驱动正在运行的游戏（实机）或隔离的临时会话。
## 动作选择沿用 tests/aurora_playthrough_test.gd；事件、材料、人物位置全部由游戏自己的规则产生，
## 不强改章节或事件。推进过程中一路采集报告：章节时间线、关卡过程、覆盖率，
## 以及异常（游戏提示、界面与会话不一致、存档校验与读档往返不一致、失败界面与重试）。
## 跳关（jump）也走这里：隔离会话 + 通关打法 + 目标，到达后交出存档快照。
const SessionScript = preload("res://systems/aurora/aurora_session.gd")
const InvestigationScript = preload("res://systems/aurora/aurora_investigation.gd")
const STRATEGIES := {"win": "通关打法", "fail": "错误尝试", "random": "随机打法"}
const CHOICE_POLICIES := {"cycle": "循环取项", "first": "总选第一项", "last": "总选最后一项", "random": "随机取项"}
const COMPLETE_FEEDBACK := ["support", "exclude", "inference", "limit"]
const MAX_STEPS := 90000
const MAX_MILLISECONDS := 180000
const FRAME_BUDGET_MS := 14
const NARRATIVE_LOOP_LIMIT := 3000
const UI_MISMATCH_FRAMES := 3
const PROCESSING_WAIT_MS := 5000
const PROCESSING_GRACE_MS := 2000
const MENU_WAIT_MS := 180000
const TRACE_LIMIT := 40
const DECISION_LIMIT := 6000
const CONTINUE := 0
const DONE := 1
const FAILED := 2
const WAIT := 3
const SWEEP_LIMIT := 10
const REFUSED_LIMIT := 40

var host: Node
var session: Node
var shared_config: RefCounted
var start_snapshot := {}
var app: Control
var isolated := true
var checks := true
var strategy := "win"
var choice_policy := "cycle"
var seed_value := 0
var delay_ms := 0
var goal := {"kind": "ending", "label": "片尾演职员画面"}
var progress: Callable
## 可选的逐步观察钩子：每一步开始前以 (步数, 会话) 调用，供测试和排查使用。
var step_hook: Callable
var cancelled := false
var report := {}
var failure := ""
var steps := 0
var actions := 0
var _model: RefCounted
var _twin: Node
var _rng := RandomNumberGenerator.new()
var _attempted := {}
var _signature := ""
var _visits := {}
var _choice_visits := {}
var _choice_stall := {}
var _entry_scenes := {}
var _levels := {}
var _plans := {}
var _force_failure := {}
var _anomaly_index := {}
var _decisions: Array = []
var _trace: Array = []
var _timeline: Array = []
var _scenes_seen := {}
var _last_chapter := ""
var _last_completed := 0
var _pending_checkpoint := ""
var _narrative_run := 0
var _sweeps := 0
var _refused_run := 0
var _probing := false
var _probe_notice := ""
var _ui_bad := 0
var _wait_since := 0
var _result_stamp := ""
var _started := 0
var _stats := {}

func cancel() -> void:
	cancelled = true

## 目标形如 {"kind": "chapter", "chapter": "CH03"}、{"kind": "ending"}、{"kind": "level", "question": "L07_R02"}。
func run() -> Dictionary:
	_reset()
	_started = Time.get_ticks_msec()
	var tree := host.get_tree()
	var verdict := CONTINUE if _begin() else FAILED
	var slice_start := _started
	var last_report := 0
	while verdict == CONTINUE or verdict == WAIT:
		verdict = _step()
		if verdict == DONE or verdict == FAILED: break
		var now := Time.get_ticks_msec()
		if progress.is_valid() and now - last_report >= 120:
			last_report = now
			progress.call(progress_text())
		if verdict == WAIT or delay_ms > 0 or now - slice_start >= FRAME_BUDGET_MS:
			if delay_ms > 0 and verdict != WAIT: await tree.create_timer(delay_ms / 1000.0, true, false, true).timeout
			else: await tree.process_frame
			slice_start = Time.get_ticks_msec()
			if cancelled:
				failure = "已取消。"
				verdict = FAILED
				break
			if delay_ms == 0 and slice_start - _started > MAX_MILLISECONDS:
				failure = "运行超过 %d 秒仍未到达目标，已停止。" % (MAX_MILLISECONDS / 1000)
				verdict = FAILED
				break
			_check_ui()
	return _conclude(verdict == DONE)

func progress_text() -> String:
	if session == null: return ""
	var data: Dictionary = session.case_state.data
	return "%s  第 %d 步  动作 %d  关卡 %d/%d  %.1f 秒" % [data.chapter, steps, actions, data.completed_questions.size(), session.config.questions.size(), (Time.get_ticks_msec() - _started) / 1000.0]

# ---------- 起止 ----------

func _reset() -> void:
	cancelled = false
	failure = ""
	steps = 0
	actions = 0
	_attempted.clear()
	_signature = ""
	_visits.clear()
	_choice_visits.clear()
	_choice_stall.clear()
	_entry_scenes.clear()
	_levels.clear()
	_plans.clear()
	_force_failure.clear()
	_anomaly_index.clear()
	_decisions.clear()
	_trace.clear()
	_timeline.clear()
	_scenes_seen.clear()
	_last_chapter = ""
	_last_completed = 0
	_pending_checkpoint = ""
	_narrative_run = 0
	_sweeps = 0
	_refused_run = 0
	_probing = false
	_ui_bad = 0
	_wait_since = 0
	_result_stamp = ""
	_stats = {"paragraphs": 0, "choices": 0, "refused": 0, "materials": 0, "presents": 0, "wrong": 0, "failures": 0, "retries": 0, "travels": 0, "arrivals": 0, "probe_notices": 0, "checkpoints": 0, "roundtrips": 0}
	report = {"anomalies": []}

func _begin() -> bool:
	_rng.seed = seed_value
	if isolated:
		session = SessionScript.new()
		host.add_child(session)
		session.seen_storage_path = ""
		if not session.initialize(str(shared_config.definition.root), shared_config):
			failure = "临时会话无法初始化。"
			return false
		var started: bool = session.restore_snapshot(start_snapshot) if not start_snapshot.is_empty() else session.new_game()
		if not started:
			failure = "临时会话无法开始：" + str(session.last_notice)
			return false
	elif session == null:
		failure = "没有可驱动的会话。"
		return false
	_model = InvestigationScript.new()
	_model.bind(session)
	if not session.notice.is_connected(_on_notice): session.notice.connect(_on_notice)
	_last_chapter = str(session.case_state.data.chapter)
	_last_completed = session.case_state.data.completed_questions.size()
	_timeline.append({"chapter": _last_chapter, "step": 0, "actions": 0, "ms": 0})
	return true

func _conclude(reached: bool) -> Dictionary:
	var elapsed := Time.get_ticks_msec() - _started
	if reached and str(goal.kind) == "ending" and not session.case_state.data.ending_started: _anomaly("flow", "到达片尾画面，但案件状态没有记录片尾已开始。")
	var result := {"ok": false, "message": "", "actions": actions, "snapshot": {}}
	if session != null:
		if reached:
			_checkpoint("到达目标")
			_missing_levels()
		report.final = {"chapter": str(session.case_state.data.chapter), "scene": str(session.case_state.data.scene), "mode": str(session.mode)}
		report.coverage = _coverage()
		if session.notice.is_connected(_on_notice): session.notice.disconnect(_on_notice)
	var errors := 0
	for item in report.anomalies:
		if str(item.severity) == "error": errors += 1
	var snapshot_ok := true
	if reached and session != null and isolated:
		var snapshot: Dictionary = session.export_snapshot()
		snapshot_ok = session.validate_snapshot(snapshot)
		if snapshot_ok: result.snapshot = snapshot
		else: failure = "到达目标，但得到的存档未通过完整性校验。"
	var ok: bool = reached and snapshot_ok and (not checks or errors == 0)
	var reason := failure
	if reached and snapshot_ok: reason = "" if ok or not checks else "到达了目标，但检出 %d 类错误级异常，判定为未通过。" % errors
	report.merge({"ok": ok, "reached": reached, "cancelled": cancelled, "reason": reason, "strategy": strategy, "choice": choice_policy,
		"seed": seed_value, "goal": str(goal.get("label", goal.kind)), "mode": "隔离快速" if isolated else "实机演示", "elapsed_ms": elapsed, "steps": steps, "actions": actions,
		"stats": _stats.duplicate(), "timeline": _timeline.duplicate(true), "levels": _levels.duplicate(true), "decisions": _decisions.duplicate(), "trace": _trace.duplicate(),
		"errors": errors}, true)
	result.ok = ok
	result.message = str(report.reason)
	result.report = report
	if session != null:
		result.chapter = str(session.case_state.data.chapter)
		result.scene = str(session.case_state.data.scene)
		result.mode = str(session.mode)
	_dispose()
	return result

func _dispose() -> void:
	if is_instance_valid(_twin): _twin.queue_free()
	_twin = null
	if isolated and is_instance_valid(session): session.queue_free()
	if isolated: session = null
	_model = null

# ---------- 目标与关卡规则 ----------

func _reached(target: Dictionary) -> bool:
	match str(target.kind):
		# 部分章节（如第五章）剧情直接衔接下一章，没有稳定的调查画面；取该章或其后第一个可操作点。
		"chapter": return session.mode == "investigation" and chapter_index(session.config, str(session.case_state.data.chapter)) >= chapter_index(session.config, str(target.chapter))
		"ending": return session.mode == "credits"
		"level": return session.mode == "investigation" and level_open(session, str(target.question)) and not solvable_rows(session, str(target.question)).is_empty()
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

# ---------- 单步推进 ----------

func _fail(message: String) -> int:
	failure = message
	return FAILED

func _step() -> int:
	steps += 1
	if steps > MAX_STEPS: return _fail("步数超过上限 %d，已停止。" % MAX_STEPS)
	if step_hook.is_valid(): step_hook.call(steps, session)
	if not isolated:
		var tree := host.get_tree()
		if tree.paused:
			_wait_since = 0
			return WAIT
		if app != null and str(app.current_layer) != "game": return _wait("游戏处于暂停或菜单界面，关闭后才会继续。", MENU_WAIT_MS)
		if session.processing: return _wait_processing()
	_wait_since = 0
	_track()
	var mode := str(session.mode)
	if mode != "narrative": _narrative_run = 0
	match mode:
		"narrative": return _step_narrative()
		"material": return _step_material()
		"selection": return _step_selection()
		"result": return _step_result()
		"failure": return _step_failure()
		"investigation": return _step_investigation()
		"credits": return DONE if str(goal.kind) == "ending" else _fail("已经走到片尾，仍没有遇到目标：" + str(goal.get("label", goal.kind)))
	return _fail("停在未知状态：%s（实机请先离开摸猫等特殊界面）" % mode)

func _wait(reason: String, limit_ms: int) -> int:
	var now := Time.get_ticks_msec()
	if _wait_since == 0: _wait_since = now
	if now - _wait_since > limit_ms: return _fail(reason)
	return WAIT

func _wait_processing() -> int:
	var now := Time.get_ticks_msec()
	if _wait_since == 0: _wait_since = now
	var effect: Control = app.gameplay_page.result_effect if app != null else null
	var playing: bool = effect != null and effect.visible
	# 关键时刻的演出按配置长达 5.6-6.8 秒，所以按演出自己的时长再留一段宽限来判断是否卡住。
	var allowed := maxi(PROCESSING_WAIT_MS, int(effect.duration_ms) + PROCESSING_GRACE_MS) if playing else PROCESSING_WAIT_MS
	if now - _wait_since <= allowed: return WAIT
	# 结果演出自己没有结束时，用它的"跳过表现"收尾，并记下这次异常。
	if playing:
		effect.stop()
		_anomaly("ui", "结果演出超过 %.1f 秒（配置时长 %.1f 秒）仍未自行结束，已强制跳过。" % [allowed / 1000.0, effect.duration_ms / 1000.0])
		_wait_since = 0
		return WAIT
	return _fail("会话长时间处于处理中，无法继续。")

func _track() -> void:
	var data: Dictionary = session.case_state.data
	var chapter := str(data.chapter)
	if chapter != _last_chapter:
		_last_chapter = chapter
		_timeline.append({"chapter": chapter, "step": steps, "actions": actions, "ms": Time.get_ticks_msec() - _started})
		_pending_checkpoint = "进入 " + chapter
	var completed: int = data.completed_questions.size()
	if completed != _last_completed:
		_last_completed = completed
		for id in data.completed_questions:
			var entry := _level(str(id))
			if int(entry.done_step) == 0:
				entry.done_step = steps
				entry.result = str(data.completed_questions[id])
				_note("关卡 %s 完成（%s）" % [id, entry.result])
		if _pending_checkpoint.is_empty(): _pending_checkpoint = "关卡完成"
	_scenes_seen[str(data.scene)] = true

func _level(question_id: String) -> Dictionary:
	if not _levels.has(question_id):
		_levels[question_id] = {"first_step": steps, "selections": 0, "presents": 0, "wrong": 0, "failures": 0, "done_step": 0, "result": ""}
	return _levels[question_id]

func _step_investigation() -> int:
	if not _pending_checkpoint.is_empty():
		_checkpoint(_pending_checkpoint)
		_pending_checkpoint = ""
	# 回到调查界面时不应再有未收尾的出示结果或回应，否则存档与换场景都会被一直禁用。
	if not session.can_save():
		_anomaly("flow", "回到调查界面后仍无法存档和换场景：%s。" % _save_block_reason(), "error")
	if _reached(goal): return DONE
	if _act(): return CONTINUE
	# 全部入口都试过仍没有进展：像玩家一样再来一轮（选项会换一种取法），多轮仍无变化才算走不下去。
	_sweeps += 1
	if _sweeps > SWEEP_LIMIT:
		_anomaly("stuck", "走不下去：" + _stuck_report(), "error")
		return _fail("当前章节没有可继续推进的入口：%s（已重试 %d 轮）" % [session.case_state.data.chapter, SWEEP_LIMIT])
	_note("入口都已试过，第 %d 轮重新来过" % _sweeps)
	_attempted.clear()
	return CONTINUE

## 走不下去时的诊断：未完成关卡各自卡在哪个条件。
func _stuck_report() -> String:
	var parts: Array = []
	for id in session.config.questions:
		if session.case_state.data.completed_questions.has(id): continue
		var row: Dictionary = session.config.questions[id]
		var entry: Dictionary = session.config.entries.get(str(row.get("entry_ref", "")), {})
		var why := ""
		if not session.condition(str(row.get("condition_ref", ""))): why = "关卡条件 " + str(row.get("condition_ref", ""))
		elif not session.condition(str(entry.get("condition_id", ""))): why = "入口条件 " + str(entry.get("condition_id", ""))
		elif not str(row.get("trigger_text_ref", "")).is_empty() and not session.case_state.data.texts.get(str(row.trigger_text_ref), false): why = "未听过原话 " + str(row.trigger_text_ref)
		else:
			var missing := _missing_materials(str(id))
			why = "已开放，" + (missing if missing.begins_with("等待") else "缺少材料 " + missing) if not missing.is_empty() else "已开放但未完成"
		parts.append("%s(%s)" % [id, why])
	if not session.can_save(): parts.append("【当前不能换场景：%s】" % _save_block_reason())
	return "；".join(parts) if not parts.is_empty() else "无未完成关卡"

## 存档和换场景被禁用的原因（会话状态里残留了什么）。
func _save_block_reason() -> String:
	var reasons: Array = []
	if session.processing: reasons.append("结果演出处理中")
	if session.response_active: reasons.append("回应尚未结束")
	if not session.pending_result.is_empty():
		reasons.append("关卡 %s 的出示结果 %s 没有收尾（%s）" % [session.pending_result.get("question", "?"), session.pending_result.get("relation", "不足反馈"), session.pending_result.get("feedback", "")])
	if session.mode not in ["investigation", "selection"]: reasons.append("模式为 " + str(session.mode))
	return "、".join(reasons) if not reasons.is_empty() else "未知"

## 已开放关卡的卡点：条件成立的出示关系里缺得最少的那条还缺哪些内容版本；
## 若没有任何关系的条件成立，则列出各关系在等的条件。
func _missing_materials(question_id: String) -> String:
	var best: Array = []
	var found := false
	var waiting: Array = []
	for row in session.config.relations:
		if row.question_ref != question_id: continue
		if session.config.results[row.result_ref].feedback_key == "insufficient": continue
		var cond := str(row.get("condition_ref", ""))
		if not session.condition(cond):
			if not waiting.has(cond): waiting.append(cond)
			continue
		var missing: Array = relation_refs(row).filter(func(id): return not session.case_state.owns(id))
		if not found or missing.size() < best.size():
			best = missing
			found = true
	if found: return "、".join(best)
	return ("等待关系条件 " + "、".join(waiting)) if not waiting.is_empty() else ""

# ---------- 剧情与原件 ----------

func _step_narrative() -> int:
	var narrative: Node = session.narrative
	narrative.tick(100)
	if narrative.state.get("waiting_for_choice", false): return _choose(narrative)
	_narrative_run += 1
	if _narrative_run > NARRATIVE_LOOP_LIMIT: return _fail("正文接续形成循环：%s %s" % [session.active_entry, session.last_notice])
	narrative.advance()
	_stats.paragraphs += 1
	return CONTINUE

func _choose(narrative: Node) -> int:
	var choices: Array = narrative.available_choices
	if choices.is_empty(): return _fail("选项为空：" + str(session.active_entry))
	var source := str(narrative.state.get("current_text_id", "")) + "/" + str(session.active_entry)
	var visits := int(_choice_visits.get(source, 0))
	_choice_visits[source] = visits + 1
	var index := _pick_choice(source, choices.size(), visits)
	_stats.choices += 1
	var label := str(session.choice_label(choices[index]))
	_note("选项 %s：第 %d/%d 项「%s」" % [source, index + 1, choices.size(), label], "choice")
	session.last_notice = ""
	var was_response: bool = session.response_active
	_probing = true
	var accepted: bool = narrative.choose_transition(index)
	_probing = false
	if not accepted:
		# 被拒绝的选项不应改动状态：回应中途被拒后回应标记丢失，之后会留下无法收尾的出示结果。
		if was_response and not session.response_active:
			_anomaly("flow", "回应中的选项「%s」被拒绝，但回应状态已被提前结束（%s）；之后返回调查会留下未收尾的出示结果。" % [label, source], "error")
		# 选项被游戏拒绝时，文本留在原处；玩家再点一下会重新出现选项，所以这里也一样再点一下并换个选项。
		var why := str(session.last_notice)
		var jump: Dictionary = choices[index]
		_stats.refused += 1
		_anomaly("choice", "选项被游戏拒绝：%s 「%s」→ %s %s：%s" % [source, label, jump.get("target_kind", ""), jump.get("target_ref", ""), why if not why.is_empty() else "没有提示"])
		_refused_run += 1
		if _refused_run > REFUSED_LIMIT: return _fail("选项反复被拒绝，无法继续：%s（%s）" % [source, why])
		narrative.advance()
		return CONTINUE
	_refused_run = 0
	_narrative_run = 0
	return CONTINUE

## 选项取法：cycle 按遇到次数轮换；first/last 一直取第一/最后项，只有同一个选项点在没有任何进展时被重复遇到才换项
## （避免固定取法绕回同一菜单形成死循环）；random 随机取，多轮无进展后退回轮换以保证能走出去。
func _pick_choice(source: String, count: int, visits: int) -> int:
	match choice_policy:
		"first": return _stalled(source) % count
		"last": return count - 1 - _stalled(source) % count
		"random": return _rng.randi_range(0, count - 1) if _sweeps < 3 else visits % count
	return visits % count

## 剧情进展的指纹：章节、已发生事件、已持有版本、已听文本、已完成关卡与入口、人物位置。
## 只含会随进展单调变化的内容，来回切换场景或重复观察不会改变它。
func _progress_key() -> String:
	var data: Dictionary = session.case_state.data
	var happened := 0
	for id in data.events:
		if data.events[id]: happened += 1
	var versions := 0
	for material in data.materials.values(): versions += material.get("versions", {}).size()
	return "%s/%d/%d/%d/%d/%d/%d" % [data.chapter, happened, versions, data.texts.size(), data.completed_questions.size(), data.entries.size(), str(data.npc).hash()]

## 该选项点自上次有进展以来被重复遇到的次数。
func _stalled(source: String) -> int:
	var key := _progress_key()
	var record: Dictionary = _choice_stall.get(source, {})
	var count := int(record.get("n", 0)) + 1 if str(record.get("key", "")) == key else 0
	_choice_stall[source] = {"key": key, "n": count}
	return count

func _step_material() -> int:
	if not session.material_read_complete(): return _fail("原件无法读完：" + str(session.active_entry))
	_stats.materials += 1
	return CONTINUE

# ---------- 选材与结果 ----------

func _plan(question_id: String) -> Dictionary:
	if not _plans.has(question_id):
		match strategy:
			"fail": _plans[question_id] = {"wrong": 2, "failure": true, "collapse": false}
			"random": _plans[question_id] = {"wrong": _rng.randi_range(0, 2), "failure": _rng.randf() < 0.3, "collapse": _rng.randf() < 0.2}
			_: _plans[question_id] = {"wrong": 0, "failure": false, "collapse": false}
	return _plans[question_id]

func _step_selection() -> int:
	var question_id := str(session.question)
	_level(question_id).selections += 1
	# 实际走进目标关卡的选材界面，且已持有可过关的材料时立即停下，不替玩家作答。
	if str(goal.kind) == "level" and question_id == str(goal.question) and not solvable_rows(session, question_id).is_empty(): return DONE
	var plan := _plan(question_id)
	if int(plan.wrong) > 0:
		plan.wrong = int(plan.wrong) - 1
		if _present_wrong(question_id, plan): return CONTINUE
		plan.wrong = 0
	if bool(plan.collapse):
		plan.collapse = false
		_note("关卡 %s：先离开选材界面，稍后再回来" % question_id)
		_attempted.clear()
		session.collapse_question()
		return CONTINUE
	if _solve(question_id): return CONTINUE
	_note("关卡 %s：当前材料不足以过关，收起问题" % question_id)
	# 持有可过关材料却出示不出去，是游戏本身的问题，不是"还没到时候"。
	if not solvable_rows(session, question_id).is_empty():
		_anomaly("present", "关卡 %s 已持有可过关的材料，却无法出示：%s" % [question_id, _probe_notice if not _probe_notice.is_empty() else "没有提示"], "error")
	session.collapse_question()
	return CONTINUE

## 用实际取得的版本逐条尝试出示关系；找不到可行关系就收起问题，留待后续章节条件成熟。
func _solve(question_id: String) -> bool:
	_probing = true
	_probe_notice = ""
	for row in solvable_rows(session, question_id):
		session.clear_slot(0)
		session.clear_slot(1)
		if not session.select_target(): continue
		for field in ["a_content_ref", "b_content_ref"]:
			if not str(row.get(field, "")).is_empty(): session.select_content(str(row[field]))
		if session.present():
			_probing = false
			_stats.presents += 1
			_level(question_id).presents += 1
			_note("关卡 %s：出示关系 %s" % [question_id, row.id], "present")
			return true
	_probing = false
	return false

## 故意出示一组不构成任何关系的材料，走"不足"反馈路径；plan.failure 时在最后一次把机会清零，走失败界面和重试。
func _present_wrong(question_id: String, plan: Dictionary) -> bool:
	var owned := _owned_contents()
	if owned.is_empty(): return false
	var relations: Array = session.config.relations.filter(func(row): return row.question_ref == question_id and session.condition(str(row.get("condition_ref", ""))))
	for attempt in range(12):
		var pool := _shuffled(owned)
		var picks: Array = []
		var want := _rng.randi_range(1, 2)
		for id in pool:
			if picks.size() >= want: break
			if picks.all(func(other): return session.config.contents[other].material_id != session.config.contents[id].material_id): picks.append(id)
		if _completes_relation(relations, picks): continue
		_probing = true
		session.clear_slot(0)
		session.clear_slot(1)
		var ready: bool = session.select_target()
		if ready:
			for id in picks: session.select_content(str(id))
		_probing = false
		if not ready: return false
		if session.slots.all(func(id): return str(id).is_empty()): continue
		if not session.present(): return false
		_stats.presents += 1
		_stats.wrong += 1
		_level(question_id).wrong += 1
		var feedback := str(session.pending_result.get("feedback", ""))
		_note("关卡 %s：故意出示 %s，反馈 %s" % [question_id, "、".join(picks), feedback], "wrong")
		if feedback != "insufficient" and feedback != "incorrect" and feedback not in COMPLETE_FEEDBACK: _anomaly("flow", "错误组合得到了意外反馈：%s（关卡 %s）" % [feedback, question_id])
		if bool(plan.failure) and int(plan.wrong) == 0 and feedback in ["insufficient", "incorrect"]: _force_failure[question_id] = true
		return true
	return false

## 这组材料是否已经凑齐某条关系的 A、B（凑齐就不算"错误组合"）。
func _completes_relation(relations: Array, picks: Array) -> bool:
	for row in relations:
		var refs: Array = []
		for field in ["a_content_ref", "b_content_ref"]:
			if not str(row.get(field, "")).is_empty(): refs.append(str(row[field]))
		if not refs.is_empty() and refs.all(func(id): return id in picks): return true
	return false

func _owned_contents() -> Array:
	var owned: Array = []
	for material in session.case_state.data.materials:
		for id in session.case_state.data.materials[material].versions: owned.append(str(id))
	return owned

func _shuffled(source: Array) -> Array:
	var result := source.duplicate()
	for index in range(result.size() - 1, 0, -1):
		var other := _rng.randi_range(0, index)
		var held = result[index]
		result[index] = result[other]
		result[other] = held
	return result

func _step_result() -> int:
	var question_id := str(session.question)
	var pending: Dictionary = session.pending_result
	var stamp := "%s/%s/%s" % [question_id, pending.get("relation", ""), pending.get("feedback", "")]
	if stamp != _result_stamp:
		_result_stamp = stamp
		_note("关卡 %s：结果 %s" % [question_id, stamp.trim_prefix(question_id + "/")], "result")
	# 调试：不足反馈后把机会清零，使"继续"进入失败界面（现行配置没有会扣机会的错误出示）。
	if _force_failure.has(question_id) and str(pending.get("feedback", "")) in ["insufficient", "incorrect"]:
		_force_failure.erase(question_id)
		session.case_state.data.chances[question_id] = 0
		_note("关卡 %s：机会清零，走失败界面" % question_id, "wrong")
	return _advance_result()

## 推进一次结果界面：先提交待收推论或读回应，再收下推论，最后继续；失败时记录原因。
func _advance_result() -> int:
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
	if not ok: return _fail(step + str(session.question))
	return CONTINUE

func _step_failure() -> int:
	var question_id := str(session.question)
	_stats.failures += 1
	_level(question_id).failures += 1
	if not session.retry_question(): return _fail("失败界面无法重试：" + question_id)
	_stats.retries += 1
	_note("关卡 %s：失败界面，重试" % question_id, "wrong")
	var data: Dictionary = session.case_state.data
	var clean: bool = int(data.chances.get(question_id, 3)) == 3 and str(session.mode) == "selection" and session.slots.all(func(id): return str(id).is_empty())
	if not clean: _anomaly("flow", "重试后关卡 %s 没有恢复到初始选材状态（机会 %s，模式 %s）。" % [question_id, data.chances.get(question_id, "-"), session.mode], "error")
	return CONTINUE

# ---------- 调查入口 ----------

## 从当前可达入口中挑访问次数最少者执行一次；随机打法在同等访问次数里随机取。返回是否有动作被执行。
func _act() -> bool:
	var current := _progress_key()
	if current != _signature:
		_signature = current
		_attempted.clear()
		_sweeps = 0
	for id in _external():
		var row: Dictionary = session.config.entries[id]
		var scenes: Array = session.config.ids(str(row.get("allowed_scene_ids", "")))
		var scene: String = str(_entry_scenes.get(id, scenes[0] if not scenes.is_empty() else str(session.case_state.data.scene)))
		var key := scene + "/" + str(id)
		if _attempted.has(key) or not session.scene_status(scene).available: continue
		_attempted[key] = true
		if scene != session.case_state.data.scene:
			if not session.travel(scene): continue
			_stats.travels += 1
			if session.arrive():
				_stats.arrivals += 1
				_note("到达 %s 触发短场" % scene, "act")
				return true
		if session.activate_entry(id, {"kind": "scene", "scene": scene, "view": session.case_state.data.view}):
			_visits[id] = int(_visits.get(id, 0)) + 1
			actions += 1
			_note("入口 %s @%s" % [id, scene], "act")
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
		var goals: Array = session.config.rows("objective", "正式目标").filter(func(goal_row): return goal_row.goal_id == row.goal_id and session.condition(str(goal_row.get("condition_id", ""))))
		if goals.is_empty() or not session.condition(str(row.get("condition_id", ""))): continue
		if not str(row.get("completion_condition_id", "")).is_empty() and session.condition(str(row.completion_condition_id)): continue
		var id := str(row.get("target_ref", ""))
		if session.config.entries.has(id):
			ids[id] = true
			_entry_scenes[id] = str(row.get("scene_id", ""))
	var ordered: Array = ids.keys()
	if strategy == "random":
		var ranks := {}
		for id in ordered: ranks[id] = _rng.randf()
		ordered.sort_custom(func(a, b): return int(_visits.get(a, 0)) < int(_visits.get(b, 0)) or (int(_visits.get(a, 0)) == int(_visits.get(b, 0)) and float(ranks[a]) < float(ranks[b])))
	else:
		ordered.sort_custom(func(a, b): return int(_visits.get(a, 0)) < int(_visits.get(b, 0)))
	return ordered

# ---------- 异常采集 ----------

func _note(text: String, kind: String = "info") -> void:
	var line := "#%d %s %s" % [steps, str(session.case_state.data.chapter), text]
	_trace.append(line)
	if _trace.size() > TRACE_LIMIT: _trace.remove_at(0)
	if _decisions.size() < DECISION_LIMIT: _decisions.append({"step": steps, "kind": kind, "text": text})

func _on_notice(message: String) -> void:
	if _probing:
		_stats.probe_notices += 1
		_probe_notice = message
		return
	# 自动保存完成等成功提示不经 _notice 记录 last_notice；只有失败类提示才是异常。
	if message != str(session.last_notice): return
	_anomaly("notice", message)

func _anomaly(kind: String, message: String, severity: String = "warn") -> void:
	var key := kind + "|" + message
	if _anomaly_index.has(key):
		report.anomalies[int(_anomaly_index[key])].count += 1
		return
	_anomaly_index[key] = report.anomalies.size()
	var data: Dictionary = session.case_state.data if session != null else {}
	report.anomalies.append({"kind": kind, "severity": severity, "message": message, "count": 1, "step": steps, "chapter": str(data.get("chapter", "")),
		"scene": str(data.get("scene", "")), "mode": str(session.mode) if session != null else "", "entry": str(session.active_entry) if session != null else "",
		"question": str(session.question) if session != null else "", "trace": _trace.slice(maxi(0, _trace.size() - 6))})

## 实机模式：每帧核对界面是否跟上了会话模式。
func _check_ui() -> void:
	if app == null or not checks or isolated: return
	var tree := host.get_tree()
	if tree.paused or str(app.current_layer) != "game":
		_ui_bad = 0
		return
	var page: Control = app.gameplay_page
	var want: Control = {"investigation": page.scene_page, "selection": page.card_page, "result": page.card_page, "failure": page.card_page,
		"narrative": page.narrative_page, "material": page.reader_page, "credits": page.ending_page}.get(str(session.mode))
	if want == null:
		_ui_bad = 0
		return
	var wrong := not want.is_visible_in_tree()
	var names := {"investigation": "调查页", "selection": "选材页", "result": "选材页", "failure": "选材页", "narrative": "对白页", "material": "原件阅读", "credits": "片尾页"}
	for other in [page.scene_page, page.card_page, page.narrative_page, page.ending_page]:
		if other != want and other.is_visible_in_tree(): wrong = true
	if not wrong:
		_ui_bad = 0
		return
	_ui_bad += 1
	if _ui_bad == UI_MISMATCH_FRAMES:
		var visible_pages: Array = []
		for item in [["调查页", page.scene_page], ["选材页", page.card_page], ["对白页", page.narrative_page], ["原件阅读", page.reader_page], ["片尾页", page.ending_page]]:
			if item[1].is_visible_in_tree(): visible_pages.append(item[0])
		_anomaly("ui", "界面与会话模式不一致：模式 %s 应显示%s，实际可见 %s。" % [session.mode, names.get(str(session.mode), "-"), "、".join(visible_pages) if not visible_pages.is_empty() else "无"], "error")

# ---------- 存档校验与读档往返 ----------

func _checkpoint(label: String) -> void:
	if not checks: return
	var snapshot: Dictionary = session.export_snapshot()
	_stats.checkpoints += 1
	if not session.validate_snapshot(snapshot):
		_anomaly("snapshot", "%s：存档快照未通过完整性校验。" % label, "error")
		return
	var twin := _twin_session()
	if twin == null: return
	if not twin.restore_snapshot(snapshot):
		_anomaly("roundtrip", "%s：快照无法读回：%s" % [label, twin.last_notice], "error")
		return
	_stats.roundtrips += 1
	var again: Dictionary = twin.export_snapshot()
	var diff := _state_diff(snapshot, again)
	if not diff.is_empty(): _anomaly("roundtrip", "%s：读档后状态与存档前不一致（%s）。" % [label, diff], "error")

func _twin_session() -> Node:
	if is_instance_valid(_twin): return _twin
	var twin: Node = SessionScript.new()
	host.add_child(twin)
	twin.seen_storage_path = ""
	if not twin.initialize(str(session.config.definition.root), session.config):
		twin.queue_free()
		return null
	_twin = twin
	return twin

func _state_diff(before: Dictionary, after: Dictionary) -> String:
	var differing: Array = []
	for key in ["chapter", "scene", "view", "events", "texts", "entries", "materials", "completed_questions", "chances", "npc", "climaxes"]:
		if hash(before.case_state.get(key)) != hash(after.case_state.get(key)): differing.append(key)
	for key in ["mode", "question", "active_entry", "selected_target", "slots"]:
		if hash(before.get(key)) != hash(after.get(key)): differing.append(key)
	return "、".join(differing)

# ---------- 报告 ----------

func _missing_levels() -> void:
	if str(goal.kind) != "ending": return
	var missing: Array = []
	for id in session.config.questions:
		if not session.case_state.data.completed_questions.has(id): missing.append(str(id))
	if not missing.is_empty(): _anomaly("coverage", "到达片尾时仍有 %d 个关卡未完成：%s。" % [missing.size(), "、".join(missing)])

func _coverage() -> Dictionary:
	var data: Dictionary = session.case_state.data
	var config: RefCounted = session.config
	var versions := 0
	for id in data.materials: versions += data.materials[id].versions.size()
	var events := 0
	for id in data.events:
		if data.events[id]: events += 1
	var visited := {}
	for item in _timeline: visited[str(item.chapter)] = true
	return {"章节": [visited.size(), config.chapters.size()], "场景": [_scenes_seen.size(), config.scenes.size()], "关卡": [data.completed_questions.size(), config.questions.size()],
		"入口": [data.entries.size(), config.entries.size()], "事件": [events, config.events.size()], "原话": [data.texts.size(), config.texts.size()],
		"材料": [data.materials.size(), config.materials.size()], "材料版本": [versions, config.contents.size()]}

## 把报告整理成控制台与界面共用的文字行：{kind, text}。detail 为 true 时附上逐关明细与最近轨迹。
static func report_lines(data: Dictionary, detail: bool = true) -> Array:
	var lines: Array = []
	if data.is_empty(): return lines
	var verdict := "通过" if bool(data.get("ok", false)) and data.anomalies.is_empty() else ("通过（有 %d 类提示）" % data.anomalies.size() if bool(data.get("ok", false)) else "未通过")
	lines.append({"kind": "title" if bool(data.get("ok", false)) else "error", "text": "自动推进报告 [%s]  %s · %s · 目标 %s" % [verdict, STRATEGIES.get(str(data.strategy), data.strategy), data.mode, data.goal]})
	var seed_text := "  随机种子 %d" % int(data.seed) if str(data.strategy) == "random" or str(data.choice) == "random" else ""
	var reached := bool(data.get("reached", false))
	var reason := str(data.get("reason", ""))
	# 到达了目标但判定未通过时，原因里已写明（检出错误级异常 / 存档未过校验）。
	var outcome := ("结果  已到达目标。" if reason.is_empty() else "结果  " + reason) if reached else "结果  未到达目标：" + reason
	lines.append({"kind": "ok" if reached and reason.is_empty() else "warn", "text": outcome + "  选项取法 " + str(CHOICE_POLICIES.get(str(data.choice), data.choice)) + seed_text})
	var stats: Dictionary = data.stats
	lines.append({"kind": "info", "text": "过程  耗时 %.1f 秒  %d 步  入口动作 %d 次  对白 %d 段  选项 %d 处（被拒 %d）  原件 %d 份  出示 %d 次（错误 %d，失败界面 %d，重试 %d）  跨场景 %d 次，到达短场 %d 次" % [
		int(data.elapsed_ms) / 1000.0, int(data.steps), int(data.actions), int(stats.paragraphs), int(stats.choices), int(stats.refused), int(stats.materials), int(stats.presents), int(stats.wrong), int(stats.failures), int(stats.retries), int(stats.travels), int(stats.arrivals)]})
	lines.append({"kind": "info", "text": "校验  存档快照校验 %d 次，读档往返核对 %d 次" % [int(stats.checkpoints), int(stats.roundtrips)]})
	var chapters: Array = []
	for item in data.timeline: chapters.append("%s(第%d步)" % [item.chapter, int(item.step)])
	lines.append({"kind": "info", "text": "章节  " + " → ".join(chapters)})
	var coverage: Dictionary = data.get("coverage", {})
	var parts: Array = []
	for key in coverage: parts.append("%s %d/%d" % [key, int(coverage[key][0]), int(coverage[key][1])])
	lines.append({"kind": "info", "text": "覆盖  " + "  ".join(parts)})
	if detail:
		for id in data.levels:
			var level: Dictionary = data.levels[id]
			lines.append({"kind": "dim", "text": "  关卡 %-8s 出示 %d 次（错误 %d，失败 %d）%s" % [id, int(level.presents), int(level.wrong), int(level.failures), "  第 %d 步完成：%s" % [int(level.done_step), level.result] if int(level.done_step) > 0 else "  未完成"]})
	if data.anomalies.is_empty():
		lines.append({"kind": "ok", "text": "异常  无"})
	else:
		lines.append({"kind": "warn", "text": "异常  共 %d 类" % data.anomalies.size()})
		for item in data.anomalies:
			var where := "%s %s 模式 %s%s%s" % [item.chapter, item.scene, item.mode, " 入口 " + str(item.entry) if not str(item.entry).is_empty() else "", " 关卡 " + str(item.question) if not str(item.question).is_empty() else ""]
			lines.append({"kind": "error" if str(item.severity) == "error" else "warn", "text": "  [%s] %s%s  （%s，第 %d 步）" % ["错误" if str(item.severity) == "error" else "提示", item.message, " ×%d" % int(item.count) if int(item.count) > 1 else "", where, int(item.step)]})
			if detail:
				for trace in item.trace: lines.append({"kind": "dim", "text": "      " + str(trace)})
	if detail and not bool(data.get("reached", false)) and not data.trace.is_empty():
		lines.append({"kind": "dim", "text": "停止前最近的动作："})
		for trace in data.trace.slice(maxi(0, data.trace.size() - 10)): lines.append({"kind": "dim", "text": "  " + str(trace)})
	return lines
