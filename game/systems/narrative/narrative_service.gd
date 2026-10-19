extends Node
## 文案系统公开接口：管理当前文本、逐字进度、已读判定、章节和可恢复快照。

signal changed
signal progressed(visible: String, typing: bool)
signal text_started(record: Dictionary)
signal text_finished(record: Dictionary)
signal event_started(record: Dictionary)
signal performance_requested(events: Array)
signal notice(message: String)
signal typing_sound_requested(resource_ref: String) # 仅实际新增正文字符请求一次声音，不为快显或重绘补播。

const CatalogScript = preload("res://systems/narrative/narrative_catalog.gd")
const WorkbookLoader = preload("res://systems/narrative/narrative_workbook_loader.gd")
const SNAPSHOT_VERSION := 1
var catalog: RefCounted = CatalogScript.new()
var state: Dictionary = {}
var typewriter_speed := 30.0
var normal_characters_per_second := 30.0
var read_fast_multiplier := 4.0
var read_fast_page_delay := 0.15
var typing_sound_min_interval := 0.11
var _typing_sound_elapsed := 0.11
var punctuation_pause := {"，": 0.12, "、": 0.12, "；": 0.12, "。": 0.26, "！": 0.26, "？": 0.26, "…": 0.26}
var hidden := false
var reading_log := false
var fast_mode := ""
var _elapsed := 0.0
var _page_wait := 0.0
var _fast_visited: Array[String] = []
var _page_ends: Array[int] = []
var seen_storage_path := "" # 独立已看文件；空路径用于纯内存测试。
var seen_versions := {}
var stage_wait_left := 0.0 # 明确演出时长；隐藏、记录和暂停时不推进。

func configure_playback(parameters: Dictionary) -> void:
	# 正式文案公参是唯一标准值；玩家偏好只乘倍率，不改标点停顿和演出时长。
	normal_characters_per_second = maxf(1, float(parameters.get("normal_characters_per_second", 30)))
	typewriter_speed = normal_characters_per_second
	read_fast_multiplier = maxf(1, float(parameters.get("read_fast_multiplier", 4)))
	read_fast_page_delay = maxf(0, float(parameters.get("read_fast_page_delay_ms", 150)) / 1000.0)
	typing_sound_min_interval = maxf(0, float(parameters.get("typing_sound_min_interval_ms", 110)) / 1000.0)
	var pauses: Dictionary = parameters.get("punctuation_pause_ms", {})
	for mark in ["，", "、", "；", "："]: punctuation_pause[mark] = float(pauses.get("comma", 120)) / 1000.0
	for mark in ["。", "！", "？", "…"]: punctuation_pause[mark] = float(pauses.get("sentence_end", 260)) / 1000.0

func set_text_speed(level: int) -> void:
	typewriter_speed = normal_characters_per_second * {1: 0.5, 2: 1.0, 3: 1.5}.get(level, 1.0)

func load_seen_registry(path: String) -> bool:
	seen_storage_path = path
	seen_versions = {}
	if path.is_empty() or not FileAccess.file_exists(path): return true
	var file := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text()) if file != null else null
	if not data is Dictionary or data.get("version") != 1 or not data.get("read_versions") is Dictionary: return _reject("已看记录无效，原文件已保留")
	for id in data.read_versions:
		var version = data.read_versions[id]
		if not id is String or not (version is int or version is float) or not is_finite(float(version)) or version < 1 or floor(float(version)) != float(version): return _reject("已看记录无效，原文件已保留")
	seen_versions = data.read_versions.duplicate(true)
	return true

