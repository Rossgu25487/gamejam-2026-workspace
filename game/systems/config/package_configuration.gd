extends RefCounted
## 一个配置包只在启动读取一次。Excel是内容源；profile只选择路径与测试/正式作用域。
const Reader = preload("res://systems/config/workbook_reader.gd")
var definition := {}
var workbooks := {}
var errors: Array[String] = []

func load_profile(path: String) -> bool:
	errors.clear()
	workbooks.clear()
	var file := FileAccess.open(path, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text()) if file else null
	if not parsed is Dictionary or parsed.get("schema") != 1:
		errors.append("配置包格式无效：" + path)
		return false
	definition = parsed
	for key in ["story", "core", "start", "save", "settings", "audio", "handbook", "cat", "investigation", "map", "objective", "narrative", "performance", "bindings"]:
		if str(definition.get("workbooks", {}).get(key, "")).is_empty(): errors.append("配置包缺少工作簿入口：" + key)
	if not errors.is_empty(): return false
	for key in definition.get("workbooks", {}):
		var reader := Reader.new()
		if reader.open(workbook_path(key)): workbooks[key] = reader
		errors.append_array(reader.errors)
	if workbooks.has("bindings"): _read_bindings()
	return errors.is_empty()

func workbook_path(key: String) -> String:
	var path := str(definition.get("workbooks", {}).get(key, ""))
	return path if path.begins_with("res://") else str(definition.get("root", "")).path_join("配置表").path_join(path)

