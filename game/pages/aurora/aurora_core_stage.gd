extends Control
## 核查对象固定于本次合法会话，材料署名和回应插话不改变对象或业务地点。
const Stage = preload("res://pages/narrative/narrative_stage.gd")
var stage: Control
var fixed_actor := ""
var question_id := ""
var session: Node
var portrait_path := ""
var portrait_missing := false

func bind(value: Node) -> void:
	session = value
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage = Stage.new()
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(stage)
	stage.configure_formal(session.config)

func refresh() -> void:
	if question_id != session.question:
		question_id = session.question
		fixed_actor = str(session.return_context.get("object", ""))
		if not session.config.actors.has(fixed_actor): fixed_actor = ""
		if fixed_actor.is_empty():
			# 只接受问题或其实际绑定显式声明的会话对象；台词署名不授予对象身份。
			fixed_actor = str(session.question_binding().get("talk_character_id", session.config.questions.get(question_id, {}).get("talk_character_id", "")))
			if not session.config.actors.has(fixed_actor): fixed_actor = ""
		portrait_path = _portrait_for(fixed_actor)
		portrait_missing = not fixed_actor.is_empty() and portrait_path.is_empty()
	stage.apply_record({"scene_id":session.case_state.data.scene, "background_path":session.background_path(),
		"clear_positions":true, "scene_layers":[], "character_id":fixed_actor, "avatar_path":portrait_path,
		"text_type":"dialogue", "position":"left" if not fixed_actor.is_empty() else ""}, session.narrative.catalog)

func _portrait_for(actor_id: String) -> String:
	if actor_id.is_empty(): return ""
	var default_path := str(session.config.actors.get(actor_id, {}).get("default_portrait_path", ""))
	var fallback := ""
	for path in stage.actor_assets:
		var asset: Dictionary = stage.actor_assets[path]
		if str(asset.get("character_id", "")) != actor_id or str(asset.get("facing_direction", "")) not in ["right", "near_front", "front"]: continue
		if not ResourceLoader.exists(str(path)): continue
		if path == default_path: return str(path)
		if fallback.is_empty(): fallback = str(path)
	# 没有朝向合适的真实资源时保留对象姓名，不镜像衣饰或伤痕，也不伪造路径。
	return fallback

func set_preferences(values: Dictionary) -> void:
	# 亮度只作用舞台图片；卡面、原话、按钮与姓名均在独立的上层节点。
	if is_instance_valid(stage): stage.set_brightness(int(values.get("brightness", 100)))

func reset() -> void:
	question_id = ""
	fixed_actor = ""
	portrait_path = ""
	portrait_missing = false
	stage.reset_stage()
