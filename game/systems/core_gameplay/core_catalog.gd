extends RefCounted
## 内容目录只解析配置与精确引用；它不授予玩家任何材料或知识。

var data: Dictionary = {}
var rules: Dictionary = {}
var function_texts: Dictionary = {}
var errors: Array[String] = []

func load_files(path: String = "res://data/core/placeholder_case.json") -> bool:
	var content = _json(path)
	var rule_data = _json("res://data/core/rules.json")
	var texts = _json("res://data/core/function_text.json")
	if not content is Dictionary or not rule_data is Dictionary or not texts is Array:
		errors.assign(["核心配置文件格式无效"])
		return false
	for row in texts:
		function_texts[str(row.id)] = str(row.text)
	rules = rule_data
	return configure(content)

func configure(content: Dictionary) -> bool:
	data = content.duplicate(true)
	errors.clear()
	for section in ["texts", "materials", "contents", "statements", "questions", "relations", "nodes", "groups", "conditions", "entries"]:
		if not data.get(section) is Dictionary:
			errors.append("缺少内容表：" + section)
	if not errors.is_empty(): return false
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
		_text_ref(s.get("text", ""), id)
		_check(data.contents.has(s.get("record_content", "")), "原话所属材料不存在：" + id)
		if data.contents.has(s.get("record_content", "")):
			_check(text(data.contents[s.record_content].body).contains(text(s.text)), "记录正文未包含原话：" + id)
	for id in data.questions:
		var q: Dictionary = data.questions[id]
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
		_text_ref(entry.get("title", ""), id)
		_text_ref(entry.get("text", ""), id)
		_check(data.conditions.has(entry.get("condition", "")), "调查条件缺失：" + id)
		for content_id in entry.get("contents", []): _check(data.contents.has(content_id), "取得内容缺失：" + id)
		for statement_id in entry.get("statements", []): _check(data.statements.has(statement_id), "问话目标缺失：" + id)
	for id in data.conditions:
		_check(data.conditions[id] is Array and not data.conditions[id].is_empty(), "条件必须具有显式分支：" + id)
		for branch in data.conditions[id]:
			for term in branch:
				_check(term.get("kind", "") in ["fact", "heard", "owned", "completed"], "未知条件：" + id)
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
		for ref in r.get("materials", []): _check(valid_material_ref(ref), "关系材料版本无效：" + id)
		if not data.questions.has(r.get("question_id", "")): continue
		var q: Dictionary = data.questions[r.question_id]
		if q.get("target_kind", "statement") == "reasoning":
			_check(r.get("question_text_id", "") == q.get("question_text_id", ""), "推理目标不精确：" + id)
			_check(str(r.get("statement_id", "")).is_empty() and str(r.get("after", "")).is_empty(), "推理不能更正人物目标：" + id)
			_check(r.get("effect_kind", "support") in ["support", "inference", "ordinary"], "推理问题不能碎裂原话：" + id)
		else:
			_check(data.statements.has(r.get("statement_id", "")), "关系目标说法缺失：" + id)
		var level: String = r.get("effect_level", "normal")
		_check(level in ["normal", "progress", "key"], "表现等级错误：" + id)
		if level != "normal": _check(r.get("feedback") == "full", "强表现要求充分成果：" + id)
		_check((level == "key") == (not str(r.get("climax_key", "")).is_empty()), "高潮标识绑定错误：" + id)
		if r.get("feedback") == "incorrect":
			_text_ref(r.get("reason", ""), id)
			_check(str(r.get("result_key", "")).is_empty() and str(r.get("inference", "")).is_empty(), "错误关系不能提交成果：" + id)
		if not str(r.get("inference", "")).is_empty():
			_check(data.contents.has(r.inference), "推论内容缺失：" + id)
			_check(data.nodes[r.node].get("timing") == "collect", "新推论必须主动收下：" + id)
			for ref in r.materials: _check(ref.content_id != r.inference, "推论不能以自身为来源：" + id)
		for basis in r.get("basis_results", []):
			_check(data.relations.has(basis.get("relation_id", "")), "前次关联不存在：" + id)
			_check(basis.get("target_ref") is Dictionary, "前次目标必须精确：" + id)
		if r.feedback == "full" and data.nodes.has(r.get("node", "")):
			_check(data.groups.has(data.nodes[r.node].get("group", "")), "充分关系缺少确认结果组：" + id)
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
	return errors.is_empty()

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

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

func _json(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text()) if file else null