func _read_bindings() -> void:
	# 适配层把表格行转为运行结构；内容身份、文字和资源仍只由工作簿维护。
	for sheet in ["资源绑定", "流程入口", "事件接续", "目标运行", "事项运行", "依据运行", "场景附加对象", "回应头像", "核心动作声音"]:
		var field: String = {"资源绑定": "resource_id", "事件接续": "event_id", "回应头像": "node_id"}.get(sheet, "id")
		var used := {}
		for row in rows("bindings", sheet):
			var id := str(row.get(field, ""))
			if id.is_empty() or used.has(id): errors.append("程序接入配置表 / %s：ID为空或重复 %s" % [sheet, id])
			used[id] = true
	definition.resources = {}
	for row in rows("bindings", "资源绑定"): definition.resources[row.resource_id] = row.path
	for id in definition.resources:
		if not FileAccess.file_exists(resource_path(str(id))): errors.append("程序资源绑定文件不存在：" + str(id))
	for row in rows("bindings", "流程入口"):
		if row.id not in ["opening", "closing"]: errors.append("流程入口只允许opening/closing：" + str(row.id)); continue
		definition["initial_text_id" if row.id == "opening" else "closing_text_id"] = row.text_id
	for field in ["initial_text_id", "closing_text_id"]:
		if not definition.has(field): errors.append("流程入口缺少：" + field)
	definition.event_routes = {}
	for row in rows("bindings", "事件接续"):
		if str(row.target_text_id).is_empty() == str(row.return_action).is_empty(): errors.append("事件接续须填写跳转文本或返回动作之一：" + str(row.event_id))
		if not str(row.return_action).is_empty() and row.return_action not in ["investigation", "commit_entry", "ending"]: errors.append("事件返回动作无效：" + str(row.event_id))
		definition.event_routes[row.event_id] = {"target_text_id": row.target_text_id} if not str(row.target_text_id).is_empty() else {"ends": true, "return_action": row.return_action}
	definition.choices = []
	var grouped := {}
	for row in rows("bindings", "阅读选择"):
		if not grouped.has(row.source_text_id): grouped[row.source_text_id] = []
		var option: Dictionary = row.duplicate(true)
		for field in ["target_text_id", "target_event_id"]:
			if str(option.get(field, "")).is_empty(): option.erase(field)
		if option.has("target_text_id") == option.has("target_event_id"): errors.append("阅读选择必须且只能指定一种目标：" + str(row.source_text_id))
		grouped[row.source_text_id].append(option)
	for source in grouped:
		grouped[source].sort_custom(func(a: Dictionary, b: Dictionary): return int(a.order) < int(b.order))
		definition.choices.append({"source": source, "options": grouped[source]})
	definition.stage_exits = {}
	for row in rows("bindings", "立绘离场"):
		if not definition.stage_exits.has(row.text_id): definition.stage_exits[row.text_id] = []
		definition.stage_exits[row.text_id].append(row.character_id)
	definition.transfer_observations = []
	for row in rows("bindings", "观察效果"):
		if row.transfer: definition.transfer_observations.append(row.observation_ref)
	definition.conditions = {}
	for row in rows("bindings", "补充条件"):
		if not definition.conditions.has(row.id): definition.conditions[row.id] = []
		if int(row.or_group) < 1: errors.append("条件组应从1开始：" + str(row.id)); continue
		while definition.conditions[row.id].size() < int(row.or_group): definition.conditions[row.id].append([])
		definition.conditions[row.id][int(row.or_group) - 1].append({"kind": row.kind, "ref": row.ref})
	var goals := {}
	for row in rows("bindings", "目标运行"):
		goals[row.id] = {"id": row.id, "visible": row.visible_condition, "items": []}
		if not str(row.closed_condition).is_empty(): goals[row.id].closed = row.closed_condition
	for row in rows("bindings", "事项运行"):
		if not goals.has(row.goal_id): errors.append("事项所属目标不存在：" + str(row.goal_id)); continue
		var basis: Array = str(row.basis_refs).split(";", false)
		goals[row.goal_id].items.append({"id": row.id, "done": row.done_condition, "go": {"kind": row.go_kind, "id": row.go_id}, "basis": basis})
	var bases := {}
	for row in rows("bindings", "依据运行"):
		bases[row.id] = {"kind": row.kind, "content_id": row.content_id} if row.kind == "material" else {"kind": row.kind, "statement_id": row.statement_id}
	definition.objectives = {"goals": goals.values(), "bases": bases}
	definition.canvas_objects = rows("bindings", "场景附加对象")
	for row in definition.canvas_objects:
		if row.kind not in ["character", "cat"] or int(row.w) <= 0 or int(row.h) <= 0: errors.append("场景附加对象类型或尺寸无效：" + str(row.id))
	definition.response_portraits = {}
	for row in rows("bindings", "回应头像"): definition.response_portraits[row.node_id] = row.image_path
	definition.sound_timings = rows("bindings", "核心动作声音")
	for row in definition.sound_timings:
		if row.effect not in ["support", "partial", "break", "insight", "collect", "error", "failure", "retry"] or int(row.at_ms) < 0: errors.append("核心动作声音类型或时点无效：" + str(row.id))

func rows(key: String, sheet: String, header_row: int = 0) -> Array:
	if not workbooks.has(key): return []
	var reader: RefCounted = workbooks[key]
	var result: Array = reader.records(sheet, str(definition.get("scope", "runtime")), header_row)
	for error in reader.errors:
		if error not in errors: errors.append(error)
	return result

func resource_path(value: String) -> String:
	if value.is_empty(): return ""
	var mapped := str(definition.get("resources", {}).get(value, value))
	if mapped.ends_with(".svg") and not str(definition.get("generated_root", "")).is_empty():
		var flattened := str(definition.generated_root).path_join(mapped.trim_prefix("res://").get_basename() + ".png")
		if FileAccess.file_exists(flattened): return flattened
	if mapped.begins_with("res://") and not mapped.begins_with("res://assets/"): return mapped
	return str(definition.root).path_join(mapped.trim_prefix("res://"))

