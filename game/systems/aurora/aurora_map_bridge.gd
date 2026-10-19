extends Node
## 旧地图表现的公开接口适配。地点资格与提交继续读取正式会话，不另建地图进度。
signal changed
var session: Node
var state := {"mode": "investigation", "current_scene_id": "SC01", "current_view_id": "", "confirmed_actor_locations": []}
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
	session.case_state.actor_location_confirmed.connect(refresh)
	refresh()

func refresh() -> void:
	# 地图只消费同一案件快照的已确认位置；绝不能从后台 npc_scene 补人物。
	state = {"mode": session.mode, "current_scene_id": session.case_state.data.scene,
		"current_view_id": session.case_state.data.get("view", ""),
		"confirmed_actor_locations": session.case_state.data.get("confirmed_actor_locations", []).duplicate(true)}
	paused = session.paused
	changed.emit()

func condition_met(id: String) -> bool:
	if id.begins_with("MAP_VIEW_DIFFERENT_"):
		var scene_id := id.trim_prefix("MAP_VIEW_DIFFERENT_")
		return str(state.current_scene_id) == scene_id and str(state.current_view_id) != str(session.config.scenes.get(scene_id, {}).get("default_view_id", ""))
	return session.scene_status(id.trim_prefix("MAP_KNOWN_")).known if id.begins_with("MAP_KNOWN_") else (session.scene_status(id.trim_prefix("MAP_OPEN_")).available if id.begins_with("MAP_OPEN_") else session.condition(id))

func can_save() -> bool: return session.can_save()
func prepare_departure(link: String) -> String:
	return session.prepare_departure(link.get_slice("->", 1))
func departure_status(target: String) -> String:
	if session.departure_ready_destination == target: return "ready"
	if session.requested_destination == target: return "waiting"
	return "cancelled"
func ui(id: String) -> String: return session.config.text(id)
func move_scene(link: String) -> bool:
	var target := link.get_slice("->", 1)
	if session.departure_ready_destination == target: return session.commit_prepared_departure(target)
	return session.travel(target)

func definition() -> Dictionary:
	var data: Dictionary = session.config.map_definition()
	var path := str(session.config.definition.root).path_join("design/map/runtime/map_runtime.json")
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		var runtime = JSON.parse_string(file.get_as_text()) if file != null else null
		if runtime is Dictionary and runtime.get("schema") == "map-spatial-v2":
			data = _spatial_definition(runtime)
	for from_id in session.config.scenes:
		for to_id in session.config.scenes:
			if from_id == to_id:
				if from_id == "SC01": data.transitions.append({"transition_id": "SC01->SC01", "from_scene": "SC01", "to_scene": "SC01", "condition": "MAP_OPEN_SC01", "reveal_condition": "MAP_VIEW_DIFFERENT_SC01", "order": 1})
				continue
			data.transitions.append({"transition_id": from_id + "->" + to_id, "from_scene": from_id, "to_scene": to_id,
				"condition": "MAP_OPEN_" + to_id, "reveal_condition": "MAP_KNOWN_" + to_id, "locked_reason": "当前还不能进入", "order": int(str(to_id).trim_prefix("SC"))})
	return data

func _spatial_definition(runtime: Dictionary) -> Dictionary:
	# 最终地图案明确规定使用此运行数据；统一成地图服务的字典接口，保留原始空间字段。
	var data := {"schema": "map-spatial-v2", "boards": {}, "transitions": [],
		"projection": runtime.projection.duplicate(true), "resources": runtime.resources.duplicate(true),
		"display": {}, "pawn": {"default": runtime.pawn.duplicate(true)},
		"actor_pieces": {}, "ui_texts": runtime.get("ui_texts", {}).duplicate(true)}
	for pair in [["groups", "groups", "group_id"], ["nodes", "nodes", "node_id"],
		["scenes", "scenes", "scene_id"], ["views", "map_views", "id"], ["layers", "layers", "id"],
		["waypoints", "waypoints", "id"], ["edges", "edges", "id"], ["view_points", "view_arrivals", "view_id"],
		["reachability", "scene_access_bindings", "id"]]:
		data[pair[0]] = {}
		for row in runtime.get(pair[1], []): data[pair[0]][str(row[pair[2]])] = row.duplicate(true)
	for key in runtime.get("display_params", {}): data.display[key] = {"value": runtime.display_params[key]}
	for row in runtime.get("actor_pieces", []): data.actor_pieces[str(row.actor_id)] = row.duplicate(true)
	for id in data.resources: data.resources[id].path = session.config.resource_path(str(data.resources[id].path))
	for scene in data.scenes.values():
		for field in ["scene_resource_ref", "default_focus_ref", "name_text_id", "display_name"]:
			if scene.get(field) == null: scene[field] = ""
	for id in data.views: data.boards[id] = {"spatial": true, "view_id": id}
	var ui_path := str(session.config.definition.root).path_join("design/map/ui_layout.json")
	if FileAccess.file_exists(ui_path):
		var ui_file := FileAccess.open(ui_path, FileAccess.READ)
		var ui_data = JSON.parse_string(ui_file.get_as_text()) if ui_file != null else null
		if ui_data is Dictionary: data["ui_layout"] = ui_data
	data["ui_assets"] = {}
	var manifest_path := str(session.config.definition.root).path_join("design/ui_20261018/adopted_assets.json")
	if FileAccess.file_exists(manifest_path):
		var manifest_file := FileAccess.open(manifest_path, FileAccess.READ)
		var manifest = JSON.parse_string(manifest_file.get_as_text()) if manifest_file != null else null
		if manifest is Dictionary:
			for item in manifest.get("assets", []): data.ui_assets[str(item.asset_id)] = session.config.resource_path(str(item.runtime_path))
	# 姓名沿当前已公开资料；地图资源只提供图像，不能公开真实人物名。
	for id in data.actor_pieces:
		data.actor_pieces[id]["public_name"] = _public_actor_name(id)
	return data

func _public_actor_name(actor_id: String) -> String:
	var profile_id := str(session.case_state.data.get("profiles", {}).get(actor_id, ""))
	var profile: Dictionary = session.config.profiles.get(profile_id, {})
	var label := str(profile.get("display_name", ""))
	if not label.is_empty(): return label
	return "已知位置"

func public_actor_label(actor_id: String) -> String:
	return _public_actor_name(actor_id)
