extends SceneTree
## 调查系统业务回归。使用内存配置和核心临时会话，不读取或改写正式存档。

const Session = preload("res://systems/core_gameplay/game_session_service.gd")
var failures: Array[String] = []
var checks := 0
var session: Node
var scene: Node

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, detail: String) -> void:
	checks += 1
	if not ok:
		failures.append(detail)
		printerr("SCENE_CHECK_FAILED: " + detail)

func _run() -> void:
	session = Session.new()
	root.add_child(session)
	expect(session.initialize(), "核心配置可加载")
	scene = session.scene_interaction
	var core: Node = session.core
	var definition := {
		"display": {"topic_visible_rows": 5},
		"hotspots": [
			{"hotspot_id":"H_TABLE", "data_scope":"runtime", "scene_id":core.catalog.data.initial_scene, "object_ref":"TABLE", "object_kind":"object", "x":10,"y":20,"w":120,"h":80,"hit_priority":2,"focus_order":1,"inspect_entry_ref":"INSPECT","topic_entry_ref":"","view_id":"VIEW"},
			{"hotspot_id":"H_PERSON", "data_scope":"runtime", "scene_id":core.catalog.data.initial_scene, "object_ref":"PERSON", "object_kind":"character", "x":200,"y":20,"w":120,"h":160,"hit_priority":1,"focus_order":2,"inspect_entry_ref":"","topic_entry_ref":"TOPIC_LIST","view_id":"VIEW"},
			{"hotspot_id":"H_OTHER", "data_scope":"runtime", "scene_id":"OTHER_SCENE", "object_ref":"OTHER", "object_kind":"object", "x":0,"y":0,"w":80,"h":80,"hit_priority":1,"focus_order":1,"inspect_entry_ref":"INSPECT","topic_entry_ref":"","view_id":"OTHER"},
		],
		"observations": [
			{"observation_ref":"OBS_FIRST", "data_scope":"runtime", "object_ref":"TABLE", "entry_ref":"INSPECT", "content_ref":"A1", "version":1, "source_ref":"SRC_FIRST"},
			{"observation_ref":"OBS_SECOND", "data_scope":"runtime", "object_ref":"TABLE", "entry_ref":"UPDATE", "content_ref":"", "version":0, "source_ref":"", "previous_observation_ref":"OBS_FIRST"},
		],
		"topics": [
			{"topic_ref":"TALK_A", "data_scope":"runtime", "person_ref":"PERSON", "list_entry_ref":"TOPIC_LIST", "public_name":"已知话题", "kind":"topic", "entry_ref":"TALK", "interactive":true, "public_reason":"", "focus_order":1},
			{"topic_ref":"TALK_LOCKED", "data_scope":"runtime", "person_ref":"PERSON", "list_entry_ref":"TOPIC_LIST", "public_name":"暂不可用", "kind":"topic", "entry_ref":"", "interactive":false, "public_reason":"需要更多线索", "focus_order":2},
		],
	}
	expect(scene.configure(definition), "调查配置可接入")
	session.start_new_game()
	expect(scene.hotspots_for_scene(core.state.current_scene_id).size() == 2, "当前地点只显示当前热点")
	expect(scene.hotspot_state("H_OTHER").is_empty(), "其他地点热点不泄露")
	expect(scene.can_save(), "稳定调查允许保存")
	var first: Dictionary = scene.begin_inspection("H_TABLE", {"focus_ref":"H_TABLE"})
	expect(first.ok and not scene.can_save(), "检查请求锁定并禁止保存")
	expect(scene.begin_inspection("H_TABLE").get("ok", false) == false, "重复检查请求被锁定")
	expect(scene.hotspot_state("H_TABLE").status == "检查", "未提交时不能显示已查")
	expect(scene.cancel_inspection(first.request_id), "取消检查返回成功")
	expect(scene.hotspot_state("H_TABLE").status == "检查", "取消检查不提交观察")
	var snapshot_before: Dictionary = scene.export_snapshot()
	expect(scene.restore_snapshot(snapshot_before), "有效调查快照可恢复")
	var second: Dictionary = scene.begin_inspection("H_TABLE")
	expect(second.ok, "恢复后可以重新检查")
	var committed: Dictionary = scene.commit_inspection(second.request_id, true)
	expect(committed.ok and committed.committed, "提交检查事务")
	expect(scene.hotspot_state("H_TABLE").status == "可补查", "提交后显示可补查")
	expect(core.store.owns(core.catalog.material_ref("A1")), "检查提交取得材料")
	expect(scene.available_new_observation("TABLE") == "OBS_SECOND", "已有观察解锁可补查")
	scene.set_object_state("TABLE", false, false)
	expect(scene.hotspots_for_scene(core.state.current_scene_id).size() == 1, "离场对象从热点和焦点列表移除")
	expect(not scene.hotspot_state("H_TABLE").visible and not scene.hotspot_state("H_TABLE").interactive, "离场对象不可见且不可交互")
	expect(core.store.owns(core.catalog.material_ref("A1")), "离场不删除手册材料")
	scene.set_object_state("TABLE", true, true)
	expect(scene.hotspots_for_scene(core.state.current_scene_id).size() == 2, "对象恢复可见")
	var topics: Array = scene.topics_for_person("PERSON")
	expect(topics.size() == 2 and topics[0].interactive and not topics[1].interactive, "话题列表保留可用与不可用原因")
	expect(scene.open_topic("TALK_LOCKED").get("ok", false) == false, "不可用话题不发起内容请求")
	expect(scene.open_topic("TALK_A", {"focus_ref":"H_PERSON"}).ok, "可用话题保存返回上下文")
	expect(scene.state.topic_anchor == "TALK_A" and scene.state.return_context.focus_ref == "H_PERSON", "话题锚点和焦点可恢复")
	var full: Dictionary = session.export_snapshot()
	expect(session.validate_snapshot(full), "联合核心与调查快照可验证")
	var roundtrip: Dictionary = JSON.parse_string(JSON.stringify(full))
	expect(session.restore_snapshot(roundtrip), "联合快照 JSON 往返恢复")
	var broken: Dictionary = full.duplicate(true)
	broken.scene_interaction_snapshot.state.erase("observations")
	expect(not session.restore_snapshot(broken), "损坏调查状态拒绝恢复")
	var bad_after: Dictionary = scene.export_snapshot()
	expect(bad_after.state.observations.has("OBS_FIRST"), "拒绝损坏快照不替换当前状态")
	scene.set_object_state("TABLE", true, false)
	expect(not scene.hotspot_state("H_TABLE").interactive and scene.hotspot_state("H_TABLE").public_reason != "", "不可交互对象显示公开原因")
	if failures.is_empty(): print("SCENE_PASS: %d checks; hotspots, inspection transactions, topics, focus, departure and snapshots." % checks)
	else: printerr("SCENE_FAIL: %d failures / %d checks" % [failures.size(), checks])
	session.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
