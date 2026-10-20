extends SceneTree
## 材料真正前进时才提示“手册已更新”；同版重复授予不重复，提示插在正文前且无头像。
const Session = preload("res://systems/aurora/aurora_session.gd")
var checks := 0
var failures: Array[String] = []
var updates: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _run() -> void:
	var session := Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式配置可载入")
	if not failures.is_empty():
		session.queue_free()
		quit(1)
		return
	session.case_state.content_updated.connect(func(id): updates.append(id))

	# 运行时取E02（现场尸体记录）的前两个版本，避免硬编码内容ID。
	var e02_versions: Array[String] = []
	for cid in session.config.contents:
		if str(session.config.contents[cid].material_id) == "E02": e02_versions.append(cid)
	e02_versions.sort_custom(func(a, b): return int(session.config.contents[a].version) < int(session.config.contents[b].version))
	check(e02_versions.size() >= 2, "E02应至少有两个版本：" + str(e02_versions))
	if e02_versions.size() < 2:
		session.queue_free()
		quit(1)
		return
	var v1: String = e02_versions[0]
	var v2: String = e02_versions[1]
	var material_name := str(session.config.contents[v2].name)
	var expected_text := "【手册已更新：" + material_name + "】"

	# 首次授予只发一次更新；同版重复授予不再发；更高版本只发一次。
	updates.clear()
	check(session.case_state.grant(v1, {"test": true}), "授予" + v1 + "成功")
	check(updates == [v1], "首次授予只发一次更新：" + str(updates))
	check(session.narrative._pending_manual_updates == [v1], "会话把更新排入手册提示队列")
	updates.clear()
	check(session.case_state.grant(v1, {"test": true}), "重复授予" + v1 + "成功")
	check(updates.is_empty(), "同版重复授予不再发更新：" + str(updates))
	check(session.narrative._pending_manual_updates == [v1], "同版重复授予不重复入队")
	updates.clear()
	check(session.case_state.grant(v2, {"test": true}), "授予" + v2 + "成功")
	check(updates == [v2], "更高版本只发一次更新：" + str(updates))
	check(session.narrative._pending_manual_updates == [v1, v2], "更高版本追加到提示队列")

	# queue_manual_update 自身也去重。
	session.narrative.clear_manual_updates()
	session.narrative.queue_manual_update(v2)
	session.narrative.queue_manual_update(v2)
	check(session.narrative._pending_manual_updates == [v2], "提示入队去重")

	# 提示记录为无头像旁白，文案为手册已更新，且不清除舞台人物。
	var record: Dictionary = session.narrative._manual_update_record(v2)
	check(str(record.get("text", "")) == expected_text, "提示文案为手册已更新：" + str(record.get("text", "")))
	check(str(record.get("text_type", "")) == "narration", "提示为无头像旁白")
	check(bool(record.get("clear_positions", true)) == false, "提示不清除舞台人物")
	check(str(record.get("text_id", "")) == "__MANUAL_UPDATE__", "提示使用保留ID")

	# show_text 拦截：有待提示时先播提示，结束后再接真实正文。
	session.narrative.clear_manual_updates()
	session.narrative.queue_manual_update(v2)
	var real_text := ""
	for id in session.config.texts:
		real_text = id
		break
	check(not real_text.is_empty(), "存在可用的正文ID")
	check(session.narrative.show_text(real_text), "排入提示后show_text仍返回true")
	check(str(session.narrative.state.get("current_text_id", "")) == "__MANUAL_UPDATE__", "先显示手册更新提示")
	check(session.narrative.current_text() == expected_text, "提示正文为手册已更新文案")
	check(not session.narrative.state.history.has("__MANUAL_UPDATE__"), "提示不污染跨重启已看原话记录")
	var continued: bool = session.narrative._finish_current_text()
	check(continued, "提示播完后接回真实正文")
	check(str(session.narrative.state.get("current_text_id", "")) == real_text, "接回原正文：" + str(session.narrative.state.get("current_text_id", "")))

	session.queue_free()
	await process_frame
	print("MANUAL_UPDATE_HINT_PASS %d checks" % checks if failures.is_empty() else "MANUAL_UPDATE_HINT_FAIL %d/%d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
