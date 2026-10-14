extends Node
## 地图切换服务：维护地图页选择状态、可达地点和前往事务。
## 实际地点状态仍由核心玩法服务保存；本服务只负责地图页面的临时选择和切换调度。

signal changed
signal notice(message: String)
signal transition_started(from_scene: String, to_scene: String)
signal transition_completed(scene_id: String)

const SNAPSHOT_VERSION := 1
var core: Node
var state: Dictionary = {}
var transitions: Dictionary = {}
var locations: Dictionary = {}

func bind_core(value: Node) -> void:
	core = value
	if core != null and not core.changed.is_connected(_on_core_changed): core.changed.connect(_on_core_changed)

func configure(definition: Dictionary = {}) -> bool:
	transitions.clear()
	locations.clear()
	for id in definition.get("locations", {}): locations[id] = definition.locations[id].duplicate(true)
	for row in definition.get("transitions", []):
		var id := str(row.get("transition_id", row.get("link_id", "")))
		if id.is_empty() or transitions.has(id): return false
		transitions[id] = row.duplicate(true)
	return true

func initialize(scene_id: String = "") -> void:
	state = {"snapshot_version": SNAPSHOT_VERSION, "current_scene_id": scene_id, "selected_scene_id": "", "selected_transition_id": "", "open": false, "request_serial": 0, "active_request": {}}
	_changed()

func open() -> bool:
	if state.is_empty() or not can_open(): return false
	state.open = true
	state.selected_scene_id = current_scene_id()
	state.selected_transition_id = ""
	_changed()
	return true

func close() -> void:
	state.open = false
	state.selected_scene_id = ""
	state.selected_transition_id = ""
	state.active_request = {}
	_changed()

func can_open() -> bool:
	return core != null and not core.state.is_empty() and core.state.mode == "investigation" and not core.processing and not core.presenting and core.inspection_depth == 0

func current_scene_id() -> String:
	return str(core.state.get("current_scene_id", state.get("current_scene_id", "")) if core != null else state.get("current_scene_id", ""))

func available_transitions() -> Array:
	var result: Array = []
	for id in transitions:
		var row: Dictionary = transitions[id]
		if str(row.get("from_scene", row.get("from_scene_id", ""))) != current_scene_id(): continue
		var to_scene := str(row.get("to_scene", row.get("to_scene_id", "")))
		var allowed := true
		if core != null and not str(row.get("condition", "")).is_empty(): allowed = core.condition_met(str(row.condition))
		var item := row.duplicate(true)
		item["transition_id"] = id
		item["to_scene"] = to_scene
		item["available"] = allowed
		item["reason"] = "" if allowed else str(row.get("locked_reason", "当前无法前往"))
		item["selected"] = str(state.get("selected_transition_id", "")) == id
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	return result

func select_transition(transition_id: String) -> bool:
	if not state.get("open", false): return false
	for item in available_transitions():
		if item.transition_id != transition_id: continue
		if not item.available:
			notice.emit(item.reason)
			return false
		state.selected_transition_id = transition_id
		state.selected_scene_id = item.to_scene
		_changed()
		return true
	return false

func travel() -> bool:
	if not state.get("open", false) or str(state.get("selected_transition_id", "")).is_empty():
		notice.emit("请先选择要前往的地点")
		return false
	if core == null or not core.can_save():
		notice.emit("当前无法前往；请先结束当前操作")
		return false
	var id := str(state.selected_transition_id)
	var row: Dictionary = transitions.get(id, {})
	if row.is_empty(): return false
	var from_scene := current_scene_id()
	var link_id := str(row.get("core_link_id", row.get("link_id", id)))
	state.request_serial = int(state.request_serial) + 1
	state.active_request = {"request_id":"map-%d" % state.request_serial, "transition_id":id, "from_scene":from_scene, "to_scene":str(row.to_scene)}
	transition_started.emit(from_scene, str(row.to_scene))
	if not core.move_scene(link_id):
		state.active_request = {}
		notice.emit("当前无法前往该地点")
		_changed()
		return false
	state.current_scene_id = str(row.to_scene)
	state.active_request = {}
	state.open = false
	state.selected_transition_id = ""
	state.selected_scene_id = ""
	transition_completed.emit(state.current_scene_id)
	_changed()
	return true

func cancel() -> void:
	close()

func can_save() -> bool:
	return not state.get("open", false) and state.get("active_request", {}).is_empty()

func export_snapshot() -> Dictionary:
	return {"snapshot_version": SNAPSHOT_VERSION, "state": state.duplicate(true)}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or int(snapshot.get("snapshot_version", -1)) != SNAPSHOT_VERSION: return false
	var incoming: Dictionary = snapshot.get("state", {})
	return incoming is Dictionary and incoming.has("current_scene_id") and incoming.has("open") and incoming.get("active_request", {}) is Dictionary and incoming.active_request.is_empty()

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	state = snapshot.state.duplicate(true)
	state.open = false
	state.selected_scene_id = ""
	state.selected_transition_id = ""
	_changed()
	return true

func _on_core_changed() -> void:
	if state.is_empty() or core == null: return
	state.current_scene_id = str(core.state.get("current_scene_id", state.current_scene_id))
	_changed()

func _changed() -> void:
	changed.emit()
