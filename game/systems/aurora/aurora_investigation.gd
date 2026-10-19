extends RefCounted
## 调查规则只消费正式热区、图层与案件状态；一个热区只调用自己登记的入口。
var session: Node
var config: RefCounted
var presentation_catalog: Dictionary = {}
var interface_layout: Dictionary = {}
var actor_layout: Dictionary = {}

func bind(value: Node) -> void:
	session = value
	config = value.config
	presentation_catalog = _read_json("03_调查与场景交互/场景与交谈背景配置.json")
	interface_layout = _read_json("03_调查与场景交互/调查界面资源配置.json")
	actor_layout = _read_json("02_文案/人物演出资源配置.json")

func _read_json(relative: String) -> Dictionary:
	var path: String = str(config.definition.root).path_join(relative)
	if not FileAccess.file_exists(path): return {}
	var value = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}

func hotspots(view_id: String = "") -> Array:
	var result: Array = []
	var view := view_id if not view_id.is_empty() else str(session.case_state.data.view)
	var presentations := active_presentation_ids(view)
	for source in config.rows("investigation", "热点映射"):
		var row: Dictionary = source
		if str(source.get("hotspot_id", "")) == "HS_SC07_BEDROLL" and session.case_state.data.events.get("EV_CASE_INVESTIGATION_OPEN", false):
			# 对应现有可见行李卷的案后正文，不新增物件或图片。
			row = source.duplicate(true)
			row["required_condition_ref"] = "COND_EV_CASE_INVESTIGATION_OPEN"
			row["inspect_entry_ref"] = "ENTRY_CH02_WRENCH"
			row["detail_view_ref"] = "VIEW_E12_DETAIL"
		if str(source.get("inspect_entry_ref", "")) == "INV_SC02_REGISTER" and session.case_state.data.events.get("EV_CASE_INVESTIGATION_OPEN", false):
			row = source.duplicate(true)
			row["inspect_entry_ref"] = "ENTRY_CH02_REGISTER_READ"
		if str(row.scene_id) != str(session.case_state.data.scene) or str(row.view_id) != view: continue
		if not session.condition(str(row.get("required_condition_ref", ""))) or not object_present(row): continue
		if row.get("visible", true) == false: continue
		# 前景热区只由实际近景人物提供；空坐标不能变成左上角的伪按钮。
		if str(row.object_kind) == "foreground_character": continue
		var presentation := str(row.get("presentation_ref", ""))
		if not presentation.is_empty() and presentation not in presentations: continue
		if float(row.get("w", 0)) <= 0 or float(row.get("h", 0)) <= 0: continue
		var entry := str(row.get("inspect_entry_ref", ""))
		if not entry.is_empty() and not entry_available(entry): continue
		var bound: Dictionary = row
		# 大厅中隔门可见的尼娜只调用该机位父入口，不能借此近问厨房话题。
		if str(row.get("hotspot_id", "")) in ["HS_SC02_NINA_VISIBLE", "HS_SC02_NINA_VISIBLE_COUNTER"] and entry.is_empty():
			bound = row.duplicate(true)
			bound["inspect_entry_ref"] = "ENTRY_SC02_NINA_VISIBLE"
			if not entry_available(bound.inspect_entry_ref): continue
		result.append(bound)
	var last_sheet := _last_sheet_layer(view)
	if not last_sheet.is_empty() and entry_available("ENTRY_CH02_COUNTER_LAST_SHEET"):
		# 热区仅包住纸张本体，灰色摄影底和柜台不参与命中。
		result.append({"hotspot_id": "HS_SC02_LAST_SHEET_COUNTER", "scene_id": "SC02", "view_id": view,
			"object_ref": "OBJ_SC02_LAST_SHEET", "object_kind": "object", "public_name": "最后一联货单",
			"inspect_entry_ref": "ENTRY_CH02_COUNTER_LAST_SHEET", "topic_entry_ref": "", "detail_view_ref": "",
			"x": 640.0, "y": 298.0, "w": 322.0, "h": 466.0,
			"hit_polygon": [[640,298],[949,298],[962,311],[962,764],[649,764],[640,752]], "hit_priority": 80, "focus_order": 8})
	# 前景先命中，同层由优先级和稳定ID决定。页面使用同一个排序选择唯一目标。
	result.sort_custom(func(a, b):
		var az := hotspot_layer(a, view)
		var bz := hotspot_layer(b, view)
		if az != bz: return az > bz
		if int(a.get("hit_priority", 0)) != int(b.get("hit_priority", 0)): return int(a.get("hit_priority", 0)) > int(b.get("hit_priority", 0))
		return str(a.hotspot_id) < str(b.hotspot_id))
	return result

