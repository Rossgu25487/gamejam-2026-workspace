extends Node
## 游戏设置服务：设置文件独立于调查存档，负责读取、即时生效和写回。

signal initialized(success: bool, message: String) # 初始化结果和提示文字。
signal changed(settings: Dictionary) # 设置值发生变化。
signal persistence_failed(message: String) # 文件写入失败。
signal persistence_changed # 写入锁、未保存及错误变化，页面只消费公开状态。
signal display_changed(area: Rect2) # 页面、场景和热区共用的有效显示区域。

const FILE_PATH := "user://game_settings.json"
const FILE_VERSION := 2
const DEFAULTS := { # 首次建立和恢复默认使用的设置初值。
	"master_volume": 100,
	"bgm_volume": 70,
	"ambient_volume": 60,
	"effect_volume": 80,
	"mute": false,
	"reduce_motion": false,
	"display_mode": 1,
	"window_width": 1600,
	"window_height": 900,
	"aspect_ratio": 0,
	"brightness": 100,
	"text_speed": 2,
}
const VOLUME_STEP := 5 # 键盘或步进操作的音量变化幅度。
var values: Dictionary = DEFAULTS.duplicate(true) # 当前运行中的设置值。
var initialized_ok := false # 是否完成初始化流程。
var storage_path := FILE_PATH # 回归测试独立设置文件，不改写玩家偏好。
var busy := false
var unsaved := false
var last_error := ""
var defaults: Dictionary = DEFAULTS.duplicate(true)
var volume_step := VOLUME_STEP
var display_candidate: Dictionary = {}
var display_preview_active := false
var display_preview_seconds := 0.0
var preview_deadline_ms := 0
var display_restore_values: Dictionary = {}
var display_restore_candidate: Dictionary = {}
var display_restore_all := false
var runtime_display: Dictionary = {}
var display_adaptation_notice := ""
var apply_window_enabled := true
const DISPLAY_KEYS := ["display_mode", "window_width", "window_height", "aspect_ratio"]
const WINDOW_PRESETS := [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(1280, 800), Vector2i(1200, 900), Vector2i(1680, 720), Vector2i(1440, 900), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2100, 900), Vector2i(2520, 1080)]

func configure_defaults(row: Dictionary) -> bool:
	if initialized_ok: return false
	# 六项旧设置在历史工作簿中仍可用；最终设置表额外提供显示和文字速度字段。
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume", "mute", "reduce_motion"]:
		if not row.has(key): return false
		if DEFAULTS[key] is bool:
			if not row[key] is bool: return false
		elif not (row[key] is int or row[key] is float) or not is_finite(float(row[key])) or row[key] < 0 or row[key] > 100 or floor(float(row[key])) != float(row[key]): return false
	for key in ["display_mode", "window_width", "window_height", "aspect_ratio", "brightness", "text_speed"]:
		if not row.has(key): continue
		if not (row[key] is int or row[key] is float) or not is_finite(float(row[key])) or floor(float(row[key])) != float(row[key]): return false
	var mode := int(row.get("display_mode", DEFAULTS.display_mode))
	var width := int(row.get("window_width", DEFAULTS.window_width))
	var height := int(row.get("window_height", DEFAULTS.window_height))
	var ratio := int(row.get("aspect_ratio", DEFAULTS.aspect_ratio))
	var brightness := int(row.get("brightness", DEFAULTS.brightness))
	var text_speed := int(row.get("text_speed", DEFAULTS.text_speed))
	if mode not in [1, 2] or width < 320 or height < 240 or ratio < 0 or ratio > 4 or brightness < 50 or brightness > 150 or text_speed not in [1, 2, 3]: return false
	var step_value = row.get("volume_step", VOLUME_STEP)
	if not (step_value is int or step_value is float) or not is_finite(float(step_value)) or step_value < 1 or step_value > 100 or floor(float(step_value)) != float(step_value): return false
	defaults = DEFAULTS.duplicate(true)
	for key in DEFAULTS:
		if row.has(key): defaults[key] = row[key]
	volume_step = int(step_value)
	values = defaults.duplicate(true)
	return true

