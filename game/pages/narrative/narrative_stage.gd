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

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	background = TextureRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	resized.connect(_layout)

func reset_stage() -> void:
	movements.clear()
	for item in departures:
		if is_instance_valid(item.node): item.node.queue_free()
	departures.clear()
	for item in occupants.values(): item.node.queue_free()
	occupants.clear()
	scene_id = ""
	if background != null: background.texture = null

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
	if not next_scene.is_empty() and next_scene != scene_id:
		reset_stage()
		scene_id = next_scene
	if not path.is_empty(): background.texture = texture
	for id in row.get("exit_characters", []):
		for slot in occupants.keys():
			if occupants[slot].character_id == id:
				if movement_duration > 0 and not reduced:
					departures.append({"node": occupants[slot].node, "alpha": occupants[slot].node.modulate.a})
					occupants.erase(slot)
				else: _remove_actor(slot)
	var position_key := str(row.get("position", ""))
	var position_index: int = {"左": 1, "中": 2, "右": 3, "left": 1, "center": 2, "right": 3, "1": 1, "2": 2, "3": 3}.get(position_key, 0)
	var kind := str(row.get("text_type", ""))
	var character_id := str(row.get("character_id", ""))
	if position_index > 0 and kind not in ["旁白", "画外对白", "narration", "offscreen"]:
		path = str(row.get("avatar_path", ""))
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
	for item in occupants.values(): item.node.modulate = Color.WHITE if item.character_id == character_id and kind not in ["旁白", "画外对白", "narration", "offscreen"] else Color(0.88, 0.88, 0.88)
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
	for position_index in occupants:
		var node: TextureRect = occupants[position_index].node
		var rect: Rect2 = rects[position_index]
		var texture_size := node.texture.get_size()
		var image_factor := minf(rect.size.x / texture_size.x, rect.size.y / texture_size.y)
		node.size = texture_size * image_factor * factor
		node.position = offset + Vector2(rect.get_center().x * factor - node.size.x / 2, rect.end.y * factor - node.size.y)