func apply_core(catalog: RefCounted) -> bool:
	var rules := {}
	for sheet in ["核心总控", "容错策略", "判定顺序", "普通反馈", "表现规则", "槽位模板", "错误出示"]: rules[sheet] = rows("core", sheet)
	catalog.rules = rules
	# 以下是当前玩法协议，改结构需要同步槽位、判定和存档，不能只改Excel而静默无效。
	var fixed := {"核心总控": {"slot_count": 2, "bar_page_size": 5, "grid_columns": 6, "grid_visible_rows": 2, "single_material_sufficient": true, "material_consumed": false}, "容错策略": {"initial_chances": 999, "error_cost": 1, "failure_at": 0, "retry_chances": 999}}
	for sheet in fixed:
		if rules[sheet].size() != 1: errors.append(sheet + "必须只有一条有效记录"); continue
		for key in fixed[sheet]:
			if rules[sheet][0].get(key) != fixed[sheet][key]: errors.append("当前玩法协议不支持改变 %s.%s" % [sheet, key])
	for row in rows("start", "功能文字"): catalog.function_texts[str(row.id)] = str(row.text)
	# 功能文字绑定允许一个位置引用共用文字，不另维护中文副本。
	for key in ["start", "settings", "save"]:
		for row in rows(key, "界面文本绑定"):
			if not catalog.function_texts.has(str(row.text_id)): errors.append("功能文字引用缺失：" + str(row.text_id))
			else: catalog.function_texts[str(row.id)] = catalog.function_texts[str(row.text_id)]
	for row in rows("handbook", "文字绑定"):
		if catalog.function_texts.has(str(row.textId)): catalog.function_texts[str(row.id)] = catalog.function_texts[str(row.textId)]
	catalog.set_meta("navigation_buttons", rows("start", "导航按钮"))
	var control: Array = rows("start", "导航总控")
	if control.size() != 1: errors.append("导航总控必须只有一条有效记录")
	else: catalog.set_meta("navigation_control", control[0])
	catalog.set_meta("handbook_tabs", rows("handbook", "页签显示"))
	var handbook: Array = rows("handbook", "手册总控")
	if handbook.size() != 1: errors.append("手册总控必须只有一条有效记录")
	else: catalog.set_meta("handbook_control", handbook[0])
	var goals: Array = definition.get("objectives", {}).get("goals", []).duplicate(true)
	# 目标测试快照只提供文字与身份；完成/公开状态始终读取核心条件，绝不导入checked/pending初值。
	var labels := {}
	for row in rows("objective", "测试目标", 4): labels[str(row.get("目标ID", ""))] = str(row.get("主目标全文", ""))
	for row in rows("objective", "测试事项", 4): labels[str(row.get("事项ID", ""))] = str(row.get("事项全文", ""))
	for goal in goals:
		catalog.data.texts[goal.id] = labels.get(goal.id, goal.id)
		goal.text = goal.id
		for item in goal.items:
			catalog.data.texts[item.id] = labels.get(item.id, item.id)
			item.text = item.id
	for id in definition.get("conditions", {}): catalog.data.conditions[id] = definition.conditions[id].duplicate(true)
	for row in definition.canvas_objects:
		if not catalog.data.scenes.has(row.scene_id): errors.append("附加对象地点不存在：" + str(row.id))
		if row.kind == "character" and not catalog.data.characters.has(row.target_ref): errors.append("附加对象人物不存在：" + str(row.id))
		if not FileAccess.file_exists(resource_path(str(row.image_path))): errors.append("附加对象图片不存在：" + str(row.id))
	for id in definition.response_portraits:
		if not catalog.data.nodes.has(id) or not FileAccess.file_exists(resource_path(str(definition.response_portraits[id]))): errors.append("回应头像节点或图片不存在：" + str(id))
	catalog.data["objectives"] = {"goals": goals, "bases": definition.get("objectives", {}).get("bases", {}).duplicate(true)}
	return errors.is_empty() and catalog.configure(catalog.data)

func audio_definition() -> Dictionary:
	var control: Array = rows("audio", "声音总控")
	return {"control": control[0] if not control.is_empty() else {}, "resources": rows("audio", "声音资源"), "events": rows("audio", "声音事件"), "soundscapes": rows("audio", "场景音景")}

