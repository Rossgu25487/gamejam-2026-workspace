extends SceneTree
## 真正读取编辑后的 XLSX，验证来源格式、错误定位、地点与联合存读档。
## 无参数可校验用户当前填写的工作簿；--fixtures 才运行固定占位案例回归。

const Loader = preload("res://systems/core_gameplay/story_workbook_loader.gd")
const Catalog = preload("res://systems/core_gameplay/core_catalog.gd")
const Core = preload("res://systems/core_gameplay/core_gameplay_service.gd")
const Save = preload("res://systems/save_load/save_load_service.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("STORY_FAILED: " + message)

func _fixture(name: String) -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/story-workbook/fixtures/" + name + ".xlsx")

func _run() -> void:
	var catalog := Catalog.new()
	expect(catalog.load_files(), "当前故事配置表合法：" + str(catalog.errors))
	if "--fixtures" in OS.get_cmdline_user_args():
		await _fixtures(catalog)
	if failures.is_empty(): print("STORY_PASS: %d checks; direct XLSX content, validation, conditions, scene navigation and restore." % checks)
	else: printerr("STORY_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)

func _fixtures(current: RefCounted) -> void:
	for name in ["inline", "shared"]:
		var converted := Catalog.new()
		expect(converted.load_files(_fixture(name)), "支持 XLSX 文本格式 " + name + "：" + str(converted.errors))
		expect(converted.data == current.data, "不同 XLSX 文本编码保持相同故事数据：" + name)
	for pair in [["duplicate", "材料 第20行"], ["missing_ref", "问题 第5行"], ["formula", "材料版本 第5行"], ["bad_header", "缺少列"], ["broken_inference", "出示关系 第5行"], ["bad_collect", "出示关系 第5行"], ["basis_cycle", "循环"]]:
		var invalid := Catalog.new()
		expect(not invalid.load_files(_fixture(pair[0])), "拒绝无效故事配置：" + pair[0])
		expect("\n".join(invalid.errors).contains(pair[1]), "配置错误定位：" + pair[0] + "/" + str(invalid.errors))
	var core := Core.new()
	root.add_child(core)
	expect(core.initialize(_fixture("modified")), "编辑后的工作簿可直接读取：" + str(core.catalog.errors))
	if not core.catalog.errors.is_empty(): core.queue_free(); return
	core.start_new_game()
	expect(core.catalog.text(core.catalog.data.scenes.ROOM.name) == "正式地点测试：档案室", "直接修改地点名称即生效")
	expect(core.catalog.text(core.catalog.data.contents.A1.body) == "第一行：甲🙂乙\n第二行：直接编辑后由程序读取。", "中文、多行、Unicode 正文保持完整")
	expect(not core.catalog.data.materials.has("BROKEN_DISABLED") and not core.catalog.data.materials.has("IGNORED"), "禁用行与备注行不参与配置")
	expect(core.catalog.data.materials.has("LATE_ROW"), "第200行以后新增数据仍可读取")
	expect(not core.condition_met("COND_OR") and not core.condition_met("COND_AND"), "空进度不伪造条件")
	core.activate_entry("INSPECT"); core.finish_dialogue()
	expect(core.condition_met("COND_OR") and not core.condition_met("COND_AND"), "条件分支间或、分支内与")
	core.activate_entry("TALK"); core.finish_dialogue()
	expect(core.condition_met("COND_AND"), "全部条件满足后开放")
	expect(not core.activate_entry("ROOM2_ENTRY"), "服务拒绝调用其他地点调查入口")
	expect(not core.move_scene("LINK_LOCKED"), "移动真实检查开放条件")
	var autos := [0]
	core.autosave_requested.connect(func(): autos[0] += 1)
	expect(core.move_scene("LINK_OUT") and core.state.current_scene_id == "ROOM2" and autos[0] == 1, "配置地点切换提交一次自动保存请求")
	expect(not core.activate_entry("INSPECT") and not core.open_card_session("Q1"), "异地调查和问题不能绕过页面直接调用")
	expect(core.activate_entry("ROOM2_ENTRY"), "新地点调查入口有效")
	core.finish_dialogue()
	var snapshot: Dictionary = core.export_card_state()
	expect(core.move_scene("LINK_BACK") and core.state.current_scene_id == "ROOM", "反向连接单独配置")
	expect(core.restore_card_state(snapshot) and core.state.current_scene_id == "ROOM2", "核心快照恢复配置地点")
	var save := Save.new()
	root.add_child(save)
	save.storage_path = "user://story-config-test/%d" % Time.get_ticks_usec()
	var bundle := {"state_revision": snapshot.revision, "content_revision": snapshot.content_revision, "card_snapshot": snapshot,
		"navigation_snapshot": {"state_revision": snapshot.revision, "page_id": snapshot.mode, "current_scene_id": snapshot.current_scene_id}}
	save.snapshot_validator = func(record: Dictionary): return core.validate_card_state(record.get("card_snapshot", {}))
	expect(save.save_snapshot("manual", 0, bundle), "编辑故事的地点和材料可以写入隔离存档")
	core.start_new_game()
	expect(core.restore_card_state(save.load_snapshot("manual", 0).card_snapshot) and core.state.current_scene_id == "ROOM2" and core.store.entities.has("A"), "磁盘存档恢复真实地点和材料")
	core.catalog.data.content_revision = "changed-revision"
	expect(not core.restore_card_state(snapshot), "修改内容版本后拒绝旧档")
	# 页面只显示当前地点入口，且不依赖任何占位问题 ID。
	core.catalog.data.content_revision = snapshot.content_revision
	core.restore_card_state(snapshot)
	var page := preload("res://pages/core/investigation_page.gd").new()
	root.add_child(page)
	page.render(core)
	expect(_has_button(page, "调查第二地点") and not _has_button(page, "检查占位资料"), "页面按当前地点过滤调查入口")
	page.queue_free(); save.queue_free(); core.queue_free()
	await process_frame
	var title: Control = load("res://title_page/title_page.tscn").instantiate()
	root.add_child(title)
	var error_messages: Array[String] = ["材料 第20行：ID重复 A"]
	title.show_configuration_error(error_messages)
	await process_frame
	expect(title.new_game_button.disabled and title.continue_button.disabled and title.status.text == "故事配置错误", "错误标题页阻止运行并显示具体原因")
	expect(root.get_visible_rect().encloses(title.panel.get_global_rect()), "配置错误正文和退出入口完整位于窗口内")
	title.queue_free()
	await process_frame

func _has_button(parent: Node, title: String) -> bool:
	for child in parent.get_children():
		if child is Button and child.text == title: return true
		if _has_button(child, title): return true
	return false
