class_name CounterView
extends Control
## Presentation only: this scene owns no counter state.

signal increment_requested
signal reset_requested

@onready var _value_label: Label = %ValueLabel
@onready var _increment_button: Button = %IncrementButton
@onready var _connection_status: Label = %ConnectionStatus
@onready var _step_note: Label = %StepNote

var _connected: bool = false


func set_connected(connected: bool) -> void:
	_connected = connected
	if _has_model_connection():
		_connection_status.text = "逻辑已连接 · 当前数值已同步"
	else:
		_connection_status.text = "独立界面预览 · 尚未连接逻辑"


func show_value(value: int) -> void:
	_value_label.text = str(value)
	if _has_model_connection():
		_connection_status.text = "逻辑已连接 · 当前数值已同步"
	else:
		_connection_status.text = "独立界面预览 · 尚未连接逻辑"


func set_step(step: int) -> void:
	_increment_button.text = "加 " + str(step)
	_step_note.text = "每次变化 " + str(step) + "  ·  重置回到起点"


func _has_model_connection() -> bool:
	return _connected and increment_requested.get_connections().size() > 0 and reset_requested.get_connections().size() > 0


func _on_increment_pressed() -> void:
	if not _has_model_connection():
		_connection_status.text = "尚未连接逻辑 · 按钮可预览，数值不会改变"
		return
	increment_requested.emit()


func _on_reset_pressed() -> void:
	if not _has_model_connection():
		_connection_status.text = "尚未连接逻辑 · 按钮可预览，数值不会改变"
		return
	reset_requested.emit()
