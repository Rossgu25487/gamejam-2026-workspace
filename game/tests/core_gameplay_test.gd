extends SceneTree
## 核心策划回归：所有写档使用独立临时目录，验证业务状态而非标签文案。

const Session = preload("res://systems/core_gameplay/game_session_service.gd")
const Save = preload("res://systems/save_load/save_load_service.gd")
var failures: Array[String] = []
var checks := 0
var services: Array[Node] = []
var auto_requests := 0
var folder := "user://core-regression/%d" % Time.get_ticks_usec()

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, detail: String) -> void:
	checks += 1
	if not ok:
		failures.append(detail)
		printerr("CORE_CHECK_FAILED: " + detail)

func new_session() -> Node:
	var session := Session.new()
	root.add_child(session)
	services.append(session)
	expect(session.initialize(), "配置有效：" + str(session.core.catalog.errors))
	session.start_new_game()
	return session

func ref(core: Node, id: String) -> Dictionary:
	return core.catalog.material_ref(id)

func acquire_entry(core: Node, id: String) -> void:
	expect(core.activate_entry(id), "合法取得入口：" + id)
	core.finish_dialogue()

func open_question(core: Node, id: String = "Q1") -> void:
	expect(core.open_card_session(id), "问题可打开：" + id)
	if core.draft().get("target_ref", {}).get("target_kind") == "statement": core.select_target()

func settle(core: Node) -> void:
	core.finish_presentation()

