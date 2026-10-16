extends RefCounted
## 调查配置独立读取；runtime 进入游戏，test 只有显式联调调用才采用。
const Reader = preload("res://systems/config/workbook_reader.gd")
const DEFAULT_PATH := "res://代码开发需求/调查与场景交互系统/调查与场景交互系统配置表.xlsx"
var errors: Array[String] = []

func load_workbook(path: String = DEFAULT_PATH, scope: String = "runtime") -> Dictionary:
	var reader := Reader.new()
	if not reader.open(path):
		errors.assign(["无法打开调查配置表：" + path])
		return {}
	var sheets: Dictionary = reader.tables
	var result := {"display": {}, "hotspots": [], "observations": [], "bindings": [], "topics": [], "object_images": []}
	var sections := {"热点映射": "hotspots", "观察引用": "observations", "入口绑定": "bindings", "话题展示例": "topics", "对象图片": "object_images"}
	for name in sheets:
		if name != "显示参数" and not sections.has(name): continue
		for row in reader.records(name, scope):
			if row.get("data_scope", "") != scope: continue
			if name == "显示参数": result.display = row.duplicate(true)
			else:
				var copy: Dictionary = row.duplicate(true)
				copy.data_scope = "runtime" # 显式测试调用隔离后走同一验证契约。
				result[sections[name]].append(copy)
	errors.assign(reader.errors)
	return {} if not errors.is_empty() else result
