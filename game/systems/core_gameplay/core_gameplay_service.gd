extends Node
## 核心玩法唯一状态入口：页面提交动作，服务维护材料、草稿和完整业务事务。

signal changed
signal notice(message: String)
signal autosave_requested
signal presentation_requested(display: Dictionary)
signal material_acquired(message: String)

const CatalogScript = preload("res://systems/core_gameplay/core_catalog.gd")
const StoreScript = preload("res://systems/core_gameplay/core_material_store.gd")
const TalkStore = preload("res://systems/core_gameplay/core_talk_records.gd")
const SNAPSHOT_VERSION := 1
const DEFAULT_CHANCES := 999
var catalog: RefCounted = CatalogScript.new()
var store: RefCounted = StoreScript.new()
var state: Dictionary = {}
var processing := false
var presenting := false
var inspection_depth := 0
var paused := false

func _chance_rule(key: String, fallback: int = DEFAULT_CHANCES) -> int:
	# 容错由核心配置表统一提供；没有接入配置时使用正式规则的安全默认值。
	var rows: Array = catalog.rules.get("容错策略", [])
	if rows.size() == 1 and rows[0] is Dictionary:
		var value := int(rows[0].get(key, fallback))
		return maxi(0, value)
	return fallback

func initial_chances() -> int:
	return _chance_rule("initial_chances")

func retry_chances() -> int:
	return _chance_rule("retry_chances")

func error_cost() -> int:
	return _chance_rule("error_cost", 1)

func failure_at() -> int:
	return _chance_rule("failure_at", 0)

func initialize(path: String = "res://data/story/outputs/story-images-20261011/故事配置表.xlsx", asset_root: String = "") -> bool:
	store.catalog = catalog
	return catalog.load_files(path, asset_root)

func start_new_game() -> void:
	store.entities.clear()
	store.acquire_index = 0
	state = {"snapshot_version": SNAPSHOT_VERSION, "case_id": catalog.data.case_id, "content_revision": catalog.data.content_revision,
		"run_id": "%s-%s" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()], "call_index": 0, "attempt_index": 0, "completion_index": 0, "revision": 1,
		"current_scene_id": catalog.data.initial_scene, "mode": "investigation", "card_ui_page": "closed", "question_id": "", "drafts": {}, "chances": {},
		"heard_statements": [], "current_statements": {}, "talk_records": [], "facts": [], "completed_questions": [], "confirmed_results": [],
		"resolved_result_keys": [], "applied_group_ids": [], "handled_climax_keys": [], "deducted_attempts": [], "attempt_results": {},
		"current_result": {}, "partial_result": {}, "failure_records": {}, "call_id": "", "card_caller_ref": {}, "last_selection_view": "bar",
		"bar_view": _default_view(), "grid_view": _default_view(), "current_node_id": "", "dialogue_return_ref": {}}
	state.grid_view.merge({"initialized": false, "expanded": false})
	for id in catalog.data.questions:
		var q: Dictionary = catalog.data.questions[id]
		if q.get("target_kind", "statement") == "statement": state.current_statements[id] = q.statement_id
	presenting = false
	inspection_depth = 0
	paused = false
	changed.emit()

func _default_view() -> Dictionary:
	return {"type": "all", "sort": "acquire", "important_only": false, "positions_by_type": {}, "focus_ref": {}}

func ui(key: String) -> String:
	return catalog.ui(key)

func can_save() -> bool:
	return not state.is_empty() and not processing and not presenting and inspection_depth == 0 and state.mode in ["investigation", "selection"]

func save_disabled_reason() -> String:
	return ui("UI_SAVE_DISABLED_CORE_FAILURE") if state.get("mode") == "failure" else "当前正在阅读或处理结果；返回调查或稳定选材后可以保存。"

func can_inspect() -> bool:
	return not processing and not presenting and not state.is_empty()

func can_menu() -> bool:
	return not processing and not state.is_empty()

func set_paused(value: bool) -> void:
	paused = value

func _changed() -> void:
	state.revision = int(state.get("revision", 0)) + 1
	changed.emit()

func _reject(message: String) -> bool:
	notice.emit(message)
	return false

func condition_met(id: String, selected: Array = []) -> bool:
	if not catalog.data.conditions.has(id): return false
	# 分支之间为或，分支内为与；空分支只能由作者显式配置。
	for branch in catalog.data.conditions[id]:
		var matched := true
		for term in branch:
			var kind: String = term.get("kind", "")
			var ref: String = term.get("ref", "")
			var ok := false
			match kind:
				"fact": ok = ref in state.facts
				"heard": ok = ref in state.heard_statements
				"owned": ok = store.owns(catalog.material_ref(ref))
				"completed": ok = ref in state.completed_questions
				"observation":
					# 只读本次所选精确版，不从牌库当前最高版补观察。
					for material in selected:
						if ref in catalog.data.contents.get(material.content_id, {}).get("observations", []): ok = true
			if not ok: matched = false; break
		if matched: return true
	return false

