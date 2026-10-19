extends SceneTree
## 核对最终策划包新增契约及其真实引用，防止载表成功掩盖未绑定的运行数据。
const Config = preload("res://systems/aurora/aurora_configuration.gd")
var config: RefCounted
var checks := 0
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _init() -> void:
	config = Config.new()
	check(config.load_package(), "最终配置包完整加载")
	if not config.errors.is_empty():
		for message in config.errors: printerr(message)
		quit(1)
		return
	check(config.content_revision == "AVG_20261019_FINAL_SCRIPT_MERGED_01", "采用最终正文版本")
	check(config.narrative_data.get("meta", {}).get("content_revision") == config.content_revision, "文案绑定与配置版本一致")
	check(config.tables.has("tutorial") and not config.tutorial_data.is_empty(), "联合引导表及绑定均加载")
	_validate_statements()
	_validate_pages()
	_validate_arrivals()
	_validate_scene_flow()
	_validate_cat()
	_validate_tutorial()
	print("FINAL_PACKAGE_CONTRACT_PASS: %d checks" % checks if failures.is_empty() else "FINAL_PACKAGE_CONTRACT_FAIL: %d / %d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)

func _validate_statements() -> void:
	var statements: Array = config.narrative_bindings("statement_bindings")
	check(statements.size() == 86, "86句证言绑定保留")
	for row in statements:
		var owner := str(row.get("statement_id", ""))
		check(config.questions.has(str(row.get("question_id", ""))), owner + "引用真实问题")
		check(config.texts.has(str(row.get("target_text_ref", ""))), owner + "选中原话存在")
		check(config.entries.has(str(row.get("press_entry_ref", ""))), owner + "逐句追问入口存在")
		for text_id in row.get("text_refs", []):
			check(config.texts.has(str(text_id)), owner + "分页正文存在：" + str(text_id))
		var read_event := str(row.get("read_completion_event_ref", ""))
		if not read_event.is_empty(): check(config.events.has(read_event), owner + "读完事件存在")
	var bindings: Array = config.narrative_bindings("question_bindings")
	check(bindings.size() == 37, "37个核查轮次绑定保留")
	for row in bindings:
		var question_id := str(row.get("question_id", ""))
		check(config.questions.has(question_id), question_id + "关卡轮次存在")
		check(row.get("statement_refs", []).size() == row.get("press_entry_refs", []).size(), question_id + "原句与追问顺序对齐")

func _validate_pages() -> void:
	var groups: Array = config.narrative_bindings("text_page_groups")
	check(groups.size() == 102, "102条观察等分页组保留")
	for group in groups:
		var pages: Array = group.get("page_text_refs", [])
		var owner := str(group.get("text_id", ""))
		check(not pages.is_empty() and pages.has(group.get("completion_text_ref", "")), owner + "完成回执落在实际分页中")
		check(not pages.is_empty() and pages.back() == group.get("completion_text_ref", ""), owner + "最后一页提交完成")
		for page in pages: check(config.texts.has(str(page)), owner + "分页引用存在：" + str(page))

func _validate_arrivals() -> void:
	var arrivals: Array = config.narrative_bindings("arrival_bindings")
	check(arrivals.size() == 99, "九阶段十一地点首次到达绑定")
	for row in arrivals:
		var owner := str(row.get("stage_ref", "")) + "/" + str(row.get("scene_id", ""))
		check(config.scenes.has(str(row.get("scene_id", ""))), owner + "地点存在")
		check(config.entries.has(str(row.get("entry_ref", ""))), owner + "到达正文入口存在")
		check(config.events.has(str(row.get("completion_event_ref", ""))), owner + "实际读完事件存在")

func _validate_scene_flow() -> void:
	for key in ["scene_entry_bindings", "scene_exit_bindings"]:
		for row in config.narrative_bindings(key):
			check(config.scenes.has(str(row.get("scene_ref", ""))), str(row.get("id", "")) + "场景存在")
			check(config.entries.has(str(row.get("entry_ref", ""))), str(row.get("id", "")) + "场景接续入口存在")
	var presentations: Array = config.narrative_bindings("material_presentation_bindings")
	check(presentations.size() == 1, "保留第六章医院回信的实际出示")
	if not presentations.is_empty():
		var row: Dictionary = presentations[0]
		check(row.get("actor_id") == "CHR04" and row.get("content_id") == "E22_V2", "医院回信向伊万出示准确版本")
		check(config.entries.has(str(row.get("response_entry_ref", ""))), "实际出示回应入口存在")

func _validate_cat() -> void:
	var binding: Dictionary = config.narrative_data.get("cat_reward_binding", {})
	check(binding.get("count_state_key") == "cat_pet_completed_count" and binding.get("threshold") == 5 and binding.get("count_cap") == 5, "五次摸猫使用唯一计数及上限")
	check(binding.get("completed_action_ms") == 2800 and binding.get("resume_pending_on_reenter") == true, "摸猫完成时长及中断后续读契约")
	check(config.contents.has("E27_V1") and config.materials.has("E27"), "干印观察材料与准确版本存在")
	check(config.entries.has(str(binding.get("reward_entry_ref", ""))) and config.events.has(str(binding.get("completion_event_ref", ""))), "猫奖励观察入口及取得事件存在")

func _validate_tutorial() -> void:
	var completed: Dictionary = config.tutorial_data.get("state_binding", {})
	check(completed.get("key") == "tutorial_completed_steps" and completed.get("only_on_actual_completion") == true, "引导仅保存实际完成步骤")
	var presentation: Dictionary = config.tutorial_data.get("presentation", {})
	check(presentation.get("lock_outside_target") == true and presentation.get("consume_transition_input") == true, "引导保持真实命中与输入隔离")
	for row in config.tutorial_data.get("steps", []):
		check(row.get("hit_source") == "original_target" and row.get("geometry_source") == "current_rendered_node", str(row.get("group_id", "")) + "读取实际控件几何")
