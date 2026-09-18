extends Control

const ModelScript = preload("res://features/counter_demo/counter_model.gd")

@export var demo_config: Resource = preload("res://data/demo_config.tres")
@onready var counter_view: Control = $CounterView
var model: RefCounted


func _ready() -> void:
	model = ModelScript.new()
	model.configure(demo_config.initial_value, demo_config.step)
	model.value_changed.connect(counter_view.show_value)
	counter_view.increment_requested.connect(_on_increment_requested)
	counter_view.reset_requested.connect(_on_reset_requested)
	counter_view.set_connected(true)
	counter_view.set_step(demo_config.step)
	counter_view.show_value(model.read_value())
	get_window().min_size = Vector2i(860, 560)


func _on_increment_requested() -> void:
	model.increment()


func _on_reset_requested() -> void:
	model.reset()
