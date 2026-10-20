extends RefCounted
## 正式十二册配置的唯一读取入口。原工作簿只读；不使用参考JSON替代策划填写的数据。
const Reader = preload("res://systems/config/workbook_reader.gd")
const DEFAULT_ROOT := "res://极光_主策合并交付_20261019"
const BOOKS := {
	"core": "01_核心玩法/玩法策划案.xlsx", "narrative": "02_文案/文案配置表.xlsx",
	"investigation": "03_调查与场景交互/调查与场景交互系统配置表.xlsx",
	"handbook": "04_办案手册/办案手册系统配置表.xlsx", "map": "05_地图切换/地图切换系统配置表.xlsx",
	"objective": "06_目标导航/目标导航系统配置表.xlsx", "start": "07_初始化与开始/游戏初始化与开始系统配置表.xlsx",
	"save": "08_存读档/存读档系统配置表.xlsx", "settings": "09_游戏设置/游戏设置系统配置表.xlsx",
	"audio": "10_声音播放/声音播放系统配置表.xlsx", "cat": "11_撸猫/撸猫系统配置表.xlsx",
	"tutorial": "12_联合新手引导/联合新手引导配置表.xlsx",
}
var definition := {"root": DEFAULT_ROOT}
var errors: Array[String] = []
var warnings: Array[String] = []
var tables := {}
var texts := {}
var entries := {}
var sequences := {}
var conditions := {}
var events := {}
var jumps := {}
var contents := {}
var materials := {}
var profiles := {}
var actors := {}
var chapters := {}
var ui_texts := {}
var scenes := {}
var resources := {}
var questions := {}
var results := {}
var relations: Array = []
var path_migrations := {}
var narrative_data: Dictionary = {}
var tutorial_data: Dictionary = {}
var content_revision := "AVG_20261019_FINAL_SCRIPT_MERGED_01"
var _audio_overrides := {} # 1020资源清单 resource_overrides 的音频别名缓存：逻辑键 → 实际 res:// 路径。

