extends "res://systems/objective/objective_provider.gd"
## 案件目标提供方：从案件配置的 objectives 与核心玩法已有的记录推导目标显示结果。
## 不另存一份进度：事项是否核查沿核心的条件判定，依据只列玩家已取得或已听到的准确对象。
## 回顾期间借用核心的检视占用（期间不能新建存档），关闭或前往入口时归还。

var core: Node
var _docs: Dictionary = {} # 本次回顾内来源层的读取内容
var _serial := 0
var _reviewing := false


func bind_core(core_service: Node) -> void:
	core = core_service
	core.changed.connect(func(): objective_changed.emit())


func _config() -> Dictionary:
	return core.catalog.data.get("objectives", {}) if core != null else {}


# ---------- 目标显示结果 ----------

func objective_snapshot() -> Dictionary:
	if core == null or core.state.is_empty():
		return {}
	var config := _config()
	for goal in config.get("goals", []):
		if not core.condition_met(String(goal["visible"])):
			continue
		var closed := String(goal.get("closed", ""))
		if not closed.is_empty() and core.condition_met(closed):
			continue
		return _goal_snapshot(goal, config)
	return {}


func _goal_snapshot(goal: Dictionary, config: Dictionary) -> Dictionary:
	var items: Array = []
	var bases: Dictionary = {}
	var order := 0
	for item in goal.get("items", []):
		var public := String(item.get("public", ""))
		if not public.is_empty() and not core.condition_met(public):
			continue
		order += 1
		var done: bool = core.condition_met(String(item["done"]))
		var entry := {}
		var reason := ""
		var go: Dictionary = item.get("go", {})
		if not go.is_empty():
			var available := _go_available(go)
			var why: String = "" if available else _blocked_reason(go)
			entry = {"id": "%s:%s" % [go["kind"], go["id"]], "available": available, "reason": why}
			if not done:
				reason = why # 暂时无法继续时在目标里显示已公开原因
		var refs: Array = []
		for basis_id in item.get("basis", []):
			var info := _basis_info(String(basis_id), config["bases"][basis_id])
			if not info.is_empty():
				bases[String(basis_id)] = info
				refs.append(String(basis_id))
		items.append({"id": item["id"], "order": order, "text": core.catalog.text(String(item["text"])), "status": "checked" if done else "pending", "reason": reason, "basis": refs, "entry": entry})
	return {"goal_id": goal["id"], "goal_text": core.catalog.text(String(goal["text"])), "items": items, "bases": bases}


func _go_available(go: Dictionary) -> bool:
	var table: Dictionary = core.catalog.data.entries if String(go["kind"]) == "entry" else core.catalog.data.questions
	var record: Dictionary = table.get(go["id"], {})
	if record.is_empty() or not core.condition_met(String(record["condition"])): return false
	# 事项与依据仍可阅读，异地入口必须先沿地图到达，不能显示可前往后再由核心拒绝。
	return String(record.get("scene_id", "")).is_empty() or record.scene_id == core.state.current_scene_id


func _basis_info(id: String, config: Dictionary) -> Dictionary:
	# 只列已经取得的材料版本或已经听到的原话；没有取得的不在回顾里出现。
	if String(config["kind"]) == "material":
		var ref: Dictionary = core.catalog.material_ref(String(config["content_id"]))
		if not core.store.owns(ref):
			return {}
		var content: Dictionary = core.catalog.data.contents[ref["content_id"]]
		return {"id": id, "kind": "material", "name": core.catalog.text(String(content["title"])), "version_text": _version(content), "has_original": true, "has_source": not core.store.sources(ref).is_empty()}
	var statement: Dictionary = core.catalog.data.statements[config["statement_id"]]
	if not (config["statement_id"] in core.state.heard_statements):
		return {}
	var record_ref: Dictionary = core.catalog.material_ref(String(statement["record_content"]))
	return {"id": id, "kind": "quote", "name": _speaker(statement), "version_text": "第%d版" % int(statement["version"]), "has_original": true, "has_source": core.store.owns(record_ref)}


func _version(content: Dictionary) -> String:
	return "第%d版" % int(content["version"])


func _speaker(statement: Dictionary) -> String:
	var characters: Dictionary = core.catalog.data.get("characters", {})
	var speaker := String(statement["speaker"])
	return core.catalog.text(String(characters[speaker]["name"])) if characters.has(speaker) else speaker


# ---------- 回顾与阅读 ----------

func prepare_review() -> Variant:
	# 准备成功才切页：借用核心的检视占用；失败时原页保持，核心已给出原因提示。
	if core == null or _reviewing or not core.begin_inspection():
		return false
	_reviewing = true
	_docs.clear()
	_serial = 0
	return true


func end_review() -> void:
	if _reviewing:
		_reviewing = false
		core.end_inspection()
	_docs.clear()


func read_basis(basis_id: String) -> Variant:
	if core == null or not _reviewing:
		return {"ok": false}
	if _docs.has(basis_id):
		return {"ok": true, "doc": _docs[basis_id]}
	var bases: Dictionary = _config().get("bases", {})
	if not bases.has(basis_id):
		return {"ok": false}
	var doc := _document(basis_id, bases[basis_id])
	if doc.is_empty():
		return {"ok": false}
	_docs[basis_id] = doc # 同一次回顾内再次阅读直接复用，不重复标记已读
	return {"ok": true, "doc": doc}


