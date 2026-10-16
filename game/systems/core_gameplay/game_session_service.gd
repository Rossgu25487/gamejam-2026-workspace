extends Node
## 会话接口组合核心与导航快照，主入口不拼装库存、容错或结果字段。

const CoreScript = preload("res://systems/core_gameplay/core_gameplay_service.gd")
const WorkbookLoader = preload("res://systems/core_gameplay/story_workbook_loader.gd")
const SceneInteractionScript = preload("res://systems/scene_interaction/scene_interaction_service.gd")
const SceneWorkbookLoader = preload("res://systems/scene_interaction/scene_workbook_loader.gd")
const NarrativeScript = preload("res://systems/narrative/narrative_service.gd")
const NarrativeWorkbookLoader = preload("res://systems/narrative/narrative_workbook_loader.gd")
const MapNavigationScript = preload("res://systems/map_navigation/map_navigation_service.gd")
const MapWorkbookLoader = preload("res://systems/map_navigation/map_workbook_loader.gd")
const CatScript = preload("res://features/cat_interaction/cat_service.gd")
const CatCatalogScript = preload("res://features/cat_interaction/cat_catalog.gd")
signal autosave_requested(snapshot: Dictionary)
signal cat_requested(definition: Dictionary)
signal media_requested(request: Dictionary)
signal node_media_stopped
signal narrative_soundscape_requested(bgm_key: String)
signal ending_configuration_required
signal investigation_entry_requested(entry_id: String)
var cat: RefCounted = CatScript.new()
var cat_catalog: RefCounted = CatCatalogScript.new()
var cat_serial := 0
var core: Node
var scene_interaction: Node
var narrative: Node
var map_navigation: Node
var seen_storage_path := "user://narrative_seen.json"
var elapsed_seconds: Variant = null # 旧档无此字段时保持未知，不虚构此前累计时间。
var activity_enabled := false
var window_focused := true
var file_processing := false
var clock_usec: Callable = Time.get_ticks_usec # 可注入单调时钟，回归不依赖等待误差。
var last_clock_usec := -1
var configuration: RefCounted
var pending_narrative_entry := ""
var narrative_entry_bindings := {}
var ending_pending := false

func initialize_profile(path: String) -> bool:
	configuration = preload("res://systems/config/package_configuration.gd").new()
	if not configuration.load_profile(path):
		core = CoreScript.new()
		add_child(core)
		core.catalog.errors.assign(configuration.errors)
		return false
	return initialize(configuration.workbook_path("story"))

func _update_clock() -> void:
	# 只在边界和取快照时结算单调时间，无需每帧轮询或累计帧delta。
	var now := int(clock_usec.call())
	if last_clock_usec >= 0 and elapsed_seconds != null and activity_enabled and window_focused and not file_processing:
		elapsed_seconds = float(elapsed_seconds) + maxf(0.0, (now - last_clock_usec) / 1000000.0)
	last_clock_usec = now

func set_activity_enabled(value: bool) -> void:
	_update_clock()
	activity_enabled = value

func set_window_focused(value: bool) -> void:
	_update_clock()
	window_focused = value

func set_file_processing(value: bool) -> void:
	_update_clock()
	file_processing = value

