extends RefCounted
## 撸猫配置目录：解析并校验四张表，提供互动/展示/动作/文字引用与入口就绪判定。
## 正式记录与 EX 联调记录分开，Main 只消费正式记录；占位素材不能假播放完成或记录首见。

const WorkbookLoader = preload("res://features/cat_interaction/cat_workbook_loader.gd")
const FUNCTION_TEXT_PATH := "res://data/core/function_text.json"

var interactions: Dictionary = {}     # 猫互动（正式）id -> 记录
var views: Dictionary = {}           # 猫展示（正式）id -> 记录
var ex_views: Dictionary = {}        # 猫展示 EX 联调行 id -> 记录
var actions: Array = []              # 动作绑定（正式）记录数组
var texts: Dictionary = {}           # 文字绑定 id -> 共用功能文字 text_id
var function_texts: Dictionary = {}  # text_id -> 实际文字
var errors: Array[String] = []

func load_files(path: String = WorkbookLoader.DEFAULT_PATH) -> bool:
	var workbook = WorkbookLoader.new()
	var tables = workbook.load_workbook(path)
	if not workbook.errors.is_empty():
		errors.assign(workbook.errors)
		return false
	var ft_file := FileAccess.open(FUNCTION_TEXT_PATH, FileAccess.READ)
	var ft = JSON.parse_string(ft_file.get_as_text()) if ft_file else null
	if not ft is Array:
		errors.assign(["功能文字配置无法读取"])
		return false
	for row in ft: function_texts[str(row.id)] = str(row.text)
	return configure(tables)

func configure(tables: Dictionary) -> bool:
	errors.clear()
	interactions.clear(); views.clear(); ex_views.clear(); actions.clear(); texts.clear()
	for sheet in ["猫互动", "猫展示", "动作绑定", "文字绑定"]:
		if not tables.has(sheet): _check(false, "缺少配置表：" + sheet)
	if not errors.is_empty(): return false
	for row in tables["猫互动"]:
		if not _formal(row): continue
		_put(interactions, row.get("id", ""), row)
	for row in tables["猫展示"]:
		if _formal(row): _put(views, row.get("id", ""), row)
		else: _put(ex_views, row.get("id", ""), row)
	for row in tables["动作绑定"]:
		if not _formal(row): continue
		actions.append(row)
		_check(row.get("action_kind", "") in ["waiting", "gesture", "response_first", "response_repeat", "stable_first", "stable_repeat", "finish"], "动作用途无效：" + str(row.get("id", "")))
		_check(row.get("play_mode", "") in ["loop", "once", "pose"], "播放方式无效：" + str(row.get("id", "")))
	for row in tables["文字绑定"]:
		if not _formal(row): continue
		texts[row.get("id", "")] = row.get("text_id", "")
		_check(function_texts.has(row.get("text_id", "")), "文字引用缺失：" + str(row.get("id", "")) + "/" + str(row.get("text_id", "")))
	for id in interactions:
		var it: Dictionary = interactions[id]
		if not str(it.get("view_profile_ref", "")).is_empty():
			_check(views.has(it.view_profile_ref), "展示引用缺失：" + str(id))
	for row in actions:
		_check(interactions.has(str(row.get("interaction_ref", ""))), "动作归属互动缺失：" + str(row.get("id", "")))
	# 每个正式互动须具备全部动作键，稳定姿态与结束归位允许复用素材但行必须存在。
	for id in interactions:
		var kinds := {}
		for row in actions:
			if row.get("interaction_ref", "") == id: kinds[row.get("action_kind", "")] = true
		for kind in ["waiting", "gesture", "response_first", "response_repeat", "stable_first", "stable_repeat", "finish"]:
			_check(kinds.has(kind), "互动缺少动作：" + str(id) + "/" + kind)
	return errors.is_empty()

func interaction(id: String) -> Dictionary:
	return interactions.get(id, {})

func view(id: String) -> Dictionary:
	return views.get(id, {})

func test_view(id: String) -> Dictionary:
	# 仅供联调读取 EX 展示行；正式互动不得引用。
	return ex_views.get(id, {})

func actions_for(interaction_id: String) -> Dictionary:
	var result := {}
	for row in actions:
		if row.get("interaction_ref", "") == interaction_id:
			result[row.get("action_kind", "")] = row
	return result

func ui(key: String) -> String:
	# 固定功能文字引用初始化系统的同一来源；缺引用时回退显示键名。
	var text_id: String = texts.get(key, key)
	return str(function_texts.get(text_id, text_id))

func resolve(interaction_id: String) -> Dictionary:
	# 返回 {"ok": bool, "reason": String, "interaction": {}, "view": {}, "actions": {}}。
	if not interactions.has(interaction_id): return {"ok": false, "reason": "互动记录缺失：" + interaction_id}
	var it: Dictionary = interactions[interaction_id]
	var v: Dictionary = views.get(str(it.get("view_profile_ref", "")), {})
	var acts := actions_for(interaction_id)
	var reason := _unready_reason(it, v, acts)
	if not reason.is_empty(): return {"ok": false, "reason": reason}
	return {"ok": true, "interaction": it, "view": v, "actions": acts}

func _unready_reason(it: Dictionary, view: Dictionary, acts: Dictionary) -> String:
	# 正式必需素材未就绪时入口禁用，原因使用 CAT_ENTRY_UNREADY 的正式文字。
	if view.is_empty(): return "猫展示配置缺失"
	if str(view.get("visual_host_ref", "")).is_empty(): return "猫素材载体未就绪"
	for key in ["screen_x", "screen_y", "screen_w", "screen_h", "head_x", "head_y", "head_w", "head_h", "anchor_x", "anchor_y", "display_scale"]:
		if not (view.get(key) is float): return "猫展示几何未就绪"
	for kind in ["waiting", "gesture", "response_first", "response_repeat", "stable_first", "stable_repeat"]:
		if not acts.has(kind) or str(acts[kind].get("visual_ref", "")).is_empty(): return "猫动作未就绪：" + kind
	return ""

func _formal(row: Dictionary) -> bool:
	return bool(row.get("_formal", false))

func _put(target: Dictionary, id: String, value) -> void:
	if target.has(id): _check(false, "ID重复：" + id)
	else: target[id] = value

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
