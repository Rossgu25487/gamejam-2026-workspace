extends SceneTree
## 最终目标纸面与旧目标服务共用真实提供方，验证四比例布局、页签和无副作用关闭。
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FINAL_OBJECTIVE_FAIL: " + message)
func frames(count := 4) -> void:
	for i in range(count): await process_frame
func run() -> void:
	var s := preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(s)
	s.seen_storage_path = ""
	check(s.initialize(), "正式包载入")
	s.case_state.reset()
	s.mode = "investigation"
	s.case_state.data.chapter = "CH02"
	s.case_state.data.scene = "SC09"
	s.case_state.data.view = "VIEW_SC09_MAIN"
	s.case_state.data.events.EV_CH02_ENTER = true
	var objective := preload("res://systems/objective/objective_service.gd").new()
	root.add_child(objective)
	var definition: Dictionary = s.config.objective_definition()
	check(definition.final_paper and definition.hud.main_color == "#34413F", "最终语义参数映射到实际纸面组件")
	check(definition.hud.visible_item_limit == 1 and definition.hud.panel_max_height_px == 430, "HUD限制一条方向及430高")
	objective.configure(definition)
	objective.text_source = s.config.text
	var provider := preload("res://systems/aurora/aurora_objective_provider.gd").new()
	provider.bind(s)
	objective.bind_provider(provider)
	var host := Control.new()
	root.add_child(host)
	var hud := preload("res://pages/objective/objective_hud_page.gd").new()
	var review := preload("res://pages/objective/objective_review_page.gd").new()
	host.add_child(hud)
	host.add_child(review)
	hud.bind(objective)
	review.bind(objective)
	objective.refresh("initial")
	await frames()
	check(not objective.model.expanded, "HUD按最终表默认收起")
	check(hud.panel.get_theme_stylebox("panel") is StyleBoxTexture, "HUD使用正式连续纸面资源")
	# 入口可用性独立于事项正文版本，切换时仍需刷新HUD的唯一可执行方向。
	var directions := {"goal_id": "TEST_DIRECTIONS", "goal_text": "当前真实目标", "bases": {}, "items": []}
	for i in range(3):
		directions.items.append({"id": "D%d" % i, "order": i + 1, "text": "方向%d" % i, "status": "pending", "reason": "", "basis": [], "entry": {"id": "R%d" % i, "available": i > 0, "reason": ""}})
	objective.deliver(directions, "initial")
	objective.toggle_expanded()
	await frames()
	check(hud.blocks.size() == 1 and hud.blocks[0].get_meta("item_id") == "D1", "HUD仅显示首条可执行方向，跳过不可用入口")
	check(objective.review_view().pending.size() == 3, "回顾保留所有已公开事项")
	var content_revision: int = objective.model.content_revision
	directions.items[1].entry.available = false
	objective.deliver(directions, "result")
	await frames()
	check(objective.model.content_revision == content_revision and hud.blocks.size() == 1 and hud.blocks[0].get_meta("item_id") == "D2", "只有入口变化时更新当前可执行方向")
	directions.items[2].entry.available = false
	objective.deliver(directions, "result")
	await frames()
	check(hud.blocks.is_empty(), "无可执行入口时不编造方向")
	objective.toggle_expanded()
	objective.refresh("initial")
	var before: Dictionary = s.case_state.data.duplicate(true)
	check(objective.request_review() == "opened", "真实提供方可打开回顾")
	await frames()
	for extent in [Vector2(1600,900), Vector2(1440,900), Vector2(1200,900), Vector2(2100,900)]:
		root.size = Vector2i(extent)
		root.content_scale_size = Vector2i(extent)
		host.size = extent
		hud.size = extent
		review.size = extent
		review._apply_transform()
		hud._refresh()
		await frames()
		var local_rect := Rect2(Vector2.ZERO, extent)
		check(local_rect.encloses(review.paper_panel.get_global_rect()), "回顾纸面在有效区域：" + str(extent))
		check(local_rect.encloses(review.return_button.get_global_rect()), "返回按钮在有效区域：" + str(extent))
		check(review.pending_list.visible and not review.progress_list.visible, "待核与已有进展通过页签显示")
		check(not hud.visible, "回顾期间隐藏HUD")
		for action in review.pending_list.find_children("Go", "Button", true, false): check(action.size.x >= 150 and not action.text.is_empty(), "前往动作保留横向按钮与文字")
		if extent.x == 1200: check(review.main_list.position.x == review.pending_list.position.x, "4:3回顾单栏")
		else: check(review.main_list.position.x < review.pending_list.position.x, "常规与宽屏采用双栏")
		review._select_tab("progress")
		check(review.progress_list.visible and not review.pending_list.visible, "真实切换已有进展页签")
		review._select_tab("pending")
		if "--capture" in OS.get_cmdline_user_args():
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final_objective_%d.png" % extent.x))
		var doc := {"id": "LAYOUT_ONLY", "title": "调查记录及其完整的原始来源资料", "version_text": "第1版", "body": "此处显示已经公开的准确依据全文。".repeat(30), "sources": [{"id": "SOURCE_LAYOUT", "title": "现场记录的准确来源"}]}
		review._remember_position()
		review.reading.open(doc, false)
		await frames()
		for button in review.reading.find_children("*", "Button", true, false):
			if button.is_visible_in_tree(): check(review.paper_panel.get_global_rect().encloses(button.get_global_rect()) and button.get_theme_stylebox("normal") is StyleBoxTexture, "单份阅读操作保持在纸面内并使用四态资源")
		review.reading._push({"kind": "sources", "doc": doc, "scroll": 0})
		await frames()
		for button in review.reading.find_children("*", "Button", true, false):
			if button.is_visible_in_tree(): check(review.paper_panel.get_global_rect().encloses(button.get_global_rect()), "来源层导航保持在纸面内")
		review.reading.finish()
		await frames()
	objective.close_review()
	check(s.case_state.data == before, "回顾与切页关闭不改案件进度")
	print("FINAL_OBJECTIVE_UI_TEST: %d checks, %d failures" % [checks, failures.size()])
	host.free()
	objective.free()
	s.free()
	quit(0 if failures.is_empty() else 1)
