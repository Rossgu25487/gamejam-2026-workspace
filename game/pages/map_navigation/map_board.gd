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
var group_definition := {}
var display_definition := {}
var pawn_definition := {}
var textures := {} # 绘制命令在帧末使用纹理，必须持有引用，避免临时加载后被回收成白块。

func configure_art(definition: Dictionary, group_id: String) -> void:
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

func cell_point(cell: Vector2) -> Vector2:
	return board_origin + (cell + Vector2(0.5, 0.5)) * cell_size

func _draw() -> void:
	_geometry()
	var board_image := _texture(str(group_definition.get("map_image_ref", "")))
	var logical_size := Vector2(_display("map_width", 960), _display("map_height", 640))
	var factor := minf(size.x / logical_size.x, size.y / logical_size.y)
	if board_image != null: draw_texture_rect(board_image, Rect2((size - logical_size * factor) / 2, logical_size * factor), false)
	var surface := _texture(str(layout_definition.get("grid_surface_ref", "")))
	var line := Color(str(layout_definition.get("grid_line_color", "#573F29")))
	line.a = float(layout_definition.get("grid_line_opacity", 1))
	for y in range(rows):
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
		draw_texture_rect(building, Rect2(point - Vector2(dimensions.x / 2, dimensions.y), dimensions), false)
	if is_instance_valid(pawn_overlay): pawn_overlay.queue_redraw()

func _draw_pawn() -> void:
	if pawn_visible:
		var point := cell_point(pawn_cell)
		draw_ellipse_shadow(point)
		var texture := _texture(str(pawn_definition.get("image_ref", "")))
		if texture != null:
			var dimensions := Vector2(_display("pawn_width", 64), _display("pawn_height", 88)) * cell_size / logical_cell_size
			pawn_overlay.draw_texture_rect(texture, Rect2(point - Vector2(dimensions.x / 2, dimensions.y + pawn_lift), dimensions), false, Color(1, 1, 1, pawn_alpha))
			return
		pawn_overlay.draw_circle(point + Vector2(0, -12 - pawn_lift), 10, Color(0.93, 0.86, 0.68, pawn_alpha))
		pawn_overlay.draw_rect(Rect2(point + Vector2(-9, -4 - pawn_lift), Vector2(18, 19)), Color(0.25, 0.20, 0.16, pawn_alpha))
		pawn_overlay.draw_line(point + Vector2(-13, 15 - pawn_lift), point + Vector2(13, 15 - pawn_lift), Color(0.93, 0.86, 0.68, pawn_alpha), 4)

func draw_ellipse_shadow(point: Vector2) -> void:
	pawn_overlay.draw_circle(point + Vector2(0, 14), 14, Color(0, 0, 0, 0.25 * pawn_alpha))

func _layout_buttons() -> void:
	queue_redraw()
	call_deferred("_place_buttons")

func _place_buttons() -> void:
	# 绘制与点击统一缩放，配置的跨格点击区保持同一矩形，不另写像素坐标。
	_geometry()
	for button in get_children():
		if not button is Button: continue
		var cell: Vector2 = button.get_meta("cell", Vector2.ZERO)
		var dimensions: Vector2 = button.get_meta("logical_hit_size", Vector2.ZERO)
		# 旧故事无图内触区尺寸时使用紧凑原生按钮；正式配置才按图内单位映射。
		button.custom_minimum_size = dimensions * cell_size / logical_cell_size if dimensions != Vector2.ZERO else Vector2(76, 48)
		button.size = button.custom_minimum_size
		button.position = cell_point(cell) - button.size / 2

func _geometry() -> void:
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
	textures[id] = texture
	return texture

func set_pawn(cell: Vector2, lift: float, alpha: float = 1.0) -> void:
	pawn_cell = cell
	pawn_lift = lift
	pawn_alpha = alpha
	queue_redraw()
