extends SceneTree

const WorkspacePanel = preload("res://addons/team_workspace/workspace_panel.gd")


func _initialize() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			var parts := argument.trim_prefix("--size=").split("x")
			root.size = Vector2i(int(parts[0]), int(parts[1]))
	call_deferred("_show")


func _show() -> void:
	root.title = "八人协作空间 · 界面检查"
	var panel := WorkspacePanel.new()
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	panel.setup(repo, false)
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.select_role("planner")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--tab="):
			panel.get_controls().tabs.current_tab = int(argument.trim_prefix("--tab="))
