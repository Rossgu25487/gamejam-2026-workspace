extends Control
## 棋盘由行列和格宽生成，棋子只负责表现；经过的格子不触发调查。
var rows := 5
var cols := 8
var pawn_cell := Vector2.ZERO
var pawn_lift := 0.0
var pawn_alpha := 1.0
var pawn_visible := true
var cell_size := 50.0
var board_origin := Vector2(16, 16)
var nodes: Array = []
var selected_group := ""
var pawn_overlay: Control
var logical_cell_size := 100.0
var layout_definition := {}
var resource_definition := {}
var map_definition := {} # 完整地图定义，供跨层原地切换取 groups/boards
var group_definition := {}
var display_definition := {}
var pawn_definition := {}
var textures := {} # 绘制命令在帧末使用纹理，必须持有引用，避免临时加载后被回收成白块。
var confirmed_actors: Array = []
var display_scale := 1.0
var spatial_factor := 1.0
var spatial_origin := Vector2.ZERO
var spatial_crop := Rect2()

func configure_art(definition: Dictionary, group_id: String) -> void:
	map_definition = definition
	resource_definition = definition.get("resources", {})
	group_definition = definition.get("groups", {}).get(group_id, {})
	display_definition = definition.get("display", {})
	pawn_definition = definition.get("pawn", {}).get("default", {})
	textures.clear()

func setup(records: Array, layout: Dictionary, group_id: String) -> void:
	layout_definition = layout.duplicate(true)
	nodes = records
	selected_group = group_id
	rows = maxi(1, int(layout.get("rows", 5)))
	cols = maxi(1, int(layout.get("cols", 8)))
	logical_cell_size = float(layout.get("cell_size", 100))
	resized.connect(_layout_buttons)
	pawn_overlay = Control.new()
	pawn_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pawn_overlay.z_index = 10
	add_child(pawn_overlay)
	pawn_overlay.draw.connect(_draw_pawn)
	queue_redraw()

func switch_group(group_id: String) -> void:
	# 跨层切换原地换楼层背景与格子定义，不整页重建（反馈#21）。
	if group_id == selected_group: return
	var layout: Dictionary = map_definition.get("boards", {}).get(group_id, {})
	if layout.is_empty(): return # 目标层无棋盘定义，不切换（由页面走整页重建）
	selected_group = group_id
	group_definition = map_definition.get("groups", {}).get(group_id, {})
	layout_definition = layout
	rows = maxi(1, int(layout.get("rows", 5)))
	cols = maxi(1, int(layout.get("cols", 8)))
	logical_cell_size = float(layout.get("cell_size", 100))
	queue_redraw()

func cell_point(cell: Vector2) -> Vector2:
	if is_spatial(): return spatial_origin + (cell - spatial_crop.position) * spatial_factor
	return board_origin + (cell + Vector2(0.5, 0.5)) * cell_size

func _draw() -> void:
	_geometry()
	if is_spatial():
		_draw_spatial()
		if is_instance_valid(pawn_overlay): pawn_overlay.queue_redraw()
		return
	var board_image := _texture(str(group_definition.get("map_image_ref", "")))
	var logical_size := Vector2(_display("map_width", 960), _display("map_height", 640))
	var factor := minf(size.x / logical_size.x, size.y / logical_size.y)
	if board_image != null: draw_texture_rect(board_image, Rect2((size - logical_size * factor) / 2, logical_size * factor), false)
	var surface := _texture(str(layout_definition.get("grid_surface_ref", "")))
	var line := Color(str(layout_definition.get("grid_line_color", "#573F29")))
	line.a = float(layout_definition.get("grid_line_opacity", 1))
	for y in range(0 if layout_definition.get("grid_baked", false) else rows):
		for x in range(cols):
			var rect := Rect2(board_origin + Vector2(x, y) * cell_size, Vector2.ONE * cell_size)
			# 双色资源是两张相邻格面；逐格取对应半幅，不能把整图拉成两大片颜色。
			if surface != null:
				var half := Vector2(surface.get_width() / 2.0, surface.get_height())
				draw_texture_rect_region(surface, rect, Rect2(Vector2(half.x * ((x + y) % 2), 0), half))
			if surface == null and board_image == null: draw_rect(rect, Color("a9987c") if (x + y) % 2 == 0 else Color("64747b"))
			draw_rect(rect, line, false, maxf(0.5, float(layout_definition.get("grid_line_width", 1)) * cell_size / logical_cell_size))
	for record in nodes:
		var node: Dictionary = record.get("node", {})
		if str(node.get("group_id", "")) != selected_group: continue
		var building := _texture(str(node.get("building_ref", "")))
		if building == null: continue
		var dimensions := Vector2(_display("building_width", 192), _display("building_height", 128)) * cell_size / logical_cell_size
		var point := cell_point(Vector2(int(node.get("grid_col", 0)), int(node.get("grid_row", 0))))
		var factor_art := cell_size / logical_cell_size
		var ring := _texture(str(group_definition.get("current_ring_ref", "")))
		if record.get("current", false) and ring != null: draw_texture_rect(ring, Rect2(point - Vector2(50, 50) * factor_art, Vector2(100, 100) * factor_art), false)
		draw_texture_rect(building, Rect2(point - Vector2(dimensions.x / 2, dimensions.y), dimensions), false)
		var plate := _texture(str(group_definition.get("name_plate_ref", "")))
		if plate != null: draw_texture_rect(plate, Rect2(point + Vector2(-116, 26) * factor_art, Vector2(232, 66) * factor_art), false)
		var focus := _texture(str(group_definition.get("focus_frame_ref", "")))
		if record.get("selected", false) and focus != null: draw_texture_rect(focus, Rect2(point - Vector2(116, 123) * factor_art, Vector2(232, 246) * factor_art), false)
	if is_instance_valid(pawn_overlay): pawn_overlay.queue_redraw()

