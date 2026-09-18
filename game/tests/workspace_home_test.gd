extends SceneTree

const WorkspaceHome = preload("res://addons/team_workspace/workspace_home.gd")

class StubHome extends "res://addons/team_workspace/workspace_home.gd":
	var git_available := true
	var responses := {
		"symbolic-ref": {"code": 0, "output": "codex/qa/check"},
		"rev-parse": {"code": 0, "output": "1234abcd"},
		"status": {"code": 0, "output": " M docs/example.md"},
	}
	var git_calls: Array = []
	var opened_urls: Array[String] = []
	var open_result: Error = OK

	func _find_git() -> String:
		return "test-git" if git_available else ""

	func _run_git(_executable: String, arguments: Array) -> Dictionary:
		git_calls.append(arguments.duplicate())
		return responses[str(arguments[0])]

	func _open_external(url: String) -> Error:
		opened_urls.append(url)
		return open_result


var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _run() -> void:
	var repository := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var home := StubHome.new()
	home.setup(repository)
	root.add_child(home)
	await process_frame
	_expect(home.find_child("Title", true, false).text == "团队工作台", "home title")
	_expect(home.find_child("Description", true, false).text == "版本、任务和排期在网页查看", "short description")
	_expect(home.find_children("*", "Button", true, false).size() == 3, "only three navigation buttons")
	_expect(home.find_children("*", "TabContainer", true, false).is_empty(), "legacy tabs are absent")
	_expect(home.find_children("*", "TextEdit", true, false).is_empty(), "document editors are absent")
	var version: Label = home.find_child("LocalVersion", true, false)
	_expect(version.text.contains("codex/qa/check") and version.text.contains("1234abcd") and version.text.contains("有未提交修改"), "local branch commit and dirty state")
	_expect(home.find_child("VersionHint", true, false).text.contains("main"), "web main and local workspace are distinguished")
	for node_name in ["OpenTeam", "OpenRepository", "OpenTasks"]:
		home.find_child(node_name, true, false).pressed.emit()
	_expect(home.opened_urls == [WorkspaceHome.TEAM_URL, WorkspaceHome.REPOSITORY_URL, WorkspaceHome.TASKS_URL], "buttons open the intended destinations")
	var message: Label = home.find_child("LinkError", true, false)
	_expect(not message.visible, "successful browser request has no error")
	home.open_result = ERR_CANT_OPEN
	home.find_child("OpenTeam", true, false).pressed.emit()
	_expect(message.visible and message.text.contains(WorkspaceHome.TEAM_URL), "browser failure is visible with target URL")
	home.open_result = OK
	home.find_child("OpenTeam", true, false).pressed.emit()
	_expect(not message.visible, "later successful open clears the failure")
	home.responses.status.output = ""
	home.refresh_git_status()
	_expect(version.text.contains("工作区干净"), "clean workspace is reported")
	home.responses["symbolic-ref"] = {"code": 1, "output": ""}
	home.refresh_git_status()
	_expect(version.text.contains("分离 HEAD") and version.text.contains("1234abcd"), "detached commit is reported without inventing a branch")
	home.responses.status.code = 128
	home.refresh_git_status()
	_expect(version.text.contains("Git 检查失败"), "Git failure does not reuse a success state")
	home.git_available = false
	home.refresh_git_status()
	_expect(version.text.contains("未找到 Git"), "missing Git is explicit")
	var previous_calls: int = home.git_calls.size()
	home.setup(repository.path_join("planning"))
	_expect(version.text.contains("没有 Git 信息") and home.git_calls.size() == previous_calls, "non-repository folder does not borrow parent Git status")
	for arguments in home.git_calls:
		_expect(arguments[0] in ["symbolic-ref", "rev-parse", "status"], "Git calls are local reads")
	home.queue_free()
	await process_frame
	var real_home := WorkspaceHome.new()
	real_home.setup(repository)
	root.add_child(real_home)
	await process_frame
	var real_version: String = real_home.find_child("LocalVersion", true, false).text
	if real_home._find_git().is_empty():
		_expect(real_version.contains("未找到 Git"), "actual environment reports missing Git")
	else:
		_expect(real_version.begins_with("本机："), "actual repository Git status is readable")
	real_home.queue_free()
	await process_frame
	for failure in failures:
		printerr("CHECK FAILED: " + failure)
	if failures.is_empty():
		print("PASS: %d workspace home checks; no browser or Git mutations were invoked." % checks)
	quit(0 if failures.is_empty() else 1)
