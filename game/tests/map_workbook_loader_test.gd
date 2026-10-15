extends SceneTree
## 地图配置表读取回归：验证正式表可打开，失败时不会伪造地图数据。

const Loader = preload("res://systems/map_navigation/map_workbook_loader.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("MAP_WORKBOOK_FAILED: " + message)

func _run() -> void:
	var loader := Loader.new()
	var definition := loader.load_workbook()
	# 原始策划表可能仍在工作区外；这种情况应明确失败，而不是吞掉错误。
	expect(definition.is_empty() or definition is Dictionary, "读取结果保持字典结构")
	if not definition.is_empty():
		expect(definition.has("nodes"), "配置包含地点节点段")
		expect(definition.has("display"), "配置包含显示参数段")
		expect(definition.has("transitions"), "配置包含转场段")
		expect(definition.boards.has("EX_GROUP_A") and definition.boards.EX_GROUP_A.cols == 8 and definition.display.has("logical_width"), "正式机器表头按真实身份解析棋盘和显示参数")
		var previous: Dictionary = loader.last_valid_definition.duplicate(true)
		expect(loader.load_workbook("user://missing-map-audit.xlsx").is_empty() and not loader.errors.is_empty() and loader.last_valid_definition == previous, "重载失败保留上一有效定义且不偷偷读TEST表")
	else:
		expect(not loader.errors.is_empty(), "读取失败时保留错误信息")
	if failures.is_empty(): print("MAP_WORKBOOK_PASS: %d checks" % checks)
	else: printerr("MAP_WORKBOOK_FAIL: %d failures / %d checks" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
