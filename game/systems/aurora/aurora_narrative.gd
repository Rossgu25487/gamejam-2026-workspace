extends "res://systems/narrative/narrative_service.gd"
## 沿用逐字、分页、记录、快读与已看登记；正式接续交由同一会话执行器处理。
const InvestigationScript = preload("res://systems/aurora/aurora_investigation.gd")
var session: Node
var available_choices: Array = []
var conversation: RefCounted

func _begin_text(id: String) -> void:
	# 无正文菜单只承担操作，不能变成听过的原话或污染跨重启快读登记。
	super._begin_text(id)
	if id == "__CONTROL__":
		state.history.erase(id)
		if not state.visible_history.is_empty(): state.visible_history.pop_back()
	if session != null and session.case_state.data.ending_started:
		session.ending_checkpoint_requested.emit()

func _progressed() -> void:
	if state.get("current_text_id") == "__CONTROL__": progressed.emit(visible_text(), is_typing())
	else: super._progressed()

func export_snapshot() -> Dictionary:
	var result := super.export_snapshot()
	result["choices"] = available_choices.duplicate(true)
	result["control_label"] = str(catalog.data.texts.get("__CONTROL__", {}).get("text", ""))
	return result

func validate_snapshot(snapshot: Dictionary) -> bool:
	if not snapshot.get("choices", []) is Array: return false
	if snapshot.get("state", {}).get("current_text_id") == "__CONTROL__":
		catalog.data.texts["__CONTROL__"] = _control_record()
		catalog.data.texts["__CONTROL__"].text = str(snapshot.get("control_label", ""))
	for jump in snapshot.get("choices", []):
		if not jump is Dictionary or not jump.has("target_kind") or not jump.has("target_ref"): return false
	return super.validate_snapshot(snapshot)

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot): return false
	available_choices = snapshot.get("choices", []).duplicate(true)
	var restored := super.restore_snapshot(snapshot)
	if restored and state.get("waiting_for_choice", false): show_choices(available_choices)
	return restored

func configure_formal(value: Node) -> void:
	session = value
	conversation = preload("res://systems/aurora/aurora_conversation.gd").new()
	conversation.bind(session)
	catalog.data = {"texts": {}, "chapters": session.config.chapters, "scenes": {}, "avatars": {}, "transitions": {}}
	for id in session.config.texts:
		var row: Dictionary = session.config.texts[id].duplicate(true)
		row["text_type"] = {"chapter_title": "章节字幕", "time_caption": "时间字幕"}.get(row.text_kind, row.text_kind)
		row["avatar_path"] = row.portrait_path
		row["avatar_id"] = row.avatar_ref
		row["scene_id"] = ""
		catalog.data.texts[id] = row
		if not str(row.avatar_ref).is_empty(): catalog.data.avatars[row.avatar_ref] = {"path": row.avatar_ref}

func show_text(id: String) -> bool:
	if not catalog.data.texts.has(id): return false
	var row: Dictionary = catalog.data.texts[id]
	row.scene_id = session.display_scene()
	var background: String = session.background_path()
	# 固定回忆图沿片段地点关联；caller反馈不能把玩家拉回编辑表中的旧场景。
	if not background.is_empty(): row.background_path = background
	_mark_stage_clearing(row)
	_attach_scene_layers(row)
	row.erase("conversation_actor")
	conversation.apply(row)
	available_choices.clear()
	catalog.data.transitions.clear()
	for jump in session.config.jumps.get(id, []):
		if jump.trigger == "continue" and jump.target_kind == "text" and str(jump.get("condition_id", "")).is_empty() and str(jump.get("event_id", "")).is_empty():
			catalog.data.transitions[str(catalog.data.transitions.size())] = {"source_text_id": id, "target_text_id": jump.target_ref, "transition_type": "single"}
	if state.is_empty(): return start(id)
	_begin_text(id)
	return true

func _finish_current_text() -> bool:
	if state.get("finished", false): return false
	var row := current_record()
	var id := str(state.current_text_id)
	if not session.config.texts.has(id): return false
	# 原ID可能同时是分页第一段；该身份的全局已看也要等待末页，不能快显便提前登记。
	if not _is_page_group_intermediate(id): _register_read(id, row)
	text_finished.emit(row.duplicate(true))
	# 分页组的首段可能仍使用原文本 ID，但原文本的取得与完成回执必须等组内最后一页。
	# 页面本身仍写入叙事已读记录，避免玩家再次进入时丢失实际阅读进度。
	if not _is_page_group_intermediate(id):
		session.case_state.finish_text(row)
		for group in session.config.narrative_bindings("text_page_groups"):
			if str(group.get("completion_text_ref", "")) != id: continue
			var owner := str(group.get("text_id", ""))
			if session.config.texts.has(owner):
				session.case_state.finish_text(session.config.texts[owner])
				_register_read(owner, session.config.texts[owner])
	# 六稿正文在同一次认款结束只挂了认款事件，核心表同时要求纸带核对事件。
	# 两张实物已出示且完整回应实际读完，才补交这一已配置结果；不改原件或对白。
	if id == "TXT_CH02_0699" and session.response_active and session.question == "L03_R03":
		if not session.case_state.event("EV_PAPER_BAND_MATCHED", session.source_context()): return false
	# 六稿表声明了信件已出示事件，却遗漏其正文挂点；两段出示交谈
	# 完整读完才开放信件，阅读器仍单独提交E20实际读完回执。
	if id == "TXT_CH03_0527" and session.active_entry == "ENTRY_CH03_VERA_LETTERS":
		if not session.case_state.event("EV_VERA_LETTERS_SHOWN", session.source_context()): return false
	if id == "TXT_CH03_8006" and row.get("sequence_id") == "SEQ_CH03_LEDGER_HANDOVER":
		if not session.case_state.event("EV_NINA_LEDGER_REMAINS_OFFERED", session.source_context()): return false
	# 薇拉先读过旧供述的替代分支同样听完尤里核认，不能漏掉首分支的事实回执。
	if id == "TXT_CH03_0660" and session.active_entry == "ENTRY_CH03_L07_WRENCH":
		if not session.case_state.event("EV_YURI_OLD_STATEMENT_CONFIRMED", session.source_context()): return false
	if id == "TXT_CH03_0589" and session.active_entry == "ENTRY_CH03_L09_WRITER_FIRST":
		if not session.case_state.event("EV_CH03_REGISTER_ACCOUNT_HEARD", session.source_context()): return false
		return session.activate_entry("ENTRY_CH03_L09_AFTER_BASIC")
	if id == "TXT_CH03_0635" and session.response_active and session.question == "L11_R02":
		if not session.case_state.event("EV_CH03_L11_DOCUMENT_SCOPE_CONFIRMED", session.source_context()): return false
	if not session.on_text_finished(id): return false
	return session.finish_text(id)

