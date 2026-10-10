extends SceneTree
## 导航回归只使用公开页面和真实确认控件；文件写入隔离目录。
var scene: Control
var failures: Array[String] = []
func _initialize() -> void: call_deferred("_run")
func check(value: bool, detail: String) -> void:
	if not value: failures.append(detail); printerr("NAV_FAILED: " + detail)
func _run() -> void:
	scene = load("res://main/main.tscn").instantiate()
	scene.test_storage_path = "user://navigation-regression/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await process_frame
	check(scene.current_layer == "title" and scene.title_page.visible and not scene.gameplay_page.visible, "标题层隐藏玩法")
	scene._on_settings()
	scene._on_close_subpage()
	check(scene.current_layer == "title" and not scene.pause_page.visible, "标题设置关闭返回标题")
	scene._on_new_game()
	await process_frame
	check(scene.current_layer == "investigation" and scene.gameplay_page.visible, "新游戏进入调查")
	var sequence: int = scene.save_service.sequence
	scene._open_pause()
	check(scene.current_layer == "pause" and scene.save_service.sequence == sequence, "暂停不补存")
	scene._on_settings(); scene._on_close_subpage()
	check(scene.current_layer == "pause", "调查设置关闭回暂停")
	scene._on_return_title()
	check(scene.current_layer == "confirm", "返回标题打开确认")
	scene._on_confirm_cancel()
	check(scene.current_layer == "pause", "取消回原暂停")
	scene._on_return_title(); scene._on_confirm_direct()
	check(scene.current_layer == "title" and not scene.gameplay_page.visible and scene.save_service.sequence == sequence, "直接离开不补存")
	scene._on_load(); scene._on_close_subpage()
	check(scene.current_layer == "title" and get_root().gui_get_focus_owner() == scene.title_page.load_button, "标题读取关闭恢复焦点")
	scene._on_continue(); scene._open_pause()
	await process_frame
	await process_frame
	check(scene.pause_page.get_node("PanelContainer").get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) <= 1.0, "暂停菜单居中")
	for page in ["load", "settings", "save"]:
		if page == "load": scene._on_load()
		elif page == "settings": scene._on_settings()
		else: scene._on_save()
		await process_frame
		await process_frame
		var panel: Control = scene.load_page.panel if page == "load" else (scene.settings_page.panel if page == "settings" else scene.save_page.panel)
		check(panel.get_global_rect().get_center().distance_to(root.get_visible_rect().get_center()) <= 1.0, page + "页面居中")
		scene._on_close_subpage()
	scene.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty(): print("NAV_PASS: title, pause, save/load/settings, focus and centering.")
	quit(0 if failures.is_empty() else 1)