func acquire_material(content_id: String, entry_id: String, source_id: String) -> bool:
	if paused or processing or state.is_empty(): return false
	if not catalog.data.entries.has(entry_id): return _reject("材料取得入口无效")
	var entry: Dictionary = catalog.data.entries[entry_id]
	if content_id not in entry.get("contents", []) or source_id != entry.get("source_id", "") or not condition_met(entry.condition): return _reject("材料取得条件未满足")
	if catalog.data.materials[catalog.data.contents[content_id].material_id].type == "inference": return _reject("推论需要主动收下")
	var ref: Dictionary = catalog.material_ref(content_id)
	var previously_owned: bool = store.owns(ref)
	var previous_sources: Array = store.sources(ref)
	var ok: bool = store.acquire(content_id, {"entry_id": entry_id, "source_id": source_id, "object_id": entry.get("object_id", ""), "text_id": entry.text})
	if ok:
		_changed()
		if not previously_owned or previous_sources != store.sources(ref):
			material_acquired.emit(("更新：" if previously_owned else "取得：") + catalog.text(catalog.data.contents[content_id].title) + " · " + catalog.text(entry.get("title", entry.text)))
	return ok

func validate_entry_commit(id: String) -> bool:
	# 先核对整批输出，再改材料、原话和事实，避免中途遇坏引用只提交前半批。
	if paused or processing or presenting or state.is_empty() or not catalog.data.entries.has(id): return false
	var entry: Dictionary = catalog.data.entries[id]
	if not _in_current_scene(entry) or not condition_met(str(entry.get("condition", ""))) or str(entry.get("source_id", "")).is_empty(): return false
	for content_id in entry.get("contents", []):
		var ref: Dictionary = catalog.material_ref(content_id)
		if not catalog.valid_material_ref(ref) or catalog.data.materials.get(ref.material_id, {}).get("type") == "inference": return false
	for statement_id in entry.get("statements", []):
		if not catalog.data.statements.has(statement_id): return false
	return true

func activate_entry(id: String) -> bool:
	if paused or processing or presenting or state.mode not in ["investigation", "selection"] or inspection_depth > 0: return false
	if not catalog.data.entries.has(id): return false
	var entry: Dictionary = catalog.data.entries[id]
	if not _in_current_scene(entry): return _reject("该入口不在当前地点")
	if not condition_met(entry.condition): return _reject("该入口尚未开放")
	if not validate_entry_commit(id): return _reject("入口内容尚未就绪，当前调查保持。")
	state.dialogue_return_ref = {"mode": state.mode, "card_ui_page": state.card_ui_page, "question_id": state.question_id}
	for content_id in entry.get("contents", []):
		if not acquire_material(content_id, id, entry.source_id): return false
	for statement_id in entry.get("statements", []): hear_statement(statement_id, id)
	for fact in entry.get("facts", []):
		if fact not in state.facts: state.facts.append(fact)
	state.current_node_id = id
	state.mode = "dialogue"
	state.card_ui_page = "closed"
	_changed()
	return true

func hear_statement(statement_id: String, entry_id: String) -> bool:
	if not catalog.data.statements.has(statement_id): return false
	if not catalog.data.entries.has(entry_id) or statement_id not in catalog.data.entries[entry_id].get("statements", []): return false
	if statement_id not in state.heard_statements: state.heard_statements.append(statement_id)
	# 相同原话在另一真实会面入口出现时保留另一段经历；重复打开同一入口不补记。
	for record in state.talk_records:
		if record.get("kind") == "statement" and record.get("entry_id") == entry_id and record.get("statement_id") == statement_id: return true
	var s: Dictionary = catalog.data.statements[statement_id]
	state.talk_records.append({"kind": "statement", "record_id": "statement/%s/%s" % [entry_id, statement_id], "statement_id": statement_id, "claim_id": s.claim_id, "speaker": s.speaker, "text_id": s.text, "entry_id": entry_id, "read": false})
	return true

func talk_segments() -> Array:
	# 派生展示不建立第二份剧情正文，也不向静态配置追补未听句。
	return TalkStore.segments(state.get("talk_records", []), catalog)

func mark_talk_read(record_id: String) -> void:
	if record_id.is_empty(): return
	for record in state.get("talk_records", []):
		if TalkStore.record_id(record) == record_id:
			if not record.get("read", false):
				record.read = true
				_changed()
			return

func finish_dialogue() -> void:
	if paused or state.mode != "dialogue": return
	state.mode = state.dialogue_return_ref.get("mode", "investigation")
	state.card_ui_page = state.dialogue_return_ref.get("card_ui_page", "closed")
	state.dialogue_return_ref = {}
	state.current_node_id = ""
	_changed()

func target_for(question_id: String) -> Dictionary:
	if not catalog.data.questions.has(question_id): return {}
	var q: Dictionary = catalog.data.questions[question_id]
	if q.get("target_kind", "statement") == "reasoning":
		return {"target_kind": "reasoning", "question_id": question_id, "question_text_id": q.question_text_id}
	var id: String = state.current_statements.get(question_id, q.statement_id)
	return {"target_kind": "statement", "question_id": question_id, "statement_ref": {"claim_id": catalog.data.statements[id].claim_id, "statement_id": id}}

func _legal_target(target: Dictionary) -> bool:
	var qid: String = target.get("question_id", "")
	if not catalog.data.questions.has(qid) or target != target_for(qid): return false
	return target.target_kind == "reasoning" or target.statement_ref.statement_id in state.heard_statements

func _new_draft(id: String) -> Dictionary:
	var target := target_for(id)
	return {"question_id": id, "target_ref": target, "target_selected": target.target_kind == "reasoning", "slots": [null, null]}

