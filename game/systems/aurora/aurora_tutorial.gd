extends Node
## 联合引导只观察真实业务状态并过滤输入，不代替调查、选牌或出示执行操作。
## 步骤完成记录归当前案件存档；高亮的点击范围始终由原控件判断。
signal changed
signal first_card_feedback_requested(content_id: String, animation_ms: int, hold_ms: int, text: String)
var session: Node
var gameplay: Control
var map_service: Node
var current_step: Dictionary = {}
var definition: Dictionary = {}
var enabled := true
var feedback_left := 0.0
var feedback_content := ""
var last_run := ""
var previous_owns_first := false
var _feedback_had_log := false
var _press_binding: Dictionary = {}
var _armed: Dictionary = {}

func bind(value: Node, page: Control, map_value: Node) -> void:
	session = value
	gameplay = page
	map_service = map_value
	definition = session.config.tutorial_data.duplicate(true)
	last_run = str(session.run_id)
	previous_owns_first = session.case_state.owns("E01_V1") if not session.case_state.data.is_empty() else false
	if not session.changed.is_connected(refresh): session.changed.connect(refresh)
	if not session.narrative.changed.is_connected(refresh): session.narrative.changed.connect(refresh)
	if map_service != null and not map_service.changed.is_connected(refresh): map_service.changed.connect(refresh)
	refresh()

func _process(delta: float) -> void:
	if session == null or not is_instance_valid(gameplay): return
	if not is_finite(delta) or delta < 0: return
	if feedback_left > 0 and gameplay.is_visible_in_tree() and not session.paused:
		feedback_left = maxf(0, feedback_left - delta)
		if feedback_left == 0: _finish_feedback()
	refresh()

func refresh() -> void:
	if session == null or not is_instance_valid(gameplay) or session.case_state.data.is_empty(): return
	if last_run != str(session.run_id):
		_finish_feedback()
		last_run = str(session.run_id)
		previous_owns_first = false
		_press_binding.clear()
		_armed.clear()
	_check_first_card()
	if not enabled or not gameplay.is_visible_in_tree() or session.paused or feedback_left > 0:
		_set_step({})
		return
	_complete_observed_steps()
	var next := _choose_step()
	_set_step(next)

func step_key(step: Dictionary) -> String:
	return str(step.get("group_id", "")) + ":" + str(int(step.get("step", 0)))

func completed(step: Dictionary) -> bool:
	return session.case_state.data.get("tutorial_completed_steps", []).has(step_key(step))

func _mark(step: Dictionary) -> void:
	var key := step_key(step)
	if key.is_empty() or completed(step): return
	var steps: Array = session.case_state.data.get("tutorial_completed_steps", [])
	steps.append(key)
	session.case_state.data.tutorial_completed_steps = steps

func _set_step(step: Dictionary) -> void:
	if step_key(current_step) == step_key(step) and str(current_step.get("target_ref", "")) == str(step.get("target_ref", "")): return
	current_step = step.duplicate(true)
	if not step.is_empty(): _armed[step_key(step)] = step.duplicate(true)
	changed.emit()

func _complete_observed_steps() -> void:
	# 仅已启动的步骤可被本次业务回执完成；打开遮罩、悬停和点亮均不算成功。
	if not current_step.is_empty() and _succeeded(current_step): _mark(current_step)
	for key in _armed.keys():
		var step: Dictionary = _armed[key]
		if _succeeded(step):
			_mark(step)
			_armed.erase(key)
	# 收下归位会跨入后续对白，仍以实际持有且归位已结束为回执。
	for step in definition.get("steps", []):
		if step.get("completion_kind") == "inference_accepted" and _succeeded(step): _mark(step)
	if not _press_binding.is_empty():
		var event_id := str(_press_binding.get("completion_event_ref", ""))
		if session.case_state.data.events.get(event_id, false) and session.mode == "selection" and str(session.current_statement) == str(_press_binding.target_text_ref) and session.question_reading.is_empty():
			_mark({"group_id": "TUT_PRESS_FIRST", "step": 2})

