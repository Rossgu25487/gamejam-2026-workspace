extends Node
## 游戏设置服务：设置文件独立于调查存档，负责读取、即时生效和写回。

signal initialized(success: bool, message: String) # 初始化结果和提示文字。
signal changed(settings: Dictionary) # 设置值发生变化。
signal persistence_failed(message: String) # 文件写入失败。

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

func initialize() -> void:
	# 读取独立设置文件；文件不存在或版本无效时回退到默认值。
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		values = DEFAULTS.duplicate(true)
		initialized_ok = true
		_apply_audio()
		initialized.emit(true, "已建立默认设置")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("version", -1)) != FILE_VERSION:
		values = DEFAULTS.duplicate(true)
		initialized_ok = true
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

func set_value(key: String, value) -> bool:
	# 校验、应用并持久化单项设置。
	if not DEFAULTS.has(key): return false
	values[key] = value
	_sanitize()
	_apply_audio()
	changed.emit(values.duplicate(true))
	return save()

func restore_defaults() -> bool:
	# 恢复设置初值，但不改变配置中的音量步长。
	values = DEFAULTS.duplicate(true)
	_apply_audio()
	changed.emit(values.duplicate(true))
	return save()

func save() -> bool:
	# 将当前偏好写入独立 JSON 文件。
	var file := FileAccess.open(storage_path, FileAccess.WRITE)
	if file == null:
		persistence_failed.emit("无法写入设置文件")
		return false
	var data := {"version": FILE_VERSION}
	data.merge(values)
	file.store_string(JSON.stringify(data))
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