func load_package(root: String = DEFAULT_ROOT) -> bool:
	definition.root = root
	errors.clear()
	warnings.clear()
	tables.clear()
	conditions.clear()
	events.clear()
	jumps.clear()
	questions.clear()
	path_migrations.clear()
	narrative_data.clear()
	tutorial_data.clear()
	_audio_overrides.clear()
	for key in BOOKS:
		var reader := Reader.new()
		if not reader.open(root.path_join(BOOKS[key])):
			errors.append_array(reader.errors)
			continue
		tables[key] = {}
		for sheet in reader.tables:
			if str(sheet).begins_with("##"): continue
			tables[key][sheet] = reader.records(sheet)
		errors.append_array(reader.errors)
	if not errors.is_empty(): return false
	texts = index("narrative", "脚本文本", "text_id")
	entries = index("narrative", "剧情片段字典", "entry_id")
	sequences = index("narrative", "剧情片段字典", "sequence_id")
	actors = index("narrative", "人物字典", "character_id")
	chapters = index("narrative", "章节字典", "chapter_id")
	contents = index("handbook", "材料内容", "content_id")
	materials = index("handbook", "材料字典", "material_id")
	profiles = index("handbook", "人物资料", "profile_id")
	# 调查文字关联中的INV入口是正式公开入口，不要求再抄入剧情片段字典。
	for feedback in rows("narrative", "调查文字关联"):
		var id := str(feedback.entry_id)
		if not entries.has(id):
			entries[id] = {"entry_id": id, "sequence_id": "", "entry_kind": "investigation", "location_mode": "caller", "feedback_entry": true, "allowed_scene_ids": ""}
		if entries[id].get("feedback_entry", false):
			var allowed := ids(str(entries[id].allowed_scene_ids))
			for scene in ids(str(feedback.get("allowed_scene_ids", feedback.get("scene_id", "")))):
				if scene not in allowed: allowed.append(scene)
			entries[id].allowed_scene_ids = ";".join(allowed)
	ui_texts = index("start", "功能文字", "id")
	scenes = index("map", "场景定义", "scene_id")
	resources = index("map", "场景资源", "id")
	results = index("core", "结果接续", "id")
	relations = rows("core", "出示关系")
	for row in rows("narrative", "案件条件"):
		var id := str(row.condition_id)
		if not conditions.has(id): conditions[id] = {}
		var branch := str(row.branch)
		if not conditions[id].has(branch): conditions[id][branch] = []
		conditions[id][branch].append(row)
	_register_navigation_conditions()
	for row in rows("narrative", "事件结果"):
		var id := str(row.event_id)
		if not events.has(id): events[id] = []
		events[id].append(row)
	for id in events: events[id].sort_custom(func(a, b): return int(a.order) < int(b.order))
	for row in rows("narrative", "文本跳转"):
		var source := str(row.get("source_text_id", ""))
		if source.is_empty(): source = str(row.get("source_entry_id", ""))
		if not jumps.has(source): jumps[source] = []
		jumps[source].append(row)
	for row in rows("core", "关卡轮次"):
		var id := str(row.get("question_ref", ""))
		if not id.is_empty() and not questions.has(id): questions[id] = row
	_relocate_resources()
	_load_final_json_bindings(root)
	_repair_lorne_click_routes()
	# 最终首章迁入连续场后，阅读回执仍要求“已展示回信”；实际递交时补交既有事件。
	for jump in jumps.get("TXT_PLANNER_LETTER_002", []):
		if jump.get("target_ref") == "ENTRY_PLANNER_LETTER_DOCUMENT" and str(jump.get("event_id", "")).is_empty():
			jump.event_id = "EV_IVAN_HOSPITAL_LETTER_SHOWN"
	# 薇拉已在本段实际拿出家信；原表漏了展示回执，必须在读原件前提交。
	for jump in jumps.get("TXT_F7_CH03_ENTRY_CH03_VERA_LETTERS_004", []):
		if jump.get("target_ref") == "ENTRY_CH03_E20_READER" and str(jump.get("event_id", "")).is_empty():
			jump.event_id = "EV_VERA_LETTERS_SHOWN"
	# 无主笔记已支持在空值班室与档案间阅读，艾琳的读后观察沿同一地点返回。
	if entries.has("ENTRY_CH03_NOTEBOOK_RESPONSE"):
		entries.ENTRY_CH03_NOTEBOOK_RESPONSE.allowed_scene_ids = "SC04;SC10"
	for id in ["ENTRY_CH03_LEDGER_DISTRIBUTION_RESPONSE", "ENTRY_CH03_LEDGER_RECENT_RESPONSE"]:
		if entries.has(id): entries[id].allowed_scene_ids = "SC04;SC10"
	_repair_final_register_receipts()
	_repair_final_counter_topic()
	_repair_final_tutorial_prerequisites()
	# 正式第四章的厨房质询在旧案对证结束后开启；若第二章提前启动，
	# 完整回应会撞上仍未满足的还衣接续。入口与公开话题共用真实章节门槛。
	for id in ["COND_TOPIC_NINA_MEAL", "COND_CH04_MEAL_OBSERVATIONS_READY"]:
		for terms in conditions.get(id, {}).values():
			terms.append({"kind": "chapter", "ref": "CH04", "expected": true})
			terms.append({"kind": "event", "ref": "EV_CH03_JOINT_SCENE_FINISHED", "expected": true})
	# 结婚钱关联以实际听完尼娜分款口述为提示；原表误用尚未开启的
	# 推理题目自身作“已读”门槛，造成P02与旧案共同对证永远无法公开。
	for row in rows("core", "关卡轮次"):
		if row.get("question_ref") == "L08_R03":
			row.trigger_text_ref = "TXT_F7_CH03_ENTRY_CH03_L08_NINA_OPEN_008"
	# “回档案间”末句从空值班室承接；原表只切章，漏了进入标题前的实际移场。
	for jump in jumps.get("TXT_F7_CH04_ENTRY_F7_CH04_TO_CH05_001", []):
		if jump.get("target_ref") == "ENTRY_CH05_TITLE":
			jump["location_mode"] = "fixed"
			jump["scene_id"] = "SC04"
	# I06唯一正式两槽关系漏写其已配置题目，不能把空目标当作实际选中原话。
	for relation in relations:
		if relation.get("id") == "L15_R00_P04_T07" and str(relation.get("target_text_ref", "")).is_empty():
			relation.target_text_ref = "TXT_QUESTION_L15_R00"
	# 电话接完后沿正式“到站外接人”选项集合众人；原末句只返回大厅，
	# 留下这个没有任何前驱的选项。既有读档也可再次点电话进入该选项。
	for jump in jumps.get("TXT_F7_CH06_PHONE_003", []):
		if jump.get("target_kind") == "map" and jump.get("target_ref") == "SC02":
			jump.target_kind = "entry"
			jump.target_ref = "ACTION_CH06_LEAVE"
	conditions["COND_FINAL_PHONE_DEPARTURE"] = {"1": [
		{"kind": "chapter", "ref": "CH06", "expected": true},
		{"kind": "event", "ref": "EV_CH06_RECORDS_READY", "expected": true},
		{"kind": "event", "ref": "EV_CH06_PHONE_RECEIVED", "expected": true},
		{"kind": "event", "ref": "EV_CH06_GUESTS_GATHERED", "expected": false}]}
	for text_id in ["TXT_SC02_PHONE_FIRST_PAGE_02", "TXT_SC02_PHONE_REPEAT", "TXT_SC02_PHONE_CASE_FIRST", "TXT_SC02_PHONE_CASE_REPEAT", "TXT_SC02_PHONE_OLD_FIRST_PAGE_02", "TXT_SC02_PHONE_OLD_REPEAT"]:
		jumps[text_id].append({"source_text_id": text_id, "target_kind": "entry", "target_ref": "ACTION_CH06_LEAVE",
			"condition_id": "COND_FINAL_PHONE_DEPARTURE", "event_id": "", "timing": "after_text", "trigger": "condition"})
	# 最终包把L01三个旧分支入口都改成无正文、无事件、同一ROUTE的别名，
	# 但仍保留同时成立的三个跳转。归一成同一既有别名，不跳过ROUTE内正式逐轮正文。
	for jump in jumps.get("TALK_CH02_YURI_CURRENT", []):
		if jump.get("target_ref") in ["ENTRY_CH02_L01_TOGETHER_START", "ENTRY_CH02_L01_SEPARATED_START"]:
			jump.target_ref = "ENTRY_CH02_L01_QUESTION"
	if entries.has("ENTRY_CH03_READ_E13_RESPONSE"):
		entries.ENTRY_CH03_READ_E13_RESPONSE.allowed_scene_ids = "SC04;SC10;SC02"
	_validate()
	return errors.is_empty()