func _persist_seen() -> bool:
	if seen_storage_path.is_empty(): return true
	var temporary := seen_storage_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return _reject("已看记录保存失败，本次运行记录保留")
	file.store_string(JSON.stringify({"version": 1, "read_versions": seen_versions}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(seen_storage_path)) != OK: return _reject("已看记录保存失败，本次运行记录保留")
	return true

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
	var previous_reads: Dictionary = state.get("read_versions", {}).duplicate(true)
	for seen_id in seen_versions: previous_reads[seen_id] = maxi(int(previous_reads.get(seen_id, 0)), int(seen_versions[seen_id]))
	var previous_ids: Array = state.get("read_text_ids", []).duplicate()
	state = {"snapshot_version": SNAPSHOT_VERSION, "current_text_id": id, "chapter_id": catalog.text_record(id).get("chapter_id", ""),
		"scene_id": catalog.text_record(id).get("scene_id", ""), "read_text_ids": [], "read_versions": {},
		"visible_characters": 0, "typing": true, "waiting_for_choice": false, "finished": false,
		"history": [], "active_event_id": "", "active_performance_id": "",
		"state_values": {}, "return_context": {}}
	state.read_versions = previous_reads
	state.read_text_ids = previous_ids
	state["visible_history"] = []
	hidden = false
	reading_log = false
	stop_fast_read()
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
	state["page_start"] = 0
	state["seen_at_start"] = not can_read_again(id, int(row.get("read_version", 1)))
	state.visible_history.append({"text_id": id, "speaker_name": row.get("speaker_name", ""), "text_type": row.get("text_type", ""), "text": ""})
	_page_ends = [current_text().length()]
	_elapsed = 0.0
	_page_wait = 0.0
	_typing_sound_elapsed = typing_sound_min_interval
	stage_wait_left = maxf(0, float(row.get("stage_duration_ms", 0)) / 1000.0)
	# 界面短字和章节名整页呈现；普通对白、心声、旁白与时地沿逐字参数。
	if str(row.get("text_kind", row.get("text_type", ""))) in ["option_text", "ui_text", "chapter_title", "章节字幕"]:
		state.visible_characters = current_text().length()
		state.typing = false
	if not state.seen_at_start or not catalog.choices_from_text(id).is_empty(): stop_fast_read()
	text_started.emit(row.duplicate(true))
	_changed()

func current_record() -> Dictionary:
	return catalog.text_record(str(state.get("current_text_id", "")))

func current_text() -> String:
	return catalog.text(str(state.get("current_text_id", "")))

func visible_text() -> String:
	var value := current_text()
	var start_index := int(state.get("page_start", 0))
	return value.substr(start_index, clampi(int(state.get("visible_characters", 0)), start_index, value.length()) - start_index)

func set_page_ends(ends: Array[int]) -> void:
	# 页面按实际字形宽度生成两行分页；重新排版不丢弃已显示的字符。
	var previous := 0
	for end in ends:
		if end <= previous or end > current_text().length(): return
		previous = end
	if ends.is_empty() or previous != current_text().length(): return
	_page_ends = ends.duplicate()

func page_end() -> int:
	for end in _page_ends:
		if end > int(state.get("page_start", 0)): return end
	return current_text().length()

func is_typing() -> bool:
	return bool(state.get("typing", false))

func advance() -> bool:
	if state.is_empty(): return false
	if hidden: return set_hidden(false)
	if reading_log: return false
	if state.get("finished", false): return false
	if not str(state.get("active_event_id", "")).is_empty(): return _reject("此事件的可执行步骤尚未配置，请返回原流程。")
	if not fast_mode.is_empty():
		stop_fast_read()
		return true
	# 本次点击只快显当前页，不跨页、不登记已读，也不提交文本结束事件。
	if is_typing():
		state.visible_characters = page_end()
		state.typing = false
		_elapsed = 0.0
		_page_wait = 0.0
		_progressed()
		return true
	if stage_wait_left > 0: return false
	if bool(state.get("waiting_for_choice", false)): return false
	if page_end() < current_text().length():
		state.page_start = page_end()
		state.visible_characters = state.page_start
		state.typing = true
		_elapsed = 0.0
		_page_wait = 0.0
		_changed()
		return true
	return _finish_current_text()

func tick(delta: float) -> void:
	if state.is_empty() or hidden or reading_log or not is_finite(delta) or delta <= 0: return
	_typing_sound_elapsed += delta
	if stage_wait_left > 0:
		var remaining := maxf(0, delta - stage_wait_left)
		stage_wait_left = maxf(0, stage_wait_left - delta)
		if remaining <= 0: return
		delta = remaining
	if fast_mode == "skip":
		state.visible_characters = page_end()
		state.typing = false
		_progressed()
	elif is_typing():
		_elapsed += delta * (read_fast_multiplier if fast_mode == "accelerate" else 1.0)
		var value := current_text()
		var breaks := TextServerManager.get_primary_interface().string_get_character_breaks(value)
		var before := int(state.visible_characters)
		while int(state.visible_characters) < page_end():
			var index := int(state.visible_characters)
			var duration := 1.0 / typewriter_speed
			# 连续标点只等待较长的一次，组合字符按字素边界一次显示。
			if index > 0 and (index >= value.length() or not punctuation_pause.has(value[index])):
				var cursor := index - 1
				while cursor >= 0 and punctuation_pause.has(value[cursor]):
					duration = maxf(duration, float(punctuation_pause[value[cursor]]))
					cursor -= 1
			if _elapsed < duration: break
			_elapsed -= duration
			var next_index := index + 1
			for boundary in breaks:
				if boundary > index:
					next_index = boundary
					break
			state.visible_characters = mini(next_index, page_end())
		if state.visible_characters >= page_end():
			state.typing = false
			_page_wait = 0.0
		_request_typing_sound(value.substr(before, int(state.visible_characters) - before))
		_progressed()
	if not is_typing() and not fast_mode.is_empty():
		_page_wait += delta
		if _page_wait >= read_fast_page_delay:
			var mode := fast_mode
			fast_mode = ""
			if page_end() < current_text().length():
				advance()
				fast_mode = mode
			else:
				_fast_next(mode)

func _request_typing_sound(added: String) -> void:
	# 声音忙时直接丢弃；一帧积累多个字符也只请求一次，不能排队补播。
	if not fast_mode.is_empty() or _typing_sound_elapsed < typing_sound_min_interval: return
	var audible := false
	for character in added:
		if not character.strip_edges().is_empty() and not "，。、；：！？…—·“”‘’（）()[]【】《》〈〉「」『』.,;:!?-\"'".contains(character):
			audible = true
			break
	if not audible: return
	var kind := str(current_record().get("text_kind", current_record().get("text_type", "")))
	if kind in ["option_text", "ui_text", "chapter_title", "章节字幕"]: return
	_typing_sound_elapsed = 0
	typing_sound_requested.emit("SFX_TEXT_TIME_LOCATION" if kind in ["time_caption", "时间字幕"] else "SFX_TEXT_DIALOGUE")

func fast_read_available() -> bool:
	return not state.is_empty() and bool(state.get("seen_at_start", false)) and not state.get("finished", false) and not state.get("waiting_for_choice", false) and not hidden and not reading_log and catalog.choices_from_text(str(state.current_text_id)).is_empty()

func begin_fast_read(mode: String) -> bool:
	if mode not in ["accelerate", "skip"] or not fast_read_available(): return false
	fast_mode = mode
	_fast_visited.assign([str(state.current_text_id)])
	_page_wait = 0.0
	return true

func stop_fast_read() -> void:
	fast_mode = ""
	_page_wait = 0.0

func _fast_next(mode: String) -> void:
	var row := current_record()
	var transitions: Array = catalog.transitions_from_text(str(state.current_text_id))
	if transitions.is_empty() and not str(row.get("next_text_id", "")).is_empty(): transitions = [{"target_text_id": row.next_text_id}]
	if transitions.size() != 1 or not catalog.choices_from_text(str(state.current_text_id)).is_empty(): return
	var target := str(transitions[0].get("target_text_id", ""))
	var next_row: Dictionary = catalog.text_record(target)
	# 快读永不越过事件、场景／章节边界、未看文本和循环跳转。
	if target.is_empty() or next_row.is_empty() or not str(transitions[0].get("target_event_id", "")).is_empty(): return
	if target in _fast_visited:
		notice.emit("文案快读遇到循环跳转，已停止")
		return
	if next_row.get("scene_id", "") != row.get("scene_id", "") or next_row.get("chapter_id", "") != row.get("chapter_id", ""): return
	_fast_visited.append(target)
	_finish_current_text()
	if fast_read_available(): fast_mode = mode

func set_hidden(value: bool) -> bool:
	if value and (state.is_empty() or state.get("waiting_for_choice", false) or state.get("finished", false)): return false
	stop_fast_read()
	hidden = value
	_changed()
	return true

func set_log_open(value: bool) -> void:
	stop_fast_read()
	reading_log = value
	_changed()

func visible_history() -> Array:
	return state.get("visible_history", []).duplicate(true)

func _finish_current_text() -> bool:
	if state.get("finished", false): return false
	var id := str(state.current_text_id)
	var row: Dictionary = catalog.text_record(id)
	var version := int(row.get("read_version", 1))
	if id not in state.read_text_ids: state.read_text_ids.append(id)
	state.read_versions[id] = maxi(int(state.read_versions.get(id, 0)), version)
	if int(seen_versions.get(id, 0)) < version:
		seen_versions[id] = version
		_persist_seen()
	text_finished.emit(row.duplicate(true))
	var transitions: Array = catalog.transitions_from_text(id)
	if transitions.is_empty() and not str(row.get("next_text_id", "")).is_empty():
		transitions = [{"target_text_id": row.next_text_id, "order": 1, "transition_type": "single"}]
	if transitions.is_empty():
		state.finished = true
		_changed()
		return false
	if not catalog.choices_from_text(id).is_empty():
		if catalog.choices_from_text(id).size() != transitions.size(): return _reject("本页同时包含不同用途的接续，尚未配置界面执行方式。")
		stop_fast_read()
		state.waiting_for_choice = true
		_changed()
		return true
	if transitions.size() != 1: return _reject("本页需要条件或并列接续，尚未配置执行方式。")
	return _apply_transition(transitions[0])

func choose_transition(index: int) -> bool:
	if not bool(state.get("waiting_for_choice", false)): return false
	var transitions: Array = catalog.choices_from_text(str(state.get("current_text_id", "")))
	if transitions.is_empty(): return false
	if index < 0 or index >= transitions.size(): return false
	stop_fast_read()
	return _apply_transition(transitions[index])

func _apply_transition(row: Dictionary) -> bool:
	# 不把条件分支、并列控件和动态返回冒充普通下一句。
	# 完整执行器接入前保留原调用位置，并向玩家说明待配状态。
	var kind := str(row.get("transition_type", "single")).to_lower()
	if kind not in ["", "single", "单路", "choice", "选项", "按钮", "button", "当前事件结束"]: return _reject("此接续类型尚未接入：" + kind)
	for key in ["condition", "enabled_condition"]:
		if str(row.get(key, "")).strip_edges().to_lower() not in ["", "1 == 1", "true"]: return _reject("此接续需要状态条件执行器，当前文本保持。")
	if not str(row.get("dynamic_state_id", "")).is_empty() or not str(row.get("return_state_id", "")).is_empty(): return _reject("此接续需要明确的动态返回位置，当前文本保持。")
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
	# 仅采用调用者明确登记的接续，不执行事件内容中的自然语言制作说明。
	if catalog.data.get("event_bindings", {}).has(event_id):
		var binding: Dictionary = catalog.data.event_bindings[event_id]
		state.active_event_id = ""
		state["return_action"] = binding.get("return_action", "")
		return _apply_transition(binding)
	var row: Dictionary = catalog.data.events[event_id]
	state.active_event_id = event_id
	state.chapter_id = row.get("chapter_id", state.chapter_id)
	state.typing = false
	event_started.emit(row.duplicate(true))
	# 制作说明不转为动作，也不跳过必需演出直接走后继。
	if not str(row.get("content", "")).is_empty():
		_changed()
		return _reject("事件可执行步骤尚未配置，已保留当前调用位置。")
	var performances := []
	for id in catalog.data.get("performance_events", {}):
		var performance: Dictionary = catalog.data.performance_events[id]
		if performance.get("event_id", "") == event_id: performances.append(performance.duplicate(true))
	performances.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	if not performances.is_empty(): performance_requested.emit(performances)
	var transitions: Array = catalog.transitions_from_event(event_id)
	if transitions.is_empty(): return false
	if transitions.size() > 1: return _reject("事件后继需要明确的条件或返回入口，当前调用保持。")
	state.active_event_id = ""
	return _apply_transition(transitions[0])

func can_read_again(text_id: String, version: int = 1) -> bool:
	return maxi(int(seen_versions.get(text_id, 0)), int(state.get("read_versions", {}).get(text_id, 0))) < version

func set_state_value(state_id: String, value) -> void:
	state.state_values[state_id] = value
	_changed()

func can_save() -> bool:
	# 文案对白和选择期间均禁止调查存档，结束并归还调查后再按调查资格判断。
	return state.is_empty() or bool(state.get("finished", false))

func export_snapshot() -> Dictionary:
	return {"snapshot_version": SNAPSHOT_VERSION, "state": state.duplicate(true), "typewriter_speed": typewriter_speed}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or int(snapshot.get("snapshot_version", -1)) != SNAPSHOT_VERSION: return false
	var incoming = snapshot.get("state", {})
	if not incoming is Dictionary or not incoming.has("current_text_id"): return false
	var id := str(incoming.get("current_text_id", ""))
	if not id.is_empty() and not catalog.has_text(id): return false
	for key in ["visible_characters", "page_start"]:
		var number = incoming.get(key, 0)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floor(float(number)): return false
	var visible := int(incoming.get("visible_characters", 0))
	if visible < 0 or (not id.is_empty() and visible > catalog.text(id).length()): return false
	if incoming.get("read_text_ids", []) is not Array or incoming.get("read_versions", {}) is not Dictionary: return false
	if incoming.get("waiting_for_choice", false) and incoming.get("typing", false): return false
	for key in ["typing", "waiting_for_choice", "finished"]:
		if not incoming.get(key, false) is bool: return false
	var speed = snapshot.get("typewriter_speed", typewriter_speed)
	if not (speed is float or speed is int) or not is_finite(float(speed)) or speed <= 0: return false
	if not incoming.get("visible_history", []) is Array: return false
	for key in ["state_values", "return_context"]:
		if not incoming.get(key, {}) is Dictionary: return false
	for key in ["history", "read_text_ids"]:
		if not incoming.get(key, []) is Array: return false
		for text_id in incoming.get(key, []):
			if not text_id is String or not catalog.has_text(text_id): return false
	for text_id in incoming.get("read_versions", {}):
		var version = incoming.read_versions[text_id]
		if not text_id is String or not (version is int or version is float) or not is_finite(float(version)) or version < 1 or floor(float(version)) != float(version): return false
	for item in incoming.get("visible_history", []):
		if not item is Dictionary or not item.get("text", "") is String or not item.get("speaker_name", "") is String: return false
	if int(incoming.get("page_start", 0)) < 0 or int(incoming.get("page_start", 0)) > visible: return false
	return true

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	state = snapshot.state.duplicate(true)
	if not state.has("visible_history"): state.visible_history = []
	state["seen_at_start"] = not can_read_again(str(state.current_text_id), int(current_record().get("read_version", 1)))
	_page_ends = [current_text().length()]
	_elapsed = 0.0
	_page_wait = 0.0
	hidden = false
	reading_log = false
	stop_fast_read()
	typewriter_speed = float(snapshot.get("typewriter_speed", typewriter_speed))
	_changed()
	return true

func _reject(message: String) -> bool:
	notice.emit(message)
	return false

func _changed() -> void:
	changed.emit()

func _progressed() -> void:
	if not state.get("visible_history", []).is_empty():
		state.visible_history[-1].text = current_text().substr(0, int(state.visible_characters))
	progressed.emit(visible_text(), is_typing())
