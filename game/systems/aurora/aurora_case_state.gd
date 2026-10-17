extends RefCounted
## 所有系统共同读取的案件状态。条件为“分支或、分支内且”，反条件严格保留false。
var config: RefCounted
var data := {}
var errors: Array[String] = []
var _executing := {}
var _transaction_depth := 0
var _checking := {}
var commit_guard: Callable

func bind(value: RefCounted) -> void:
	config = value

func reset() -> void:
	data = {"chapter": "CH01", "scene": "SC01", "view": "VIEW_SC01_MAIN", "events": {}, "texts": {}, "entries": {},
		"npc": {}, "objects": {}, "profiles": {}, "materials": {}, "next_acquisition": 1, "revision": 0,
		"completed_questions": {}, "drafts": {}, "chances": {}, "climaxes": {}, "results": {}, "cat_first_seen": false,
		"history": [], "ending_started": false, "ending_completed": false, "ending_cursor": 0}
	errors.clear()
	_executing.clear()

func condition(id: String) -> bool:
	if id.is_empty(): return true
	if not config.conditions.has(id): return false
	if _checking.has(id): return false
	_checking[id] = true
	for terms in config.conditions[id].values():
		var all_met := true
		for term in terms:
			var actual := false
			var ref := str(term.get("ref", ""))
			match str(term.kind):
				"event": actual = bool(data.events.get(ref, false))
				"text": actual = bool(data.texts.get(ref, false))
				"entry":
					# 正式表用entry判断可调用入口，dispatch据此选择前后阶段。
					var entry: Dictionary = config.entries.get(ref, {})
					actual = not entry.is_empty() and condition(str(entry.get("condition_id", "")))
					var scenes: Array = config.ids(str(entry.get("allowed_scene_ids", "")))
					if entry.get("location_mode") == "caller" and not scenes.is_empty(): actual = actual and str(data.scene) in scenes
				"chapter": actual = data.chapter == ref
				"current_scene": actual = data.scene == ref
				"npc_scene": actual = data.npc.get(ref, {}).get("scene_id", "") == str(term.get("scene_id", ""))
				_:
					if str(term.kind) not in errors: errors.append(str(term.kind))
					all_met = false
			if actual != bool(term.get("expected", true)): all_met = false
		if all_met:
			_checking.erase(id)
			return true
	_checking.erase(id)
	return false

func event(id: String, source: Dictionary = {}) -> bool:
	# 在候选状态执行整个结果组；嵌套事件或资源引用失败时一并撤回。
	var before := data.duplicate(true)
	_transaction_depth += 1
	var success := _apply_event(id, source)
	# 正式表把两处餐食观察的聚合结果独立声明，却未挂在任一观察动作中。
	# 仅在实际观察事务内补接；另一处尚未观察时不会授予材料。
	if success and id in ["EV_KITCHEN_PORTION_OBSERVED", "EV_STATION_TRAY_OBSERVED"] and not data.events.get("EV_MEAL_LOCATIONS_BOTH_OBSERVED", false):
		if condition("COND_GATE_EV_MEAL_LOCATIONS_BOTH_OBSERVED"):
			success = _apply_event("EV_MEAL_LOCATIONS_BOTH_OBSERVED", source)
	# 六稿正文明确I01结束兄弟返回空值班室；表只记录了赴站长室，漏记返回。
	if success and id == "EV_INJURY_DEATH_SEQUENCE_LINKED":
		for person in ["CHR10", "CHR11"]: data.npc[person] = {"scene_id": "SC10"}
	_transaction_depth -= 1
	if success and _transaction_depth == 0 and commit_guard.is_valid():
		var candidate: Dictionary = data.duplicate(true)
		data = before
		success = bool(commit_guard.call(id, before, candidate))
		if success: data = candidate
	if not success: data = before
	return success

func _apply_event(id: String, source: Dictionary) -> bool:
	if id.is_empty(): return true
	if not config.events.has(id): return false
	if _executing.has(id): return true
	var rows: Array = config.events[id]
	for row in rows:
		if not condition(str(row.get("condition_id", ""))): return data.events.get(id, false)
	# 同一事件回访可更新知识组合；取得、版本和来源各自幂等，不用旧事件布尔跳过整组。
	_executing[id] = true
	var already_applied := bool(data.events.get(id, false))
	data.events[id] = true
	for row in rows:
		if not condition(str(row.get("action_condition_id", ""))): continue
		# 回访可补充新知识版，不能重放首次迁移或把章节退回事件发生时。
		if already_applied and row.get("kind") in ["set_chapter", "set_npc_state", "set_object_state", "start_ending"]: continue
		var ref := str(row.get("ref", ""))
		var value = row.get("value", "")
		match str(row.get("kind", "")):
			"", "refresh_goals": pass
			"set_chapter": data.chapter = ref
			"set_npc_state":
				var parsed = {"scene_id": str(value)} if config.scenes.has(str(value)) else (JSON.parse_string(str(value)) if value is String else value)
				if not parsed is Dictionary or not config.actors.has(ref) or not config.scenes.has(parsed.get("scene_id", "")):
					_executing.erase(id)
					return false
				data.npc[ref] = parsed.duplicate(true)
			"set_object_state":
				var parsed = JSON.parse_string(str(value)) if value is String and str(value).begins_with("{") else value
				# 已交付表对此历史位置标签有明确含义；保留原值，并仅映射被采用的SC04材料桌。
				data.objects[ref] = parsed if parsed is Dictionary else {"location_label": value, "scene_id": "SC04" if value == "SC04材料桌" else ""}
			"set_person_profile":
				if config.profiles.has(str(value)):
					var old := str(data.profiles.get(ref, ""))
					if old.is_empty() or str(value).naturalnocasecmp_to(old) >= 0: data.profiles[ref] = str(value)
			"grant_content":
				var content_id := str(row.get("content_id", ""))
				if content_id.is_empty(): content_id = str(value) if config.contents.has(str(value)) else ref
				if not grant(content_id, source.merged({"event_id": id}, true)):
					_executing.erase(id)
					return false
			"complete_event":
				if not event(ref, source):
					_executing.erase(id)
					return false
			"start_ending": data.ending_started = true
			_:
				errors.append("未支持的事件动作：" + str(row.kind))
				_executing.erase(id)
				return false
	_executing.erase(id)
	data.revision = int(data.revision) + 1
	return true

