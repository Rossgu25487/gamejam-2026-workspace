extends RefCounted
## 目标内容提供方接口：案件模块实现它，目标导航只通过这些方法读取同一份目标显示结果。
## 导航本身不保存第二份进度，也不推进目标、取得材料、收下推论或保存。

signal objective_changed # 目标记录或案件结果变化，导航据此重新读取


func objective_snapshot() -> Dictionary:
	# 同一份目标显示结果（供 HUD 与回顾共同读取），格式见 ObjectiveData.normalize：
	# {"goal_id", "goal_text", "items": [{"id","order","text","status","reason","basis":[依据ID],"entry":{"id","available","reason"}}], "bases": {依据ID: {...}}}
	# 目标编号为空表示无目标或调查结束。
	return {}


func prepare_review() -> Variant:
	# 准备打开调查回顾。返回 true 成功、false 失败；返回 null 表示异步准备中，之后由导航服务的 complete_review 收尾。
	return true


func end_review() -> void:
	# 回顾关闭（返回调查）。
	pass


func read_basis(_basis_id: String) -> Variant:
	# 读取一份准确依据，供单份阅读。成功返回 {"ok": true, "doc": {"id","kind","title","version_text","body","sources":[{"id","title"}]}}，
	# 失败返回 {"ok": false}；返回 null 表示异步准备中，之后由 complete_read 收尾。阅读成功可在此沿原模块更新已读。
	return {"ok": false}


func recheck_entry(_entry_id: String) -> Dictionary:
	# 点击【前往核对】时再次检查入口，返回 {"available": bool, "reason": String}。
	return {"available": false, "reason": ""}


func go_entry(_entry_id: String) -> Dictionary:
	# 前往调查入口。成功必须已经结束回顾占用并进入入口；失败必须保持回顾原状。返回 {"ok": bool, "reason": String}。
	return {"ok": false, "reason": ""}
