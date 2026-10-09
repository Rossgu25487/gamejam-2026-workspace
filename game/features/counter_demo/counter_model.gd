class_name CounterModel
extends RefCounted
## State belongs here. The view sends requests and displays returned values.

signal value_changed(value: int)

var _initial_value: int = 0
var _step: int = 1
var _value: int = 0


func configure(initial: int, step: int) -> void:
	_initial_value = initial
	_step = step
	_value = initial
	value_changed.emit(_value)

func restore_value(value: int) -> void:
	# 读取存档只恢复当前值，保留初始值作为重置目标。
	_value = value
	value_changed.emit(_value)


func read_value() -> int:
	return _value


func increment() -> int:
	_value += _step
	value_changed.emit(_value)
	return _value


func reset() -> int:
	_value = _initial_value
	value_changed.emit(_value)
	return _value
