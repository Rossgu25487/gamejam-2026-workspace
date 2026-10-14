extends Node
## 调查与场景交互的唯一状态入口。
##
## 这个服务不创建页面控件，也不把检查正文塞进 Main。页面只提交
## hotspot/object/entry 引用，服务负责资格、重复请求锁、观察事务和快照。

signal changed
signal notice(message: String)

const SNAPSHOT_VERSION := 1
const DEFAULT_DISPLAY := {
	"canvas_width": 1600,
	"canvas_height": 900,
	"name_line_chars": 16,
	"hint_line_chars": 16,
	"hint_lines": 2,
	"topic_visible_rows": 5,
}

var core: Node
var display: Dictionary = DEFAULT_DISPLAY.duplicate(true)
var hotspots: Dictionary = {}
var observations: Dictionary = {}
var bindings: Dictionary = {}
var topics: Dictionary = {}
var object_images: Dictionary = {}
var state: Dictionary = {}

func bind_core(value: Node) -> void:
	core = value
	if core != null and not core.changed.is_connected(_on_core_changed): core.changed.connect(_on_core_changed)

func configure(definition: Dictionary = {}) -> bool:
	## 配置表导出后可直接映射到此结构；test 范围记录由调用方过滤。
	var errors: Array[String] = []
	display = DEFAULT_DISPLAY.duplicate(true)
	for key in DEFAULT_DISPLAY:
		if definition.get("display", {}).has(key): display[key] = int(definition.display[key])
	hotspots.clear(); observations.clear(); bindings.clear(); topics.clear(); object_images.clear()
	for row in definition.get("hotspots", []):
		if str(row.get("data_scope", "runtime")) != "runtime": continue
		var id := str(row.get("hotspot_id", ""))
		if id.is_empty() or hotspots.has(id): errors.append("热点ID重复或为空：" + id); continue
		var copy: Dictionary = row.duplicate(true)
		for field in ["x", "y", "w", "h", "hit_priority", "focus_order"]: copy[field] = int(copy.get(field, 0))
		if copy.w <= 0 or copy.h <= 0: errors.append("热点尺寸无效：" + id)
		hotspots[id] = copy
	for row in definition.get("observations", []):
		if str(row.get("data_scope", "runtime")) != "runtime": continue
		var id := str(row.get("observation_ref", ""))
		if id.is_empty() or observations.has(id): errors.append("观察ID重复或为空：" + id); continue
		observations[id] = row.duplicate(true)
	for row in definition.get("bindings", []):
		if str(row.get("data_scope", "runtime")) != "runtime": continue
		var id := str(row.get("id", ""))
		if id.is_empty() or bindings.has(id): errors.append("入口绑定ID重复或为空：" + id); continue
		bindings[id] = row.duplicate(true)
	for row in definition.get("topics", []):
		if str(row.get("data_scope", "runtime")) != "runtime": continue
		var id := str(row.get("topic_ref", ""))
		if id.is_empty() or topics.has(id): errors.append("话题ID重复或为空：" + id); continue
		topics[id] = row.duplicate(true)
	for row in definition.get("object_images", []):
		if str(row.get("data_scope", "runtime")) != "runtime": continue
		var object_ref := str(row.get("object_ref", ""))
		if object_ref.is_empty(): continue
		object_images[object_ref] = row.duplicate(true)
	return errors.is_empty()

func initialize(scene_id: String = "") -> void:
	state = {
		"snapshot_version": SNAPSHOT_VERSION,
		"current_scene_id": scene_id,
		"view_id": "",
		"focus_ref": "",
		"observations": {},
		"object_visibility": {},
		"object_interactive": {},
		"request_serial": 0,
		"active_request": {},
		"return_context": {},
		"topic_anchor": "",
	}
	if hotspots.is_empty(): _derive_story_hotspots()
	_changed()

func _derive_story_hotspots() -> void:
	## 旧故事表没有独立热点表时，仍按调查入口提供可运行的兼容热点。
	if core == null: return
	var index := 0
	for entry_id in core.catalog.data.get("entries", {}):
		var entry: Dictionary = core.catalog.data.entries[entry_id]
		var object_ref := str(entry.get("object_id", ""))
		if object_ref.is_empty(): object_ref = entry_id
		var hotspot_id := "story/%s" % entry_id
		var kind := "character" if core.catalog.data.get("characters", {}).has(object_ref) else "object"
		hotspots[hotspot_id] = {"hotspot_id": hotspot_id, "scene_id": str(entry.get("scene_id", "")),
			"object_ref": object_ref, "object_kind": kind, "x": 0, "y": index * 44,
			"w": 1, "h": 1, "hit_priority": 0, "focus_order": index,
			"inspect_entry_ref": entry_id if kind == "object" else "", "topic_entry_ref": entry_id if kind == "character" else "",
			"view_id": "story"}
		index += 1

func _on_core_changed() -> void:
	if state.is_empty(): return
	if core != null and not core.state.is_empty() and str(core.state.get("current_scene_id", "")) != str(state.get("current_scene_id", "")):
		state.current_scene_id = str(core.state.get("current_scene_id", ""))
		state.focus_ref = ""
	changed.emit()

