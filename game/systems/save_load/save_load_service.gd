extends Node
## 存读档服务：保存完整会话快照，调查存档不覆盖设置偏好。

signal scan_completed(records: Array) # 扫描完成后返回有效存档列表。
signal operation_completed(success: bool, message: String) # 保存或读取结果。

const MANUAL_SLOT_COUNT := 3 # 玩家可见的手动存档栏位。
const AUTO_SLOT_COUNT := 1 # 普通自动档固定只有一个栏位。
const PRE_ACCUSATION_SLOT_COUNT := 1 # 指认前保护档栏位。
const SCHEMA_VERSION := 1 # 存档容器格式版本。
const DIR_PATH := "user://saves" # 存档文件目录，不依赖工程绝对路径。
var records: Array = [] # 最近一次扫描得到的有效记录。
var sequence := 0 # 全部栏位共用的成功保存序号。

func scan() -> Array:
	# 按固定栏位读取磁盘文件，并恢复本次运行的序号基线。
	records.clear()
	for kind in ["manual", "auto", "pre_accusation"]:
		var count := MANUAL_SLOT_COUNT if kind == "manual" else (AUTO_SLOT_COUNT if kind == "auto" else PRE_ACCUSATION_SLOT_COUNT)
		for index in range(count):
			var path := _path(kind, index)
			if not FileAccess.file_exists(path): continue
			var file := FileAccess.open(path, FileAccess.READ)
			var data = JSON.parse_string(file.get_as_text()) if file else null
			if typeof(data) == TYPE_DICTIONARY and int(data.get("schema_version", -1)) == SCHEMA_VERSION:
				records.append(data)
				sequence = maxi(sequence, int(data.get("save_sequence", 0)))
	scan_completed.emit(records.duplicate(true))
	return records.duplicate(true)

func has_valid_record() -> bool:
	# 快速判断最近一次扫描是否发现有效存档。
	return not records.is_empty()

func save_snapshot(slot_kind: String, slot_index: int, snapshot: Dictionary) -> bool:
	# 将完整快照写入指定栏位；只有文件写入成功才提交新序号。
	if not _valid_slot(slot_kind, slot_index):
		operation_completed.emit(false, "存档栏位无效")
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR_PATH))
	var path := _path(slot_kind, slot_index)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		operation_completed.emit(false, "存档写入失败")
		return false
	# 序号只在写入成功后提交；同一服务实例启动时先从磁盘最大序号继续。
	if sequence == 0:
		scan()
	var next_sequence := sequence + 1
	var record := snapshot.duplicate(true)
	# 强制写入本次目标栏位的元数据，避免从自动档恢复后手动保存仍被标记为 auto。
	record.merge({"schema_version": SCHEMA_VERSION, "slot_kind": slot_kind, "slot_index": slot_index, "save_sequence": next_sequence, "saved_at_utc": Time.get_datetime_string_from_system(true)}, true)
	file.store_string(JSON.stringify(record))
	sequence = next_sequence
	operation_completed.emit(true, "存档成功")
	return true

func save_auto(snapshot: Dictionary) -> bool:
	# 普通自动档固定写入唯一自动栏，不占用手动存档栏位。
	return save_snapshot("auto", 0, snapshot)

func load_snapshot(slot_kind: String, slot_index: int) -> Dictionary:
	# 按栏位读取并校验格式；失败时不替换当前会话。
	if not _valid_slot(slot_kind, slot_index):
		operation_completed.emit(false, "存档栏位无效")
		return {}
	var file := FileAccess.open(_path(slot_kind, slot_index), FileAccess.READ)
	if file == null:
		operation_completed.emit(false, "读取存档失败，当前会话已保留")
		return {}
	var data = JSON.parse_string(file.get_as_text())
	if typeof(data) != TYPE_DICTIONARY or int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		operation_completed.emit(false, "存档版本不受支持，当前会话已保留")
		return {}
	operation_completed.emit(true, "读取存档成功")
	return data

func latest_record() -> Dictionary:
	# 从所有有效栏位中查找保存序号最大的记录。
	var all_records: Array = scan()
	var latest: Dictionary = {}
	for record in all_records:
		if latest.is_empty() or int(record.get("save_sequence", 0)) > int(latest.get("save_sequence", 0)):
			latest = record
	return latest.duplicate(true)

func load_latest() -> Dictionary:
	# 读取“继续游戏”应恢复的最新有效存档。
	var record := latest_record()
	if record.is_empty():
		operation_completed.emit(false, "没有可继续的有效存档")
		return {}
	return load_snapshot(str(record.get("slot_kind", "manual")), int(record.get("slot_index", 0)))

func latest_summary() -> String:
	# 生成标题页和离开确认页共用的最新存档摘要。
	var record := latest_record()
	if record.is_empty():
		return "当前没有已保存的存档。"
	var kind := str(record.get("slot_kind", "manual"))
	var index := int(record.get("slot_index", 0)) + 1
	var kind_text := "手动存档" if kind == "manual" else ("自动存档" if kind == "auto" else "保护存档")
	return "最新保存：%s %d（保存序号 %d）" % [kind_text, index, int(record.get("save_sequence", 0))]

func _valid_slot(kind: String, index: int) -> bool:
	# 约束栏位类型和编号，防止写入未知位置。
	return (kind == "manual" and index >= 0 and index < MANUAL_SLOT_COUNT) or (kind == "auto" and index == 0) or (kind == "pre_accusation" and index == 0)

func _path(kind: String, index: int) -> String:
	# 将逻辑栏位映射到 user:// 下的实际文件名。
	return "%s/%s_%d.json" % [DIR_PATH, kind, index]