func _choose_step() -> Dictionary:
	if session.processing or session.mode in ["narrative", "material", "cat", "credits"]: return {}
	var reader: Control = gameplay.get("reader_page")
	if is_instance_valid(reader) and reader.visible: return _manual_step(reader)
	var map_page: Control = gameplay.get("map_page")
	if is_instance_valid(map_page) and map_page.visible: return _map_step(map_page)
	if session.mode == "selection":
		var group := "TUT_T00_ONE" if session.question == "T00_R01" else ("TUT_T00_TWO" if session.question == "T00_R02" else "")
		if not group.is_empty(): return _core_step(group)
		return _first_press_step()
	if session.mode == "result":
		for step in definition.get("steps", []):
			if step.get("trigger_kind") == "pending_inference" and not completed(step):
				var result: Dictionary = session.config.results.get(str(session.pending_result.get("result", "")), {})
				if result.get("inference_content_ref") == step.get("trigger_ref") and not session.pending_result.get("accepted", false) and (session.pending_result.get("response_read", false) or session.pending_result.get("response_after_accept", false)) and not session.pending_result.get("effect_pending", false): return step
	if session.mode == "investigation":
		for step in definition.get("steps", []):
			if step.get("trigger_kind") == "scene_ready" and session.case_state.data.scene == step.get("trigger_ref") and not completed(step): return step
	return {}

func _map_step(page: Control) -> Dictionary:
	var steps := _group("TUT_MAP_FIRST")
	if steps.is_empty() or completed(steps.back()): return {}
	# 教学不额外公开目的地；只有真实地图记录已经可前往时才接管。
	var reachable := false
	for record in map_service.location_records():
		if record.get("to_scene") == "SC06" and record.get("available", false): reachable = true
	if not reachable: return {}
	if str(map_service.current_scene_id()) == "SC06": return {}
	if str(page.get("selected_group")) not in ["MAP02", "overview"]: return steps[0]
	if not completed(steps[0]): _mark(steps[0]) # 二楼已实际显示时无需教一次多余切层。
	if str(map_service.state.get("selected_scene_id", "")) != "SC06": return steps[1]
	if not completed(steps[1]): _mark(steps[1])
	if str(map_service.state.get("phase", "")) in ["browsing", "failure"]: return steps[2]
	return {}

func _manual_step(page: Control) -> Dictionary:
	var steps := _group("TUT_MANUAL_FIRST")
	if steps.is_empty() or completed(steps.back()) or session.case_state.data.materials.is_empty(): return {}
	if not str(page.get("reading_content")).is_empty():
		# 正文是手册真实打开的内容，教学不要求读完、返回或下楼。
		_mark(steps[0]); _mark(steps[1]); return {}
	if not _field_string(page, "selected_material").is_empty():
		if not completed(steps[0]): _mark(steps[0])
		return steps[1]
	var step: Dictionary = steps[0].duplicate(true)
	if not session.case_state.owns(str(step.target_ref)):
		var items: Array = session.case_state.data.materials.values()
		items.sort_custom(func(a, b): return int(a.order) < int(b.order))
		step.target_ref = str(items[0].current)
	return step

func _core_step(group: String) -> Dictionary:
	var steps := _group(group)
	if steps.is_empty() or completed(steps.back()): return {}
	if group == "TUT_T00_ONE":
		if not session.selected_target: return steps[0]
		if not completed(steps[0]): _mark(steps[0])
		if not session.slots.has("E28_V1"): return steps[1]
		if not completed(steps[1]): _mark(steps[1])
		return steps[2]
	if not session.slots.has("E01_V1"): return steps[0]
	if not completed(steps[0]): _mark(steps[0])
	if not session.slots.has("E28_V1"): return steps[1]
	if not completed(steps[1]): _mark(steps[1])
	return steps[2]

func _first_press_step() -> Dictionary:
	if completed({"group_id": "TUT_PRESS_FIRST", "step": 2}): return {}
	var options: Array = session.statement_options()
	if options.is_empty() or options.any(func(option): return not bool(option.heard)): return {}
	for binding in definition.get("first_press_bindings", []):
		if not binding.get("enabled", true) or str(binding.get("question_ref", "")) != str(session.question): continue
		_press_binding = binding.duplicate(true)
		if str(session.current_statement) != str(binding.target_text_ref):
			return {"group_id": "TUT_PRESS_FIRST", "step": 1, "target_kind": "text", "target_ref": binding.target_text_ref, "text_ref": "UI_GUIDE_PRESS", "completion_kind": "statement_selected", "completion_ref": binding.target_text_ref, "allow_pause": true, "allow_cancel": false}
		_mark({"group_id": "TUT_PRESS_FIRST", "step": 1})
		return {"group_id": "TUT_PRESS_FIRST", "step": 2, "target_kind": "control", "target_ref": "core.current_press", "text_ref": "UI_GUIDE_PRESS", "completion_kind": "press_response_completed_and_returned", "completion_ref": binding.completion_event_ref, "allow_pause": true, "allow_cancel": false}
	return {}