func narrative_definition() -> Dictionary:
	var loader := preload("res://systems/narrative/narrative_workbook_loader.gd").new()
	var data: Dictionary = loader.load_workbook(workbook_path("narrative"))
	errors.append_array(loader.errors)
	if data.is_empty(): return {}
	for section in ["texts", "characters", "scenes"]:
		for row in data[section].values():
			for key in ["avatar_path", "background_path"]:
				if row.has(key): row[key] = resource_path(str(row[key]))
	data["avatars"] = {}
	for row in rows("performance", "头像资源"):
		data.avatars[str(row["头像ID"])] = {"path": resource_path(str(row["真实路径"]))}
	data["event_bindings"] = definition.get("event_routes", {}).duplicate(true)
	for field in ["initial_text_id", "closing_text_id"]:
		if not data.texts.has(str(definition.get(field, ""))): errors.append("流程入口文本不存在：" + str(definition.get(field, "")))
	for id in data.event_bindings:
		var route: Dictionary = data.event_bindings[id]
		if not data.events.has(id): errors.append("事件接续源不存在：" + str(id))
		if route.has("target_text_id") and not data.texts.has(route.target_text_id): errors.append("事件接续目标文本不存在：" + str(id))
	# 选择是明确的测试调用者编排，事件制作说明保留原文且从不解释执行。
	for choice in definition.get("choices", []):
		if not data.texts.has(choice.source): errors.append("阅读选择源文本不存在：" + str(choice.source)); continue
		for id in data.transitions.keys():
			if data.transitions[id].get("source_text_id") == choice.source: data.transitions.erase(id)
		for index in range(choice.options.size()):
			var option: Dictionary = choice.options[index]
			var transition: Dictionary = option.duplicate(true)
			if not data.texts.has(str(option.label_text_id)): errors.append("阅读选择按钮文本不存在：" + str(option.label_text_id)); continue
			transition.merge({"source_text_id": choice.source, "transition_type": "choice", "order": index + 1})
			transition["choice_text"] = data.texts[str(option.label_text_id)].text
			data.transitions["choice/%s/%d" % [choice.source, index]] = transition
	for id in data.texts:
		data.texts[id]["exit_characters"] = definition.get("stage_exits", {}).get(id, [])
	# 本包明确给出逐句动作时长；仅采用准确文本定位，其余制作说明不执行。
	for row in rows("performance", "演出步骤"):
		var trigger := str(row.get("触发定位", ""))
		var id := trigger.trim_prefix("跳转至").trim_suffix("前")
		if data.texts.has(id): data.texts[id]["stage_duration_ms"] = int(row.get("时长ms", 0))
	var chapters := {}
	for row in rows("narrative", "章节字典"): chapters[str(row["章节id"])] = str(row.get("默认配乐ID", ""))
	for row in rows("narrative", "剧情场景字典"):
		var id := str(row["场景id"])
		if not data.scenes.has(id): continue
		var method := str(row.get("配乐方式", "静音"))
		data.scenes[id]["bgm_key"] = str(row.get("配乐ID", "")) if method == "指定配乐" else str(chapters.get(str(row.get("章节id", "")), "")) if method == "继承章节" else ""
	return data

func objective_definition() -> Dictionary:
	var result := {"schema": 1, "hud": {}, "review": {}, "texts": {}}
	for row in rows("objective", "组件参数", 4):
		var key := str(row.get("配置键", ""))
		var type := str(row.get("类型", ""))
		var raw := str(row.get("初值", ""))
		var value = raw
		if type in ["int", "float", "int[]"]:
			value = JSON.parse_string(raw)
			if value == null: errors.append("目标导航参数无效：" + key); continue
		if key.begins_with("review_"): result.review[key.trim_prefix("review_")] = value
		else: result.hud[key] = value
	for row in rows("objective", "功能文字引用", 4): result.texts[str(row["位置键"])] = str(row["统一文字键"])
	return result
