extends RefCounted
## 从合法运行记录派生手册会面段。正文仍引用唯一内容源，成果依据沿形成时快照。

static func record_id(record: Dictionary) -> String:
	# 缺少新增身份字段的旧档沿既有精确引用生成身份，缺少阅读标记按未读处理。
	if record.has("record_id"): return str(record.record_id)
	if record.get("kind") == "confirmed": return "confirmed/%s" % record.get("result_id", "")
	return "statement/%s/%s" % [record.get("entry_id", ""), record.get("statement_id", "")]

static func segments(records: Array, catalog: RefCounted) -> Array:
	var groups := {}
	for index in range(records.size()):
		var record: Dictionary = records[index]
		if record.get("kind") != "statement" or record.get("entry_id") == "result": continue
		var entry_id: String = record.get("entry_id", "")
		var entry: Dictionary = catalog.data.entries.get(entry_id, {})
		var id := "entry/" + entry_id
		if not groups.has(id):
			var object_id: String = entry.get("object_id", "")
			if not catalog.data.characters.has(object_id): object_id = record.get("speaker", "")
			groups[id] = _segment(id, object_id, entry_id, entry.get("title", ""), index)
		groups[id].statements.append(record.duplicate(true))
		_append_record(groups[id], record, index)
	# 更正在业务时点生效后才进入记录，关联原精确说法；原话持续保留。
	for index in range(records.size()):
		var record: Dictionary = records[index]
		if record.get("kind") != "confirmed": continue
		var result: Dictionary = record.get("record", {})
		var q: Dictionary = catalog.data.questions.get(result.get("question_id", ""), {})
		var targets: Array = []
		var statement_id: String = result.get("target_ref", {}).get("statement_ref", {}).get("statement_id", "")
		for segment in groups.values():
			for original in segment.statements:
				if not statement_id.is_empty() and original.get("statement_id") == statement_id:
					targets.append(segment); break
		if targets.is_empty():
			var id := "result/" + str(record.get("result_id", ""))
			groups[id] = _segment(id, q.get("parent", ""), result.get("question_id", ""), q.get("title", ""), index)
			targets.append(groups[id])
		for segment in targets:
			segment.corrections.append(record.duplicate(true))
			_append_record(segment, record, index)
			var node: Dictionary = catalog.data.nodes.get(result.get("node", ""), {})
			for action in catalog.data.groups.get(node.get("group", ""), []):
				if action.get("kind") != "correct": continue
				for corrected in records:
					if corrected.get("kind") == "statement" and corrected.get("entry_id") == "result" and corrected.get("statement_id") == action.get("statement_id"):
						if corrected not in segment.corrected_statements: segment.corrected_statements.append(corrected.duplicate(true))
						_append_record(segment, corrected, index)
	var result: Array = groups.values()
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.order) > int(b.order))
	return result

static func _segment(id: String, object_id: String, topic_id: String, title_id: String, order: int) -> Dictionary:
	return {"id": id, "object_id": object_id, "topic_id": topic_id, "title_id": title_id, "order": order, "statements": [], "corrections": [], "corrected_statements": [], "record_ids": [], "unread": false}

static func _append_record(segment: Dictionary, record: Dictionary, order: int) -> void:
	var id := record_id(record)
	if id not in segment.record_ids: segment.record_ids.append(id)
	segment.unread = segment.unread or not record.get("read", false)
	segment.order = maxi(int(segment.order), order)
