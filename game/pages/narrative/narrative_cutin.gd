extends TextureRect
## 正式特写只管理镜头时长及还原，不改变阅读、材料或案件事件。
var page: Control
var bindings: Array = []
var pending: Array = []
var sequence := ""
var remaining_ms := 0.0
var current_id := ""

func bind(value: Control) -> void:
	clear()
	page = value
	# 前景人物有独立层级；特写须覆盖这些立绘，同时留在页面的阅读栏之下。
	z_index = 10
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bindings = page.formal_config.narrative_bindings("cutin_bindings") if page.formal_config != null else []
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hide()

func show_record(row: Dictionary) -> void:
	var text_id := str(row.get("text_id", ""))
	for binding in bindings:
		if str(binding.get("end_before_text_ref", "")) == text_id: clear()
	var found: Array = bindings.filter(func(binding): return binding.get("text_ref") == text_id)
	if not found.is_empty():
		pending = found.duplicate(true)
		pending.sort_custom(func(a,b): return int(a.get("order",0)) < int(b.get("order",0)))
		_next()
	elif not sequence.is_empty():
		# 猫三页同一局部持续最后干印画面；其他镜头沿明确结束引用还原。
		if sequence == "CUE_CAT_DRY_MARK" and not text_id.begins_with("TXT_CAT_DRY_MARK_"): clear()

func _next() -> void:
	if pending.is_empty(): return
	var binding: Dictionary = pending.pop_front()
	var path: String = page.formal_config.resource_path(str(binding.image_ref))
	if not ResourceLoader.exists(path): clear(); return
	texture = load(path) as Texture2D
	current_id = str(binding.id)
	sequence = str(binding.get("sequence_ref", ""))
	remaining_ms = float(binding.get("duration_ms", 0))
	show()

func _process(delta: float) -> void:
	if not is_visible_in_tree() or page == null or page.service == null or page.service.reading_log or page.service.hidden: return
	var session = page.service.get("session")
	if session != null and session.paused: return
	if remaining_ms > 0:
		remaining_ms = maxf(0, remaining_ms - delta * 1000)
		if remaining_ms == 0:
			if not pending.is_empty(): _next()
			elif sequence != "CUE_CAT_DRY_MARK": clear()

func is_blocking() -> bool:
	return visible and remaining_ms > 0

func clear() -> void:
	texture = null; pending.clear(); sequence = ""; remaining_ms = 0; current_id = ""
	hide()
