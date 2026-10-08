extends Node
## 初始化与开始服务：先加载设置，再扫描存档，最后允许标题页操作。

signal ready_for_title(has_progress: bool)
var initialized := false

func initialize(settings_service: Node, save_service: Node) -> void:
	settings_service.initialized.connect(_on_settings_initialized.bind(save_service), CONNECT_ONE_SHOT)
	settings_service.initialize()

func _on_settings_initialized(_success: bool, _message: String, save_service: Node) -> void:
	var records: Array = save_service.scan()
	initialized = true
	ready_for_title.emit(not records.is_empty())

func create_new_game() -> Dictionary:
	return {"state_revision": 1, "question_id": "intro", "elapsed_seconds": 0, "navigation_snapshot": {"page_id": "investigation"}}
