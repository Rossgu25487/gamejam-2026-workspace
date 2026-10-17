extends Node
## 存读档服务：保存完整会话快照，调查存档不覆盖设置偏好。

signal scan_completed(records: Array) # 扫描完成后返回有效存档列表。
signal operation_completed(success: bool, message: String) # 保存或读取结果。
signal processing_changed(active: bool) # 会话以此排除实际文件处理耗时。

const MANUAL_SLOT_COUNT := 3 # 玩家可见的手动存档栏位。
const AUTO_SLOT_COUNT := 1 # 普通自动档固定只有一个栏位。
const PRE_ACCUSATION_SLOT_COUNT := 1 # 指认前保护档栏位。
const SCHEMA_VERSION := 1 # 存档容器格式版本。
const DIR_PATH := "user://saves" # 存档文件目录，不依赖工程绝对路径。
var records: Array = [] # 最近一次扫描得到的有效记录。
var sequence := 0 # 全部栏位共用的成功保存序号。
var storage_path := DIR_PATH # 测试可注入隔离目录，运行默认使用玩家目录。
var snapshot_validator: Callable # 会话模块提供完整性验证，读取前拒绝损坏快照。
var busy := false # 文件事务及其完成回调期间拒绝重入，不排队。
var manual_slot_count := MANUAL_SLOT_COUNT

func configure(row: Dictionary) -> bool:
	# 格式与保护记录数量是存档协议；手动栏数量允许策划在1—10内调整。
	for key in ["auto_slot_count", "pre_accusation_slot_count", "ending_resume_record_count", "save_schema_version"]:
		if int(row.get(key, -1)) != 1: return false
	var count = row.get("manual_slot_count", 0)
	if not (count is int or count is float) or count < 1 or count > 10 or floor(float(count)) != float(count): return false
	manual_slot_count = int(count)
	return true

func scan() -> Array:
	# 按固定栏位读取磁盘文件，并恢复本次运行的序号基线。
	records.clear()
	for kind in ["manual", "auto", "pre_accusation", "ending_resume"]:
		var count := manual_slot_count if kind == "manual" else (AUTO_SLOT_COUNT if kind == "auto" else PRE_ACCUSATION_SLOT_COUNT)
		for index in range(count):
			var path := _path(kind, index)
			if not FileAccess.file_exists(path): continue
			var file := FileAccess.open(path, FileAccess.READ)
			var data = JSON.parse_string(file.get_as_text()) if file else null
			if _valid_record(data, kind, index):
				sequence = maxi(sequence, int(data.get("save_sequence", 0)))
				if kind != "ending_resume" or data.get("ending_status") == "active": records.append(data)
	scan_completed.emit(records.duplicate(true))
	return records.duplicate(true)

func has_valid_record() -> bool:
	# 快速判断最近一次扫描是否发现有效存档。
	return not records.is_empty()

func save_snapshot(slot_kind: String, slot_index: int, snapshot: Dictionary) -> bool:
	if busy: return false
	busy = true
	processing_changed.emit(true)
	var success := _write_snapshot(slot_kind, slot_index, snapshot)
	busy = false
	processing_changed.emit(false)
	return success

