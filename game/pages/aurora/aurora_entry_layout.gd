extends RefCounted
## 基础入口页面的纯布局数据；状态、存档资格和页面切换仍由各页面负责。
var records: Array = []
var theme: Theme
var config: RefCounted

func bind(value: RefCounted) -> void:
	config = value
	var path := str(config.definition.root).path_join("design/basic/ui_layout/entry/ui_layout.json")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary: records = data.get("records", [])
	theme = preload("res://pages/aurora/aurora_paper_theme.gd").build(config)

func ratio_for(logical_width: float) -> int:
	var selected := 1
	var best := INF
	for pair in [[1, 1600], [2, 1440], [3, 1200], [4, 2100]]:
		var distance := absf(logical_width - float(pair[1]))
		if distance < best: best = distance; selected = int(pair[0])
	return selected

func row_for(id: String, state: String, ratio: int) -> Dictionary:
	for row in records:
		if str(row.get("control_id", "")) == id and str(row.get("state_id", "")) == state and int(row.get("aspect_ratio", 0)) == ratio: return row
	return {}

func place(control: Control, row: Dictionary, canvas_size: Vector2) -> void:
	if row.is_empty(): return
	var index := clampi(int(row.get("anchor", 1)) - 1, 0, 8)
	var alignment := Vector2(float(index % 3) / 2.0, float(index / 3) / 2.0)
	var dimensions := Vector2(float(row.width), float(row.height))
	control.custom_minimum_size = Vector2.ZERO
	control.position = canvas_size * alignment + Vector2(float(row.offset_x), float(row.offset_y)) - dimensions * alignment
	control.size = dimensions
	if control is Label: control.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func panel(parent: Control) -> Panel:
	var result := Panel.new()
	result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(result)
	return result

func button_style(button: Button, primary := false) -> void:
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 24)
	var family := "primary" if primary else "secondary"
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var asset_state: String = state
		var path: String = config.resource_path("res://assets/aurora/ui/art7/paper_v2/controls/button_%s_%s.png" % [family, asset_state])
		if state == "hover_pressed" and not ResourceLoader.exists(path):
			path = config.resource_path("res://assets/aurora/ui/art7/paper_v2/controls/button_%s_pressed.png" % family)
		var skin := StyleBoxTexture.new()
		if ResourceLoader.exists(path): skin.texture = load(path)
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			skin.set_texture_margin(side, float([16, 12, 16, 16][side]))
			skin.set_content_margin(side, float([20, 9, 20, 9][side]))
		button.add_theme_stylebox_override(state, skin)
