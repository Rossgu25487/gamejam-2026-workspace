extends "res://systems/objective/objective_provider.gd"
## 正式案表适配既有HUD与分区回顾；进度、依据和前往资格均读取同一会话。
var session: Node
var reviewing := false
var docs := {}
var routes := {}
var serial := 0
var parent_mode := ""

func bind(value: Node) -> void:
	session = value
	session.changed.connect(func(): objective_changed.emit())

func objective_snapshot() -> Dictionary:
	routes.clear()
	var goals: Array = session.config.rows("objective", "正式目标").duplicate()
	goals.sort_custom(func(a, b): return int(a.display_order) < int(b.display_order))
	for goal in goals:
		if not session.condition(str(goal.condition_id)): continue
		var end := str(goal.get("end_condition_id", ""))
		if not end.is_empty() and session.condition(end): continue
		var items: Array = []
		var bases := {}
		for row in session.config.rows("objective", "正式事项"):
			if row.goal_id != goal.goal_id or not session.condition(str(row.get("condition_id", ""))): continue
			var done: bool = session.condition(str(row.completion_condition_id))
			var refs: Array = []
			for id in session.config.ids(str(row.get("basis_ids", ""))):
				for basis in session.config.rows("objective", "正式依据"):
					var content := str(basis.content_id)
					if basis.basis_id != id or not session.case_state.owns(content): continue
					var info: Dictionary = session.config.contents[content]
					var sources: Array = session.case_state.data.materials[info.material_id].versions[content]
					bases[id] = {"id": id, "kind": "material", "name": info.name, "version_text": "第%d版" % int(info.version), "has_original": true, "has_source": not sources.is_empty()}
					refs.append(id)
			var route: Dictionary = session.check_objective_route(row)
			if reviewing and parent_mode != "investigation":
				route = {"ok": false, "reason": "请先返回调查主视图，再前往核对。"}
			var entry := {}
			if not str(row.get("target_ref", "")).is_empty():
				routes[str(row.item_id)] = row
				entry = {"id": row.item_id, "available": route.ok, "reason": route.reason}
			items.append({"id": row.item_id, "order": int(row.display_order), "text": row.text, "status": "checked" if done else "pending", "reason": "" if done or route.ok else route.reason, "basis": refs, "entry": entry,
				"scene_id": str(row.get("scene_id", "")), "view_id": str(row.get("view_id", "")), "target_kind": str(row.get("target_kind", "")), "target_ref": str(row.get("target_ref", ""))})
		var done_count := 0
		for item in items:
			if item["status"] == "checked": done_count += 1
		return {"goal_id": goal.goal_id, "goal_text": goal.text, "items": items, "bases": bases,
			"progress": {"done": done_count, "total": items.size(), "text": "%02d/%02d" % [done_count, items.size()]},
			"current_scene_id": str(session.case_state.data.scene)}
	return {}

func prepare_review() -> Variant:
	if reviewing or session.mode not in ["investigation", "selection", "narrative", "result", "failure", "material"] or session.processing: return false
	reviewing = true
	parent_mode = str(session.mode)
	docs.clear()
	serial = 0
	objective_changed.emit()
	return true

func end_review() -> void:
	reviewing = false
	parent_mode = ""
	docs.clear()

func read_basis(id: String) -> Variant:
	if not reviewing: return {"ok": false}
	if docs.has(id): return {"ok": true, "doc": docs[id]}
	for row in session.config.rows("objective", "正式依据"):
		if row.basis_id != id or not session.case_state.owns(str(row.content_id)): continue
		var content: Dictionary = session.config.contents[row.content_id]
		var record: Dictionary = session.case_state.data.materials[content.material_id]
		record.read[str(row.content_id)] = true
		var doc := _material(str(row.content_id), record.versions[row.content_id])
		doc.id = id
		docs[id] = doc
		return {"ok": true, "doc": doc}
	return {"ok": false}

func _material(id: String, sources: Array) -> Dictionary:
	var content: Dictionary = session.config.contents[id]
	return {"id": id, "kind": "material", "title": content.name, "version_text": "第%d版" % int(content.version), "body": content.detail_text, "sources": _sources(sources)}

func _sources(sources: Array) -> Array:
	var result: Array = []
	for source in sources:
		var title: String = session.entry_label(str(source.get("entry", ""))) if source.has("entry") else "核查 · " + str(source.get("question", ""))
		var children: Array = []
		for basis in source.get("sources", []):
			var id := str(basis.get("content_id", ""))
			if session.config.contents.has(id): children.append(_register(_material(id, basis.get("sources", []))))
		var body: String = session.config.text(str(source.text)) if session.config.texts.has(str(source.get("text", ""))) else title
		result.append(_register({"id": "", "kind": "source", "title": title, "version_text": "", "body": body, "sources": children}))
	return result

func _register(doc: Dictionary) -> Dictionary:
	serial += 1
	var id := "formal_source_%d" % serial
	doc.id = id
	docs[id] = doc
	return {"id": id, "title": doc.title}

func recheck_entry(id: String) -> Dictionary:
	if parent_mode != "investigation" or session.mode != "investigation": return {"available": false, "reason": "请先返回调查主视图，再前往核对。"}
	var route: Dictionary = session.check_objective_route(routes.get(id, {}))
	return {"available": route.ok, "reason": route.reason}

func go_entry(id: String) -> Dictionary:
	if parent_mode != "investigation" or session.mode != "investigation": return {"ok": false, "reason": "请先返回调查主视图，再前往核对。"}
	var row: Dictionary = routes.get(id, {})
	if not session.go_objective(row): return {"ok": false, "reason": str(row.get("public_reason", "当前还不能前往。"))}
	end_review()
	return {"ok": true}
