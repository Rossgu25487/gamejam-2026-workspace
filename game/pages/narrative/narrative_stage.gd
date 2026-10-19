extends Control
## 舞台只消费明确的背景、位置与图片，制作说明不能当作动作执行。
var background: TextureRect
var occupants := {}
var scene_id := ""
var warnings: Array[String] = []
var movements: Array = []
var movement_time := 0.0
var movement_duration := 0.0
var departures: Array = []
var reduced := false
# 调用者地点的对话沿用调查画面的人物与物件图层；{node, rect, character_id}
var scene_layers: Array = []
var actor_layout: Dictionary = {}
var actor_assets: Dictionary = {}

func set_brightness(percent: int) -> void:
	var factor := clampf(float(percent) / 100.0, 0.5, 1.5)
	modulate = Color(factor, factor, factor, 1.0)

func configure_formal(config: RefCounted) -> void:
	actor_layout.clear()
	actor_assets.clear()
	var path: String = str(config.definition.root).path_join("02_文案/人物演出资源配置.json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary: return
	actor_layout = data
	for asset in data.get("assets", []):
		actor_assets[config.resource_path(str(asset.get("resource_path", "")))] = asset

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true # 近景按人体锚点放大后，膝下及透明留白由有效画面裁切。
	background = TextureRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	resized.connect(_layout)

func reset_stage() -> void:
	_clear_actors()
	_clear_scene_layers()
	scene_id = ""
	if background != null: background.texture = null

func _clear_actors() -> void:
	# 只清人物；背景和地点不动，供“清空人物位”这类片段起点使用。
	movements.clear()
	for item in departures:
		if is_instance_valid(item.node): item.node.queue_free()
	departures.clear()
	for item in occupants.values(): item.node.queue_free()
	occupants.clear()

func _clear_scene_layers() -> void:
	for item in scene_layers:
		if is_instance_valid(item.node): item.node.queue_free()
	scene_layers.clear()

func _apply_scene_layers(layers: Array) -> void:
	# 每条记录按调用方给出的当前图层重建；贴图缺失的图层直接跳过，不占用“站定人物”的位置。
	_clear_scene_layers()
	for layer in layers:
		var texture := _texture(str(layer.get("image_path", "")))
		if texture == null: continue
		var node := TextureRect.new()
		node.texture = texture
		node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		node.stretch_mode = TextureRect.STRETCH_SCALE
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.flip_h = bool(layer.get("flip_h", false))
		add_child(node)
		scene_layers.append({"node": node, "character_id": str(layer.get("character_id", "")),
			"rect": Rect2(float(layer.get("x", 0)), float(layer.get("y", 0)), float(layer.get("w", 0)), float(layer.get("h", 0)))})

func _layer_has_character(character_id: String) -> bool:
	if character_id.is_empty(): return false
	for item in scene_layers:
		if item.character_id == character_id: return true
	return false

func apply_record(row: Dictionary, catalog: RefCounted) -> void:
	# 正文切换前收束上一条动画，离场节点从槽位移走后单独管理到淡出结束。
	for item in departures:
		if is_instance_valid(item.node): item.node.queue_free()
	departures.clear()
	movement_duration = maxf(0, float(row.get("stage_duration_ms", 0)) / 1000.0)
	var previous := {}
	for item in occupants.values(): previous[item.character_id] = {"position": item.node.position, "alpha": item.node.modulate.a}
	var next_scene := str(row.get("scene_id", ""))
	var path := str(row.get("background_path", ""))
	if path.is_empty(): path = str(catalog.data.get("scenes", {}).get(next_scene, {}).get("background_path", ""))
	var texture := _texture(path)
	# 非空的必需背景缺失时保持当前舞台；不先清人物再报告失败。
	if not path.is_empty() and texture == null: return
	if row.get("clear_positions", false): _clear_actors()
	if not next_scene.is_empty() and next_scene != scene_id:
		reset_stage()
		scene_id = next_scene
	if not path.is_empty(): background.texture = texture
	_apply_scene_layers(row.get("scene_layers", []))
	for id in row.get("exit_characters", []):
		for slot in occupants.keys():
			if occupants[slot].character_id == id:
				if movement_duration > 0 and not reduced:
					departures.append({"node": occupants[slot].node, "alpha": occupants[slot].node.modulate.a})
					occupants.erase(slot)
				else: _remove_actor(slot)
	var position_key := str(row.get("position", ""))
	var conversation: Dictionary = row.get("conversation_actor", {})
	if not conversation.is_empty(): position_key = str(conversation.position)
	var position_index: int = {"左": 1, "中": 2, "右": 3, "left": 1, "center": 2, "right": 3, "1": 1, "2": 2, "3": 3}.get(position_key, 0)
	var kind := str(row.get("text_type", ""))
	var character_id := str(row.get("character_id", ""))
	var display_character := str(conversation.get("character_id", character_id))
	var inner := kind in ["内心", "inner"]
	path = str(row.get("avatar_path", ""))
	if not conversation.is_empty(): path = str(conversation.path)
	var asset: Dictionary = actor_assets.get(path, {})
	# 朝向以实际图片登记为准，文件名与表内站位不能把人物转向画面外。
	if not asset.is_empty() and position_index > 0:
		if asset.get("facing_direction") == "right": position_index = 1
		elif asset.get("facing_direction") == "left": position_index = 3
	# 人物已作为场景图层站在原处时，不再另起一个槽位立绘，否则点开对话人物会跳到别处。
	var anchored := _layer_has_character(display_character)
	if anchored:
		for slot in occupants.keys():
			if occupants[slot].character_id == character_id: _remove_actor(slot)
	# 心声仅有发言身份，不新建艾琳立绘；当前场景与已有会话人物保持。
	if position_index > 0 and not anchored and not inner and kind not in ["旁白", "画外对白", "narration", "offscreen", "offscreen_dialogue", "时间字幕", "章节字幕"]:
		path = str(conversation.get("path", row.get("avatar_path", "")))
		character_id = display_character
		texture = _texture(path)
		if not character_id.is_empty() and texture != null:
			for old_position in occupants.keys():
				if occupants[old_position].character_id == character_id and old_position != position_index:
					if occupants.has(position_index): _remove_actor(position_index)
					occupants[position_index] = occupants[old_position]
					occupants.erase(old_position)
			if occupants.has(position_index) and (occupants[position_index].character_id != character_id or occupants[position_index].path != path): _remove_actor(position_index)
			if not occupants.has(position_index):
				var actor := TextureRect.new()
				actor.texture = texture
				actor.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				actor.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				actor.mouse_filter = Control.MOUSE_FILTER_IGNORE
				actor.z_index = {1: 1, 3: 2, 2: 3}[position_index]
				add_child(actor)
				occupants[position_index] = {"character_id": character_id, "path": path, "node": actor}
	var speaking := not character_id.is_empty() and not inner and kind not in ["旁白", "画外对白", "narration", "offscreen", "offscreen_dialogue", "时间字幕", "章节字幕"]
	for item in occupants.values(): item.node.modulate = Color.WHITE if item.character_id == character_id and speaking else Color(0.88, 0.88, 0.88)
	# 场景里的人物只在“别人发言”时变暗，旁白和内心保持与调查画面一致的亮度。
	for item in scene_layers:
		var dimmed: bool = speaking and not item.character_id.is_empty() and item.character_id != character_id
		item.node.modulate = Color(0.88, 0.88, 0.88) if dimmed else Color.WHITE
	_layout()
	movements.clear()
	movement_time = 0
	if movement_duration > 0 and not reduced:
		for item in occupants.values():
			var from: Vector2 = previous.get(item.character_id, {}).get("position", item.node.position)
			var alpha := 1.0 if previous.has(item.character_id) else 0.0
			movements.append({"node": item.node, "from": from, "to": item.node.position, "alpha": alpha})
			item.node.position = from
			item.node.modulate.a = alpha

func _process(delta: float) -> void:
	if (movements.is_empty() and departures.is_empty()) or not is_visible_in_tree(): return
	var page := get_parent()
	if page.service != null and (page.service.hidden or page.service.reading_log): return
	movement_time += delta
	var amount := clampf(movement_time / maxf(0.001, movement_duration), 0, 1)
	for movement in movements:
		if not is_instance_valid(movement.node): continue
		movement.node.position = movement.from.lerp(movement.to, amount)
		movement.node.modulate.a = lerpf(float(movement.alpha), 1.0, amount)
	for departure in departures:
		if is_instance_valid(departure.node): departure.node.modulate.a = float(departure.alpha) * (1 - amount)
	if amount >= 1:
		movements.clear()
		for departure in departures:
			if is_instance_valid(departure.node): departure.node.queue_free()
		departures.clear()

func _remove_actor(position_index: int) -> void:
	occupants[position_index].node.queue_free()
	occupants.erase(position_index)

func _texture(path: String) -> Texture2D:
	if path.is_empty(): return null
	if ResourceLoader.exists(path):
		var resource = load(path)
		if resource is Texture2D: return resource
	if path not in warnings:
		warnings.append(path)
		push_warning("文案图片未就绪：" + path)
	return null

func _layout() -> void:
	var factor := minf(size.x / 1600.0, size.y / 900.0)
	var offset := (size - Vector2(1600, 900) * factor) / 2.0
	background.set_anchors_preset(Control.PRESET_TOP_LEFT)
	background.position = offset
	background.size = Vector2(1600, 900) * factor
	var rects := {1: Rect2(140, 130, 440, 770), 2: Rect2(570, 90, 460, 810), 3: Rect2(1020, 130, 440, 770)}
	var owner: Node = get_parent()
	var has_formal_record: bool = owner != null and owner.get("service") != null and owner.service.current_record().has("font_color")
	if has_formal_record:
		rects = {1: Rect2(80, 150, 480, 750), 2: Rect2(560, 150, 480, 750), 3: Rect2(1040, 150, 480, 750)}
	for item in scene_layers:
		var layer_rect: Rect2 = item.rect
		item.node.position = offset + layer_rect.position * factor
		item.node.size = layer_rect.size * factor
	for position_index in occupants:
		var node: TextureRect = occupants[position_index].node
		var asset: Dictionary = actor_assets.get(str(occupants[position_index].path), {})
		if not asset.is_empty():
			# 头顶与膝上切线用实际图内坐标，透明画布不参与人物身高计算。
			var anchor: Array = asset.get("dialogue_anchor_px", [])
			if anchor.size() == 2:
				var head := float(asset.get("visible_head_top_y_px", 0))
				var head_y := 900.0 * float(actor_layout.get("head_top_ratio", 250.0 / 900.0))
				var bottom_y := 900.0 * float(actor_layout.get("bottom_cut_ratio", 1))
				var image_scale := (bottom_y - head_y) / maxf(1, float(anchor[1]) - head)
				var slot_name: String = {1: "left", 2: "center", 3: "right"}[position_index]
				var center := 1600.0 * float(actor_layout.get("slot_center_x_ratio", {}).get(slot_name, float(position_index) * 0.3 - 0.1))
				node.size = node.texture.get_size() * image_scale * factor
				node.position = offset + Vector2(center - float(anchor[0]) * image_scale, head_y - head * image_scale) * factor
				continue
		var rect: Rect2 = rects[position_index]
		var texture_size := node.texture.get_size()
		var image_factor := minf(rect.size.x / texture_size.x, rect.size.y / texture_size.y)
		node.size = texture_size * image_factor * factor
		node.position = offset + Vector2(rect.get_center().x * factor - node.size.x / 2, rect.end.y * factor - node.size.y)
