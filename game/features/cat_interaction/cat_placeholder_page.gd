extends Control
## 【占位】撸猫互动联调页：仅验证状态机、计时与输入，不接入正式 main，不使用正式素材。
## 运行：编辑器 F6，或命令行 --path game res://features/cat_interaction/cat_placeholder_page.tscn
## 删除：删除本文件与 cat_placeholder_page.tscn 即可，不影响任何正式代码。

const CatalogScript = preload("res://features/cat_interaction/cat_catalog.gd")
const ServiceScript = preload("res://features/cat_interaction/cat_service.gd")

var _catalog: RefCounted
var _service: RefCounted
var _slot: ColorRect
var _head_button: Button
var _touch_button: Button
var _return_button: Button
var _menu_button: Button
var _reduce_toggle: CheckButton
var _status: Label
var _debug: Label

func _ready() -> void:
	# 联调刻意使用 EX 展示行；正式 cat_view_default 素材未就绪、入口仍禁用。
	get_window().size = Vector2i(1280, 800)
	_catalog = CatalogScript.new()
	if not _catalog.load_files():
		_add_error("配置加载失败：" + str(_catalog.errors))
		return
	var interaction: Dictionary = _catalog.interaction("cat_stove_head")
	var view: Dictionary = _catalog.test_view("EX_CAT_VIEW_A")
	var actions: Dictionary = _catalog.actions_for("cat_stove_head")
	_service = ServiceScript.new()
	_build_ui(view)
	_service.changed.connect(_refresh)
	_service.finished.connect(_refresh)
	if not _service.enter(interaction, view, actions):
		_add_error("互动未就绪")
		return
	_refresh()
	get_viewport().size_changed.connect(_apply_layout.bind(view))

func _build_ui(view: Dictionary) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.13)
	bg.anchors_preset = Control.PRESET_FULL_RECT
	add_child(bg)

	_slot = ColorRect.new()
	_slot.color = Color(0.25, 0.25, 0.32)
	add_child(_slot)

	_head_button = Button.new()
	_head_button.text = "猫头"
	_head_button.flat = true
	_head_button.pressed.connect(_on_touch)
	add_child(_head_button)

	_touch_button = Button.new()
	_touch_button.text = _catalog.ui("CAT_TOUCH")
	_touch_button.pressed.connect(_on_touch)
	add_child(_touch_button)

	_return_button = Button.new()
	_return_button.text = _catalog.ui("CAT_RETURN")
	_return_button.pressed.connect(_on_return)
	add_child(_return_button)

	_menu_button = Button.new()
	_menu_button.text = _catalog.ui("CAT_MENU")
	_menu_button.pressed.connect(_on_menu)
	add_child(_menu_button)

	_reduce_toggle = CheckButton.new()
	_reduce_toggle.text = "减弱动态（联调开关）"
	add_child(_reduce_toggle)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 28)
	add_child(_status)

	_debug = Label.new()
	add_child(_debug)

	var tag := Label.new()
	tag.text = "占位联调页（非正式）"
	tag.modulate = Color(0.7, 0.5, 0.3)
	add_child(tag)
	tag.anchors_preset = Control.PRESET_TOP_LEFT
	tag.position = Vector2(12, 12)

	_apply_layout(view)
	_touch_button.grab_focus()

func _apply_layout(view: Dictionary) -> void:
	var w := size.x
	var h := size.y
	var slot_rect := Rect2(_f(view, "screen_x") * w, _f(view, "screen_y") * h, _f(view, "screen_w") * w, _f(view, "screen_h") * h)
	_place(_slot, slot_rect)
	# 占位简化：内容矩形 = 屏幕槽（未做真实 contain 等比）；头区按内容矩形比例换算。
	var head_rect := Rect2(slot_rect.position.x + _f(view, "head_x") * slot_rect.size.x, slot_rect.position.y + _f(view, "head_y") * slot_rect.size.y, _f(view, "head_w") * slot_rect.size.x, _f(view, "head_h") * slot_rect.size.y)
	_place(_head_button, head_rect)
	_place(_touch_button, Rect2(w * 0.08, h * 0.82, 140, 40))
	_place(_return_button, Rect2(w * 0.08 + 160, h * 0.82, 140, 40))
	_place(_menu_button, Rect2(w * 0.08 + 320, h * 0.82, 120, 40))
	_place(_reduce_toggle, Rect2(w * 0.08, h * 0.90, 240, 32))
	_place(_status, Rect2(w * 0.08, h * 0.06, w * 0.5, 40))
	_place(_debug, Rect2(w * 0.08, h * 0.13, w * 0.7, 80))

func _place(node: Control, rect: Rect2) -> void:
	node.anchors_preset = Control.PRESET_TOP_LEFT
	node.position = rect.position
	node.size = rect.size

func _f(d: Dictionary, key: String) -> float:
	var v = d.get(key, 0.0)
	return float(v) if v is float else 0.0

func _refresh() -> void:
	var phase: String = _service.phase
	var status_key := ""
	match phase:
		"waiting": status_key = "CAT_WAITING"
		"gesture": status_key = "CAT_GESTURE"
		"response": status_key = "CAT_RESPONSE"
	_status.text = _catalog.ui(status_key) if not status_key.is_empty() else "互动已结束（占位）"
	_debug.text = "phase=%s kind=%s action=%s first_seen=%s remaining=%dms reduce=%s" % [phase, _service.response_kind, _service.current_action_kind(), str(_service.first_seen), int(_service.remaining_ms()), str(_service.reduce_motion)]
	_touch_button.disabled = phase != "waiting"
	_head_button.disabled = phase != "waiting"

func _on_touch() -> void:
	_service.begin_touch(_reduce_toggle.button_pressed)

func _on_return() -> void:
	_service.finish()

func _on_menu() -> void:
	print("占位：菜单（正式暂停来源返回由 main 接入，不在占位页实现）")

func _process(delta: float) -> void:
	if _service == null or not _service.is_active(): return
	_service.advance(delta * 1000.0)
	# 占位：无真实动画，回应阶段即视为稳定画面已显示（当前 stable_point 初值为 0）。
	if _service.phase == "response":
		_service.notify_stable_displayed()

func _add_error(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.modulate = Color(1, 0.3, 0.3)
	add_child(label)
	label.anchors_preset = Control.PRESET_TOP_LEFT
	label.position = Vector2(12, 40)