func initialize(path: String = WorkbookLoader.DEFAULT_PATH) -> bool:
	core = CoreScript.new()
	add_child(core)
	core.autosave_requested.connect(_on_autosave)
	var ok: bool = core.initialize(path, str(configuration.definition.root) if configuration != null else "")
	if ok and configuration != null: ok = configuration.apply_core(core.catalog)
	if ok:
		if configuration == null: cat_catalog.load_files()
		if configuration != null:
			var cat_tables := preload("res://features/cat_interaction/cat_workbook_loader.gd").new().load_workbook(configuration.workbook_path("cat"))
			cat_catalog.function_texts = core.catalog.function_texts.duplicate(true)
			for row in cat_tables.get("猫展示", []): row.visual_host_ref = configuration.resource_path(str(row.visual_host_ref))
			for row in cat_tables.get("动作绑定", []): row.visual_ref = configuration.resource_path(str(row.visual_ref))
			if not cat_catalog.configure(cat_tables): core.catalog.errors.append_array(cat_catalog.errors); return false
		cat.purr_requested.connect(_cat_purr)
		scene_interaction = SceneInteractionScript.new()
		add_child(scene_interaction)
		scene_interaction.bind_core(core)
		var investigation_loader := SceneWorkbookLoader.new()
		var investigation_definition: Dictionary = investigation_loader.load_workbook(configuration.workbook_path("investigation"), "test") if configuration != null else investigation_loader.load_workbook()
		if configuration != null:
			for row in investigation_definition.get("object_images", []): row.image_path = configuration.resource_path(str(row.image_path))
			for row in investigation_definition.get("observations", []): row["transfer"] = row.observation_ref in configuration.definition.get("transfer_observations", [])
		if configuration != null and investigation_definition.is_empty(): core.catalog.errors.append_array(investigation_loader.errors); return false
		if not investigation_definition.is_empty() and not scene_interaction.configure(investigation_definition): core.catalog.errors.append_array(scene_interaction.configuration_errors); return false
		scene_interaction.initialize(core.catalog.data.initial_scene)
		narrative = NarrativeScript.new()
		add_child(narrative)
		narrative.load_seen_registry(seen_storage_path)
		# 读档校验需要先有同一文案目录；仅载入，不播放或执行开场。
		if configuration != null:
			if not narrative.initialize(configuration.narrative_definition()): core.catalog.errors.append_array(narrative.catalog.errors); return false
			for row in configuration.rows("performance", "正文调用"):
				narrative_entry_bindings[str(row["普通交谈入口"])] = str(row["正文文本ID"]).split(";")[0]
			narrative.changed.connect(_narrative_changed, CONNECT_DEFERRED)
			narrative.text_started.connect(_narrative_text_started)
		elif FileAccess.file_exists(NarrativeWorkbookLoader.DEFAULT_PATH): narrative.initialize_from_workbook()
		map_navigation = MapNavigationScript.new()
		add_child(map_navigation)
		map_navigation.bind_core(core)
		map_navigation.media_requested.connect(func(request: Dictionary): media_requested.emit(request))
		map_navigation.initialize(core.catalog.data.initial_scene)
		var map_definition: Dictionary = _load_map_definition()
		if configuration != null and map_definition.is_empty(): return false
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
		if not map_navigation.configure(map_definition): core.catalog.errors.append_array(map_navigation.configuration_errors); return false
		if configuration != null and not configuration.errors.is_empty(): core.catalog.errors.append_array(configuration.errors); return false
	return ok

func _load_map_definition() -> Dictionary:
	# 地图配置读取独立于主调度；表缺失时保留旧故事连接，确保旧存档仍可打开。
	var loader := MapWorkbookLoader.new()
	var definition: Dictionary = loader.load_workbook(configuration.workbook_path("map")) if configuration != null else loader.load_workbook()
	if configuration != null:
		if definition.is_empty(): core.catalog.errors.append_array(loader.errors); return {}
		for id in definition.get("resources", {}):
			var row: Dictionary = definition.resources[id]
			row.path = configuration.resource_path(id if str(row.path).is_empty() else str(row.path))
	if definition.is_empty(): return {}
	return definition

func story_title() -> String:
	# 对外提供已解析的标题，Main无需了解Excel与旧JSON的文本引用差异。
	return core.catalog.text(core.catalog.data.get("package_title", "package_title"))

func start_new_game() -> Dictionary:
	_update_clock()
	elapsed_seconds = 0.0
	cat.restore_state({"first_seen": false})
	core.start_new_game()
	if scene_interaction != null:
		scene_interaction.initialize(core.state.current_scene_id)
	if map_navigation != null:
		map_navigation.initialize(core.state.current_scene_id)
	if narrative != null:
		narrative.state = {}
	pending_narrative_entry = ""
	ending_pending = false
	if configuration != null: narrative.start(str(configuration.definition.get("initial_text_id", "")))
	return export_snapshot()

func begin_opening() -> void:
	if configuration != null and narrative.state.is_empty(): narrative.start(str(configuration.definition.get("initial_text_id", "")))

func activate_entry(entry_id: String) -> bool:
	# 普通交谈先阅读，完整结束才原子提交材料与原话。物件检查仍走调查服务事务。
	if not narrative_entry_bindings.has(entry_id): return core.activate_entry(entry_id)
	if not can_save() or core.state.mode != "investigation" or not core.validate_entry_commit(entry_id): return false
	if not narrative.start(str(narrative_entry_bindings[entry_id])): return false
	pending_narrative_entry = entry_id
	return true

