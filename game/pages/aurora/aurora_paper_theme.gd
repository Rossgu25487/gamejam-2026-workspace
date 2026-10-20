extends RefCounted
## 正式界面共用主题只编译已采用的组件，不参与各页面业务和动作。
static func build(config: RefCounted, factor := 1.0) -> Theme:
	var theme := Theme.new()
	var base: String = str(config.definition.root)
	var assets := {}
	var path := base.path_join("design/ui_20261018/adopted_assets.json")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		for row in parsed.get("assets", []): assets[str(row.asset_id)] = config.resource_path(str(row.get("runtime_path", "")))
	var font_path := str(assets.get("A03_DreamHanSansCN-W12", ""))
	if ResourceLoader.exists(font_path): theme.default_font = load(font_path)
	theme.default_font_size = maxi(16, roundi(24 * factor))
	for type in ["Label", "Button", "OptionButton", "CheckButton", "LineEdit", "RichTextLabel"]:
		for color in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "default_color"]: theme.set_color(color, type, Color("34413F"))
		theme.set_color("font_disabled_color", type, Color("737B70"))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		# 交付资源没有单独的 hover_pressed 皮肤时沿用 pressed，
		# 避免 Godot 使用空 StyleBox 导致按住/悬停按钮边框和文字消失。
		var asset_state: String = state
		if state == "hover_pressed" and not assets.has("PAPER_V2_button_secondary_hover_pressed"):
			asset_state = "pressed"
		var skin := surface(assets, "PAPER_V2_button_secondary_" + asset_state, [16,12,16,16], [20,9,20,9], factor)
		for type in ["Button", "OptionButton"]: theme.set_stylebox(state, type, skin)
	var focus := surface(assets, "A03_focus", [16,12,16,16], [20,9,20,9], factor)
	for type in ["Button", "OptionButton"]: theme.set_stylebox("focus", type, focus)
	theme.set_stylebox("panel", "PanelContainer", surface(assets, "PAPER_V2_panel_paper", [32,32,32,36], [48,40,48,44], factor))
	theme.set_stylebox("panel", "Panel", surface(assets, "PAPER_V2_panel_paper", [32,32,32,36], [48,40,48,44], factor))
	theme.set_stylebox("panel", "PopupMenu", surface(assets, "PAPER_V2_panel_paper", [32,32,32,36], [18,14,18,14], factor))
	theme.set_stylebox("slider", "HSlider", surface(assets, "A03_slider_track", [3,3,3,3], [0,4,0,4], factor))
	theme.set_stylebox("grabber_area", "HSlider", surface(assets, "A03_slider_fill", [3,3,3,3], [0,4,0,4], factor))
	var knob := str(assets.get("A03_slider_knob", ""))
	if ResourceLoader.exists(knob):
		for state in ["grabber", "grabber_highlight", "grabber_disabled"]: theme.set_icon(state, "HSlider", load(knob))
	return theme

static func surface(assets: Dictionary, id: String, margins: Array, padding: Array, factor: float) -> StyleBoxTexture:
	var skin := StyleBoxTexture.new()
	var path := str(assets.get(id, ""))
	if ResourceLoader.exists(path): skin.texture = load(path)
	for side in [SIDE_LEFT,SIDE_TOP,SIDE_RIGHT,SIDE_BOTTOM]:
		skin.set_texture_margin(side, float(margins[side]))
		skin.set_content_margin(side, float(padding[side]) * factor)
	return skin
