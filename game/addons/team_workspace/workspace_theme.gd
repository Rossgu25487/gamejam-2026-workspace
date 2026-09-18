@tool
extends RefCounted

const PAGE := Color("f1f0eb")
const SURFACE := Color("fafaf7")
const INK := Color("273330")
const MUTED := Color("52605a")
const ACCENT := Color("2f6962")
const ACCENT_SOFT := Color("ddebe5")
const BORDER := Color("c6cec7")
const DISABLED := Color("606860")
const ERROR := Color("963c32")


static func make_theme() -> Theme:
	var result := Theme.new()
	var regular := _font(400)
	var bold := _font(600)
	result.default_font = regular
	result.default_font_size = 16
	for type_name in ["Label", "Button", "ItemList", "TextEdit", "TabContainer", "PopupMenu", "LineEdit", "Tree"]:
		result.set_font("font", type_name, regular)
		result.set_font_size("font_size", type_name, 16)
		result.set_color("font_color", type_name, INK)
		result.set_constant("outline_size", type_name, 0)
	result.set_color("font_shadow_color", "Label", Color.TRANSPARENT)
	result.set_color("font_outline_color", "Label", Color.TRANSPARENT)
	result.set_stylebox("panel", "PanelContainer", box(SURFACE, BORDER, 10))
	result.set_stylebox("panel", "AcceptDialog", box(SURFACE, BORDER, 18))
	result.set_stylebox("embedded_border", "Window", box(PAGE, BORDER, 10))
	result.set_stylebox("embedded_unfocused_border", "Window", box(PAGE, BORDER, 10))
	result.set_color("title_color", "Window", INK)
	result.set_font("title_font", "Window", regular)
	result.set_font_size("title_font_size", "Window", 16)
	result.set_constant("title_outline_size", "Window", 0)
	result.set_stylebox("normal", "LineEdit", box(Color.WHITE, BORDER, 8))
	result.set_stylebox("read_only", "LineEdit", box(SURFACE, BORDER, 8))
	result.set_stylebox("focus", "LineEdit", focus_box())
	result.set_color("font_uneditable_color", "LineEdit", MUTED)
	result.set_stylebox("panel", "Tree", box(Color.WHITE, BORDER, 8))
	result.set_stylebox("selected", "Tree", box(ACCENT_SOFT, ACCENT_SOFT, 3))
	result.set_stylebox("selected_focus", "Tree", box(ACCENT_SOFT, ACCENT, 3))
	result.set_color("font_selected_color", "Tree", INK)
	result.set_color("folder_icon_color", "FileDialog", ACCENT)
	result.set_color("file_icon_color", "FileDialog", MUTED)
	for type_name in ["VBoxContainer", "HBoxContainer"]:
		result.set_constant("separation", type_name, 10)
	for type_name in ["HFlowContainer", "VFlowContainer"]:
		result.set_constant("h_separation", type_name, 8)
		result.set_constant("v_separation", type_name, 8)
	result.set_constant("separation", "HSplitContainer", 14)
	_button_styles(result, "Button", Color("e8ebe5"), INK, Color("dfe6df"), Color("d2dfd7"))
	result.set_type_variation("WorkspacePrimaryButton", "Button")
	_button_styles(result, "WorkspacePrimaryButton", ACCENT, Color.WHITE, Color("285d56"), Color("214f49"))
	result.set_stylebox("panel", "ItemList", box(SURFACE, BORDER, 10))
	result.set_stylebox("focus", "ItemList", focus_box())
	result.set_stylebox("cursor", "ItemList", focus_box())
	result.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	result.set_stylebox("selected", "ItemList", box(ACCENT_SOFT, ACCENT_SOFT, 6))
	result.set_stylebox("selected_focus", "ItemList", box(ACCENT_SOFT, ACCENT, 6))
	result.set_stylebox("hovered", "ItemList", box(Color("edf1eb"), Color("edf1eb"), 6))
	result.set_stylebox("hovered_selected", "ItemList", box(ACCENT_SOFT, ACCENT_SOFT, 6))
	result.set_stylebox("hovered_selected_focus", "ItemList", box(ACCENT_SOFT, ACCENT, 6))
	result.set_color("font_selected_color", "ItemList", INK)
	result.set_color("font_hovered_color", "ItemList", INK)
	result.set_color("font_hovered_selected_color", "ItemList", INK)
	result.set_color("font_disabled_color", "ItemList", DISABLED)
	result.set_color("guide_color", "ItemList", BORDER)
	result.set_constant("v_separation", "ItemList", 12)
	result.set_constant("h_separation", "ItemList", 10)
	result.set_constant("line_separation", "ItemList", 4)
	result.set_stylebox("panel", "TabContainer", box(SURFACE, BORDER, 14))
	result.set_stylebox("tab_selected", "TabContainer", box(SURFACE, BORDER, 10))
	result.set_stylebox("tab_unselected", "TabContainer", box(Color("e5e8e1"), Color("e5e8e1"), 10))
	result.set_stylebox("tab_hovered", "TabContainer", box(ACCENT_SOFT, ACCENT_SOFT, 10))
	result.set_color("font_selected_color", "TabContainer", INK)
	result.set_color("font_unselected_color", "TabContainer", MUTED)
	result.set_color("font_hovered_color", "TabContainer", INK)
	result.set_color("font_disabled_color", "TabContainer", DISABLED)
	result.set_font("normal_font", "RichTextLabel", regular)
	result.set_font("bold_font", "RichTextLabel", bold)
	result.set_font("italics_font", "RichTextLabel", regular)
	result.set_font("bold_italics_font", "RichTextLabel", bold)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "Noto Sans Mono CJK SC", "monospace"])
	result.set_font("mono_font", "RichTextLabel", mono)
	result.set_font_size("normal_font_size", "RichTextLabel", 16)
	result.set_font_size("bold_font_size", "RichTextLabel", 16)
	result.set_font_size("mono_font_size", "RichTextLabel", 14)
	result.set_color("default_color", "RichTextLabel", INK)
	result.set_color("font_selected_color", "RichTextLabel", INK)
	result.set_color("selection_color", "RichTextLabel", Color("cfe3da"))
	result.set_stylebox("normal", "RichTextLabel", box(SURFACE, SURFACE, 14))
	result.set_stylebox("focus", "RichTextLabel", focus_box())
	result.set_constant("line_separation", "RichTextLabel", 5)
	result.set_constant("paragraph_separation", "RichTextLabel", 8)
	result.set_stylebox("normal", "TextEdit", box(Color.WHITE, BORDER, 14))
	result.set_stylebox("read_only", "TextEdit", box(SURFACE, BORDER, 14))
	result.set_stylebox("focus", "TextEdit", focus_box())
	result.set_color("font_readonly_color", "TextEdit", INK)
	result.set_color("font_placeholder_color", "TextEdit", MUTED)
	result.set_color("font_selected_color", "TextEdit", INK)
	result.set_color("selection_color", "TextEdit", Color("cfe3da"))
	result.set_color("caret_color", "TextEdit", ACCENT)
	result.set_constant("line_spacing", "TextEdit", 5)
	for type_name in ["VScrollBar", "HScrollBar"]:
		result.set_stylebox("scroll", type_name, box(Color("e6e9e2"), Color("e6e9e2"), 4))
		result.set_stylebox("scroll_focus", type_name, box(Color("e6e9e2"), BORDER, 4))
		result.set_stylebox("grabber", type_name, box(Color("9aafa4"), Color("9aafa4"), 4))
		result.set_stylebox("grabber_highlight", type_name, box(Color("718f80"), Color("718f80"), 4))
		result.set_stylebox("grabber_pressed", type_name, box(ACCENT, ACCENT, 4))
	return result


static func box(background: Color, border: Color, padding: int = 10) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


static func focus_box() -> StyleBoxFlat:
	var style := box(Color.TRANSPARENT, ACCENT, 0)
	style.set_border_width_all(2)
	return style


static func _font(weight: int) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC", "sans-serif"])
	font.font_weight = weight
	return font


static func _button_styles(theme: Theme, type_name: String, normal: Color, text: Color, hover: Color, pressed: Color) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var background: Color = {"normal": normal, "hover": hover, "pressed": pressed, "disabled": Color("e3e5e0")}[state]
		var style := box(background, BORDER if type_name == "Button" else background, 9)
		style.content_margin_left = 13
		style.content_margin_right = 13
		theme.set_stylebox(state, type_name, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, type_name, text)
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		theme.set_color(state, type_name, text)
	theme.set_color("font_disabled_color", type_name, DISABLED)
	theme.set_color("icon_disabled_color", type_name, DISABLED)
	theme.set_stylebox("focus", type_name, focus_box())
