extends Control
## 独立接口演练夹具；正式主入口已接入核心玩法，夹具仍供旧合同回归使用。
const ModelScript = preload("res://features/counter_demo/counter_model.gd")
@export var demo_config: Resource = preload("res://data/demo_config.tres")
@onready var counter_view: Control = $CounterView
var model: RefCounted

func _ready() -> void:
	model = ModelScript.new()
	model.configure(demo_config.initial_value, demo_config.step)
	model.value_changed.connect(counter_view.show_value)
	counter_view.increment_requested.connect(model.increment)
	counter_view.reset_requested.connect(model.reset)
	counter_view.set_connected(true)
	counter_view.set_step(demo_config.step)
	counter_view.show_value(model.read_value())
