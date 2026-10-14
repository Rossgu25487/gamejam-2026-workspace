extends Control
## 文案页面私有逻辑：逐字显示、继续/快进、跳转选择和输入焦点。

const UI = preload("res://pages/core/page_controls.gd")
var service: Node
var text_label: RichTextLabel
var name_label: Label
var continue_button: Button
var choices: VBoxContainer
var title_label: Label
var background: TextureRect
var actor: TextureRect

func bind(value: Node) -> void:
	service = value
	if not service.changed.is_connected(_queue_render): service.changed.connect(_queue_render)
	if not service.progressed.is_connected(_on_progressed): service.progressed.connect(_on_progressed)
	if not service.text_started.is_connected(_on_text_started): service.text_started.connect(_on_text_started)
	_queue_render()

func _ready() -> void:
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_STOP

func _process(delta: float) -> void:
	if service != null and not service.state.is_empty() and service.is_typing(): service.tick(delta)

func _queue_render(_unused = null) -> void:
	if not is_inside_tree(): return
	call_deferred("_render")

func _render() -> void:
	if service == null or service.state.is_empty(): return
	for child in get_children(): child.queue_free()
	var root_box := VBoxContainer.new()
	root_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_box.offset_left = 96
	root_box.offset_top = 120
	root_box.offset_right = -96
	root_box.offset_bottom = -36
	add_child(root_box)
	title_label = UI.label(root_box, "第 " + str(service.state.get("chapter_id", "")), 26)
	title_label.visible = not str(service.state.get("chapter_id", "")).is_empty()
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_box.add_child(spacer)
	var dialog := PanelContainer.new()
	dialog.custom_minimum_size.y = 278
	root_box.add_child(dialog)
	var box := VBoxContainer.new()
	dialog.add_child(box)
	name_label = UI.label(box, str(service.current_record().get("speaker_name", service.current_record().get("character_name", ""))), 28)
	text_label = UI.body(box, service.visible_text(), 100)
	text_label.bbcode_enabled = false
	var footer := HBoxContainer.new()
	box.add_child(footer)
	var hint := UI.label(footer, "Enter / Space 继续", 16)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	continue_button = UI.button(footer, "继续", _advance)
	if is_instance_valid(continue_button) and continue_button.visible and not continue_button.disabled: continue_button.grab_focus()
	choices = VBoxContainer.new()
	choices.visible = false
	box.add_child(choices)
	_render_choices()

func _render_choices() -> void:
	if service == null or service.is_typing(): return
	var transitions: Array = service.catalog.choices_from_text(str(service.state.get("current_text_id", "")))
	if transitions.is_empty(): return
	choices.visible = true
	for index in range(transitions.size()):
		var row: Dictionary = transitions[index]
		var label := str(row.get("choice_text", row.get("target_text_id", "继续")))
		UI.button(choices, label, service.choose_transition.bind(index))
	continue_button.visible = false
	if choices.get_child_count() > 0 and is_instance_valid(choices.get_child(0)): choices.get_child(0).grab_focus()

func _advance() -> void:
	if service != null: service.advance()

func _on_text_started(_record: Dictionary) -> void:
	_queue_render()

func _on_progressed(value: String, _typing: bool) -> void:
	if is_instance_valid(text_label): text_label.text = value

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_SPACE]:
		_advance()
		get_viewport().set_input_as_handled()
