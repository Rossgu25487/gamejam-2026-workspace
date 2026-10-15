extends Node
## 地图切换服务：维护地图页选择状态、可达地点和前往事务。
## 实际地点状态仍由核心玩法服务保存；本服务只负责地图页面的临时选择和切换调度。

signal changed
signal notice(message: String)
signal transition_started(from_scene: String, to_scene: String)
signal transition_completed(scene_id: String)
signal phase_changed(phase: String)

const SNAPSHOT_VERSION := 2
const PHASE_CLOSED := "closed"
const PHASE_BROWSING := "browsing"
const PHASE_PREPARING := "preparing"
const PHASE_MOVING := "moving"
const PHASE_ARRIVAL_HOLD := "arrival_hold"
const PHASE_TRANSITIONING := "transitioning"
const PHASE_FAILURE := "failure"
var core: Node
var state: Dictionary = {}
var transitions: Dictionary = {}
var locations: Dictionary = {}
var map_definition: Dictionary = {}
## 页面绑定后由页面驱动阶段动画；未绑定时保留旧版同步调用兼容性。
var visual_controller_bound := false

func bind_core(value: Node) -> void:
	core = value
	if core != null and not core.changed.is_connected(_on_core_changed): core.changed.connect(_on_core_changed)

func bind_visual_controller() -> void:
	visual_controller_bound = true

func configure(definition: Dictionary = {}) -> bool:
	map_definition = definition.duplicate(true)
	transitions.clear()
	locations.clear()
	for id in definition.get("locations", {}): locations[id] = definition.locations[id].duplicate(true)
	for id in definition.get("scenes", {}):
		locations[id] = definition.scenes[id].duplicate(true)
	for id in definition.get("nodes", {}):
		var node: Dictionary = definition.nodes[id].duplicate(true)
		var scene_id := str(node.get("scene_id", ""))
		if not scene_id.is_empty():
			if not locations.has(scene_id): locations[scene_id] = {}
			locations[scene_id]["node"] = node
	for row in definition.get("transitions", []):
		var id := str(row.get("transition_id", row.get("link_id", "")))
		if id.is_empty() or transitions.has(id): return false
		transitions[id] = row.duplicate(true)
	return true

func initialize(scene_id: String = "") -> void:
	state = {"snapshot_version": SNAPSHOT_VERSION, "current_scene_id": scene_id, "selected_scene_id": "", "selected_transition_id": "", "open": false, "phase": PHASE_CLOSED, "request_serial": 0, "active_request": {}, "failure_reason": "", "arrival_progress": 0.0, "pending_scene_id": ""}
	_changed()

func open() -> bool:
	if state.is_empty() or not can_open(): return false
	state.open = true
	state.phase = PHASE_BROWSING
	state.selected_scene_id = current_scene_id()
	state.selected_transition_id = ""
	_changed()
	return true

func preview_scene(scene_id: String) -> Dictionary:
	# 选择地点只更新预览，不改变核心地点；页面可用此接口显示背景、原因和节点信息。
	for item in location_records():
		if str(item.get("to_scene", "")) == scene_id:
			return item.duplicate(true)
	return {"scene_id": scene_id, "available": false, "reason": "该地点尚未公开"}

func scene_name(scene_id: String) -> String:
	var scene: Dictionary = locations.get(scene_id, {})
	if core != null:
		scene = core.catalog.data.get("scenes", {}).get(scene_id, scene)
		return core.catalog.text(str(scene.get("name", scene.get("name_text_id", scene_id))))
	return str(scene.get("name", scene.get("name_text_id", scene_id)))

func location_records() -> Array:
	# 节点和列表共用这一份运行时记录；只展示当前地点与已公开的出发连接。
	var current := current_scene_id()
	var result: Array = [{"transition_id": "", "to_scene": current, "title": scene_name(current),
		"available": false, "current": true, "selected": state.get("selected_scene_id", "") == current,
		"reason": "已在当前地点", "node": locations.get(current, {}).get("node", {})}]
	var seen := {current: true}
	for item in available_transitions():
		if seen.has(item.to_scene): continue
		seen[item.to_scene] = true
		item["current"] = false
		item["title"] = scene_name(str(item.to_scene))
		result.append(item)
	return result

