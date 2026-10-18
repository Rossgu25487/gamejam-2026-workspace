extends RefCounted
## 调试控制台的统一外观：深色面板、蓝色强调，字体带中文回退。
## 控件样式集中在这里，各页签只负责摆放控件。
const BG := Color("0d141e")
const RAISED := Color("172233")
const HOVER := Color("22334b")
const PRESSED := Color("2b5d94")
const FIELD := Color("101a28")
const BORDER := Color("2b3d55")
const ACCENT := Color("4a9eed")
const ACCENT_TEXT := Color("7cc0ff")
const TEXT := Color("dbe3ee")
const DIM := Color("8191a6")
const OK := Color("7fd18b")
const WARN := Color("f0c674")
const ERROR := Color("ff7b72")
const LOG_COLORS := {"info": TEXT, "ok": OK, "warn": WARN, "error": ERROR, "dim": DIM, "title": ACCENT_TEXT, "echo": Color("9ecbff")}
const UI_FONTS := ["Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Noto Sans CJK SC", "SimHei", "sans-serif"]
const MONO_FONTS := ["Cascadia Mono", "Consolas", "Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "monospace"]
const BASE_SIZE := 15

static func make_font(mono: bool = false) -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(MONO_FONTS if mono else UI_FONTS)
	font.allow_system_fallback = true
	return font

static func box(color: Color, border: Color = Color.TRANSPARENT, border_width: int = 0, radius: int = 4, margin_h: int = 12, margin_v: int = 7) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = margin_h
	style.content_margin_right = margin_h
	style.content_margin_top = margin_v
	style.content_margin_bottom = margin_v
	return style

static func line(color: Color, thickness: int = 1) -> StyleBoxLine:
	var style := StyleBoxLine.new()
	style.color = color
	style.thickness = thickness
	return style

## 复选框图标：默认主题的方框在深色底上几乎看不见，这里画一个边框清楚、勾选后高亮的方块。
static func check_icon(checked: bool, enabled: bool = true, partial: bool = false) -> Texture2D:
	var size := 18
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var edge := Color("9db4d0") if enabled else Color("3a4a60")
	var fill := (ACCENT if enabled else Color("34506f")) if (checked or partial) else FIELD
	for x in range(1, size - 1):
		for y in range(1, size - 1):
			var on_edge := x == 1 or y == 1 or x == size - 2 or y == size - 2
			var corner := (x == 1 or x == size - 2) and (y == 1 or y == size - 2)
			if corner: continue
			image.set_pixel(x, y, edge if on_edge else fill)
	var mark := Color.WHITE if enabled else Color("8191a6")
	if checked:
		for step in range(0, 5):
			_dot(image, 4 + step, 9 + step, mark)
		for step in range(0, 8):
			_dot(image, 8 + step, 13 - step, mark)
	elif partial:
		for x in range(5, size - 5):
			_dot(image, x, 9, mark)
	return ImageTexture.create_from_image(image)

static func _dot(image: Image, x: int, y: int, color: Color) -> void:
	for dx in range(0, 2):
		for dy in range(0, 2):
			image.set_pixel(clampi(x + dx, 0, image.get_width() - 1), clampi(y + dy, 0, image.get_height() - 1), color)

static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font = make_font()
	theme.default_font_size = BASE_SIZE

	theme.set_color("font_color", "Label", TEXT)

	theme.set_stylebox("panel", "PanelContainer", box(BG, BORDER, 2, 10, 12, 10))

	for kind in ["Button", "OptionButton", "MenuButton"]:
		theme.set_stylebox("normal", kind, box(RAISED, BORDER, 1))
		theme.set_stylebox("hover", kind, box(HOVER, ACCENT, 1))
		theme.set_stylebox("pressed", kind, box(PRESSED, ACCENT, 1))
		theme.set_stylebox("hover_pressed", kind, box(PRESSED, ACCENT_TEXT, 1))
		theme.set_stylebox("disabled", kind, box(Color("121a26"), Color("1d2a3b"), 1))
		theme.set_stylebox("focus", kind, box(Color.TRANSPARENT, ACCENT_TEXT, 2))
		theme.set_color("font_color", kind, TEXT)
		theme.set_color("font_hover_color", kind, Color.WHITE)
		theme.set_color("font_pressed_color", kind, Color.WHITE)
		theme.set_color("font_hover_pressed_color", kind, Color.WHITE)
		theme.set_color("font_focus_color", kind, Color.WHITE)
		theme.set_color("font_disabled_color", kind, Color("55627a"))

	for kind in ["CheckBox", "CheckButton"]:
		theme.set_color("font_color", kind, TEXT)
		theme.set_color("font_hover_color", kind, Color.WHITE)
		theme.set_color("font_pressed_color", kind, Color.WHITE)
		theme.set_color("font_hover_pressed_color", kind, Color.WHITE)
		theme.set_color("font_focus_color", kind, Color.WHITE)
		theme.set_color("font_disabled_color", kind, Color("55627a"))
		theme.set_stylebox("focus", kind, box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	var checked := check_icon(true)
	var unchecked := check_icon(false)
	var checked_off := check_icon(true, false)
	var unchecked_off := check_icon(false, false)
	for kind in ["CheckBox", "Tree"]:
		theme.set_icon("checked", kind, checked)
		theme.set_icon("unchecked", kind, unchecked)
		theme.set_icon("checked_disabled", kind, checked_off)
		theme.set_icon("unchecked_disabled", kind, unchecked_off)
	theme.set_icon("indeterminate", "Tree", check_icon(false, true, true))

	theme.set_stylebox("normal", "LineEdit", box(FIELD, BORDER, 1))
	theme.set_stylebox("focus", "LineEdit", box(FIELD, ACCENT, 2))
	theme.set_stylebox("read_only", "LineEdit", box(Color("121a26"), BORDER, 1))
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", Color("5d6c82"))
	theme.set_color("caret_color", "LineEdit", Color.WHITE)
	theme.set_color("selection_color", "LineEdit", Color(0.29, 0.62, 0.93, 0.45))

	theme.set_stylebox("panel", "PopupMenu", box(Color("121c2b"), ACCENT, 1, 4, 6, 6))
	theme.set_stylebox("hover", "PopupMenu", box(PRESSED, Color.TRANSPARENT, 0, 3, 6, 4))
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	theme.set_constant("v_separation", "PopupMenu", 6)

	theme.set_stylebox("panel", "Tree", box(FIELD, BORDER, 1, 4, 4, 4))
	theme.set_stylebox("focus", "Tree", box(Color.TRANSPARENT, Color.TRANSPARENT, 0))
	theme.set_stylebox("selected", "Tree", box(Color("27456b"), Color.TRANSPARENT, 0, 2, 4, 2))
	theme.set_stylebox("selected_focus", "Tree", box(PRESSED, Color.TRANSPARENT, 0, 2, 4, 2))
	theme.set_stylebox("cursor", "Tree", box(Color.TRANSPARENT, ACCENT, 1, 2, 4, 2))
	theme.set_stylebox("cursor_unfocused", "Tree", box(Color.TRANSPARENT, BORDER, 1, 2, 4, 2))
	theme.set_stylebox("title_button_normal", "Tree", box(RAISED, BORDER, 1, 0, 8, 5))
	theme.set_stylebox("title_button_hover", "Tree", box(HOVER, BORDER, 1, 0, 8, 5))
	theme.set_stylebox("title_button_pressed", "Tree", box(HOVER, BORDER, 1, 0, 8, 5))
	theme.set_color("font_color", "Tree", TEXT)
	theme.set_color("font_selected_color", "Tree", Color.WHITE)
	theme.set_color("title_button_color", "Tree", ACCENT_TEXT)
	theme.set_color("guide_color", "Tree", Color(1, 1, 1, 0.08))
	theme.set_color("relationship_line_color", "Tree", Color(1, 1, 1, 0.12))
	theme.set_constant("v_separation", "Tree", 3)
	theme.set_constant("item_margin", "Tree", 14)

	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_stylebox("normal", "RichTextLabel", box(FIELD, BORDER, 1, 4, 8, 6))
	theme.set_stylebox("focus", "RichTextLabel", box(Color.TRANSPARENT, Color.TRANSPARENT, 0))

	theme.set_stylebox("panel", "TabContainer", box(Color(0, 0, 0, 0), BORDER, 0, 0, 0, 8))
	theme.set_stylebox("tab_selected", "TabContainer", box(PRESSED, Color.TRANSPARENT, 0, 4, 14, 6))
	theme.set_stylebox("tab_unselected", "TabContainer", box(RAISED, Color.TRANSPARENT, 0, 4, 14, 6))
	theme.set_stylebox("tab_hovered", "TabContainer", box(HOVER, Color.TRANSPARENT, 0, 4, 14, 6))
	theme.set_color("font_selected_color", "TabContainer", Color.WHITE)
	theme.set_color("font_unselected_color", "TabContainer", DIM)
	theme.set_color("font_hovered_color", "TabContainer", Color.WHITE)

	theme.set_stylebox("background", "ProgressBar", box(Color("0b121b"), BORDER, 1, 3, 2, 2))
	theme.set_stylebox("fill", "ProgressBar", box(ACCENT, Color.TRANSPARENT, 0, 3, 2, 2))
	theme.set_color("font_color", "ProgressBar", Color.WHITE)

	theme.set_stylebox("separator", "HSeparator", line(BORDER))
	theme.set_constant("separation", "HSeparator", 10)
	theme.set_stylebox("slider", "HSlider", box(Color("0b121b"), BORDER, 1, 3, 2, 2))
	return theme
