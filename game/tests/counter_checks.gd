extends RefCounted
## PREP-001 integration checks. Called with "await checks.run(tree)".
## Button signals are emitted programmatically; this does not verify physical input or layout.

const ModelScript = preload("res://features/counter_demo/counter_model.gd")
const ConfigScript = preload("res://data/demo_config.gd")

const MAIN_SCENE: String = "res://main/main.tscn"
const VIEW_SCENE: String = "res://ui/counter_view.tscn"


func run(tree: SceneTree) -> Array[String]:
	var failures: Array[String] = []
	_check_model(failures)
	await _check_main(tree, failures, "main 首次加载", 0, 1, 2)
	await _check_main(tree, failures, "main 释放后重载", 0, 1, 1)
	await _check_main(tree, failures, "main 可配置步长", 5, 2, 1, true)
	await _check_standalone_view(tree, failures)
	return failures


func _check_model(failures: Array[String]) -> void:
	var model: CounterModel = ModelScript.new()
	var observed: Array[int] = []
	model.value_changed.connect(func(value: int) -> void: observed.append(value))

	_expect(model.read_value() == 0, "CounterModel 新实例初值应为 0", failures)
	for expected: int in [1, 2, 3]:
		_expect(model.increment() == expected, "CounterModel increment 返回值应为 " + str(expected), failures)
		_expect(model.read_value() == expected, "CounterModel 实际状态应为 " + str(expected), failures)
	_expect(model.reset() == 0, "CounterModel 默认 reset 返回值应为 0", failures)
	_expect(model.read_value() == 0, "CounterModel 默认 reset 后读取应为 0", failures)
	_expect(observed == [1, 2, 3, 0], "CounterModel 默认信号应依次发出 [1, 2, 3, 0]，实际为 " + str(observed), failures)

	model.configure(5, 2)
	_expect(model.read_value() == 5, "configure(5, 2) 后读取应为 5", failures)
	# Configure notification timing is not part of the consumer contract.
	observed.clear()
	_expect(model.increment() == 7, "configure(5, 2) 后 increment 返回值应为 7", failures)
	_expect(model.read_value() == 7, "可配置模型增加后实际状态应为 7", failures)
	_expect(model.reset() == 5, "可配置模型 reset 返回值应为配置初值 5", failures)
	_expect(model.read_value() == 5, "可配置模型 reset 后读取应为 5", failures)
	_expect(observed == [7, 5], "可配置模型增加与重置信号应为 [7, 5]，实际为 " + str(observed), failures)


func _check_main(
	tree: SceneTree,
	failures: Array[String],
	context: String,
	initial: int,
	step: int,
	increment_count: int,
	override_config: bool = false
) -> void:
	var packed: PackedScene = load(MAIN_SCENE) as PackedScene
	if packed == null:
		failures.append(context + "：无法加载 " + MAIN_SCENE)
		return

	var instance: Node = packed.instantiate()
	if override_config:
		var config: Resource = ConfigScript.new()
		config.set("initial_value", initial)
		config.set("step", step)
		instance.set("demo_config", config)
	tree.root.add_child(instance)
	await tree.process_frame

	var view: Control = instance.get_node_or_null("CounterView") as Control
	if view == null:
		failures.append(context + "：缺少 CounterView 节点")
		await _release_scene(instance, tree)
		return

	var nodes: Dictionary = _view_nodes(view, failures, context)
	if nodes.is_empty():
		await _release_scene(instance, tree)
		return

	var value_label: Label = nodes["value"]
	var increment_button: Button = nodes["increment"]
	var reset_button: Button = nodes["reset"]
	var status: Label = nodes["status"]
	var step_note: Label = nodes["step"]
	var actual_model: RefCounted = instance.get("model") as RefCounted

	_expect(value_label.text == str(initial), context + "：首次显示应为 " + str(initial), failures)
	_expect(status.text.contains("逻辑已连接"), context + "：应明确显示逻辑已连接，实际为 " + status.text, failures)
	_expect(increment_button.text == "加 " + str(step), context + "：增加按钮应显示实际步长 " + str(step), failures)
	_expect(step_note.text.contains("每次变化 " + str(step)), context + "：步长说明未反映实际配置", failures)
	if actual_model == null:
		failures.append(context + "：主入口没有提供真实 model")
	else:
		_expect(actual_model.call("read_value") == initial, context + "：真实模型的初值与界面不一致", failures)

	for index: int in range(increment_count):
		increment_button.pressed.emit()
		await tree.process_frame
		var expected: int = initial + (index + 1) * step
		_expect(value_label.text == str(expected), context + "：第 " + str(index + 1) + " 次点击后应显示 " + str(expected) + "，实际为 " + value_label.text, failures)
		if actual_model != null:
			_expect(actual_model.call("read_value") == expected, context + "：按钮操作未正确更新真实模型，或存在重复连接", failures)

	reset_button.pressed.emit()
	await tree.process_frame
	_expect(value_label.text == str(initial), context + "：重置后应显示配置初值 " + str(initial), failures)
	_expect(status.text.contains("逻辑已连接"), context + "：操作后连接状态丢失", failures)
	if actual_model != null:
		_expect(actual_model.call("read_value") == initial, context + "：重置没有恢复真实模型初值", failures)
	await _release_scene(instance, tree)