func _document(id: String, config: Dictionary) -> Dictionary:
	# 读取准确的材料版本或当时原话；阅读成功沿核心更新已读，不推进目标也不收下推论。
	if String(config["kind"]) == "material":
		var ref: Dictionary = core.catalog.material_ref(String(config["content_id"]))
		if not core.store.owns(ref):
			return {}
		core.mark_read(ref)
		return _material_doc(id, ref, core.store.sources(ref))
	var statement: Dictionary = core.catalog.data.statements[config["statement_id"]]
	if not (config["statement_id"] in core.state.heard_statements):
		return {}
	var sources: Array = []
	var record_ref: Dictionary = core.catalog.material_ref(String(statement["record_content"]))
	if core.store.owns(record_ref):
		sources.append(_register(_material_doc("", record_ref, [])))
	return {"id": id, "kind": "quote", "title": _speaker(statement), "version_text": "第%d版" % int(statement["version"]), "body": core.catalog.text(String(statement["text"])), "sources": sources}


func _material_doc(id: String, ref: Dictionary, sources: Array) -> Dictionary:
	var content: Dictionary = core.catalog.data.contents[ref["content_id"]]
	return {"id": id, "kind": "material", "title": core.catalog.text(String(content["title"])), "version_text": _version(content), "body": core.catalog.text(String(content["body"])), "sources": _listed(sources)}


func _listed(sources: Array) -> Array:
	var listed: Array = []
	for source in sources:
		var doc := _source_doc(source)
		if not doc.is_empty():
			listed.append(_register(doc))
	return listed


func _source_doc(source: Dictionary) -> Dictionary:
	# 来源沿材料取得时冻结的路径逐层读取：取得入口、前次确认、形成推论的材料。
	match String(source.get("kind", "")):
		"acquisition":
			var entries: Dictionary = core.catalog.data.entries
			var entry: Dictionary = entries.get(source.get("entry_id", ""), {})
			var title: String = core.catalog.text(String(entry.get("title", ""))) if not entry.is_empty() else String(source.get("source_id", ""))
			return {"id": "", "kind": "source", "title": "取得来源 · " + title, "version_text": "", "body": core.catalog.text(String(source.get("text_id", ""))), "sources": []}
		"material":
			var ref: Dictionary = source.get("ref", {})
			if core.catalog.valid_material_ref(ref):
				return _material_doc("", ref, source.get("sources", []))
		"confirmed":
			var record: Dictionary = source.get("record", {})
			var nodes: Dictionary = core.catalog.data.nodes
			var node: Dictionary = nodes.get(record.get("node", ""), {})
			return {"id": "", "kind": "source", "title": "前次确认 · " + str(record.get("confirmed_scope", "")), "version_text": "", "body": core.catalog.text(String(node.get("text", ""))), "sources": _listed(record.get("used_sources", []))}
	return {}


func _register(doc: Dictionary) -> Dictionary:
	# 来源层的读取内容留在本次回顾内，用稳定的临时编号按需读取。
	_serial += 1
	var id := "src:%d" % _serial
	doc["id"] = id
	_docs[id] = doc
	return {"id": id, "title": doc["title"]}


# ---------- 前往核对 ----------

func recheck_entry(entry_id: String) -> Dictionary:
	var go := _parse(entry_id)
	if go.is_empty():
		return {"available": false, "reason": ""}
	var available := _go_available(go)
	return {"available": available, "reason": "" if available else _blocked_reason(go)}


func _blocked_reason(go: Dictionary) -> String:
	var table: Dictionary = core.catalog.data.entries if String(go["kind"]) == "entry" else core.catalog.data.questions
	var record: Dictionary = table.get(go["id"], {})
	if not String(record.get("scene_id", "")).is_empty() and record.scene_id != core.state.current_scene_id:
		return core.ui("UI_OBJECTIVE_NO_ROUTE") # 沿唯一功能文字源，不泄露尚未公开的地点名称。
	for goal in _config().get("goals", []):
		for item in goal.get("items", []):
			var target: Dictionary = item.get("go", {})
			if not target.is_empty() and target["kind"] == go["kind"] and target["id"] == go["id"]:
				return core.catalog.text(String(item.get("blocked_reason", "")))
	return ""


func _parse(entry_id: String) -> Dictionary:
	var parts := entry_id.split(":", false, 1)
	if parts.size() != 2 or not ["entry", "question"].has(parts[0]):
		return {}
	return {"kind": parts[0], "id": parts[1]}


func go_entry(entry_id: String) -> Dictionary:
	# 前往调查入口：先结束回顾占用，入口才允许进入；失败时归还占用，回顾保持原状。
	var go := _parse(entry_id)
	if core == null or not _reviewing or go.is_empty():
		return {"ok": false, "reason": ""}
	if not _go_available(go): return {"ok": false, "reason": _blocked_reason(go)}
	core.end_inspection()
	var entered := false
	if go["kind"] == "entry":
		entered = core.activate_entry(String(go["id"]))
	else:
		entered = core.open_card_session(String(go["id"]), {"page": "investigation", "focus_key": go["id"], "scene_id": core.state.get("current_scene_id", "")})
	if not entered:
		core.begin_inspection()
		return {"ok": false, "reason": _blocked_reason(go)}
	_reviewing = false
	_docs.clear()
	return {"ok": true, "reason": ""}
