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

func setup(records: Array, layout: Dictionary, group_id: String) -> void:
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
	cell_size = minf(maxf(1.0, size.x - 32) / cols, maxf(1.0, size.y - 32) / rows)
	board_origin = (size - Vector2(cols, rows) * cell_size) / 2.0
	for y in range(rows):
		for x in range(cols):
			var rect := Rect2(board_origin + Vector2(x, y) * cell_size, Vector2.ONE * cell_size)
			draw_rect(rect, Color("a9987c") if (x + y) % 2 == 0 else Color("64747b"))
			draw_rect(rect, Color("573f29"), false, 1)
	if is_instance_valid(pawn_overlay): pawn_overlay.queue_redraw()

func _draw_pawn() -> void:
	if pawn_visible:
		var point := cell_point(pawn_cell)
		draw_ellipse_shadow(point)
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
	cell_size = minf(maxf(1.0, size.x - 32) / cols, maxf(1.0, size.y - 32) / rows)
	board_origin = (size - Vector2(cols, rows) * cell_size) / 2.0
	for button in get_children():
		if not button is Button: continue
		var cell: Vector2 = button.get_meta("cell", Vector2.ZERO)
		var dimensions: Vector2 = button.get_meta("logical_hit_size", Vector2.ZERO)
		# 旧故事无图内触区尺寸时使用紧凑原生按钮；正式配置才按图内单位映射。
		button.custom_minimum_size = dimensions * cell_size / logical_cell_size if dimensions != Vector2.ZERO else Vector2(76, 48)
		button.size = button.custom_minimum_size
		button.position = cell_point(cell) - button.size / 2

func set_pawn(cell: Vector2, lift: float, alpha: float = 1.0) -> void:
	pawn_cell = cell
	pawn_lift = lift
	pawn_alpha = alpha
	queue_redraw()
