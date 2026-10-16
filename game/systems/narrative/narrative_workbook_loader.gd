extends RefCounted
## 文案工作簿读取器：只负责把 Excel 的中文字段转换为文案服务的标准字典。
## 页面和 Main 不接触 ZIP/XML；正式表与测试表可以通过同一接口加载。

const DEFAULT_PATH := "res://代码开发需求/文案系统/极光_脚本文本与场景配置_文案系统修订.xlsx"
const TEST_PATH := "res://代码开发需求/测试用资源/配置表/文案系统_测试配置表.xlsx"

var errors: Array[String] = []
var _zip: ZIPReader
var _shared: Array[String] = []

func load_workbook(path: String = DEFAULT_PATH) -> Dictionary:
	errors.clear()
	_shared.clear()
	_zip = ZIPReader.new()
	if _zip.open(path) != OK:
		errors.append("无法打开文案配置表：" + path)
		return {}
	if _zip.file_exists("xl/sharedStrings.xml"):
		_read_shared_strings()
	var sheets := _sheet_paths()
	var raw := {}
	for sheet_name in sheets:
		raw[sheet_name] = _read_rows(sheets[sheet_name])
	_zip.close()
	_zip = null
	return _compile(raw)

func _xml(path: String) -> XMLParser:
	var parser := XMLParser.new()
	if _zip == null or not _zip.file_exists(path) or parser.open_buffer(_zip.read_file(path)) != OK:
		errors.append("文案表 XML 无法读取：" + path)
		return null
	return parser

func _name(parser: XMLParser) -> String:
	var value := parser.get_node_name()
	return value.get_slice(":", value.get_slice_count(":") - 1)

func _attrs(parser: XMLParser) -> Dictionary:
	var result := {}
	for index in range(parser.get_attribute_count()):
		result[parser.get_attribute_name(index)] = parser.get_attribute_value(index)
	return result

func _sheet_paths() -> Dictionary:
	var relations := {}
	var rels := _xml("xl/_rels/workbook.xml.rels")
	if rels == null: return relations
	while rels.read() == OK:
		if rels.get_node_type() == XMLParser.NODE_ELEMENT and _name(rels) == "Relationship":
			var attr := _attrs(rels)
			if attr.get("TargetMode", "") == "External": continue
			var target: String = attr.get("Target", "")
			var path := target.trim_prefix("/") if target.begins_with("/") else "xl/".path_join(target).simplify_path()
			if path.begins_with("xl/"): relations[attr.get("Id", "")] = path
	var workbook := _xml("xl/workbook.xml")
	if workbook == null: return {}
	var result := {}
	while workbook.read() == OK:
		if workbook.get_node_type() == XMLParser.NODE_ELEMENT and _name(workbook) == "sheet":
			var attr := _attrs(workbook)
			var rid := ""
			for key in attr:
				if str(key).ends_with(":id"): rid = attr[key]
			if relations.has(rid): result[attr.get("name", "")] = relations[rid]
	return result

func _read_shared_strings() -> void:
	var parser := _xml("xl/sharedStrings.xml")
	if parser == null: return
	var current := ""
	var reading := false
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			if _name(parser) == "si": current = ""
			elif _name(parser) == "t": reading = not parser.is_empty()
		elif parser.get_node_type() == XMLParser.NODE_TEXT and reading: current += parser.get_node_data()
		elif parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
			if _name(parser) == "t": reading = false
			elif _name(parser) == "si": _shared.append(current)

func _read_rows(path: String) -> Dictionary:
	var parser := _xml(path)
	if parser == null: return {}
	var rows := {}
	var cell_ref := ""
	var cell_type := ""
	var value := ""
	var reading := false
	while parser.read() == OK:
		var kind := parser.get_node_type()
		if kind == XMLParser.NODE_ELEMENT:
			match _name(parser):
				"c":
					var attr := _attrs(parser)
					cell_ref = attr.get("r", "")
					cell_type = attr.get("t", "")
					value = ""
					if parser.is_empty(): cell_ref = ""
				"v", "t": reading = not parser.is_empty() and not cell_ref.is_empty()
				"f": pass
		elif kind == XMLParser.NODE_TEXT and reading: value += parser.get_node_data()
		elif kind == XMLParser.NODE_ELEMENT_END:
			match _name(parser):
				"v", "t": reading = false
				"c":
					if cell_ref.is_empty(): continue
					var column := ""
					var number := ""
					for ch in cell_ref:
						if ch >= "0" and ch <= "9": number += ch
						else: column += ch
					if number.is_empty(): continue
					if cell_type == "s" and value.is_valid_int() and int(value) >= 0 and int(value) < _shared.size(): value = _shared[int(value)]
					if not rows.has(int(number)): rows[int(number)] = {}
					rows[int(number)][column] = value
					cell_ref = ""
	return rows

