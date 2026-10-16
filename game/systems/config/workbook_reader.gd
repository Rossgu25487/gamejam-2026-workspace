extends RefCounted
## 通用只读工作簿入口。按表头声明转换类型，ID不按内容猜测数字；公式和错误单元格拒绝进入运行态。
const XMLReader = preload("res://features/cat_interaction/cat_workbook_loader.gd")
var errors: Array[String] = []
var tables := {}
var source_path := ""

func open(path: String) -> bool:
	errors.clear()
	tables.clear()
	source_path = path
	var reader := XMLReader.new()
	reader._zip = ZIPReader.new()
	if reader._zip.open(path) != OK:
		errors.append("无法打开配置表：" + path)
		return false
	if reader._zip.file_exists("xl/sharedStrings.xml"): reader._read_shared_strings()
	var paths: Dictionary = reader._sheet_paths()
	for name in paths:
		tables[name] = reader._sheet_cells(paths[name])
	reader._zip.close()
	errors.append_array(reader.errors)
	return errors.is_empty()

func records(sheet: String, scope: String = "runtime", header_row: int = 0) -> Array:
	if not tables.has(sheet):
		errors.append("缺少工作表：%s / %s" % [source_path, sheet])
		return []
	return read_records(tables[sheet], sheet, scope, header_row)

func read_records(rows: Dictionary, sheet: String, scope: String = "runtime", header_row: int = 0) -> Array:
	var four_rows := false
	if header_row == 0:
		header_row = 1
		# 接受 ##var 和调查表的 ##，但只在英文字段行伴随第4行分组时使用四行结构。
		if str(rows.get(2, {}).get("A", {}).get("value", "")).begins_with("##"):
			header_row = 2
			four_rows = true
	var headers: Dictionary = rows.get(header_row, {})
	var start := 5 if four_rows else header_row + 1
	var result: Array = []
	var numbers: Array = rows.keys()
	numbers.sort()
	for number in numbers:
		if int(number) < start: continue
		var cells: Dictionary = rows[number]
		var marker := str(cells.get("A", {}).get("value", "")) if four_rows else ""
		var row_scope := ""
		var enabled := true
		for column in headers:
			var field := str(headers[column].get("value", ""))
			var value := str(cells.get(column, {}).get("value", ""))
			if field == "data_scope": row_scope = value
			if field == "enabled" and value.to_lower() in ["0", "false"]: enabled = false
		if not enabled or (not row_scope.is_empty() and row_scope != scope and not (scope == "test" and row_scope == "runtime")): continue
		if marker.begins_with("#") and not (scope == "test" and row_scope == "test") and scope != "legacy_map": continue
		var record := {}
		var nonempty := false
		for column in headers:
			var field := str(headers[column].get("value", "")).strip_edges()
			if field.is_empty() or field.begins_with("#") or (four_rows and column == "A"): continue
			var cell: Dictionary = cells.get(column, {})
			var value := str(cell.get("value", ""))
			var where := "%s / %s 第%d行 %s" % [source_path, sheet, number, field]
			if cell.get("formula", false) or cell.get("error", false): errors.append(where + "：不能使用公式或错误单元格")
			if not value.is_empty(): nonempty = true
			var type := str(rows.get(3, {}).get(column, {}).get("value", "string")).split("#")[0].split("/")[0].strip_edges().trim_suffix("!").trim_suffix("?") if four_rows else "string"
			record[field] = _convert(value, type, where)
		if nonempty:
			if four_rows:
				for column in headers:
					var field := str(headers[column].get("value", ""))
					if not record.has(field): continue
					var declaration := str(rows.get(3, {}).get(column, {}).get("value", ""))
					if ("!" in declaration or "必填" in declaration) and str(record[field]).is_empty(): errors.append("%s / %s 第%d行 %s：必填项为空" % [source_path, sheet, number, field])
			result.append(record)
	return result

func _convert(value: String, type: String, where: String):
	if value.is_empty(): return ""
	match type:
		"bool":
			if value.to_lower() not in ["0", "1", "false", "true"]: errors.append(where + "：布尔值应为0/1或true/false")
			return value.to_lower() in ["1", "true"]
		"int", "long", "float", "double":
			if not value.is_valid_float() or not is_finite(float(value)):
				errors.append(where + "：数值无效")
				return 0
			if type in ["int", "long"]:
				if floor(float(value)) != float(value): errors.append(where + "：整数不能有小数")
				return int(float(value))
			return float(value)
	return value
