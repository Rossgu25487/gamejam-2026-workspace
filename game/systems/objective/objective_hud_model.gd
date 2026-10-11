extends RefCounted
## 目标 HUD 的纯逻辑状态：开合、更新提示、提亮、列表位置目标、暂停与遮挡冻结。不含任何节点，便于回归。
## 依据《目标导航系统策划案》第 2-4、6、8 节；时间由调用方以毫秒推进，暂停与遮挡期间不推进。

const Data = preload("res://systems/objective/objective_data.gd")

var notice_total_ms := 2000.0 # “已更新”保留时长
var glow_total_ms := 300.0 # 同一段提示内条目提亮时长
var visible_item_limit := 3

var expanded := true # 本次运行内保留的开合选择，首次默认展开
var goal: Dictionary = {} # 规范化后的当前目标；空表示无目标
var allowed := true # 当前是否为可以继续操作场景的调查画面
var paused := false
var reduce_motion := false
var marker := false # 收起期间未查看的“更新”标记（只留一个）
var notice_ms := 0.0 # “已更新”剩余时长
var glow_ms := 0.0 # 提亮剩余时长
var glow_used := false # 当前连续提示段是否已提亮
var pending_notice := false # 遮挡期间收到的变化，返回后提示一次
var scroll := {"mode": "top", "item": ""} # 页面下次渲染应采用的位置：top / keep / item
var reported_first := "" # 页面回报的第一条可见待核事项
var errors: Array[String] = []
var revision := 0 # HUD 可见状态（内容、开合、显示许可）每变化一次递增
var content_revision := 0 # 只在目标内容实际变化时递增，页面据此决定是否重建列表


func configure(config: Dictionary) -> void:
	notice_total_ms = float(config.get("update_notice_ms", notice_total_ms))
	glow_total_ms = float(config.get("update_glow_ms", glow_total_ms))
	visible_item_limit = int(config.get("visible_item_limit", visible_item_limit))


func shown() -> bool:
	return not goal.is_empty() and allowed


func ticking() -> bool:
	return shown() and not paused and (notice_ms > 0.0 or glow_ms > 0.0)


func apply(result: Dictionary, origin: String) -> Dictionary:
	# 接收规范化结果。返回 {"content": HUD 内容是否变化, "full": 回顾所读内容是否变化}。
	var before_full := Data.full_signature(goal)
	if not bool(result.get("ok", false)):
		errors.assign(result.get("errors", []))
		var had := not goal.is_empty()
		_reset_transient()
		goal = {}
		_set_scroll("top")
		revision += 1
		content_revision += 1
		return {"content": had, "full": had}
	errors.clear()
	var incoming: Dictionary = result["goal"]
	var content_changed := Data.content_signature(goal) != Data.content_signature(incoming)
	if incoming.is_empty():
		# 无目标：隐藏整个面板，停止提示并清除旧标记和列表位置。
		_reset_transient()
		goal = {}
		_set_scroll("top")
		if content_changed:
			revision += 1
			content_revision += 1
		return {"content": content_changed, "full": before_full != ""}
	if origin != "result":
		# 首次建立与读档成功：静默重建，清旧提示与位置，从第一条开始。
		_reset_transient()
		goal = incoming
		_set_scroll("top")
		revision += 1
		content_revision += 1
		return {"content": true, "full": true}
	if not content_changed:
		# 完全相同的内容重复送达：不重新计时，不再次提亮；依据与入口的变化静默生效。
		goal = incoming
		return {"content": false, "full": Data.full_signature(goal) != before_full}
	var old := goal
	var goal_changed: bool = old.is_empty() or old["goal_id"] != incoming["goal_id"]
	var main_changed: bool = old.is_empty() or old["goal_text"] != incoming["goal_text"]
	if goal_changed:
		_reset_transient() # 旧目标的标记、提示计时和列表位置不再保留
	var old_pending := Data.item_ids(Data.pending_items(old))
	var new_pending := Data.item_ids(Data.pending_items(incoming))
	if goal_changed or main_changed or new_pending.is_empty():
		_set_scroll("top")
	else:
		var first := _first_visible(old_pending)
		if first.is_empty() or new_pending.has(first):
			_set_scroll("keep") # 主目标和第一条可见内容均未变化，列表位置保持
		else:
			_set_scroll("item", Data.neighbor_id(old_pending, first, new_pending))
	goal = incoming
	revision += 1
	content_revision += 1
	_notify()
	return {"content": true, "full": true}


