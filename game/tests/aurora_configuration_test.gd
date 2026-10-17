extends SceneTree
func _init() -> void:
	var config := preload("res://systems/aurora/aurora_configuration.gd").new()
	var ok := config.load_package()
	print("AURORA_CONFIGURATION ", ok, " texts=", config.texts.size(), " entries=", config.entries.size(), " questions=", config.questions.size())
	for message in config.errors: printerr(message)
	quit(0 if ok else 1)
