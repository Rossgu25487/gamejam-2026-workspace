extends SceneTree
## 回归测试：确认页重复打开时不重复创建按钮。

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene: Control = load("res://main/main.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    var box: VBoxContainer = scene.confirm_panel.get_child(0)
    for cycle in range(5):
        scene._on_new_game()
        scene._open_pause()
        scene._on_return_title()
        if box.get_child_count() != 5:
            printerr("FAIL: confirmation controls accumulated")
            quit(1)
            return
        scene.confirm_cancel.pressed.emit()
        if scene.current_layer != "pause" or scene.confirm_panel.visible:
            printerr("FAIL: confirmation cancel")
            quit(1)
            return
        scene._on_return_title()
        scene.confirm_direct.pressed.emit()
        if scene.current_layer != "title" or box.get_child_count() != 5:
            printerr("FAIL: return title or control count")
            quit(1)
            return
    scene._on_title_exit()
    if scene.confirm_direct.visible or scene.confirm_accept.disabled:
        quit(1)
        return
    print("PASS: repeated confirmations retain exactly three buttons; cancel and return work")
    scene.confirm_accept.pressed.emit()
    await create_timer(0.5).timeout
    printerr("FAIL: confirmed exit did not terminate")
    quit(1)
