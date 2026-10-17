extends RefCounted
## 正式十一册配置的唯一读取入口。原工作簿只读；不使用参考JSON替代策划填写的数据。
const Reader = preload("res://systems/config/workbook_reader.gd")
const DEFAULT_ROOT := "res://极光_六稿文本配置完整交付_20261017"
const BOOKS := {
	"core": "01_核心玩法/玩法策划案.xlsx", "narrative": "02_文案/文案配置表.xlsx",
	"investigation": "03_调查与场景交互/调查与场景交互系统配置表.xlsx",
	"handbook": "04_办案手册/办案手册系统配置表.xlsx", "map": "05_地图切换/地图切换系统配置表.xlsx",
	"objective": "06_目标导航/目标导航系统配置表.xlsx", "start": "07_初始化与开始/游戏初始化与开始系统配置表.xlsx",
	"save": "08_存读档/存读档系统配置表.xlsx", "settings": "09_游戏设置/游戏设置系统配置表.xlsx",
	"audio": "10_声音播放/声音播放系统配置表.xlsx", "cat": "11_撸猫/撸猫系统配置表.xlsx",
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
var content_revision := "AVG_20261017_01"

# 正式表中的场景姿态仍由策划维护。当前素材包尚未交付伊万大厅坐姿图，
# 先把这一条明确登记为临时资源回退，避免图片加载失败后整个人物图层被静默跳过。
# 交付坐姿 PNG 后删除该项即可恢复正式表中的原路径。
const SCENE_IMAGE_FALLBACKS := {
	"res://assets/aurora/characters/1000004/伊万_坐姿_提取.png": "res://assets/aurora/characters/1000004/伊万_常态站姿.png",
}

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
	_validate()
	return errors.is_empty()

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
	var resolved := resource_path(raw_path)
	if FileAccess.file_exists(resolved): return resolved
	var fallback := str(SCENE_IMAGE_FALLBACKS.get(raw_path, ""))
	if fallback.is_empty():
		return resolved
	var fallback_path := resource_path(fallback)
	if not FileAccess.file_exists(fallback_path):
		return resolved
	path_migrations[resolved] = fallback_path
	var message := "场景图片缺失，临时使用替代资源：%s → %s" % [resolved, fallback_path]
	if message not in warnings: warnings.append(message)
	return fallback_path

func text(id: String) -> String:
	# 导航label_key先引用界面绑定，再引用唯一功能文字，不能把绑定ID显示给玩家。
	for row in rows("start", "界面文本绑定"):
		if row.get("id") == id: id = str(row.text_id); break
	return str(texts.get(id, {}).get("text", ui_texts.get(id, {}).get("text", id)))

func audio_definition() -> Dictionary:
	var audio_resources := rows("audio", "声音资源").duplicate(true)
	for row in audio_resources:
		for field in ["resource_path", "resource_ref"]:
			if not str(row.get(field, "")).is_empty(): row[field] = resource_path(str(row[field]))
	return {"control": rows("audio", "声音总控")[0], "resources": audio_resources,
		"events": rows("audio", "声音事件"), "soundscapes": rows("audio", "场景音景")}

func map_definition() -> Dictionary:
	var data := {}
	for pair in [["display", "地图显示参数", "id"], ["boards", "棋盘布局", "group_id"], ["groups", "地图分组", "group_id"], ["nodes", "地点节点", "node_id"], ["pawn", "棋子表现", "id"]]:
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
		if resources[id].get("required", false) and not FileAccess.file_exists(str(resources[id].path)): errors.append("地图必需资源缺失：%s / %s" % [id, resources[id].path])

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
	var aliases := {"COND_BAG_DIRECTION_PUBLIC": "COND_BAG_DOCUMENT_MENU_READY", "COND_OLD_RECORDS_PUBLIC": "COND_AVG_EV_BAG_DOCUMENTS_VIEWED_Y", "COND_OLD_CASE_JOINT_READY": "COND_CH03_JOINT_READY"}
	conditions["COND_OLD_RECORDS_PUBLIC"] = {"1": [{"kind": "event", "ref": "EV_BAG_DOCUMENTS_VIEWED", "expected": true}]}
	for id in aliases:
		if not conditions.has(id) and conditions.has(aliases[id]): conditions[id] = conditions[aliases[id]].duplicate(true)