func _succeeded(step: Dictionary) -> bool:
	var ref := str(step.get("completion_ref", ""))
	match str(step.get("completion_kind", "")):
		"observation_opened": return session.mode == "narrative" and str(session.active_entry) == ref and not session.narrative.state.is_empty()
		"floor_selected":
			var page: Control = gameplay.get("map_page")
			return is_instance_valid(page) and page.visible and str(page.get("selected_group")) == ref
		"destination_selected": return map_service != null and str(map_service.state.get("selected_scene_id", "")) == ref
		"arrived": return str(session.case_state.data.scene) == ref and str(map_service.state.get("phase", "")) in ["arrival_hold", "transitioning", "closed"]
		"material_selected":
			var page: Control = gameplay.get("reader_page")
			return is_instance_valid(page) and not _field_string(page, "selected_material").is_empty()
		"material_detail_opened":
			var page: Control = gameplay.get("reader_page")
			return is_instance_valid(page) and page.visible and not str(page.get("reading_content")).is_empty()
		"target_selected": return session.mode == "selection" and session.selected_target and str(session.current_statement) == ref
		"statement_selected": return session.mode == "selection" and str(session.current_statement) == ref
		"material_inserted": return session.slots.has(ref)
		"presentation_succeeded": return session.pending_result.get("question") == ref and session.pending_result.get("complete", false) and session.pending_result.get("feedback") in ["support", "exclude", "inference"]
		"inference_accepted": return session.case_state.owns(ref) and not session.processing and not session.pending_result.get("effect_pending", false)
		"press_response_completed_and_returned": return session.case_state.data.events.get(ref, false) and session.mode == "selection" and session.question_reading.is_empty()
	return false

func _group(id: String) -> Array:
	var result: Array = []
	for step in definition.get("steps", []):
		if step.get("group_id") == id and step.get("enabled", true): result.append(step)
	result.sort_custom(func(a, b): return int(a.step) < int(b.step))
	return result

func target_control() -> Control:
	if current_step.is_empty() or not is_instance_valid(gameplay): return null
	var root: Node = gameplay
	var kind := str(current_step.get("target_kind", ""))
	if kind == "hotspot": root = gameplay.get("scene_page")
	elif str(current_step.get("group_id", "")).begins_with("TUT_MAP"): root = gameplay.get("map_page")
	elif str(current_step.get("group_id", "")).begins_with("TUT_MANUAL"): root = gameplay.get("reader_page")
	else: root = gameplay.get("card_page")
	return _find_target(root, str(current_step.get("target_ref", "")), kind)

func _find_target(root: Node, ref: String, kind: String) -> Control:
	if root == null: return null
	if root is Control and root.is_visible_in_tree() and not root.is_queued_for_deletion():
		var matches := str(root.get_meta("tutorial_target", "")) == ref or str(root.name) == ref
		if {"CORE_LAYOUT_PRESENT": "PresentMaterials", "core.current_press": "PressStatement", "core.current_accept": "AcceptInference"}.get(ref, "") == str(root.name): matches = true
		if kind == "material" and str(root.name) == "Card_" + ref: matches = true
		if ref.begins_with("map.select_") and str(root.get_meta("scene_id", "")).to_lower() == ref.trim_prefix("map.select_"): matches = true
		if root is BaseButton and root.disabled: matches = false
		if matches: return root
	for child in root.get_children():
		var found := _find_target(child, ref, kind)
		if found != null: return found
	return null

func tutorial_text() -> String:
	return "" if current_step.is_empty() else session.config.text(str(current_step.get("text_ref", "")))

func _field_string(object: Object, field: String) -> String:
	var value = object.get(field)
	return "" if value == null else str(value)

