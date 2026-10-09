extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene: Control = load("res://main/main.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    await process_frame
    if scene.current_layer != "title" or not scene.title_page.visible or scene.counter_view.visible:
        printerr("NAV_FAILED: initial layer")
        quit(1)
        return
    scene._on_new_game()
    if scene.current_layer != "investigation" or scene.title_page.visible or not scene.counter_view.visible:
        printerr("NAV_FAILED: new game")
        quit(1)
        return
    scene.model.increment()
    scene._on_save()
    await process_frame
    scene.save_page._save_slot(0)
    await process_frame
    scene._on_close_subpage()
    scene.model.reset()
    scene._show_title()
    scene._on_continue()
    if scene.model.read_value() != 1:
        printerr("NAV_FAILED: continue did not restore latest manual save")
        quit(1)
        return
    if not scene.title_page.detail.text.begins_with("最近有效进度："):
        printerr("NAV_FAILED: latest summary text")
        quit(1)
        return
    scene.model.reset()
    for _index in range(7):
        scene.model.increment()
    if scene.model.read_value() != 7:
        printerr("NAV_FAILED: counter setup")
        quit(1)
        return
    await scene._open_pause()
    if scene.current_layer != "pause" or scene.pause_page.save_button.disabled:
        printerr("NAV_FAILED: pause state or save unavailable")
        quit(1)
        return
    scene._on_load()
    await process_frame
    if not scene.load_page.visible:
        printerr("NAV_FAILED: first load page")
        quit(1)
        return
    scene.load_page._load_slot("auto", 0)
    await process_frame
    scene._on_load()
    await process_frame
    if not scene.load_page.visible:
        printerr("NAV_FAILED: repeated load page after auto load")
        quit(1)
        return
    scene._on_close_subpage()
    scene._on_save()
    if scene.current_layer != "subpage" or not scene.save_page.visible:
        printerr("NAV_FAILED: save page")
        quit(1)
        return
    scene.save_page._save_slot(0)
    scene.model.reset()
    if scene.model.read_value() != 0:
        printerr("NAV_FAILED: counter reset")
        quit(1)
        return
    scene._on_load()
    await process_frame
    scene.load_page._load_slot("manual", 0)
    await process_frame
    if scene.model.read_value() != 7:
        printerr("NAV_FAILED: manual save restore")
        quit(1)
        return
    scene._on_close_subpage()
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
    if not scene.title_page.visible or scene.counter_view.visible or scene.current_layer != "title":
        printerr("NAV_FAILED: return to title visibility")
        quit(1)
        return
    scene._on_load()
    scene._on_close_subpage()
    if scene.current_layer != "title" or scene.pause_page.visible or scene.counter_view.visible or scene.get_viewport().gui_get_focus_owner() != scene.title_page.load_button:
        printerr("NAV_FAILED: title load return after prior investigation")
        quit(1)
        return
    scene._on_settings()
    scene._on_close_subpage()
    if scene.current_layer != "title" or scene.get_viewport().gui_get_focus_owner() != scene.title_page.settings_button:
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
    var menu_center: Vector2 = scene.pause_page.get_node("PanelContainer").get_global_rect().get_center()
    var window_center: Vector2 = scene.get_viewport().get_visible_rect().get_center()
    if menu_center.distance_to(window_center) > 1.0:
        printerr("NAV_FAILED: pause menu centering")
        quit(1)
        return
    print("NAV_PASS: title, new game, pause, settings return and leave confirmation")
    scene._on_pause_exit()
    scene._on_confirm_cancel()
    scene._show_title()
    scene._on_title_exit()
    if scene.confirm_panel.get_child(0).get_child(0).get_child(3).disabled:
        printerr("NAV_FAILED: title exit confirmation")
        quit(1)
        return
    scene._on_confirm_accept()
    await create_timer(1.0).timeout
    printerr("NAV_FAILED: exit did not terminate the application")
    quit(1)