func _last_sheet_layer(view: String) -> Dictionary:
	if str(session.case_state.data.scene) != "SC02" or view != "VIEW_SC02_COUNTER" or not session.case_state.data.events.get("EV_CASE_INVESTIGATION_OPEN", false): return {}
	var content: Dictionary = config.contents.get("E06_V1", {})
	var path := str(content.get("image_ref", ""))
	if path.is_empty() or not ResourceLoader.exists(path): return {}
	return {"presentation_id": "E06_COUNTER_VISIBLE_CARD", "scene_id": "SC02", "view_id": view,
		"image_role": "object", "draw_layer": 90, "object_ref": "OBJ_SC02_LAST_SHEET", "image_path": path,
		"image_x": 620.0, "image_y": 260.0, "image_w": 360.0, "image_h": 540.0,
		"visible_caption": "最后一联货单", "caption_x": 657.0, "caption_y": 330.0, "caption_w": 284.0}

func conversation_candidates() -> Array:
	# 已采用“交谈视角”：仍要求人物实际在本地点且拥有本地点公开入口。
	# 世界调查不画近景；页面显式切换后才为真实 PNG 生成点击区域。
	var result: Array = []
	var scene := str(session.case_state.data.scene)
	var view := str(session.case_state.data.view)
	if view != str(config.scenes.get(scene, {}).get("default_view_id", "")): return result
	for row in config.rows("investigation", "热点映射"):
		if str(row.get("object_kind", "")) != "foreground_character" or str(row.get("scene_id", "")) != scene or str(row.get("view_id", "")) != view: continue
		var actor := str(row.get("object_ref", ""))
		var npc: Dictionary = session.case_state.data.npc.get(actor, {})
		if str(npc.get("scene_id", "")) != scene or npc.get("visible", true) == false or row.get("visible", true) == false or not object_present(row): continue
		if not session.condition(str(row.get("required_condition_ref", ""))): continue
		var entry := str(row.get("inspect_entry_ref", ""))
		var public_entry := not entry.is_empty() and entry_available(entry)
		var public_topics := not topics(str(row.get("topic_entry_ref", ""))).is_empty()
		var can_offer := false
		for binding in config.narrative_bindings("material_presentation_bindings"):
			if str(binding.get("actor_id", "")) == actor and str(binding.get("scene_id", "")) == scene and session.condition(str(binding.get("condition_ref", ""))): can_offer = true
		if not public_entry and not public_topics and not can_offer: continue
		for asset in actor_layout.get("assets", []):
			if str(asset.get("character_id", "")) != actor: continue
			var path: String = config.resource_path(str(asset.get("resource_path", "")))
			if path.is_empty() or not ResourceLoader.exists(path): continue
			var candidate: Dictionary = row.duplicate(true)
			if not public_entry: candidate["inspect_entry_ref"] = ""
			candidate["actor_asset"] = asset.duplicate(true)
			candidate["portrait_path"] = path
			result.append(candidate)
			break
	result.sort_custom(func(a, b): return str(a.object_ref) < str(b.object_ref))
	return result