func open_card_session(id: String, caller: Dictionary = {}) -> bool:
	if paused or processing or presenting or inspection_depth > 0 or state.mode not in ["investigation", "selection"]: return false
	if not catalog.data.questions.has(id) or not condition_met(catalog.data.questions[id].condition): return _reject("问题尚未开放")
	if not _in_current_scene(catalog.data.questions[id]): return _reject("该问题不在当前地点")
	var target := target_for(id)
	if not _legal_target(target): return _reject("尚未听到这版说法")
	# 同一问题收起后可恢复；切换到另一合法问题才清除旧问题选择。
	for previous in state.drafts.keys():
		if previous != id: state.drafts.erase(previous)
	if state.question_id != id: state.partial_result = {}
	state.question_id = id
	state.card_caller_ref = caller.duplicate(true)
	if not state.chances.has(id): state.chances[id] = initial_chances()
	state.call_index = int(state.call_index) + 1
	state.call_id = "call-%d" % int(state.call_index)
	if id in state.completed_questions:
		for record in state.confirmed_results:
			if record.question_id == id:
				state.current_result = record.duplicate(true)
				state.current_result["replay"] = true
				state.mode = "response"
				state.card_ui_page = "closed"
				_changed()
				return true
	if int(state.chances[id]) == 0:
		state.mode = "failure"
		state.card_ui_page = "closed"
		state.current_result = state.failure_records.get(id, {}).duplicate(true)
	else:
		if not state.drafts.has(id): state.drafts[id] = _new_draft(id)
		elif state.drafts[id].target_ref != target:
			state.drafts[id].target_ref = target
			state.drafts[id].target_selected = target.target_kind == "reasoning"
			state.partial_result = {}
		state.mode = "selection"
		state.card_ui_page = "grid" if state.last_selection_view == "grid" else "selection"
	_changed()
	return true

func _in_current_scene(record: Dictionary) -> bool:
	# 空地点表示全局入口；明确绑定地点的内容只在实际所在地点可调用。
	return str(record.get("scene_id", "")).is_empty() or record.scene_id == state.current_scene_id

func move_scene(link_id: String) -> bool:
	# 普通移动只改变地点；地图策划4.2规定不取得、不推进、不自动保存。
	if paused or processing or presenting or inspection_depth > 0 or state.get("mode") != "investigation": return false
	if not catalog.data.get("scene_links", {}).has(link_id): return false
	var link: Dictionary = catalog.data.scene_links[link_id]
	if link.from_scene != state.current_scene_id or not condition_met(link.condition): return _reject("当前无法前往该地点")
	state.current_scene_id = link.to_scene
	_changed()
	return true

func draft() -> Dictionary:
	return state.get("drafts", {}).get(state.get("question_id", ""), {}).duplicate(true)

func select_target() -> bool:
	if not _selectable(): return false
	state.drafts[state.question_id].target_selected = true
	_changed()
	return true

func _selectable() -> bool:
	return not paused and not processing and not presenting and inspection_depth == 0 and state.get("mode") == "selection"

func select_material(ref: Dictionary) -> bool:
	if not _selectable() or not store.owns(ref): return false
	var slots: Array = state.drafts[state.question_id].slots
	for old in slots:
		if old != null and old.material_id == ref.material_id: return _reject("该材料已在出示槽中；更换版本前请先撤下")
	for i in range(2):
		if slots[i] == null:
			slots[i] = ref.duplicate(true)
			_changed()
			return true
	return _reject("两个槽已满，请先撤下一份材料")

func withdraw_material(index: int = -1) -> bool:
	if not _selectable() or index < -1 or index > 1: return false
	var slots: Array = state.drafts[state.question_id].slots
	if index == -1: slots[0] = null; slots[1] = null
	else: slots[index] = null
	state.partial_result = {}
	_changed()
	return true

func fold_card_selection() -> bool:
	if not _selectable(): return false
	state.last_selection_view = "grid" if state.card_ui_page == "grid" else "bar"
	state.mode = "investigation"
	state.card_ui_page = "closed"
	_changed()
	return true

func set_grid(expanded: bool) -> void:
	if not _selectable(): return
	if expanded and not state.grid_view.initialized:
		state.grid_view = state.bar_view.duplicate(true)
		state.grid_view.merge({"initialized": true, "expanded": true})
	state.grid_view.expanded = expanded
	state.card_ui_page = "grid" if expanded else "selection"
	state.last_selection_view = "grid" if expanded else "bar"
	_changed()

func current_view() -> Dictionary:
	return state.grid_view.duplicate(true) if state.card_ui_page == "grid" else state.bar_view.duplicate(true)

func update_view(values: Dictionary) -> void:
	if not _selectable(): return
	var view: Dictionary = state.grid_view if state.card_ui_page == "grid" else state.bar_view
	for key in ["type", "sort", "important_only", "positions_by_type", "focus_ref"]:
		if values.has(key): view[key] = values[key].duplicate(true) if values[key] is Dictionary else values[key]
	_changed()

func toggle_important(id: String) -> void:
	if store.entities.has(id) and not paused and not presenting:
		store.entities[id].important = not store.entities[id].important
		_changed()

