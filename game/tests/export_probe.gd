extends SceneTree

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
		root.add_child(scene)
		await process_frame
		var view = scene.get_node("CounterView")
		view.get_node("%IncrementButton").pressed.emit()
		if view.get_node("%ValueLabel").text != "1":
			failures.append("Exported live interface did not increment")
		scene.queue_free()
		await process_frame
	for error in failures:
		printerr(error)
	if failures.is_empty():
		print("EXPORT_PASS: standalone dependencies and UI wiring work; collaboration data and tools absent.")
	quit(0 if failures.is_empty() else 1)
