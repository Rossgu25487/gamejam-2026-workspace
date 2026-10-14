extends Node
## 会话接口组合核心与导航快照，主入口不拼装库存、容错或结果字段。

const CoreScript = preload("res://systems/core_gameplay/core_gameplay_service.gd")
const WorkbookLoader = preload("res://systems/core_gameplay/story_workbook_loader.gd")
const SceneInteractionScript = preload("res://systems/scene_interaction/scene_interaction_service.gd")
const NarrativeScript = preload("res://systems/narrative/narrative_service.gd")
const NarrativeWorkbookLoader = preload("res://systems/narrative/narrative_workbook_loader.gd")
const MapNavigationScript = preload("res://systems/map_navigation/map_navigation_service.gd")
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
		var map_transitions: Array = []
		for id in core.catalog.data.get("scene_links", {}):
			var link: Dictionary = core.catalog.data.scene_links[id].duplicate(true)
			link["transition_id"] = id
			map_transitions.append(link)
		map_navigation.configure({"transitions": map_transitions})
	return ok

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

func _on_autosave() -> void:
	if can_save(): autosave_requested.emit(export_snapshot())