func select_scene(scene_id: String) -> bool:
	if not state.get("open", false) or state.get("phase") not in [PHASE_BROWSING, PHASE_FAILURE]: return false
	for item in location_records():
		if str(item.to_scene) != scene_id: continue
		state.selected_scene_id = scene_id
		state.selected_transition_id = str(item.transition_id)
		state.failure_reason = ""
		state.phase = PHASE_BROWSING
		_changed()
		return true
	return false

func travel_disabled_reason() -> String:
	if state.get("phase") in [PHASE_PREPARING, PHASE_MOVING, PHASE_ARRIVAL_HOLD, PHASE_TRANSITIONING]: return "正在切换地点，请稍候"
	if not state.get("open", false): return "请先打开地图"
	if str(state.get("selected_transition_id", "")).is_empty():
		return "当前没有可前往的其他地点" if available_transitions().is_empty() else "请先选择其他地点"
	for item in available_transitions():
		if item.transition_id == state.selected_transition_id:
			return "" if item.available else str(item.reason)
	return "该地点已不可用，请重新选择"

func close() -> void:
	if state.get("phase", PHASE_CLOSED) in [PHASE_PREPARING, PHASE_MOVING, PHASE_ARRIVAL_HOLD, PHASE_TRANSITIONING]: return
	state.open = false
	state.phase = PHASE_CLOSED
	state.selected_scene_id = ""
	state.selected_transition_id = ""
	state.active_request = {}
	_changed()

func can_open() -> bool:
	return core != null and not core.state.is_empty() and core.state.mode == "investigation" and not core.processing and not core.presenting and core.inspection_depth == 0 and state.get("phase", PHASE_CLOSED) in [PHASE_CLOSED, PHASE_FAILURE]

func current_scene_id() -> String:
	return str(core.state.get("current_scene_id", state.get("current_scene_id", "")) if core != null else state.get("current_scene_id", ""))

func available_transitions() -> Array:
	var result: Array = []
	for id in transitions:
		var row: Dictionary = transitions[id]
		if str(row.get("from_scene", row.get("from_scene_id", ""))) != current_scene_id(): continue
		var to_scene := str(row.get("to_scene", row.get("to_scene_id", "")))
		var reveal_condition := str(row.get("reveal_condition", ""))
		if not reveal_condition.is_empty() and (core == null or not core.condition_met(reveal_condition)): continue
		var allowed := true
		if core != null and not str(row.get("condition", "")).is_empty(): allowed = core.condition_met(str(row.condition))
		var item := row.duplicate(true)
		item["transition_id"] = id
		item["to_scene"] = to_scene
		item["available"] = allowed
		item["reason"] = "" if allowed else str(row.get("locked_reason", "当前无法前往"))
		item["selected"] = str(state.get("selected_transition_id", "")) == id
		item["from_scene"] = current_scene_id()
		item["node"] = locations.get(to_scene, {}).get("node", {})
		item["scene"] = locations.get(to_scene, {})
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	return result

func select_transition(transition_id: String) -> bool:
	for item in available_transitions():
		if item.transition_id != transition_id: continue
		return select_scene(str(item.to_scene))
	return false

func travel() -> bool:
	var disabled_reason := travel_disabled_reason()
	if not disabled_reason.is_empty():
		notice.emit(disabled_reason)
		return false
	if core == null or not core.can_save():
		notice.emit("当前无法前往；请先结束当前操作")
		return false
	var id := str(state.selected_transition_id)
	var row: Dictionary = transitions.get(id, {})
	if row.is_empty(): return false
	var from_scene := current_scene_id()
	var to_scene := str(row.get("to_scene", row.get("to_scene_id", "")))
	if not _validate_prepare(row, from_scene, to_scene): return false
	var link_id := str(row.get("core_link_id", row.get("link_id", id)))
	state.request_serial = int(state.request_serial) + 1
	state.active_request = {"request_id":"map-%d" % state.request_serial, "transition_id":id, "from_scene":from_scene, "to_scene":to_scene, "link_id":link_id}
	state.phase = PHASE_PREPARING
	_changed()
	transition_started.emit(from_scene, to_scene)
	# 准备阶段只锁定请求；核心地点在移动表现完成后才提交，失败可完整回到原位。
	state.pending_scene_id = to_scene
	state.phase = PHASE_MOVING
	state.arrival_progress = 0.0
	_changed()
	if not visual_controller_bound:
		if finish_movement():
			begin_transition()
			finish_transition()
	return true

