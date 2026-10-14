extends SceneTree
## 地图切换服务回归：验证节点选择、锁定地点、成功移动、取消和快照。

const Session = preload("res://systems/core_gameplay/game_session_service.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("MAP_FAILED: " + message)

func _run() -> void:
	var session := Session.new()
	root.add_child(session)
	expect(session.initialize(), "核心配置有效")
	session.start_new_game()
	var map: Node = session.map_navigation
	expect(map != null, "地图服务已创建")
	map.open()
	expect(map.state.open and map.current_scene_id() == session.core.state.current_scene_id, "地图页打开并显示当前地点")
	var links: Array = map.available_transitions()
	if not links.is_empty():
		var selected := false
		for item in links:
			if item.available:
				selected = map.select_transition(item.transition_id)
				break
		expect(selected, "可达地点可以选中")
		expect(map.travel(), "选中地点可以前往")
		expect(not map.state.open and map.current_scene_id() == session.core.state.current_scene_id, "成功前往后关闭地图并同步地点")
	else:
		expect(true, "当前配置没有可达地点，跳过移动")
	map.open()
	var snapshot: Dictionary = map.export_snapshot()
	expect(map.validate_snapshot(snapshot), "地图快照有效")
	map.cancel()
	expect(not map.state.open, "取消返回调查")
	var broken: Dictionary = snapshot.duplicate(true)
	broken.state.active_request = {"request_id":"bad"}
	expect(not map.validate_snapshot(broken), "活动切换快照拒绝")
	session.queue_free()
	await process_frame
	if failures.is_empty(): print("MAP_PASS: %d checks" % checks)
	else: printerr("MAP_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