func _run() -> void:
	var session := new_session()
	var core: Node = session.core
	expect(core.store.entities.is_empty() and core.state.drafts.is_empty(), "新案件为空集合和空草稿")
	expect(not core.open_card_session("Q1"), "未听目标不能进入")
	expect(not core.open_card_session("Q2"), "后问不能提前开放")
	expect(core.can_save(), "初始调查允许保存")
	expect(core.catalog.rules["错误出示"].is_empty(), "禁用错误模板和test数据不导入")
	expect(core.ui("UI_CORE_PRESENT") != "UI_CORE_PRESENT", "固定文字读取唯一源")
	# 直接新版取得不能授予旧版；后来取得旧版不倒退最高版本。
	acquire_entry(core, "UPDATE")
	expect(core.store.entities.A.acquired_content_ids == ["A2"], "新版不会补发旧版")
	acquire_entry(core, "INSPECT")
	expect(core.store.entities.A.current_content_id == "A2", "后来取得旧版不覆盖最高版本")
	core.mark_read(ref(core,"A1"))
	expect(core.store.marker("A") == "更新", "读旧版不清新版更新")
	core.mark_read(ref(core,"A2"))
	expect(core.store.marker("A") == "", "读当前版本清除标记")
	acquire_entry(core, "TALK")
	expect(core.store.entities.size() == 7, "超过五份材料完整保留")
	var source_count: int = core.store.sources(ref(core,"A1")).size()
	var order: int = core.store.entities.A.acquire_index
	acquire_entry(core, "INSPECT")
	expect(core.store.sources(ref(core,"A1")).size() == source_count and core.store.entities.A.acquire_index == order, "重复路径不新增来源或序号")
	expect(core.open_card_session("Q1"), "合法人物问题入口")
	expect(not core.draft().target_selected and core.draft().slots == [null,null], "人物问题首次目标未选两槽为空")
	expect(not core.can_present(), "缺目标或材料不能出示")
	core.select_target()
	expect(core.select_material(ref(core,"A1")), "选用实际旧版")
	expect(not core.select_material(ref(core,"A2")), "同材料两个版本不能占两槽")
	core.select_material(ref(core,"B1"))
	expect(not core.select_material(ref(core,"OTHER1")), "第三张不能自动替换")
	core.withdraw_material(0)
	expect(core.draft().slots[0] == null and core.draft().slots[1] == ref(core,"B1"), "撤左槽右槽不移动")
	core.select_material(ref(core,"A1"))
	expect(core.draft().slots[0] == ref(core,"A1"), "最左空槽先填")
	var before_talk: Dictionary = core.draft()
	expect(core.activate_entry("TALK"), "选材可直接普通问话")
	core.finish_dialogue()
	expect(core.state.mode == "selection" and core.draft() == before_talk, "普通问话返回同问且保留精确两槽")
	core.set_grid(true)
	core.update_view({"type":"evidence","sort":"type","important_only":true})
	var draft_before: Dictionary = core.draft()
	core.fold_card_selection()
	core.open_card_session("Q1")
	expect(core.draft() == draft_before and core.state.card_ui_page == "grid", "同问恢复精确草稿与网格")
	var selection_snapshot: Dictionary = session.export_snapshot()
	expect(session.validate_snapshot(selection_snapshot), "稳定选材完整快照可验证")
	var saved_json: Dictionary = JSON.parse_string(JSON.stringify(selection_snapshot))
	expect(session.restore_snapshot(saved_json), "JSON往返恢复完整联合快照")
	expect(core.draft() == draft_before, "读档不替换旧版出示")
	var broken: Dictionary = selection_snapshot.duplicate(true)
	broken.card_snapshot.erase("deducted_attempts")
	var preserved: Dictionary = core.export_card_state()
	expect(not session.restore_snapshot(broken) and preserved == core.export_card_state(), "损坏新版拒绝且不替换当前会话")
	var invalid_catalog: Dictionary = core.catalog.data.duplicate(true)
	invalid_catalog.relations.R_ONE.basis_results = [{"relation_id":"R_ONE","target_ref":core.target_for("Q1")}]
	var probe_catalog = load("res://systems/core_gameplay/core_catalog.gd").new()
	expect(not probe_catalog.configure(invalid_catalog), "循环来源配置拒绝接入")
	invalid_catalog = core.catalog.data.duplicate(true)
	invalid_catalog.relations.R_TWO.climax_key = "DIFFERENT"
	expect(not probe_catalog.configure(invalid_catalog), "等价解法业务或高潮冲突拒绝接入")
	broken = selection_snapshot.duplicate(true)
	broken.navigation_snapshot.state_revision += 1
	expect(not session.validate_snapshot(broken), "卡牌和导航版本必须一致")
	broken = selection_snapshot.duplicate(true)
	broken.card_snapshot.drafts.Q1.slots[0].content_id = "UNACQUIRED"
	expect(not session.validate_snapshot(broken), "未取得或缺失的槽内版本拒绝恢复")
	# 双卡换序依旧充分。待收、阅读、收下都不请求自动保存。
	core.autosave_requested.connect(func(): auto_requests += 1)
	var result: Dictionary = core.present_materials("two-attempt")
	expect(result.get("relation_id") == "R_TWO" and core.state.mode == "pending", "双卡换序充分且进入待收")
	expect(not core.store.owns(ref(core,"I1")) and "Q1" not in core.state.completed_questions, "待收不拥有不确认")
	expect(not core.can_save() and not core.begin_inspection(), "主演出阶段禁存禁检视")
	settle(core)
	var pending_snapshot: Dictionary = session.export_snapshot()
	expect(session.restore_snapshot(JSON.parse_string(JSON.stringify(pending_snapshot))) and core.state.mode == "pending" and not core.presenting, "待收快照恢复稳定全文不重播")
	expect(core.begin_inspection(), "待收稳定可检视")
	core.end_inspection()
	expect(not core.continue_result(), "待收不能继续绕过收下")
	var frozen: Array = core.state.current_result.used_sources.duplicate(true)
	# 测试另一真实取得入口，旧成果递归快照保持不变。
	core.catalog.data.entries["SECOND_PATH"] = {"condition":"ALWAYS","contents":["A1"],"source_id":"SRC_SECOND","object_id":"TABLE","text":core.catalog.data.entries.INSPECT.text}
	expect(core.acquire_material("A1","SECOND_PATH","SRC_SECOND"), "另一真实路径追加")
	expect(core.store.sources(ref(core,"A1")).size() == source_count + 1, "普通材料显示新路径")
	expect(core.state.current_result.used_sources == frozen, "形成时实际来源逐层冻结")
	expect(core.collect_inference(result.result_id,"I1"), "主动收下整体提交")
	expect(core.store.entities.size() == 8 and "Q1" in core.state.completed_questions and core.state.current_statements.Q1 == "S2", "拥有更正确认解锁同时提交")
	expect(not core.can_save() and auto_requests == 0, "收下未继续仍禁存且没有自动保存")
	settle(core)
	expect(core.collect_inference(result.result_id,"I1"), "重复收卡回调幂等")
	var collected_snapshot: Dictionary = session.export_snapshot()
	expect(session.restore_snapshot(collected_snapshot) and core.state.mode == "collected" and not core.presenting, "已收快照恢复不重发卡或重播")
	expect(core.store.entities.size() == 8 and core.state.confirmed_results.size() == 1 and core.state.applied_group_ids.size() == 1, "重复收下不重发不重确认")
	expect(core.store.sources(ref(core,"I1")) == frozen, "推论永久来源保持形成时集合")
	expect(core.continue_result(), "已收正常继续")
	expect(auto_requests == 1 and core.can_save() and not core.state.drafts.has("Q1"), "正常返回才发一次自动档并清草稿")
	open_question(core, "Q2")
	expect(core.draft().target_selected and core.draft().slots == [null,null], "自主推理自动选目标且两槽为空")
	core.select_material(ref(core,"B1")); core.select_material(ref(core,"I1"))
	var followup: Dictionary = core.present_materials()
	expect(followup.get("used_sources", []).size() == 3 and followup.used_sources[-1].kind == "confirmed", "前次确认作为冻结来源而非第三槽")
	settle(core)
	expect("Q2" not in core.state.completed_questions, "支持事实在继续之前不提交")
	expect(core.continue_result() and "Q2" in core.state.completed_questions, "继续时提交支持确认")
	expect(auto_requests == 2, "第二次成功正常返回请求一次自动档")
	var completed_snapshot: Dictionary = session.export_snapshot()
	expect(session.restore_snapshot(completed_snapshot), "完成状态恢复")
	core.open_card_session("Q1")
	expect(core.state.mode == "response" and core.state.current_result.get("replay"), "已完成问题只回看")
	expect(not core.presenting and core.store.entities.size() == 8, "重复成果不重播高潮不发卡")
	core.continue_result()
	expect(auto_requests == 2, "重复回看正常返回不额外自动保存")
	# 独立新案件覆盖单份充分、局部主动补充、默认不足、扣次、失败、重试。
	var single_session := new_session()
	var single: Node = single_session.core
	acquire_entry(single,"UPDATE"); acquire_entry(single,"INSPECT"); acquire_entry(single,"TALK")
	open_question(single)
	single.select_material(ref(single,"OTHER1")); single.select_material(ref(single,"A2"))
	var one: Dictionary = single.present_materials()
	expect(one.get("relation_id") == "R_ONE" and one.used_sources.size() == 1 and int(single.state.chances.Q1) == 3, "单份充分忽略无关第二张且不扣次")
	var partial_session := new_session()
	var partial: Node = partial_session.core
	acquire_entry(partial,"INSPECT"); acquire_entry(partial,"TALK")
	open_question(partial)
	partial.select_material(ref(partial,"A1"))
	var p: Dictionary = partial.present_materials()
	expect(p.get("feedback") == "partial" and int(partial.state.chances.Q1) == 3, "局部不扣次不完成")
	settle(partial)
	var supplement: Dictionary = partial.supplement_source("B1")
	expect(supplement.get("feedback") == "full" and partial.state.mode == "pending", "玩家主动补入实际版本后重新匹配")
	var error_session := new_session()
	var error_core: Node = error_session.core
	acquire_entry(error_core,"INSPECT"); acquire_entry(error_core,"TALK")
	open_question(error_core)
	error_core.select_material(ref(error_core,"EXTRA11"))
	expect(error_core.present_materials().get("feedback") == "insufficient" and int(error_core.state.chances.Q1) == 3, "默认不足不扣容错")
	settle(error_core)
	error_core.continue_result("reselect")
	error_core.withdraw_material()
	error_core.select_material(ref(error_core,"OTHER1"))
	for i in range(3):
		var attempt := "error-%d" % i
		var e: Dictionary = error_core.present_materials(attempt)
		expect(e.get("feedback") == "incorrect" and int(error_core.state.chances.Q1) == 2-i, "明确错误扣一次："+str(i))
		error_core.present_materials(attempt)
		expect(int(error_core.state.chances.Q1) == 2-i, "重复尝试不重复扣次")
		settle(error_core)
		if i < 2: error_core.continue_result("reselect")
	expect(error_core.state.mode == "failure" and not error_core.can_save() and not error_core.continue_result(), "归零失败禁存禁成功继续")
	expect(error_core.continue_result("defer") and error_core.can_save(), "失败返回调查后允许保存零次状态")
	var zero_snapshot: Dictionary = error_session.export_snapshot()
	expect(error_session.restore_snapshot(zero_snapshot) and int(error_core.state.chances.Q1) == 0, "合法调查档恢复零次及扣次记录")
	error_core.open_card_session("Q1")
	expect(error_core.state.mode == "failure" and int(error_core.state.chances.Q1) == 0, "重入不补次数")
	expect(error_core.state.current_result.get("reason_text_id") == error_core.catalog.data.relations.R_ERROR.reason, "失败重入保留实际原因与依据")
	var entity_count: int = error_core.store.entities.size()
	expect(error_core.retry_question(), "主动重试")
	settle(error_core)
	expect(int(error_core.state.chances.Q1) == 3 and error_core.draft().slots == [null,null] and not error_core.draft().target_selected and error_core.store.entities.size() == entity_count, "重试仅恢复本题并保留库存")
	# 文件保存与元数据，故意损坏文件不应覆盖当前会话。
	var save := Save.new()
	root.add_child(save); services.append(save)
	save.storage_path = folder.path_join("saves")
	save.snapshot_validator = session.validate_snapshot
	expect(save.save_auto(completed_snapshot), "隔离自动档写入")
	expect(save.save_snapshot("manual",0,completed_snapshot), "隔离手动档写入")
	var manual: Dictionary = save.load_snapshot("manual",0)
	expect(manual.get("slot_kind") == "manual" and int(manual.get("save_sequence",0)) == 2, "手动元数据覆盖继承值且序号只在成功保存增加")
	expect(save.load_latest().get("slot_kind") == "manual", "继续选择最新成功保存")
	var seq: int = save.sequence
	expect(not save.save_snapshot("manual",0,broken) and int(save.sequence) == seq, "不完整快照拒绝写入不增加序号")
	expect(save.load_snapshot("manual",0).card_snapshot.completed_questions == completed_snapshot.card_snapshot.completed_questions, "拒绝保存保留原文件")
	# 进入回应时确认的成果不能被动画跳过或重复回调二次执行。
	var enter_session := new_session()
	var enter_core: Node = enter_session.core
	enter_core.catalog.data.relations.R_ONE.erase("inference")
	enter_core.catalog.data.relations.R_ONE.effect_level = "normal"
	enter_core.catalog.data.relations.R_ONE.climax_key = ""
	enter_core.catalog.data.nodes.N_ONE.timing = "enter"
	acquire_entry(enter_core,"UPDATE"); acquire_entry(enter_core,"TALK")
	open_question(enter_core)
	enter_core.select_material(ref(enter_core,"A2"))
	enter_core.present_materials()
	expect("Q1" in enter_core.state.completed_questions and enter_core.state.current_statements.Q1 == "S2" and enter_core.state.mode == "response", "进入回应按配置确认更正且不发推论")
	settle(enter_core)
	enter_core.continue_result()
	expect(enter_core.state.applied_group_ids.size() == 1, "回应进入与继续不重复结果组")
	await _ui_regression()
	for node in services: node.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty(): print("CORE_PASS: %d checks; versioned materials, matching, frozen sources, collection, attempts, restore and page input." % checks)
	else: printerr("CORE_FAIL: %d failures / %d checks" % [failures.size(),checks])
	quit(0 if failures.is_empty() else 1)

