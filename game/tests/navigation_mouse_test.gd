extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _click(button: Button) -> void:
    var point := button.get_global_rect().get_center()
    var motion := InputEventMouseMotion.new()
    motion.position = point
    root.push_input(motion)
    await process_frame
    for pressed in [true, false]:
        var event := InputEventMouseButton.new()
        event.position = point
        event.button_index = MOUSE_BUTTON_LEFT
        event.pressed = pressed
        root.push_input(event)
        await process_frame

func _run() -> void:
    root.size = Vector2i(1152, 720)
    var scene: Control = load("res://main/main.tscn").instantiate()
    root.add_child(scene)
    await create_timer(0.3).timeout
    await _click(scene.title_page.settings_button)
    if scene.current_layer != "subpage":
        printerr("FAIL: title settings mouse click blocked")
        quit(1)
        return
    var close: Button = scene.subpage_panel.get_child(0).get_child(2)
    await _click(close)
    if scene.current_layer != "title":
        printerr("FAIL: subpage close mouse click blocked")
        quit(1)
        return
    await _click(scene.title_page.new_game_button)
    if scene.current_layer != "investigation":
        printerr("FAIL: new game mouse click blocked")
        quit(1)
        return
    print("PASS: mouse dispatch opens settings, closes settings and starts investigation")
    quit(0)