func record_view_position(view_name: String, type_name: String, position: Dictionary = {}, focus: Dictionary = {}) -> void:
	# 页面回报真实位置与焦点；服务写入视图状态，避免刷新引起循环。
	if state.is_empty() or view_name not in ["bar", "grid"] or type_name not in ["all", "evidence", "testimony", "inference"]: return
	var view: Dictionary = state.grid_view if view_name == "grid" else state.bar_view
	if not position.is_empty():
		var old: Dictionary = view.positions_by_type.get(type_name, {})
		old.merge(position.duplicate(true), true)
		view.positions_by_type[type_name] = old
	if not focus.is_empty(): view.focus_ref = focus.duplicate(true)
	state.revision = int(state.revision) + 1

func mark_read(ref: Dictionary) -> void:
	store.mark_read(ref)
	_changed()

func begin_inspection() -> bool:
	if paused or not can_inspect(): return _reject("当前演出结束后可以检视")
	inspection_depth += 1
	return true

func end_inspection() -> void:
	inspection_depth = maxi(0, inspection_depth - 1)
	changed.emit()

func can_present() -> bool:
	return present_disabled_reason().is_empty()

func present_disabled_reason() -> String:
	# 资格与禁用提示共用同一次检查；一份材料即可出示，第二个槽允许为空。
	if state.is_empty(): return "请先开始调查。"
	if paused: return "请先恢复游戏。"
	if processing or presenting: return "请等待本次反馈结束。"
	if inspection_depth > 0: return "请先关闭阅读页面。"
	if state.mode != "selection": return "请先进入选材页面。"
	var d := draft()
	if d.is_empty(): return "请先打开待核问题。"
	if not d.target_selected: return "请先点击上方人物说法，选定核对目标。"
	if not _legal_target(d.target_ref): return "当前核对目标不可用，请重新进入问题。"
	if d.slots[0] == null and d.slots[1] == null: return "请选用至少一份材料放入出示槽。"
	if int(state.chances[state.question_id]) <= 0: return "本题容错已用完，请重试。"
	return ""

func _rank(r: Dictionary) -> int:
	if r.feedback == "full": return 0 if r.materials.size() == 2 else 1
	return 2 if r.feedback in ["partial", "counter"] else 3

func _match(r: Dictionary, d: Dictionary, selected: Array) -> bool:
	if r.question_id != state.question_id or not condition_met(r.condition, selected): return false
	if d.target_ref.target_kind == "statement":
		if r.get("statement_id", "") != d.target_ref.statement_ref.statement_id: return false
	elif r.get("question_text_id", "") != d.target_ref.question_text_id: return false
	if r.get("match_scope", "contains") == "exact_set" and r.materials.size() != selected.size(): return false
	for ref in r.materials:
		if ref not in selected: return false
	return true

func _result_key(r: Dictionary, target: Dictionary) -> String:
	return JSON.stringify([state.run_id, r.get("result_key", ""), target])

func _basis(r: Dictionary) -> Array:
	var refs: Array = []
	for basis in r.get("basis_results", []):
		var found: Dictionary = {}
		for record in state.confirmed_results:
			if record.confirmed and record.run_id == state.run_id and record.relation_id == basis.relation_id and record.target_ref == basis.target_ref:
				if found.is_empty() or int(record.completion_index) > int(found.completion_index): found = record
		if found.is_empty(): return []
		refs.append({"kind": "confirmed", "record": found.duplicate(true)})
	return refs

