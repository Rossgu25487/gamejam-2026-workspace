extends Control
## 普通材料的新版本生成反馈：只呈现已提交的取得，400ms内不拦截鼠标、不改变处理锁。
const MaterialCard = preload("res://pages/aurora/aurora_material_card.gd")
signal media_requested(request: Dictionary)
signal completed(content_id: String)

var session: Node
var active := false
var current_content := ""
var elapsed_ms := 0.0
var generation := 0
var reduced := false
var duration_ms := 400.0
var card: Control
var _pending: Array[String] = []
var _seen := {}
var _run_id := ""
var _sync_queued := false
var _presentation_mode := ""
var _baseline_generation := 0

func bind(value: Node) -> void:
	session = value
	name = "OrdinaryAcquisitionFeedback"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	resized.connect(_layout)
	session.changed.connect(_schedule_sync)
	reset()

func _schedule_sync() -> void:
	# 案件事件可以回滚；延后到本次完整同步提交结束后观察，不在grant中直接播放。
	if _sync_queued: return
	_sync_queued = true
	call_deferred("sync_committed_versions", _baseline_generation)

func sync_committed_versions(expected_generation: int = -1) -> void:
	if expected_generation != -1 and expected_generation != _baseline_generation: return
	_sync_queued = false
	if session == null: return
	if _run_id != str(session.run_id): reset(); return
	for record in session.case_state.data.get("materials", {}).values():
		for id in record.get("versions", {}):
			if not _seen.has(str(id)): enqueue(str(id))

func reset() -> void:
	# 新游戏/读档由宿主调用，已在档内的内容版只建基线，不补历史生成。
	cancel()
	_baseline_generation += 1
	_sync_queued = false
	_seen.clear()
	_run_id = str(session.run_id) if session != null else ""
	if session != null:
		for record in session.case_state.data.get("materials", {}).values():
			for id in record.get("versions", {}): _seen[str(id)] = true

func enqueue(content_id: String) -> bool:
	if session == null or not session.config.contents.has(content_id) or not session.case_state.owns(content_id): return false
	if _run_id != str(session.run_id): reset()
	if _seen.has(content_id): return false
	if content_id == "E01_V1": _seen[content_id] = true; return false
	var material_id := str(session.config.contents[content_id].material_id)
	if str(session.config.materials[material_id].type) == "inference": _seen[content_id] = true; return false
	_seen[content_id] = true
	_pending.append(content_id)
	show() # 等待关联对白结束时仍处理轻量队列，不靠业务锁唤醒。
	_try_start()
	return true

func _try_start() -> void:
	if active or _pending.is_empty() or session == null or session.paused or session.processing or session.response_active or session.mode not in ["investigation", "selection"] or session.pending_result.get("effect_pending", false): return
	current_content = _pending.pop_front()
	_presentation_mode = str(session.mode)
	elapsed_ms = 0.0
	active = true
	card = MaterialCard.new()
	card.size = Vector2(220, 330)
	add_child(card)
	card.configure(session, current_content, false)
	card.name = "Acquired_" + current_content
	# 卡面复用正式组件，但反馈不是按钮，所有后代保持输入穿透。
	for node in [card] + card.find_children("*", "Control", true, false):
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.focus_mode = Control.FOCUS_NONE
	show()
	_layout()
	_update_visual()
	media_requested.emit({"sfx": "SFX_CARD_ACQUIRE", "slot": "ui",
		"instance": "aurora_acquire/%d/%d/%s" % [get_instance_id(), generation, current_content]})

func _process(delta: float) -> void:
	if session == null or not is_visible_in_tree() or session.paused: return
	if _run_id != str(session.run_id): reset(); return
	if active and str(session.mode) != _presentation_mode: cancel(); return
	_try_start()
	if not active: return
	elapsed_ms += maxf(0.0, delta) * 1000.0
	_update_visual()
	if elapsed_ms >= duration_ms:
		var finished := current_content
		_clear_card()
		completed.emit(finished)
		_try_start()

func _update_visual() -> void:
	if not is_instance_valid(card): return
	var t := clampf(elapsed_ms / duration_ms, 0.0, 1.0)
	var weight := 1.0 - pow(1.0 - t, 3.0)
	card.set_meta("animation_scale", 1.0 if reduced else lerpf(0.82, 1.0, weight))
	card.modulate.a = 1.0 if reduced else clampf(elapsed_ms / 80.0, 0.0, 1.0)
	_layout()

func _layout() -> void:
	if not is_instance_valid(card): return
	var scale_factor := minf(1.0, size.y / 700.0)
	card.scale = Vector2.ONE * scale_factor * float(card.get_meta("animation_scale", 1.0))
	card.position = size * Vector2(0.5, 0.43) - card.size * card.scale / 2.0

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))
	_update_visual()

func _clear_card() -> void:
	if is_instance_valid(card):
		remove_child(card)
		card.queue_free()
	card = null
	active = false
	current_content = ""
	_presentation_mode = ""

func cancel() -> void:
	# 新操作换页结束表现，取得和未读状态继续由原业务保存；不发完成或重放。
	generation += 1
	_pending.clear()
	_clear_card()
	hide()