func route_entry(entry_id: String) -> bool:
	# 回顾前往物件只打开原检查入口，不绕过正文确认直接发材料或取走物件。
	if not core.validate_entry_commit(entry_id): return false
	if scene_interaction != null:
		for row in scene_interaction.hotspots.values():
			if row.get("inspect_entry_ref", "") == entry_id:
				investigation_entry_requested.emit(entry_id)
				return true
	return activate_entry(entry_id)

func _narrative_text_started(row: Dictionary) -> void:
	var scene: Dictionary = narrative.catalog.data.get("scenes", {}).get(str(row.get("scene_id", "")), {})
	narrative_soundscape_requested.emit(str(scene.get("bgm_key", "")))

func resume_narrative_audio() -> void:
	if narrative != null and not narrative.state.is_empty(): _narrative_text_started(narrative.current_record())

func _narrative_changed() -> void:
	if not narrative.state.get("finished", false): return
	var action := str(narrative.state.get("return_action", ""))
	if action == "commit_entry" and not pending_narrative_entry.is_empty():
		var id := pending_narrative_entry
		pending_narrative_entry = ""
		if core.activate_entry(id): core.finish_dialogue()
	elif action == "ending" and not ending_pending:
		ending_pending = true
		ending_configuration_required.emit()

func start_closing() -> bool:
	if configuration == null or ending_pending or core.state.mode != "investigation" or not can_save() or not core.condition_met(str(core.catalog.data.get("completion_condition", ""))): return false
	return narrative.start(str(configuration.definition.get("closing_text_id", "")))

func prepare_new_game() -> Dictionary:
	# 在破坏旧会话前验证明确的起始地点及必需场景引用；不执行任何取得或事件。
	var scene_id := str(core.catalog.data.get("initial_scene", ""))
	if not core.catalog.errors.is_empty() or not core.catalog.data.get("scenes", {}).has(scene_id): return {"ok": false, "reason": "初始调查内容无效，请修正配置后重试。"}
	return map_navigation.prepare_scene(scene_id)

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
	_update_clock()
	var card: Dictionary = core.export_card_state()
	# 摘要随同一完整档案冻结，浏览旧档不能用当前调查名称或当前时间替补。
	var question: Dictionary = core.catalog.data.questions.get(card.get("question_id", ""), {})
	var summary := {"scene": core.catalog.text(core.catalog.data.scenes.get(card.current_scene_id, {}).get("name", "")), "phase": "", "question": core.catalog.text(question.get("title", ""))}
	return {"state_revision": card.revision, "content_revision": card.content_revision, "elapsed_seconds": elapsed_seconds, "progress_summary": summary, "card_snapshot": card,
		"cat_snapshot": cat.export_state(),
		"scene_interaction_snapshot": scene_interaction.export_snapshot() if scene_interaction != null else {},
		"map_navigation_snapshot": map_navigation.export_snapshot() if map_navigation != null else {},
		"narrative_snapshot": narrative.export_snapshot() if narrative != null and not narrative.state.is_empty() else {},
		"navigation_snapshot": {"state_revision": card.revision, "page_id": card.mode, "current_scene_id": card.current_scene_id}}

