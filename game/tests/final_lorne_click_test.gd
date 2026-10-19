extends SceneTree
## 验证休息室洛恩人物点击按正式第一章状态直接进入对应对白。
const Session = preload("res://systems/aurora/aurora_session.gd")
const ScenePage = preload("res://pages/aurora/aurora_scene_page.gd")
var session: Node
var page: Control
var failures: Array[String] = []
var checks := 0

func _init() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("LORNE_CLICK_FAIL: " + message)

func frames(count := 3) -> void:
	for index in range(count): await process_frame

func finish_dialogue() -> void:
	for index in range(80):
		if session.mode != "narrative": return
		session.narrative.tick(100)
		if session.narrative.state.get("waiting_for_choice", false): session.narrative.choose_transition(0)
		else: session.narrative.advance()
		await process_frame

func run() -> void:
	session = Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式配置载入")
	session.case_state.reset()
	session.case_state.data.chapter = "CH01"
	session.case_state.data.scene = "SC06"
	session.case_state.data.view = "VIEW_SC06_MAIN"
	session.case_state.data.npc["CHR02"] = {"scene_id": "SC06"}
	session.mode = "investigation"
	session.return_context = {"kind": "scene", "scene": "SC06", "view": "VIEW_SC06_MAIN"}
	page = ScenePage.new()
	root.add_child(page)
	page.size = Vector2(1600, 900)
	page.bind(session)
	await frames()
	var rows: Array = page.model.hotspots().filter(func(row): return str(row.get("object_ref", "")) == "CHR02")
	check(rows.size() == 1, "休息室洛恩有唯一可点击人物热区")
	if rows.is_empty():
		quit(1)
		return
	page._inspect(rows[0])
	await frames()
	check(session.mode == "narrative" and session.active_entry == "ENTRY_CH01_LORNE_UNREAD", "清单未读时点击洛恩直接进入未读对白")
	await finish_dialogue()
	check(session.mode == "investigation", "未读对白结束返回休息室调查")
	session.case_state.data.events["EV_E01_READ"] = true
	page.refresh()
	await frames()
	rows = page.model.hotspots().filter(func(row): return str(row.get("object_ref", "")) == "CHR02")
	check(rows.size() == 1, "清单读完后洛恩仍可点击")
	if not rows.is_empty(): page._inspect(rows[0])
	await frames()
	check(session.mode == "narrative" and session.active_entry == "ENTRY_CH01_LORNE_BUSY", "清单已读时点击洛恩进入忙碌反馈")
	print("FINAL_LORNE_CLICK: %d checks, %d failures" % [checks, failures.size()])
	page.queue_free(); session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
