extends SceneTree
const Settings = preload("res://systems/game_settings/settings_service.gd")
var page: Control
var service: Node
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(value: bool, text: String) -> void:
	checks += 1
	if not value: failures.append(text); push_error(text)

func run() -> void:
	service = Settings.new()
	service.storage_path = "user://final_settings_layout_test.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(service.storage_path))
	service.apply_window_enabled = false
	root.add_child(service)
	service.initialize()
	page = preload("res://pages/settings_page.tscn").instantiate()
	root.add_child(page)
	var config := preload("res://systems/aurora/aurora_configuration.gd").new()
	check(config.load_package(), "正式设置专属文字读取")
	page.configure_formal(config)
	page.open(service)
	for dimensions in [Vector2i(1600, 900), Vector2i(1200, 900), Vector2i(960, 540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		for tab in ["sound", "display", "presentation", "controls"]:
			page._switch_tab(tab)
			await frames()
			check(inside(page.close_button) and inside(page.reset_button), str(dimensions) + " " + tab + " 返回与恢复可见")
			for key in page.tab_buttons: check(inside(page.tab_buttons[key]), "四页签完整位于有效显示区")
			if tab == "sound":
				check(inside(page.sliders.master_volume) and inside(page.preview_button), "四音量与试听使用正式布局")
				var slider: Control = page.sliders.master_volume
				service.set_value("master_volume", 20)
				slider.value = 20
				var start := slider.get_global_transform() * Vector2(16 + (slider.size.x - 32) * 0.2, slider.size.y * 0.5)
				var end := slider.get_global_transform() * Vector2(slider.size.x * 0.7, slider.size.y * 0.5)
				await drag(start, end)
				check(int(service.get_value("master_volume")) >= 60 and not page.adjusting, "真实鼠标拖动提交音量")
			elif tab == "display":
				check(inside(page.mode_option) and inside(page.aspect_option) and inside(page.apply_display_button), "显示候选与应用可见")
				service.set_value("brightness", 65)
				page._refresh_status()
				check(not page.sample_worlds.is_empty() and is_equal_approx(page.sample_worlds[0].modulate.r, 0.65), "场景采样随亮度即时变化")
				service.set_value("brightness", 100)
				page._refresh_status()
				if dimensions.x == 1200:
					page._open_scene_sample()
					await frames()
					check(page.scene_preview_overlay != null and page.scene_preview_overlay.mouse_filter == Control.MOUSE_FILTER_STOP, "窄比例独立画面预览独占输入")
					page._close_scene_sample()
			await capture("settings-%s-%dx%d.png" % [tab, dimensions.x, dimensions.y])
	page._switch_tab("sound")
	page._restore_defaults()
	await frames()
	check(page.reset_confirmation.visible and page.close_button.disabled, "默认恢复确认独占输入")
	page._confirm_reset()
	await frames()
	check(not page.reset_confirmation.visible and not service.display_preview_active and service.get_value("master_volume") == service.defaults.master_volume, "默认恢复延迟重建无锁对象错误")
	page._switch_tab("display")
	page.candidate_display = service.confirmed_display()
	page.candidate_display.aspect_ratio = 3
	page._apply_display()
	await frames()
	check(page.display_confirm.visible and not page.sliders.master_volume.editable and page.close_button.disabled, "显示确认阻断下层真实滑杆")
	page._revert_display()
	await frames()
	check(not page.display_confirm.visible and not page.close_button.disabled, "显示回退恢复入口")
	page.close_page()
	page.queue_free()
	service.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://final_settings_layout_test.json"))
	await frames()
	print("FINAL_SETTINGS_LAYOUT ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func frames() -> void:
	for i in range(4): await process_frame

func inside(control: Control) -> bool:
	if control == null or not control.is_visible_in_tree(): return false
	var a := control.get_global_transform() * Vector2.ZERO
	var b := control.get_global_transform() * control.size
	return a.x >= -1 and a.y >= -1 and b.x <= root.size.x + 1 and b.y <= root.size.y + 1

func drag(start: Vector2, end: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.position = start
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = end
	motion.relative = end - start
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = end
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame

func capture(filename: String) -> void:
	if "--capture" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/" + filename))