func conversation_layers(actor: String) -> Array:
	# 复用交付的同机位去人图，避免人物同时出现在背景和近景。
	var layers := image_layers()
	var background := {}
	for layer in layers:
		if str(layer.get("image_role", "")) == "background" or int(layer.get("draw_layer", 0)) <= 0: background = layer
	for group in presentation_catalog.get("groups", []):
		if str(group.get("base_background_ref", "")) != str(background.get("presentation_id", "")): continue
		for pair in group.get("pairs", []):
			if pair.get("foreground_actor_refs", []) != [actor]: continue
			var replacement: Dictionary = background.duplicate(true)
			var path := ""
			var embedded: Array = []
			for resource in presentation_catalog.get("resources", []):
				if str(resource.get("id", "")) != str(pair.get("background_ref", "")): continue
				path = config.resource_path(str(resource.get("resource_path", "")))
				embedded = resource.get("embedded_actor_refs", []).duplicate()
				break
			if path.is_empty(): path = str(view_resource(str(pair.get("background_ref", ""))).get("resource_or_text_ref", ""))
			if not path.is_empty() and ResourceLoader.exists(path):
				replacement["image_path"] = path
				replacement["embedded_actor_refs"] = embedded
				layers.erase(background)
				layers.append(replacement)
	return layers.filter(func(layer): return str(layer.get("object_ref", "")) != actor and str(layer.get("actor_location_ref", "")) != actor)

func object_present(row: Dictionary) -> bool:
	var object_id := str(row.get("object_ref", ""))
	var object: Dictionary = session.case_state.data.objects.get(object_id, {})
	if object.get("visible", true) == false: return false
	var placed := str(object.get("scene_id", ""))
	return placed.is_empty() or placed == str(row.get("scene_id", session.case_state.data.scene))

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
		var done := str(config.entries[str(row.entry_ref)].get("completion_event_id", ""))
		if not done.is_empty() and session.case_state.data.events.get(done, false): continue
		result.append(row)
	result.sort_custom(func(a, b): return int(a.get("focus_order", 0)) < int(b.get("focus_order", 0)))
	return result

func observation_options(object_id: String) -> Array:
	# 只供状态和文案名称查询；禁止把同物的部位、阶段反馈变成调查菜单。
	var variants := {}
	for row in config.rows("investigation", "观察引用"):
		if row.object_ref != object_id or row.scene_id != session.case_state.data.scene or not session.condition(str(row.get("condition_ref", ""))): continue
		var key := str(row.observation_ref)
		if not variants.has(key) or not str(row.get("condition_ref", "")).is_empty(): variants[key] = row
	return variants.values()

func scene_options() -> Array:
	# 正式版通过可见实体直接点查，不再提供绕开热区资格的“检查物件”目录。
	return []

func inspect(row: Dictionary, caller: Dictionary = {}) -> bool:
	var context := caller.duplicate(true)
	context.merge({"kind": "topics" if str(row.object_kind) in ["character", "foreground_character", "embedded_character"] else "inspection",
		"scene": str(row.scene_id), "view": str(row.view_id), "object": str(row.object_ref), "hotspot": str(row.hotspot_id),
		"focus": str(row.hotspot_id), "topics": str(row.get("topic_entry_ref", ""))}, true)
	if context.get("conversation_view", false) and str(row.object_kind) == "foreground_character": context["focus"] = "ConversationActor_" + str(row.object_ref)
	var entry := str(row.get("inspect_entry_ref", ""))
	var detail := str(row.get("detail_view_ref", ""))
	# 开容器的反馈必须实际结束，页面收到完成回执后才切换局部。
	if not detail.is_empty():
		context["pending_detail"] = detail
		context["inspection_entry"] = entry
	if str(row.object_kind) == "cat": context["interaction"] = str(row.get("interaction_ref", ""))
	if not entry.is_empty():
		if not entry_available(entry): return false
		return session.activate_entry(entry, context)
	if not detail.is_empty() or str(row.object_kind) == "exit": return false
	var can_offer := false
	for binding in config.narrative_bindings("material_presentation_bindings"):
		if binding.get("actor_id") == row.object_ref and binding.get("scene_id") == session.case_state.data.scene and session.condition(str(binding.get("condition_ref", ""))): can_offer = true
	if context.kind == "topics" and (not topics(str(context.topics)).is_empty() or can_offer):
		session.return_context = context
		session.returned.emit(context)
		return true
	return false

