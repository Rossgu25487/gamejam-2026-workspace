extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene: Control = load("res://main/main.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    await process_frame
    if scene.current_layer != "title":
        printerr("NAV_FAILED: initial layer")
        quit(1)
        return
    scene._on_new_game()
    if scene.current_layer != "investigation":
        printerr("NAV_FAILED: new game")
        quit(1)
        return
    await scene._open_pause()
    if scene.current_layer != "pause" or scene.pause_save.disabled == false:
        printerr("NAV_FAILED: pause state")
        quit(1)
        return
    scene._on_settings()
    if scene.current_layer != "subpage":
        printerr("NAV_FAILED: settings subpage")
        quit(1)
        return
    scene._on_close_subpage()
    if scene.current_layer != "pause":
        printerr("NAV_FAILED: settings return")
        quit(1)
        return
    scene._on_return_title()
    if scene.current_layer != "confirm":
        printerr("NAV_FAILED: leave confirmation")
        quit(1)
        return
    scene._on_confirm_cancel()
    if scene.current_layer != "pause":
        printerr("NAV_FAILED: cancel confirmation")
        quit(1)
        return
    print("NAV_PASS: title, new game, pause, settings return and leave confirmation")
    quit(0)