func initialize() -> void:
	# 读取独立设置文件；文件不存在或版本无效时回退到默认值。
	if initialized_ok or busy: return
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null:
		values = defaults.duplicate(true)
		initialized_ok = true
		_apply_audio()
		_initialize_display()
		initialized.emit(true, "已建立默认设置")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not _valid_file(parsed):
		values = defaults.duplicate(true)
		initialized_ok = true
		last_error = "设置文件无效，已使用默认设置；重新提交前保留原文件"
		unsaved = true
		_apply_audio()
		_initialize_display()
		initialized.emit(false, "设置文件无效，已使用默认设置")
		return
	values = defaults.duplicate(true)
	for key in DEFAULTS.keys():
		if parsed.has(key): values[key] = parsed[key]
	_sanitize()
	initialized_ok = true
	_apply_audio()
	_initialize_display()
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
	if key == "display_mode" and int(value) not in [1, 2]: return false
	if key == "aspect_ratio" and int(value) not in range(0, 5): return false
	if key == "brightness" and int(value) not in range(50, 151): return false
	if key == "text_speed" and int(value) not in [1, 2, 3]: return false
	if key in ["window_width", "window_height"] and int(value) < 320: return false
	values[key] = value
	_sanitize()
	unsaved = true
	_apply_audio()
	changed.emit(values.duplicate(true))
	persistence_changed.emit()
	return save() if persist else true

func restore_defaults() -> bool:
	# 恢复设置初值，但不改变配置中的音量步长。
	if busy or not initialized_ok or display_preview_active: return false
	values = defaults.duplicate(true)
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
	# 恢复全部默认的预览只改变运行值；确认前保存仍写之前的整组偏好。
	if display_preview_active and display_restore_all:
		for key in display_restore_values: data[key] = display_restore_values[key]
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
	# 格式1保留六项旧偏好；新增显示字段缺失时从默认值补齐。
	if not data is Dictionary or int(data.get("version", 0)) not in [1, FILE_VERSION]: return false
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume", "mute", "reduce_motion"]:
		if not data.has(key): return false
		var value = data.get(key)
		if DEFAULTS[key] is bool:
			if not value is bool: return false
		elif not (value is int or value is float) or not is_finite(float(value)) or float(value) != floor(float(value)) or value < 0 or value > 100: return false
	for key in ["display_mode", "window_width", "window_height", "aspect_ratio", "brightness", "text_speed"]:
		if not data.has(key): continue
		var value = data[key]
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floor(float(value)): return false
	if int(data.get("display_mode", 1)) not in [1, 2] or int(data.get("aspect_ratio", 0)) not in range(0, 5): return false
	if int(data.get("brightness", 100)) not in range(50, 151) or int(data.get("text_speed", 2)) not in [1, 2, 3]: return false
	if int(data.get("window_width", 1600)) < 320 or int(data.get("window_height", 900)) < 240: return false
	return true

func _sanitize() -> void:
	# 限制音量范围并确保开关字段保持布尔类型。
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		values[key] = clampi(int(values.get(key, DEFAULTS[key])), 0, 100)
	values["mute"] = bool(values.get("mute", false))
	values["reduce_motion"] = bool(values.get("reduce_motion", false))
	values["display_mode"] = 2 if int(values.get("display_mode", 1)) == 2 else 1
	values["window_width"] = maxi(320, int(values.get("window_width", 1600)))
	values["window_height"] = maxi(240, int(values.get("window_height", 900)))
	values["aspect_ratio"] = clampi(int(values.get("aspect_ratio", 0)), 0, 4)
	values["brightness"] = clampi(int(values.get("brightness", 100)), 50, 150)
	values["text_speed"] = clampi(int(values.get("text_speed", 2)), 1, 3)

func _apply_audio() -> void:
	# 将总音量和静音状态即时应用到 Godot 音频总线。
	var master := 0.0 if values.mute else float(values.master_volume) / 100.0
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, 0.0001)))


func confirmed_display() -> Dictionary:
	return {"display_mode": int(values.display_mode), "window_width": int(values.window_width), "window_height": int(values.window_height), "aspect_ratio": int(values.aspect_ratio)}

func begin_display_preview(candidate: Dictionary, restore_all: bool = false) -> bool:
	if busy or not initialized_ok or display_preview_active: return false
	var next := confirmed_display()
	for key in next:
		if candidate.has(key): next[key] = int(candidate[key])
	if next.display_mode not in [1, 2] or next.window_width < 320 or next.window_height < 240 or next.aspect_ratio not in range(0, 5): return false
	display_restore_values = values.duplicate(true)
	display_restore_candidate = display_candidate.duplicate(true)
	display_restore_all = restore_all
	display_candidate = next
	display_preview_active = display_candidate != runtime_display or restore_all or not display_adaptation_notice.is_empty()
	if not display_preview_active: return false
	if restore_all:
		values = defaults.duplicate(true)
		_apply_audio()
		changed.emit(values.duplicate(true))
	_apply_display(next)
	preview_deadline_ms = Time.get_ticks_msec() + 15000
	display_preview_seconds = 15.0
	persistence_changed.emit()
	return true