func _repair_final_counter_topic() -> void:
	# 正式正文已有伊万的完整对单口述与末句回执，话题表漏挂了公开入口。
	# 只补回本地点实际两人都在场时的话题，不提前授予T04/T05。
	conditions["COND_FINAL_IVAN_COUNTER_TOPIC"] = {"1": [
		{"kind": "chapter", "ref": "CH02", "expected": true},
		{"kind": "current_scene", "ref": "SC02", "expected": true},
		{"kind": "npc_scene", "ref": "CHR04", "scene_id": "SC02", "expected": true},
		{"kind": "npc_scene", "ref": "CHR10", "scene_id": "SC02", "expected": true},
		{"kind": "event", "ref": "EV_CASE_INVESTIGATION_OPEN", "expected": true},
		{"kind": "entry", "ref": "ENTRY_CH02_IVAN_T04_FIRST", "expected": true}]}
	rows("investigation", "话题显示").append({
		"topic_ref": "TOPIC_FINAL_IVAN_COUNTER_ACCOUNT", "kind": "topic", "data_scope": "runtime",
		"list_entry_ref": "TOPICS_1000004_SC02", "person_ref": "CHR04",
		"entry_ref": "ENTRY_CH02_IVAN_T04_FIRST", "condition_ref": "COND_FINAL_IVAN_COUNTER_TOPIC",
		"public_name": "从厨房出来后在柜台对货单", "focus_order": 3, "interactive": true,
		"public_reason": "", "question_ref": ""})
	var read_terms: Array = []
	for number in range(1, 7):
		read_terms.append({"kind": "text", "ref": "F7_CH02_IVAN_T04_FIRST_%03d" % number, "expected": true})
	conditions["COND_FINAL_COUNTER_ACCOUNT_READ"] = {"1": read_terms}
	for action in events.get("EV_SIXTH_COUNTER_CLAIMS_HEARD", []):
		action["condition_id"] = "COND_FINAL_COUNTER_ACCOUNT_READ"
	# 未先发现皮包时L02会留兄弟在大厅；之后的公开邀约仍需先读
	# “两位，跟我去空值班室”，再由该句原有事件移动人物和接入L03。
	for jump in jumps.get("ENTRY_CH02_L03_INVITE_KIRILL", []):
		if jump.get("target_ref") == "F7_CH02_L03_ROUTE":
			jump.target_ref = "F7_CH02_L02_BAG_KNOWN"
	# 运费结清单属于正式唯一“木柜台与交接单据”调查点；原表虽保留
	# 阅读入口，却漏掉了从该父物件接入的边。读完柜台观察后接已有正文。
	conditions["COND_FINAL_COUNTER_E09_BEFORE_CASE"] = {"1": [
		{"kind": "entry", "ref": "ENTRY_CH01_READ_E09", "expected": true},
		{"kind": "event", "ref": "EV_CASE_INVESTIGATION_OPEN", "expected": false},
		{"kind": "event", "ref": "EV_E09_READ", "expected": false}]}
	conditions["COND_FINAL_COUNTER_E09_AFTER_CASE"] = {"1": [
		{"kind": "event", "ref": "EV_CASE_INVESTIGATION_OPEN", "expected": true},
		{"kind": "event", "ref": "EV_E09_READ", "expected": false}]}
	for text_id in ["TXT_SC02_COUNTER_FIRST", "TXT_SC02_COUNTER_REPEAT"]:
		for pair in [["COND_FINAL_COUNTER_E09_BEFORE_CASE", "ENTRY_CH01_READ_E09"], ["COND_FINAL_COUNTER_E09_AFTER_CASE", "ENTRY_CH02_FREIGHT_READ"]]:
			jumps[text_id].append({"source_text_id": text_id, "target_kind": "entry", "target_ref": pair[1],
				"condition_id": pair[0], "event_id": "", "timing": "after_text", "trigger": "condition"})