func _write_snapshot(slot_kind: String, slot_index: int, snapshot: Dictionary) -> bool:
	# 将完整快照写入指定栏位；只有文件写入成功才提交新序号。
	if not _valid_slot(slot_kind, slot_index):
		operation_completed.emit(false, "存档栏位无效")
		return false
	if snapshot_validator.is_valid() and not snapshot_validator.call(snapshot):
		operation_completed.emit(false, "快照不完整，未覆盖存档")
		return false
	if sequence == 0: scan()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(storage_path))
	var path := _path(slot_kind, slot_index)
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		operation_completed.emit(false, "存档写入失败")
		return false
	# 序号只在写入成功后提交；同一服务实例启动时先从磁盘最大序号继续。
	var next_sequence := sequence + 1
	var record := snapshot.duplicate(true)
	# 强制写入本次目标栏位的元数据，避免从自动档恢复后手动保存仍被标记为 auto。
	record.merge({"schema_version": SCHEMA_VERSION, "slot_kind": slot_kind, "slot_index": slot_index, "save_sequence": next_sequence, "saved_at_utc": Time.get_datetime_string_from_system(true)}, true)
	file.store_string(JSON.stringify(record))
	file.flush()
	var write_error := file.get_error()
	file.close()
	# 先重读临时文件确认完整有效，再原子替换旧栏位；失败不提交序号。
	var verified = JSON.parse_string(FileAccess.get_file_as_string(temporary))
	if write_error != OK or not _valid_record(verified, slot_kind, slot_index) or DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path)) != OK:
		operation_completed.emit(false, "存档写入失败，原存档已保留")
		return false
	sequence = next_sequence
	operation_completed.emit(true, "存档成功")
	return true

func save_auto(snapshot: Dictionary) -> bool:
	# 普通自动档固定写入唯一自动栏，不占用手动存档栏位。
	return save_snapshot("auto", 0, snapshot)

func save_ending(snapshot: Dictionary) -> bool:
	# 续播独立于auto/pre和手动栏，只有active记录参与“继续”。
	if snapshot.get("ending_status") not in ["active", "completed", "abandoned"]: return false
	return save_snapshot("ending_resume", 0, snapshot)

func abandon_ending() -> void:
	var info := slot_info("ending_resume", 0)
	if not info.valid: return
	var record := load_snapshot("ending_resume", 0)
	if record.get("ending_status") != "active": return
	record.ending_status = "abandoned"
	save_ending(record)

func clear_previous_run_protection(run_id: String) -> void:
	# 只清理已确认属于上一调查的固定保护；手动栏永远保留。
	for kind in ["pre_accusation", "ending_resume"]:
		var path := _path(kind, 0)
		if not FileAccess.file_exists(path): continue
		var file := FileAccess.open(path, FileAccess.READ)
		var record = JSON.parse_string(file.get_as_text()) if file else null
		if file != null: file.close()
		var previous := str(record.get("run_id", record.get("card_snapshot", {}).get("run_id", ""))) if record is Dictionary else ""
		if not previous.is_empty() and previous != run_id: DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func load_snapshot(slot_kind: String, slot_index: int) -> Dictionary:
	if busy: return {}
	busy = true
	processing_changed.emit(true)
	var result := _read_snapshot(slot_kind, slot_index)
	busy = false
	processing_changed.emit(false)
	return result

func _read_snapshot(slot_kind: String, slot_index: int) -> Dictionary:
	# 按栏位读取并校验格式；失败时不替换当前会话。
	if not _valid_slot(slot_kind, slot_index):
		operation_completed.emit(false, "存档栏位无效")
		return {}
	var file := FileAccess.open(_path(slot_kind, slot_index), FileAccess.READ)
	if file == null:
		operation_completed.emit(false, "读取存档失败，当前会话已保留")
		return {}
	var data = JSON.parse_string(file.get_as_text())
	if not _valid_record(data, slot_kind, slot_index):
		operation_completed.emit(false, "存档版本不受支持，当前会话已保留")
		return {}
	operation_completed.emit(true, "读取存档成功")
	return data

func slot_info(kind: String, index: int) -> Dictionary:
	# 固定栏位始终显示；无效档也保留身份和实际原因，不用当前调查冒充摘要。
	var result := {"slot_kind": kind, "slot_index": index, "exists": false, "valid": false, "summary": "空栏位", "reason": ""}
	if not _valid_slot(kind, index): return result
	var path := _path(kind, index)
	if not FileAccess.file_exists(path): return result
	result.exists = true
	var file := FileAccess.open(path, FileAccess.READ)
	var record = JSON.parse_string(file.get_as_text()) if file else null
	if not _valid_record(record, kind, index):
		result.reason = "存档损坏、版本不支持或必要内容无效"
		result.summary = result.reason
		return result
	result.valid = true
	result.merge(_record_presentation(record), true)
	return result