func _frames(count: int = 3) -> void:
	for i in range(count): await process_frame

func _ui_regression() -> void:
	var scene: Control = load("res://main/main.tscn").instantiate()
	scene.test_storage_path = folder.path_join("ui")
	root.add_child(scene)
	await _frames()
	expect(scene.title_page.visible and not scene.gameplay_page.visible, "标题隐藏玩法节点")
	scene.title_page.new_game_requested.emit()
	scene.confirm_page.accepted.emit()
	await _frames()
	var core: Node = scene.session_service.core
	expect(core.state.mode == "investigation" and scene.gameplay_page.visible, "新游戏显示占位调查")
	var seq: int = scene.save_service.sequence
	scene.gameplay_page.menu_requested.emit()
	expect(scene.current_layer == "pause" and scene.save_service.sequence == seq, "暂停不新增序号")
	scene.pause_page.settings_requested.emit()
	scene.settings_page.closed.emit()
	expect(scene.current_layer == "pause", "设置关闭回原暂停")
	scene.pause_page.resume_requested.emit()
	acquire_entry(core,"INSPECT"); acquire_entry(core,"TALK")
	open_question(core)
	core.select_material(ref(core,"A1"))
	await _frames()
	var selection_page: Control = scene.gameplay_page.selection
	expect(selection_page.card_buttons.size() == 5, "底栏五张控件")
	core.acquire_material("A2", "UPDATE", "SRC_UPDATE")
	await _frames()
	var read_button: Button = selection_page.card_buttons[0]
	read_button.pressed.emit()
	expect(scene.gameplay_page.reader.stack[-1].ref.content_id == "A1", "牌库已选卡片沿槽内旧版阅读，不切换到当前新版")
	scene.gameplay_page.reader.close_all()
	await _frames()
	scene.gameplay_page.reader.open_material(ref(core,"A1"),true)
	await _frames()
	expect(not core.can_save() and core.store.entities.A.viewed_content_ids == ["A1"], "全文才记已读且阅读禁存")
	var before: Dictionary = core.draft()
	scene.gameplay_page.toggle_inspection()
	expect(scene.gameplay_page.inspection_reader.visible, "来源或详情上可再打开完整检视")
	scene.gameplay_page.toggle_inspection()
	expect(scene.gameplay_page.reader.visible and core.draft() == before, "结束整次检视回原详情且草稿保持")
	scene.gameplay_page.reader.close_all()
	await _frames()
	var body_ref: String = core.catalog.data.contents.A1.body
	var original_body: String = core.catalog.text(body_ref)
	core.catalog.data.texts[body_ref] = "甲🙂乙\n".repeat(250)
	scene.gameplay_page.reader.open_material(ref(core,"A1"),true)
	await _frames()
	var reading: Control = scene.gameplay_page.reader
	reading.body.get_v_scroll_bar().value = 500
	reading._push({"kind":"sources","sources":core.store.sources(ref(core,"A1"))})
	var anchor: Dictionary = reading.stack[0].body_anchor
	expect(anchor.text_id == body_ref and int(anchor.character_index) > 0, "长正文锚点绑定准确文本与真实码点")
	reading.back()
	await _frames()
	expect(reading.body.get_v_scroll_bar().value > 0, "来源上一级恢复正文阅读位置")
	reading.close_all()
	core.catalog.data.texts[body_ref] = original_body
	await _frames()
	core.set_grid(true)
	await _frames()
	expect(selection_page.card_buttons.size() == 7, "展开网格包含超过五份的全部材料")
	scene.gameplay_page.handle_escape()
	expect(core.state.card_ui_page == "selection", "Esc先收网格")
	scene.gameplay_page.handle_escape()
	expect(core.state.mode == "investigation", "再次Esc收对局")
	core.open_card_session("Q1")
	core.withdraw_material()
	core.select_material(ref(core,"A1")); core.select_material(ref(core,"B1"))
	core.present_materials()
	await _frames()
	expect(scene.gameplay_page.feedback.active, "反馈白模实际开始播放")
	scene._open_pause()
	var elapsed: float = scene.gameplay_page.feedback.elapsed
	await _frames(4)
	expect(scene.gameplay_page.feedback.elapsed == elapsed and scene.pause_page.save_button.disabled, "暂停冻结显示时钟且待收禁存")
	scene._on_resume()
	scene.gameplay_page.feedback.finish()
	await _frames()
	expect(core.state.mode == "pending" and not core.store.owns(ref(core,"I1")), "跳过只结束表现不收卡")
	scene._open_pause(); scene._on_return_title()
	expect(scene.confirm_page.accept_button.visible and scene.confirm_page.accept_button.disabled, "禁存离开保留灰色保存项，直接离开与取消可用")
	scene._on_confirm_cancel(); scene._on_resume()
	expect(core.state.mode == "pending", "取消离开保留待收")
	var result: Dictionary = core.state.current_result
	core.collect_inference(result.result_id,result.inference_content_id)
	scene.gameplay_page.feedback.finish()
	core.continue_result()
	await _frames()
	expect(scene.save_service.sequence == seq+1, "正常返回只新增一份自动档")
	scene._open_pause(); scene._on_save()
	scene.save_page._save_slot(0)
	scene.save_page._submit()
	expect(scene.current_layer == "subpage" and scene.save_page.visible, "手动保存成功停留原栏")
	scene._on_close_subpage()
	scene._on_return_title(); scene._on_confirm_direct()
	expect(scene.current_layer == "title" and not scene.gameplay_page.visible, "返回标题隐藏玩法")
	scene._on_continue()
	await _frames()
	expect("Q1" in core.state.completed_questions and core.store.owns(ref(core,"I1")), "继续恢复最新完整玩法档")
	# 连续重建页面与节点释放，不保留旧按钮引用或旧会话锁。
	for i in range(5):
		scene._open_pause(); scene._on_load(); scene._on_close_subpage(); scene._on_resume()
		await _frames(1)
	expect(scene.current_layer == "investigation", "读取页重复开合无崩溃")
	scene.queue_free()
	await _frames()