func permits_control(control: Control) -> bool:
	var target := target_control()
	if target != null and (control == target or target.is_ancestor_of(control)): return true
	if not is_instance_valid(control) or not control.is_visible_in_tree(): return false
	if current_step.get("allow_pause", true) and (control.name in ["MenuButton", "PauseButton"] or (control is Button and control.text in ["菜单", "菜单 Esc"])): return true
	if current_step.get("allow_cancel", false) and (str(control.get_meta("tutorial_target", "")) == "map.return" or (control is Button and control.text in ["关闭手册", "返回调查", "取消准备", "返回"])): return true
	# T00允许撤回原草稿，但不允许用其他卡替换指定材料。
	if str(current_step.get("group_id", "")).begins_with("TUT_T00") and control is Button and control.text in ["撤下", "全部撤下"]: return true
	return false

func input_allowed(event: InputEvent) -> bool:
	if current_step.is_empty() and feedback_left <= 0: return true
	if event is InputEventKey:
		if event.keycode == KEY_ESCAPE: return true
		if feedback_left > 0: return false
		# Tab只在当前放行控件之间导航；不让隐藏快捷键绕过教学。
		if event.keycode == KEY_TAB: return false
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]: return permits_control(gameplay.get_viewport().gui_get_focus_owner())
		return false
	if event is InputEventMouse:
		if feedback_left > 0: return false
		var picked := actual_hit_control(gameplay, event.position)
		# 选材步骤只放行卡牌本体，卡内“详情”是另一项真实操作，不能借目标祖先绕过。
		if current_step.get("target_kind") == "material" and str(current_step.get("group_id", "")).begins_with("TUT_T00") and picked != target_control(): return false
		return permits_control(picked) and original_hit(picked, event.position)
	if event is InputEventJoypadButton or event is InputEventJoypadMotion: return false
	return true

func original_hit(control: Control, viewport_point: Vector2) -> bool:
	if not is_instance_valid(control): return false
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is Control and ancestor.clip_contents:
			var clipped_local: Vector2 = ancestor.get_global_transform_with_canvas().affine_inverse() * viewport_point
			if not Rect2(Vector2.ZERO, ancestor.size).has_point(clipped_local): return false
		ancestor = ancestor.get_parent()
	var local: Vector2 = control.get_global_transform_with_canvas().affine_inverse() * viewport_point
	# 自定义多边形/遮挡命中继续走原按钮的规则；光晕不会扩大热区。
	if control.has_method("_has_point"): return bool(control.call("_has_point", local))
	return Rect2(Vector2.ZERO, control.size).has_point(local)

func actual_hit_control(root: Node, viewport_point: Vector2) -> Control:
	# 使用原节点顺序、z层、裁切及_has_point寻找接收者；过滤器不另建放大的点击矩形。
	if root is Control:
		if not root.is_visible_in_tree() or root.is_queued_for_deletion(): return null
		if root.clip_contents and not original_hit(root, viewport_point): return null
	var children := root.get_children()
	children.sort_custom(func(a, b): return int(a.z_index if a is CanvasItem else 0) < int(b.z_index if b is CanvasItem else 0))
	children.reverse()
	for child in children:
		var picked := actual_hit_control(child, viewport_point)
		if picked != null: return picked
	if root is Control and root.mouse_filter != Control.MOUSE_FILTER_IGNORE and original_hit(root, viewport_point): return root
	return null

func _check_first_card() -> void:
	var owns: bool = session.case_state.owns("E01_V1")
	var just_acquired := owns and not previous_owns_first
	# set_log_open 会同步发 changed；先记录观察值，防止重入再次播放同一反馈。
	previous_owns_first = owns
	if just_acquired and feedback_left <= 0 and not completed({"group_id": "TUT_FIRST_CARD", "step": 1}):
		for row in definition.get("acquisition_feedback", []):
			if row.get("content_ref") != "E01_V1": continue
			feedback_content = "E01_V1"
			feedback_left = float(row.get("animation_ms", 400) + row.get("hold_ms", 2000)) / 1000.0
			_feedback_had_log = session.narrative.reading_log
			session.narrative.set_log_open(true)
			first_card_feedback_requested.emit(feedback_content, int(row.get("animation_ms", 400)), int(row.get("hold_ms", 2000)), session.config.text(str(row.get("text_ref", "UI_GUIDE_FIRST_CARD"))))

func _finish_feedback() -> void:
	if feedback_content.is_empty(): return
	feedback_left = 0
	feedback_content = ""
	if session != null:
		_mark({"group_id": "TUT_FIRST_CARD", "step": 1})
		session.narrative.set_log_open(_feedback_had_log)
	changed.emit()