func _repair_final_register_receipts() -> void:
	# 最终正文L09直接以E13中盖毯/死讯击破登记，不再强制先听尤里旧案口述。
	# 所有回执仍等证言③及完整九句回应实际结束；不把“听过尤里”补成既成事实。
	var read_terms: Array = [
		{"kind": "event", "ref": "EV_E13_READ", "expected": true},
		{"kind": "event", "ref": "EV_E17_READ", "expected": true},
		{"kind": "text", "ref": "TXT_F7_CH03_ENTRY_F7_CH03_L09_R01_S3_001", "expected": true},
		{"kind": "text", "ref": "TXT_F7_CH03_ENTRY_F7_CH03_L09_RESPONSE_009", "expected": true}]
	conditions["COND_FINAL_L09_RESPONSE_READ"] = {"1": read_terms}
	var complete_terms: Array = read_terms.duplicate(true)
	complete_terms.append({"kind": "event", "ref": "EV_CH03_REGISTER_ACCOUNT_HEARD", "expected": true})
	conditions["COND_CH03_REGISTER_ACCOUNT_COMPLETE"] = {"1": complete_terms}
	# 父回执先登记本段已听完，再递归提交依赖它的确认；原表相反次序会原子回滚。
	var actions: Array = events.get("EV_F7_CH03_REGISTER", [])
	for action in actions:
		action["condition_id"] = "COND_FINAL_L09_RESPONSE_READ"
		if action.get("kind") == "complete_event":
			action["order"] = {"EV_CH03_REGISTER_ACCOUNT_HEARD": 1, "EV_REGISTER_AUTHOR_CONFIRMED": 2, "EV_REGISTER_ACCOUNT_CONFIRMED": 3}.get(str(action.get("ref", "")), int(action.get("order", 0)))
	actions.sort_custom(func(a, b): return int(a.order) < int(b.order))
	# 调卷发生在当面核实假登记之后；以实际完成回执开题，不复制旧门槛。
	for branch in conditions.get("COND_TOPIC_IVAN_LATER_FILES", {}).values():
		branch.append({"kind": "event", "ref": "EV_REGISTER_ACCOUNT_CONFIRMED", "expected": true})

func _repair_final_tutorial_prerequisites() -> void:
	# T00先用休息室实际读过的清单，再核对柜台内页。大厅旧观察入口
	# 没有此前置时会提前把玩家锁进缺牌的双卡教学，不能靠教学自动补发材料。
	for id in ["INV_SC02_REGISTER", "ENTRY_T00_START", "ENTRY_T00_R02"]:
		if not entries.has(id): continue
		var original := str(entries[id].get("condition_id", ""))
		var gate: String = "COND_FINAL_TUTORIAL_" + str(id)
		var branches: Dictionary = conditions.get(original, {"1": []}).duplicate(true)
		for terms in branches.values():
			terms.append({"kind": "content", "ref": "E01_V1", "expected": true})
			terms.append({"kind": "event", "ref": "EV_E01_READ", "expected": true})
			if id == "ENTRY_T00_R02": terms.append({"kind": "content", "ref": "E28_V1", "expected": true})
		conditions[gate] = branches
		entries[id]["condition_id"] = gate

