extends RefCounted
## 撸猫互动状态机：纯逻辑、时间由外部注入，便于无窗口回归测试。
## 负责等待/手势/回应三段与首见记录；素材显示与动作播放由页面（integration）负责。

signal changed                          # 任意可见状态或数据变化，页面据此刷新
signal purr_requested(sound_ref: String, gain: float)  # 有效触摸请求播放一次呼噜
signal finished                         # 两段计时自然结束

var phase: String = "idle"              # idle / waiting / gesture / response / returned
var first_seen: bool = false            # 本次调查的首见记录（随 cat_snapshot 持久化）
var response_kind: String = ""          # 本次互动锁定的回应类型 "first" / "repeat"
var reduce_motion: bool = false         # 本回可中途开启；开启后保持静态，下一回才允许恢复动态

var _interaction: Dictionary = {}       # 进入时冻结的互动配置
var _view: Dictionary = {}              # 进入时冻结的展示配置
var _actions: Dictionary = {}           # 进入时冻结的动作绑定（按 action_kind 索引）
var _remaining_ms: float = 0.0          # 当前阶段剩余时长
var _paused: bool = false

func enter(interaction: Dictionary, view: Dictionary, actions: Dictionary) -> bool:
	# 冻结本次配置；基础时长字段缺失则拒绝进入。正式就绪判定由 catalog.resolve 负责。
	if is_active() or int(interaction.get("pet_ms", 0)) <= 0 or int(interaction.get("response_ms", 0)) <= 0:
		return false
	_interaction = interaction.duplicate(true)
	_view = view.duplicate(true)
	_actions = actions.duplicate(true)
	phase = "waiting"
	response_kind = ""
	reduce_motion = false
	_remaining_ms = 0.0
	_paused = false
	changed.emit()
	return true

func begin_touch(motion_reduced: bool) -> bool:
	# 有效触摸只提交一次；等待态之外重复输入不排队。
	if phase != "waiting" or _paused: return false
	reduce_motion = motion_reduced
	response_kind = "repeat" if first_seen else "first"
	phase = "gesture"
	_remaining_ms = float(int(_interaction.pet_ms))
	_paused = false
	var sound_ref: String = str(_interaction.get("sound_ref", ""))
	if not sound_ref.is_empty():
		purr_requested.emit(sound_ref, float(_interaction.get("purr_gain", 0.0)))
	changed.emit()
	return true

func advance(delta_ms: float) -> void:
	# 时间由调用方注入；暂停或非计时阶段不推进。
	if _paused or phase not in ["gesture", "response"] or not is_finite(delta_ms) or delta_ms <= 0.0: return
	if phase == "gesture":
		_remaining_ms -= delta_ms
		if _remaining_ms <= 0.0:
			phase = "response"
			# 一帧跨过边界的余量计入回应段，不因帧率不同额外延长本回。
			_remaining_ms += float(int(_interaction.response_ms))
	elif phase == "response":
		_remaining_ms -= delta_ms
	if phase == "response" and _remaining_ms <= 0.0:
		phase = "returned"
		_remaining_ms = 0.0
		changed.emit()
		finished.emit()
		return
	changed.emit()

func set_reduce_motion(enabled: bool) -> void:
	# 开启立即改用本回选定的稳定姿态，时钟保持；关闭不补播已经跳过的动作。
	if enabled and is_active() and not reduce_motion:
		reduce_motion = true
		changed.emit()

func notify_stable_displayed() -> void:
	# 视图确认稳定画面已实际显示（普通回应到达 stable_point，或减弱动态直接显示）才记首见。
	if _paused or (phase != "response" and not (phase == "gesture" and reduce_motion)) or response_kind != "first" or first_seen: return
	first_seen = true
	changed.emit()

func pause() -> void:
	if is_active() and not _paused:
		_paused = true
		changed.emit()

func resume() -> void:
	if _paused:
		_paused = false
		changed.emit()

func finish() -> void:
	# 主动返回：停止本次动作与计时，未显示稳定画面的首见不记录。
	if phase == "returned" or phase == "idle": return
	phase = "returned"
	_remaining_ms = 0.0
	_paused = false
	changed.emit()

func is_active() -> bool:
	return phase == "waiting" or phase == "gesture" or phase == "response"

func current_action_kind() -> String:
	# 当前应显示的动作键；减弱动态映射到对应稳定姿态，结束映射到归位。
	match phase:
		"waiting": return "waiting"
		"gesture": return ("stable_first" if response_kind == "first" else "stable_repeat") if reduce_motion else "gesture"
		"response":
			if reduce_motion:
				return "stable_first" if response_kind == "first" else "stable_repeat"
			return "response_first" if response_kind == "first" else "response_repeat"
		_: return "finish"

func caption_text_id() -> String:
	if phase != "response": return ""
	return str(_interaction.get("first_caption_text_id" if response_kind == "first" else "repeat_caption_text_id", ""))

func remaining_ms() -> float:
	return _remaining_ms

func export_state() -> Dictionary:
	# 猫互动只持久化首见记录；动作与呼噜声不续播。
	return {"first_seen": first_seen}

func restore_state(snapshot: Dictionary) -> bool:
	if not validate_state(snapshot): return false
	# 调查读档只恢复首见，丢弃旧动作与暂停时钟；不续播旧呼噜或结束回调。
	first_seen = snapshot.first_seen
	phase = "idle"
	response_kind = ""
	reduce_motion = false
	_remaining_ms = 0.0
	_paused = false
	_interaction = {}
	_view = {}
	_actions = {}
	changed.emit()
	return true

func validate_state(snapshot: Dictionary) -> bool:
	return snapshot.get("first_seen") is bool
