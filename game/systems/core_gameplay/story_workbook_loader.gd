extends RefCounted
## 原生读取故事 XLSX：仅消费固定字段和启用行，不执行公式、脚本或 Office 宏。
## 输出当前核心目录使用的数据结构，页面和 Main 不需要了解 Excel 格式。

const SCHEMA_PATH := "res://data/story/schema.json"
const DEFAULT_PATH := "res://data/story/outputs/story-config-20261011/故事配置表.xlsx"
var errors: Array[String] = []
var origins: Dictionary = {}
var _zip: ZIPReader
var _shared: Array[String] = []
var _data: Dictionary = {}

func load_workbook(path: String) -> Dictionary:
	# 每次启动只读一次；不轮询文件，也不保留压缩包和 XML 对象。
	errors.clear()
	origins.clear()
	_shared.clear()
	var schema_file := FileAccess.open(SCHEMA_PATH, FileAccess.READ)
	var schema = JSON.parse_string(schema_file.get_as_text()) if schema_file else null
	if not schema is Dictionary:
		_error("故事字段定义无法读取")
		return {}
	_zip = ZIPReader.new()
	if _zip.open(path) != OK:
		_error("无法打开故事配置表：" + path)
		return {}
	if _zip.file_exists("xl/sharedStrings.xml"):
		_read_shared_strings()
	var paths := _sheet_paths()
	var tables := {}
	for definition in schema.sheets:
		var name: String = definition.name
		if not paths.has(name):
			_error("缺少工作表：" + name)
			continue
		tables[name] = _read_table(paths[name], definition)
	_zip.close()
	_zip = null
	if not errors.is_empty(): return {}
	return _compile(tables)

func locate_catalog_errors(messages: Array[String]) -> Array[String]:
	# 核心语义错误沿稳定 ID 回到原行，不把无效配置偷偷替换为占位案。
	var result: Array[String] = []
	for message in messages:
		var suffix := message.get_slice("：", 1).get_slice("/", 0)
		result.append("%s：%s" % [origins[suffix], message] if origins.has(suffix) else message)
	return result

func _error(message: String) -> void:
	errors.append(message)

func _xml(path: String) -> XMLParser:
	var parser := XMLParser.new()
	if not _zip.file_exists(path) or parser.open_buffer(_zip.read_file(path)) != OK:
		_error("XLSX 内部 XML 无法读取：" + path)
		return null
	return parser

func _name(parser: XMLParser) -> String:
	return parser.get_node_name().get_slice(":", parser.get_node_name().get_slice_count(":") - 1)

