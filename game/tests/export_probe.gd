extends SceneTree
## 导出探针：确认工程可以在无编辑器界面时加载关键资源。

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var failures: Array[String] = []
	for path in ["res://addons/team_workspace/plugin.gd", "res://tests/test_suite.gd", "res://planning/current.json", "res://workspace/manifest.json"]:
		if FileAccess.file_exists(path) or ResourceLoader.exists(path):
			failures.append("Internal file was exported: " + path)
	var packed = load("res://main/main.tscn")
	if packed == null:
		failures.append("Exported main scene could not load")
	else:
		var scene = packed.instantiate()
		scene.test_storage_path = "user://export-probe/%d" % Time.get_ticks_usec()
		root.add_child(scene)
		await process_frame
		scene.title_page.new_game_requested.emit()
		scene.confirm_page.accepted.emit()
		var core: Node = scene.session_service.core
		if not core.activate_entry("INSPECT") or core.store.entities.size() != 3:
			failures.append("Exported gameplay could not acquire configured materials")
		scene.queue_free()
		await process_frame
	for error in failures:
		printerr(error)
	if failures.is_empty():
		print("EXPORT_PASS: standalone dependencies and UI wiring work; collaboration data and tools absent.")
	quit(0 if failures.is_empty() else 1)
