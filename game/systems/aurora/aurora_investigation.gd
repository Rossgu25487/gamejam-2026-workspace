extends RefCounted
## 按实际案件状态筛选热点、观察差分、话题与图层，不复制第二份NPC或物件进度。
var session: Node
var config: RefCounted

func bind(value: Node) -> void:
	session = value
	config = value.config

func hotspots() -> Array:
	var result: Array = []
	for row in config.rows("investigation", "热点映射"):
		if row.scene_id != session.case_state.data.scene or row.view_id != session.case_state.data.view: continue
		if row.object_kind == "character" and str(row.hotspot_id) != "HS_SC02_NINA_VISIBLE" and session.case_state.data.npc.get(row.object_ref, {}).get("scene_id", "") != row.scene_id: continue
		if not object_present(row): continue
		var entry := str(row.get("inspect_entry_ref", ""))
		if not entry.is_empty() and not entry_available(entry):
			# 同一观察对象在阶段改变后可有不同入口；按观察表筛选，不展示不可达按钮。
			if observation_options(str(row.object_ref)).is_empty() and topics(str(row.get("topic_entry_ref", ""))).is_empty(): continue
		result.append(row)
	result.sort_custom(func(a, b): return int(a.hit_priority) < int(b.hit_priority))
	return result

func object_present(row: Dictionary) -> bool:
	var object := str(row.object_ref)
	if object == "OBJ_SC10_BAG":
		var moved: bool = session.case_state.data.events.get("EV_BAG_MOVED_TO_ARCHIVE", false)
		if str(row.scene_id) == "SC04" and not moved: return false
		if str(row.scene_id) == "SC10" and moved: return false
	if object == "OBJ_SC10_NOTEBOOK":
		var scene := str(session.case_state.data.objects.get(object, {}).get("scene_id", ""))
		if not scene.is_empty() and scene != str(row.scene_id): return false
	return true

func entry_available(id: String) -> bool:
	var row: Dictionary = config.entries.get(id, {})
	if row.is_empty() or not session._entry_condition(row): return false
	var scenes: Array[String] = config.ids(str(row.get("allowed_scene_ids", "")))
	return row.get("location_mode") == "fixed" or scenes.is_empty() or str(session.case_state.data.scene) in scenes

func topics(list_id: String) -> Array:
	var result: Array = []
	if list_id.is_empty(): return result
	for row in config.rows("investigation", "话题显示"):
		if row.list_entry_ref != list_id or not session.condition(str(row.get("condition_ref", ""))): continue
		if not entry_available(str(row.entry_ref)): continue
		# 完成事件与可用条件负责同一话题的差分；不把所有入口目录自动公开。
		var entry: Dictionary = config.entries[str(row.entry_ref)]
		var done := str(entry.get("completion_event_id", ""))
		if not done.is_empty() and session.case_state.data.events.get(done, false): continue
		result.append(row)
	result.sort_custom(func(a, b): return int(a.get("focus_order", 0)) < int(b.get("focus_order", 0)))
	return result

func observation_options(object_id: String) -> Array:
	var variants := {}
	for row in config.rows("investigation", "观察引用"):
		if row.object_ref != object_id or row.scene_id != session.case_state.data.scene or not session.condition(str(row.get("condition_ref", ""))): continue
		var key := str(row.observation_ref)
		# 条件版本覆盖同一观察的默认反馈，不把各个知识版排成多段过场。
		if not variants.has(key) or not str(row.get("condition_ref", "")).is_empty(): variants[key] = row
	return variants.values()

func scene_options() -> Array:
	# 表中只有scene_id而未分配独立触区的原件，仍可从场景检查目录进入。
	var result: Array = []
	var objects := {}
	for row in config.rows("investigation", "观察引用"):
		if row.scene_id == session.case_state.data.scene: objects[str(row.object_ref)] = true
	for object in objects:
		for row in observation_options(object):
			if entry_available(str(row.entry_ref)): result.append(row)
	return result

func inspect(row: Dictionary) -> bool:
	var context := {"kind": "topics" if row.object_kind == "character" else "inspection", "scene": row.scene_id,
		"view": row.view_id, "object": row.object_ref, "hotspot": row.hotspot_id, "topics": row.get("topic_entry_ref", ""), "detail": row.get("detail_view_ref", "")}
	var entry := str(row.get("inspect_entry_ref", ""))
	# 并列观察先列菜单，逐项正文结束后仍回同一检查上下文。
	var options := observation_options(str(row.object_ref))
	if row.object_kind != "character" and options.size() > 1:
		session.return_context = context
		session.returned.emit(context)
		return true
	if not entry.is_empty() and entry_available(entry): return session.activate_entry(entry, context)
	if options.size() == 1: return session.activate_entry(str(options[0].entry_ref), context)
	session.return_context = context
	session.returned.emit(context)
	return true

func image_layers(view_id: String = "") -> Array:
	var result: Array = []
	var state: Dictionary = session.case_state.data
	var view := view_id if not view_id.is_empty() else str(state.view)
	for row in config.rows("investigation", "对象图片"):
		if row.scene_id != state.scene or row.get("view_id") != view: continue
		if not session.condition(str(row.get("required_condition_ref", ""))): continue
		var ref := str(row.get("state_ref", ""))
		var expected_scene := str(row.get("expected_scene_ref", ""))
		if not expected_scene.is_empty():
			var present: bool = state.npc.get(ref, {}).get("scene_id", "") == expected_scene
			var expected = row.get("state_value", true)
			if present != (expected if expected is bool else true): continue
		if expected_scene.is_empty() and not ref.is_empty() and state.events.get(ref, false) != row.get("state_value", true): continue
		if not object_present(row): continue
		result.append(row)
	result.sort_custom(func(a, b): return int(a.get("draw_layer", 0)) < int(b.get("draw_layer", 0)))
	return result

func observation_status(object_id: String) -> String:
	var options := observation_options(object_id)
	var seen := 0
	for row in options:
		if session.case_state.data.entries.get(str(row.entry_ref), false): seen += 1
	if seen == 0: return ""
	return "已查" if seen == options.size() else "可补查"

func view_resource(view_id: String) -> Dictionary:
	# 同一视图还可登记脸额、伤口等附图；底图只取明确的视图资源，不能逐行覆盖。
	for row in config.rows("investigation", "资源需求"):
		if row.get("view_id") == view_id and row.get("view_kind") in ["fixed_view", "scene_background", "object_detail"]:
			return row
	return {}
