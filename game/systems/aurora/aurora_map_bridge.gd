extends Node
## 旧地图表现的公开接口适配。地点资格与提交继续读取正式会话，不另建地图进度。
signal changed
var session: Node
var state := {"mode": "investigation", "current_scene_id": "SC01"}
var processing := false
var presenting := false
var inspection_depth := 0
var paused := false
var catalog: RefCounted

class MapCatalog extends RefCounted:
	var data := {"scenes": {}}
	var config: RefCounted
	func text(id: String) -> String: return config.text(id)

func bind(value: Node) -> void:
	session = value
	catalog = MapCatalog.new()
	catalog.config = session.config
	catalog.data.scenes = session.config.scenes
	session.changed.connect(refresh)
	refresh()

func refresh() -> void:
	state = {"mode": session.mode, "current_scene_id": session.case_state.data.scene}
	paused = session.paused
	changed.emit()

func condition_met(id: String) -> bool:
	return session.scene_status(id.trim_prefix("MAP_KNOWN_")).known if id.begins_with("MAP_KNOWN_") else (session.scene_status(id.trim_prefix("MAP_OPEN_")).available if id.begins_with("MAP_OPEN_") else session.condition(id))

func can_save() -> bool: return session.can_save()
func ui(id: String) -> String: return session.config.text(id)
func move_scene(link: String) -> bool:
	var target := link.get_slice("->", 1)
	return session.travel(target)

func definition() -> Dictionary:
	var data: Dictionary = session.config.map_definition()
	for from_id in session.config.scenes:
		for to_id in session.config.scenes:
			if from_id == to_id: continue
			data.transitions.append({"transition_id": from_id + "->" + to_id, "from_scene": from_id, "to_scene": to_id,
				"condition": "MAP_OPEN_" + to_id, "reveal_condition": "MAP_KNOWN_" + to_id, "locked_reason": "当前还不能进入", "order": int(str(to_id).trim_prefix("SC"))})
	return data
