extends SceneTree
## Render the real collaboration panel at explicit viewport sizes for layout inspection.
const WorkspacePanel = preload("res://addons/team_workspace/workspace_panel.gd")

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var output := repo.path_join(".local/captures")
	DirAccess.make_dir_recursive_absolute(output)
	for target_size in [Vector2i(1280, 820), Vector2i(950, 700)]:
		var viewport := SubViewport.new()
		viewport.size = target_size
		viewport.disable_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var panel := WorkspacePanel.new()
		panel.setup(repo, false)
		viewport.add_child(panel)
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		panel.select_role("planner")
		for tab in [0, 1, 2]:
			panel.get_controls().tabs.current_tab = tab
			await process_frame
			await RenderingServer.frame_post_draw
			var snapshot := viewport.get_texture().get_image()
			var path := output.path_join("workspace-%dx%d-tab%d.png" % [target_size.x, target_size.y, tab])
			var result := snapshot.save_png(path)
			if result != OK:
				printerr("Capture failed: " + path)
				quit(1)
				return
			print("CAPTURE: " + path)
		viewport.queue_free()
		await process_frame
	quit()
