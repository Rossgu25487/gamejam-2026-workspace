extends Control
## 猫页只绘制已交付整张透明帧，暂停隐藏时不推进计时，也不重新启动clip。
const UI = preload("res://pages/core/page_controls.gd")
const CatScript = preload("res://systems/aurora/aurora_cat.gd")
signal closed
signal menu_requested
var session: Node
var cat: RefCounted = CatScript.new()
var cat_image: TextureRect
var hand_image: TextureRect
var touch_button: Button
var canvas: Control
var frames := {"cat": [], "hand": []}
var reduced := false
var frame_index := -1

func bind(value: Node) -> void:
	session = value
	hide()

func open() -> bool:
	if session.mode != "investigation" or session.case_state.data.scene != "SC02": return false
	var reward: Dictionary = session.config.narrative_data.get("cat_reward_binding", {})
	if int(session.case_state.data.get("cat_pet_completed_count", 0)) >= int(reward.get("threshold", 5)) and not session.case_state.owns(str(reward.get("content_ref", "E27_V1"))):
		return session.activate_entry(str(reward.get("reward_entry_ref", "ENTRY_CAT_DRY_MARK")), {"kind": "scene", "scene": session.case_state.data.scene, "view": session.case_state.data.view})
	var row: Dictionary = session.config.rows("cat", "猫互动")[0]
	var path: String = session.config.resource_path("res://assets/aurora/cat/animation.json")
	var descriptor = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not descriptor is Dictionary: return false
	for pair in [["cat", "cat_response"], ["hand", "pet_hand"]]:
		frames[pair[0]].clear()
		for frame_path in descriptor.clips[pair[1]].frames:
			var image_path := path.get_base_dir().path_join(str(frame_path))
			if not ResourceLoader.exists(image_path): return false
			frames[pair[0]].append(load(image_path))
	cat.enter(row, bool(session.case_state.data.cat_first_seen), reduced)
	session.mode = "cat"
	_build()
	show()
	_show_frame(0)
	return true

func _build() -> void:
	UI.clear(self)
	canvas = Control.new()
	canvas.size = Vector2(1600, 900)
	canvas.scale = Vector2.ONE * minf(size.x / 1600, size.y / 900)
	canvas.position = (size - canvas.size * canvas.scale) / 2
	add_child(canvas)
	var background := ColorRect.new()
	background.color = Color(0.04, 0.06, 0.08, 0.95)
	background.size = canvas.size
	canvas.add_child(background)
	cat_image = _layer()
	hand_image = _layer()
	var head := Button.new()
	head.flat = true
	head.position = Vector2(352 + 896 * 0.5533854, 180 + 504 * 0.126953)
	head.size = Vector2(896 * 0.37109375, 504 * 0.546875)
	head.pressed.connect(_touch)
	canvas.add_child(head)
	var bar := HBoxContainer.new()
	bar.position = Vector2(420, 760)
	canvas.add_child(bar)
	touch_button = UI.button(bar, "摸摸头", _touch)
	UI.button(bar, "返回调查", finish)
	UI.button(bar, "菜单", menu_requested.emit)
	touch_button.call_deferred("grab_focus")

func _layer() -> TextureRect:
	var image := TextureRect.new()
	image.position = Vector2(352, 180)
	image.size = Vector2(896, 504)
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_SCALE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(image)
	return image

func _touch() -> void:
	if not cat.touch(): return
	touch_button.disabled = true
	_show_frame(cat.frame)

func _show_frame(index: int) -> void:
	cat_image.texture = frames.cat[index]
	hand_image.texture = frames.hand[index]
	hand_image.visible = cat.touching
	frame_index = index
	# 绘制到帧末后确认仍是同一互动；提前返回、菜单隐藏不提交未显示帧。
	call_deferred("_confirm_display", index)

func _confirm_display(index: int) -> void:
	await RenderingServer.frame_post_draw
	if not visible or not cat.active or frame_index != index: return
	cat.displayed_frame(index)
	session.case_state.data.cat_first_seen = cat.first_seen

func _process(delta: float) -> void:
	if not is_visible_in_tree() or session == null or session.paused: return
	var result: Dictionary = cat.tick(delta * 1000)
	if result.is_empty(): return
	if result.purr:
		session.media_requested.emit({"event": "SND_NODE_SOUND", "instance": "cat/%s/%s" % [session.run_id, Time.get_ticks_usec()], "ref": cat.config.get("sound_ref", ""), "gain": cat.config.get("purr_gain", 0.35)})
	if result.frame != frame_index: _show_frame(int(result.frame))
	if result.finished: finish()

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))
	cat.preferences(reduced)
	if visible and cat.touching: _show_frame(cat.frame)

func finish() -> void:
	session.case_state.data.cat_first_seen = cat.first_seen
	# 只有整段2800ms互动实际完成才累加次数；提前返回不会发放奖励。
	var completed: bool = cat.touching and cat.elapsed >= cat.total_ms
	cat.finish()
	hide()
	session.mode = "investigation"
	if completed: session.complete_cat_interaction()
	closed.emit()
	session.changed.emit()

func discard() -> void:
	# 读档已替换世界时，只销毁旧动画；不能把旧首见或mode写回目标档。
	cat.finish()
	hide()
	frame_index = -1