func _draw_pawn() -> void:
	if is_spatial():
		_draw_confirmed_actors()
		if not pawn_visible: return
		var point := cell_point(pawn_cell)
		var texture := _texture(str(pawn_definition.get("image_ref", "")))
		var shadow := _texture(str(pawn_definition.get("shadow_ref", "")))
		if shadow != null: pawn_overlay.draw_texture_rect(shadow, Rect2(point - Vector2(16, 4.5) * display_scale, Vector2(32, 9) * display_scale), false, Color(1, 1, 1, pawn_alpha))
		if texture != null:
			pawn_overlay.draw_texture_rect(texture, Rect2(point - Vector2(16, 41) * display_scale - Vector2(0, pawn_lift * display_scale), Vector2(32, 44) * display_scale), false, Color(1, 1, 1, pawn_alpha))
		else: pawn_overlay.draw_circle(point - Vector2(0, 12) * display_scale, 10 * display_scale, Color(0.9, 0.8, 0.6, pawn_alpha))
		return
	if pawn_visible:
		var point := cell_point(pawn_cell)
		draw_ellipse_shadow(point)
		var texture := _texture(str(pawn_definition.get("image_ref", "")))
		if texture != null:
			var dimensions := Vector2(_display("pawn_width", 64), _display("pawn_height", 88)) * cell_size / logical_cell_size
			var pivot := Vector2(float(pawn_definition.get("pivot_x", 32)), float(pawn_definition.get("pivot_y", 88))) * cell_size / logical_cell_size
			pawn_overlay.draw_texture_rect(texture, Rect2(point - pivot - Vector2(0, pawn_lift), dimensions), false, Color(1, 1, 1, pawn_alpha))
			return
		pawn_overlay.draw_circle(point + Vector2(0, -12 - pawn_lift), 10, Color(0.93, 0.86, 0.68, pawn_alpha))
		pawn_overlay.draw_rect(Rect2(point + Vector2(-9, -4 - pawn_lift), Vector2(18, 19)), Color(0.25, 0.20, 0.16, pawn_alpha))
		pawn_overlay.draw_line(point + Vector2(-13, 15 - pawn_lift), point + Vector2(13, 15 - pawn_lift), Color(0.93, 0.86, 0.68, pawn_alpha), 4)

func draw_ellipse_shadow(point: Vector2) -> void:
	var shadow := _texture(str(pawn_definition.get("shadow_ref", "")))
	if shadow != null:
		var factor := cell_size / logical_cell_size
		var pivot := Vector2(float(pawn_definition.get("shadow_pivot_x", 32)), float(pawn_definition.get("shadow_pivot_y", 9))) * factor
		pawn_overlay.draw_texture_rect(shadow, Rect2(point - pivot, Vector2(64, 18) * factor), false, Color(1, 1, 1, pawn_alpha))
		return
	pawn_overlay.draw_circle(point + Vector2(0, 14), 14, Color(0, 0, 0, 0.25 * pawn_alpha))

func _layout_buttons() -> void:
	queue_redraw()
	call_deferred("_place_buttons")

func _place_buttons() -> void:
	# 绘制与点击统一缩放，配置的跨格点击区保持同一矩形，不另写像素坐标。
	_geometry()
	for button in get_children():
		if not button is Button: continue
		if is_spatial():
			var points: PackedVector2Array = button.get_meta("source_polygon", PackedVector2Array())
			var polygon := PackedVector2Array()
			for point in points: polygon.append(cell_point(point))
			if polygon.size() < 3: continue
			var bounds := Rect2(polygon[0], Vector2.ZERO)
			for point in polygon: bounds = bounds.expand(point)
			button.custom_minimum_size = Vector2.ZERO
			button.position = bounds.position
			button.size = bounds.size
			var local_polygon := PackedVector2Array()
			for point in polygon: local_polygon.append(point - bounds.position)
			button.set("hit_polygon", local_polygon)
			continue
		var cell: Vector2 = button.get_meta("cell", Vector2.ZERO)
		var dimensions: Vector2 = button.get_meta("logical_hit_size", Vector2.ZERO)
		# 旧故事无图内触区尺寸时使用紧凑原生按钮；正式配置才按图内单位映射。
		button.custom_minimum_size = dimensions * cell_size / logical_cell_size if dimensions != Vector2.ZERO else Vector2(76, 48)
		button.size = button.custom_minimum_size
		button.position = cell_point(cell) - button.size / 2