func _find_header(rows: Dictionary, aliases: Array[String]) -> int:
	var keys: Array = rows.keys()
	keys.sort()
	for number in keys:
		var row: Dictionary = rows[number]
		for value in row.values():
			if str(value) in aliases: return int(number)
	return 1

func _table(rows: Dictionary, aliases: Dictionary) -> Array:
	var all_aliases: Array[String] = []
	for values in aliases.values(): all_aliases.append_array(values)
	var header_row := _find_header(rows, all_aliases)
	var headers: Dictionary = {}
	for column in rows.get(header_row, {}): headers[str(rows[header_row][column]).strip_edges()] = column
	var result: Array = []
	var numbers: Array = rows.keys()
	numbers.sort()
	for number in numbers:
		if int(number) <= header_row: continue
		var source: Dictionary = rows[number]
		var record := {}
		var nonempty := false
		for key in aliases:
			var value := ""
			for alias in aliases[key]:
				if headers.has(alias): value = str(source.get(headers[alias], "")).strip_edges(); break
			record[key] = value
			if not value.is_empty(): nonempty = true
		if not nonempty: continue
		var enabled := str(record.get("enabled", "true")).to_lower()
		if enabled in ["false", "0", "否", "no"]: continue
		result.append(record)
	return result

func _dict(rows: Array, id_key: String) -> Dictionary:
	var result := {}
	for row in rows:
		var id := str(row.get(id_key, "")).strip_edges()
		if id.is_empty(): continue
		if result.has(id): errors.append("文案ID重复：" + id)
		else: result[id] = row.duplicate(true)
	return result

func _aliases(keys: Array[String]) -> Dictionary:
	var result := {}
	for key in keys: result[key] = [key]
	return result