func validate_snapshot(snapshot: Dictionary) -> bool:
	var duration = snapshot.get("elapsed_seconds")
	if duration != null and (not (duration is int or duration is float) or not is_finite(float(duration)) or duration < 0): return false
	var summary = snapshot.get("progress_summary", {})
	if not summary is Dictionary: return false
	for key in ["scene", "phase", "question"]:
		if summary.has(key) and not summary[key] is String: return false
	var card = snapshot.get("card_snapshot")
	var nav = snapshot.get("navigation_snapshot")
	if not card is Dictionary or not nav is Dictionary or not core.validate_card_state(card): return false
	# 先检查 Variant 类型再赋给模块；坏档不能在类型转换时抛错，更不能先替换核心。
	for key in ["scene_interaction_snapshot", "narrative_snapshot", "map_navigation_snapshot", "cat_snapshot"]:
		if not snapshot.get(key, {}) is Dictionary: return false
	if not cat.validate_state(snapshot.get("cat_snapshot", {"first_seen": false})): return false
	var scene_snapshot: Dictionary = snapshot.get("scene_interaction_snapshot", {})
	if scene_interaction != null and not scene_snapshot.is_empty() and not scene_interaction.validate_snapshot(scene_snapshot): return false
	if not scene_snapshot.is_empty() and scene_snapshot.state.current_scene_id != card.current_scene_id: return false
	var narrative_snapshot: Dictionary = snapshot.get("narrative_snapshot", {})
	if narrative != null and not narrative_snapshot.is_empty() and not narrative.validate_snapshot(narrative_snapshot): return false
	var map_snapshot: Dictionary = snapshot.get("map_navigation_snapshot", {})
	if map_navigation != null and not map_snapshot.is_empty() and not map_navigation.validate_snapshot(map_snapshot): return false
	if not map_snapshot.is_empty() and map_snapshot.state.current_scene_id != card.current_scene_id: return false
	return snapshot.get("content_revision") == card.content_revision and int(snapshot.get("state_revision", -1)) == int(card.revision) and int(nav.get("state_revision", -2)) == int(card.revision) and nav.get("page_id") == card.mode and nav.get("current_scene_id") == card.current_scene_id

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot):
		core.notice.emit("存档不包含完整玩法进度或内容版本不受支持；当前会话已保留。")
		return false
	# 读取只准备档案里的目标，不受当前会话的公开／可达状态约束。
	# 任一必需资源失败，尚未替换任何模块，旧会话及档案均保留。
	if map_navigation != null and not map_navigation.prepare_scene(str(snapshot.card_snapshot.current_scene_id)).ok:
		core.notice.emit("待读地点必需内容未就绪，当前会话已保留。")
		return false
	if not core.restore_card_state(snapshot.card_snapshot): return false
	pending_narrative_entry = ""
	ending_pending = false
	_update_clock()
	elapsed_seconds = snapshot.get("elapsed_seconds")
	cat.restore_state(snapshot.get("cat_snapshot", {"first_seen": false}))
	node_media_stopped.emit()
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
	if ending_pending: return false
	return not cat.is_active() and core.can_save() and (scene_interaction == null or scene_interaction.can_save()) and (narrative == null or narrative.can_save()) and (map_navigation == null or map_navigation.can_save())

func save_disabled_reason() -> String:
	if ending_pending: return "片尾可执行步骤待配置；当前边界不生成调查存档。"
	if cat.is_active(): return "返回调查后可以保存。"
	# 原因与联合资格来自同一会话；不能用核心的可存状态掩盖文案、地图的禁存边界。
	if narrative != null and not narrative.can_save(): return core.ui("UI_SAVE_DISABLED_DIALOGUE")
	if map_navigation != null and not map_navigation.can_save(): return core.ui("UI_SAVE_DISABLED_READING")
	return core.save_disabled_reason()

func _on_autosave() -> void:
	if can_save(): autosave_requested.emit(export_snapshot())

func cat_entries() -> Array:
	var entries: Array = []
	for id in cat_catalog.interactions:
		var row: Dictionary = cat_catalog.interaction(id)
		# 未绑定地点和对象的制作模板不在所有场景生成假入口。
		if str(row.get("scene_ref", "")).is_empty() or str(row.get("cat_object_ref", "")).is_empty() or row.scene_ref != core.state.current_scene_id: continue
		var resolved: Dictionary = cat_catalog.resolve(id)
		entries.append({"id": id, "enabled": resolved.ok, "reason": resolved.get("reason", ""), "title": cat_catalog.ui("CAT_ENTRY")})
	return entries

func enter_cat(id: String) -> bool:
	if not can_save() or core.paused or core.state.mode != "investigation": return false
	var row: Dictionary = cat_catalog.interaction(id)
	if row.is_empty() or row.get("scene_ref") != core.state.current_scene_id: return false
	var resolved: Dictionary = cat_catalog.resolve(id)
	if not resolved.ok:
		core.notice.emit(str(resolved.reason))
		return false
	cat_serial += 1
	if not cat.enter(resolved.interaction, resolved.view, resolved.actions): return false
	cat_requested.emit(resolved.duplicate(true))
	return true

func _cat_purr(sound_ref: String, gain: float) -> void:
	media_requested.emit({"event": "SND_NODE_SOUND", "instance": "cat/%s/%d" % [core.state.run_id, cat_serial], "ref": sound_ref, "gain": gain})

func finish_cat() -> void:
	cat.finish()
	node_media_stopped.emit()