func _attrs(parser: XMLParser) -> Dictionary:
	var attributes := {}
	for i in range(parser.get_attribute_count()):
		attributes[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
	return attributes

func _sheet_paths() -> Dictionary:
	var relations := {}
	var parser := _xml("xl/_rels/workbook.xml.rels")
	if parser == null: return {}
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and _name(parser) == "Relationship":
			var a := _attrs(parser)
			if a.get("TargetMode", "") == "External": continue
			var target: String = a.get("Target", "")
			var path := target.trim_prefix("/") if target.begins_with("/") else "xl/".path_join(target).simplify_path()
			if path.begins_with("xl/"): relations[a.get("Id", "")] = path
	parser = _xml("xl/workbook.xml")
	if parser == null: return {}
	var sheets := {}
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and _name(parser) == "sheet":
			var a := _attrs(parser)
			var rid: String = a.get("r:id", "")
			# namespace 前缀可以改变，关系属性的本名仍为 id。
			for key in a:
				if str(key).ends_with(":id"): rid = a[key]
			if relations.has(rid): sheets[a.get("name", "")] = relations[rid]
	return sheets

func _read_shared_strings() -> void:
	var parser := _xml("xl/sharedStrings.xml")
	if parser == null: return
	var text := ""
	var reading_text := false
	var phonetic := false
	while parser.read() == OK:
		var kind := parser.get_node_type()
		if kind == XMLParser.NODE_ELEMENT:
			match _name(parser):
				"si": text = ""
				"rPh": phonetic = true
				"t": reading_text = not phonetic and not parser.is_empty()
		elif kind == XMLParser.NODE_TEXT and reading_text: text += parser.get_node_data()
		elif kind == XMLParser.NODE_ELEMENT_END:
			match _name(parser):
				"t": reading_text = false
				"rPh": phonetic = false
				"si": _shared.append(text)

func _sheet_cells(path: String) -> Dictionary:
	var parser := _xml(path)
	if parser == null: return {}
	var rows := {}
	var cell := ""
	var cell_type := ""
	var value := ""
	var in_text := false
	var formula := false
	while parser.read() == OK:
		var kind := parser.get_node_type()
		if kind == XMLParser.NODE_ELEMENT:
			match _name(parser):
				"c":
					var a := _attrs(parser)
					cell = a.get("r", "")
					cell_type = a.get("t", "")
					value = ""
					formula = false
					if parser.is_empty(): cell = ""
				"v", "t": in_text = not parser.is_empty() and not cell.is_empty()
				"f": formula = true
		elif kind == XMLParser.NODE_TEXT and in_text: value += parser.get_node_data()
		elif kind == XMLParser.NODE_ELEMENT_END:
			match _name(parser):
				"v", "t": in_text = false
				"c":
					if cell.is_empty(): continue
					var column := ""
					var number := ""
					for ch in cell:
						if ch >= "0" and ch <= "9": number += ch
						else: column += ch
					if number.is_empty(): continue
					var row := int(number)
					if not rows.has(row): rows[row] = {}
					if cell_type == "s":
						if not value.is_valid_int() or int(value) < 0 or int(value) >= _shared.size():
							_error("共享文本索引无效：" + cell)
							value = ""
						else: value = _shared[int(value)]
					rows[row][column] = {"value": value, "formula": formula, "error": cell_type == "e"}
					cell = ""
	return rows

func _value(row: Dictionary, column: String) -> String:
	return str(row.get(column, {}).get("value", ""))

func _read_table(path: String, definition: Dictionary) -> Array:
	var cells := _sheet_cells(path)
	var keys := {"enabled": "B"}
	var headers: Dictionary = cells.get(2, {})
	if _value(headers, "A") != "##var" or _value(headers, "B") != "enabled":
		_error("%s 第2行表头应为 ##var / enabled，请勿删除四行表头" % definition.name)
		return []
	for column in headers:
		var key := _value(headers, column)
		if not key.is_empty(): keys[key] = column
	for field in definition.fields:
		if not keys.has(field[0]):
			_error("%s 缺少列：%s" % [definition.name, field[0]])
		elif _value(cells.get(3, {}), keys[field[0]]) != field[2]:
			_error("%s 第3行字段类型不符：%s" % [definition.name, field[0]])
	if not errors.is_empty(): return []
	var records: Array = []
	var row_numbers: Array = cells.keys()
	row_numbers.sort()
	for row_number in row_numbers:
		if int(row_number) < 5: continue
		var row: Dictionary = cells[row_number]
		if _value(row, "A").begins_with("#"): continue
		var id: String = _value(row, keys[definition.id]).strip_edges()
		var enabled := _value(row, "B").strip_edges().to_lower()
		if id.is_empty() and enabled.is_empty(): continue
		var location := "%s 第%d行" % [definition.name, row_number]
		if row.get("B", {}).get("formula", false) or row.get("B", {}).get("error", false):
			_error(location + " enabled 不能使用公式或错误值")
			continue
		if enabled not in ["true", "false", "1", "0"]:
			_error(location + " enabled 应填 true 或 false")
			continue
		if enabled in ["false", "0"]: continue
		var record := {"_location": location}
		for field in definition.fields:
			var key: String = field[0]
			var column: String = keys[key]
			var raw := _value(row, column)
			if row.get(column, {}).get("formula", false) or row.get(column, {}).get("error", false):
				_error("%s %s：请输入实际内容，不使用公式或错误值" % [location, key])
			if field[3] and raw.strip_edges().is_empty(): _error("%s %s：必填项为空" % [location, key])
			var options: String = field[4]
			if not options.is_empty() and field[2] != "bool" and raw not in options.split(","): _error("%s %s：不支持的选项 %s" % [location, key, raw])
			match str(field[2]):
				"int":
					if not raw.is_valid_int() or int(raw) < 1: _error("%s %s：需要正整数" % [location, key])
					record[key] = int(raw)
				"bool":
					if raw.to_lower() not in ["true", "false", "1", "0"]: _error("%s %s：需要 true 或 false" % [location, key])
					record[key] = raw.to_lower() in ["true", "1"]
				"list":
					var ids: Array = []
					for item in raw.split(";", false):
						var ref := item.strip_edges()
						if not _id_valid(ref): _error("%s %s：列表ID无效 %s；使用英文分号分隔" % [location, key, ref])
						elif ref in ids: _error("%s %s：列表ID重复 %s" % [location, key, ref])
						else: ids.append(ref)
					record[key] = ids
				_: record[key] = raw
		if not _id_valid(id): _error(location + "：ID只能包含英文字母、数字、下划线、短横线或点")
		record[definition.id] = id
		records.append(record)
	return records

func _id_valid(id: String) -> bool:
	if id.is_empty(): return false
	for ch in id:
		if not ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in ["_", "-", "."]): return false
	return true

