extends RefCounted
## 内容目录只解析配置与精确引用；它不授予玩家任何材料或知识。

const WorkbookLoader = preload("res://systems/core_gameplay/story_workbook_loader.gd")

var data: Dictionary = {}
var rules: Dictionary = {}
var function_texts: Dictionary = {}
var errors: Array[String] = []

func load_files(path: String = WorkbookLoader.DEFAULT_PATH) -> bool:
	var workbook: RefCounted = null
	var content
	if path.get_extension().to_lower() == "xlsx":
		workbook = WorkbookLoader.new()
		content = workbook.load_workbook(path)
		if not workbook.errors.is_empty():
			errors.assign(workbook.errors)
			return false
	else: content = _json(path)
	var rule_data = _json("res://data/core/rules.json")
	var texts = _json("res://data/core/function_text.json")
	if not content is Dictionary or not rule_data is Dictionary or not texts is Array:
		errors.assign(["核心配置文件格式无效"])
		return false
	for row in texts:
		function_texts[str(row.id)] = str(row.text)
	rules = rule_data
	var valid := configure(content)
	if not valid and workbook != null: errors.assign(workbook.locate_catalog_errors(errors))
	return valid

func configure(content: Dictionary) -> bool:
	data = content.duplicate(true)
	errors.clear()
	for section in ["texts", "materials", "contents", "statements", "questions", "relations", "nodes", "groups", "conditions", "entries", "scenes", "characters"]:
		if not data.get(section) is Dictionary:
			errors.append("缺少内容表：" + section)
	if not errors.is_empty(): return false
	_check(not str(data.get("case_id", "")).is_empty() and not str(data.get("content_revision", "")).is_empty(), "案件ID或内容版本缺失")
	_check(data.scenes.has(data.get("initial_scene", "")), "起始地点缺失：" + str(data.get("initial_scene", "")))
	for section in ["scenes", "characters"]:
		for id in data[section]: _text_ref(data[section][id].get("name", ""), id)
	for id in data.materials:
		_check(data.materials[id].get("type") in ["evidence", "testimony", "inference"], "材料类型无效：" + id)
	if not str(data.get("completion_condition", "")).is_empty():
		_check(data.conditions.has(data.completion_condition), "完成条件缺失：" + data.completion_condition)
		_text_ref(data.get("completion_text", ""), data.case_id)
	for id in data.contents:
		var c: Dictionary = data.contents[id]
		_check(data.materials.has(c.get("material_id", "")), "材料身份缺失：" + id)
		_check(int(c.get("version", 0)) > 0, "版本无效：" + id)
		for key in ["title", "summary", "body"]: _text_ref(c.get(key, ""), id)
		var previous: String = c.get("previous", "")
		if not previous.is_empty():
			_check(data.contents.has(previous), "历史版本不存在：" + id)
			if data.contents.has(previous):
				_check(data.contents[previous].material_id == c.material_id and int(data.contents[previous].version) < int(c.version), "历史版本归属错误：" + id)
	for id in data.statements:
		var s: Dictionary = data.statements[id]
		_check(data.characters.has(s.get("speaker", "")), "发言人物缺失：" + id)
		_check(not str(s.get("claim_id", "")).is_empty() and int(s.get("version", 0)) > 0, "说法身份或版本无效：" + id)
		_text_ref(s.get("text", ""), id)
		_check(data.contents.has(s.get("record_content", "")), "原话所属材料不存在：" + id)
		if data.contents.has(s.get("record_content", "")):
			_check(text(data.contents[s.record_content].body).contains(text(s.text)), "记录正文未包含原话：" + id)
	for id in data.questions:
		var q: Dictionary = data.questions[id]
		_scene_ref(q.get("scene_id", ""), id)
		_text_ref(q.get("title", ""), id)
		_check(q.get("target_kind", "statement") in ["statement", "reasoning"], "目标类型无效：" + id)
		_check(data.conditions.has(q.get("condition", "")), "入口条件缺失：" + id)
		_check(data.nodes.has(q.get("insufficient_node", "")), "不足回应缺失：" + id)
		if q.get("target_kind", "statement") == "reasoning":
			_text_ref(q.get("question_text_id", ""), id)
		else:
			_check(data.statements.has(q.get("statement_id", "")), "说法缺失：" + id)
			if data.statements.has(q.get("statement_id", "")):
				_check(data.statements[q.statement_id].speaker == q.get("parent", ""), "说法不属于交谈对象：" + id)
	for id in data.nodes:
		var node: Dictionary = data.nodes[id]
		_text_ref(node.get("text", ""), id)
		_check(node.get("timing", "continue") in ["enter", "continue", "collect", "none"], "执行时点无效：" + id)
		if not str(node.get("group", "")).is_empty(): _check(data.groups.has(node.group), "结果组缺失：" + id)
		for next in node.get("next_questions", []): _check(data.questions.has(next), "后续问题不存在：" + id)
	for id in data.groups:
		var confirms := 0
		_check(data.groups[id] is Array, "结果组必须为有序动作：" + id)
		if not data.groups[id] is Array: continue
		for action in data.groups[id]:
			match action.get("kind", ""):
				"confirm": confirms += 1
				"fact": _check(not str(action.get("ref", "")).is_empty(), "结果事实缺失：" + id)
				"correct":
					_check(data.statements.has(action.get("statement_id", "")) and data.questions.has(action.get("question_id", "")), "更正引用缺失：" + id)
				_: _check(false, "未知结果动作：" + id)
		_check(confirms == 1, "结果组必须确认一次：" + id)
	for id in data.entries:
		var entry: Dictionary = data.entries[id]
		_scene_ref(entry.get("scene_id", ""), id)
		_check(not str(entry.get("source_id", "")).is_empty(), "取得来源缺失：" + id)
		_text_ref(entry.get("title", ""), id)
		_text_ref(entry.get("text", ""), id)
		_check(data.conditions.has(entry.get("condition", "")), "调查条件缺失：" + id)
		for content_id in entry.get("contents", []):
			_check(data.contents.has(content_id), "取得内容缺失：" + id)
			if data.contents.has(content_id): _check(data.materials.get(data.contents[content_id].material_id, {}).get("type") != "inference", "调查入口不能直接授予推论：" + id)
		for statement_id in entry.get("statements", []): _check(data.statements.has(statement_id), "问话目标缺失：" + id)
	for id in data.get("scene_links", {}):
		var link: Dictionary = data.scene_links[id]
		_check(data.scenes.has(link.get("from_scene", "")) and data.scenes.has(link.get("to_scene", "")), "地点连接引用缺失：" + id)
		_check(data.conditions.has(link.get("condition", "")), "地点连接条件缺失：" + id)
		_text_ref(link.get("title", ""), id)
	# 作者声明的事实必须有真实生产者，避免拼写错误让后续入口永久锁住。
	var declared_facts: Array = []
	for entry in data.entries.values(): declared_facts.append_array(entry.get("facts", []))
	for actions in data.groups.values():
		if actions is Array:
			for action in actions:
				if action.get("kind") == "fact": declared_facts.append(action.get("ref", ""))
	for id in data.conditions:
		_check(data.conditions[id] is Array and not data.conditions[id].is_empty(), "条件必须具有显式分支：" + id)
		for branch in data.conditions[id]:
			for term in branch:
				_check(term.get("kind", "") in ["fact", "heard", "owned", "completed"], "未知条件：" + id)
				if term.get("kind") == "fact": _check(term.get("ref", "") in declared_facts, "条件事实没有生产者：" + id)
				if term.get("kind") == "heard": _check(data.statements.has(term.get("ref", "")), "条件说法缺失：" + id)
				if term.get("kind") == "owned": _check(data.contents.has(term.get("ref", "")), "条件材料缺失：" + id)
				if term.get("kind") == "completed": _check(data.questions.has(term.get("ref", "")), "条件问题缺失：" + id)
	for id in data.relations:
		var r: Dictionary = data.relations[id]
		_check(data.questions.has(r.get("question_id", "")), "关系问题缺失：" + id)
		_check(data.nodes.has(r.get("node", "")), "关系回应缺失：" + id)
		_check(data.conditions.has(r.get("condition", "")), "关系条件缺失：" + id)
		_check(r.get("feedback", "") in ["full", "partial", "counter", "incorrect"], "关系类别无效：" + id)
		_check(r.get("match_scope", "contains") in ["contains", "exact_set"], "匹配范围无效：" + id)
		_check(r.get("materials", []).size() in [1, 2], "关系必须使用一或两份材料：" + id)
		if r.get("materials", []).size() == 2: _check(r.materials[0].get("material_id") != r.materials[1].get("material_id"), "两个出示槽不能使用同一材料身份：" + id)
		for ref in r.get("materials", []): _check(valid_material_ref(ref), "关系材料版本无效：" + id)
		if not data.questions.has(r.get("question_id", "")): continue
		var q: Dictionary = data.questions[r.question_id]
		if q.get("target_kind", "statement") == "reasoning":
			_check(r.get("question_text_id", "") == q.get("question_text_id", ""), "推理目标不精确：" + id)
			_check(str(r.get("statement_id", "")).is_empty() and str(r.get("after", "")).is_empty(), "推理不能更正人物目标：" + id)
			_check(r.get("effect_kind", "support") in ["support", "inference", "ordinary"], "推理问题不能碎裂原话：" + id)
		else:
			_check(data.statements.has(r.get("statement_id", "")), "关系目标说法缺失：" + id)
			if data.statements.has(r.get("statement_id", "")) and data.statements.has(q.get("statement_id", "")):
				_check(data.statements[r.statement_id].claim_id == data.statements[q.statement_id].claim_id, "关系说法不属于当前问题：" + id)
		var level: String = r.get("effect_level", "normal")
		_check(level in ["normal", "progress", "key"], "表现等级错误：" + id)
		if level != "normal": _check(r.get("feedback") == "full", "强表现要求充分成果：" + id)
		_check((level == "key") == (not str(r.get("climax_key", "")).is_empty()), "高潮标识绑定错误：" + id)
		if r.get("feedback") == "incorrect":
			_text_ref(r.get("reason", ""), id)
			_check(str(r.get("result_key", "")).is_empty() and str(r.get("inference", "")).is_empty(), "错误关系不能提交成果：" + id)
		if not str(r.get("inference", "")).is_empty():
			_check(data.contents.has(r.inference), "推论内容缺失：" + id)
			if data.contents.has(r.inference): _check(data.materials.get(data.contents[r.inference].material_id, {}).get("type") == "inference", "新推论的材料类型错误：" + id)
			_check(data.nodes.get(r.get("node", ""), {}).get("timing") == "collect", "新推论必须主动收下：" + id)
			for ref in r.materials: _check(ref.content_id != r.inference, "推论不能以自身为来源：" + id)
		for basis in r.get("basis_results", []):
			_check(data.relations.has(basis.get("relation_id", "")), "前次关联不存在：" + id)
			_check(basis.get("target_ref") is Dictionary, "前次目标必须精确：" + id)
		if r.feedback == "full" and data.nodes.has(r.get("node", "")):
			_check(data.groups.has(data.nodes[r.node].get("group", "")), "充分关系缺少确认结果组：" + id)
			_check(data.nodes[r.node].get("timing") in ["enter", "continue", "collect"], "充分成果没有合法提交时点：" + id)
			_check((data.nodes[r.node].get("timing") == "collect") == (not str(r.get("inference", "")).is_empty()), "收下时点必须绑定新推论：" + id)
		var quote: String = r.get("statement_quote", "")
		if r.get("effect_kind") in ["limit", "exclude"] and data.statements.has(r.get("statement_id", "")):
			var original := text(data.statements[r.statement_id].text)
			_check(not quote.is_empty() and original.count(quote) == 1, "更正片段必须唯一：" + id)
	# 等价解法必须分享业务语义，而不是仅分享动画。
	var results := {}
	for id in data.relations:
		var r: Dictionary = data.relations[id]
		if r.get("feedback") != "full" or not data.nodes.has(r.get("node", "")): continue
		var signature := [r.get("inference", ""), data.nodes[r.node].get("group", ""), data.nodes[r.node].get("timing", ""), r.get("effect_level", "normal"), r.get("climax_key", ""), r.get("confirmed_scope", "")]
		var key: String = r.get("result_key", "")
		_check(not key.is_empty(), "充分关系缺少稳定成果：" + id)
		if results.has(key): _check(results[key] == signature, "等价解法成果冲突：" + id)
		results[key] = signature
	# 引用边不能成环；record_content 只是正文归属，不建立证明边。
	for id in data.relations:
		_check(not _relation_cycle(id, []), "前次证明来源形成循环：" + id)
	_check_images()
	return errors.is_empty()

