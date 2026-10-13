extends SceneTree
## 对照设计稿补缺的业务回归：真实排序、合法已听记录、更正时点、旧档与阅读隔离。

const Session = preload("res://systems/core_gameplay/game_session_service.gd")
const TalkPage = preload("res://pages/core/talk_records_page.gd")
const Reader = preload("res://pages/core/material_reader_page.gd")
const Selection = preload("res://pages/core/card_selection_page.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("AUDIT_FAILED: " + message)

func frames(count: int = 3) -> void:
	for i in range(count): await process_frame

func _run() -> void:
	var session := Session.new()
	root.add_child(session)
	expect(session.initialize(), "当前故事配置有效")
	session.start_new_game()
	var core: Node = session.core
	expect(core.talk_segments().is_empty(), "新游戏不泄露未听人物或话题")
	core.activate_entry("INSPECT"); core.finish_dialogue()
	core.activate_entry("TALK"); core.finish_dialogue()
	var segment: Dictionary = core.talk_segments()[0]
	expect(segment.object_id == "PERSON" and segment.topic_id == "TALK" and segment.unread, "已听会面沿真实对象与入口建立未读段")
	expect(segment.statements.size() == 1 and segment.corrections.is_empty(), "未来更正不出现在合法记录")
	for id in segment.record_ids: core.mark_talk_read(id)
	expect(not core.talk_segments()[0].unread, "阅读进度回写唯一记录集合")
	core.activate_entry("TALK"); core.finish_dialogue()
	expect(core.talk_segments().size() == 1 and not core.talk_segments()[0].unread, "重复问话不造新段或重置阅读")
	# 同名人物沿身份筛选，另一入口听见同一句也保留真实取得路径。
	core.catalog.data.characters["PERSON_2"] = core.catalog.data.characters.PERSON.duplicate(true)
	core.catalog.data.entries["TALK_2"] = core.catalog.data.entries.TALK.duplicate(true)
	core.catalog.data.entries.TALK_2.object_id = "PERSON_2"
	core.activate_entry("TALK_2"); core.finish_dialogue()
	expect(core.talk_segments().size() == 2 and core.talk_segments()[0].object_id == "PERSON_2", "交谈对象与实际发言署名分开，同名对象不合并")
	var original_count: int = core.state.talk_records.size()
	core.open_card_session("Q1"); core.select_target()
	core.select_material(core.catalog.material_ref("A1")); core.select_material(core.catalog.material_ref("B1"))
	var result: Dictionary = core.present_materials()
	core.finish_presentation()
	expect(core.state.talk_records.size() == original_count, "待收不提前记录更正或归纳")
	core.collect_inference(result.result_id, result.inference_content_id)
	core.finish_presentation()
	var updated: Dictionary = core.talk_segments()[0]
	expect(updated.unread and updated.corrections.size() == 1 and updated.corrected_statements.size() == 1, "收下时新归纳与更正恢复未读")
	expect(updated.statements[0].statement_id == "S1" and updated.corrected_statements[0].statement_id == "S2", "旧话与生效更正保留精确独立引用")
	expect(updated.corrections[0].record.used_sources == result.used_sources, "记录依据沿成果冻结快照")
	core.continue_result()
	# 缺新增身份与阅读字段的有效旧档可读；未知或伪造记录不能通过快照校验。
	var old: Dictionary = session.export_snapshot()
	for record in old.card_snapshot.talk_records:
		record.erase("record_id"); record.erase("read")
	expect(session.validate_snapshot(old) and session.restore_snapshot(old), "旧档缺新增记录字段仍能恢复")
	expect(core.talk_segments()[0].unread, "旧档未保存阅读状态时按未读显示")
	var broken: Dictionary = session.export_snapshot()
	broken.card_snapshot.talk_records[0].text_id = "UNHEARD_TEXT"
	var preserved: Dictionary = core.export_card_state()
	expect(not session.restore_snapshot(broken) and core.export_card_state() == preserved, "坏记录拒绝恢复且保留会话")
	broken = session.export_snapshot()
	broken.card_snapshot.talk_records[0].record_id = "forged-id"
	expect(not session.validate_snapshot(broken), "伪造记录身份不能改变阅读定位")
	broken = session.export_snapshot()
	broken.card_snapshot.talk_records.append(broken.card_snapshot.talk_records[0].duplicate(true))
	expect(not session.validate_snapshot(broken), "重复记录身份拒绝恢复")
	broken = session.export_snapshot()
	broken.card_snapshot.confirmed_results.clear()
	expect(not session.validate_snapshot(broken), "失去真实确认生产者的更正和归纳拒绝恢复")
	var page := TalkPage.new()
	root.add_child(page)
	var view := {"object_id": "PERSON", "topic_id": "", "segment_id": ""}
	page.render(core, view)
	await frames()
	expect(page.segments.size() == 2 and view.segment_id == "entry/TALK", "人物筛选定位准确会面段")
	expect(page.original.text.contains(core.catalog.text(core.catalog.data.statements.S1.text)), "原话区保留旧版全文")
	expect(page.summary.text.contains(core.catalog.text(core.catalog.data.statements.S2.text)), "归纳区展示已生效更正全文")
	expect(core.state.drafts.is_empty() and core.store.entities.size() == 8, "只读记录不出示不收卡不造库存")
	view.topic_id = "result/Q2"
	page.render(core, view)
	expect(view.topic_id == "", "换对象时无效话题回到全部")
	view.object_id = "UNHEARD_PERSON"
	page.render(core, view)
	expect(view.segment_id == "" and page.original == null and page.summary == null, "无匹配清除正文及旧控件")
	page._clear_filters()
	await frames()
	expect(view.object_id == "" and view.topic_id == "" and not view.segment_id.is_empty(), "清除筛选恢复已有记录")
	page.queue_free()
	# 名称按Unicode排序，同名按首次获得序号；类型顺序必须按策划排列。
	var a_title: String = core.catalog.data.contents.A1.title
	var b_title: String = core.catalog.data.contents.B1.title
	core.catalog.data.texts[a_title] = "Alpha"
	core.catalog.data.texts[b_title] = "Alpha"
	var names: Array = core.store.list_refs({"sort": "name"})
	expect(names[0].material_id == "A" and names[1].material_id == "B", "同名材料按获得序号稳定排列")
	var types: Array = core.store.list_refs({"sort": "type"})
	var order := ["evidence", "testimony", "inference"]
	var previous := -1
	for ref in types:
		var rank := order.find(core.store.entities[ref.material_id].type)
		expect(rank >= previous, "类型顺序为证据、证言、推论")
		previous = rank
	core.open_card_session("Q2")
	core.update_view({"sort": "name"})
	var snapshot: Dictionary = session.export_snapshot()
	expect(core.current_view().sort == "name" and session.validate_snapshot(snapshot) and session.restore_snapshot(snapshot), "名称排序实际写入并可恢复合法快照")
	core.select_material(core.catalog.material_ref("B1"))
	var held: Dictionary = core.draft()
	core.fold_card_selection(); core.open_card_session("Q2")
	expect(core.draft() == held, "收起后重入同问保留精确选择")
	core.fold_card_selection(); core.open_card_session("Q1")
	expect(not core.state.drafts.has("Q2"), "打开另一合法问题清除旧问题草稿")
	core.continue_result()
	var reader := Reader.new()
	root.add_child(reader)
	reader.bind(core)
	reader.open_material(core.catalog.material_ref("A1"))
	var versions := _version_buttons(reader)
	expect(versions.size() == 1 and versions[0].text == "v1" and versions[0].disabled, "单一已获版本保留标识并禁用切换")
	reader.close_all()
	core.acquire_material("A2", "UPDATE", "SRC_UPDATE")
	reader.open_material(core.catalog.material_ref("A1"))
	versions = _version_buttons(reader)
	expect(versions.size() == 2 and versions[0].text == "v2" and versions[1].text == "v1", "版本列表按实际已获版本倒序")
	expect(reader.stack[-1].ref.content_id == "A1" and core.store.entities.A.current_content_id == "A2", "阅读旧版保持精确引用且不倒退当前最高版本")
	reader.close_all()
	core.catalog.data.materials["TEST_I"] = {"type": "inference"}
	core.catalog.data.contents["TEST_I1"] = core.catalog.data.contents.I1.duplicate(true)
	core.catalog.data.contents.TEST_I1.material_id = "TEST_I"
	core.store.acquire("TEST_I1", {}, [])
	reader.open_library(); reader._new_inferences()
	expect(reader.stack[-1].new_inference_refs.size() == 2 and reader.stack[-1].entry_index == 0, "新推论按获得顺序固定本次两项名单")
	reader._step_inference(1)
	expect(reader.stack[-1].entry_index == 1 and reader.stack[-1].ref.content_id == "TEST_I1", "新推论切到后一项")
	reader._step_inference(1)
	expect(reader.stack[-1].entry_index == 1, "新推论末项停止不循环")
	reader._step_inference(-1)
	expect(reader.stack[-1].entry_index == 0 and reader.stack[-1].new_inference_refs.size() == 2, "已读后仍可返回固定名单前项")
	reader.close_all()
	reader.open_library()
	expect(reader._unread_inferences().is_empty(), "结束本次阅读后按已读状态重新统计")
	reader.close_all(); reader.queue_free()
	core.start_new_game()
	# 尚未取得材料的合法问题仍保留类型与翻页控制，页码应为0/0。
	core.catalog.data.questions["EMPTY_Q"] = core.catalog.data.questions.Q2.duplicate(true)
	core.catalog.data.questions.EMPTY_Q.condition = "ALWAYS"
	core.open_card_session("EMPTY_Q")
	var selection := Selection.new()
	root.add_child(selection)
	selection.render(core)
	expect(_has_label(selection, "0 / 0") and selection.refs.is_empty(), "空牌库显示0/0且不造卡")
	selection.queue_free()
	var empty := TalkPage.new()
	root.add_child(empty)
	empty.render(core, {"object_id": "", "topic_id": "", "segment_id": ""})
	expect(empty.segments.is_empty() and empty.original == null, "空记录不生成假正文")
	empty.queue_free(); session.queue_free()
	# 另一个入口先听到同句，也不能吞掉这次核查实际产生的更正经历。
	var earlier := Session.new()
	root.add_child(earlier)
	expect(earlier.initialize(), "先前听过更正句的独立案例有效")
	earlier.start_new_game()
	var next: Node = earlier.core
	next.catalog.data.entries["EARLIER"] = next.catalog.data.entries.TALK.duplicate(true)
	next.catalog.data.entries.EARLIER.statements = ["S2"]
	next.activate_entry("EARLIER"); next.finish_dialogue()
	next.activate_entry("INSPECT"); next.finish_dialogue()
	next.activate_entry("TALK"); next.finish_dialogue()
	next.open_card_session("Q1"); next.select_target()
	next.select_material(next.catalog.material_ref("A1")); next.select_material(next.catalog.material_ref("B1"))
	var correction: Dictionary = next.present_materials()
	next.finish_presentation()
	next.collect_inference(correction.result_id, correction.inference_content_id)
	next.finish_presentation()
	var records: Array = next.talk_segments()
	var corrected := false
	for item in records:
		if item.topic_id == "TALK": corrected = item.corrected_statements.size() == 1
	expect(corrected, "已在别处听过同句仍保留所属核查的生效更正")
	expect(earlier.validate_snapshot(earlier.export_snapshot()), "同句不同取得经历可保存为合法快照")
	earlier.queue_free()
	await frames()
	if failures.is_empty(): print("CORE_AUDIT_PASS: %d checks; sorting, lawful talk records, correction timing, read state and legacy snapshots." % checks)
	else: printerr("CORE_AUDIT_FAIL: %d / %d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)

func _has_label(parent: Node, text: String) -> bool:
	for child in parent.get_children():
		if child is Label and child.text == text: return true
		if _has_label(child, text): return true
	return false

func _version_buttons(parent: Node) -> Array[Button]:
	var found: Array[Button] = []
	for child in parent.get_children():
		if child is Button and child.text in ["v1", "v2"]: found.append(child)
		found.append_array(_version_buttons(child))
	return found
