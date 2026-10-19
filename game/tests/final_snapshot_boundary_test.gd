extends SceneTree
## 损坏读档在写入当前会话前被拒绝，避免空引用、越界或半恢复。
var checks := 0
var failures: Array[String] = []
var session: Node
func _init() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); printerr("FINAL_SNAPSHOT_FAIL: " + label)
func rejected(snapshot: Dictionary, label: String) -> void:
	var before: Dictionary = session.export_snapshot()
	check(not session.restore_snapshot(snapshot), label + "被拒绝")
	check(session.export_snapshot() == before, label + "保留完整当前会话")
func run() -> void:
	session = preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session); session.seen_storage_path = ""
	check(session.initialize(), "正式配置初始化")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset(); session.run_id = "snapshot-boundary"
	session.set_scene("SC07"); session.mode = "investigation"
	session.return_context = {"kind":"scene", "scene":"SC07", "view":session.case_state.data.view}
	session.active_entry = str(session.config.questions.L01_R01.entry_ref)
	check(session.open_question("L01_R01"), "实际启动证言逐句阅读")
	var good: Dictionary = session.export_snapshot()
	check(session.validate_snapshot(good), "实际证言阅读快照有效")
	for bad_value in [null, true, "broken", {}, [], ["MISSING_TEXT"], [12]]:
		var bad := good.duplicate(true)
		bad.question_reading.texts = bad_value
		rejected(bad, "证言正文类型%s" % str(bad_value))
	for bad_index in [null, "0", true, -1, 0.5, 999, INF, NAN]:
		var bad := good.duplicate(true)
		bad.question_reading.index = bad_index
		rejected(bad, "证言游标%s" % str(bad_index))
	for key in ["positions", "library_positions", "library_pages", "document", "stack", "new_list", "visible", "new_index"]:
		var bad := good.duplicate(true)
		bad.page_snapshot = {"reader":{key:"invalid"}}
		rejected(bad, "手册损坏字段" + key)
	var bad_reader := good.duplicate(true)
	bad_reader.page_snapshot = {"reader":[]}
	rejected(bad_reader, "手册状态数组")
	check(session.restore_snapshot(JSON.parse_string(JSON.stringify(good))), "合法JSON往返能继续同一证言")
	print("FINAL_SNAPSHOT_BOUNDARY %d checks, %d failures" % [checks, failures.size()])
	session.queue_free(); await process_frame
	quit(0 if failures.is_empty() else 1)
