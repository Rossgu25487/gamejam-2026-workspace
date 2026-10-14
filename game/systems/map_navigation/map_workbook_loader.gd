extends RefCounted
## 地图配置表读取器：只读取地图系统需要的实际单元格，不执行公式或宏。
## 输出统一结构，页面和会话服务不需要了解 XLSX 的压缩 XML 细节。

const DEFAULT_PATH := "res://代码开发需求/地图切换系统/地图切换系统配置表.xlsx"
const FALLBACK_PATH := "res://代码开发需求/测试用资源/配置表/地图切换系统配置表.xlsx"

var errors: Array[String] = []
var _zip: ZIPReader
var _shared: Array[String] = []

func load_workbook(path: String = DEFAULT_PATH) -> Dictionary:
	errors.clear()
	_shared.clear()
	_zip = ZIPReader.new()
	if _zip.open(path) != OK:
		if path == DEFAULT_PATH and _zip.open(FALLBACK_PATH) == OK:
			path = FALLBACK_PATH
		else:
			errors.append("无法打开地图配置表：" + path)
			return {}
	if _zip.file_exists("xl/sharedStrings.xml"):
		_read_shared_strings()
	var sheets := _sheet_paths()
	var result := {"display": {}, "boards": {}, "groups": {}, "scenes": {}, "resources": {}, "nodes": {}, "function_text": {}, "pawn": {}, "transitions": []}
	for sheet_name in sheets:
		var records := _read_records(sheets[sheet_name])
		if records.is_empty():
			continue
		var key := _section_for(sheet_name)
		if key == "transitions":
			result.transitions.append_array(records)
		elif key != "":
			for record in records:
				var id := str(record.get(_id_field(key), record.get("id", "")))
				if id.is_empty():
					continue
				result[key][id] = record
	_zip.close()
	_zip = null
	if not errors.is_empty():
		return {}
	return result

func _section_for(name: String) -> String:
	var normalized := name.replace(" ", "").replace("　", "")
	if normalized in ["地图显示参数", "显示参数"]: return "display"
	if normalized in ["棋盘布局", "棋盘"]: return "boards"
	if normalized == "地图分组": return "groups"
	if normalized in ["场景定义", "地点定义"]: return "scenes"
	if normalized in ["场景资源", "资源"]: return "resources"
	if normalized in ["地点节点", "地图节点", "节点"]: return "nodes"
	if normalized in ["功能文字引用", "功能文字"]: return "function_text"
	if normalized in ["棋子表现", "棋子"]: return "pawn"
	if normalized in ["地点连接", "场景连接"]: return "transitions"
	return ""

func _id_field(section: String) -> String:
	match section:
		"display": return "key"
		"boards": return "board_id"
		"groups": return "group_id"
		"scenes": return "scene_id"
		"resources": return "resource_id"
		"nodes": return "node_id"
		"function_text": return "text_id"
		"pawn": return "pawn_id"
	return "id"

func _sheet_paths() -> Dictionary:
	var relations := {}
	var parser := _xml("xl/_rels/workbook.xml.rels")
	if parser == null: return {}
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and _name(parser) == "Relationship":
			var attrs := _attrs(parser)
			var target: String = attrs.get("Target", "")
			var path := target.trim_prefix("/") if target.begins_with("/") else ("xl/" + target).simplify_path()
			if path.begins_with("xl/"): relations[attrs.get("Id", "")] = path
	parser = _xml("xl/workbook.xml")
	if parser == null: return {}
	var sheets := {}
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and _name(parser) == "sheet":
			var attrs := _attrs(parser)
			var rid := ""
			for key in attrs:
				if str(key).ends_with(":id"): rid = attrs[key]
			if relations.has(rid): sheets[attrs.get("name", "")] = relations[rid]
	return sheets

func _read_shared_strings() -> void:
	var parser := _xml("xl/sharedStrings.xml")
	if parser == null: return
	var current := ""
	var reading := false
	var phonetic := false
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				match _name(parser):
					"si": current = ""
					"rPh": phonetic = true
					"t": reading = not phonetic and not parser.is_empty()
			XMLParser.NODE_TEXT:
				if reading: current += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				match _name(parser):
					"t": reading = false
					"rPh": phonetic = false
					"si": _shared.append(current)

func _read_records(path: String) -> Array:
	var parser := _xml(path)
	if parser == null: return []
	var rows := {}
	var cell := ""
	var cell_type := ""
	var value := ""
	var reading := false
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				match _name(parser):
					"c":
						var attrs := _attrs(parser)
						cell = attrs.get("r", "")
						cell_type = attrs.get("t", "")
						value = ""
					"v", "t": reading = not parser.is_empty() and not cell.is_empty()
			XMLParser.NODE_TEXT:
				if reading: value += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				match _name(parser):
					"v", "t": reading = false
					"c":
						if cell.is_empty(): continue
						var column := ""
						var number := ""
						for ch in cell:
							if ch >= "0" and ch <= "9": number += ch
							else: column += ch
						if not number.is_valid_int(): cell = ""; continue
						if cell_type == "s" and value.is_valid_int() and int(value) >= 0 and int(value) < _shared.size(): value = _shared[int(value)]
						if not rows.has(int(number)): rows[int(number)] = {}
						rows[int(number)][column] = value
						cell = ""
	var row_numbers: Array = rows.keys()
	row_numbers.sort()
	if row_numbers.size() < 2: return []
	var header_row := int(row_numbers[0])
	var data_start := header_row + 1
	var headers: Dictionary = rows[header_row]
	# 正式表沿用项目四行表头；兼容普通首行表头，便于测试夹具使用。
	if rows.has(2) and rows[2].has("A") and str(rows[2]["A"]).begins_with("##"):
		header_row = 2
		headers = rows[2]
		data_start = 5
	var result: Array = []
	for number in row_numbers:
		if int(number) < data_start: continue
		var source: Dictionary = rows[number]
		var record := {}
		for column in headers:
			var field := str(headers[column]).strip_edges()
			if field.is_empty() or field.begins_with("#"): continue
			var raw := str(source.get(column, "")).strip_edges()
			if field in ["enabled", "启用"] and raw.to_lower() in ["false", "0", "否"]: record = {}; break
			record[_normalize_field(field)] = _coerce(raw)
		if not record.is_empty(): result.append(record)
	return result

func _normalize_field(field: String) -> String:
	var aliases := {"键": "key", "参数": "key", "值": "value", "参数值": "value", "场景ID": "scene_id", "地点ID": "scene_id", "节点ID": "node_id", "分组ID": "group_id", "资源ID": "resource_id", "棋盘ID": "board_id", "文字ID": "text_id", "图片路径": "path", "PNG资源路径": "path"}
	if aliases.has(field): return aliases[field]
	var value := field.to_snake_case()
	return value

func _coerce(raw: String):
	if raw.is_empty(): return ""
	if raw.to_lower() in ["true", "false"]: return raw.to_lower() == "true"
	if raw.is_valid_int(): return int(raw)
	if raw.is_valid_float(): return float(raw)
	return raw

func _xml(path: String) -> XMLParser:
	var parser := XMLParser.new()
	if not _zip.file_exists(path) or parser.open_buffer(_zip.read_file(path)) != OK:
		errors.append("地图配置表内部文件无法读取：" + path)
		return null
	return parser

func _name(parser: XMLParser) -> String:
	var name := parser.get_node_name()
	return name.get_slice(":", name.get_slice_count(":") - 1)

func _attrs(parser: XMLParser) -> Dictionary:
	var result := {}
	for i in range(parser.get_attribute_count()): result[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
	return result
