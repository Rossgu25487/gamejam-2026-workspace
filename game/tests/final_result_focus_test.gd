extends SceneTree
## 核验从选牌切到结果后，焦点回调不得再访问已经销毁的手牌节点。
var session: Node
var page: Control
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("RESULT_FOCUS_FAIL: " + message)
func frames(count := 5) -> void:
	for index in range(count): await process_frame
func click(control: Control) -> void:
	check(is_instance_valid(control) and control.is_visible_in_tree(), "实际按钮可见")
	if not is_instance_valid(control): return
	var point := control.get_global_transform_with_canvas() * (control.size / 2)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event); await process_frame
	await frames()
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session); session.seen_storage_path = ""
	check(session.initialize(), "正式包加载")
	session.run_id = "result-focus-test"
	session.case_state.reset(); session.set_scene("SC02")
	# 本专项隔离核验页面生命周期：只准备两张真实内容版，不伪造结果回执。
	session.case_state.grant("E28_V1", {})
	session.case_state.grant("E01_V1", {})
	# 材料已读前置作为隔离夹具；真实判定、回应与发卡仍由会话执行。
	session.case_state.data.events["EV_T00_INNER_READ"] = true
	session.case_state.data.events["EV_E01_READ"] = true
	session.active_entry = str(session.config.questions.T00_R01.entry_ref)
	check(session.open_question("T00_R01"), "打开正式首轮核验")
	for index in range(40):
		if session.mode != "narrative": break
		session.narrative.tick(100); session.narrative.advance()
	check(session.mode == "selection", "进入真实选材状态")
	page = preload("res://pages/aurora/aurora_card_page.gd").new()
	root.add_child(page); page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session); page.refresh(); await frames()
	check(page.card_buttons.size() == 2, "核验手牌显示真实持有材料")
	var target: Control = page.find_child("TargetStatement", true, false)
	await click(target)
	var card: Control = page.find_child("Card_E28_V1", true, false)
	check(is_instance_valid(card), "正式内页卡可见")
	if is_instance_valid(card):
		card.grab_focus(); await frames()
		await click(card)
	check(not page.focus_content.is_empty(), "选材时记录实际手牌焦点")
	await click(page.find_child("PresentMaterials", true, false))
	check(session.mode == "result", "真实出示进入核验结果")
	check(session.pending_result.get("complete", false), "本次核验确实成立")
	await frames(8)
	check(page.card_buttons.is_empty(), "结果页面不保留已销毁的手牌引用")
	check(not is_instance_valid(page.hand_area) and not is_instance_valid(page.card_scroll), "结果页面清除选材区节点引用")
	# 结果演出结束及其他changed都会再画一次结果页，复现第二次焦点恢复。
	session.finish_result_effect(); await frames(8)
	page.refresh(); await frames(8)
	check(page.card_buttons.is_empty(), "结果刷新仍无旧手牌")
	page._restore_card_focus(); page._restore_library_focus()
	await frames()
	check(is_instance_valid(page.find_child("ContinueResult", true, false)) or not page.find_children("*", "Button", true, false).is_empty(), "核验后保留结果操作入口")
	# 从结果返回选材后，新的手牌应能重新取得焦点。
	check(session.open_question("T00_R01"), "重新打开未提交结果的原核验")
	await frames(8)
	check(session.mode == "selection" and page.card_buttons.size() == 2, "返回选材重建当前手牌")
	var current_card: Control = page.find_child("Card_E28_V1", true, false)
	if is_instance_valid(current_card):
		current_card.grab_focus(); await frames()
		check(root.gui_get_focus_owner() == current_card, "新手牌可正常接收焦点")
	session.clear_slot(0); session.clear_slot(1); await frames()
	check(session.select_target() and session.select_content("E01_V1"), "准备材料不足的真实出示")
	await frames()
	await click(page.find_child("PresentMaterials", true, false))
	check(session.pending_result.get("feedback") == "insufficient", "不足结果也实际走判定")
	await frames(8); page.refresh(); await frames(8)
	check(page.card_buttons.is_empty(), "不足结果刷新不会保留旧手牌")
	page._restore_card_focus()
	check(session.continue_result(), "不足结果可重新选材")
	await frames(8)
	check(session.mode == "selection" and page.card_buttons.size() == 2, "不足结果返回后重建手牌")
	# 快速换成失败页同样丢弃选材节点，滞后回调不得抢走重试按钮焦点。
	session.mode = "failure"; session.changed.emit(); await frames(8)
	check(page.card_buttons.is_empty(), "失败页也清理旧手牌引用")
	page._restore_card_focus(); page._restore_library_focus()
	page.queue_free(); session.queue_free(); await frames(10)
	print("FINAL_RESULT_FOCUS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
