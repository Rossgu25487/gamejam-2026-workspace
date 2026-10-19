extends SceneTree
## 正式入口集成：真实输入、工具退层、效果暂停及换档；存储与玩家档案隔离。
var app: Control
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FINAL_APP_FAIL: " + message)
func frames(count := 4) -> void:
	for index in range(count): await process_frame
func click(control: Control) -> void:
	check(is_instance_valid(control) and control.is_visible_in_tree(), "真实点击目标可见")
	if not is_instance_valid(control): return
	var point := control.get_global_transform_with_canvas() * (control.size / 2)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed
		root.push_input(event)
		await process_frame
	await frames()
func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = pressed
		root.push_input(event)
	await frames()
func contained(control: Control) -> bool:
	return control != null and control.is_visible_in_tree() and app.display_surface.get_global_rect().grow(1).encloses(control.get_global_rect())
func drain() -> void:
	for index in range(1000):
		if app.session.mode != "narrative": return
		app.session.narrative.tick(100)
		if app.session.narrative.state.waiting_for_choice: return
		app.session.narrative.advance()
	check(false, "开场有界结束")
func capture(label: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture"): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://../.local/final-app-" + label + ".png")
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://final_app_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(8)
	app.settings_service.apply_window_enabled = false
	check(app.current_layer == "title" and app.title_page.visible, "正式标题初始化")
	check(app.gameplay_page.objectives.integration_errors.is_empty(), "目标配置无集成错误")
	await click(app.title_page.settings_button)
	check(app.current_layer == "subpage" and app.settings_page.visible, "标题打开设置")
	await click(app.settings_page.close_button)
	check(app.current_layer == "title" and app.title_page.visible, "设置返回原标题")
	await click(app.title_page.new_game_button)
	await click(app.confirm_page.accept_button)
	check(app.current_layer == "game" and app.session.mode == "narrative", "实际点击新游戏进入正文")
	drain()
	await frames(8)
	check(app.session.mode == "investigation" and app.session.initial_saved, "开场实际结束后生成初档")
	check(app.gameplay_page.tutorial.target_control() != null, "联合引导集成真实场景")
	await key(KEY_ESCAPE)
	check(app.current_layer == "pause", "调查教学期间Esc可暂停")
	await click(app.pause_page.settings_button)
	check(app.settings_page.visible and app.session.paused, "设置保持原游戏暂停")
	var slider: HSlider = app.settings_page.sliders.master_volume
	slider.grab_focus()
	var old_value := slider.value
	await key(KEY_LEFT)
	check(slider.value < old_value, "整机音量滑杆键盘调整")
	app.settings_page._switch_tab("display")
	app.settings_page.candidate_display = app.settings_service.confirmed_display()
	app.settings_page.candidate_display.aspect_ratio = 3
	app.settings_page._apply_display()
	await frames()
	check(app.settings_service.display_preview_active and app.settings_page.display_confirm.visible, "显示预览覆盖设置")
	await key(KEY_ESCAPE)
	check(app.settings_page.visible and not app.settings_service.display_preview_active and app.current_layer == "subpage", "Esc仅撤销显示预览")
	await click(app.settings_page.close_button)
	check(app.current_layer == "pause", "设置返回原暂停页")
	await key(KEY_ESCAPE)
	check(app.current_layer == "game" and not app.session.paused, "暂停原位恢复")
	var saved: Dictionary = app.session.export_snapshot()
	check(app.session.validate_snapshot(saved), "实际初档快照完整")
	for index in range(3):
		app._loaded(saved)
		await frames()
		check(app.current_layer == "game" and app.session.case_state.data.scene == saved.case_state.scene, "重复读取原档不残留页面")
	# 表现夹具只验表现生命周期，不冒称实际完成核查。
	var effect: Control = app.gameplay_page.result_effect
	effect.play({"effect_level":"progress", "duration_ms":3200})
	await frames()
	await click(effect.menu_button)
	check(app.current_layer == "pause" and effect.active, "演出中菜单保持当前效果")
	var paused_time: float = effect.elapsed_ms
	await frames(8)
	check(effect.elapsed_ms == paused_time, "暂停期间效果时钟不推进")
	await key(KEY_ESCAPE)
	await frames(8)
	check(app.current_layer == "game" and effect.elapsed_ms > paused_time, "恢复继续同一效果")
	effect.stop(false)
	app.session.processing = false
	# 所有页面共用同一有效区域，最小尺寸仍保留主要返回与确认。
	app._show_title()
	for ratio in [0, 1, 2, 3, 4]:
		app.settings_service.runtime_display.aspect_ratio = ratio
		app.settings_service._emit_display_area()
		await frames()
		check(contained(app.title_page.new_game_button), "比例%d标题按钮位于有效区" % ratio)
		await capture("title-ratio%d" % ratio)
		await click(app.title_page.settings_button)
		check(contained(app.settings_page.close_button), "比例%d设置返回位于有效区" % ratio)
		await capture("ratio%d" % ratio)
		await click(app.settings_page.close_button)
	root.size = Vector2i(960, 540)
	root.content_scale_size = Vector2i(960, 540)
	app.settings_service.runtime_display.aspect_ratio = 0
	app.settings_service._emit_display_area()
	await frames(8)
	await click(app.title_page.settings_button)
	check(contained(app.settings_page.close_button), "最小窗口设置返回可见")
	await capture("960-settings")
	app.queue_free()
	await frames(20)
	print("FINAL_APP_INTEGRATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