func grant(content_id: String, source: Dictionary) -> bool:
	if not config.contents.has(content_id): return false
	var content: Dictionary = config.contents[content_id]
	var id := str(content.material_id)
	if not data.materials.has(id):
		data.materials[id] = {"order": data.next_acquisition, "current": content_id, "versions": {}, "read": {}, "star": false}
		data.next_acquisition = int(data.next_acquisition) + 1
	var record: Dictionary = data.materials[id]
	if not record.versions.has(content_id): record.versions[content_id] = []
	var sources: Array = record.versions[content_id]
	# 推论来源在首次形成冻结；普通材料同版可以追加另一个真实取得路径。
	if sources.is_empty() or (config.materials[id].type != "inference" and source not in sources): sources.append(source.duplicate(true))
	if int(content.version) > int(config.contents[record.current].version): record.current = content_id
	return true

func owns(content_id: String) -> bool:
	var row: Dictionary = config.contents.get(content_id, {})
	return not row.is_empty() and data.materials.get(row.material_id, {}).get("versions", {}).has(content_id)

func finish_text(row: Dictionary) -> void:
	if not config.texts.has(str(row.get("text_id", ""))): return
	data.texts[str(row.text_id)] = true
	# 人物公开事件的实际锚点由其action_condition_id读取已听文本；只在正文
	# 实际完成时检查一次，不在载表、地图回访或读档时补执行。
	for id in config.events:
		if not str(id).begins_with("EV_PERSON_PUBLIC_") or data.events.get(id, false): continue
		for action in config.events[id]:
			if action.get("kind") == "set_person_profile" and condition(str(action.get("action_condition_id", ""))):
				event(id, {"text": row.text_id, "scene": data.scene})
				break

func validate(incoming: Dictionary) -> bool:
	for key in ["events", "texts", "entries", "npc", "objects", "profiles", "materials", "completed_questions", "drafts", "chances", "climaxes", "results"]:
		if not incoming.get(key) is Dictionary: return false
	if not config.chapters.has(incoming.get("chapter", "")) or not config.scenes.has(incoming.get("scene", "")): return false
	for id in incoming.events:
		if not config.events.has(id) or not incoming.events[id] is bool: return false
	for id in incoming.texts:
		if not config.texts.has(id) or not incoming.texts[id] is bool: return false
	for id in incoming.entries:
		if not config.entries.has(id) or not incoming.entries[id] is bool: return false
	for person in incoming.profiles:
		if not config.profiles.has(incoming.profiles[person]) or config.profiles[incoming.profiles[person]].person_id != person: return false
	var orders := {}
	for id in incoming.materials:
		var record = incoming.materials[id]
		if not config.materials.has(id) or not record is Dictionary or not record.get("versions") is Dictionary: return false
		if not record.get("read", {}) is Dictionary or not record.get("star", false) is bool: return false
		if not _integer(record.get("order")) or record.order < 1 or orders.has(record.order): return false
		orders[record.order] = true
		if not record.versions.has(record.get("current", "")): return false
		for content_id in record.versions:
			if not config.contents.has(content_id) or config.contents[content_id].material_id != id or not record.versions[content_id] is Array: return false
			if int(config.contents[content_id].version) > int(config.contents[record.current].version): return false
	for id in incoming.completed_questions:
		if not config.questions.has(id): return false
	for id in incoming.chances:
		if not config.questions.has(id) or not _integer(incoming.chances[id]) or incoming.chances[id] < 0 or incoming.chances[id] > 3: return false
	for id in incoming.drafts:
		if not config.questions.has(id) or not incoming.drafts[id] is Dictionary: return false
		for content_id in incoming.drafts[id].get("slots", []):
			if not content_id is String or (not content_id.is_empty() and not _incoming_owns(incoming, content_id)): return false
	return _integer(incoming.get("revision")) and incoming.revision >= 0 and _integer(incoming.get("next_acquisition")) and incoming.next_acquisition > orders.size() and incoming.get("cat_first_seen") is bool

func _incoming_owns(incoming: Dictionary, id: String) -> bool:
	return config.contents.has(id) and incoming.materials.get(config.contents[id].material_id, {}).get("versions", {}).has(id)

func _integer(value) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value))