func present_materials(attempt_id: String = "") -> Dictionary:
	# 外部回调可携带同一个尝试 ID；重复消费直接返回冻结结果，绝不重复扣次。
	if not attempt_id.is_empty() and state.attempt_results.has(attempt_id): return state.attempt_results[attempt_id].duplicate(true)
	if not can_present(): return {}
	if attempt_id.is_empty():
		state.attempt_index = int(state.attempt_index) + 1
		attempt_id = "%s/%s/%d" % [state.run_id, state.question_id, int(state.attempt_index)]
	var d := draft()
	var selected: Array = []
	for ref in d.slots:
		if ref != null: selected.append(ref)
	var candidates: Array = []
	for id in catalog.data.relations:
		var relation: Dictionary = catalog.data.relations[id].duplicate(true)
		relation["id"] = id
		if _match(relation, d, selected):
			if relation.get("basis_results", []).size() > 0 and _basis(relation).is_empty(): continue
			candidates.append(relation)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary): return _rank(a) < _rank(b))
	if candidates.size() > 1 and _rank(candidates[0]) == _rank(candidates[1]) and candidates[0].get("result_key", candidates[0].node) != candidates[1].get("result_key", candidates[1].node):
		_reject("内容配置存在同优先级冲突，未执行本次判定")
		return {}
	var r: Dictionary = candidates[0] if not candidates.is_empty() else {"id": "", "feedback": "insufficient", "materials": selected, "node": catalog.data.questions[state.question_id].insufficient_node, "effect_level": "normal", "effect_kind": "ordinary"}
	var used: Array = []
	for ref in r.materials: used.append(store.freeze(ref))
	used.append_array(_basis(r))
	var key := _result_key(r, d.target_ref)
	var result := {"run_id": state.run_id, "call_id": state.call_id, "result_id": "%s/%s/%s" % [state.run_id, state.call_id, attempt_id], "attempt_id": attempt_id,
		"question_id": state.question_id, "relation_id": r.id, "target_ref": d.target_ref.duplicate(true), "used_sources": used,
		"feedback": r.feedback, "node": r.node, "inference_content_id": r.get("inference", ""), "collected": false, "confirmed": false,
		"confirmed_scope": r.get("confirmed_scope", ""), "resolution_key": key, "first_resolution": key not in state.resolved_result_keys,
		"effect_kind": r.get("effect_kind", "ordinary"), "effect_level": r.get("effect_level", "normal"), "climax_key": r.get("climax_key", ""), "reason_text_id": r.get("reason", "")}
	result["comparison"] = {"statement_quote": r.get("statement_quote", ""), "quotes": [], "confirmed_scope": r.get("confirmed_scope", "")}
	for index in range(r.materials.size()):
		var quote: String = r.get("a_quote" if index == 0 else "b_quote", "")
		if not quote.is_empty(): result.comparison.quotes.append({"ref": r.materials[index].duplicate(true), "quote": quote})
	# 重复成果复用原证明，不能让后来取得的来源扩大原结论。
	if r.feedback == "full" and not result.first_resolution:
		for old in state.confirmed_results:
			if old.resolution_key == key:
				result = old.duplicate(true)
				result["replay"] = true
				result.effect_level = "normal"
				break
	if not str(result.inference_content_id).is_empty() and store.owns(catalog.material_ref(result.inference_content_id)) and result.first_resolution:
		_reject("该推论已拥有；需配置已拥有条件下的独立回应")
		return {}
	processing = true
	state.current_result = result
	state.current_node_id = result.node
	state.card_ui_page = "closed"
	if r.feedback == "incorrect":
		state.chances[state.question_id] = maxi(failure_at(), int(state.chances[state.question_id]) - error_cost())
		state.deducted_attempts.append(attempt_id)
	if r.feedback in ["partial", "counter"]: state.partial_result = result.duplicate(true)
	state.mode = "pending" if not str(result.inference_content_id).is_empty() and not result.get("replay", false) else "response"
	if state.mode == "pending": state.card_ui_page = "pending"
	if r.feedback == "incorrect" and int(state.chances[state.question_id]) <= failure_at(): state.mode = "failure"
	if r.feedback == "incorrect": state.failure_records[state.question_id] = result.duplicate(true)
	if state.mode != "pending" and r.feedback == "full" and not result.get("replay", false):
		if not _apply_result("enter"):
			processing = false
			_reject("结果组配置不完整，未提交确认")
			return {}
	processing = false
	state.attempt_results[attempt_id] = result.duplicate(true)
	_start_presentation(result)
	_changed()
	return result.duplicate(true)

func _start_presentation(result: Dictionary, override: String = "") -> void:
	var level: String = result.get("effect_level", "normal")
	if not result.get("first_resolution", true) or result.get("feedback") != "full": level = "normal"
	if level == "key" and (str(result.get("climax_key", "")).is_empty() or result.climax_key in state.handled_climax_keys): level = "normal"
	var selected := level
	if level == "key":
		state.handled_climax_keys.append(result.climax_key)
		selected = "key_insight_fact" if str(result.inference_content_id).is_empty() and result.effect_kind == "inference" else ("key_break" if result.effect_kind == "exclude" and str(result.inference_content_id).is_empty() else "key_inference")
	result["selected_presentation"] = selected
	var duration := 300
	if level == "progress": duration = 3200
	elif level == "key": duration = 5600 if selected == "key_break" else 6800
	else:
		var feedback: String = override if not override.is_empty() else result.get("effect_kind", "support")
		if result.get("feedback") == "incorrect": feedback = "question_failed" if state.mode == "failure" else "error_deduct"
		elif result.get("feedback") in ["partial", "counter", "insufficient"]: feedback = result.feedback
		elif result.get("replay", false): feedback = "repeat"
		elif not str(result.get("inference_content_id", "")).is_empty(): feedback = "inference_card"
		for row in catalog.rules.get("普通反馈", []):
			if row.feedback_key == feedback: duration = int(row.duration_ms)
	if level in ["progress", "key"]:
		for row in catalog.rules.get("表现规则", []):
			if row.effect_level != level: continue
			if level == "progress" or row.effect_kind == ("击破" if selected == "key_break" else "涌现"):
				duration = int(row.duration_ms)
				break
	presenting = true
	presentation_requested.emit({"duration_ms": duration, "kind": selected, "result_id": result.get("result_id", ""), "effect_kind": result.get("effect_kind", "ordinary")})

func finish_presentation() -> void:
	if paused: return
	presenting = false
	changed.emit()

