extends Node
## 存读档服务：保存完整会话快照，调查存档不覆盖设置偏好。

signal scan_completed(records: Array)
signal operation_completed(success: bool, message: String)

const MANUAL_SLOT_COUNT := 3
const AUTO_SLOT_COUNT := 1
const PRE_ACCUSATION_SLOT_COUNT := 1
const SCHEMA_VERSION := 1
const DIR_PATH := "user://saves"
var records: Array = []
var sequence := 0

func scan() -> Array:
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
	scan_completed.emit(records.duplicate(true))
	return records.duplicate(true)

func has_valid_record() -> bool:
	return not records.is_empty()

func save_snapshot(slot_kind: String, slot_index: int, snapshot: Dictionary) -> bool:
	if not _valid_slot(slot_kind, slot_index):
		operation_completed.emit(false, "存档栏位无效")
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR_PATH))
	var path := _path(slot_kind, slot_index)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		operation_completed.emit(false, "存档写入失败")
		return false
	sequence += 1
	var record := snapshot.duplicate(true)
	record.merge({"schema_version": SCHEMA_VERSION, "slot_kind": slot_kind, "slot_index": slot_index, "save_sequence": sequence, "saved_at_utc": Time.get_datetime_string_from_system(true)})
	file.store_string(JSON.stringify(record))
	operation_completed.emit(true, "存档成功")
	return true

func save_auto(snapshot: Dictionary) -> bool:
	# 普通自动档固定写入唯一自动栏，不占用手动存档栏位。
	return save_snapshot("auto", 0, snapshot)

func load_snapshot(slot_kind: String, slot_index: int) -> Dictionary:
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

func _valid_slot(kind: String, index: int) -> bool:
	return (kind == "manual" and index >= 0 and index < MANUAL_SLOT_COUNT) or (kind == "auto" and index == 0) or (kind == "pre_accusation" and index == 0)

func _path(kind: String, index: int) -> String:
	return "%s/%s_%d.json" % [DIR_PATH, kind, index]
