extends SceneTree
## 用最终真实配置验证热区、反条件、局部返回、镜头和多边形，不绕过页面的操作路径。
var failures: Array[String] = []
var checks := 0
var session: Node
var model: RefCounted
var page: Control

func _init() -> void: call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr(message)

func _run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	_check(session.initialize(), "最终配置可初始化")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset()
	session.mode = "investigation"
	model = preload("res://systems/aurora/aurora_investigation.gd").new()
	model.bind(session)
	session.case_state.data.scene = "SC09"
	session.case_state.data.view = "VIEW_SC09_MAIN"
	_check(model.image_layers().filter(func(row): return row.image_role == "background").size() == 1, "案前只选一个底图")
	_check("BG_SC09_BEFORE_CASE" in model.active_presentation_ids("VIEW_SC09_MAIN"), "反条件false选择案前底图")
	session.case_state.data.events["EV_CASE_INVESTIGATION_OPEN"] = true
	_check("BG_SC09_S6_BOTH_PRESENT" in model.active_presentation_ids("VIEW_SC09_MAIN"), "案后保留遗体和两件实物")
	session.case_state.data.events["EV_E03_EXAMINED"] = true
	_check("BG_SC09_S6_E03_TAKEN" in model.active_presentation_ids("VIEW_SC09_MAIN"), "酒壶实际收取事件切换唯一差分")
	_check(model.image_layers().filter(func(row): return row.image_role == "background").size() == 1, "差分切换不能叠加案前底图")
	var body: Array = model.hotspots().filter(func(row): return row.hotspot_id == "HS_SC09_BODY")
	_check(body.size() == 1 and model.inspect(body[0]), "遗体热点精确执行指定入口")
	_check(session.return_context.get("inspection_entry") == "ENTRY_CH02_SCENE" and session.mode != "investigation", "同物多观察不能替换为检查菜单")
	session.mode = "investigation"
	session.case_state.data.chapter = "CH01"
	session.case_state.data.scene = "SC06"
	session.case_state.data.view = "VIEW_SC06_MAIN"
	session.case_state.data.npc["CHR02"] = {"scene_id": "SC06"}
	var lorne: Array = model.hotspots().filter(func(row): return row.hotspot_id == "HS_EMB_SC06_LORNE")
	_check(lorne.size() == 1, "实际在场母图显示洛恩真实热区")
	if not lorne.is_empty():
		_check(model.contains_point(lorne[0], Vector2(820, 360)), "洛恩身体内部可命中")
		_check(not model.contains_point(lorne[0], Vector2(540, 320)), "矩形空白不可穿透多边形命中洛恩")
	_check(model.hotspots().all(func(row): return row.object_kind != "foreground_character"), "未显示近景不创建空坐标人物热区")
	var wide: Dictionary = model.view_transform("VIEW_SC11_MAIN", Vector2(1600, 900))
	_check(is_equal_approx(wide.offset, 400) and is_equal_approx(wide.maximum, 800), "连续车边镜头采用初始400及0到800范围")
	var narrow: Dictionary = model.view_transform("VIEW_SC05_MAIN", Vector2(1200, 900))
	_check(is_equal_approx(narrow.maximum, 400), "4比3下走廊按高度适配并可横移")
	var full: Dictionary = model.view_transform("VIEW_SC05_MAIN", Vector2(1600, 900))
	_check(is_zero_approx(full.maximum), "16比9走廊不生成虚假横移")
	var fixed: Dictionary = model.view_transform("VIEW_SC01_MAIN", Vector2(1200, 900))
	_check(is_equal_approx(fixed.scale, 0.75) and is_equal_approx(fixed.origin.y, 112.5), "fixed视图等比纳入并居中")
	session.narrative.end_reading()
	session.case_state.data.scene = "SC11"
	session.case_state.data.view = "VIEW_SC11_MAIN"
	session.return_context = {"kind": "scene", "scene": "SC11", "view": "VIEW_SC11_MAIN"}
	page = preload("res://pages/aurora/aurora_scene_page.gd").new()
	root.add_child(page)
	page.size = Vector2(1600, 900)
	page.bind(session)
	await process_frame
	await process_frame
	_check(is_equal_approx(page.view_offset_x, 400), "页面底图和热区共用初始镜头")
	var truck: Array = page.render_hotspots.filter(func(row): return row.hotspot_id == "HS_SC11_TRUCK")
	_check(truck.size() == 1, "车边真实驾驶室入口可见")
	if not truck.is_empty(): page._inspect(truck[0])
	await process_frame
	await process_frame
	_check(session.case_state.data.view == "VIEW_SC11_CABIN", "驾驶室只切同SC11局部")
	_check(page.find_child("ReturnPreviousView", true, false) != null, "每个局部具有可见返回按钮")
	_check(page.render_hotspots.all(func(row): return row.view_id == "VIEW_SC11_CABIN"), "局部只接收自身热区")
	page._back_view()
	await process_frame
	await process_frame
	_check(session.case_state.data.view == "VIEW_SC11_MAIN" and is_equal_approx(page.view_offset_x, 400), "返回恢复真实父视图和横移偏移")
	page._open_view("VIEW_SC11_CABIN")
	await process_frame
	page._open_view("VIEW_E08_DETAIL")
	await process_frame
	_check(page.current_context.parent_views.size() == 2, "容器内层保留逐层caller栈")
	page._back_view()
	await process_frame
	_check(session.case_state.data.view == "VIEW_SC11_CABIN", "从票据袋先返回驾驶室")
	page._back_view()
	await process_frame
	_check(session.case_state.data.view == "VIEW_SC11_MAIN", "第二次返回再到车边")
	_check(page.find_children("*", "Button", true, false).all(func(button): return button.text not in ["摸猫", "检查物件"]), "撤销旧常驻猫快捷入口和物件汇总目录")
	page.set_preferences({"aspect_ratio": 3})
	page.size = Vector2(1600, 900)
	await process_frame
	_check(is_equal_approx(page.canvas.size.x, 1200), "调查世界和UI消费4比3有效区域")
	# 柜台先实际完成反馈才进入局部，取消读字仍留在大厅。
	session.case_state.data.scene = "SC02"
	session.case_state.data.view = "VIEW_SC02_MAIN"
	session.mode = "investigation"
	page.current_context = {"kind": "scene", "scene": "SC02", "view": "VIEW_SC02_MAIN"}
	session.return_context = page.current_context.duplicate(true)
	page.refresh()
	await process_frame
	var counter: Array = model.hotspots().filter(func(row): return row.hotspot_id == "HS_SC02_COUNTER")
	_check(counter.size() == 1, "大厅柜台具有自身真实热区")
	if not counter.is_empty():
		page._inspect(counter[0])
		_check(session.case_state.data.view == "VIEW_SC02_MAIN", "柜台反馈未读完不能提前切局部")
		_check(session.cancel_inspection(), "局部反馈可以取消")
		await process_frame
		_check(session.case_state.data.view == "VIEW_SC02_MAIN", "取消柜台反馈留在父视图")
		page._inspect(counter[0])
		for i in range(100):
			if session.mode != "narrative": break
			session.narrative.tick(100)
			if session.narrative.state.waiting_for_choice: session.narrative.choose_transition(0)
			else: session.narrative.advance()
		await process_frame
		_check(session.case_state.data.view == "VIEW_SC02_COUNTER", "柜台反馈完成后实际进入柜台局部")
		_check(page.render_hotspots.all(func(row): return row.view_id == "VIEW_SC02_COUNTER"), "柜台局部只启用电话、登记簿、杯等自己的热区")
	print("FINAL_INVESTIGATION ", failures.is_empty(), " checks=", checks)
	page.queue_free()
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