func _apply_result(timing: String) -> bool:
	var result: Dictionary = state.current_result
	if result.is_empty() or result.get("replay", false) or result.feedback != "full": return true
	var node: Dictionary = catalog.data.nodes[result.node]
	if node.get("timing", "none") != timing: return true
	var group_id: String = node.get("group", "")
	if not catalog.data.groups.has(group_id): return false
	var execution_key := JSON.stringify([state.run_id, result.call_id, timing, group_id])
	if execution_key in state.applied_group_ids: return true
	# 先验证整组，再提交。错误配置不会造成半份确认或半张卡。
	var actions: Array = catalog.data.groups[group_id]
	var confirms := 0
	for action in actions:
		match action.kind:
			"confirm": confirms += 1
			"fact":
				if str(action.get("ref", "")).is_empty(): return false
			"correct":
				if not catalog.data.statements.has(action.get("statement_id", "")) or not catalog.data.questions.has(action.get("question_id", "")): return false
			_:
				return false
	if confirms != 1: return false
	if timing == "collect":
		if str(result.inference_content_id).is_empty(): return false
		if not store.acquire(result.inference_content_id, {}, result.used_sources): return false
	for action in actions:
		match action.kind:
			"fact":
				if action.ref not in state.facts: state.facts.append(action.ref)
			"correct":
				state.current_statements[action.question_id] = action.statement_id
				if action.statement_id not in state.heard_statements:
					state.heard_statements.append(action.statement_id)
				# 先前在别的入口听过同句，也须保留本次真实更正经历。
				var recorded := false
				for previous in state.talk_records:
					if previous.get("kind") == "statement" and previous.get("entry_id") == "result" and previous.get("statement_id") == action.statement_id: recorded = true; break
				if not recorded:
					var statement: Dictionary = catalog.data.statements[action.statement_id]
					state.talk_records.append({"kind": "statement", "record_id": "statement/result/%s" % action.statement_id, "statement_id": action.statement_id, "claim_id": statement.claim_id, "speaker": statement.speaker, "text_id": statement.text, "entry_id": "result", "read": false})
				state.partial_result = {}
	state.applied_group_ids.append(execution_key)
	if result.resolution_key not in state.resolved_result_keys: state.resolved_result_keys.append(result.resolution_key)
	state.completion_index = int(state.completion_index) + 1
	result["completion_index"] = state.completion_index
	result.confirmed = true
	if result.question_id not in state.completed_questions: state.completed_questions.append(result.question_id)
	state.confirmed_results.append(result.duplicate(true))
	state.talk_records.append({"kind": "confirmed", "record_id": "confirmed/%s" % result.result_id, "result_id": result.result_id, "text_id": node.text, "record": result.duplicate(true), "read": false})
	return true

func collect_inference(result_id: String, content_id: String) -> bool:
	if paused or processing or presenting or inspection_depth > 0: return false
	var result: Dictionary = state.current_result
	if result.get("result_id", "") != result_id or result.get("inference_content_id", "") != content_id: return false
	if result.get("collected", false): return true
	if state.mode != "pending": return false
	processing = true
	var ok := _apply_result("collect")
	if ok:
		result.collected = true
		state.mode = "collected"
		state.card_ui_page = "collected"
	processing = false
	if ok:
		presenting = true
		presentation_requested.emit({"duration_ms": 900, "kind": "collect", "result_id": result_id})
		_changed()
	return ok

func continue_result(action: String = "continue", request_auto: bool = true) -> bool:
	if paused or processing or presenting or inspection_depth > 0 or state.mode not in ["response", "collected", "failure"]: return false
	var result: Dictionary = state.current_result
	if state.mode == "failure" and action != "defer": return false
	var success: bool = result.get("feedback") == "full"
	if success and action != "continue": return false
	if not success and action not in ["reselect", "defer"]: return false
	if success:
		processing = true
		var ok := _apply_result("continue")
		processing = false
		if not ok or not result.get("confirmed", false): return false
		state.drafts.erase(state.question_id)
		state.partial_result = {}
	if action == "reselect":
		state.mode = "selection"
		state.card_ui_page = "grid" if state.last_selection_view == "grid" else "selection"
	else:
		state.mode = "investigation"
		state.card_ui_page = "closed"
	state.current_result = {}
	state.current_node_id = ""
	_changed()
	if request_auto and success and not result.get("replay", false): autosave_requested.emit()
	return true

func next_question(id: String) -> bool:
	# 先正常结束旧结果，再按更新后的真实条件打开作者显式绑定的下一问。
	var result: Dictionary = state.current_result
	if result.is_empty() or id not in catalog.data.nodes[result.node].get("next_questions", []): return false
	if not continue_result("continue", false): return false
	var opened := open_card_session(id, state.card_caller_ref)
	# 下一问选择只在最终合法页面请求完整自动档。
	if opened and can_save(): autosave_requested.emit()
	return opened

func supplement_source(content_id: String) -> Dictionary:
	if paused or presenting or processing or state.mode != "response" or state.partial_result.is_empty(): return {}
	if state.partial_result.target_ref != target_for(state.question_id): return {}
	var ref: Dictionary = catalog.material_ref(content_id)
	if not store.owns(ref): return {}
	var slots: Array = state.drafts[state.question_id].slots
	if null not in slots: _reject("请重新选材并撤下一份无关材料"); return {}
	for source in state.partial_result.used_sources:
		if source.get("kind") == "material" and source.ref not in slots: return {}
	state.mode = "selection"
	if not select_material(ref): state.mode = "response"; return {}
	return present_materials()

func retry_question() -> bool:
	var id: String = state.get("question_id", "")
	if paused or presenting or processing or inspection_depth > 0 or state.mode != "failure" or id in state.completed_questions: return false
	if not condition_met(catalog.data.questions[id].condition): return false
	state.chances[id] = retry_chances()
	state.drafts[id] = _new_draft(id)
	state.partial_result = {}
	state.current_result = {}
	state.failure_records.erase(id)
	state.bar_view = _default_view()
	state.last_selection_view = "bar"
	state.mode = "selection"
	state.card_ui_page = "selection"
	presenting = true
	presentation_requested.emit({"duration_ms": 850, "kind": "retry", "result_id": ""})
	_changed()
	return true

