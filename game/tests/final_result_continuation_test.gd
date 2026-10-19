extends SceneTree
## 已读核查结果的接续失败应完整保留，重试仍可沿同一结果继续。
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr(message)
func run() -> void:
	var session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session); session.seen_storage_path = ""
	check(session.initialize(), "正式包加载")
	session.case_state.reset(); session.set_scene("SC03"); session.run_id = "result-continuation"
	session.case_state.grant("T03_V1", {}); session.case_state.grant("T07_V1", {})
	session.question = "L13_R03"; session.active_entry = "ENTRY_F7_CH04_L13_R03"
	session.return_context = {"kind":"scene", "scene":"SC03", "view":session.case_state.data.view}
	session.mode = "result"; session.slots = ["T03_V1", "T07_V1"]; session.selected_target = true
	session.pending_result = {"question":"L13_R03", "result":"RESULT_L13_R03", "complete":true, "response_read":true, "refs":["T03_V1", "T07_V1"]}
	session.case_state.data.drafts[session.question] = {"slots":session.slots.duplicate()}
	var before: Dictionary = session.export_snapshot()
	check(session.validate_snapshot(before), "回执夹具是完整合法快照")
	check(not session.continue_result(), "未满足后续入口时拒绝跳转")
	check(session.export_snapshot() == before, "接续失败完整保留结果、草稿和原场景")
	check(not session.pending_result.is_empty() and session.mode == "result", "结果页仍可继续操作")
	check(session.validate_snapshot(session.export_snapshot()), "失败后档案仍有效")
	var result: Dictionary = session.config.results.RESULT_L13_R03
	var original: String = result.after_effect_entry_ref
	result.after_effect_entry_ref = "ENTRY_F7_CH04_L13_EXCLUSION"
	check(session.continue_result() and session.mode == "narrative", "后续准备就绪可重试同一结果")
	check(session.pending_result.is_empty(), "成功跳转后清理待继续结果")
	result.after_effect_entry_ref = original
	session.queue_free(); await process_frame
	print("FINAL_RESULT_CONTINUATION %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
