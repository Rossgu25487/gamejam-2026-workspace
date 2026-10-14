extends SceneTree
## 文案系统专项回归：使用内存配置验证服务契约，若传入 --workbook 则同时检查正式/测试工作簿入口。

const Service = preload("res://systems/narrative/narrative_service.gd")
const Loader = preload("res://systems/narrative/narrative_workbook_loader.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("NARRATIVE_FAILED: " + message)

func definition() -> Dictionary:
	return {
		"texts": {
			"T1": {"text":"第一段正文。", "speaker_name":"甲", "chapter_id":"C1", "read_version":1, "is_default_start":true},
			"T2": {"text":"分支甲。", "speaker_name":"甲", "chapter_id":"C1", "read_version":1},
			"T3": {"text":"分支乙。", "speaker_name":"乙", "chapter_id":"C1", "read_version":2}
		},
		"chapters":{"C1":{"name":"第一章"}}, "scenes":{}, "locations":{}, "backgrounds":{}, "states":{}, "state_values":{}, "events":{}, "performance_events":{},
		"transitions": {
			"B": {"source_text_id":"T1", "order":2, "transition_type":"choice", "choice_text":"乙", "target_text_id":"T3"},
			"A": {"source_text_id":"T1", "order":1, "transition_type":"choice", "choice_text":"甲", "target_text_id":"T2"}
		}
	}

func _run() -> void:
	var service := Service.new()
	root.add_child(service)
	expect(service.initialize(definition()), "内存配置初始化")
	expect(service.start(), "默认起始文本")
	expect(service.current_text() == "第一段正文。" and service.is_typing(), "进入起始文本并开始逐字")
	service.tick(1.0)
	expect(service.visible_text() == "第一段正文。" and not service.is_typing(), "逐字推进到完整正文")
	expect(service.advance(), "完整文本等待玩家继续")
	expect(service.state.waiting_for_choice and service.catalog.choices_from_text("T1").size() == 2, "多分支等待玩家选择")
	expect(not service.advance(), "等待分支时继续键不自动选第一项")
	expect(service.choose_transition(1) and service.current_text() == "分支乙。", "选择第二条分支")
	service.advance()
	var snapshot := service.export_snapshot()
	expect(service.validate_snapshot(snapshot), "有效快照通过校验")
	var restored := Service.new()
	root.add_child(restored)
	expect(restored.initialize(definition()) and restored.restore_snapshot(snapshot), "快照恢复")
	expect(restored.current_text() == "分支乙。" and restored.state.read_versions.get("T1", 0) == 1, "恢复文本与已读版本")
	var broken := snapshot.duplicate(true)
	broken.state.visible_characters = 99999
	expect(not restored.validate_snapshot(broken), "越界逐字快照拒绝")
	if "--workbook" in OS.get_cmdline_user_args():
		var loader := Loader.new()
		var formal := loader.load_workbook()
		expect(not formal.is_empty(), "正式文案工作簿可读取：" + str(loader.errors))
		var test_data := loader.load_workbook(Loader.TEST_PATH)
		expect(not test_data.is_empty(), "测试文案工作簿可读取：" + str(loader.errors))
	service.queue_free(); restored.queue_free()
	await process_frame
	if failures.is_empty(): print("NARRATIVE_PASS: %d checks" % checks)
	else: printerr("NARRATIVE_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
