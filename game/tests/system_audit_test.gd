extends SceneTree
## 本轮策划补缺的行为回归：失败保留、显式提交、首读与猫的联合保存边界。
const Session = preload("res://systems/core_gameplay/game_session_service.gd")
const Narrative = preload("res://systems/narrative/narrative_service.gd")
const Settings = preload("res://systems/game_settings/settings_service.gd")
const Save = preload("res://systems/save_load/save_load_service.gd")
const SceneLoader = preload("res://systems/scene_interaction/scene_workbook_loader.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://system-audit/%d" % Time.get_ticks_usec()
var scene: Control

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("SYSTEM_AUDIT_FAILED: " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func send_key(code: Key, down: bool, shift: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = down
	event.shift_pressed = shift
	root.push_input(event, true)
	await process_frame

func press_key(code: Key, shift: bool = false) -> void:
	await send_key(code, true, shift)
	await send_key(code, false, shift)
	await frames()

func move_mouse(point: Vector2, dragging: bool = false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if dragging else 0
	root.push_input(event, true)
	await process_frame

func mouse_button(point: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	root.push_input(event, true)
	await process_frame

func read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""

func settings_checks() -> void:
	var settings := Settings.new()
	root.add_child(settings)
	settings.storage_path = folder.path_join("settings.json")
	settings.initialize()
	check(settings.values == settings.DEFAULTS, "六项精确初值")
	check(settings.set_value("master_volume", 65), "偏好首次提交")
	var old := read_file(settings.storage_path)
	check(settings.set_value("master_volume", 43, false) and settings.unsaved, "拖动即时应用并标记未保存")
	check(settings.get_value("master_volume") == 43 and read_file(settings.storage_path) == old, "拖动期间旧偏好文件不变")
	check(settings.save() and not settings.unsaved, "结束调整提交")
	var real_path: String = settings.storage_path
	settings.storage_path = folder.path_join("missing-parent/settings.json")
	check(not settings.set_value("effect_volume", 29) and settings.unsaved and not settings.last_error.is_empty(), "写入失败保留当前值与错误")
	check(settings.get_value("effect_volume") == 29 and read_file(real_path).contains('43'), "写失败不还原当前偏好或破坏原文件")
	settings.storage_path = real_path
	check(settings.save() and settings.last_error.is_empty(), "重试整体提交当前六项")
	check(not settings.set_value("mute", "false") and not settings.set_value("master_volume", NAN), "坏类型和非有限数拒绝")
	settings.busy = true
	check(not settings.restore_defaults() and not settings.set_value("mute", true), "写入锁拒绝重入")
	settings.busy = false
	check(settings.restore_defaults() and settings.values == settings.DEFAULTS, "确认恢复精确初值")
	settings.queue_free()

func narrative_checks() -> void:
	var service := Narrative.new()
	root.add_child(service)
	var data := {"texts": {"A": {"text": "甲，乙。丙丁", "speaker_name": "男人", "next_text_id": "B", "read_version": 1}, "B": {"text": "新句", "speaker_name": "甲", "read_version": 1}}, "chapters": {}, "scenes": {}, "events": {}, "transitions": {}, "performance_events": {}}
	check(service.initialize(data) and service.start("A"), "文案夹具准备")
	check(not service.advance() and service.visible_text().is_empty(), "首读继续不瞬间补齐")
	service.tick(0.0)
	check(service.visible_text().is_empty(), "零时间不凭帧数出现字符")
	service.tick(0.034)
	check(service.visible_text() == "甲", "30字每秒首字")
	service.tick(0.034)
	check(service.visible_text() == "甲，", "标点作为一个可见字素")
	service.tick(0.08)
	check(service.visible_text() == "甲，", "逗号后保留120毫秒停顿")
	service.set_hidden(true)
	var frozen: String = service.visible_text()
	service.tick(2)
	check(service.visible_text() == frozen and not service.begin_fast_read("skip"), "隐藏冻结正文并拒绝快读")
	check(service.advance() and not service.hidden and service.visible_text() == frozen, "恢复输入不推进")
	service.set_log_open(true)
	service.tick(2)
	check(service.visible_history()[0].speaker_name == "男人" and service.visible_history()[0].text == frozen, "记录只含实际出现字符与历史称呼")
	service.set_log_open(false)
	service.set_page_ends([4, 6])
	service.tick(2)
	check(service.visible_text() == "甲，乙。" and service.can_read_again("A"), "第一页完整不补整条已看")
	service.advance()
	check(service.state.page_start == 4 and service.is_typing(), "末页开始时清空本页字符")
	service.tick(1)
	check(service.visible_text() == "丙丁" and service.can_read_again("A"), "末页完整仍等待主动继续")
	service.advance()
	check(not service.can_read_again("A") and service.current_text() == "新句", "离开末页才登记已看")
	service.seen_storage_path = folder.path_join("seen.json")
	check(service._persist_seen(), "已看记录独立写盘")
	var registry := Narrative.new()
	root.add_child(registry)
	registry.initialize(data)
	check(registry.load_seen_registry(service.seen_storage_path) and not registry.can_read_again("A") and registry.can_read_again("B"), "重启读取已看资格而不补未走分支")
	registry.queue_free()
	check(not service.begin_fast_read("accelerate"), "新句不能继承已看加速")
	service.start("A")
	check(service.begin_fast_read("skip"), "重复阅读可跳过")
	service.tick(0.2)
	check(service.current_text() == "新句" and service.fast_mode.is_empty() and service.visible_text().is_empty(), "快读遇未看句停止在正常起点")
	var bad := service.export_snapshot()
	bad.state.visible_history = [null]
	check(not service.validate_snapshot(bad), "畸形阅读记录拒绝")
	bad = service.export_snapshot()
	bad.state.visible_characters = []
	check(not service.validate_snapshot(bad), "畸形阅读游标先验证类型")
	var branching := data.duplicate(true)
	branching.transitions = {"COND": {"source_text_id": "A", "transition_type": "条件分支", "target_text_id": "B", "condition": "[X] == 1"}, "PARALLEL": {"source_text_id": "A", "transition_type": "并列展示", "target_text_id": "B"}}
	check(service.initialize(branching) and service.start("A"), "非线性接续夹具准备")
	service.tick(4)
	check(not service.advance() and service.state.current_text_id == "A" and not service.state.waiting_for_choice, "条件与并列接续不被冒充选项或静默选第一项")
	service.catalog.data.events = {"E": {"content": "制作说明：移动人物并发卡"}}
	check(not service.start_event("E") and service.state.current_text_id == "A" and not service.advance(), "待配事件不执行说明或绕过等待")
	service.queue_free()

func catalog_overlap_checks() -> void:
	var catalog := preload("res://systems/core_gameplay/core_catalog.gd").new()
	catalog.load_files("res://data/core/placeholder_case.json")
	var base: Dictionary = catalog.data.duplicate(true)
	base.contents.A1["observations"] = ["OBS_A"]
	base.contents.A2["observations"] = ["OBS_B"]
	base.conditions["ONLY_A"] = [[{"kind": "observation", "ref": "OBS_A"}]]
	base.conditions["ONLY_B"] = [[{"kind": "observation", "ref": "OBS_B"}]]
	base.relations = {"FIRST": {"question_id":"Q1","statement_id":"S1","feedback":"incorrect","node":"N_BAD","result_key":"","materials":[base.relations.R_ONE.materials[0]],"match_scope":"exact_set","condition":"ONLY_A"},"SECOND":{"question_id":"Q1","statement_id":"S1","feedback":"incorrect","node":"N_OTHER","result_key":"","materials":[base.relations.R_ONE.materials[0]],"match_scope":"exact_set","condition":"ONLY_B"}}
	catalog.data = base
	catalog.data.relations.FIRST.materials = [catalog.material_ref("A1")]
	catalog.data.relations.SECOND.materials = [catalog.material_ref("A1")]
	catalog.errors.clear(); catalog._validate_relation_overlap()
	check(catalog.errors.is_empty(), "精确所选版本无法具备的观察不会误报关系重叠")
	catalog.data.relations.SECOND.condition = "ONLY_A"
	catalog._validate_relation_overlap()
	check(not catalog.errors.is_empty(), "同一材料和观察的不同同级回应接入前报冲突")

func map_checks() -> void:
	var session := Session.new()
	session.seen_storage_path = ""
	root.add_child(session)
	check(session.initialize("res://data/core/placeholder_case.json"), "地图事务夹具准备")
	session.start_new_game()
	var core: Node = session.core
	core.catalog.data.scenes["SECOND"] = {"name": "second"}
	core.catalog.data["scene_links"] = {"MOVE": {"from_scene": "ROOM", "to_scene": "SECOND", "condition": "ALWAYS"}}
	var map: Node = session.map_navigation
	var definition := {"scenes": {"ROOM": {"name": "room"}, "SECOND": {"name": "second"}}, "boards": {"FLOOR": {"rows": 4, "cols": 5}}, "nodes": {"A": {"scene_id": "ROOM", "group_id": "FLOOR", "grid_col": 0, "grid_row": 0}, "B": {"scene_id": "SECOND", "group_id": "FLOOR", "grid_col": 3, "grid_row": 2}}, "transitions": [{"transition_id": "MOVE", "from_scene": "ROOM", "to_scene": "SECOND", "condition": "ALWAYS"}]}
	map.configure(definition)
	var invalid := definition.duplicate(true)
	invalid.nodes.B.grid_col = 5
	check(not map.configure(invalid) and map.map_definition == definition and not map.configuration_errors.is_empty(), "越界地图拒绝并保留上一有效定义")
	invalid = definition.duplicate(true)
	invalid.nodes.B.grid_col = 0; invalid.nodes.B.grid_row = 0
	check(not map.configure(invalid) and map.map_definition == definition, "地图点击区重叠在接入前拒绝")
	invalid = definition.duplicate(true)
	invalid.transitions.append(invalid.transitions[0].duplicate(true))
	check(not map.configure(invalid) and map.map_definition == definition, "地点连接重复ID不覆盖上一有效配置")
	invalid = definition.duplicate(true)
	invalid.nodes.B.scene_id = "MISSING"
	check(not map.configure(invalid), "地图节点坏场景引用拒绝")
	invalid = definition.duplicate(true)
	invalid.scenes.ROOM.background_ref = "MISSING"
	check(not map.configure(invalid), "场景坏资源身份接入前拒绝")
	check(map.configure(definition), "修正后可重新接入同一地图")
	map.bind_visual_controller()
	map.open(); map.select_scene("SECOND")
	check(map.travel() and map.state.phase == "preparing" and core.state.current_scene_id == "ROOM", "普通准备不提前移动")
	var first_id := str(map.state.active_request.request_id)
	check(map.cancel_preparation() and map.state.open and map.state.phase == "browsing", "准备取消回同一地图")
	check(not map.complete_preparation(first_id) and core.state.current_scene_id == "ROOM", "迟到准备结果失效")
	map.travel()
	var second_id := str(map.state.active_request.request_id)
	core.set_paused(true)
	check(not map.complete_preparation(second_id) and map.state.phase == "preparing", "失焦暂停不提交后台就绪")
	core.set_paused(false)
	check(map.complete_preparation(second_id) and map.state.phase == "moving", "主动继续重新准备后才提子")
	check(map.movement_path() == [Vector2(0, 0), Vector2(1, 0), Vector2(2, 0), Vector2(3, 0), Vector2(3, 1), Vector2(3, 2)], "棋子路径先横后纵且每步四邻格")
	map.close()
	check(map.state.open and core.state.current_scene_id == "ROOM", "提子后不可取消且中间格不改地点")
	check(map.finish_movement() and core.state.current_scene_id == "SECOND", "终点上方提交一次地点")
	check(not map.finish_movement(), "重复完成不会再提交")
	map.begin_transition(); map.finish_transition()
	check(not map.state.open and map.can_save(), "到达转场结束才恢复保存资格")
	var old: Dictionary = session.export_snapshot()
	map.locations.SECOND["background_ref"] = "MISSING"
	check(not session.restore_snapshot(old) and session.export_snapshot() == old, "读档目标必需资源失败保留所有模块")
	map.locations.SECOND.erase("background_ref")
	check(session.restore_snapshot(old), "资源恢复后重试同一档案")
	core.catalog.data.scene_links["BACK"] = {"from_scene": "SECOND", "to_scene": "ROOM", "condition": "ALWAYS"}
	map.transitions["BACK"] = {"from_scene": "SECOND", "to_scene": "ROOM", "condition": "ALWAYS"}
	map.locations.ROOM["background_ref"] = "MISSING"
	map.open(); map.select_scene("ROOM"); map.travel()
	map.complete_preparation(str(map.state.active_request.request_id))
	check(map.state.phase == "failure" and core.state.current_scene_id == "SECOND", "普通目的地准备失败留原地点")
	map.close()
	session.queue_free()

func configured_map_page_checks() -> void:
	var session := Session.new()
	session.seen_storage_path = ""
	root.add_child(session)
	session.initialize("res://data/core/placeholder_case.json")
	session.start_new_game()
	var core: Node = session.core
	core.catalog.data.scenes["SECOND"] = {"name": "第二地点"}
	core.catalog.data["scene_links"] = {"MOVE": {"from_scene": "ROOM", "to_scene": "SECOND", "condition": "ALWAYS"}}
	var map: Node = session.map_navigation
	map.configure({"scenes": {"ROOM": {"name": "起点"}, "SECOND": {"name": "终点"}}, "boards": {"F": {"rows": 4, "cols": 5}}, "nodes": {"A": {"scene_id": "ROOM", "group_id": "F", "grid_col": 0, "grid_row": 0}, "B": {"scene_id": "SECOND", "group_id": "F", "grid_col": 3, "grid_row": 2}}, "transitions": [{"transition_id": "MOVE", "from_scene": "ROOM", "to_scene": "SECOND", "condition": "ALWAYS"}]})
	var page := preload("res://pages/map_navigation/map_navigation_page.gd").new()
	root.add_child(page)
	page.size = Vector2(1280, 720)
	page.set_process(false)
	page.bind(map); page.open()
	await frames()
	var markers: Array[Button] = []
	for child in page.board_view.get_children():
		if child is Button: markers.append(child)
	check(markers.size() == 2 and markers[0].get_rect().size.y <= 50 and not markers[0].get_global_rect().intersects(markers[1].get_global_rect()), "棋盘长名称不会撑高触区或重叠其他落点")
	check(map.scene_name("SECOND") == "第二地点", "地图优先使用故事地点名称，直接文字不因缺少文字引用变空")
	map.select_scene("SECOND"); map.travel()
	await frames()
	check(is_instance_valid(page.board_view) and page.route.size() == 6, "配置棋盘渲染并生成五步路线")
	core.set_paused(true)
	page._process(2.0)
	check(page.animation_ms == 0 and core.state.current_scene_id == "ROOM", "页面暂停冻结姿态与地点")
	core.set_paused(false)
	for i in range(26): page._process(0.01)
	check(core.state.current_scene_id == "ROOM", "第一格只改表现不提交调查地点")
	for i in range(230):
		page._process(0.01)
		if not page.visible: break
	check(not page.visible and core.state.current_scene_id == "SECOND", "逐格落子确认转场后才关闭地图")
	check(map.state.request_serial == 1 and not page.is_processing(), "整条路线只接受一个移动事务")
	page.queue_free(); session.queue_free()
	await frames()

func inspection_atomic_checks() -> void:
	var session := Session.new()
	session.seen_storage_path = ""
	root.add_child(session)
	session.initialize("res://data/core/placeholder_case.json")
	session.start_new_game()
	var core: Node = session.core
	var investigation: Node = session.scene_interaction
	var original: Array = core.catalog.data.entries.INSPECT.contents.duplicate()
	var request: Dictionary = investigation.begin_inspection("story/INSPECT")
	core.catalog.data.entries.INSPECT.contents.append("MISSING")
	var before: Dictionary = core.export_card_state()
	check(not investigation.commit_inspection(request.request_id).ok and core.export_card_state() == before and investigation.state.observations.is_empty(), "检查多份材料坏引用不产生半批材料或观察")
	core.catalog.data.entries.INSPECT.contents = original
	check(investigation.commit_inspection(request.request_id).ok and core.store.owns(core.catalog.material_ref("A1")), "修正资源后重试同一检查请求")
	session.queue_free()

func stage_checks() -> void:
	var stage := preload("res://pages/narrative/narrative_stage.gd").new()
	root.add_child(stage)
	stage.size = Vector2(1280, 720)
	var catalog := preload("res://systems/narrative/narrative_catalog.gd").new()
	catalog.data = {"scenes": {}}
	# 使用仓库自有图标验证摆放，不把它绑定成正式人物素材。
	var row := {"character_id": "A", "scene_id": "SCENE", "position": "左", "avatar_path": "res://art/visual/loop_mark.svg", "text_type": "对白"}
	stage.apply_record(row, catalog)
	check(stage.occupants.size() == 1 and stage.occupants.has(1), "明确位置生成左位立绘")
	row.character_id = "B"; row.position = "右"
	stage.apply_record(row, catalog)
	check(stage.occupants.size() == 2 and is_equal_approx(stage.occupants[1].node.modulate.r, 0.88), "非发言者保留并降亮度")
	row.character_id = "A"; row.position = "中"
	stage.apply_record(row, catalog)
	check(not stage.occupants.has(1) and stage.occupants.has(2) and stage.occupants.has(3), "同人物换位只清旧位")
	row.position = ""; row.character_id = "C"; row.text_type = "画外对白"
	stage.apply_record(row, catalog)
	check(stage.occupants.size() == 2, "空位置与画外发言不自动生成或挪动人物")
	row.scene_id = "NEW"; row.text_type = "旁白"
	stage.apply_record(row, catalog)
	check(stage.occupants.is_empty(), "新场景清除旧舞台人物")
	# 清空人物位只动人物；站在场景里的人物以图层呈现，不再另起槽位立绘。
	var icon := "res://art/visual/loop_mark.svg"
	var base := {"scene_id": "SCENE2", "background_path": icon, "text_type": "对白", "avatar_path": icon}
	stage.apply_record(base.merged({"character_id": "A", "position": "左"}, true), catalog)
	stage.apply_record(base.merged({"character_id": "B", "position": "右"}, true), catalog)
	check(stage.occupants.size() == 2, "同场景连续发言保留两位人物")
	stage.apply_record(base.merged({"character_id": "C", "position": "中", "clear_positions": true}, true), catalog)
	check(stage.occupants.size() == 1 and stage.occupants.has(2) and stage.scene_id == "SCENE2" and stage.background.texture != null, "清空人物位只清人物，不动背景与地点")
	stage.apply_record(base.merged({"character_id": "A", "position": "左", "clear_positions": true}, true), catalog)
	check(stage.occupants.size() == 1 and stage.occupants.has(1), "清空人物位后发言人仍按位置入场")
	var layers := [
		{"image_path": icon, "x": 100, "y": 200, "w": 300, "h": 400, "character_id": "A"},
		{"image_path": icon, "x": 900, "y": 200, "w": 300, "h": 400, "character_id": "B"},
		{"image_path": "res://art/visual/missing_layer.png", "x": 0, "y": 0, "w": 10, "h": 10, "character_id": "D"},
		{"image_path": icon, "x": 600, "y": 700, "w": 100, "h": 100, "character_id": ""}]
	stage.apply_record(base.merged({"character_id": "A", "position": "左", "scene_layers": layers}, true), catalog)
	check(stage.scene_layers.size() == 3, "缺图的场景图层被跳过，其余照常建立")
	check(stage.occupants.is_empty(), "已站在场景里的发言人不再另起槽位立绘，旧槽位一并撤下")
	var layer_a: TextureRect = stage.scene_layers[0].node
	var layer_b: TextureRect = stage.scene_layers[1].node
	check(layer_a.position.is_equal_approx(Vector2(80, 160)) and layer_a.size.is_equal_approx(Vector2(240, 320)), "场景图层按调查画面坐标缩放到舞台")
	check(layer_a.modulate == Color.WHITE and is_equal_approx(layer_b.modulate.r, 0.88), "发言人所在图层保持亮度，其他场景人物变暗")
	stage.apply_record(base.merged({"character_id": "", "text_type": "旁白", "scene_layers": layers}, true), catalog)
	check(stage.scene_layers.all(func(item): return item.node.modulate == Color.WHITE), "旁白时场景人物都不变暗")
	stage.apply_record(base.merged({"character_id": "E", "position": "右"}, true), catalog)
	check(stage.scene_layers.is_empty() and stage.occupants.has(3), "记录不带图层时清掉上一幕图层")
	stage.queue_free()

func pagination_checks() -> void:
	# 分页只依赖字体度量；用与正文相同的 RichTextLabel 取字体，断言的是性质而非具体字数。
	var Page := preload("res://pages/narrative/narrative_page.gd")
	var label := RichTextLabel.new()
	label.add_theme_font_size_override("normal_font_size", 32)
	root.add_child(label)
	await frames(2)
	var font: Font = label.get_theme_font("normal_font")
	var width := 1192.0
	check(Page.page_ends("", font, 32, width) == [0] and Page.page_ends("很短的一句。", font, 32, width) == [6], "空文与单页短句各只有一个终点")
	var sentences := "这是一句用来检验分页的台词，它长度适中。".repeat(16)
	var cases := {"短句重复": sentences, "无标点长串": "字".repeat(260), "带换行": "第一段话。\n".repeat(8) + sentences, "标点扎堆": ("他说：“没有，真的没有……”" + "。".repeat(3)).repeat(30)}
	for name in cases:
		var text: String = cases[name]
		var ends: Array[int] = Page.page_ends(text, font, 32, width)
		var ordered := ends[-1] == text.length()
		var fits := true
		var punctuation_start := false
		var start := 0
		for index in range(ends.size()):
			ordered = ordered and ends[index] > start
			fits = fits and Page._text_lines(text.substr(start, ends[index] - start), font, 32, width).get_line_count() <= 2
			if start > 0 and Page.LINE_START_FORBIDDEN.contains(text[start]): punctuation_start = true
			start = ends[index]
		check(ends.size() > 1 and ordered and fits, name + "：分页终点递增，每页不超过两行")
		check(not punctuation_start, name + "：新页不以标点开头")
	var ends: Array[int] = Page.page_ends(sentences, font, 32, width)
	var natural := true
	for index in range(ends.size() - 1): natural = natural and Page.SENTENCE_MARKS.contains(sentences[ends[index] - 1])
	check(natural, "句子较短时每页都停在句末，不在句中翻页")
	check(ends.size() < 2 or ends[-1] - ends[-2] >= Page.STUB_CHARS, "末页不留只有几个字的残页")
	label.queue_free()

func narrative_input_checks() -> void:
	var service := Narrative.new()
	root.add_child(service)
	var page := preload("res://pages/narrative/narrative_page.gd").new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.set_process(false) # 本测试固定时钟，只通过真实输入改变阅读状态。
	page.bind(service)
	var data := {"texts": {"A": {"text": "这是两行分页的长句，用于验证输入与已看规则。".repeat(15), "read_version": 1}, "B": {"text": "尚未走过的分支。", "read_version": 1}}, "chapters": {}, "scenes": {}, "events": {}, "transitions": {}, "performance_events": {}}
	service.initialize(data); service.start("A")
	await frames(8)
	check(page.pagination_ready and service.page_end() < service.current_text().length() and service.visible_text().is_empty(), "文案布局完成后按实际宽度分页而不先露全文")
	service.tick(20)
	await frames()
	check(page.text_label.get_line_count() <= 2, "长对白每页最多两行")
	check(page.name_label.get_theme_font_size("font_size") > page.text_label.get_theme_font_size("normal_font_size"), "姓名字号大于正文")
	check(page.name_label.get_theme_color("font_color") != page.text_label.get_theme_color("default_color"), "姓名与正文颜色不同")
	var visible_before: String = service.visible_text()
	await press_key(KEY_H)
	check(service.hidden, "H隐藏对白")
	await press_key(KEY_ENTER)
	check(not service.hidden and service.visible_text() == visible_before, "恢复对白的Enter不同时翻页")
	# 开始第二次阅读后，Tab应进入跳过，不能被默认UI焦点导航吞掉。
	service.seen_versions["A"] = 1
	service.start("A")
	await frames(8)
	page.fast_button.grab_focus()
	await press_key(KEY_TAB)
	check(service.fast_mode == "skip", "正文Tab启动跳过已看")
	await press_key(KEY_TAB)
	check(service.fast_mode.is_empty(), "再次Tab停止跳过")
	await send_key(KEY_CTRL, true)
	check(service.fast_mode == "accelerate", "Ctrl按下进入四倍加速")
	await send_key(KEY_CTRL, false)
	check(service.fast_mode.is_empty(), "Ctrl松开立即停止加速")
	service.set_log_open(true)
	await frames()
	await press_key(KEY_H)
	check(service.reading_log and not service.hidden, "记录打开时H不隐藏底层对白")
	service.set_log_open(false)
	service.start("B")
	await frames(8)
	await press_key(KEY_TAB)
	check(service.fast_mode.is_empty() and service.visible_text().is_empty(), "未看文本Tab不补全文或产生快读")
	page.queue_free(); service.queue_free()
	await frames()

func session_checks() -> void:
	var session := Session.new()
	root.add_child(session)
	check(session.initialize("res://data/core/placeholder_case.json"), "联合会话初始化")
	session.start_new_game()
	var old: Dictionary = session.export_snapshot()
	for module in ["scene_interaction_snapshot", "map_navigation_snapshot", "narrative_snapshot", "cat_snapshot"]:
		var broken: Dictionary = old.duplicate(true)
		broken[module] = []
		check(not session.restore_snapshot(broken) and session.export_snapshot() == old, "坏模块失败不替换会话：" + module)
	var mismatch: Dictionary = old.duplicate(true)
	mismatch.scene_interaction_snapshot.state.current_scene_id = "missing"
	check(not session.restore_snapshot(mismatch) and session.export_snapshot() == old, "联合地点不一致拒绝且保持原状态")
	session.cat.enter({"pet_ms": 600, "response_ms": 1200}, {}, {})
	check(not session.can_save(), "猫等待态同样禁手动存与先存后读")
	session.cat.begin_touch(false)
	session.cat.pause()
	session.cat.advance(600)
	check(session.cat.remaining_ms() == 600, "猫菜单暂停冻结时钟")
	session.cat.resume()
	session.cat.advance(600)
	check(not session.cat.first_seen, "推进到回应不冒称看见素材")
	session.cat.notify_stable_displayed()
	session.finish_cat()
	check(session.can_save() and session.export_snapshot().cat_snapshot.first_seen, "猫返回后可存且保存首见")
	var legacy: Dictionary = old.duplicate(true)
	legacy.erase("cat_snapshot")
	check(session.restore_snapshot(legacy) and not session.cat.first_seen and not session.cat.is_active(), "旧档缺猫字段恢复为未首见并不重播")
	var loader := SceneLoader.new()
	var formal := loader.load_workbook()
	var sample := loader.load_workbook(SceneLoader.DEFAULT_PATH, "test")
	check(formal.hotspots.is_empty() and formal.display.canvas_width == 1600, "正式调查表过滤匿名热点并采用显示参数")
	check(sample.hotspots.size() == 2 and sample.object_images.size() == 3, "显式测试作用域读取同一结构")
	var core: Node = session.core
	core.catalog.data.contents.A1["observations"] = ["OBS_A"]
	core.catalog.data.conditions["OBS_SELECTED"] = [[{"kind": "observation", "ref": "OBS_A"}]]
	check(core.condition_met("OBS_SELECTED", [core.catalog.material_ref("A1")]) and not core.condition_met("OBS_SELECTED", [core.catalog.material_ref("A2")]), "观察条件只检查所选精确版")
	session.queue_free()

func clock_and_summary_checks() -> void:
	var session := Session.new()
	root.add_child(session)
	session.set_process(false)
	session.seen_storage_path = ""
	var time := [0]
	session.clock_usec = func(): return time[0]
	session.initialize("res://data/core/placeholder_case.json")
	session.start_new_game()
	session.set_activity_enabled(true)
	time[0] += 3500000
	check(session.export_snapshot().elapsed_seconds == 3.5, "调查和阅读期间累计单调时间")
	session.set_activity_enabled(false)
	time[0] += 10000000
	check(session.export_snapshot().elapsed_seconds == 3.5, "暂停与设置不计调查时长")
	session.set_activity_enabled(true)
	session.set_window_focused(false)
	time[0] += 5000000
	session.set_window_focused(true)
	session.set_file_processing(true)
	time[0] += 5000000
	session.set_file_processing(false)
	check(session.export_snapshot().elapsed_seconds == 3.5, "失焦与文件处理不计调查时长")
	time[0] += 500000
	var snapshot: Dictionary = session.export_snapshot()
	check(snapshot.elapsed_seconds == 4.0 and not snapshot.progress_summary.scene.is_empty(), "恢复后继续计时且摘要随完整档案冻结")
	session.set_activity_enabled(false)
	var save := Save.new()
	root.add_child(save)
	save.storage_path = folder.path_join("clock-saves")
	save.snapshot_validator = session.validate_snapshot
	check(save.save_snapshot("manual", 0, snapshot), "累计时长联合落盘")
	var info: Dictionary = save.slot_info("manual", 0)
	check(info.elapsed == "00:00:04" and info.scene == snapshot.progress_summary.scene and info.saved_time.length() == 16 and info.full_summary.contains("保存序号 1"), "档案显示本机时间与真实累计时长")
	check(save._short_text("甲🙂乙丙丁", 4) == "甲🙂乙…", "摘要按完整字符省略")
	snapshot.elapsed_seconds = 360000
	save.save_snapshot("manual", 1, snapshot)
	check(save.slot_info("manual", 1).elapsed == "100:00:00", "超过99小时保留实际位数")
	snapshot.erase("elapsed_seconds"); snapshot.erase("progress_summary")
	check(session.restore_snapshot(snapshot) and session.export_snapshot().elapsed_seconds == null, "旧档缺时长时保持未知，不填零")
	save.save_snapshot("manual", 2, snapshot)
	check(save.slot_info("manual", 2).elapsed.is_empty() and save.slot_info("manual", 2).scene.is_empty(), "旧档摘要缺值不借用当前调查")
	var broken := snapshot.duplicate(true)
	broken.elapsed_seconds = -1
	check(not session.validate_snapshot(broken), "负累计时长拒绝")
	broken.elapsed_seconds = []
	check(not session.validate_snapshot(broken), "畸形累计时长拒绝")
	save.queue_free(); session.queue_free()

func page_checks() -> void:
	scene = load("res://main/main.tscn").instantiate()
	scene.story_workbook_path = "res://data/core/placeholder_case.json"
	scene.test_storage_path = folder.path_join("pages")
	root.add_child(scene)
	await frames()
	scene.title_page.new_game_requested.emit()
	check(scene.current_layer == "confirm" and root.gui_get_focus_owner() == scene.confirm_page.cancel_button, "新游戏先确认且默认取消")
	scene._on_confirm_cancel()
	check(scene.save_service.sequence == 0 and scene.current_layer == "title", "取消新游戏不写盘")
	scene._request_new_game()
	scene._on_confirm_accept()
	await frames()
	check(scene.save_service.sequence == 1 and not scene.game_start_service.initial_save_failed, "新游戏首次可操作节点写初档")
	scene._open_pause()
	scene._on_save()
	scene.save_page._save_slot(1)
	check(scene.save_service.sequence == 1 and not scene.save_service.slot_info("manual", 1).exists, "点击保存栏位只选择")
	scene.save_page._submit()
	check(scene.save_service.sequence == 2 and scene.current_layer == "subpage" and scene.save_page.status_label.text == "保存完成", "显式保存写入原选择且停留显示完成")
	scene.save_page._save_slot(1)
	scene.save_page._submit()
	check(scene.save_page.confirmation.visible and scene.save_service.sequence == 2, "已有档覆盖需确认")
	scene.save_page._cancel_overwrite()
	check(scene.save_service.sequence == 2, "取消覆盖不写盘")
	scene._on_close_subpage()
	scene._on_load()
	check(scene.load_page.box.get_child_count() == 10, "读取固定五栏加状态与提交按钮")
	scene.load_page._load_slot("manual", 1)
	check(not scene.load_page.confirmation.visible and scene.current_layer == "subpage", "选择读取目标不替换")
	scene.load_page._request_load()
	check(scene.load_page.confirmation.visible, "点击读取才确认替换")
	scene.load_page._save_first()
	check(scene.pending_load and scene.save_page.exclusion == 1 and scene.save_page.slot_buttons[1].disabled, "先存后读排除原目标栏位")
	scene._on_close_subpage()
	check(not scene.pending_load and scene.load_page.confirmation.visible, "取消先存返回原读取确认")
	scene.load_page._save_first()
	scene.save_page._save_slot(0)
	scene.save_page._submit()
	await frames()
	check(scene.current_layer == "investigation" and scene.save_service.sequence == 3, "先存成功后只读取冻结的原目标")
	scene._open_pause(); scene._on_settings()
	var page: Control = scene.settings_page
	await frames()
	var slider: HSlider = page.sliders.master_volume
	var rect := slider.get_global_rect()
	var start := Vector2(rect.position.x + rect.size.x - 10, rect.get_center().y)
	var target := Vector2(rect.position.x + rect.size.x * 0.33, rect.get_center().y)
	var previous_file := read_file(scene.settings_service.storage_path)
	await move_mouse(start)
	check(root.gui_get_hovered_control() == slider, "设置滑条真实鼠标命中，无覆盖层挡住")
	await mouse_button(start, true)
	await move_mouse(target, true)
	check(page.adjusting and scene.settings_service.get_value("master_volume") < 50 and read_file(scene.settings_service.storage_path) == previous_file, "拖动实时改整数音量且松开前不写盘")
	await mouse_button(target, false)
	check(not page.adjusting and not scene.settings_service.unsaved and read_file(scene.settings_service.storage_path) != previous_file, "鼠标松开才持久化完整偏好")
	var before_key: int = scene.settings_service.get_value("master_volume")
	slider.grab_focus()
	await send_key(KEY_RIGHT, true)
	check(scene.settings_service.get_value("master_volume") == before_key + 5 and scene.settings_service.unsaved, "键盘步长五且按住期间不落盘")
	await send_key(KEY_RIGHT, false)
	check(not scene.settings_service.unsaved, "方向键松开提交")
	scene.settings_service.set_value("master_volume", 55)
	page._restore_defaults()
	await press_key(KEY_TAB)
	check(root.gui_get_focus_owner() == page.reset_confirmation.accept_button, "恢复默认Tab只移动到确认")
	await press_key(KEY_TAB)
	check(root.gui_get_focus_owner() == page.reset_confirmation.cancel_button, "确认框Tab循环不落到底层滑条")
	await press_key(KEY_TAB, true)
	check(root.gui_get_focus_owner() == page.reset_confirmation.accept_button, "ShiftTab在确认框反向循环")
	page._cancel_reset()
	check(scene.settings_service.get_value("master_volume") == 55, "恢复默认取消保持当前设置")
	page._restore_defaults(); page._confirm_reset()
	await frames()
	check(scene.settings_service.values == scene.settings_service.DEFAULTS and page.sliders.size() == 4, "恢复确认一次提交且安全重建")
	page._begin_adjustment("master_volume")
	page.sliders.master_volume.value = 44
	check(scene.settings_service.unsaved and scene.settings_service.get_value("master_volume") == 44, "页面调整中只应用")
	page._request_close()
	check(page.visible and not scene.settings_service.unsaved, "第一次关闭仅结束调整并提交")
	page._request_close()
	check(scene.current_layer == "pause", "第二次关闭返回原暂停")
	# 写入路径故障只影响本测试目录；旧档和新会话必须都在。
	scene._on_resume()
	var real_path: String = scene.save_service.storage_path
	var blocker := folder.path_join("not-a-directory")
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	file.store_string("blocked"); file.close()
	scene.save_service.storage_path = blocker
	scene._on_new_game()
	check(scene.game_start_service.initial_save_failed and scene.current_layer == "investigation" and scene.gameplay_page.initial_save_retry.visible, "初档失败保留新调查并提供重试")
	scene.save_service.storage_path = real_path
	scene._retry_initial_save()
	check(not scene.game_start_service.initial_save_failed and not scene.gameplay_page.initial_save_retry.visible, "初档重试使用当前稳定会话")
	scene.queue_free()
	await frames()

func _run() -> void:
	root.size = Vector2i(1280, 800)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	settings_checks()
	narrative_checks()
	catalog_overlap_checks()
	session_checks()
	clock_and_summary_checks()
	map_checks()
	inspection_atomic_checks()
	await configured_map_page_checks()
	stage_checks()
	await pagination_checks()
	await narrative_input_checks()
	await page_checks()
	if failures.is_empty(): print("SYSTEM_AUDIT_PASS: %d checks" % checks)
	else: printerr("SYSTEM_AUDIT_FAIL: %d / %d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