func _geometry() -> void:
	if is_spatial():
		var view: Dictionary = map_definition.get("views", {}).get(selected_group, {})
		spatial_crop = Rect2(float(view.get("crop_left", 0)), float(view.get("crop_top", 0)), float(view.get("crop_width", 2400)), float(view.get("crop_height", 1800)))
		spatial_factor = minf(size.x / spatial_crop.size.x, size.y / spatial_crop.size.y)
		spatial_origin = (size - spatial_crop.size * spatial_factor) / 2
		return
	if layout_definition.has("grid_origin_x"):
		var logical_size := Vector2(_display("map_width", 960), _display("map_height", 640))
		var factor := minf(size.x / logical_size.x, size.y / logical_size.y)
		cell_size = logical_cell_size * factor
		board_origin = (size - logical_size * factor) / 2 + Vector2(float(layout_definition.grid_origin_x), float(layout_definition.get("grid_origin_y", 0))) * factor
	else:
		cell_size = minf(maxf(1.0, size.x - 32) / cols, maxf(1.0, size.y - 32) / rows)
		board_origin = (size - Vector2(cols, rows) * cell_size) / 2.0

func _display(key: String, fallback: float) -> float:
	return float(display_definition.get(key, {}).get("value", fallback))

func _texture(id: String) -> Texture2D:
	if textures.has(id): return textures[id]
	var path := str(resource_definition.get(id, {}).get("path", ""))
	var texture: Texture2D = load(path) as Texture2D if not path.is_empty() and ResourceLoader.exists(path) else null
	var row: Dictionary = resource_definition.get(id, {})
	if texture != null and float(row.get("region_width", 0)) > 0 and float(row.get("region_height", 0)) > 0:
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(float(row.get("region_x", 0)), float(row.get("region_y", 0)), float(row.region_width), float(row.region_height))
		texture = atlas
	textures[id] = texture
	return texture

func set_pawn(cell: Vector2, lift: float, alpha: float = 1.0) -> void:
	pawn_cell = cell
	pawn_lift = lift
	pawn_alpha = alpha
	queue_redraw()

func is_spatial() -> bool:
	return map_definition.get("schema") == "map-spatial-v2"

func _draw_spatial() -> void:
	var layers: Array = []
	for layer in map_definition.get("layers", {}).values():
		if str(layer.get("map_view_id", "")) == selected_group: layers.append(layer)
	layers.sort_custom(func(a, b): return int(a.get("display_order", 0)) < int(b.get("display_order", 0)))
	var destination := Rect2(spatial_origin, spatial_crop.size * spatial_factor)
	for layer in layers:
		var texture := _texture(str(layer.get("image_ref", "")))
		if texture != null: draw_texture_rect_region(texture, destination, spatial_crop)
	for record in nodes:
		var node: Dictionary = record.get("node", {})
		if selected_group != "overview" and str(node.get("group_id", "")) != selected_group: continue
		var source: Array = node.get("hit_polygon_px", [])
		var polygon := PackedVector2Array()
		for point in source: polygon.append(cell_point(Vector2(float(point[0]), float(point[1]))))
		if polygon.size() < 3: continue
		if record.get("selected", false): draw_colored_polygon(polygon, Color(0.88, 0.73, 0.35, 0.26))
		var closed := polygon.duplicate()
		closed.append(closed[0])
		draw_polyline(closed, Color("b19c72") if not record.get("current", false) else Color("4c8b6a"), 2 * display_scale, true)
		var anchor := cell_point(Vector2(float(node.get("label_anchor_x", 0)), float(node.get("label_anchor_y", 0))))
		var title := str(record.get("title", ""))
		var font := get_theme_default_font()
		var font_size := maxi(12, int(18 * display_scale))
		var text_size := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_style_box(_label_paper(), Rect2(anchor - Vector2(text_size.x / 2 + 6, text_size.y + 3), text_size + Vector2(12, 8)))
		draw_string(font, anchor - Vector2(text_size.x / 2, 5), title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("34413f"))

func _label_paper() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("eee7d3")
	style.border_color = Color("8d826b")
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	return style

func _draw_confirmed_actors() -> void:
	# 同地点按稳定 actor_id 顺序并排摆放；本方法只绘制，不写回位置。
	var counts := {}
	for actor in confirmed_actors:
		if selected_group != "overview" and str(actor.get("group_id", "")) != selected_group: continue
		var scene := str(actor.get("scene_id", ""))
		var offset := int(counts.get(scene, 0))
		counts[scene] = offset + 1
		var point := cell_point(actor.point) + Vector2(24 + 34 * offset, -8) * display_scale
		var texture := _texture(str(actor.get("image_ref", "")))
		if texture == null: continue
		pawn_overlay.draw_texture_rect(texture, Rect2(point - Vector2(16, 43) * display_scale, Vector2(32, 44) * display_scale), false)
