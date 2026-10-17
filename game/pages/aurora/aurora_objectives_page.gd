extends Control
## 正式目标与回顾：公开、完成与前往全部消费当前案件条件，不推断材料即可完成。
const UI = preload("res://pages/core/page_controls.gd")
signal closed
signal material_requested(content_id: String)
var session: Node
var scroll_position := 0
var status: Label

func bind(value: Node) -> void:
	session = value
	hide()

func open() -> void:
	UI.clear(self)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 550)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)
	UI.label(box, "目标与调查回顾", 30)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(820, 420)
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 14)
	scroll.add_child(list)
	for goal in session.config.rows("objective", "正式目标"):
		if not session.condition(str(goal.get("condition_id", ""))): continue
		UI.label(list, str(goal.text), 26)
		for row in session.config.rows("objective", "正式事项"):
			if row.goal_id != goal.goal_id or not session.condition(str(row.get("condition_id", ""))): continue
			var done: bool = session.condition(str(row.get("completion_condition_id", ""))) if not str(row.get("completion_condition_id", "")).is_empty() else false
			UI.label(list, ("✓ " if done else "○ ") + str(row.text), 23)
			for basis_id in session.config.ids(str(row.get("basis_ids", ""))):
				for basis in session.config.rows("objective", "正式依据"):
					var content := str(basis.get("content_id", ""))
					if basis.basis_id == basis_id and session.case_state.owns(content): UI.button(list, "回看 · " + str(session.config.contents[content].name), material_requested.emit.bind(content))
			UI.button(list, "前往核对", _go.bind(row), not done)
	status = UI.label(box, "", 20)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UI.button(box, "返回调查", close)
	scroll.scroll_vertical = scroll_position
	scroll.get_v_scroll_bar().value_changed.connect(func(value): scroll_position = int(value))
	show()

func _go(row: Dictionary) -> void:
	var id := str(row.target_ref)
	var scene := str(row.scene_id)
	if not session.scene_status(scene).available or not session.prepare_scene(scene) or not session.config.entries.has(id):
		status.text = str(row.get("public_reason", "当前还不能前往。"))
		return
	var entry: Dictionary = session.config.entries[id]
	# 以目的地候选状态验证入口，失败不改变当前场景或关闭回顾。
	var old: Dictionary = session.case_state.data.duplicate(true)
	session.case_state.data.scene = scene
	session.case_state.data.view = str(row.get("view_id", "VIEW_%s_MAIN" % scene))
	var valid: bool = session.condition(str(entry.get("condition_id", "")))
	session.case_state.data = old
	if not valid: status.text = str(row.get("public_reason", "当前还不能开始这项核对。")); return
	if session.set_scene(scene) and session.activate_entry(id, {"kind": "scene", "scene": scene, "view": row.get("view_id", "")}):
		hide()
		closed.emit()

func close() -> void:
	hide()
	closed.emit()