func _matches_presentation(selection: Dictionary) -> bool:
	if selection.is_empty(): return true
	for terms in selection.get("any", []):
		var matched := true
		for term in terms:
			var actual := false
			match str(term.get("kind", "")):
				"chapter": actual = str(session.case_state.data.chapter) == str(term.ref)
				"event": actual = bool(session.case_state.data.events.get(str(term.ref), false))
				"npc_scene": actual = str(session.case_state.data.npc.get(str(term.ref), {}).get("scene_id", "")) == str(term.get("scene_id", ""))
				"condition": actual = session.condition(str(term.ref))
			if actual != bool(term.get("expected", true)): matched = false
		if matched: return true
	return false

func _catalog_background(view: String) -> Dictionary:
	var selected := ""
	for group in presentation_catalog.get("groups", []):
		if group.get("scene_id") != session.case_state.data.scene or group.get("view_id") != view: continue
		if group.get("selection_mode", "") == "temporary_text_cue": continue
		if _matches_presentation(group.get("selection_condition", {})): selected = str(group.get("base_background_ref", ""))
	for row in presentation_catalog.get("observation_only_backgrounds", []):
		if not _matches_presentation(row.get("selection_condition", {})): continue
		for resource in presentation_catalog.get("resources", []):
			if resource.get("id") == row.get("background_ref") and resource.get("scene_id") == session.case_state.data.scene and resource.get("view_id") == view:
				selected = str(resource.id)
	for resource in presentation_catalog.get("resources", []):
		if str(resource.id) != selected: continue
		var rect: Array = resource.get("display_rect_default_px", [0, 0, 1600, 900])
		return {"presentation_id": selected, "scene_id": session.case_state.data.scene, "view_id": view,
			"image_role": "background", "draw_layer": -100, "object_ref": "", "image_path": config.resource_path(str(resource.resource_path)),
			"image_x": rect[0], "image_y": rect[1], "image_w": rect[2], "image_h": rect[3], "embedded_actor_refs": resource.get("embedded_actor_refs", [])}
	return {}

func _layer_available(row: Dictionary) -> bool:
	var condition_id := str(row.get("required_condition_ref", ""))
	var condition_expected = row.get("condition_value", true)
	if not condition_id.is_empty() and session.condition(condition_id) != (condition_expected if condition_expected is bool else true): return false
	if not object_present(row): return false
	var context := str(row.get("entry_context_ref", ""))
	if not context.is_empty() and context != str(session.active_entry): return false
	var ref := str(row.get("state_ref", ""))
	if not ref.is_empty():
		var actual: bool = session.condition(ref) if config.conditions.has(ref) else bool(session.case_state.data.events.get(ref, false))
		if actual != bool(row.get("state_value", true)): return false
	var actor := str(row.get("actor_location_ref", ""))
	var object := str(row.get("object_location_ref", ""))
	var expected_scene := str(row.get("expected_scene_ref", ""))
	if not actor.is_empty() or not object.is_empty():
		var locations: Dictionary = session.case_state.data.npc if not actor.is_empty() else session.case_state.data.objects
		var matches := str(locations.get(actor if not actor.is_empty() else object, {}).get("scene_id", "")) == expected_scene
		var expected = row.get("location_matches", true)
		if matches != (expected if expected is bool else true): return false
	return true