func _load_final_json_bindings(root: String) -> void:
	# 最终包把逐句追问、到达绑定和分页放在 JSON 中；正文、条件和事件仍以工作簿为唯一来源。
	var narrative_path := root.path_join("02_文案/文案接入数据.json")
	var narrative_file := FileAccess.open(narrative_path, FileAccess.READ)
	if narrative_file != null:
		var parsed = JSON.parse_string(narrative_file.get_as_text())
		if parsed is Dictionary: narrative_data = parsed
		else: warnings.append("文案接入数据不是有效JSON：" + narrative_path)
	else: warnings.append("未找到最终文案绑定数据：" + narrative_path)
	var tutorial_path := root.path_join("12_联合新手引导/引导接入数据.json")
	var tutorial_file := FileAccess.open(tutorial_path, FileAccess.READ)
	if tutorial_file != null:
		var tutorial = JSON.parse_string(tutorial_file.get_as_text())
		if tutorial is Dictionary: tutorial_data = tutorial
		else: warnings.append("引导接入数据不是有效JSON：" + tutorial_path)

func _repair_lorne_click_routes() -> void:
	# 第一章饭前点击洛恩应直接进入已有对白；旧接入只显示心声，读完后没有开谈入口。
	# 运行时按E01阅读状态分流，饭后及后续章节继续使用原有话题条件。
	var source := "ENTRY_CLICK_CHR02_SC06"
	if not jumps.has(source): return
	var retained: Array = []
	for jump in jumps[source]:
		if str(jump.get("target_ref", "")) in ["ENTRY_CLICK_CHR02_CH01_0287", "ENTRY_CLICK_CHR02_CH01_0289"]: continue
		retained.append(jump)
	conditions["COND_FINAL_CH01_LORNE_UNREAD_CLICK"] = {"1": [
		{"kind": "chapter", "ref": "CH01", "expected": true},
		{"kind": "event", "ref": "EV_E01_READ", "expected": false},
		{"kind": "event", "ref": "EV_CH01_REST_SELECTED", "expected": false}]}
	conditions["COND_FINAL_CH01_LORNE_BUSY_CLICK"] = {"1": [
		{"kind": "chapter", "ref": "CH01", "expected": true},
		{"kind": "event", "ref": "EV_E01_READ", "expected": true},
		{"kind": "event", "ref": "EV_CH01_REST_SELECTED", "expected": false}]}
	retained.push_front({"source_entry_id": source, "trigger": "continue", "condition_id": "COND_FINAL_CH01_LORNE_BUSY_CLICK", "target_kind": "entry", "target_ref": "ENTRY_CH01_LORNE_BUSY", "timing": "after_text"})
	retained.push_front({"source_entry_id": source, "trigger": "continue", "condition_id": "COND_FINAL_CH01_LORNE_UNREAD_CLICK", "target_kind": "entry", "target_ref": "ENTRY_CH01_LORNE_UNREAD", "timing": "after_text"})
	jumps[source] = retained

func narrative_bindings(key: String) -> Array:
	var value = narrative_data.get(key, [])
	return value if value is Array else []

func rows(book: String, sheet: String) -> Array:
	return tables.get(book, {}).get(sheet, [])

func index(book: String, sheet: String, field: String) -> Dictionary:
	var result := {}
	for row in rows(book, sheet):
		var id := str(row.get(field, ""))
		if id.is_empty() or result.has(id): errors.append("%s / %s：%s为空或重复：%s" % [BOOKS[book], sheet, field, id])
		else: result[id] = row
	return result

func resource_path(path: String) -> String:
	if path.is_empty(): return ""
	# shared_layout、配置JSON和逻辑引用由对应系统解析，不是资源文件路径。
	if path.begins_with("shared_layout:") or path.ends_with(".json") and not path.begins_with("res://"):
		return path
	# 本包地图仍引用上一版backgrounds目录；仅采用这一条已核实的目录迁移，不模糊搜索同名文件。
	var relative := path.trim_prefix("res://")
	if relative.begins_with("assets/aurora/backgrounds/"):
		relative = relative.replace("assets/aurora/backgrounds/", "assets/aurora/scenes/backgrounds/")
	var resolved := str(definition.root).path_join(relative)
	if path.begins_with(str(definition.root) + "/"): resolved = path
	if path != resolved: path_migrations[path] = resolved
	return resolved

