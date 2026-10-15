extends Node
## 游戏设置服务：设置文件独立于调查存档，负责读取、即时生效和写回。

signal initialized(success: bool, message: String) # 初始化结果和提示文字。
signal changed(settings: Dictionary) # 设置值发生变化。
signal persistence_failed(message: String) # 文件写入失败。
signal persistence_changed # 写入锁、未保存及错误变化，页面只消费公开状态。

const FILE_PATH := "user://game_settings.json"
const FILE_VERSION := 1
const DEFAULTS := { # 首次建立和恢复默认使用的设置初值。
	"master_volume": 100,
	"bgm_volume": 70,
	"ambient_volume": 60,
	"effect_volume": 80,
	"mute": false,
	"reduce_motion": false,
}
const VOLUME_STEP := 5 # 键盘或步进操作的音量变化幅度。
var values: Dictionary = DEFAULTS.duplicate(true) # 当前运行中的设置值。
var initialized_ok := false # 是否完成初始化流程。
var storage_path := FILE_PATH # 回归测试独立设置文件，不改写玩家偏好。
var busy := false
var unsaved := false
var last_error := ""

func initialize() -> void:
	# 读取独立设置文件；文件不存在或版本无效时回退到默认值。
	if initialized_ok or busy: return
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		values = DEFAULTS.duplicate(true)
		initialized_ok = true
		_apply_audio()
		initialized.emit(true, "已建立默认设置")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not _valid_file(parsed):
		values = DEFAULTS.duplicate(true)
		initialized_ok = true
		last_error = "设置文件无效，已使用默认设置；重新提交前保留原文件"
		unsaved = true
		_apply_audio()
		initialized.emit(false, "设置文件无效，已使用默认设置")
		return
	values = DEFAULTS.duplicate(true)
	for key in DEFAULTS.keys():
		if parsed.has(key): values[key] = parsed[key]
	_sanitize()
	initialized_ok = true
	_apply_audio()
	initialized.emit(true, "设置读取完成")

func get_value(key: String, fallback = null):
	# 页面读取单项设置时使用的只读接口。
	return values.get(key, fallback)

func set_value(key: String, value, persist: bool = true) -> bool:
	# 拖动期间只应用；鼠标／键盘结束调整后再整体提交六项偏好。
	if busy or not initialized_ok or not DEFAULTS.has(key): return false
	if key in ["mute", "reduce_motion"] and not value is bool: return false
	if key not in ["mute", "reduce_motion"] and not (value is int or value is float): return false
	if value is float and not is_finite(value): return false
	values[key] = value
	_sanitize()
	unsaved = true
	_apply_audio()
	changed.emit(values.duplicate(true))
	persistence_changed.emit()
	return save() if persist else true

func restore_defaults() -> bool:
	# 恢复设置初值，但不改变配置中的音量步长。
	if busy or not initialized_ok: return false
	values = DEFAULTS.duplicate(true)
	unsaved = true
	_apply_audio()
	changed.emit(values.duplicate(true))
	return save()

func save() -> bool:
	# 处理锁涵盖信号回调，重复输入不排队；临时文件成功落盘才替换旧偏好。
	if busy or not initialized_ok: return false
	busy = true
	persistence_changed.emit()
	var temporary := storage_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _finish_save(false, "无法写入设置文件（%s）" % error_string(FileAccess.get_open_error()))
	var data := {"version": FILE_VERSION}
	data.merge(values)
	file.store_string(JSON.stringify(data))
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(storage_path))
	return _finish_save(error == OK, "无法保存设置，原文件已保留（%s）" % error_string(error))

func _finish_save(success: bool, message: String) -> bool:
	unsaved = not success
	last_error = "" if success else message
	if not success: persistence_failed.emit(last_error)
	busy = false
	persistence_changed.emit()
	return success

func _valid_file(data) -> bool:
	# 损坏字段不能强转成看似有效的0或开关，也不能在读取时覆盖原文件。
	if not data is Dictionary or data.get("version") != FILE_VERSION: return false
	for key in DEFAULTS:
		var value = data.get(key)
		if DEFAULTS[key] is bool:
			if not value is bool: return false
		elif not (value is int or value is float) or not is_finite(float(value)) or float(value) != floor(float(value)) or value < 0 or value > 100:
			return false
	return true

func _sanitize() -> void:
	# 限制音量范围并确保开关字段保持布尔类型。
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		values[key] = clampi(int(values.get(key, DEFAULTS[key])), 0, 100)
	values["mute"] = bool(values.get("mute", false))
	values["reduce_motion"] = bool(values.get("reduce_motion", false))

func _apply_audio() -> void:
	# 将总音量和静音状态即时应用到 Godot 音频总线。
	var master := 0.0 if values.mute else float(values.master_volume) / 100.0
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, 0.0001)))
