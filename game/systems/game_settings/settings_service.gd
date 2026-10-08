extends Node
## 游戏设置服务：设置文件独立于调查存档，负责读取、即时生效和写回。

signal initialized(success: bool, message: String)
signal changed(settings: Dictionary)
signal persistence_failed(message: String)

const FILE_PATH := "user://game_settings.json"
const FILE_VERSION := 1
const DEFAULTS := {
	"master_volume": 100,
	"bgm_volume": 70,
	"ambient_volume": 60,
	"effect_volume": 80,
	"mute": false,
	"reduce_motion": false,
}
const VOLUME_STEP := 5
var values: Dictionary = DEFAULTS.duplicate(true)
var initialized_ok := false

func initialize() -> void:
	var file := FileAccess.open(FILE_PATH, FileAccess.READ)
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
	return values.get(key, fallback)

func set_value(key: String, value) -> bool:
	if not DEFAULTS.has(key): return false
	values[key] = value
	_sanitize()
	_apply_audio()
	changed.emit(values.duplicate(true))
	return save()

func restore_defaults() -> bool:
	values = DEFAULTS.duplicate(true)
	_apply_audio()
	changed.emit(values.duplicate(true))
	return save()

func save() -> bool:
	var file := FileAccess.open(FILE_PATH, FileAccess.WRITE)
	if file == null:
		persistence_failed.emit("无法写入设置文件")
		return false
	var data := {"version": FILE_VERSION}
	data.merge(values)
	file.store_string(JSON.stringify(data))
	return true

func _sanitize() -> void:
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		values[key] = clampi(int(values.get(key, DEFAULTS[key])), 0, 100)
	values["mute"] = bool(values.get("mute", false))
	values["reduce_motion"] = bool(values.get("reduce_motion", false))

func _apply_audio() -> void:
	var master := 0.0 if values.mute else float(values.master_volume) / 100.0
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, 0.0001)))
