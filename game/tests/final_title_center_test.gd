extends SceneTree
## 标题菜单随有效显示区域居中，缩放和往返设置不累计平移。
var app: Control
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("TITLE_CENTER_FAIL: " + message)
func frames(count := 5) -> void:
	for index in range(count): await process_frame
func capture(label: String) -> void:
	if not "--capture" in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://../.local/title-center-%s.png" % label)
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://title_center_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(8)
	app.settings_service.apply_window_enabled = false
	var title: Control = app.title_page
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1200, 900), Vector2i(1920, 1080)]:
		root.size = dimensions; root.content_scale_size = dimensions
		for ratio in [0, 1, 2, 3, 4]:
			app.settings_service.runtime_display.aspect_ratio = ratio
			app.settings_service._emit_display_area()
			await frames(7)
			var surface: Rect2 = app.display_surface.get_global_rect()
			var menu: Rect2 = title.formal_menu.get_global_rect()
			check(menu.get_center().distance_to(surface.get_center()) < 1, "%s 比例%d菜单在有效区中央" % [str(dimensions), ratio])
			check(surface.grow(1).encloses(menu), "完整菜单在有效区域内")
			check(absf(title.new_game_button.get_global_rect().get_center().x - menu.get_center().x) < 1, "按钮随纸面水平居中")
			check(title.heading.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "标题文字水平居中")
			var before: Vector2 = title.formal_menu.position
			title._layout_formal(); title._layout_formal()
			check(title.formal_menu.position.is_equal_approx(before), "重复布局不会累计位移")
			if dimensions == Vector2i(1600, 900) and ratio in [0, 3]: await capture("1600-ratio%d" % ratio)
	app.settings_service.runtime_display.aspect_ratio = 0
	app.settings_service._emit_display_area(); await frames()
	var point: Vector2 = title.new_game_button.get_global_transform_with_canvas() * (title.new_game_button.size / 2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event); await process_frame
	await frames()
	check(app.current_layer == "confirm" and app.confirm_page.visible, "居中后真实鼠标点击新游戏有效")
	app.queue_free(); await frames(12)
	print("FINAL_TITLE_CENTER: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