func set_scene(scene_id: String, view_id: String = "") -> void:
	if state.is_empty(): initialize(scene_id)
	state.current_scene_id = scene_id
	state.view_id = view_id
	state.focus_ref = ""
	_changed()

func current_scene_id() -> String:
	return str(state.get("current_scene_id", core.state.get("current_scene_id", "") if core else ""))

func hotspots_for_scene(scene_id: String = "") -> Array:
	var result: Array = []
	var wanted := scene_id if not scene_id.is_empty() else current_scene_id()
	for id in hotspots:
		var row: Dictionary = hotspots[id]
		if not str(row.get("scene_id", "")).is_empty() and row.scene_id != wanted: continue
		var view := hotspot_state(id)
		if view.visible: result.append(view)
	result.sort_custom(func(a: Dictionary, b: Dictionary):
		if int(a.focus_order) != int(b.focus_order): return int(a.focus_order) < int(b.focus_order)
		return str(a.hotspot_id) < str(b.hotspot_id))
	return result

func hotspot_state(hotspot_id: String) -> Dictionary:
	if not hotspots.has(hotspot_id): return {}
	var row: Dictionary = hotspots[hotspot_id]
	if not str(row.get("scene_id", "")).is_empty() and str(row.get("scene_id", "")) != current_scene_id(): return {}
	var object_ref := str(row.get("object_ref", ""))
	var visible := bool(state.get("object_visibility", {}).get(object_ref, true))
	var interactive := bool(state.get("object_interactive", {}).get(object_ref, true))
	var reason := ""
	if not visible: interactive = false
	if not interactive: reason = "当前无法调查"
	var object_name := object_ref
	if core != null:
		if row.get("object_kind") == "character" and core.catalog.data.characters.has(object_ref): object_name = core.catalog.text(core.catalog.data.characters[object_ref].name)
		elif core.catalog.data.entries.has(row.get("inspect_entry_ref", "")): object_name = core.catalog.text(core.catalog.data.entries[row.inspect_entry_ref].title)
	var completed := completed_observation_for(object_ref)
	var status := "检查"
	if not completed.is_empty(): status = "已查"
	if available_new_observation(object_ref) != "": status = "可补查"
	return {"hotspot_id": hotspot_id, "scene_id": row.get("scene_id", ""), "object_ref": object_ref,
		"object_kind": row.get("object_kind", "object"), "public_name": object_name, "x": row.x, "y": row.y,
		"w": row.w, "h": row.h, "hit_priority": row.hit_priority, "focus_order": row.focus_order,
		"inspect_entry_ref": row.get("inspect_entry_ref", ""), "topic_entry_ref": row.get("topic_entry_ref", ""),
		"visible": visible, "interactive": interactive, "public_reason": reason, "status": status,
		"available_new_observation_ref": available_new_observation(object_ref)}

func begin_inspection(hotspot_id: String, return_context: Dictionary = {}) -> Dictionary:
	if state.is_empty() or not hotspots.has(hotspot_id): return _fail("调查对象不存在")
	if not state.active_request.is_empty(): return _fail("当前检查尚未结束")
	var item := hotspot_state(hotspot_id)
	if not item.visible or not item.interactive: return _fail(item.public_reason)
	var entry_ref := str(item.inspect_entry_ref)
	if entry_ref.is_empty(): return _fail("该对象没有检查入口")
	if core != null and (not core.catalog.data.entries.has(entry_ref) or not core.condition_met(core.catalog.data.entries[entry_ref].condition)):
		return _fail("当前无法调查")
	var observation_ref := _observation_for_entry(item.object_ref, entry_ref)
	state.request_serial = int(state.request_serial) + 1
	var request_id := "inspect-%d" % state.request_serial
	state.active_request = {"request_id": request_id, "hotspot_id": hotspot_id, "object_ref": item.object_ref,
		"entry_ref": entry_ref, "observation_ref": observation_ref}
	state.return_context = return_context.duplicate(true)
	_changed()
	return {"ok": true, "request_id": request_id, "hotspot": item, "observation_ref": observation_ref,
		"entry_ref": entry_ref, "return_context": state.return_context.duplicate(true)}

func commit_inspection(request_id: String, committed: bool = true) -> Dictionary:
	if state.active_request.is_empty() or request_id != state.active_request.request_id: return _fail("检查请求已失效")
	var request: Dictionary = state.active_request.duplicate(true)
	if not committed:
		state.active_request = {}; _changed()
		return {"ok": true, "committed": false, "return_action": "return", "request_id": request_id}
	var acquired: Array = []
	var record: Dictionary = {}
	if core != null and core.catalog.data.entries.has(request.entry_ref):
		var entry: Dictionary = core.catalog.data.entries[request.entry_ref]
		for content_id in entry.get("contents", []):
			if core.acquire_material(content_id, request.entry_ref, entry.source_id): acquired.append(core.catalog.material_ref(content_id))
		for statement_id in entry.get("statements", []): core.hear_statement(statement_id, request.entry_ref)
		for fact in entry.get("facts", []):
			if fact not in core.state.facts: core.state.facts.append(fact)
		if not entry.get("facts", []).is_empty(): core._changed()
	var completed: Array = []
	if not str(request.observation_ref).is_empty():
		record = observations.get(request.observation_ref, {}).duplicate(true)
		if record.is_empty(): record = {"observation_ref": request.observation_ref, "object_ref": request.object_ref, "entry_ref": request.entry_ref}
		record["object_ref"] = request.object_ref
		record["entry_ref"] = request.entry_ref
		record["committed"] = true
		state.observations[request.observation_ref] = record
		completed.append(request.observation_ref)
	state.active_request = {}
	_changed()
	return {"ok": true, "committed": true, "request_id": request_id, "completed_observation_refs": completed,
		"acquired_refs": acquired, "return_action": "transfer" if record.get("transfer", false) else "return",
		"return_context": state.return_context.duplicate(true)}

