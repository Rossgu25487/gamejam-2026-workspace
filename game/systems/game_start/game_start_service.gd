extends Node
## 初始化与开始服务：先加载设置，再扫描存档，最后允许标题页操作。

signal ready_for_title(has_progress: bool) # 设置和存档扫描完成后通知标题页。
var initialized := false # 初始化是否完成。
var initial_save_failed := false

func save_initial(snapshot: Dictionary, save_service: Node) -> bool:
	# 初档失败保留新调查和所有旧档；成功后才清理上一调查的保护记录。
	initial_save_failed = not save_service.save_auto(snapshot)
	if not initial_save_failed: save_service.clear_previous_run_protection(str(snapshot.card_snapshot.run_id))
	return not initial_save_failed

func initialize(settings_service: Node, save_service: Node) -> void:
	# 设置必须先初始化，完成后才允许扫描存档并开放标题页操作。
	settings_service.initialized.connect(_on_settings_initialized.bind(save_service), CONNECT_ONE_SHOT)
	settings_service.initialize()

func _on_settings_initialized(_success: bool, _message: String, save_service: Node) -> void:
	# 初始化顺序的第二步：扫描有效存档并报告是否存在继续进度。
	var records: Array = save_service.scan()
	initialized = true
	ready_for_title.emit(not records.is_empty())
