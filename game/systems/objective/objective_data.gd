extends RefCounted
## 目标显示数据：校验并规范化提供方一次给出的同一份目标显示结果，HUD 与回顾共同读取。
## 目标编号为空是正常的无目标输入；有编号却缺主目标文字、事项编号重复或事项状态缺失时，接入检查报错。

const STATUSES := ["pending", "checked"]


static func normalize(raw: Dictionary) -> Dictionary:
	# 返回 {"ok": bool, "errors": Array[String], "goal": Dictionary}；无目标时 ok 为真且 goal 为空。
	var errors: Array[String] = []
	var goal_id := String(raw.get("goal_id", "")).strip_edges()
	if goal_id.is_empty():
		return {"ok": true, "errors": errors, "goal": {}}
	var goal_text := String(raw.get("goal_text", "")).strip_edges()
	if goal_text.is_empty():
		errors.append("目标 %s 缺少主目标文字" % goal_id)
	var bases := _normalize_bases(raw.get("bases", {}), errors)
	var items: Array = []
	var seen_ids := {}
	var seen_orders := {}
	var position := 0
	for source in raw.get("items", []):
		position += 1
		if not source is Dictionary:
			errors.append("事项格式无效（第 %d 项）" % position)
			continue
		var item := _normalize_item(source, position, bases, errors)
		if item.is_empty():
			continue
		if seen_ids.has(item["id"]):
			errors.append("事项编号重复：" + String(item["id"]))
		seen_ids[item["id"]] = true
		if seen_orders.has(item["order"]):
			errors.append("事项顺序重复：" + str(item["order"]))
		seen_orders[item["order"]] = true
		items.append(item)
	if not errors.is_empty():
		return {"ok": false, "errors": errors, "goal": {}}
	# 顺序由提供方给出；按顺序号排列，顺序号相同的情形已在上面报错。
	items.sort_custom(func(a, b): return int(a["order"]) < int(b["order"]))
	var progress: Dictionary = raw.get("progress", {}) if raw.get("progress", {}) is Dictionary else {}
	return {"ok": true, "errors": errors, "goal": {"goal_id": goal_id, "goal_text": goal_text, "items": items, "bases": bases,
		"progress": {"done": int(progress.get("done", _count_checked(items))), "total": int(progress.get("total", items.size())), "text": String(progress.get("text", "%02d/%02d" % [int(progress.get("done", _count_checked(items))), int(progress.get("total", items.size()))]))},
		"current_scene_id": String(raw.get("current_scene_id", ""))}}

static func _count_checked(items: Array) -> int:
	var count := 0
	for item in items:
		if String(item.get("status", "")) == "checked": count += 1
	return count


static func _normalize_item(source: Dictionary, position: int, bases: Dictionary, errors: Array[String]) -> Dictionary:
	var id := String(source.get("id", "")).strip_edges()
	if id.is_empty():
		errors.append("事项缺少编号（第 %d 项）" % position)
		return {}
	var status := String(source.get("status", ""))
	if not STATUSES.has(status):
		errors.append("事项 %s 的状态缺失或无效" % id)
	var text := String(source.get("text", "")).strip_edges()
	if text.is_empty():
		errors.append("事项 %s 缺少全文" % id)
	var refs: Array[String] = []
	for ref in source.get("basis", []):
		var basis_id := String(ref)
		if not bases.has(basis_id):
			errors.append("事项 %s 引用了不存在的依据 %s" % [id, basis_id])
		refs.append(basis_id)
	var entry := {}
	var raw_entry = source.get("entry", {})
	if raw_entry is Dictionary and not raw_entry.is_empty():
		var entry_id := String(raw_entry.get("id", "")).strip_edges()
		if entry_id.is_empty():
			errors.append("事项 %s 的调查入口缺少编号" % id)
		entry = {"id": entry_id, "available": bool(raw_entry.get("available", false)), "reason": String(raw_entry.get("reason", ""))}
	return {
		"id": id, "order": int(source.get("order", position)), "text": text, "status": status,
		"reason": String(source.get("reason", "")), "basis": refs, "entry": entry,
		"scene_id": String(source.get("scene_id", "")), "view_id": String(source.get("view_id", "")),
		"target_kind": String(source.get("target_kind", "")), "target_ref": String(source.get("target_ref", "")),
	}


static func _normalize_bases(raw: Dictionary, errors: Array[String]) -> Dictionary:
	var bases := {}
	for key in raw.keys():
		var base: Dictionary = raw[key]
		var id := String(base.get("id", key))
		bases[id] = {
			"id": id,
			"kind": String(base.get("kind", "")),
			"name": String(base.get("name", "")),
			"version_text": String(base.get("version_text", "")),
			"has_original": bool(base.get("has_original", true)),
			"has_source": bool(base.get("has_source", not String(base.get("source_id", "")).is_empty())),
		}
	return bases


static func pending_items(goal: Dictionary) -> Array:
	# HUD 只列待核项，保持提供方给出的顺序；全部已核查时为空。
	return _by_status(goal, "pending")


static func checked_items(goal: Dictionary) -> Array:
	return _by_status(goal, "checked")


static func _by_status(goal: Dictionary, status: String) -> Array:
	var result: Array = []
	for item in goal.get("items", []):
		if item["status"] == status:
			result.append(item)
	return result


static func item_ids(items: Array) -> Array[String]:
	var ids: Array[String] = []
	for item in items:
		ids.append(String(item["id"]))
	return ids


static func find_item(goal: Dictionary, id: String) -> Dictionary:
	for item in goal.get("items", []):
		if item["id"] == id:
			return item
	return {}


static func neighbor_id(old_ids: Array, removed_id: String, new_ids: Array) -> String:
	# 当前事项被移除：定位原顺序的后一项，没有则前一项；本区为空返回空串。
	var at := old_ids.find(removed_id)
	if at < 0:
		return String(new_ids[0]) if not new_ids.is_empty() else ""
	for i in range(at + 1, old_ids.size()):
		if new_ids.has(old_ids[i]):
			return String(old_ids[i])
	for i in range(at - 1, -1, -1):
		if new_ids.has(old_ids[i]):
			return String(old_ids[i])
	return ""


static func content_signature(goal: Dictionary) -> String:
	# 决定是否重复提示：目标、主目标、事项顺序与全文、状态和公开原因完全相同则视为同一内容。
	if goal.is_empty():
		return ""
	var parts: Array = [goal["goal_id"], goal["goal_text"]]
	for item in goal["items"]:
		parts.append([item["id"], item["order"], item["text"], item["status"], item["reason"]])
	return JSON.stringify(parts)


static func full_signature(goal: Dictionary) -> String:
	# 回顾还读取依据与入口；任一变化都需要刷新回顾，但不一定提示。
	if goal.is_empty():
		return ""
	var parts: Array = [content_signature(goal)]
	for item in goal["items"]:
		parts.append([item["basis"], item["entry"]])
	parts.append(goal["bases"])
	return JSON.stringify(parts)