func _put(section: String, id: String, value, location: String) -> void:
	if _data[section].has(id): _error(location + "：ID重复 " + id)
	else:
		_data[section][id] = value
		origins[id] = location

func _text(section: String, id: String, field: String, value: String) -> String:
	if value.is_empty(): return ""
	var ref := "%s/%s/%s" % [section, id, field]
	_data.texts[ref] = value
	return ref

func _copy(record: Dictionary, fields: Array) -> Dictionary:
	var result := {}
	for field in fields: result[field] = record[field]
	return result

func _ordered(rows: Array, owner: String, branch: bool = false) -> Array:
	var seen := {}
	for row in rows:
		var key := JSON.stringify([row[owner], row.get("branch", 0), row.order])
		if seen.has(key): _error(row._location + "：组内顺序重复")
		seen[key] = true
	rows.sort_custom(func(a: Dictionary, b: Dictionary):
		if a[owner] != b[owner]: return a[owner] < b[owner]
		if branch and a.branch != b.branch: return int(a.branch) < int(b.branch)
		return int(a.order) < int(b.order))
	return rows

func _compile(tables: Dictionary) -> Dictionary:
	_data = {"texts": {}, "scenes": {}, "characters": {}, "materials": {}, "contents": {}, "statements": {}, "questions": {}, "entries": {}, "conditions": {}, "relations": {}, "nodes": {}, "groups": {}, "scene_links": {}}
	if tables["案件"].size() != 1:
		_error("案件：必须有且只有一条启用的案件记录")
		return {}
	var case_row: Dictionary = tables["案件"][0]
	for key in ["case_id", "content_revision", "initial_scene", "placeholder", "completion_condition"]: _data[key] = case_row[key]
	_data["package_title"] = _text("case", case_row.case_id, "title", case_row.title)
	_data.texts["package_note"] = case_row.note
	_data["completion_text"] = _text("case", case_row.case_id, "completion_text", case_row.completion_text)
	for spec in [["地点", "scenes", "scene_id"], ["人物", "characters", "character_id"]]:
		for row in tables[spec[0]]:
			_put(spec[1], row[spec[2]], {"name": _text(spec[1], row[spec[2]], "name", row.name)}, row._location)
	for row in tables["材料"]: _put("materials", row.material_id, {"type": row.type}, row._location)
	for row in tables["材料版本"]:
		var value := _copy(row, ["material_id", "version", "previous"])
		for field in ["title", "summary", "body"]: value[field] = _text("contents", row.content_id, field, row[field])
		_put("contents", row.content_id, value, row._location)
	for row in tables["人物说法"]:
		var value := _copy(row, ["claim_id", "speaker", "version", "record_content"])
		value.text = _text("statements", row.statement_id, "text", row.text)
		_put("statements", row.statement_id, value, row._location)
	for row in tables["问题"]:
		var value := _copy(row, ["scene_id", "target_kind", "parent", "statement_id", "condition", "insufficient_node"])
		value.title = _text("questions", row.question_id, "title", row.title)
		value.question_text_id = _text("questions", row.question_id, "question_text", row.question_text)
		if row.target_kind == "statement" and not row.question_text.is_empty(): _error(row._location + "：人物说法问题的推理正文应留空")
		if row.target_kind == "reasoning" and (not row.statement_id.is_empty() or not row.parent.is_empty()): _error(row._location + "：推理问题的说法和人物应留空")
		_put("questions", row.question_id, value, row._location)
	for row in tables["调查入口"]:
		var value := _copy(row, ["scene_id", "condition", "source_id", "object_id", "contents", "statements", "facts"])
		for field in ["title", "text"]: value[field] = _text("entries", row.entry_id, field, row[field])
		_put("entries", row.entry_id, value, row._location)
	var condition_groups := {}
	for row in _ordered(tables["条件"], "condition_id", true):
		if not condition_groups.has(row.condition_id): condition_groups[row.condition_id] = {}
		var branches: Dictionary = condition_groups[row.condition_id]
		if not branches.has(row.branch): branches[row.branch] = []
		branches[row.branch].append(row)
		origins[row.condition_id] = row._location
	for id in condition_groups:
		var branches: Array = []
		for rows in condition_groups[id].values():
			var terms: Array = []
			for row in rows:
				if row.kind == "always":
					if rows.size() != 1 or not row.ref.is_empty(): _error(row._location + "：always 必须独占分支且 ref 留空")
				else:
					if not _id_valid(row.ref): _error(row._location + "：条件引用ID为空或无效")
					terms.append({"kind": row.kind, "ref": row.ref})
			branches.append(terms)
		_data.conditions[id] = branches
	for row in _ordered(tables["结果动作"], "group_id"):
		if not _data.groups.has(row.group_id): _data.groups[row.group_id] = []
		var action := {"kind": row.kind}
		if row.kind == "fact": action.ref = row.ref
		elif row.kind == "correct":
			action.question_id = row.question_id
			action.statement_id = row.statement_id
		_data.groups[row.group_id].append(action)
		origins[row.group_id] = row._location
	for row in tables["结果节点"]:
		var value := _copy(row, ["timing", "group", "next_questions"])
		value.text = _text("nodes", row.node_id, "text", row.text)
		_put("nodes", row.node_id, value, row._location)
	for row in tables["出示关系"]:
		var value := _copy(row, ["question_id", "statement_id", "feedback", "node", "condition", "match_scope", "result_key", "confirmed_scope", "inference", "effect_kind", "effect_level", "climax_key", "statement_quote"])
		value.question_text_id = _data.questions.get(row.question_id, {}).get("question_text_id", "")
		value.materials = []
		for content_id in [row.content_a, row.content_b]:
			if content_id.is_empty(): continue
			if not _data.contents.has(content_id): _error(row._location + "：材料版本不存在 " + content_id)
			else: value.materials.append({"material_id": _data.contents[content_id].material_id, "content_id": content_id})
		value.reason = _text("relations", row.relation_id, "reason", row.reason)
		_put("relations", row.relation_id, value, row._location)
	for row in _ordered(tables["前次依据"], "relation_id"):
		if not _data.relations.has(row.relation_id) or not _data.relations.has(row.basis_relation_id):
			_error(row._location + "：当前或前次关系不存在")
			continue
		var previous: Dictionary = _data.relations[row.basis_relation_id]
		if previous.feedback != "full": _error(row._location + "：前次依据必须是充分关系")
		var q: Dictionary = _data.questions.get(previous.question_id, {})
		var target := {"target_kind": q.get("target_kind", ""), "question_id": previous.question_id}
		if target.target_kind == "statement": target.statement_ref = {"claim_id": _data.statements.get(previous.statement_id, {}).get("claim_id", ""), "statement_id": previous.statement_id}
		else: target.question_text_id = previous.question_text_id
		var current: Dictionary = _data.relations[row.relation_id]
		if not current.has("basis_results"): current.basis_results = []
		current.basis_results.append({"relation_id": row.basis_relation_id, "target_ref": target})
	for row in tables["地点连接"]:
		var value := _copy(row, ["from_scene", "to_scene", "condition"])
		value.title = _text("scene_links", row.link_id, "title", row.title)
		_put("scene_links", row.link_id, value, row._location)
	if not errors.is_empty(): return {}
	return _data