func _relocate_resources() -> void:
	for id in resources: resources[id].path = resource_path(str(resources[id].get("path", "")))
	for id in contents: contents[id].image_ref = resource_path(str(contents[id].get("image_ref", "")))
	for id in profiles:
		for field in ["portrait_ref", "avatar_ref"]: profiles[id][field] = resource_path(str(profiles[id].get(field, "")))
	for id in actors: actors[id].default_portrait_path = resource_path(str(actors[id].get("default_portrait_path", "")))
	for id in texts:
		for field in ["portrait_path", "avatar_ref", "background_path"]: texts[id][field] = resource_path(str(texts[id].get(field, "")))
	for row in rows("investigation", "对象图片"):
		row.image_path = _scene_image_path(str(row.image_path))
	for row in rows("investigation", "资源需求"): row.resource_or_text_ref = resource_path(str(row.get("resource_or_text_ref", "")))
	for row in rows("narrative", "片段地点关联"): row.background_path = resource_path(str(row.get("background_path", "")))

func _scene_image_path(raw_path: String) -> String:
	# 姿态是策划内容；缺少坐姿时由可见交谈视角承接，不用站姿冒充场景坐姿。
	return resource_path(raw_path)

func text(id: String) -> String:
	# 导航label_key先引用界面绑定，再引用唯一功能文字，不能把绑定ID显示给玩家。
	for row in rows("start", "界面文本绑定"):
		if row.get("id") == id: id = str(row.text_id); break
	return str(texts.get(id, {}).get("text", ui_texts.get(id, {}).get("text", id)))

func audio_definition() -> Dictionary:
	# resource_path 是实际文件路径；resource_ref/resource_key 是配置逻辑 ID，
	# 不能把逻辑 ID 当作文件名拼到交付包目录，否则声音表会被错误迁移。
	var audio_resources := rows("audio", "声音资源").duplicate(true)
	for row in audio_resources:
		var path := str(row.get("resource_path", ""))
		if not path.is_empty(): row.resource_path = resource_path(path)
	var music_states := rows("audio", "音乐播放状态").duplicate(true)
	return {"control": rows("audio", "声音总控")[0] if not rows("audio", "声音总控").is_empty() else {},
		"resources": audio_resources, "events": rows("audio", "声音事件"),
		"soundscapes": rows("audio", "场景音景"), "music_states": music_states}

func audio_resource_overrides() -> Dictionary:
	# 1020资源清单给出 resource_overrides 别名契约：逻辑键（如 MAP_PAWN_LAND）→ 实际音频文件。
	# 运行时读一次并沿包 root 迁移实际路径；不能把逻辑键拼成路径，也不能只靠备用库模糊找文件。
	if not _audio_overrides.is_empty(): return _audio_overrides
	var manifest_path := str(definition.root).path_join("资源清单.json")
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null: return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary: return {}
	var result := {}
	for entry in parsed.get("resources", []):
		if not entry is Dictionary or str(entry.get("mapping_reference", "")) != "resource_overrides": continue
		var runtime := str(entry.get("runtime_path", ""))
		if not runtime.contains("/audio/"): continue
		var resolved := resource_path(runtime)
		if resolved.is_empty(): continue
		for key in entry.get("resource_ids", []):
			var id := str(key)
			if not id.is_empty(): result[id] = resolved
	_audio_overrides = result
	return result

func map_definition() -> Dictionary:
	var data := {}
	# 地图旧版棋盘布局已由最终包的图层、投影、空间路点和连线取代；
	# 同时保留旧键名，兼容尚未迁移的地图页面。
	for pair in [["display", "地图显示参数", "id"], ["boards", "棋盘布局", "group_id"],
		["groups", "地图分组", "group_id"], ["nodes", "地点节点", "node_id"], ["pawn", "棋子表现", "id"],
		["layers", "地图图层", "id"], ["views", "地图视图", "id"], ["projection", "地图投影", "id"],
		["waypoints", "空间路点", "id"], ["edges", "空间连线", "id"], ["view_points", "视图落点", "view_id"],
		["reachability", "首章可达绑定", "id"]]:
		data[pair[0]] = index("map", pair[1], pair[2])
	data["scenes"] = scenes
	data["resources"] = resources
	data["transitions"] = []
	return data

