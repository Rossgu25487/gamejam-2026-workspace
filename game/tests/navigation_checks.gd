extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene: Control = load("res://main/main.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    await process_frame
    if scene.current_layer != "title" or not scene.get_node("TitlePage").visible or scene.counter_view.visible:
        printerr("NAV_FAILED: initial layer")
        quit(1)
        return
    scene._on_new_game()
    if scene.current_layer != "investigation" or scene.get_node("TitlePage").visible or not scene.counter_view.visible:
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
    scene._on_confirm_direct()
    if not scene.get_node("TitlePage").visible or scene.counter_view.visible:
        printerr("NAV_FAILED: return to title visibility")
        quit(1)
        return
    scene._on_load()
    scene._on_close_subpage()
    if scene.current_layer != "title" or scene.pause_panel.visible or scene.counter_view.visible or scene.get_viewport().gui_get_focus_owner() != scene.title_load:
        printerr("NAV_FAILED: title load return after prior investigation")
        quit(1)
        return
    scene._on_settings()
    scene._on_close_subpage()
    if scene.current_layer != "title" or scene.get_viewport().gui_get_focus_owner() != scene.title_settings:
        printerr("NAV_FAILED: title settings return")
        quit(1)
        return
    scene._on_title_exit()
    scene._on_confirm_cancel()
    if scene.current_layer != "title":
        printerr("NAV_FAILED: title exit cancel")
        quit(1)
        return
    scene._start_investigation()
    await scene._open_pause()
    await process_frame
    await process_frame
    var menu_center: Vector2 = scene.pause_panel.get_global_rect().get_center()
    var window_center: Vector2 = scene.navigation_layer.get_global_rect().get_center()
    if menu_center.distance_to(window_center) > 1.0:
        printerr("NAV_FAILED: pause menu centering")
        quit(1)
        return
    print("NAV_PASS: title, new game, pause, settings return and leave confirmation")
    quit(0)

