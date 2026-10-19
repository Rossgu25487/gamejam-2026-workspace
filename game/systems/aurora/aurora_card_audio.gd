extends Node
## 核心专用动作音只消费已接受操作；8条声音与偏移来自最终核心工作簿。
signal media_requested(request: Dictionary)
signal production_error(message: String)
var session: Node
var bindings: Array = []
var generation := 0
var elapsed_ms := 0.0
var muted := false
var _serial := 0
var _pending: Array[Dictionary] = []
var _focus_identity := ""
var _run_id := ""
var _collect_instance := ""

func bind(value: Node) -> void:
	session = value
	bindings = session.config.rows("core", "核心动作音效").duplicate(true)
	_run_id = str(session.run_id)

func set_preferences(values: Dictionary) -> void:
	muted = bool(values.get("mute", false)) or int(values.get("master_volume", 100)) == 0 or int(values.get("effect_volume", 100)) == 0
	if muted: _pending.clear() # 静音时点内已经接受的动作不排队等解除静音。

func trigger(action: String, content_id: String = "") -> int:
	if session == null or session.paused: return 0
	if _run_id != str(session.run_id): reset()
	if action == "hand_focus_changed":
		if not session.config.contents.has(content_id): return 0
		var identity := str(session.config.contents[content_id].material_id)
		if identity == _focus_identity: return 0
		_focus_identity = identity
	if muted: return 0
	_serial += 1
	var found := 0
	for row in bindings:
		if str(row.get("trigger", "")) != action: continue
		var sound := str(row.get("sound_ref", ""))
		if sound.is_empty():
			production_error.emit("核心动作缺少声音绑定：" + action)
			continue
		found += 1
		var identity := "aurora_card/%d/%d/%d/%s" % [get_instance_id(), generation, _serial, str(row.id)]
		var request := {"sfx": sound, "slot": "ui", "instance": identity,
			"gain": float(row.get("gain_multiplier", 1.0))}
		if action == "collect_inference":
			_collect_instance = identity
			request.pan = 0.0
		var delay := maxf(0.0, float(row.get("offset_ms", 0)))
		if delay <= 0.0: media_requested.emit(request)
		else: _pending.append({"at": elapsed_ms + delay, "generation": generation, "request": request})
	if found == 0: production_error.emit("核心动作没有正式声音路由：" + action)
	return found

func _process(delta: float) -> void:
	advance(maxf(0.0, delta) * 1000.0)

func advance(delta_ms: float) -> void:
	if session == null or session.paused: return
	if _run_id != str(session.run_id): reset(); return
	elapsed_ms += maxf(0.0, delta_ms)
	var ready: Array[Dictionary] = []
	for entry in _pending.duplicate():
		if float(entry.at) > elapsed_ms: continue
		_pending.erase(entry)
		if int(entry.generation) == generation and not muted: ready.append(entry.request)
	for request in ready: media_requested.emit(request)

func update_collection_pan(center_x: float, viewport_width: float) -> void:
	if _collect_instance.is_empty() or viewport_width <= 0: return
	media_requested.emit({"command": "set_pan", "instance": _collect_instance,
		"pan": clampf((center_x / viewport_width * 2.0 - 1.0) * 0.36, -0.25, 0.25)})

func leave_page() -> void:
	# 当前已响声音自然留尾，尚未到点的动作声失效；重开不清身份，不补焦点声。
	generation += 1
	_pending.clear()
	_collect_instance = ""

func reset() -> void:
	leave_page()
	_focus_identity = ""
	_run_id = str(session.run_id) if session != null else ""