func finish_movement(success: bool = true) -> bool:
	if state.get("phase") not in [PHASE_MOVING, PHASE_PREPARING]: return false
	if not success:
		_fail("地点切换表现未完成，已返回原地点")
		return false
	var request: Dictionary = state.get("active_request", {})
	var link_id := str(request.get("link_id", ""))
	if core == null or link_id.is_empty() or not core.move_scene(link_id):
		_fail("当前无法前往该地点")
		return false
	state.current_scene_id = str(state.get("pending_scene_id", current_scene_id()))
	state.pending_scene_id = ""
	state.phase = PHASE_ARRIVAL_HOLD
	state.arrival_progress = 1.0
	_changed()
	return true

func finish_transition() -> bool:
	if state.get("phase") not in [PHASE_ARRIVAL_HOLD, PHASE_TRANSITIONING]: return false
	state.phase = PHASE_CLOSED
	state.open = false
	state.active_request = {}
	state.selected_transition_id = ""
	state.selected_scene_id = ""
	state.pending_scene_id = ""
	state.failure_reason = ""
	transition_completed.emit(state.current_scene_id)
	_changed()
	return true

func begin_transition() -> bool:
	if state.get("phase") != PHASE_ARRIVAL_HOLD: return false
	state.phase = PHASE_TRANSITIONING
	_changed()
	return true

func _validate_prepare(row: Dictionary, from_scene: String, to_scene: String) -> bool:
	if from_scene.is_empty() or to_scene.is_empty() or from_scene == to_scene:
		_fail("目标地点无效")
		return false
	if not locations.is_empty() and not locations.has(to_scene):
		_fail("目标地点尚未配置")
		return false
	if not str(row.get("condition", "")).is_empty() and not core.condition_met(str(row.condition)):
		_fail(str(row.get("locked_reason", "当前无法前往")))
		return false
	return true

func _fail(message: String) -> void:
	state.phase = PHASE_FAILURE
	state.failure_reason = message
	state.active_request = {}
	notice.emit(message)
	_changed()

func cancel() -> void:
	close()

func can_save() -> bool:
	return not state.get("open", false) and state.get("active_request", {}).is_empty() and state.get("phase", PHASE_CLOSED) in [PHASE_CLOSED, PHASE_FAILURE]

func export_snapshot() -> Dictionary:
	return {"snapshot_version": SNAPSHOT_VERSION, "state": state.duplicate(true)}

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or int(snapshot.get("snapshot_version", -1)) not in [1, SNAPSHOT_VERSION]: return false
	var incoming: Dictionary = snapshot.get("state", {})
	return incoming is Dictionary and incoming.has("current_scene_id") and incoming.has("open") and incoming.get("active_request", {}) is Dictionary and incoming.active_request.is_empty() and str(incoming.get("phase", PHASE_CLOSED)) in [PHASE_CLOSED, PHASE_BROWSING, PHASE_FAILURE]

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	state = snapshot.state.duplicate(true)
	state.snapshot_version = SNAPSHOT_VERSION
	state.open = false
	state.phase = PHASE_CLOSED
	state.selected_scene_id = ""
	state.selected_transition_id = ""
	state.pending_scene_id = ""
	_changed()
	return true

func _on_core_changed() -> void:
	if state.is_empty() or core == null: return
	state.current_scene_id = str(core.state.get("current_scene_id", state.current_scene_id))
	_changed()

func _changed() -> void:
	changed.emit()
	phase_changed.emit(str(state.get("phase", PHASE_CLOSED)))