func _record_presentation(record: Dictionary) -> Dictionary:
	# 只格式化档案里已冻结的数据，旧档缺值保持空；序号仍是排序唯一依据。
	var progress: Dictionary = record.get("progress_summary", {})
	var scene := str(progress.get("scene", ""))
	var phase := str(progress.get("phase", ""))
	var question := str(progress.get("question", ""))
	var duration := ""
	var seconds = record.get("elapsed_seconds")
	if (seconds is int or seconds is float) and is_finite(float(seconds)) and seconds >= 0:
		var whole := int(seconds)
		duration = "%02d:%02d:%02d" % [whole / 3600, (whole / 60) % 60, whole % 60]
	var saved_time := _local_saved_time(str(record.get("saved_at_utc", "")))
	var short_parts: Array[String] = []
	var full_parts: Array[String] = []
	for pair in [["场景", scene, 12], ["阶段", phase, 12], ["问题", question, 14], ["累计时长", duration, 0], ["保存时间", saved_time, 0]]:
		if str(pair[1]).is_empty(): continue
		short_parts.append(_short_text(str(pair[1]), int(pair[2])))
		full_parts.append("%s：%s" % [pair[0], pair[1]])
	var sequence_text := "保存序号 %d" % int(record.save_sequence)
	short_parts.append(sequence_text)
	full_parts.append(sequence_text)
	return {"summary": " · ".join(short_parts), "full_summary": "\n".join(full_parts), "scene": scene, "phase": phase, "question": question, "elapsed": duration, "saved_time": saved_time}

func _short_text(value: String, limit: int) -> String:
	if limit <= 0: return value
	var breaks := TextServerManager.get_primary_interface().string_get_character_breaks(value)
	return value if breaks.size() <= limit else value.substr(0, breaks[limit - 2]) + "…"

func _local_saved_time(value: String) -> String:
	if value.length() < 19: return ""
	var utc := Time.get_unix_time_from_datetime_string(value)
	if utc <= 0: return ""
	var local := Time.get_datetime_dict_from_unix_time(utc + int(Time.get_time_zone_from_system().bias) * 60)
	return "%04d.%02d.%02d %02d:%02d" % [local.year, local.month, local.day, local.hour, local.minute]

func slot_label(kind: String, index: int) -> String:
	return "手动存档 %d" % (index + 1) if kind == "manual" else ("自动存档" if kind == "auto" else "指认前")

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
	var kind_text: String = str({"manual": "手动存档", "auto": "自动存档", "ending_resume": "结局续播", "pre_accusation": "指认前"}.get(kind, "存档"))
	return "最新保存：%s %d（保存序号 %d）" % [kind_text, index, int(record.get("save_sequence", 0))]

func _valid_slot(kind: String, index: int) -> bool:
	# 约束栏位类型和编号，防止写入未知位置。
	return (kind == "manual" and index >= 0 and index < manual_slot_count) or (kind in ["auto", "pre_accusation", "ending_resume"] and index == 0)

func _path(kind: String, index: int) -> String:
	# 将逻辑栏位映射到 user:// 下的实际文件名。
	return "%s/%s_%d.json" % [storage_path, kind, index]

func _valid_record(data, kind: String, index: int) -> bool:
	if not data is Dictionary: return false
	# JSON 数字读取为浮点；拒绝数组、字符串、小数及非有限值后再转换。
	for key in ["schema_version", "slot_index", "save_sequence"]:
		var number = data.get(key)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floor(float(number)): return false
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION: return false
	if data.get("slot_kind") != kind or int(data.get("slot_index", -1)) != index or int(data.get("save_sequence", 0)) < 1: return false
	return not snapshot_validator.is_valid() or snapshot_validator.call(data)
