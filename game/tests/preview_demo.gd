extends SceneTree
## Drives real Control input dispatch; this does not claim physical desktop input testing.

func _initialize() -> void:
	call_deferred("_exercise")

func _exercise() -> void:
	var scene = load("res://main/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var button: Button = scene.get_node("CounterView").get_node("%IncrementButton")
	var center := button.get_global_rect().get_center()
	for index in range(2):
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.position = center
		down.pressed = true
		root.push_input(down)
		var up := InputEventMouseButton.new()
		up.button_index = MOUSE_BUTTON_LEFT
		up.position = center
		up.pressed = false
		root.push_input(up)
		await process_frame
	if scene.get_node("CounterView").get_node("%ValueLabel").text != "2":
		printerr("GUI_INPUT_FAILED: expected two increments")
		quit(1)
	else:
		print("GUI_INPUT_PASS: two mouse events updated the live view to 2")
