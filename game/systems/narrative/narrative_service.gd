extends Node
## 文案系统公开接口：管理当前文本、逐字进度、已读判定、章节和可恢复快照。

signal changed
signal progressed(visible: String, typing: bool)
signal text_started(record: Dictionary)
signal text_finished(record: Dictionary)
signal event_started(record: Dictionary)
signal performance_requested(events: Array)
signal notice(message: String)

const CatalogScript = preload("res://systems/narrative/narrative_catalog.gd")
const WorkbookLoader = preload("res://systems/narrative/narrative_workbook_loader.gd")
const SNAPSHOT_VERSION := 1
var catalog: RefCounted = CatalogScript.new()
var state: Dictionary = {}
var typewriter_speed := 60.0
var punctuation_pause := {"。": 0.12, "！": 0.26, "？": 0.26, "……": 0.26}

func initialize(definition: Dictionary = {}) -> bool:
	return catalog.configure(definition)

func initialize_from_workbook(path: String = WorkbookLoader.DEFAULT_PATH) -> bool:
	var loader := WorkbookLoader.new()
	var definition := loader.load_workbook(path)
	if definition.is_empty():
		for message in loader.errors: notice.emit(message)
		return false
	return initialize(definition)

func start(start_text_id: String = "") -> bool:
	var id := start_text_id
	if id.is_empty(): id = _default_start_text()
	if id.is_empty() or not catalog.data.texts.has(id): return _reject("文案没有可用起始文本")
	state = {"snapshot_version": SNAPSHOT_VERSION, "current_text_id": id, "chapter_id": catalog.text_record(id).get("chapter_id", ""),
		"scene_id": catalog.text_record(id).get("scene_id", ""), "read_text_ids": [], "read_versions": {},
		"visible_characters": 0, "typing": true, "waiting_for_choice": false, "finished": false,
		"history": [], "active_event_id": "", "active_performance_id": "",
		"state_values": {}, "return_context": {}}
	_begin_text(id)
	return true

func _default_start_text() -> String:
	for id in catalog.data.get("texts", {}):
		var row: Dictionary = catalog.data.texts[id]
		if bool(row.get("is_default_start", false)): return id
	for id in catalog.data.get("texts", {}): return id
	return ""

func _begin_text(id: String) -> void:
	var row: Dictionary = catalog.text_record(id)
	state.current_text_id = id
	state.chapter_id = row.get("chapter_id", "")
	state.scene_id = row.get("scene_id", "")
	state.visible_characters = 0
	state.typing = true
	state.waiting_for_choice = false
	state.finished = false
	state.history.append(id)
	text_started.emit(row.duplicate(true))
	_changed()

func current_record() -> Dictionary:
	return catalog.text_record(str(state.get("current_text_id", "")))

func current_text() -> String:
	return catalog.text(str(state.get("current_text_id", "")))

func visible_text() -> String:
	var value := current_text()
	return value.substr(0, clampi(int(state.get("visible_characters", 0)), 0, value.length()))

func is_typing() -> bool:
	return bool(state.get("typing", false))

func advance() -> bool:
	if state.is_empty(): return false
	if is_typing():
		state.visible_characters = current_text().length()
		state.typing = false
		_progressed()
		return true
	if bool(state.get("waiting_for_choice", false)): return false
	return _finish_current_text()

func tick(delta: float) -> void:
	if not is_typing(): return
	var count := int(state.visible_characters) + maxi(1, int(round(typewriter_speed * delta)))
	state.visible_characters = mini(count, current_text().length())
	if state.visible_characters >= current_text().length(): state.typing = false
	_progressed()