func toggle() -> void:
	# 点击标题只改变开合；收起期间积累的标记在展开时转为一次“已更新”。
	expanded = not expanded
	if expanded:
		if marker:
			marker = false
			notice_ms = notice_total_ms
			_start_glow()
	else:
		notice_ms = 0.0
		glow_ms = 0.0
		glow_used = false
	revision += 1


func set_allowed(value: bool) -> void:
	if allowed == value:
		return
	allowed = value
	if not allowed:
		glow_ms = 0.0 # 被覆盖打断的提亮不补播
	elif pending_notice:
		pending_notice = false
		_notify_shown()
	revision += 1


func set_paused(value: bool) -> void:
	paused = value
	if paused:
		glow_ms = 0.0


func set_reduce_motion(value: bool) -> void:
	reduce_motion = value
	if value:
		glow_ms = 0.0 # 开启后取消提亮并保留文字；关闭不补播


func mark_seen() -> void:
	# 在回顾中看到最新目标后，标记与提示消失。
	marker = false
	pending_notice = false
	notice_ms = 0.0
	glow_ms = 0.0
	glow_used = false
	revision += 1


func advance(delta_ms: float) -> bool:
	# 推进计时；暂停、隐藏或无目标时不推进。返回提示状态是否发生了结束性变化。
	if not shown() or paused:
		return false
	var changed := false
	if glow_ms > 0.0:
		glow_ms = maxf(0.0, glow_ms - delta_ms)
		changed = changed or glow_ms == 0.0
	if notice_ms > 0.0:
		notice_ms = maxf(0.0, notice_ms - delta_ms)
		if notice_ms == 0.0:
			glow_used = false # 连续提示段结束
			changed = true
	return changed


func report_scroll(first_id: String) -> void:
	reported_first = first_id
	scroll = {"mode": "keep", "item": ""}


func take_scroll() -> Dictionary:
	# 页面渲染时取走位置目标；之后默认保持页面自身的滚动位置。
	var current := scroll.duplicate()
	scroll = {"mode": "keep", "item": ""}
	return current


func view() -> Dictionary:
	var items: Array = []
	for item in Data.pending_items(goal):
		items.append({"id": item["id"], "text": item["text"], "reason": item["reason"]})
	return {
		"shown": shown(), "expanded": expanded, "goal_id": goal.get("goal_id", ""), "goal_text": goal.get("goal_text", ""),
		"items": items, "marker": marker and not expanded, "notice": expanded and notice_ms > 0.0,
		"glow": glow_ms / glow_total_ms if glow_ms > 0.0 and glow_total_ms > 0.0 else 0.0,
		"revision": revision, "content_revision": content_revision,
	}


func _notify() -> void:
	# 一次内容变化：遮挡中只保留最新变化；展开则提示并提亮一次；收起只留一个标记。
	if not allowed:
		pending_notice = true
	else:
		_notify_shown()


func _notify_shown() -> void:
	if expanded:
		notice_ms = notice_total_ms # 从最后一次显示新内容时重新计时
		_start_glow()
	else:
		marker = true


func _start_glow() -> void:
	if reduce_motion or paused or glow_used:
		return
	glow_ms = glow_total_ms
	glow_used = true


func _first_visible(old_pending: Array) -> String:
	if old_pending.is_empty():
		return ""
	if reported_first.is_empty() or not old_pending.has(reported_first):
		return String(old_pending[0])
	return reported_first


func _set_scroll(mode: String, item := "") -> void:
	scroll = {"mode": mode, "item": item}
	if mode == "top":
		reported_first = ""


func _reset_transient() -> void:
	marker = false
	notice_ms = 0.0
	glow_ms = 0.0
	glow_used = false
	pending_notice = false
