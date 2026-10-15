extends Node
## 会话接口组合核心与导航快照，主入口不拼装库存、容错或结果字段。

const CoreScript = preload("res://systems/core_gameplay/core_gameplay_service.gd")
const WorkbookLoader = preload("res://systems/core_gameplay/story_workbook_loader.gd")
const SceneInteractionScript = preload("res://systems/scene_interaction/scene_interaction_service.gd")
const NarrativeScript = preload("res://systems/narrative/narrative_service.gd")
const NarrativeWorkbookLoader = preload("res://systems/narrative/narrative_workbook_loader.gd")
const MapNavigationScript = preload("res://systems/map_navigation/map_navigation_service.gd")
const MapWorkbookLoader = preload("res://systems/map_navigation/map_workbook_loader.gd")
signal autosave_requested(snapshot: Dictionary)
var core: Node
var scene_interaction: Node
var narrative: Node
var map_navigation: Node

func initialize(path: String = WorkbookLoader.DEFAULT_PATH) -> bool:
	core = CoreScript.new()
	add_child(core)
	core.autosave_requested.connect(_on_autosave)
	var ok: bool = core.initialize(path)
	if ok:
		scene_interaction = SceneInteractionScript.new()
		add_child(scene_interaction)
		scene_interaction.bind_core(core)
		scene_interaction.initialize(core.catalog.data.initial_scene)
		narrative = NarrativeScript.new()
		add_child(narrative)
		map_navigation = MapNavigationScript.new()
		add_child(map_navigation)
		map_navigation.bind_core(core)
		map_navigation.initialize(core.catalog.data.initial_scene)
		var map_definition: Dictionary = _load_map_definition()
		var map_transitions: Array = []
		for id in core.catalog.data.get("scene_links", {}):
			var link: Dictionary = core.catalog.data.scene_links[id].duplicate(true)
			link["transition_id"] = id
			map_transitions.append(link)
		if map_definition.is_empty():
			map_definition = {"transitions": map_transitions}
		else:
			# 正式地图表只描述地图表现和资格；故事表仍是旧版本连接的兼容来源。
			var configured: Array = map_definition.get("transitions", [])
			if configured.is_empty(): map_definition["transitions"] = map_transitions
			for row in map_definition.get("transitions", []):
				if not row.has("transition_id") and row.has("link_id"): row["transition_id"] = row.link_id
		# 故事地点始终参与地图；独立策划表中的示例 ID 不能覆盖当前案件地点。
		# 同 ID 时保留地图坐标、背景等配置，并由故事提供实际显示名称。
		var map_scenes: Dictionary = map_definition.get("scenes", {}).duplicate(true)
		for scene_id in core.catalog.data.get("scenes", {}):
			var scene_definition: Dictionary = map_scenes.get(scene_id, {}).duplicate(true)
			scene_definition.merge(core.catalog.data.scenes[scene_id], true)
			map_scenes[scene_id] = scene_definition
		map_definition["scenes"] = map_scenes
		map_navigation.configure(map_definition)
	return ok

func _load_map_definition() -> Dictionary:
	# 地图配置读取独立于主调度；表缺失时保留旧故事连接，确保旧存档仍可打开。
	var loader := MapWorkbookLoader.new()
	var definition: Dictionary = loader.load_workbook()
	if definition.is_empty(): return {}
	return definition

func story_title() -> String:
	# 对外提供已解析的标题，Main无需了解Excel与旧JSON的文本引用差异。
	return core.catalog.text(core.catalog.data.get("package_title", "package_title"))

func start_new_game() -> Dictionary:
	core.start_new_game()
	if scene_interaction != null:
		scene_interaction.initialize(core.state.current_scene_id)
	if map_navigation != null:
		map_navigation.initialize(core.state.current_scene_id)
	if narrative != null:
		narrative.state = {}
	return export_snapshot()

func start_narrative(definition: Dictionary, start_text_id: String = "") -> bool:
	if narrative == null: return false
	if not narrative.initialize(definition):
		core.notice.emit("文案配置无效：" + str(narrative.catalog.errors))
		return false
	return narrative.start(start_text_id)

