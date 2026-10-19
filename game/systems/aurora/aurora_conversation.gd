extends RefCounted
## 内嵌人物采用同机位配对。这里只改变本次显示记录，不写NPC地点、事件或材料。
## 活跃槽位按实际逐句入场、清场和离场维护；背景只移除当前真正显示在前景的交集。
var session: Node
var model: RefCounted
var actor_config := {}
var active_slots: Dictionary = {}
var current_scene := ""
var current_view := ""
var current_entry := ""
var last_text := ""
var temporary_group := ""

func bind(value: Node) -> void:
	session = value
	model = preload("res://systems/aurora/aurora_investigation.gd").new()
	model.bind(session)
	var path: String = str(session.config.definition.root).path_join("02_文案/人物演出资源配置.json")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary: actor_config = parsed
	clear()

func clear() -> void:
	active_slots.clear()
	current_scene = ""
	current_view = ""
	current_entry = ""
	last_text = ""
	temporary_group = ""

func apply(row: Dictionary) -> void:
	var scene := str(session.case_state.data.scene)
	var view: String = session.investigation_view()
	var entry := str(session.active_entry)
	var text_id := str(row.get("text_id", ""))
	if scene != current_scene or view != current_view or bool(row.get("clear_positions", false)):
		active_slots.clear()
		temporary_group = ""
	if entry != current_entry: temporary_group = ""
	current_scene = scene
	current_view = view
	current_entry = entry
	var bindings: Dictionary = actor_config.get("scene_background_bindings", {})
	for cue in bindings.get("temporary_cues", []):
		if str(cue.get("entry_ref", "")) != entry: continue
		if str(cue.get("exit_before_text_ref", "")) == text_id: temporary_group = ""
		elif str(cue.get("text_ref", "")) == text_id: temporary_group = str(cue.get("group_ref", ""))
	# 结案双胞胎只可观察，禁止因点击心声把其中一人另放到前景。
	for binding in bindings.get("observation_bindings", []):
		if str(binding.get("entry_ref", "")) != entry: continue
		var resource := _background_record(str(binding.get("presentation_ref", "")))
		if not resource.is_empty():
			_use_background(row, resource, [])
			row["position"] = ""
			row["avatar_path"] = ""
			active_slots.clear()
		last_text = text_id
		return
	var dialogue := _can_enter(row)
	for binding in actor_config.get("embedded_character_views", []):
		if binding.get("scene_id") != scene or binding.get("view_id") != view or binding.get("conversation_entry_ref") != entry: continue
		var who := str(binding.get("character_id", ""))
		if str(session.case_state.data.npc.get(who, {}).get("scene_id", "")) != str(binding.get("actual_scene_id", "")): continue
		if not dialogue and active_slots.is_empty(): break
		var path: String = session.config.resource_path(str(binding.get("conversation_background_path", "")))
		var portrait: String = session.config.resource_path(str(binding.get("dialogue_actor_resource_path", "")))
		if not ResourceLoader.exists(path) or not ResourceLoader.exists(portrait): break
		row["background_path"] = path
		row["conversation_actor"] = {"character_id": who, "path": portrait, "position": str(binding.get("dialogue_position", "center"))}
		_track(row, row.conversation_actor)
		_remove_duplicates(row, [who])
		last_text = text_id
		return
	var groups: Array = []
	for binding in bindings.get("entry_bindings", []):
		if str(binding.get("entry_ref", "")) == entry:
			groups = binding.get("group_refs", []).duplicate()
			break
	if not temporary_group.is_empty(): groups = [temporary_group]
	_track(row)
	for group in model.presentation_catalog.get("groups", []):
		if group.get("id") not in groups: continue
		var temporary := str(group.get("selection_mode", "")) == "temporary_text_cue"
		if temporary:
			if str(group.get("id", "")) != temporary_group: continue
		elif group.get("scene_id") != scene or group.get("view_id") != view or not model._matches_presentation(group.get("selection_condition", {})):
			continue
		var embedded: Array = group.get("embedded_actor_refs", [])
		var foreground: Array[String] = []
		for actor in active_slots.values():
			if actor in embedded and actor not in foreground: foreground.append(str(actor))
		foreground.sort()
		var selected := str(group.get("base_background_ref", ""))
		for pair in group.get("pairs", []):
			var candidate: Array = pair.get("foreground_actor_refs", []).duplicate()
			candidate.sort()
			if candidate == foreground:
				selected = str(pair.get("background_ref", ""))
				break
		var resource := _background_record(selected)
		if resource.is_empty(): continue
		_use_background(row, resource, foreground)
		break
	last_text = text_id

func _track(row: Dictionary, replacement: Dictionary = {}) -> void:
	for who in row.get("exit_characters", []):
		for slot in active_slots.keys():
			if active_slots[slot] == who: active_slots.erase(slot)
	if not _can_enter(row): return
	var actor := str(replacement.get("character_id", row.get("character_id", "")))
	var path := str(replacement.get("path", row.get("avatar_path", row.get("portrait_path", ""))))
	var position := str(replacement.get("position", row.get("position", "")))
	var slot: int = {"左": 1, "中": 2, "右": 3, "left": 1, "center": 2, "right": 3, "1": 1, "2": 2, "3": 3}.get(position, 0)
	if actor.is_empty() or path.is_empty() or slot == 0 or not ResourceLoader.exists(path): return
	for asset in actor_config.get("assets", []):
		if session.config.resource_path(str(asset.get("resource_path", ""))) != path: continue
		if asset.get("facing_direction") == "right": slot = 1
		elif asset.get("facing_direction") == "left": slot = 3
		break
	for previous in active_slots.keys():
		if active_slots[previous] == actor: active_slots.erase(previous)
	active_slots[slot] = actor

func _can_enter(row: Dictionary) -> bool:
	var kind := str(row.get("text_type", row.get("text_kind", "")))
	return kind not in ["内心", "inner", "旁白", "narration", "画外对白", "offscreen", "offscreen_dialogue", "time_caption", "chapter_title", "时间字幕", "章节字幕"] and not str(row.get("character_id", "")).is_empty()

func _background_record(id: String) -> Dictionary:
	for resource in model.presentation_catalog.get("resources", []):
		if str(resource.get("id", "")) == id:
			var result: Dictionary = resource.duplicate(true)
			result["path"] = session.config.resource_path(str(resource.get("resource_path", "")))
			return result if ResourceLoader.exists(result.path) else {}
	var resource: Dictionary = model.view_resource(id)
	var path := str(resource.get("resource_or_text_ref", ""))
	return {"path": path, "embedded_actor_refs": []} if not path.is_empty() and ResourceLoader.exists(path) else {}

func _use_background(row: Dictionary, resource: Dictionary, foreground: Array) -> void:
	row["background_path"] = str(resource.path)
	# 采用图自己的在场名单，不能保留母图原名单导致地图错误确认已被移到前景者。
	row["embedded_actor_refs"] = resource.get("embedded_actor_refs", []).duplicate()
	_remove_duplicates(row, foreground)

func _remove_duplicates(row: Dictionary, foreground: Array) -> void:
	row["embedded_actor_refs"] = row.get("embedded_actor_refs", []).filter(func(id): return id not in foreground)
	row["scene_layers"] = row.get("scene_layers", []).filter(func(layer): return layer.get("character_id", "") not in foreground)
