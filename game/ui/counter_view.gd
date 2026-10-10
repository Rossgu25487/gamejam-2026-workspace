class_name CounterView
extends Control
## 计数器视图只负责控件显示和输入转发，不保存计数状态。

signal increment_requested # 用户请求递增。
signal reset_requested # 用户请求重置。

@onready var _value_label: Label = %ValueLabel
@onready var _increment_button: Button = %IncrementButton
@onready var _connection_status: Label = %ConnectionStatus
@onready var _step_note: Label = %StepNote

var _connected: bool = false # 主程序是否已经连接模型信号。


func set_connected(connected: bool) -> void:
	# 更新连接状态提示，便于独立预览界面时识别未接入逻辑。
	_connected = connected
	if _has_model_connection():
		_connection_status.text = "逻辑已连接 · 当前数值已同步"
	else:
		_connection_status.text = "独立界面预览 · 尚未连接逻辑"


func show_value(value: int) -> void:
	# 将模型提供的数值渲染到标签。
	_value_label.text = str(value)
	if _has_model_connection():
		_connection_status.text = "逻辑已连接 · 当前数值已同步"
	else:
		_connection_status.text = "独立界面预览 · 尚未连接逻辑"


func set_step(step: int) -> void:
	# 根据配置更新递增按钮和说明文字。
	_increment_button.text = "加 " + str(step)
	_step_note.text = "每次变化 " + str(step) + "  ·  重置回到起点"


func _has_model_connection() -> bool:
	# 只有主程序完成两条请求信号连接后，输入才真正生效。
	return _connected and increment_requested.get_connections().size() > 0 and reset_requested.get_connections().size() > 0


func _on_increment_pressed() -> void:
	# 按钮回调只发请求，不直接修改模型。
	if not _has_model_connection():
		_connection_status.text = "尚未连接逻辑 · 按钮可预览，数值不会改变"
		return
	increment_requested.emit()


func _on_reset_pressed() -> void:
	# 重置按钮同样通过信号交给主程序连接的模型处理。
	if not _has_model_connection():
		_connection_status.text = "尚未连接逻辑 · 按钮可预览，数值不会改变"
		return
	reset_requested.emit()