func export_card_state() -> Dictionary:
	var snapshot := state.duplicate(true)
	snapshot["materials"] = store.export_state()
	return snapshot

func validate_card_state(snapshot: Dictionary) -> bool:
	if int(snapshot.get("snapshot_version", -1)) != SNAPSHOT_VERSION or snapshot.get("case_id") != catalog.data.case_id or snapshot.get("content_revision") != catalog.data.content_revision: return false
	for key in ["run_id", "call_index", "attempt_index", "completion_index", "revision", "current_scene_id", "mode", "card_ui_page", "question_id", "drafts", "chances", "heard_statements", "current_statements", "talk_records", "facts", "completed_questions", "confirmed_results", "resolved_result_keys", "applied_group_ids", "handled_climax_keys", "deducted_attempts", "attempt_results", "current_result", "partial_result", "failure_records", "call_id", "card_caller_ref", "last_selection_view", "bar_view", "grid_view", "current_node_id", "materials", "dialogue_return_ref"]:
		if not snapshot.has(key): return false
	if not snapshot.materials is Dictionary or not store.validate(snapshot.materials): return false
	for key in ["drafts", "chances", "current_statements", "attempt_results", "current_result", "partial_result", "failure_records", "card_caller_ref", "bar_view", "grid_view", "dialogue_return_ref"]:
		if not snapshot[key] is Dictionary: return false
	for key in ["heard_statements", "talk_records", "facts", "completed_questions", "confirmed_results", "resolved_result_keys", "applied_group_ids", "handled_climax_keys", "deducted_attempts"]:
		if not snapshot[key] is Array: return false
	if str(snapshot.run_id).is_empty() or not catalog.data.scenes.has(snapshot.current_scene_id): return false
	if snapshot.mode not in ["investigation", "selection", "dialogue", "response", "pending", "collected", "failure"]: return false
	if snapshot.card_ui_page not in ["closed", "selection", "grid", "pending", "collected"]: return false
	for id in snapshot.chances:
		if not catalog.data.questions.has(id) or int(snapshot.chances[id]) < failure_at() or int(snapshot.chances[id]) > initial_chances(): return false
	for id in snapshot.heard_statements:
		if not catalog.data.statements.has(id): return false
	for result in snapshot.confirmed_results:
		if not _valid_saved_result(result) or not result.get("confirmed", false) or not result.has("completion_index"): return false
	# 旧档可缺新增的阅读字段，但不能把未知原话或未确认结果注入手册。
	var record_ids: Array = []
	for record in snapshot.talk_records:
		if not record is Dictionary or not record.get("text_id") is String or not catalog.data.texts.has(record.text_id): return false
		if record.has("read") and not record.read is bool: return false
		if record.has("record_id") and (not record.record_id is String or record.record_id.is_empty()): return false
		var canonical_id := "confirmed/%s" % record.get("result_id", "") if record.get("kind") == "confirmed" else "statement/%s/%s" % [record.get("entry_id", ""), record.get("statement_id", "")]
		if record.has("record_id") and record.record_id != canonical_id: return false
		if canonical_id in record_ids: return false
		record_ids.append(canonical_id)
		if record.get("kind") == "statement":
			var id: String = record.get("statement_id", "")
			if id not in snapshot.heard_statements or not catalog.data.statements.has(id): return false
			var statement: Dictionary = catalog.data.statements[id]
			if record.get("text_id") != statement.text or record.get("speaker") != statement.speaker or record.get("claim_id") != statement.claim_id: return false
			if not record.get("entry_id") is String: return false
			if record.entry_id != "result" and (not catalog.data.entries.has(record.entry_id) or id not in catalog.data.entries[record.entry_id].get("statements", [])): return false
			if record.entry_id == "result":
				var produced := false
				for confirmed in snapshot.confirmed_results:
					var node: Dictionary = catalog.data.nodes[confirmed.node]
					for action in catalog.data.groups.get(node.get("group", ""), []):
						if action.get("kind") == "correct" and action.get("statement_id") == id: produced = true
				if not produced: return false
		elif record.get("kind") == "confirmed":
			if not _valid_saved_result(record.get("record")) or not record.record.get("confirmed", false): return false
			if record.get("result_id") != record.record.result_id or record.text_id != catalog.data.nodes[record.record.node].text: return false
			if record.record not in snapshot.confirmed_results: return false
		else: return false
	for id in snapshot.completed_questions:
		if not catalog.data.questions.has(id): return false
	for entity in snapshot.materials.entities.values():
		for sources in entity.sources_by_content.values():
			if not _valid_sources(sources, []): return false
	for view in [snapshot.bar_view, snapshot.grid_view]:
		if view.get("type", "") not in ["all", "evidence", "testimony", "inference"] or view.get("sort", "") not in ["acquire", "name", "type"] or not view.get("positions_by_type") is Dictionary or not view.get("focus_ref") is Dictionary: return false
	for id in snapshot.current_statements:
		if not catalog.data.questions.has(id) or not catalog.data.statements.has(snapshot.current_statements[id]): return false
	for id in snapshot.drafts:
		var d = snapshot.drafts[id]
		if not d is Dictionary or not catalog.data.questions.has(id): return false
		if not d.get("slots") is Array or d.slots.size() != 2 or not d.get("target_selected") is bool or not _valid_saved_target(d.get("target_ref", {})): return false
		if d.target_ref.question_id != id: return false
		var identities: Array = []
		for ref in d.slots:
			if ref == null: continue
			if not ref is Dictionary or not catalog.valid_material_ref(ref): return false
			if not snapshot.materials.entities.has(ref.material_id) or ref.content_id not in snapshot.materials.entities[ref.material_id].acquired_content_ids or ref.material_id in identities: return false
			identities.append(ref.material_id)
	if not snapshot.current_result.is_empty() and not _valid_saved_result(snapshot.current_result): return false
	if snapshot.mode in ["response", "pending", "collected"] and snapshot.current_result.is_empty(): return false
	if snapshot.mode in ["selection", "failure", "response", "pending", "collected"] and not snapshot.chances.has(snapshot.question_id): return false
	if snapshot.mode == "selection" and (not snapshot.drafts.has(snapshot.question_id) or int(snapshot.chances[snapshot.question_id]) == 0): return false
	if snapshot.mode == "failure" and (int(snapshot.chances[snapshot.question_id]) > failure_at() or snapshot.question_id in snapshot.completed_questions): return false
	if snapshot.mode in ["response", "failure", "dialogue", "investigation"] and snapshot.card_ui_page != "closed": return false
	if snapshot.mode == "selection" and snapshot.card_ui_page not in ["selection", "grid"]: return false
	if snapshot.mode == "pending" and (snapshot.card_ui_page != "pending" or snapshot.current_result.collected or str(snapshot.current_result.inference_content_id).is_empty()): return false
	if snapshot.mode == "collected" and (snapshot.card_ui_page != "collected" or not snapshot.current_result.collected): return false
	for id in snapshot.attempt_results:
		if not _valid_saved_result(snapshot.attempt_results[id]): return false
	for id in snapshot.failure_records:
		if not catalog.data.questions.has(id) or not _valid_saved_result(snapshot.failure_records[id]): return false
	for id in snapshot.deducted_attempts:
		if not snapshot.attempt_results.has(id) or snapshot.attempt_results[id].feedback != "incorrect": return false
	return true

