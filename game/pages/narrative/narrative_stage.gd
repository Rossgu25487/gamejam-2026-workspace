extends Control
## 舞台只消费明确的背景、位置与图片，制作说明不能当作动作执行。
var background: TextureRect
var occupants := {}
var scene_id := ""
var warnings: Array[String] = []

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
	for item in occupants.values(): item.node.queue_free()
	occupants.clear()
	scene_id = ""
	if background != null: background.texture = null

func apply_record(row: Dictionary, catalog: RefCounted) -> void:
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
	var position_key := str(row.get("position", ""))
	var position_index: int = {"左": 1, "中": 2, "右": 3, "left": 1, "center": 2, "right": 3, "1": 1, "2": 2, "3": 3}.get(position_key, 0)
	var kind := str(row.get("text_type", ""))
	var character_id := str(row.get("character_id", ""))
	if position_index > 0 and kind not in ["旁白", "画外对白", "narration", "offscreen"]:
		path = str(row.get("avatar_path", ""))
		texture = _texture(path)
		if not character_id.is_empty() and texture != null:
			for old_position in occupants.keys():
				if occupants[old_position].character_id == character_id and old_position != position_index: _remove_actor(old_position)
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
