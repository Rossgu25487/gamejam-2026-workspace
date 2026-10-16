extends Node
## 目标导航服务：HUD 状态、调查回顾状态与单份阅读请求的唯一入口。
## 页面只读 hud_view / review_view 并提交操作；案件进展由提供方给出，导航不推进目标。

const Data = preload("res://systems/objective/objective_data.gd")
const HudModel = preload("res://systems/objective/objective_hud_model.gd")
const DEFAULT_CONFIG := "res://data/objective/objective_config.json"
const FUNCTION_TEXT := "res://data/core/function_text.json"

signal changed # HUD 或回顾所读内容发生变化
signal integration_error(errors: Array) # 接入检查报错（有编号缺主目标、事项重复等）
signal review_state_changed(state: String) # closed / preparing / open
signal read_completed(basis_id: String, result: Dictionary) # 异步依据准备完成

var config: Dictionary = {}
var texts: Dictionary = {} # 位置键 -> 功能文字 ID
var model: RefCounted = HudModel.new()
var provider: RefCounted
var review_state := "closed"
var review_error := "" # HUD 回顾入口附近持续显示的功能文字 ID
var integration_errors: Array[String] = []
var log_warnings := true # 接入检查报错时是否同时写引擎警告；故意构造错误数据的测试可关闭，避免污染标准错误输出。

var text_source := Callable() # 解析功能文字 ID 的函数；Main 注入核心的 ui，缺省时直接读功能文字表

var _read_busy := false
var _go_busy := false
var _function_texts: Dictionary = {}


func _ready() -> void:
	set_process(false) # 只有提示或提亮进行时才逐帧推进。


func setup(path := DEFAULT_CONFIG) -> bool:
	# 读取显示初值与功能文字键；文件缺失时保持内置默认并返回 false。
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	return configure(parsed)

func configure(parsed: Dictionary) -> bool:
	# 工作簿与原JSON共用标准运行结构，页面不区分来源。
	config = parsed
	texts = parsed.get("texts", {})
	model.configure(parsed.get("hud", {}))
	return true


func text_id(key: String) -> String:
	return String(texts.get(key, ""))


func resolve(id: String) -> String:
	# 功能文字 ID 换成显示文字；文字实际值统一在功能文字表维护，本模块只引用稳定键。
	if id.is_empty():
		return ""
	if text_source.is_valid():
		return String(text_source.call(id))
	if _function_texts.is_empty():
		var file := FileAccess.open(FUNCTION_TEXT, FileAccess.READ)
		var rows = JSON.parse_string(file.get_as_text()) if file != null else []
		if rows is Array:
			for row in rows:
				_function_texts[String(row["id"])] = String(row["text"])
	return String(_function_texts.get(id, id))


func label(key: String) -> String:
	return resolve(text_id(key))


func glow_fraction() -> float:
	# 当前条目提亮的剩余比例；页面只在提亮进行时逐帧读取。
	if model.glow_ms <= 0.0 or model.glow_total_ms <= 0.0:
		return 0.0
	return model.glow_ms / model.glow_total_ms


func bind_provider(source: RefCounted) -> void:
	if provider != null and provider.objective_changed.is_connected(_on_provider_changed):
		provider.objective_changed.disconnect(_on_provider_changed)
	provider = source
	if provider != null:
		provider.objective_changed.connect(_on_provider_changed)


func refresh(origin: String) -> void:
	# origin：initial 首次建立、result 结果生效、restore 读档成功。
	if provider != null:
		deliver(provider.objective_snapshot(), origin)


func deliver(raw: Dictionary, origin: String) -> bool:
	# 接收一份目标显示结果；返回是否通过接入检查。
	var result := Data.normalize(raw)
	var outcome: Dictionary = model.apply(result, origin)
	if bool(result["ok"]):
		integration_errors.clear()
	else:
		integration_errors.assign(result["errors"])
		if log_warnings:
			push_warning("目标导航接入检查：" + "；".join(integration_errors))
		integration_error.emit(integration_errors)
	if origin != "result":
		review_error = ""
	_update_processing()
	if outcome["content"] or outcome["full"] or not bool(result["ok"]):
		changed.emit()
	return bool(result["ok"])


func clear_errors() -> void:
	# 离开原页（切换场景、覆盖界面）或重试开始时清除持续显示的原因。
	if not review_error.is_empty():
		review_error = ""
		changed.emit()


# ---------- HUD ----------

func hud_view() -> Dictionary:
	var view: Dictionary = model.view()
	view["error"] = review_error
	view["review_enabled"] = review_state == "closed"
	return view


func toggle_expanded() -> void:
	model.toggle()
	_after_model_change()


func set_display_allowed(value: bool) -> void:
	if model.allowed == value:
		return
	model.set_allowed(value)
	if not value and review_state == "closed":
		review_error = "" # 离开原页清除打开失败原因
	_after_model_change()


func set_paused(value: bool) -> void:
	if model.paused == value:
		return
	model.set_paused(value)
	_after_model_change()


func set_reduce_motion(value: bool) -> void:
	if model.reduce_motion == value:
		return
	model.set_reduce_motion(value)
	_after_model_change()