func objective_definition() -> Dictionary:
	var result := {"schema": 1, "hud": {}, "review": {}, "texts": {}}
	for row in rows("objective", "组件参数"):
		var key := str(row.key)
		var value = row.value
		match str(row.value_type):
			"int[]": value = JSON.parse_string(str(value))
			"int": value = int(value)
			"float": value = float(value)
			"bool": value = str(value).to_lower() in ["true", "1"]
		if key.begins_with("review_"): result.review[key.trim_prefix("review_")] = value
		else: result.hud[key] = value
	for row in rows("objective", "功能文字引用"): result.texts[str(row.binding_key)] = str(row.text_id)
	# 最终表使用语义参数，旧导航页使用组件参数；只在此边界映射，进度仍来自原提供方。
	if result.hud.has("reference_width"):
		var source: Dictionary = result.hud.duplicate(true)
		var review_source: Dictionary = result.review.duplicate(true)
		result["final_paper"] = true
		result["assets"] = {}
		for row in rows("objective", "界面资源"): result.assets[str(row.binding_key)] = resource_path(str(row.resource_path))
		result.hud.merge({"final_paper": true, "assets": result.assets, "panel_opacity": 1.0, "header_opacity": 1.0,
			"main_color": source.get("paper_text_color", "#34413F"), "body_color": source.get("paper_text_color", "#34413F"), "reason_color": source.get("paper_meta_color", "#5D6864"),
			"header_font_px": source.get("hud_title_font_px", 24), "main_font_px": source.get("hud_goal_font_px", 24), "body_font_px": source.get("hud_hint_font_px", 28), "reason_font_px": 20,
			"body_line_height_px": source.get("hud_line_height_px", 43), "main_line_height_px": source.get("hud_line_height_px", 43),
			"fold_width_px": source.get("hud_fold_max_width_px", 240), "header_height_px": source.get("hud_fold_min_height_px", 48),
			"visible_item_limit": source.get("hud_visible_item_limit", 1), "panel_max_height_px": source.get("hud_expand_max_height_px", 430), "compact_max_height_px": source.get("hud_expand_max_height_px", 430), "update_glow_ms": 300}, true)
		result.review.merge({"final_paper": true, "assets": result.assets, "viewport": [1600, 900], "main_rect": [48, 154, 330, 530], "pending_rect": [420, 190, 772, 500], "progress_rect": [420, 190, 772, 500],
			"main_font_px": review_source.get("item_font_px", 28), "button_font_px": review_source.get("label_font_px", 24), "button_height_px": 48,
			"main_line_height_px": review_source.get("body_line_height_px", 43), "item_line_height_px": review_source.get("body_line_height_px", 43), "meta_line_height_px": 36,
			"modal_dimmer_opacity": source.get("modal_dimmer_opacity", 0.32)}, true)
	return result

func presentation(result: Dictionary, repeat_result: bool = false) -> Dictionary:
	var effect := result.duplicate(true)
	if repeat_result: effect.effect_level = "normal"; effect.feedback_key = "repeat"
	for row in rows("core", "表现规则"):
		if row.effect_level == effect.get("effect_level", "normal") and (str(row.get("effect_kind", "")).is_empty() or row.effect_kind == effect.get("effect_kind", "")):
			if row.has("duration_ms"): effect.duration_ms = row.duration_ms
	if not effect.has("duration_ms"):
		for row in rows("core", "普通反馈"):
			if row.feedback_key == effect.get("feedback_key", ""): effect.duration_ms = row.duration_ms
	return effect

