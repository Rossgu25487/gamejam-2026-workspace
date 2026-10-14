extends Node
## 会话接口组合核心与导航快照，主入口不拼装库存、容错或结果字段。

const CoreScript = preload("res://systems/core_gameplay/core_gameplay_service.gd")
const WorkbookLoader = preload("res://systems/core_gameplay/story_workbook_loader.gd")
const SceneInteractionScript = preload("res://systems/scene_interaction/scene_interaction_service.gd")
signal autosave_requested(snapshot: Dictionary)
var core: Node
var scene_interaction: Node

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
	return ok

func story_title() -> String:
	# 对外提供已解析的标题，Main无需了解Excel与旧JSON的文本引用差异。
	return core.catalog.text(core.catalog.data.get("package_title", "package_title"))

func start_new_game() -> Dictionary:
	core.start_new_game()
	if scene_interaction != null:
		scene_interaction.initialize(core.state.current_scene_id)
	return export_snapshot()

func export_snapshot() -> Dictionary:
	var card: Dictionary = core.export_card_state()
	return {"state_revision": card.revision, "content_revision": card.content_revision, "card_snapshot": card,
		"scene_interaction_snapshot": scene_interaction.export_snapshot() if scene_interaction != null else {},
		"navigation_snapshot": {"state_revision": card.revision, "page_id": card.mode, "current_scene_id": card.current_scene_id}}

func validate_snapshot(snapshot: Dictionary) -> bool:
	var card = snapshot.get("card_snapshot")
	var nav = snapshot.get("navigation_snapshot")
	if not card is Dictionary or not nav is Dictionary or not core.validate_card_state(card): return false
	var scene_snapshot: Dictionary = snapshot.get("scene_interaction_snapshot", {})
	if scene_interaction != null and not scene_snapshot.is_empty() and not scene_interaction.validate_snapshot(scene_snapshot): return false
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
	return true

func can_save() -> bool:
	return core.can_save() and (scene_interaction == null or scene_interaction.can_save())

func _on_autosave() -> void:
	if can_save(): autosave_requested.emit(export_snapshot())