func start_narrative_from_workbook(path: String = NarrativeWorkbookLoader.DEFAULT_PATH, start_text_id: String = "") -> bool:
	# 文案配置的文件读取由文案服务负责；会话只转发启动请求，保持 Main 不感知表格格式。
	if narrative == null: return false
	if not narrative.initialize_from_workbook(path):
		core.notice.emit("文案配置无效")
		return false
	return narrative.start(start_text_id)

func export_snapshot() -> Dictionary:
	var card: Dictionary = core.export_card_state()
	return {"state_revision": card.revision, "content_revision": card.content_revision, "card_snapshot": card,
		"scene_interaction_snapshot": scene_interaction.export_snapshot() if scene_interaction != null else {},
		"map_navigation_snapshot": map_navigation.export_snapshot() if map_navigation != null else {},
		"narrative_snapshot": narrative.export_snapshot() if narrative != null and not narrative.state.is_empty() else {},
		"navigation_snapshot": {"state_revision": card.revision, "page_id": card.mode, "current_scene_id": card.current_scene_id}}

func validate_snapshot(snapshot: Dictionary) -> bool:
	var card = snapshot.get("card_snapshot")
	var nav = snapshot.get("navigation_snapshot")
	if not card is Dictionary or not nav is Dictionary or not core.validate_card_state(card): return false
	var scene_snapshot: Dictionary = snapshot.get("scene_interaction_snapshot", {})
	if scene_interaction != null and not scene_snapshot.is_empty() and not scene_interaction.validate_snapshot(scene_snapshot): return false
	var narrative_snapshot: Dictionary = snapshot.get("narrative_snapshot", {})
	if narrative != null and not narrative_snapshot.is_empty() and not narrative.validate_snapshot(narrative_snapshot): return false
	var map_snapshot: Dictionary = snapshot.get("map_navigation_snapshot", {})
	if map_navigation != null and not map_snapshot.is_empty() and not map_navigation.validate_snapshot(map_snapshot): return false
	return snapshot.get("content_revision") == card.content_revision and int(snapshot.get("state_revision", -1)) == int(card.revision) and int(nav.get("state_revision", -2)) == int(card.revision) and nav.get("page_id") == card.mode and nav.get("current_scene_id") == card.current_scene_id

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot):
		core.notice.emit("存档不包含完整玩法进度或内容版本不受支持；当前会话已保留。")
		return false
	if not core.restore_card_state(snapshot.card_snapshot): return false
	if scene_interaction != null:
		var scene_snapshot: Dictionary = snapshot.get("scene_interaction_snapshot", {})
		if scene_snapshot.is_empty(): scene_interaction.initialize(core.state.current_scene_id)
		elif not scene_interaction.restore_snapshot(scene_snapshot): return false
	if narrative != null:
		var narrative_snapshot: Dictionary = snapshot.get("narrative_snapshot", {})
		if narrative_snapshot.is_empty(): narrative.state = {}
		elif not narrative.restore_snapshot(narrative_snapshot): return false
	if map_navigation != null:
		var map_snapshot: Dictionary = snapshot.get("map_navigation_snapshot", {})
		if map_snapshot.is_empty(): map_navigation.initialize(core.state.current_scene_id)
		elif not map_navigation.restore_snapshot(map_snapshot): return false
	return true

func can_save() -> bool:
	return core.can_save() and (scene_interaction == null or scene_interaction.can_save()) and (narrative == null or narrative.can_save()) and (map_navigation == null or map_navigation.can_save())

func save_disabled_reason() -> String:
	# 原因与联合资格来自同一会话；不能用核心的可存状态掩盖文案、地图的禁存边界。
	if narrative != null and not narrative.can_save(): return core.ui("UI_SAVE_DISABLED_DIALOGUE")
	if map_navigation != null and not map_navigation.can_save(): return core.ui("UI_SAVE_DISABLED_READING")
	return core.save_disabled_reason()

func _on_autosave() -> void:
	if can_save(): autosave_requested.emit(export_snapshot())
