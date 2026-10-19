extends SceneTree
## 真实快捷键切换全局工具；覆盖层不推进原对白，也不允许从核查跨地点。
var checks := 0
var failures: Array[String] = []
var session: Node
var page: Control
func _init() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); printerr("FINAL_TOOL_FAIL: " + label)
func frames(count := 5) -> void:
	for index in range(count): await process_frame
func key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = pressed
		root.push_input(event)
	await frames()
func button_named(node: Node, caption: String) -> Button:
	if node is Button and node.text == caption: return node
	for child in node.get_children():
		var found := button_named(child, caption)
		if found != null: return found
	return null
func click(control: Control) -> void:
	var point := control.get_global_transform_with_canvas() * (control.size / 2)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed
		root.push_input(event)
		await process_frame
	await frames()
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session); session.seen_storage_path = ""
	check(session.initialize(), "加载正式配置")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset(); session.run_id = "tools"
	session.set_scene("SC02"); session.mode = "investigation"
	var bridge := preload("res://systems/aurora/aurora_map_bridge.gd").new()
	root.add_child(bridge); bridge.bind(session)
	var map := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(map); map.bind_core(bridge); map.configure(bridge.definition()); map.initialize("SC02")
	page = preload("res://pages/aurora/aurora_gameplay_page.gd").new()
	root.add_child(page); page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session, map); page.set_active(true)
	await frames()
	# 准备一个正在逐字显示的真实文本，工具关闭后仍回同一句。
	check(session.narrative.show_text("F7_CH01_AFTER_E01_READ_001"), "显示正式正文")
	if session.narrative.state.is_empty(): quit(1); return
	session.mode = "narrative"; page.refresh(); await frames()
	var current: String = session.narrative.state.current_text_id
	var records_button := button_named(page.narrative_page, "对白记录")
	check(records_button != null, "正文有可见对白记录入口")
	if records_button == null: quit(1); return
	await click(records_button)
	check(page.tool_kind == "records" and page.reader_page.visible and session.narrative.reading_log, "实际点击记录进入独立记录并冻结正文")
	check(not page.reader_page.z_as_relative and page.reader_page.z_index > page.narrative_page.z_index, "对白记录模态层位于对白框之上")
	page._finish_tool()
	await frames(2)
	check(not session.narrative.reading_log and page.narrative_page.stage.visible, "共享工具关闭后恢复对白舞台")
	await key(KEY_ESCAPE)
	check(not page.reader_page.visible and session.narrative.state.current_text_id == current, "记录按钮打开后Esc返回原句")
	await key(KEY_L)
	check(page.tool_kind == "records" and page.reader_page.visible and page.reader_page.tab == "records", "L打开独立对白记录")
	var count: int = session.narrative.state.visible_characters
	await key(KEY_H); await key(KEY_SPACE)
	check(not session.narrative.hidden and session.narrative.state.current_text_id == current and session.narrative.state.visible_characters == count, "记录独占H和推进键")
	await key(KEY_I)
	check(page.tool_kind == "handbook" and page.reader_page.visible and page.reader_page.tab == "materials", "I替换记录为手册")
	page.reader_page.category = "evidence"
	await key(KEY_J)
	check(page.objective_page.visible and not page.reader_page.visible and session.narrative.reading_log, "J替换手册为目标回顾并冻结正文")
	var rows: Dictionary = page.objectives.review_view()
	for row in rows.pending:
		if not row.entry.is_empty(): check(not row.entry.available, "对白父状态不能借目标前往")
	await key(KEY_I)
	check(page.reader_page.visible and not page.objective_page.visible and page.reader_page.category == "evidence", "工具切回保留筛选")
	await key(KEY_L)
	check(page.reader_page.tab == "records" and not page.objective_page.visible, "手册切回独立记录")
	await key(KEY_L)
	check(not page.reader_page.visible and not page.objective_page.visible and not session.narrative.reading_log, "同键关闭回同父状态")
	check(session.mode == "narrative" and session.narrative.state.current_text_id == current, "工具返回未推进正文")
	await key(KEY_M)
	check(not page.map_page.visible, "普通对白禁止地图")
	# 回调查后，地图与工具只保留一个可见覆盖层。
	session.narrative.end_reading(); session.mode = "investigation"; page.refresh(); await frames()
	await key(KEY_I); await key(KEY_M)
	check(page.map_page.visible and not page.reader_page.visible, "调查地图替换手册")
	await key(KEY_L)
	check(page.reader_page.visible and not page.map_page.visible, "记录替换稳定地图")
	var input := LineEdit.new()
	page.reader_page.add_child(input); input.grab_focus(); await frames()
	await key(KEY_J)
	check(page.tool_kind == "records" and not page.objective_page.visible, "文本输入焦点不触发字母工具键")
	input.release_focus(); input.queue_free(); await frames(); await key(KEY_ESCAPE)
	check(not page.reader_page.visible, "Esc关闭当前记录")
	session.narrative.end_reading(); session.mode = "investigation"; page.refresh(); await frames()
	page.context_present_page.open_for_actor("CHR03")
	await frames(); await key(KEY_I)
	check(page.context_present_page.visible and not page.reader_page.visible, "情境出示层禁止旁开手册")
	page.context_present_page.close()
	page.set_active(false); await key(KEY_I)
	check(not page.reader_page.visible, "暂停后不缓存工具请求")
	page.queue_free(); map.queue_free(); bridge.queue_free(); session.queue_free()
	await frames(15)
	print("FINAL_TOOL_ROUTING %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
