extends Control
## 正文结束后的独立页面。只显示已交付署名，不将制作说明当作名单演出。
const UI = preload("res://pages/core/page_controls.gd")
const Credits = preload("res://pages/aurora/aurora_ending_credits.gd")
signal menu_requested
signal completed
var session: Node
var built := false
var credits_scroll: ScrollContainer
var credits_text: RichTextLabel
var menu_button: Button
var complete_button: Button
var _completion_sent := false

func bind(value: Node) -> void:
	if session != value: reset_page()
	session = value
	hide()

func open() -> void:
	show()
	if built: return
	built = true
	var shade := ColorRect.new()
	shade.color = Color("263B3B")
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var margin := MarginContainer.new()
	margin.name = "EndingMargin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 48)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	margin.add_child(box)
	var title := UI.label(box, "极光", 48)
	title.add_theme_color_override("font_color", Color("F1EBD8"))
	var subtitle := UI.label(box, "故事正文结束", 28)
	subtitle.add_theme_color_override("font_color", Color("F1EBD8"))
	var paper := PanelContainer.new()
	paper.name = "EndingCreditsPaper"
	paper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(paper)
	credits_scroll = ScrollContainer.new()
	credits_scroll.name = "EndingCreditsScroll"
	credits_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	credits_scroll.follow_focus = true
	paper.add_child(credits_scroll)
	credits_text = UI.body(credits_scroll, _credits(), 0)
	credits_text.name = "EndingCreditsText"
	credits_text.fit_content = true
	credits_text.scroll_active = false
	credits_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	credits_text.add_theme_color_override("default_color", Color("34413F"))
	credits_text.add_theme_font_size_override("normal_font_size", 24)
	var controls := HBoxContainer.new()
	controls.alignment = BoxContainer.ALIGNMENT_END
	controls.add_theme_constant_override("separation", 18)
	box.add_child(controls)
	menu_button = UI.button(controls, "菜单", menu_requested.emit)
	menu_button.name = "EndingMenu"
	complete_button = UI.button(controls, "结束并返回标题", _complete)
	complete_button.name = "EndingComplete"
	menu_button.call_deferred("grab_focus")

func _credits() -> String:
	var path: String = session.config.definition.root.path_join("音乐来源与署名.json")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not data is Dictionary: return Credits.TEXT
	var lines: Array[String] = [str(data.get("title", "音乐与音效署名")), str(data.get("source_note", "")), ""]
	for row in data.get("ui_sounds", []): lines.append("%s：%s" % [row.get("sound_id", ""), row.get("origin", "")])
	for row in data.get("music", []):
		lines.append("\n%s · %s\n%s" % [row.get("music_id", ""), row.get("title", ""), row.get("origin", "")])
		for credit in row.get("sample_credits", []):
			for key in ["library", "author", "additional_credit", "license", "license_url", "source", "use"]:
				if credit.has(key): lines.append("%s：%s" % [key, str(credit[key])])
	return "\n".join(lines)

func _complete() -> void:
	if _completion_sent: return
	_completion_sent = true
	session.case_state.data.ending_completed = true
	session.ending_checkpoint_requested.emit()
	completed.emit()

func reset_page() -> void:
	built = false
	_completion_sent = false
	UI.clear(self)
	credits_scroll = null
	credits_text = null
	menu_button = null
	complete_button = null
	hide()