func report_scroll(first_id: String) -> void:
	model.report_scroll(first_id)


func take_scroll() -> Dictionary:
	return model.take_scroll()


func advance(delta_ms: float) -> void:
	if model.advance(delta_ms):
		changed.emit()
	_update_processing()


func _process(delta: float) -> void:
	advance(delta * 1000.0)


func _after_model_change() -> void:
	_update_processing()
	changed.emit()


func _update_processing() -> void:
	set_process(model.ticking())


func _on_provider_changed() -> void:
	refresh("result")


# ---------- 调查回顾 ----------

func request_review() -> String:
	# 点击【调查回顾】：同一准备中只处理一次；准备成功后才进入，失败时原页保持并持续显示原因。
	if review_state != "closed" or provider == null:
		return "ignored"
	review_error = "" # 重试开始即清除上一次原因
	_set_review_state("preparing")
	var outcome = provider.prepare_review()
	if outcome == null:
		return "preparing"
	return _finish_review(bool(outcome))


func complete_review(ok: bool) -> void:
	if review_state == "preparing":
		_finish_review(ok)


func _finish_review(ok: bool) -> String:
	if ok:
		model.mark_seen()
		_set_review_state("open")
		_update_processing()
		changed.emit()
		return "opened"
	review_error = text_id("error_review")
	_set_review_state("closed")
	changed.emit()
	return "failed"


func close_review() -> void:
	# 【返回调查】：结束回顾占用，回到原调查画面。
	if review_state != "open":
		return
	_set_review_state("closed")
	if provider != null:
		provider.end_review()
	changed.emit()


func reset() -> void:
	# 新建会话或回到标题：丢弃回顾占用、持续原因和进行中的请求；占用由提供方归还。
	_read_busy = false
	_go_busy = false
	review_error = ""
	if review_state != "closed":
		_set_review_state("closed")
		if provider != null:
			provider.end_review()
	changed.emit()


func _set_review_state(value: String) -> void:
	review_state = value
	review_state_changed.emit(value)


func review_view() -> Dictionary:
	# 回顾读取同一份目标：主目标、待核事项与已核查进展；数据无效时只给出错误标记。
	var goal: Dictionary = model.goal
	if not integration_errors.is_empty():
		return {"open": review_state == "open", "invalid": true, "empty": true, "goal_id": "", "goal_text": "", "pending": [], "progress": []}
	var view := {"open": review_state == "open", "invalid": false, "empty": goal.is_empty(), "goal_id": goal.get("goal_id", ""), "goal_text": goal.get("goal_text", ""), "pending": [], "progress": []}
	for item in goal.get("items", []):
		var entry: Dictionary = (item["entry"] as Dictionary).duplicate()
		var bases: Array = []
		for id in item["basis"]:
			bases.append((goal["bases"][id] as Dictionary).duplicate())
		var row := {"id": item["id"], "text": item["text"], "status": item["status"], "reason": item["reason"], "entry": entry, "bases": bases}
		(view["pending"] if item["status"] == "pending" else view["progress"]).append(row)
	return view


# ---------- 单份依据与前往核对 ----------

func request_read(basis_id: String) -> Dictionary:
	# 读取一份准确依据。返回 {"status": ok / busy / failed / preparing, "doc": Dictionary}。
	if _read_busy:
		return {"status": "busy"}
	if provider == null:
		return {"status": "failed"}
	_read_busy = true
	var outcome = provider.read_basis(basis_id)
	if outcome == null:
		return {"status": "preparing"}
	return _finish_read(basis_id, outcome)


func complete_read(basis_id: String, result: Dictionary) -> void:
	if _read_busy:
		var outcome := _finish_read(basis_id, result)
		read_completed.emit(basis_id, outcome)


func _finish_read(_basis_id: String, result: Dictionary) -> Dictionary:
	_read_busy = false
	if bool(result.get("ok", false)):
		return {"status": "ok", "doc": result.get("doc", {})}
	return {"status": "failed", "error": text_id("error_read")}


func request_go(entry_id: String) -> Dictionary:
	# 前往核对：先看当前入口是否可用，再由提供方重新检查；成功后回顾占用已结束，失败则原状保持。
	if _go_busy:
		return {"status": "busy"}
	var entry := _find_entry(entry_id)
	if entry.is_empty() or not bool(entry["available"]):
		return {"status": "unavailable", "reason": String(entry.get("reason", ""))}
	_go_busy = true
	var check: Dictionary = provider.recheck_entry(entry_id)
	if not bool(check.get("available", false)):
		_go_busy = false
		return {"status": "unavailable", "reason": String(check.get("reason", ""))}
	var went: Dictionary = provider.go_entry(entry_id)
	_go_busy = false
	if bool(went.get("ok", false)):
		review_state = "closed"
		review_state_changed.emit("closed")
		changed.emit()
		return {"status": "ok"}
	return {"status": "failed", "reason": String(went.get("reason", ""))}


func _find_entry(entry_id: String) -> Dictionary:
	for item in model.goal.get("items", []):
		if not item["entry"].is_empty() and item["entry"]["id"] == entry_id:
			return item["entry"]
	return {}