func _check_standalone_view(tree: SceneTree, failures: Array[String]) -> void:
	var packed: PackedScene = load(VIEW_SCENE) as PackedScene
	if packed == null:
		failures.append("独立界面：无法加载 " + VIEW_SCENE)
		return

	var view: Control = packed.instantiate() as Control
	tree.root.add_child(view)
	await tree.process_frame
	var nodes: Dictionary = _view_nodes(view, failures, "独立界面")
	if nodes.is_empty():
		await _release_scene(view, tree)
		return

	var value_label: Label = nodes["value"]
	var increment_button: Button = nodes["increment"]
	var reset_button: Button = nodes["reset"]
	var status: Label = nodes["status"]
	_expect(status.text.contains("尚未连接逻辑"), "独立界面应明确显示尚未连接逻辑", failures)

	# A display update is not a model connection and must not enable local counting.
	view.call("show_value", 41)
	_expect(value_label.text == "41", "独立界面 show_value(41) 应显示传入值", failures)
	view.call("set_connected", true)
	_expect(status.text.contains("尚未连接逻辑"), "仅调用 set_connected(true) 不能伪造真实接线状态", failures)

	increment_button.pressed.emit()
	increment_button.pressed.emit()
	reset_button.pressed.emit()
	await tree.process_frame
	_expect(value_label.text == "41", "独立界面无模型时不应自行增加或重置计数", failures)
	_expect(status.text.contains("尚未连接逻辑"), "独立界面按钮操作后仍须说明未连接", failures)
	await _release_scene(view, tree)


func _view_nodes(view: Control, failures: Array[String], context: String) -> Dictionary:
	var value_label: Label = view.get_node_or_null("%ValueLabel") as Label
	var increment_button: Button = view.get_node_or_null("%IncrementButton") as Button
	var reset_button: Button = view.get_node_or_null("%ResetButton") as Button
	var status: Label = view.get_node_or_null("%ConnectionStatus") as Label
	var step_note: Label = view.get_node_or_null("%StepNote") as Label
	if value_label == null or increment_button == null or reset_button == null or status == null or step_note == null:
		failures.append(context + "：缺少 ValueLabel / IncrementButton / ResetButton / ConnectionStatus / StepNote 中的必要唯一节点")
		return {}
	return {
		"value": value_label,
		"increment": increment_button,
		"reset": reset_button,
		"status": status,
		"step": step_note,
	}


func _release_scene(scene: Node, tree: SceneTree) -> void:
	scene.queue_free()
	await tree.process_frame
	await tree.process_frame


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