func _finish_current_text() -> bool:
	var id := str(state.current_text_id)
	var row: Dictionary = catalog.text_record(id)
	var version := int(row.get("read_version", 1))
	if id not in state.read_text_ids: state.read_text_ids.append(id)
	state.read_versions[id] = maxi(int(state.read_versions.get(id, 0)), version)
	text_finished.emit(row.duplicate(true))
	var transitions: Array = catalog.transitions_from_text(id)
	if transitions.is_empty() and not str(row.get("next_text_id", "")).is_empty():
		transitions = [{"target_text_id": row.next_text_id, "order": 1, "transition_type": "single"}]
	if transitions.is_empty():
		state.finished = true
		_changed()
		return false
	if not catalog.choices_from_text(id).is_empty():
		state.waiting_for_choice = true
		_changed()
		return true
	return _apply_transition(transitions[0])

func choose_transition(index: int) -> bool:
	if not bool(state.get("waiting_for_choice", false)): return false
	var transitions: Array = catalog.choices_from_text(str(state.get("current_text_id", "")))
	if transitions.is_empty(): return false
	if index < 0 or index >= transitions.size(): return false
	return _apply_transition(transitions[index])

func _apply_transition(row: Dictionary) -> bool:
	state.waiting_for_choice = false
	var target_text := str(row.get("target_text_id", ""))
	var target_event := str(row.get("target_event_id", ""))
	if not target_event.is_empty():
		return start_event(target_event)
	if bool(row.get("ends", false)):
		state.typing = false
		state.finished = true
		_changed()
		return false
	if target_text.is_empty() or not catalog.data.texts.has(target_text): return _reject("文案跳转目标不存在")
	_begin_text(target_text)
	return true

func start_event(event_id: String) -> bool:
	if not catalog.data.events.has(event_id): return _reject("演出事件不存在")
	var row: Dictionary = catalog.data.events[event_id]
	state.active_event_id = event_id
	state.chapter_id = row.get("chapter_id", state.chapter_id)
	state.typing = false
	event_started.emit(row.duplicate(true))
	var performances := []
	for id in catalog.data.get("performance_events", {}):
		var performance: Dictionary = catalog.data.performance_events[id]
		if performance.get("event_id", "") == event_id: performances.append(performance.duplicate(true))
	performances.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	if not performances.is_empty(): performance_requested.emit(performances)
	var transitions: Array = catalog.transitions_from_event(event_id)
	if transitions.is_empty(): return false
	if transitions.size() > 1:
		state.waiting_for_choice = true
		_changed()
		return true
	return _apply_transition(transitions[0])

func can_read_again(text_id: String, version: int = 1) -> bool:
	return int(state.get("read_versions", {}).get(text_id, 0)) < version

func set_state_value(state_id: String, value) -> void:
	state.state_values[state_id] = value
	_changed()

func can_save() -> bool:
	# 文案尚未启动时不参与当前调查存档；启动后只能在稳定文本或等待选择节点保存。
	return state.is_empty() or not bool(state.get("typing", false))

func export_snapshot() -> Dictionary:
	return {"snapshot_version": SNAPSHOT_VERSION, "state": state.duplicate(true), "typewriter_speed": typewriter_speed}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or int(snapshot.get("snapshot_version", -1)) != SNAPSHOT_VERSION: return false
	var incoming: Dictionary = snapshot.get("state", {})
	if not incoming is Dictionary or not incoming.has("current_text_id"): return false
	var id := str(incoming.get("current_text_id", ""))
	if not id.is_empty() and not catalog.has_text(id): return false
	var visible := int(incoming.get("visible_characters", 0))
	if visible < 0 or (not id.is_empty() and visible > catalog.text(id).length()): return false
	if incoming.get("read_text_ids", []) is not Array or incoming.get("read_versions", {}) is not Dictionary: return false
	if incoming.get("waiting_for_choice", false) and incoming.get("typing", false): return false
	return true

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	state = snapshot.state.duplicate(true)
	typewriter_speed = float(snapshot.get("typewriter_speed", typewriter_speed))
	_changed()
	return true

func _reject(message: String) -> bool:
	notice.emit(message)
	return false

func _changed() -> void:
	changed.emit()

func _progressed() -> void:
	progressed.emit(visible_text(), is_typing())