func _register_read(id: String, row: Dictionary) -> void:
	var version := int(row.get("read_version", 1))
	if id not in state.read_text_ids: state.read_text_ids.append(id)
	state.read_versions[id] = maxi(int(state.read_versions.get(id, 0)), version)
	if int(seen_versions.get(id, 0)) < version:
		seen_versions[id] = version
		_persist_seen()

func _is_page_group_intermediate(id: String) -> bool:
	for group in session.config.narrative_bindings("text_page_groups"):
		var pages: Array = group.get("page_text_refs", [])
		if id in pages and str(group.get("completion_text_ref", "")) != id: return true
	return false

func show_control_choices(rows: Array) -> void:
	# 无正文入口也必须发出新舞台记录，避免点床时还显示大厅的旧对话。
	# 空正文不显示程序入口名；清除旧人物，且不登记为玩家已听过的原话。
	var id := "__CONTROL__"
	catalog.data.texts[id] = _control_record()
	if state.is_empty(): start(id)
	else: _begin_text(id)
	show_choices(rows)

func _control_record() -> Dictionary:
	# 快照校验和恢复也重建同一地点背景，不能把菜单退化成没有舞台的文字记录。
	var record := {"text_id": "__CONTROL__", "text": "", "text_type": "narration", "read_version": 1,
		"font_color": "#FFFFFF", "scene_id": session.display_scene(), "background_path": session.background_path(), "clear_positions": true}
	_attach_scene_layers(record)
	return record

func _mark_stage_clearing(row: Dictionary) -> void:
	# 上一轮阅读已结束后重新开始，必然是新的一幕，旧舞台人物不能带过来；
	# 同一轮里换到新片段时，才按该片段的“清空人物位”决定。
	var fresh := state.is_empty() or bool(state.get("finished", false))
	var sequence := str(row.get("sequence_id", ""))
	var new_sequence := fresh or sequence != str(current_record().get("sequence_id", ""))
	row["clear_positions"] = fresh or (new_sequence and bool(session.config.sequences.get(sequence, {}).get("clear_positions", false)))

func _attach_scene_layers(row: Dictionary) -> void:
	# 调用者地点的对话沿用调查画面的人物与物件图层，站定的人不会因为打开对话框而换成另一处的立绘；
	# 固定地点和回忆片段有自己的画面，不叠加。
	row.erase("scene_layers")
	if str(session.config.entries.get(session.active_entry, {}).get("location_mode", "caller")) != "caller": return
	var model := InvestigationScript.new()
	model.bind(session)
	var layers: Array = []
	for layer in model.image_layers(session.investigation_view()):
		var path := str(layer.image_path)
		# 第0层是调查页替换底图的整屏背景，不是叠加图层。
		if int(layer.get("draw_layer", 0)) <= 0 or layer.get("image_role") == "background":
			row["background_path"] = path
			row["embedded_actor_refs"] = layer.get("embedded_actor_refs", []).duplicate()
			continue
		var who := str(layer.get("object_ref", ""))
		layers.append({"image_path": path, "x": float(layer.image_x), "y": float(layer.image_y), "w": float(layer.image_w), "h": float(layer.image_h),
			"flip_h": bool(layer.get("flip_h", false)), "character_id": who if session.config.actors.has(who) else ""})
	# 独立物件按资源表坐标叠加；固定局部底图已经由 background_path 提供。
	var resource: Dictionary = model.view_resource(session.investigation_view())
	if resource.get("view_kind") == "object_detail":
		layers.append({"image_path": resource.resource_or_text_ref, "x": resource.display_x, "y": resource.display_y,
			"w": resource.display_w, "h": resource.display_h, "character_id": ""})
	row["scene_layers"] = layers

func show_choices(rows: Array) -> void:
	available_choices = rows.duplicate(true)
	catalog.data.transitions.clear()
	for i in range(rows.size()):
		catalog.data.transitions[str(i)] = {"source_text_id": state.current_text_id, "transition_type": "choice", "choice_text": session.choice_label(rows[i])}
	state.waiting_for_choice = true
	state.typing = false
	stop_fast_read()
	_changed()

func choose_transition(index: int) -> bool:
	if not state.get("waiting_for_choice", false) or index < 0 or index >= available_choices.size(): return false
	var jump: Dictionary = available_choices[index].duplicate(true)
	state.waiting_for_choice = false
	return session.follow(jump)

func end_reading() -> void:
	if state.is_empty(): return
	state.finished = true
	state.typing = false
	state.waiting_for_choice = false
	stop_fast_read()
	_changed()