func image_layers(view_id: String = "") -> Array:
	var result: Array = []
	var view := view_id if not view_id.is_empty() else str(session.case_state.data.view)
	var background := _catalog_background(view)
	var candidates: Array = []
	for row in config.rows("investigation", "对象图片"):
		if row.scene_id != session.case_state.data.scene or row.get("view_id") != view or not _layer_available(row): continue
		if row.get("image_role", "") == "background" or int(row.get("draw_layer", 0)) <= 0: candidates.append(row)
		else: result.append(row)
	if background.is_empty() and not candidates.is_empty(): background = candidates.back()
	var presentation := str(background.get("presentation_id", ""))
	result = result.filter(func(row): return str(row.get("scene_presentation_ref", "")).is_empty() or str(row.get("scene_presentation_ref", "")) == presentation)
	if not background.is_empty(): result.append(background)
	var last_sheet := _last_sheet_layer(view)
	if not last_sheet.is_empty(): result.append(last_sheet)
	result.sort_custom(func(a, b): return int(a.get("draw_layer", 0)) < int(b.get("draw_layer", 0)))
	return result

func active_presentation_ids(view: String) -> Array[String]:
	var result: Array[String] = []
	for row in image_layers(view):
		var id := str(row.get("presentation_id", ""))
		if not id.is_empty(): result.append(id)
	return result

func hotspot_layer(row: Dictionary, view: String = "") -> int:
	var layer := -100
	for image in image_layers(view):
		if str(image.get("object_ref", "")) == str(row.get("object_ref", "")): layer = maxi(layer, int(image.get("draw_layer", 0)))
	return layer

func hotspot_polygon(row: Dictionary) -> PackedVector2Array:
	var value = row.get("hit_polygon", "")
	if value is String: value = JSON.parse_string(value) if not value.is_empty() else []
	var polygon := PackedVector2Array()
	if value is Array:
		for point in value:
			if point is Array and point.size() >= 2: polygon.append(Vector2(float(point[0]), float(point[1])))
	return polygon

func contains_point(row: Dictionary, world_point: Vector2) -> bool:
	var rect := Rect2(float(row.x), float(row.y), float(row.w), float(row.h))
	if not rect.has_point(world_point): return false
	var polygon := hotspot_polygon(row)
	return polygon.size() < 3 or Geometry2D.is_point_in_polygon(world_point, polygon)

func observation_status(object_id: String) -> String:
	var options := observation_options(object_id)
	var seen := 0
	for row in options:
		if session.case_state.data.entries.get(str(row.entry_ref), false): seen += 1
	if seen == 0: return ""
	return "已查" if seen == options.size() else "可补查"

func view_resource(view_id: String) -> Dictionary:
	var fallback := {}
	for row in config.rows("investigation", "资源需求"):
		if row.get("view_id") != view_id or row.get("view_kind") not in ["fixed_view", "scene_background", "object_detail", "container_view"]: continue
		if str(row.get("id", "")) == view_id: return row
		if fallback.is_empty(): fallback = row
	return fallback

func view_transform(view_id: String, viewport_size: Vector2, offset: float = -1) -> Dictionary:
	var resource := view_resource(view_id)
	var content := Vector2(float(resource.get("content_width", 1600)), float(resource.get("content_height", 900)))
	if content.x <= 0 or content.y <= 0: content = Vector2(1600, 900)
	var pan: bool = resource.get("camera_mode", "fixed") == "pan"
	var scale_value := viewport_size.y / content.y if pan else minf(viewport_size.x / content.x, viewport_size.y / content.y)
	var max_offset := maxf(0, content.x - viewport_size.x / maxf(0.001, scale_value)) if pan else 0.0
	var initial := float(resource.get("initial_offset_x", 0))
	var constrained := clampf(initial if offset < 0 else offset, 0, max_offset)
	var origin := Vector2(-constrained * scale_value, 0) if pan else (viewport_size - content * scale_value) / 2
	if pan and max_offset == 0: origin.x = (viewport_size.x - content.x * scale_value) / 2
	return {"scale": scale_value, "origin": origin, "offset": constrained, "maximum": max_offset, "content": content}
