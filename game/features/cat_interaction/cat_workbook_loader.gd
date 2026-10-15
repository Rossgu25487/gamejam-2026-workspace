extends RefCounted
## 原生读取撸猫配置 XLSX：仅消费固定字段、四行表头与启用行，不执行公式、宏或外部引用。
## 输出四张表的记录数组（含 _formal 标记与 _location 溯源），页面与 Main 不需要了解 Excel 格式。

const DEFAULT_PATH := "res://代码开发需求/撸猫系统/撸猫系统配置表.xlsx"

var errors: Array[String] = []
var origins: Dictionary = {}

var _zip: ZIPReader
var _shared: Array[String] = []

# 字段模式：工作表 -> {"id": ID字段, "fields": {字段 -> {"type","required","min","max"}}}。
# type 取值 string/int/float/bool；空值分别按空串、null、null 处理（required 字段报错）。
const SCHEMA := {
	"猫互动": {"id": "id", "fields": {
		"id": {"type": "string", "required": true},
		"scene_ref": {"type": "string"},
		"cat_object_ref": {"type": "string"},
		"view_profile_ref": {"type": "string"},
		"pet_ms": {"type": "int", "required": true, "min": 1},
		"response_ms": {"type": "int", "required": true, "min": 1},
		"purr_gain": {"type": "float", "required": true, "min": 0.0, "max": 1.0},
		"sound_ref": {"type": "string"},
		"first_caption_text_id": {"type": "string"},
		"repeat_caption_text_id": {"type": "string"},
	}},
	"猫展示": {"id": "id", "fields": {
		"id": {"type": "string", "required": true},
		"visual_host_ref": {"type": "string"},
		"camera_ref": {"type": "string"},
		"screen_x": {"type": "float", "min": 0.0, "max": 1.0},
		"screen_y": {"type": "float", "min": 0.0, "max": 1.0},
		"screen_w": {"type": "float", "min": 0.0, "max": 1.0},
		"screen_h": {"type": "float", "min": 0.0, "max": 1.0},
		"head_x": {"type": "float", "min": 0.0, "max": 1.0},
		"head_y": {"type": "float", "min": 0.0, "max": 1.0},
		"head_w": {"type": "float", "min": 0.0, "max": 1.0},
		"head_h": {"type": "float", "min": 0.0, "max": 1.0},
		"anchor_x": {"type": "float", "min": 0.0, "max": 1.0},
		"anchor_y": {"type": "float", "min": 0.0, "max": 1.0},
		"flip_horizontal": {"type": "bool"},
		"display_scale": {"type": "float", "min": 0.0},
	}},
	"动作绑定": {"id": "id", "fields": {
		"id": {"type": "string", "required": true},
		"interaction_ref": {"type": "string"},
		"action_kind": {"type": "string"},
		"visual_ref": {"type": "string"},
		"play_mode": {"type": "string"},
		"stable_point": {"type": "float", "min": 0.0, "max": 1.0},
	}},
	"文字绑定": {"id": "id", "fields": {
		"id": {"type": "string", "required": true},
		"text_id": {"type": "string", "required": true},
	}},
}

func load_workbook(path: String = DEFAULT_PATH) -> Dictionary:
	# 每次启动只读一次；不轮询文件，也不保留压缩包与 XML 对象。
	errors.clear()
	origins.clear()
	_shared.clear()
	_zip = ZIPReader.new()
	if _zip.open(path) != OK:
		_error("无法打开撸猫配置表：" + path)
		return {}
	if _zip.file_exists("xl/sharedStrings.xml"):
		_read_shared_strings()
	var paths := _sheet_paths()
	var tables := {}
	for sheet_name in SCHEMA:
		if not paths.has(sheet_name):
			_error("缺少工作表：" + sheet_name)
			continue
		tables[sheet_name] = _read_table(paths[sheet_name], sheet_name, SCHEMA[sheet_name])
	_zip.close()
	_zip = null
	if not errors.is_empty(): return {}
	return tables

func _read_table(path: String, sheet_name: String, definition: Dictionary) -> Array:
	# 第2行 ##var 建立字段到列的映射；A列空为正式行，A列以 # 开头（##/注释）不正式导出。
	var cells := _sheet_cells(path)
	var headers: Dictionary = cells.get(2, {})
	if _value(headers, "A") != "##var":
		_error("%s 第2行表头应为 ##var，请勿删除四行表头" % sheet_name)
		return []
	var keys := {}
	for column in headers:
		var key := _value(headers, column)
		if key.is_empty() or key.begins_with("#"): continue  # 跳过 #备注/#使用位置 等不导出列
		keys[key] = column
	for field in definition.fields:
		if not keys.has(field): _error("%s 缺少列：%s" % [sheet_name, field])
	if not errors.is_empty(): return []
	var records: Array = []
	var row_numbers: Array = cells.keys()
	row_numbers.sort()
	for row_number in row_numbers:
		if int(row_number) < 5: continue
		var row: Dictionary = cells[row_number]
		var id := _value(row, keys[definition.id]).strip_edges()
		if id.is_empty(): continue
		var location := "%s 第%d行" % [sheet_name, row_number]
		var record := {"_location": location, "_formal": not _value(row, "A").begins_with("#")}
		record[definition.id] = id
		for field in definition.fields:
			if field == definition.id: continue
			var spec: Dictionary = definition.fields[field]
			var column: String = keys[field]
			if row.get(column, {}).get("formula", false) or row.get(column, {}).get("error", false):
				_error("%s %s：请输入实际内容，不使用公式或错误值" % [location, field])
			record[field] = _parse(_value(row, column), spec, location, field)
		if not _id_valid(id): _error(location + "：ID只能包含英文字母、数字、下划线、短横线或点")
		records.append(record)
	return records

func _parse(raw: String, spec: Dictionary, location: String, field: String):
	var value := raw.strip_edges()
	match str(spec.get("type", "string")):
		"int":
			if value.is_empty():
				if spec.get("required", false): _error("%s %s：必填项为空" % [location, field])
				return null
			if not value.is_valid_int(): _error("%s %s：需要整数" % [location, field]); return null
			var n := int(value)
			if spec.has("min") and n < int(spec.min): _error("%s %s：数值过小" % [location, field]); return null
			if spec.has("max") and n > int(spec.max): _error("%s %s：数值过大" % [location, field]); return null
			return n
		"float":
			if value.is_empty():
				if spec.get("required", false): _error("%s %s：必填项为空" % [location, field])
				return null
			if not value.is_valid_float(): _error("%s %s：需要数字" % [location, field]); return null
			var f := float(value)
			if not is_finite(f): _error("%s %s：需要有限数字" % [location, field]); return null
			if spec.has("min") and f < float(spec.min): _error("%s %s：数值过小" % [location, field]); return null
			if spec.has("max") and f > float(spec.max): _error("%s %s：数值过大" % [location, field]); return null
			return f
		"bool":
			if value.is_empty():
				if spec.get("required", false): _error("%s %s：必填项为空" % [location, field])
				return null
			if value.to_lower() not in ["true", "false", "1", "0"]: _error("%s %s：需要 true 或 false" % [location, field]); return null
			return value.to_lower() in ["true", "1"]
		_:
			if spec.get("required", false) and value.is_empty(): _error("%s %s：必填项为空" % [location, field])
			return value

func _error(message: String) -> void:
	errors.append(message)

func _id_valid(id: String) -> bool:
	if id.is_empty(): return false
	for ch in id:
		if not ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in ["_", "-", "."]): return false
	return true

func _value(row: Dictionary, column: String) -> String:
	return str(row.get(column, {}).get("value", ""))

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
