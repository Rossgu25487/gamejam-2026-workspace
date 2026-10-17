extends Control
## 正文结束后的独立页面。只显示已交付署名，不将制作说明当作名单演出。
const UI = preload("res://pages/core/page_controls.gd")
signal menu_requested
signal completed
var session: Node
var built := false

func bind(value: Node) -> void:
	session = value
	hide()

func open() -> void:
	show()
	if built: return
	built = true
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.035, 0.05)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 50)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	margin.add_child(box)
	UI.label(box, "极光", 48)
	UI.label(box, "故事正文结束", 28)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var prose := UI.body(scroll, _credits(), 0)
	prose.fit_content = true
	prose.scroll_active = false
	prose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var controls := HBoxContainer.new()
	box.add_child(controls)
	UI.button(controls, "菜单", menu_requested.emit)
	UI.button(controls, "结束并返回标题", _complete)

func _credits() -> String:
	var path: String = session.config.definition.root.path_join("音乐来源与署名.json")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not data is Dictionary: return "音乐署名文件未配置。"
	var lines: Array[String] = [str(data.get("title", "音乐与音效署名")), str(data.get("source_note", "")), ""]
	for row in data.get("ui_sounds", []): lines.append("%s：%s" % [row.get("sound_id", ""), row.get("origin", "")])
	for row in data.get("music", []):
		lines.append("\n%s · %s\n%s" % [row.get("music_id", ""), row.get("title", ""), row.get("origin", "")])
		for credit in row.get("sample_credits", []):
			for key in ["library", "author", "additional_credit", "license", "license_url", "source", "use"]:
				if credit.has(key): lines.append("%s：%s" % [key, str(credit[key])])
	return "\n".join(lines)

func _complete() -> void:
	session.case_state.data.ending_completed = true
	session.ending_checkpoint_requested.emit()
	completed.emit()

func reset_page() -> void:
	built = false
	UI.clear(self)
	hide()