func cancel_inspection(request_id: String) -> bool:
	return bool(commit_inspection(request_id, false).get("ok", false))

func _observation_for_entry(object_ref: String, entry_ref: String) -> String:
	for id in observations:
		var row: Dictionary = observations[id]
		if row.get("object_ref", "") == object_ref and row.get("entry_ref", "") == entry_ref:
			if not state.observations.has(id): return id
	for id in observations:
		var row: Dictionary = observations[id]
		if row.get("object_ref", "") == object_ref and row.get("entry_ref", "") == entry_ref: return id
	return ""

func inspection_content(request_id: String) -> Dictionary:
	if state.active_request.get("request_id", "") != request_id: return {}
	var entry_ref := str(state.active_request.get("entry_ref", ""))
	if core == null or not core.catalog.data.entries.has(entry_ref): return {}
	var entry: Dictionary = core.catalog.data.entries[entry_ref]
	return {"entry_ref": entry_ref, "title": core.catalog.text(entry.get("title", "")), "body": core.catalog.text(entry.get("text", ""))}

func completed_observation_for(object_ref: String) -> String:
	for id in state.get("observations", {}):
		if observations.get(id, {}).get("object_ref", "") == object_ref or state.observations[id].get("object_ref", "") == object_ref: return id
	return ""

func available_new_observation(object_ref: String) -> String:
	if completed_observation_for(object_ref).is_empty(): return ""
	for id in observations:
		var row: Dictionary = observations[id]
		if row.get("object_ref", "") == object_ref and not state.observations.has(id):
			var previous := str(row.get("previous_observation_ref", ""))
			if not previous.is_empty() and state.observations.has(previous): return id
	return ""

func topics_for_person(person_ref: String) -> Array:
	var result: Array = []
	for id in topics:
		var row: Dictionary = topics[id]
		if row.get("person_ref", "") != person_ref: continue
		var item := row.duplicate(true)
		item["topic_ref"] = id
		item["interactive"] = bool(row.get("interactive", true))
		if item.interactive and str(item.get("entry_ref", "")).is_empty(): item.interactive = false
		if not item.interactive and str(item.get("public_reason", "")).is_empty(): item.public_reason = "当前无法回答"
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("focus_order", 0)) < int(b.get("focus_order", 0)))
	return result

func open_topic(topic_ref: String, return_context: Dictionary = {}) -> Dictionary:
	if not topics.has(topic_ref): return _fail("话题不存在")
	var item: Dictionary = topics[topic_ref]
	if not bool(item.get("interactive", true)) or str(item.get("entry_ref", "")).is_empty(): return _fail(str(item.get("public_reason", "当前无法回答")))
	state.return_context = return_context.duplicate(true)
	state.topic_anchor = topic_ref
	_changed()
	return {"ok": true, "topic_ref": topic_ref, "entry_ref": item.entry_ref, "return_context": state.return_context.duplicate(true)}

func set_object_state(object_ref: String, visible: bool, interactive: bool = true) -> void:
	state.object_visibility[object_ref] = visible
	state.object_interactive[object_ref] = interactive
	if not visible and state.focus_ref == object_ref: state.focus_ref = ""
	_changed()

func set_focus(ref: String) -> void:
	state.focus_ref = ref
	_changed()

func can_save() -> bool:
	return not state.is_empty() and state.active_request.is_empty()

func export_snapshot() -> Dictionary:
	return {"snapshot_version": SNAPSHOT_VERSION, "display": display.duplicate(true), "state": state.duplicate(true)}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or int(snapshot.get("snapshot_version", -1)) != SNAPSHOT_VERSION: return false
	var incoming: Dictionary = snapshot.get("state", {})
	if not incoming is Dictionary: return false
	for key in ["current_scene_id", "observations", "object_visibility", "object_interactive", "active_request", "return_context"]:
		if not incoming.has(key): return false
	return incoming.observations is Dictionary and incoming.active_request is Dictionary and incoming.active_request.is_empty()

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	state = snapshot.state.duplicate(true)
	display = snapshot.get("display", DEFAULT_DISPLAY).duplicate(true)
	_changed()
	return true

func _fail(message: String) -> Dictionary:
	notice.emit(message)
	return {"ok": false, "reason": message}

func _changed() -> void:
	changed.emit()
