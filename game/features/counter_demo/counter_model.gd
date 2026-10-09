class_name CounterModel
extends RefCounted
## 计数器模型只保存数值状态；界面通过信号请求变化并显示结果。

# 数值发生变化后通知所有显示层。
signal value_changed(value: int)

var _initial_value: int = 0 # 重置操作返回的基准值。
var _step: int = 1 # 每次递增的步长。
var _value: int = 0 # 当前运行值。


func configure(initial: int, step: int) -> void:
	# 开始新游戏时同时设置初始值、步长和当前值。
	_initial_value = initial
	_step = step
	_value = initial
	value_changed.emit(_value)

func restore_value(value: int) -> void:
	# 读取存档只恢复当前值，保留初始值作为重置目标。
	_value = value
	value_changed.emit(_value)


func read_value() -> int:
	# 返回当前值，不修改模型状态。
	return _value


func increment() -> int:
	# 按配置步长增加当前值并广播结果。
	_value += _step
	value_changed.emit(_value)
	return _value


func reset() -> int:
	# 将当前值恢复到新游戏设定的初始值。
	_value = _initial_value
	value_changed.emit(_value)
	return _value
