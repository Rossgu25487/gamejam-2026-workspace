extends SceneTree
## 在正式主场景保留引导遮罩，以真实鼠标依次完成单卡和双卡操作。
var app: Control
var failures: Array[String] = []
var checks := 0
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("T00_INPUT_FAIL: " + message)
func frames(count := 6) -> void:
	for index in range(count): await process_frame
func click_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point; motion.global_position = point
	root.push_input(motion); await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point; event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT; event.pressed = down
		root.push_input(event); await process_frame
	await frames()
func click_target() -> void:
	var tutorial: Node = app.gameplay_page.tutorial
	var target: Control = tutorial.target_control()
	check(is_instance_valid(target), "引导目标有真实可见控件：" + str(tutorial.current_step))
	if not is_instance_valid(target): return
	var point := target.get_global_transform_with_canvas() * (target.size / 2)
	var picked: Control = tutorial.actual_hit_control(app.gameplay_page, point)
	print("T00_HIT target=", target.get_path(), " point=", point, " picked=", picked.get_path() if picked != null else "null", " allowed=", tutorial.permits_control(picked))
	await click_at(point)
func run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://t00_input_%d" % Time.get_ticks_usec()
	root.add_child(app); await frames(10)
	app.settings_service.apply_window_enabled = false
	check(app.debug_new_game(), "正式新游戏初始化")
	if "--recovery" in OS.get_cmdline_user_args():
		await old_save_recovery()
	else:
		# 正常贯通不预发材料、不写入事件；全部沿公开画面与真实输入取得。
		await opening_to_t00()
	Input.set_custom_mouse_cursor(null, Input.CURSOR_POINTING_HAND)
	app.queue_free(); await frames(12)
	print("FINAL_T00_INPUT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func button_text(parent: Node, value: String) -> Button:
	for child in parent.get_children():
		if child is Button and child.is_visible_in_tree() and child.text == value: return child
		var found := button_text(child, value)
		if found != null: return found
	return null

func click_control(control: Control) -> void:
	check(is_instance_valid(control) and control.is_visible_in_tree(), "正常流程有真实按钮")
	if is_instance_valid(control):
		var ancestor := control.get_parent()
		while ancestor != null:
			if ancestor is ScrollContainer: ancestor.ensure_control_visible(control); await frames()
			ancestor = ancestor.get_parent()
		await click_at(control.get_global_transform_with_canvas() * (control.size / 2))

func drain_reading() -> void:
	for index in range(140):
		if app.session.mode != "narrative" or app.session.narrative.state.get("waiting_for_choice", false): break
		app.session.narrative.tick(100)
		await click_at(app.display_surface.get_global_rect().position + app.display_surface.size * Vector2(0.5, 0.82))
	await frames()
	print("DRAIN mode=", app.session.mode, " entry=", app.session.active_entry, " scene=", app.session.case_state.data.scene, " question=", app.session.question, " reader=", app.session.reader, " step=", app.gameplay_page.tutorial.current_step)

func opening_to_t00() -> void:
	var session: Node = app.session
	await drain_reading()
	await click_target() # 站名牌
	await drain_reading()
	await click_control(app.gameplay_page.scene_page.hotspot_buttons.get("HS_SC01_DOOR"))
	await drain_reading()
	check(session.narrative.state.get("waiting_for_choice", false), "接待结束实际显示选项")
	var choices: Array = session.narrative.available_choices
	check(choices.size() == 1 and not session.choice_label(choices[0]).contains("SC02"), "接待选项不显示内部场景编号")
	if choices.is_empty(): return
	await click_control(button_text(app.gameplay_page.narrative_page, session.choice_label(choices[0])))
	check(session.mode == "investigation" and session.case_state.data.scene == "SC02", "接待结束留在大厅打开地图")
	check(not app.gameplay_page.scene_page.hotspot_buttons.has("HS_SC02_REGISTER"), "取得清单前不开放会提前锁死的核档入口")
	await click_control(app.gameplay_page.scene_page.find_child("MapEntry", true, false))
	await frames(12)
	for index in range(3): await click_target()
	# 正式地图动画以实际页面时钟完成，不替业务调用travel。
	for index in range(150):
		if not app.gameplay_page.map_page.visible: break
		app.gameplay_page.map_page._process(0.2)
		await frames(2)
	check(session.case_state.data.scene == "SC06", "首次地图真实前往休息室")
	await drain_reading()
	var scene: Control = app.gameplay_page.scene_page
	print("SC06_HOTSPOTS ", scene.hotspot_buttons.keys())
	await click_control(scene.hotspot_buttons.get("HS_SC06_CHECKLIST"))
	await drain_reading()
	check(session.mode == "material", "完整对白后打开移交清单原件")
	if session.mode != "material": return
	await click_control(button_text(app.gameplay_page.reader_page, "已读完这份原件"))
	# 首张成卡使用实际页时钟播放完，不能伪造已持有或已读事件。
	for index in range(180):
		if app.gameplay_page.tutorial.feedback_left <= 0 and not app.gameplay_page.acquisition_feedback.active: break
		app.gameplay_page.tutorial._process(0.2)
		app.gameplay_page.acquisition_feedback._process(0.2)
		await frames(2)
	await drain_reading()
	check(session.case_state.owns("E01_V1") and session.case_state.data.events.get("EV_E01_READ", false), "真实阅读取得清单并提交已读")
	print("BEFORE_RETURN ", session.mode, " context=", scene.current_context)
	await click_control(scene.find_child("MapEntry", true, false))
	await frames(10)
	for node in app.gameplay_page.map_page.find_children("*", "Button", true, false):
		if node.get_meta("tutorial_target", "") == "map.view_map01": await click_control(node); break
	await frames(8)
	var destination: Button
	for node in app.gameplay_page.map_page.find_children("*", "Button", true, false):
		if node.is_visible_in_tree() and node.get_meta("scene_id", "") == "SC02" and not node.disabled: destination = node; break
	await click_control(destination)
	await click_control(button_text(app.gameplay_page.map_page, "前往"))
	for index in range(150):
		if not app.gameplay_page.map_page.visible: break
		app.gameplay_page.map_page._process(0.2); await frames(2)
	await drain_reading()
	check(session.mode == "material" and session.reader.get("content") == "E28_V1", "返回大厅自动接核档并打开实际内页")
	if session.mode != "material": return
	await click_control(button_text(app.gameplay_page.reader_page, "已读完这份原件"))
	await drain_reading()
	check(session.mode == "selection" and session.question == "T00_R01", "读完内页才进入第一轮")
	for index in range(3): await click_target()
	check(session.pending_result.get("complete", false), "第一轮沿真实UI成立")
	await finish_effect()
	await click_control(button_text(app.gameplay_page.card_page, "阅读完整回应"))
	await drain_reading()
	if session.mode == "result":
		await click_control(button_text(app.gameplay_page.card_page, "继续"))
		await drain_reading()
	check(session.mode == "selection" and session.question == "T00_R02", "完整回应后自动进入双卡问题")
	# 恢复旧草稿曾展开材料库、填过搜索时，也必须指向能选用的真实卡牌。
	var cards: Control = app.gameplay_page.card_page
	cards.grid_mode = true; cards.category = "inference"; cards.search_text = "不存在的名称"
	cards.refresh(); await frames(12)
	check(not cards.grid_mode and is_instance_valid(app.gameplay_page.tutorial.target_control()), "教学从旧展开库筛选恢复到可选手牌")
	await click_target()
	check(session.slots.has("E01_V1"), "双卡清单真实入槽")
	var partial: Dictionary = session.export_snapshot()
	check(app.debug_load_snapshot(partial), "双卡入一张的真实草稿可读档")
	await frames(12)
	check(session.mode == "selection" and session.slots.has("E01_V1") and app.gameplay_page.tutorial.current_step.get("target_ref") == "E28_V1", "读档继续指向缺少的第二张")
	await click_control(cards.find_child("WithdrawSlot0", true, false))
	check(session.slots.all(func(id): return str(id).is_empty()), "教学允许图标撤下并恢复选卡")
	await click_target(); await click_target()
	check(session.slots.has("E01_V1") and session.slots.has("E28_V1"), "撤回后两张材料可以重新入槽")
	await click_control(cards.find_child("WithdrawSlot1", true, false))
	check(session.slots.has("E01_V1") and not session.slots.has("E28_V1"), "出示前仍可撤回第二张材料")
	await click_target(); await click_target()
	check(session.mode == "result" and session.pending_result.get("complete", false), "第二轮双卡沿真实UI出示成功")
	check(not session.case_state.owns("P06_V1"), "出示与演出不会提前发放待收推论")
	await finish_effect()
	await click_control(button_text(cards, "阅读完整回应"))
	await drain_reading()
	check(session.pending_result.get("response_read", false), "第二轮回应完整读完")
	await click_target()
	check(session.case_state.owns("P06_V1"), "实际点击收下才获得登记册归档项")
	await finish_effect()
	await drain_reading()
	check(session.case_state.data.events.get("EV_T00_COMPLETED", false), "真实完成双卡核档事件")
	check(app.gameplay_page.tutorial.completed({"group_id":"TUT_COLLECT", "step":1}), "归位结束完成推论收下引导")
	check(session.active_entry.begins_with("ENTRY_PLANNER_FREIGHT") or session.mode == "material", "核档收尾继续到货单交接")
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/t00-route-complete.png")

func finish_effect() -> void:
	var effect: Control = app.gameplay_page.result_effect
	for index in range(90):
		if not effect.active: break
		effect._process(0.2); await frames(2)
	check(not effect.active and not app.session.processing, "实际演出播放到结束并解锁")

func old_save_recovery() -> void:
	var session: Node = app.session
	# 仅此旧档兼容夹具构造历史卡点；正式贯通分支不修改材料、事件或问答状态。
	session.narrative.end_reading()
	session.set_scene("SC02")
	session.case_state.grant("E28_V1", {})
	session.case_state.data.events.EV_T00_INNER_READ = true
	session.case_state.data.events.EV_T00_YEAR_CONFIRMED = true
	session.case_state.data.events.EV_CH01_TEA_READY = true
	session.question = "T00_R02"
	session.current_statement = "TXT_QUESTION_T00_R02"
	session.selected_target = true
	session.active_entry = "ENTRY_T00_R02"
	session.mode = "selection"
	session.return_context = {"kind":"scene", "scene":"SC02", "view":"VIEW_SC02_MAIN"}
	session.case_state.data.chances.T00_R02 = 3
	session.case_state.data.drafts.T00_R02 = {"target":true, "current_statement":"TXT_QUESTION_T00_R02", "slots":["E28_V1", ""]}
	session.slots = ["E28_V1", ""]
	var old_save: Dictionary = session.export_snapshot()
	check(session.validate_snapshot(old_save), "历史缺清单卡点仍是合法存档形状")
	check(app.debug_load_snapshot(old_save), "通过正式读档入口加载历史卡点")
	await frames(12)
	check(session.mode == "investigation" and app.gameplay_page.tutorial.current_step.is_empty(), "旧档回到调查且解除缺牌教学锁定")
	check(not session.case_state.owns("E01_V1") and session.case_state.owns("E28_V1"), "恢复不补造清单并保留已取得内页")
	check(session.case_state.data.drafts.T00_R02.slots.has("E28_V1"), "历史核对草稿保留")
	check(not session.case_state.data.completed_questions.has("T00_R02") and not session.case_state.owns("P06_V1"), "恢复不伪造完成或发放推论")
	check(session.scene_status("SC06").available, "旧档仍能按地图去休息室补取清单")
	# 听完第一轮但尚未进入第二轮的旧中间档，同样安全退出缺材操作。
	check(session.activate_entry("ENTRY_T00_R02"), "旧回应后续缺材时能安全返回调查")
	check(session.mode == "investigation", "进入双卡前再核查实际持有")
	check(not session.activate_entry("ENTRY_T00_START"), "清单未读前不能从其他旧入口重新进入核档")
	check(not session.open_question("T00_R02") and session.mode == "investigation", "直接旧问题入口同样不会重新锁定")