func _valid_saved_target(target) -> bool:
	if not target is Dictionary or not catalog.data.questions.has(target.get("question_id", "")): return false
	var q: Dictionary = catalog.data.questions[target.question_id]
	if target.get("target_kind") != q.get("target_kind", "statement"): return false
	if target.target_kind == "reasoning": return target.get("question_text_id") == q.get("question_text_id") and not target.has("statement_ref")
	var ref = target.get("statement_ref")
	return ref is Dictionary and catalog.data.statements.has(ref.get("statement_id", "")) and catalog.data.statements[ref.statement_id].claim_id == ref.get("claim_id") and not target.has("question_text_id")

func _valid_saved_result(result) -> bool:
	if not result is Dictionary: return false
	for key in ["result_id", "run_id", "call_id", "question_id", "relation_id", "target_ref", "used_sources", "feedback", "node", "inference_content_id", "collected", "confirmed", "resolution_key"]:
		if not result.has(key): return false
	if not _valid_saved_target(result.target_ref) or not catalog.data.nodes.has(result.node) or not result.used_sources is Array: return false
	if result.feedback not in ["full", "partial", "counter", "incorrect", "insufficient"]: return false
	if not str(result.relation_id).is_empty() and not catalog.data.relations.has(result.relation_id): return false
	if not str(result.inference_content_id).is_empty() and not catalog.data.contents.has(result.inference_content_id): return false
	return _valid_sources(result.used_sources, [])

func _valid_sources(sources, ancestors: Array) -> bool:
	if not sources is Array or ancestors.size() > 64: return false
	for source in sources:
		if not source is Dictionary: return false
		var chain := ancestors.duplicate()
		match source.get("kind", ""):
			"material":
				if not source.get("ref") is Dictionary or not catalog.valid_material_ref(source.ref): return false
				var key: String = source.ref.content_id
				if key in chain: return false
				chain.append(key)
				if not _valid_sources(source.get("sources"), chain): return false
			"acquisition":
				if not source.get("text_id") is String or not catalog.data.texts.has(source.text_id): return false
				for key in ["entry_id", "source_id", "path_key"]:
					if not source.get(key) is String: return false
			"confirmed":
				var record = source.get("record")
				if not record is Dictionary or not record.get("confirmed", false) or not _valid_saved_target(record.get("target_ref", {})): return false
				if not record.has("result_id") or not catalog.data.relations.has(record.get("relation_id", "")): return false
				if record.result_id in chain: return false
				chain.append(record.result_id)
				if not _valid_sources(record.get("used_sources"), chain): return false
			_: return false
	return true

func restore_card_state(snapshot: Dictionary) -> bool:
	# 在任何替换前验证；失败不改写当前会话。
	if not validate_card_state(snapshot): return _reject("玩法快照不完整或内容版本不受支持，当前会话已保留")
	state = snapshot.duplicate(true)
	store.restore(state.materials)
	state.erase("materials")
	presenting = false
	processing = false
	inspection_depth = 0
	paused = false
	_changed()
	return true
