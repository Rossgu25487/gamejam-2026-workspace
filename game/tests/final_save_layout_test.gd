extends SceneTree
## 正式存读档网格、分页和覆盖确认使用真实输入验证，测试存档隔离。
var checks := 0
var failures: Array[String] = []
var service: Node
var save_page: Control
var load_page: Control

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	service = preload("res://systems/save_load/save_load_service.gd").new()
	service.storage_path = "user://final_save_layout_test"
	root.add_child(service)
	clear_saves()
	service.manual_slot_count = 10
	check(service.save_snapshot("manual", 0, {"progress_summary":{"scene":"旅馆柜台", "phase":"调查"},"elapsed_seconds":125}), "准备隔离真实存档")
	save_page = preload("res://pages/save_page.tscn").instantiate()
	load_page = preload("res://pages/load_page.tscn").instantiate()
	root.add_child(save_page)
	root.add_child(load_page)
	save_page.open(service, {"progress_summary":{"scene":"旅馆柜台"}})
	for dimensions in [Vector2i(1600, 900), Vector2i(1440, 900), Vector2i(1200, 900), Vector2i(2100, 900), Vector2i(960, 540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await frames()
		check(inside(save_page.formal_layout.close) and inside(save_page.submit_button), str(dimensions) + " 保存和返回处于有效显示区")
		var expected := 3 if dimensions.x == 1200 else 6
		check(visible_slots(save_page.slot_buttons) == expected, str(dimensions) + " 当前分页槽位数")
		check(distinct_slots(save_page.slot_buttons), str(dimensions) + " 存档网格无槽位重叠")
		await click(save_page.formal_layout.next)
		check(save_page.formal_layout.page_index == 1 and save_page.slot_buttons[expected].visible, "真实下一页输入显示后续栏位")
		await click(save_page.formal_layout.previous)
		check(save_page.formal_layout.page_index == 0, "真实上一页输入返回首栏")
		if dimensions.x in [1600, 1200, 960]: await capture("save-layout-%dx%d.png" % [dimensions.x, dimensions.y])
	await click(save_page.slot_buttons[0])
	await click(save_page.submit_button)
	check(save_page.confirmation.visible and service.sequence == 1, "点击已有存档仅打开覆盖确认")
	check(inside(save_page.confirmation.cancel_button) and inside(save_page.confirmation.accept_button), "小窗口覆盖确认按正式位置显示")
	await click(save_page.formal_layout.next)
	check(save_page.formal_layout.page_index == 0 and service.sequence == 1, "确认遮罩阻断底层分页输入")
	await capture("save-layout-confirm-960x540.png")
	await click(save_page.confirmation.cancel_button)
	check(not save_page.confirmation.visible and service.sequence == 1, "真实取消覆盖保留旧档")
	await click(save_page.submit_button)
	await click(save_page.confirmation.accept_button)
	check(not save_page.confirmation.visible and service.sequence == 2 and save_page.status_label.text == "保存完成", "真实确认覆盖写入一次并保留保存页")
	save_page.close_page()
	load_page.open(service, true, true)
	await frames()
	check(visible_slots(load_page.slot_buttons) == 6 and distinct_slots(load_page.slot_buttons), "读取手动档与保护档采用同一分页网格")
	await click(load_page.load_button)
	check(load_page.confirmation.visible and inside(load_page.confirmation.accept_button), "读取替换确认显示先保存选项")
	await click(load_page.confirmation.cancel_button)
	check(not load_page.confirmation.visible, "真实取消读取保持列表")
	await capture("load-layout-960x540.png")
	load_page.close_page()
	load_page.open(service, true, false)
	await click(load_page.load_button)
	check(load_page.confirmation.visible and not load_page.confirmation.accept_button.visible and inside(load_page.confirmation.direct_button), "不可保存时显示正式双按钮确认")
	load_page.close_page()
	save_page.queue_free()
	load_page.queue_free()
	clear_saves()
	service.queue_free()
	await frames()
	print("FINAL_SAVE_LAYOUT ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func frames() -> void:
	for index in range(4): await process_frame

func visible_slots(buttons: Array[Button]) -> int:
	var count := 0
	for button in buttons:
		if button.is_visible_in_tree(): count += 1
	return count

func distinct_slots(buttons: Array[Button]) -> bool:
	for index in range(buttons.size()):
		if not buttons[index].visible: continue
		if not inside(buttons[index]): return false
		for other in range(index + 1, buttons.size()):
			if buttons[other].visible and buttons[index].get_rect().intersects(buttons[other].get_rect()): return false
	return true

func inside(control: Control) -> bool:
	if control == null or not control.is_visible_in_tree(): return false
	var start := control.get_global_transform() * Vector2.ZERO
	var end := control.get_global_transform() * control.size
	return start.x >= -1 and start.y >= -1 and end.x <= root.size.x + 1 and end.y <= root.size.y + 1

func click(control: Control) -> void:
	var point := control.get_global_transform() * (control.size / 2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		Input.parse_input_event(event)
		await process_frame
	await frames()

func clear_saves() -> void:
	for kind in ["manual", "auto", "pre_accusation", "ending_resume"]:
		for index in range(10 if kind == "manual" else 1):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(service._path(kind, index)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(service.storage_path))

func capture(filename: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/" + filename))
