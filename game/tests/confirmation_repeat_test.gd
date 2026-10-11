extends SceneTree
## 反复打开实际确认页，最后确认退出并检查进程真实终止。
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var scene: Control = load("res://main/main.tscn").instantiate()
	scene.test_storage_path = "user://confirm-regression/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await process_frame
	var count: int = scene.confirm_page.box.get_child_count()
	for cycle in range(5):
		scene._on_new_game(); scene._open_pause(); scene._on_return_title()
		if scene.confirm_page.box.get_child_count() != count:
			printerr("CONFIRM_FAILED: controls accumulated"); quit(1); return
		scene.confirm_page.cancel_button.pressed.emit()
		if scene.current_layer != "pause" or scene.confirm_page.visible:
			printerr("CONFIRM_FAILED: cancel origin"); quit(1); return
		scene._on_return_title()
		scene.confirm_page.direct_button.pressed.emit()
		if scene.current_layer != "title":
			printerr("CONFIRM_FAILED: return title"); quit(1); return
	scene._on_title_exit()
	if scene.confirm_page.direct_button.visible or not scene.confirm_page.accept_button.visible:
		printerr("CONFIRM_FAILED: title exit actions"); quit(1); return
	print("CONFIRM_PASS: repeated controls stable; dispatching actual exit.")
	scene.confirm_page.accept_button.pressed.emit()
	await create_timer(0.5).timeout
	printerr("CONFIRM_FAILED: exit did not terminate process")
	quit(1)