func cancel_display_preview() -> void:
	if display_preview_active:
		if display_restore_all:
			values = display_restore_values.duplicate(true)
			_apply_audio()
			changed.emit(values.duplicate(true))
		_apply_display(_adapt_display(confirmed_display()))
		display_candidate = display_restore_candidate.duplicate(true) if display_restore_all else {}
	display_preview_active = false
	display_preview_seconds = 0.0
	display_restore_all = false
	persistence_changed.emit()

func keep_display_preview() -> bool:
	if busy or not display_preview_active: return false
	for key in display_candidate: values[key] = display_candidate[key]
	display_candidate.clear()
	display_preview_active = false
	display_preview_seconds = 0.0
	display_restore_all = false
	display_adaptation_notice = ""
	unsaved = true
	changed.emit(values.duplicate(true))
	return save()

func available_window_sizes(work_area := Vector2i.ZERO) -> Array[Vector2i]:
	var available := work_area
	if available == Vector2i.ZERO:
		available = DisplayServer.screen_get_usable_rect().size
		if available.x < 1 or available.y < 1: available = Vector2i(1600, 900)
	var result: Array[Vector2i] = []
	for preset in WINDOW_PRESETS:
		if preset.x <= available.x and preset.y <= available.y: result.append(preset)
	result.sort_custom(func(a: Vector2i, b: Vector2i): return a.x * a.y < b.x * b.y)
	return result

func effective_display_area(client_size := Vector2.ZERO, selected_ratio: int = -1) -> Rect2:
	var client := client_size
	if client.x <= 0 or client.y <= 0:
		client = Vector2(get_viewport().get_visible_rect().size) if get_viewport() != null else Vector2(1600, 900)
	var ratio := selected_ratio
	if ratio < 0: ratio = int(runtime_display.get("aspect_ratio", values.aspect_ratio))
	if ratio == 0: return Rect2(Vector2.ZERO, client)
	var ratios := {1: 16.0 / 9.0, 2: 16.0 / 10.0, 3: 4.0 / 3.0, 4: 21.0 / 9.0}
	var r: float = ratios.get(ratio, client.x / maxf(1.0, client.y))
	var width := minf(client.x, client.y * r)
	var area_size := Vector2(width, width / r)
	return Rect2((client - area_size) * 0.5, area_size)

func text_speed_multiplier() -> float:
	return {1: 0.5, 2: 1.0, 3: 1.5}.get(int(values.text_speed), 1.0)

func _initialize_display() -> void:
	if get_viewport() != null and not get_viewport().size_changed.is_connected(_emit_display_area): get_viewport().size_changed.connect(_emit_display_area)
	_apply_display(_adapt_display(confirmed_display()))

func _adapt_display(display: Dictionary) -> Dictionary:
	var adapted := display.duplicate(true)
	var sizes := available_window_sizes()
	if int(adapted.display_mode) == 1 and Vector2i(int(adapted.window_width), int(adapted.window_height)) not in sizes:
		if sizes.is_empty():
			adapted.display_mode = 2
			display_adaptation_notice = "当前桌面无法容纳窗口预设，已临时使用全屏；保留显示后才保存。"
		else:
			var largest: Vector2i = sizes.back()
			adapted.window_width = largest.x
			adapted.window_height = largest.y
			display_adaptation_notice = "原窗口尺寸无法容纳，已临时适配当前桌面；保留显示后才保存。"
	return adapted

func _apply_display(display: Dictionary) -> void:
	runtime_display = display.duplicate(true)
	if apply_window_enabled and DisplayServer.get_name() != "headless":
		if int(display.display_mode) == 2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var requested_size := Vector2i(int(display.window_width), int(display.window_height))
			DisplayServer.window_set_size(requested_size)
			var usable := DisplayServer.screen_get_usable_rect()
			DisplayServer.window_set_position(usable.position + (usable.size - requested_size) / 2)
	_emit_display_area()

func _emit_display_area() -> void:
	display_changed.emit(effective_display_area())

func _process(_delta: float) -> void:
	if not display_preview_active: return
	display_preview_seconds = maxf(0.0, float(preview_deadline_ms - Time.get_ticks_msec()) / 1000.0)
	if display_preview_seconds <= 0: cancel_display_preview()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and display_preview_active: cancel_display_preview()
