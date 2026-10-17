extends Control
## 反馈时轴只负责表现与输入锁；事件仍在原业务时点提交，结束不会收下或继续。
const UI = preload("res://pages/core/page_controls.gd")
signal finished
var session: Node
var elapsed_ms := 0.0
var duration_ms := 0.0
var reduced := false
var effect := {}
var paper: PanelContainer
var title: Label

func bind(value: Node) -> void:
	session = value
	session.result_presentation_requested.connect(play)
	hide()

func play(data: Dictionary) -> void:
	stop()
	effect = data.duplicate(true)
	duration_ms = float(data.get("duration_ms", 300))
	elapsed_ms = 0
	if reduced: return
	UI.clear(self)
	var shade := ColorRect.new()
	shade.color = Color(0.025, 0.035, 0.045, 0.97)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	paper = PanelContainer.new()
	paper.custom_minimum_size = Vector2(780, 360)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 24)
	paper.add_child(column)
	title = UI.label(column, "收下推论" if data.get("effect_level") == "collect" else ("灵感涌现" if data.get("effect_kind") == "涌现" else ("矛盾击破" if data.get("effect_kind") == "击破" else "进一步确认")), 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UI.body(column, session.target_text(), 120)
	var names: Array[String] = []
	for id in session.pending_result.get("refs", []): names.append(str(session.config.contents[id].name))
	var sources := UI.label(column, " ＋ ".join(names), 28)
	sources.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UI.button(column, "跳过表现", stop)
	mouse_filter = Control.MOUSE_FILTER_STOP
	session.processing = true
	show()

func _process(delta: float) -> void:
	if not visible or session == null or session.paused: return
	elapsed_ms += delta * 1000
	var progress := clampf(elapsed_ms / maxf(duration_ms, 1), 0, 1)
	if is_instance_valid(title):
		title.modulate.a = clampf(elapsed_ms / 500, 0, 1)
		paper.modulate = Color(1, 1, 1, 0.65 + 0.35 * sin(progress * PI))
	if elapsed_ms >= duration_ms: stop()

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))
	if reduced and visible: stop()

func stop() -> void:
	if visible and session != null: session.processing = false
	hide()
	finished.emit()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey or not event.pressed: return
	if event.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_SPACE]: stop()
	get_viewport().set_input_as_handled()
