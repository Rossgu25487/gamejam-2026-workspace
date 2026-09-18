@tool
extends RichTextLabel
## A small read-only Markdown view for team instructions, without HTML or active links.

var source_text := ""
var _bold_pattern := RegEx.new()


func _init() -> void:
	bbcode_enabled = true
	selection_enabled = true
	scroll_active = true
	fit_content = false
	_bold_pattern.compile("\\*\\*(.+?)\\*\\*")


func set_markdown(markdown: String) -> void:
	source_text = markdown
	clear()
	if markdown.strip_edges().is_empty():
		append_text("此岗位工作流目前为空，请联系团队维护者补充。")
		return
	var code_block := false
	for line in markdown.replace("\r\n", "\n").split("\n"):
		if line.strip_edges().begins_with("```"):
			code_block = not code_block
			append_text("\n")
			continue
		if code_block:
			append_text("[code]" + _escape(line) + "[/code]\n")
			continue
		var heading_level := 0
		while heading_level < mini(line.length(), 6) and line[heading_level] == "#":
			heading_level += 1
		if heading_level > 0 and line.length() > heading_level and line[heading_level] == " ":
			var heading_size := 24 if heading_level == 1 else (20 if heading_level == 2 else 17)
			append_text("[font_size=%d][b]%s[/b][/font_size]\n" % [heading_size, _inline(line.substr(heading_level + 1))])
		elif line.begins_with("- ") or line.begins_with("* "):
			append_text("• " + _inline(line.substr(2)) + "\n")
		else:
			append_text(_inline(line) + "\n")
	scroll_to_line(0)


func _inline(value: String) -> String:
	var segments := value.split("`")
	var rendered := ""
	for index in range(segments.size()):
		var safe := _escape(segments[index])
		if index % 2 == 1:
			rendered += "[code]" + safe + "[/code]"
		else:
			rendered += _bold_pattern.sub(safe, "[b]$1[/b]", true)
	return rendered


func _escape(value: String) -> String:
	return value.replace("[", "[lb]")