func _compile(raw: Dictionary) -> Dictionary:
	var text_rows := _table(_sheet(raw, ["脚本文本", "文本", "Script", "脚本"]), {
		"enabled":["enabled", "启用"], "text_id":["文本ID", "text_id", "文本id"], "text":["文本内容", "正文", "文本", "text"],
		"speaker_name":["人物名", "角色名", "speaker_name"], "character_id":["人物id", "人物ID", "角色ID", "character_id"],
		"avatar_path":["人物美术资源路径", "立绘路径", "avatar_path"], "position":["人物位置", "位置", "position"], "avatar_id":["头像ID", "avatar_id"],
		"text_type":["文本类型", "类型", "text_type"], "read_version":["已读判定", "已读版本", "read_version"],
		"chapter_id":["章节id", "章节ID", "chapter_id"], "chapter_name":["章节名称", "chapter_name"], "scene_id":["场景id", "场景ID", "scene_id"],
		"scene_name":["场景名称", "scene_name"], "scene_description":["场景描述", "scene_description"], "background_path":["场景美术资源路径", "背景路径", "background_path"],
		"reference_image":["参考图", "reference_image"], "next_text_id":["下一文本ID", "next_text_id"], "is_default_start":["默认起始", "是否起始", "is_default_start"]})
	var transition_rows := _table(_sheet(raw, ["文本跳转", "跳转", "Transitions"]), {
		"enabled":["enabled", "启用"], "transition_id":["跳转ID", "transition_id"], "source_text_id":["源文本ID", "source_text_id"],
		"source_event_id":["源事件ID", "source_event_id"], "source_chapter_id":["源章节ID", "source_chapter_id"], "order":["顺序", "order"],
		"transition_type":["跳转类型", "transition_type"], "choice_text":["选项文本", "选项条件", "choice_text"], "condition":["跳转条件", "condition"],
		"enabled_condition":["启用条件", "enabled_condition"], "return_state_id":["返回目标状态ID", "return_state_id"],
		"target_text_id":["目标文本ID", "target_text_id"], "target_event_id":["目标事件ID", "target_event_id"], "dynamic_state_id":["动态目标状态ID", "dynamic_state_id"],
		"fixed_state_id":["固定目标状态ID", "fixed_state_id"], "ends":["结束", "ends"]})
	var chapters := _dict(_table(_sheet(raw, ["章节字典", "章节", "Chapters"]), {"chapter_id":["章节id", "章节ID", "chapter_id"], "name":["章节名称", "名称", "name"], "description":["章节描述", "description"]}), "chapter_id")
	var characters := _dict(_table(_sheet(raw, ["人物字典", "人物", "Characters"]), {"character_id":["人物id", "人物ID", "character_id"], "name":["人物名", "人物名称", "name"], "avatar_path":["人物美术资源路径", "立绘路径", "avatar_path"]}), "character_id")
	var scenes := _dict(_table(_sheet(raw, ["剧情场景字典", "场景字典", "场景", "Scenes"]), {"scene_id":["场景id", "场景ID", "scene_id"], "name":["场景名称", "名称", "name"], "description":["场景描述", "description"], "background_path":["场景美术资源路径", "背景路径", "background_path"]}), "scene_id")
	var locations := _dict(_table(_sheet(raw, ["实体场地字典", "场地字典", "Locations"]), {"location_id":["场地id", "场地ID", "location_id"], "name":["场地名称", "名称", "name"]}), "location_id")
	var backgrounds := _dict(_table(_sheet(raw, ["背景字典", "背景", "Backgrounds"]), {"background_id":["背景id", "背景ID", "background_id"], "name":["背景名称", "名称", "name"], "image":["资源路径", "PNG资源路径", "image"]}), "background_id")
	var state_rows := _table(_sheet(raw, ["状态字典", "状态", "States"]), {"state_id":["状态id", "状态ID", "state_id"], "name":["状态名称", "名称", "name"], "default_value":["默认值", "default_value"]})
	var state_values := _dict(_table(_sheet(raw, ["状态取值", "状态值", "StateValues"]), {"value_id":["取值id", "取值ID", "value_id"], "state_id":["状态id", "状态ID", "state_id"], "value":["取值", "value"], "name":["取值名称", "名称", "name"]}), "value_id")
	var events := _dict(_table(_sheet(raw, ["事件字典", "事件", "Events"]), {"event_id":["id", "事件id", "事件ID", "event_id"], "name":["事件名称", "名称", "name"], "event_type":["事件类型", "event_type"], "chapter_id":["章节id", "章节ID", "chapter_id"], "content":["事件内容", "内容", "content"]}), "event_id")
	var performance := _table(_sheet(raw, ["跳转演出关联", "演出关联", "Performances"]), {"performance_id":["关联ID", "演出ID", "performance_id"], "transition_id":["跳转ID", "transition_id"], "order":["演出顺序", "顺序", "order"], "event_id":["事件id", "事件ID", "event_id"]})
	var data := {"texts":{}, "chapters":chapters, "characters":characters, "scenes":scenes, "locations":locations, "backgrounds":backgrounds,
		"scene_links":{}, "scene_background_links":{}, "states":_dict(state_rows, "state_id"), "state_values":state_values, "events":events, "performance_events":{}, "transitions":{}}
	for row in text_rows:
		var id := str(row.get("text_id", ""))
		if id.is_empty() or str(row.get("text", "")).is_empty():
			errors.append("脚本文本缺少文本ID或正文")
			continue
		row["read_version"] = maxi(1, int(str(row.get("read_version", "1")) if str(row.get("read_version", "1")).is_valid_int() else "1"))
		row["is_default_start"] = str(row.get("is_default_start", "")).to_lower() in ["true", "1", "是", "yes"]
		data.texts[id] = row
	for row in transition_rows:
		var id := str(row.get("transition_id", ""))
		if id.is_empty(): id = "transition_%d" % data.transitions.size()
		row["order"] = int(str(row.get("order", "0")) if str(row.get("order", "0")).is_valid_int() else "0")
		row["ends"] = str(row.get("ends", "")).to_lower() in ["true", "1", "是", "yes"] or row.get("transition_type") in ["当前事件结束", "终局结束"]
		data.transitions[id] = row
	for row in performance:
		var id := str(row.get("performance_id", ""))
		if id.is_empty(): id = "performance_%d" % data.performance_events.size()
		data.performance_events[id] = row
	if data.texts.is_empty(): errors.append("文案配置缺少脚本文本工作表或有效文本")
	return {} if not errors.is_empty() else data

func _sheet(raw: Dictionary, names: Array[String]) -> Dictionary:
	for name in names:
		if raw.has(name): return raw[name]
	for actual in raw:
		for name in names:
			if str(actual).contains(name): return raw[actual]
	return {}
