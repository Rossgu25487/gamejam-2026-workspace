@tool
extends MarginContainer
## The editor home only links out and reads local Git state.

const TEAM_URL := "https://rossgu25487.github.io/gamejam-2026-workspace/"
const REPOSITORY_URL := "https://github.com/Rossgu25487/gamejam-2026-workspace"
const TASKS_URL := REPOSITORY_URL + "/issues"

var repository_root := ""
var _version_label: Label
var _message: Label


func setup(root_path: String) -> void:
	repository_root = root_path
	if is_node_ready():
		refresh_git_status()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		add_theme_constant_override("margin_" + side, 28)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 14)
	add_child(content)
	var title := _label(content, "Title", "团队工作台")
	title.add_theme_font_size_override("font_size", 26)
	_label(content, "Description", "版本、任务和排期在网页查看")
	var open_team := _link_button(content, "OpenTeam", "打开团队网页", TEAM_URL)
	open_team.custom_minimum_size = Vector2(240, 44)
	var secondary := HBoxContainer.new()
	secondary.add_theme_constant_override("separation", 10)
	content.add_child(secondary)
	_link_button(secondary, "OpenRepository", "GitHub 仓库", REPOSITORY_URL)
	_link_button(secondary, "OpenTasks", "GitHub 任务", TASKS_URL)
	content.add_child(HSeparator.new())
	_version_label = _label(content, "LocalVersion", "本机版本：尚未读取")
	_label(content, "VersionHint", "网页展示全队 main；本机分支、提交和未提交修改可能不同。")
	_message = _label(content, "LinkError", "")
	_message.hide()
	refresh_git_status()


func _label(parent: Node, node_name: String, text: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _link_button(parent: Node, node_name: String, text: String, url: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.tooltip_text = url
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.pressed.connect(_open_link.bind(url))
	parent.add_child(button)
	return button


func _open_link(url: String) -> void:
	var result := _open_external(url)
	_message.visible = result != OK
	_message.text = "无法打开链接（错误 %d），请在浏览器打开：%s" % [result, url] if result != OK else ""


func _open_external(url: String) -> Error:
	return OS.shell_open(url)


func refresh_git_status() -> void:
	if not is_instance_valid(_version_label):
		return
	var marker := repository_root.path_join(".git")
	if not FileAccess.file_exists(marker) and not DirAccess.dir_exists_absolute(marker):
		_version_label.text = "本机版本未读取：当前目录没有 Git 信息。"
		return
	var executable := _find_git()
	if executable.is_empty():
		_version_label.text = "本机版本未读取：当前环境未找到 Git。"
		return
	var branch := _run_git(executable, ["symbolic-ref", "--quiet", "--short", "HEAD"])
	var commit := _run_git(executable, ["rev-parse", "--short=8", "--verify", "--quiet", "HEAD"])
	var status := _run_git(executable, ["status", "--porcelain", "--untracked-files=normal"])
	if branch.code not in [0, 1] or commit.code not in [0, 1] or status.code != 0:
		_version_label.text = "本机版本未读取：Git 检查失败（分支 %d / 提交 %d / 状态 %d）。" % [branch.code, commit.code, status.code]
		return
	if commit.code == 1 and branch.code != 0:
		_version_label.text = "本机版本未读取：无法确认当前分支与提交。"
		return
	var branch_name := str(branch.output) if branch.code == 0 else "分离 HEAD"
	var commit_name := str(commit.output) if commit.code == 0 else "尚无提交"
	var changes := "有未提交修改" if not str(status.output).is_empty() else "工作区干净"
	_version_label.text = "本机：%s · %s · %s" % [branch_name, commit_name, changes]


func _find_git() -> String:
	var windows := OS.get_name() == "Windows"
	var separator := ";" if windows else ":"
	var filename := "git.exe" if windows else "git"
	for entry in OS.get_environment("PATH").split(separator, false):
		var directory := entry.strip_edges().trim_prefix("\"").trim_suffix("\"")
		if directory.is_absolute_path():
			var candidate := directory.path_join(filename)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


func _run_git(executable: String, arguments: Array) -> Dictionary:
	var output: Array = []
	var command := PackedStringArray(["--no-optional-locks", "-C", repository_root])
	for argument in arguments:
		command.append(str(argument))
	var code := OS.execute(executable, command, output, true, false)
	return {"code": code, "output": "".join(output).strip_edges()}