func _check_images() -> void:
	# 图片只控制显示和入口绑定，不生成材料、改变地点或替代证明关系。
	var bindings := {}
	for id in data.get("image_layouts", {}):
		var row: Dictionary = data.image_layouts[id]
		_scene_ref(row.get("scene_id", ""), id)
		_check(row.get("page") in ["title", "pause", "save", "load", "settings", "confirm", "investigation", "dialogue", "selection", "result", "material"], "图片页面无效：" + id)
		_check(row.get("kind") in ["decoration", "entry", "portrait", "material"], "图片用途无效：" + id)
		_check(row.get("fit") in ["contain", "cover", "stretch"], "图片适配无效：" + id)
		var condition: String = row.get("condition", "")
		_check(condition.is_empty() or data.conditions.has(condition), "图片条件缺失：" + id)
		var path: String = row.get("image", "")
		var legal := path.begins_with("res://") and path == path.simplify_path() and path.get_extension().to_lower() == "png"
		_check(legal, "图片路径须为工程内PNG：" + id)
		if legal: _check(ResourceLoader.exists(path, "Texture2D"), "图片资源不存在或尚未导入：" + id)
		var ref: String = row.get("ref", "")
		match row.get("kind", ""):
			"entry":
				_check(row.page == "investigation" and data.entries.has(ref), "调查图片须绑定调查入口：" + id)
				if data.entries.has(ref):
					var scene: String = data.entries[ref].get("scene_id", "")
					_check(scene.is_empty() or row.scene_id == scene, "调查图片与入口地点不一致：" + id)
			"portrait": _check(row.page in ["dialogue", "selection", "result"] and data.characters.has(ref), "人物图片须绑定当前交谈人物：" + id)
			"material":
				_check(row.page == "material" and data.contents.has(ref) and str(row.get("scene_id", "")).is_empty() and condition.is_empty(), "材料卡面须绑定内容版本且不限制地点或条件：" + id)
				for field in ["x", "y", "width", "height", "layer"]: _check(row.get(field) == null, "材料卡面位置由页面管理，请留空：" + id + "/" + field)
			"decoration": _check(ref.is_empty() and row.page != "material", "装饰图片不绑定业务对象：" + id)
		if row.get("kind") != "material":
			var valid := true
			for field in ["x", "y", "width", "height", "layer"]:
				var value = row.get(field)
				if not (value is float or value is int) or not is_finite(float(value)): valid = false
			_check(valid, "固定图片需要坐标、尺寸和图层：" + id)
			if valid:
				_check(row.x >= 0 and row.y >= 0 and row.width > 0 and row.height > 0 and row.x + row.width <= 1280 and row.y + row.height <= 800, "图片显示框超出1280×800：" + id)
				_check(row.layer >= 0 and row.layer <= 99 and row.layer == floor(row.layer), "图片图层须为0–99整数：" + id)
		if row.get("kind") in ["entry", "material"]:
			var key := JSON.stringify([row.kind, ref, row.get("scene_id", "")])
			_check(not bindings.has(key), "图片对象重复绑定：" + id)
			bindings[key] = true

func _relation_cycle(id: String, ancestors: Array) -> bool:
	if id in ancestors: return true
	if not data.relations.has(id): return false
	var chain := ancestors.duplicate()
	chain.append(id)
	for basis in data.relations[id].get("basis_results", []):
		if _relation_cycle(basis.get("relation_id", ""), chain): return true
	return false

func text(id: String) -> String:
	return str(data.get("texts", {}).get(id, ""))

func ui(id: String) -> String:
	return str(function_texts.get(id, id))

func valid_material_ref(ref: Dictionary) -> bool:
	return data.get("contents", {}).has(ref.get("content_id", "")) and data.contents[ref.content_id].material_id == ref.get("material_id", "")

func material_ref(content_id: String) -> Dictionary:
	if not data.contents.has(content_id): return {}
	return {"material_id": data.contents[content_id].material_id, "content_id": content_id}

func _text_ref(id: String, owner: String) -> void:
	_check(data.texts.has(id) and not text(id).is_empty(), "文字引用缺失：" + owner + "/" + id)

func _scene_ref(id: String, owner: String) -> void:
	_check(id.is_empty() or data.scenes.has(id), "所属地点缺失：" + owner)

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

func _json(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text()) if file else null