func _validate() -> void:
	for id in texts:
		var row: Dictionary = texts[id]
		# 控件文字、问题标题和调查反馈可以是独立文本；只验证有声明的章节。
		if not str(row.get("chapter_id", "")).is_empty() and not chapters.has(row.chapter_id) and row.chapter_id != "CORE": errors.append("文本章节引用无效：" + id)
		var color := str(row.get("font_color", ""))
		if color.length() != 7 or not Color.html_is_valid(color): errors.append("文本颜色应为#RRGGBB：" + id)
	for id in entries:
		var row: Dictionary = entries[id]
		_check_ref(texts, str(row.get("first_text_id", "")), "入口正文", id)
		_check_ref(conditions, str(row.get("condition_id", "")), "入口条件", id)
		if row.get("call_kind") == "material": _check_ref(contents, str(row.call_ref), "材料阅读", id)
		if row.get("call_kind") == "question": _check_ref(questions, str(row.call_ref), "核查问题", id)
	for source in jumps:
		if not texts.has(source) and not entries.has(source): errors.append("跳转来源不存在：" + source)
		for row in jumps[source]:
			var targets: Dictionary = {"text": texts, "entry": entries, "question": questions, "map": scenes}
			if targets.has(row.target_kind): _check_ref(targets[row.target_kind], str(row.target_ref), "跳转目标", source)
			_check_ref(events, str(row.get("event_id", "")), "跳转事件", source)
			_check_ref(conditions, str(row.get("condition_id", "")), "跳转条件", source)
	for row in relations:
		_check_ref(questions, str(row.question_ref), "出示问题", str(row.id))
		_check_ref(results, str(row.result_ref), "出示结果", str(row.id))
		for slot in ["a", "b", "basis"]:
			var content := str(row.get(slot + "_content_ref", ""))
			_check_ref(contents, content, "出示版本", str(row.id))
			if not content.is_empty() and contents.has(content) and contents[content].material_id != row.get(slot + "_material_ref"): errors.append("出示材料与版本不一致：" + str(row.id))
	for id in resources:
		var path := str(resources[id].path)
		# Headless 校验时 PNG 可能尚未生成 .import；原文件存在即可通过结构检查，
		# 运行时由 Godot 导入器负责建立纹理资源。
		if resources[id].get("required", false) and not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
			errors.append("地图必需资源缺失：%s / %s" % [id, path])

func _check_ref(target: Dictionary, id: String, purpose: String, owner: String) -> void:
	if not id.is_empty() and not target.has(id): errors.append("%s引用不存在：%s → %s" % [purpose, owner, id])

static func ids(value: String) -> Array[String]:
	var result: Array[String] = []
	for part in value.split(";", false): result.append(part.strip_edges())
	return result

func _register_navigation_conditions() -> void:
	# 正式目标表引用的公共条件未抄入文案条件页。以策划正文指定的真实
	# 章节／完成事实提供这些公开别名，不将任意缺失条件视为成立。
	for goal in rows("objective", "正式目标"):
		var id := str(goal.condition_id)
		if conditions.has(id): continue
		var terms: Array = [{"kind": "chapter", "ref": goal.chapter_id, "expected": true}]
		if id in ["COND_CH05_UNADMITTED", "COND_CH05_ADMITTED"]:
			terms.append({"kind": "event", "ref": "EV_LORNE_FULL_ADMISSION", "expected": id == "COND_CH05_ADMITTED"})
		conditions[id] = {"1": terms}
	for row in rows("objective", "正式事项") + rows("objective", "正式目标"):
		for field in ["condition_id", "completion_condition_id", "end_condition_id"]:
			var id := str(row.get(field, ""))
			if id.begins_with("COND_EV_") and not conditions.has(id):
				conditions[id] = {"1": [{"kind": "event", "ref": id.trim_prefix("COND_"), "expected": true}]}
	for index in range(1, 4):
		conditions["COND_CH1_MAIN_%d" % index] = {"1": [{"kind": "event", "ref": "EV_CH01_MAIN_%d_DONE" % index, "expected": true}]}
	# 清单桌面图的资格沿首章饭前调查；其自身 EV_E01_READ=false 控制已读后收起。
	var aliases := {"COND_CHECKLIST_ON_TABLE": "COND_CH01_PRE_MEAL", "COND_BAG_DIRECTION_PUBLIC": "COND_BAG_DOCUMENT_MENU_READY", "COND_OLD_RECORDS_PUBLIC": "COND_AVG_EV_BAG_DOCUMENTS_VIEWED_Y", "COND_OLD_CASE_JOINT_READY": "COND_CH03_JOINT_READY"}
	conditions["COND_OLD_RECORDS_PUBLIC"] = {"1": [{"kind": "event", "ref": "EV_BAG_DOCUMENTS_VIEWED", "expected": true}]}
	for id in aliases:
		if not conditions.has(id) and conditions.has(aliases[id]): conditions[id] = conditions[aliases[id]].duplicate(true)
