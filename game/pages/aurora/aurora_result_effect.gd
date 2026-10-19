extends Control
## 反馈只消费已成立的结果快照；动画、跳过和取消不取得材料，也不替玩家收下。
## 1600×900制作舞台整体等比适配，纸面、文字、碎片及操作共用同一变换。
const UI = preload("res://pages/core/page_controls.gd")
const MaterialCard = preload("res://pages/aurora/aurora_material_card.gd")
const STAGE_SIZE := Vector2(1600, 900)
const INK := Color("34413f")
signal finished
signal menu_requested
signal media_requested(request: Dictionary)

var session: Node
var elapsed_ms := 0.0
var duration_ms := 0.0
var reduced := false
var effect := {}
var paper: PanelContainer
var title: Label
var skip_button: Button
var stage: Control
var result_card: Control
var source_cards: Array[Control] = []
var active := false
var skippable := true
var kind := "normal"
var generation := 0
var collection_target := Vector2(1134.5, 685.5)
var collection_start := Vector2(800, 445)
var _paper_texture: Texture2D
var _ink_texture: Texture2D
var _quote_viewport: SubViewport
var _shards: Array[Dictionary] = []
var _effect_art: Dictionary = {}
var menu_button: Button
var collection_geometry_provider: Callable
var _collection_sound_instance := ""

func bind(value: Node) -> void:
	session = value
	session.result_presentation_requested.connect(play)
	finished.connect(session.finish_result_effect)
	resized.connect(_layout)
	hide()

func play(data: Dictionary) -> void:
	stop(false)
	effect = data.duplicate(true)
	duration_ms = maxf(1.0, float(data.get("duration_ms", 400)))
	elapsed_ms = 0.0
	kind = _effect_kind(data)
	skippable = _may_skip(data)
	active = true
	if session != null: session.processing = true
	UI.clear(self)
	_quote_viewport = null
	source_cards.clear()
	result_card = null
	_shards.clear()
	_paper_texture = _texture("assets/aurora/ui/art7/paper_v2/controls/panel_paper.png")
	_ink_texture = _texture("assets/systems/core/fx/fx_ink_link_web.png")
	_effect_art.clear()
	for asset in ["fx_flying_pages_01", "fx_flying_pages_02", "fx_flying_pages_03", "fx_flying_pages_04", "fx_flying_pages_05", "fx_brass_clip", "fx_stamp_inspiration", "paper_portrait", "paper_landscape", "progress_circle"]:
		_effect_art[asset] = _texture("assets/systems/core/fx/adopted/" + asset + ".png")
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	stage = Control.new()
	stage.name = "ResultEffectStage"
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stage)
	_build_result()
	_build_sources()
	if kind == "break": _build_glass()
	if kind in ["collect", "acquire"]: _build_collection_card()
	_build_controls()
	_layout()
	show()
	_request_sound()
	menu_button.grab_focus()
	_update_visuals()

func play_acquisition(content_id: String, hold_ms: int = 0) -> bool:
	# 所属系统仅在实际grant提交后调用。动画不补发材料，不新增保存时机。
	if session == null or active or not session.case_state.owns(content_id): return false
	play({"effect_level": "acquire", "feedback_key": "acquire", "content_id": content_id,
		"duration_ms": 400 + maxi(0, hold_ms), "animation_ms": 400, "hold_ms": maxi(0, hold_ms)})
	return true

func _effect_kind(data: Dictionary) -> String:
	var level := str(data.get("effect_level", "normal"))
	if level in ["collect", "acquire"]: return level
	if level == "key": return "insight" if data.get("effect_kind") == "涌现" else "break"
	return "progress" if level == "progress" else "normal"

func _may_skip(data: Dictionary) -> bool:
	if kind in ["collect", "acquire"]: return false
	if data.has("skippable"): return bool(data.skippable)
	if kind not in ["break", "insight"] or session == null: return true
	var question_id := str(data.get("question_ref", session.question))
	for row in session.config.tutorial_data.get("result_presentations", []):
		if str(row.get("question_ref", "")) != question_id or bool(row.get("skip_first", true)): continue
		var climax := str(data.get("climax_key", ""))
		return not climax.is_empty() and bool(session.case_state.data.climaxes.get(climax, false))
	return true

func _build_result() -> void:
	paper = PanelContainer.new()
	paper.name = "ResultInformation"
	paper.position = Vector2(180, 182)
	paper.size = Vector2(1240, 420)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxTexture.new()
	style.texture = _paper_texture
	style.texture_margin_left = 32
	style.texture_margin_top = 32
	style.texture_margin_right = 32
	style.texture_margin_bottom = 36
	style.content_margin_left = 48
	style.content_margin_right = 48
	style.content_margin_top = 36
	style.content_margin_bottom = 36
	paper.add_theme_stylebox_override("panel", style)
	stage.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paper.add_child(column)
	var caption := UI.label(column, "本次核查" if kind != "acquire" else "材料已记录", 24)
	_style_label(caption)
	var result_row: Dictionary = session.config.results.get(str(session.pending_result.get("result", "")), {})
	var content_id := str(effect.get("content_id", result_row.get("inference_content_ref", "")))
	var content: Dictionary = session.config.contents.get(content_id, {})
	var heading_text := str(content.get("name", ""))
	if heading_text.is_empty(): heading_text = session.target_text()
	var heading := UI.label(column, heading_text, 36)
	_style_label(heading, true)
	heading.max_lines_visible = 3
	var body := RichTextLabel.new()
	body.name = "ResultEffectBody"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.scroll_active = true
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	body.focus_mode = Control.FOCUS_NONE
	body.add_theme_color_override("default_color", INK)
	body.add_theme_font_size_override("normal_font_size", 26)
	var font := _font(false)
	if font != null: body.add_theme_font_override("normal_font", font)
	body.text = str(content.get("detail_text", session.pending_result.get("text", "依据已核对。")))
	column.add_child(body)
	title = Label.new()
	title.name = "ResultEffectTitle"
	title.position = Vector2(160, 632)
	title.size = Vector2(1280, 110)
	title.text = {"break": "矛盾击破", "insight": "灵感涌现", "progress": "递进推理", "collect": "收下推论", "acquire": "已获得材料"}.get(kind, "进一步确认")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 76 if kind in ["break", "insight"] else 52)
	title.add_theme_color_override("font_color", Color("f4edda"))
	var title_font := _font(true)
	if title_font != null: title.add_theme_font_override("font", title_font)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(title)

func _build_sources() -> void:
	for id in session.pending_result.get("refs", []):
		if not session.config.contents.has(id): continue
		var card := MaterialCard.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.focus_mode = Control.FOCUS_NONE
		card.size = Vector2(130, 195)
		card.position = Vector2(1240 + 112 * source_cards.size(), 625)
		stage.add_child(card)
		card.configure(session, str(id), true)
		source_cards.append(card)

func _build_controls() -> void:
	var menu := Button.new()
	menu_button = menu
	menu.name = "ResultEffectMenu"
	menu.text = "菜单"
	menu.position = Vector2(1430, 26)
	menu.size = Vector2(128, 48)
	menu.pressed.connect(menu_requested.emit)
	stage.add_child(menu)
	_style_button(menu)
	skip_button = Button.new()
	skip_button.name = "SkipResultEffect"
	skip_button.text = "跳过表现"
	skip_button.position = Vector2(1294, 826)
	skip_button.size = Vector2(264, 48)
	skip_button.visible = skippable
	skip_button.disabled = not skippable
	skip_button.pressed.connect(skip)
	stage.add_child(skip_button)
	_style_button(skip_button)
	if not skippable and kind in ["break", "insight"]:
		var note := Label.new()
		note.name = "FirstResultEffectNotice"
		note.text = "首次核查演出 · 可按 Esc 暂停"
		note.position = Vector2(400, 831)
		note.size = Vector2(800, 36)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note.add_theme_font_size_override("font_size", 24)
		note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stage.add_child(note)
	if kind == "acquire":
		for row in session.config.tutorial_data.get("acquisition_feedback", []):
			if str(row.get("content_ref", "")) != str(effect.get("content_id", "")): continue
			var hint := Label.new()
			hint.name = "AcquisitionHint"
			hint.text = session.config.text(str(row.get("text_ref", "")))
			hint.position = Vector2(340, 818)
			hint.size = Vector2(920, 50)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			hint.add_theme_font_size_override("font_size", 24)
			hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stage.add_child(hint)
func _build_collection_card() -> void:
	var id := str(effect.get("content_id", ""))
	if not session.config.contents.has(id): return
	var card := MaterialCard.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.focus_mode = Control.FOCUS_NONE
	card.size = Vector2(260, 390)
	stage.add_child(card)
	card.configure(session, id, false)
	for label in card.find_children("*", "Label", true, false):
		if label.text == "点击查看": label.hide()
	card.name = "CollectingMaterialCard"
	result_card = card
	# 宿主可传实际手牌目标，否则读取当前可见牌的真实几何；均不飞向手册。
	collection_target = Vector2(1134.5, 685.5)
	if size.x / maxf(size.y, 1.0) <= 1.4:
		collection_target = Vector2(910.5, 693) * (STAGE_SIZE / Vector2(1200, 900))
	var provided: Variant = collection_geometry_provider.call(id) if collection_geometry_provider.is_valid() else null
	if provided is Rect2 and provided.has_area():
		collection_target = _to_reference(provided.get_center())
	elif effect.get("target_rect") is Rect2:
		var target: Rect2 = effect.target_rect
		collection_target = _to_reference(target.get_center())
	else:
		var fan := get_tree().root.find_child("ShallowFan", true, false) as Control
		if is_instance_valid(fan):
			var last_visible: Control
			for child in fan.get_children():
				if child is Control and child.is_visible_in_tree() and str(child.name).begins_with("Card_"):
					last_visible = child
					if str(child.name) == "Card_" + id: break
			if is_instance_valid(last_visible): collection_target = _to_reference(last_visible.get_global_rect().get_center())
	collection_start = Vector2(800, 445)

func _build_glass() -> void:
	# 正文和纸纹渲染为同一纹理；裂片使用原UV，文字与玻璃同步移动。
	_quote_viewport = SubViewport.new()
	_quote_viewport.name = "GlassQuoteSource"
	_quote_viewport.size = Vector2i(1428, 564)
	_quote_viewport.transparent_bg = true
	_quote_viewport.disable_3d = true
	_quote_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_quote_viewport)
	var page := NinePatchRect.new()
	page.texture = _paper_texture
	page.size = Vector2(1428, 564)
	page.patch_margin_left = 32
	page.patch_margin_right = 32
	page.patch_margin_top = 32
	page.patch_margin_bottom = 36
	_quote_viewport.add_child(page)
	var heading := Label.new()
	heading.position = Vector2(58, 40)
	heading.size = Vector2(1312, 60)
	heading.text = "指定原话 · 本次核对"
	heading.add_theme_font_size_override("font_size", 30)
	_style_label(heading)
	_quote_viewport.add_child(heading)
	var quote := Label.new()
	quote.position = Vector2(58, 144)
	quote.size = Vector2(1312, 330)
	quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quote.text = session.target_text()
	quote.add_theme_font_size_override("font_size", 54)
	_style_label(quote, true)
	_quote_viewport.add_child(quote)
	var seeds: Array[Vector2] = [Vector2(648, 177)]
	for ring in [[9, 88.0, 65.0], [15, 275.0, 172.0], [19, 620.0, 350.0]]:
		for index in range(int(ring[0])):
			var angle := (index + 0.18 * _noise(index, 2)) * TAU / float(ring[0]) + float(ring[1]) * 0.0041
			var radius := 0.81 + 0.29 * _noise(index + 20, 3)
			seeds.append(Vector2(clampf(648 + cos(angle) * float(ring[1]) * radius, 8, 1420), clampf(177 + sin(angle) * float(ring[2]) * radius, 8, 556)))
	seeds.append_array([Vector2(20, 540), Vector2(1404, 24), Vector2(1406, 544)])
	for index in range(seeds.size()):
		var polygon := PackedVector2Array([Vector2.ZERO, Vector2(1428, 0), Vector2(1428, 564), Vector2(0, 564)])
		for other in range(seeds.size()):
			if other == index: continue
			var normal := seeds[other] - seeds[index]
			polygon = _clip_half_plane(polygon, normal, (seeds[other].length_squared() - seeds[index].length_squared()) / 2.0)
			if polygon.size() < 3: break
		if polygon.size() < 3: continue
		var center := Vector2.ZERO
		for point in polygon: center += point
		center /= polygon.size()
		_shards.append({"polygon": polygon, "center": center, "distance": center.distance_to(Vector2(648, 177)) / 960.0})

func _clip_half_plane(points: PackedVector2Array, normal: Vector2, distance: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	for index in range(points.size()):
		var first := points[index]
		var last := points[(index + 1) % points.size()]
		var a := first.dot(normal) - distance
		var b := last.dot(normal) - distance
		if a <= 0.0001: result.append(first)
		if (a < 0) != (b < 0): result.append(first.lerp(last, a / (a - b)))
	return result

func _process(delta: float) -> void:
	if not active or not is_visible_in_tree() or session == null or session.paused: return
	elapsed_ms += maxf(0.0, delta) * 1000.0
	_update_visuals()
	if elapsed_ms >= duration_ms: _finish_generation(generation)

func _update_visuals() -> void:
	if not active or not is_instance_valid(paper): return
	var t := elapsed_ms
	paper.visible = kind not in ["collect", "acquire"]
	title.visible = true
	title.position.y = 632
	for card in source_cards: card.visible = kind not in ["collect", "acquire"]
	if reduced:
		paper.scale = Vector2.ONE
		paper.modulate.a = 1.0
		title.modulate.a = 1.0
	elif kind == "break":
		paper.modulate.a = _unit(t, 1840, 2580)
		title.modulate.a = _unit(t, 3000, 3120)
	elif kind == "insight":
		paper.modulate.a = _unit(t, 4860, 5140)
		title.position.y = 382 if t < 3880 else 632
		title.modulate.a = _unit(t, 1900, 2050) * (1.0 - _unit(t, 3600, 3880)) if t < 4860 else _unit(t, 4860, 5140)
	elif kind == "progress":
		paper.modulate.a = _unit(t, 1200, 1740)
		paper.scale.y = lerpf(0.06, 1.0, _ease_out(_unit(t, 1200, 1740)))
		title.modulate.a = _unit(t, 1360, 1520)
	else:
		paper.modulate.a = 1.0 if reduced else _unit(t, 0, 160)
		title.modulate.a = paper.modulate.a
	if is_instance_valid(result_card):
		var u := _unit(t, 0, 900) if kind == "collect" else _unit(t, 0, float(effect.get("animation_ms", 400)))
		var travel := 0.0 if reduced or kind == "acquire" else _ease_out(u)
		var card_scale := 1.0 if reduced else lerpf(1.0 if kind == "collect" else 0.82, 0.56 if kind == "collect" else 1.0, travel if kind == "collect" else _ease_out(u))
		result_card.scale = Vector2.ONE * card_scale
		result_card.position = collection_start.lerp(collection_target, travel) - result_card.size * card_scale / 2.0
		result_card.modulate.a = 1.0 if reduced else _unit(t, 0, 100)
		title.position.y = 110 if kind == "collect" else 720
		if kind == "collect" and t <= 900 and not _collection_sound_instance.is_empty():
			var global_center := result_card.get_global_transform_with_canvas() * (result_card.size / 2.0)
			var local_center := get_global_transform_with_canvas().affine_inverse() * global_center
			media_requested.emit({"command": "set_pan", "instance": _collection_sound_instance,
				"pan": clampf((local_center.x / maxf(size.x, 1.0) * 2.0 - 1.0) * 0.36, -0.25, 0.25)})
	queue_redraw()

func _draw() -> void:
	if not active: return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.055, 0.05, 0.94 if kind in ["break", "insight"] else 0.78))
	var factor := minf(size.x / STAGE_SIZE.x, size.y / STAGE_SIZE.y)
	draw_set_transform((size - STAGE_SIZE * factor) / 2.0, 0, Vector2.ONE * factor)
	if not reduced:
		if kind == "break": _draw_glass(elapsed_ms)
		elif kind == "insight": _draw_inspiration(elapsed_ms)
		elif kind == "progress": _draw_progress(elapsed_ms)
	draw_set_transform(Vector2.ZERO)

func _draw_glass(t: float) -> void:
	if not is_instance_valid(_quote_viewport): return
	var texture := _quote_viewport.get_texture()
	var pane := Rect2(86, 158, 1428, 564)
	if t < 1520:
		var grow := _ease_out(_unit(t, 400, 520))
		var frame := Rect2(pane.get_center() - pane.size * lerpf(0.58, 1.0, grow) / 2.0, pane.size * lerpf(0.58, 1.0, grow))
		draw_texture_rect(texture, frame, false, Color(1, 1, 1, _unit(t, 0, 400)))
		if t >= 650:
			for shard in _shards:
				if float(shard.distance) > _unit(t, 650, 1050): continue
				var edges := PackedVector2Array()
				for point in shard.polygon: edges.append(point + pane.position)
				edges.append(edges[0])
				draw_polyline(edges, Color("304a40"), 2.1, true)
				draw_polyline(edges, Color(1.0, 0.97, 0.88, 0.8), 0.75, true)
	elif t < 2580:
		for index in range(_shards.size()):
			var shard := _shards[index]
			var center: Vector2 = shard.center
			var birth := 1520.0 + float(shard.distance) * 155.0
			var age := t - birth
			var u := _unit(age, 50, minf(650 + _noise(index, 5) * 360, 2580 - birth))
			if u >= 1.0: continue
			var depth := 1.85 if index % 5 == 0 else 0.65 + _noise(index, 6) * 0.45
			var travel := _ease_out(u)
			var shift := ((center - Vector2(648, 177)) * 2.0 + Vector2((_noise(index, 7) - 0.5) * 270 - 100, (_noise(index, 8) - 0.5) * 320 - 65)) * travel * depth
			var angle := (_noise(index, 9) - 0.5) * 2.6 * u
			var stretch := Vector2(maxf(0.06, absf(cos(u * 3.0))) * lerpf(1.0, 0.48, u), lerpf(1.0, 0.72, u))
			var points := PackedVector2Array()
			var uvs := PackedVector2Array()
			for point in shard.polygon:
				points.append((point - center).rotated(angle) * stretch + center + shift + pane.position)
				uvs.append(point / pane.size)
			draw_polygon(points, PackedColorArray([Color(1, 1, 1, 1.0 - _unit(u, 0.76, 1.0))]), uvs, texture)
	# 墨线接触原话后产生裂纹，不使用全屏白闪。
	if t >= 520 and t < 1740:
		var end := Vector2(1190, 610).lerp(Vector2(734, 335), _unit(t, 520, 650))
		draw_line(Vector2(1190, 610), end, Color(0.20, 0.30, 0.25, 1.0 - _unit(t, 1580, 1740)), 8, true)

func _draw_inspiration(t: float) -> void:
	if _ink_texture != null and t > 900 and t < 4180:
		var alpha := minf(0.65, _unit(t, 900, 1500)) * (1.0 - _unit(t, 3580, 4180))
		draw_texture_rect(_ink_texture, Rect2(290, 146, 1040, 541), false, Color(1, 1, 1, alpha))
	if _paper_texture == null: return
	for index in range(28):
		var u := (t - (900 + index * 110)) / 1400.0
		if u < 0.0 or u >= 1.0: continue
		var side := -1.0 if index % 2 else 1.0
		var depth := 1.35 if index % 5 == 0 else 0.72
		var width := (116 + index % 4 * 9) * depth * (0.72 + 0.58 * sin(PI * u))
		var point := Vector2(800 + side * (sin(PI * u) * 490 + 180 * u) + sin(float(index)) * 28, 846 - 1040 * u)
		var flip := 0.12 + 0.88 * absf(cos(u * PI * 2.2 + index * 0.7))
		var color := Color(1, 1, 1, _unit(u, 0, 0.06) * (1.0 - _unit(u, 0.87, 1.0)))
		var rect := Rect2(-width * flip / 2, -width * 1.5 / 2, width * flip, width * 1.5)
		var page_texture: Texture2D = _effect_art.get("fx_flying_pages_%02d" % (index % 5 + 1), _paper_texture)
		_draw_sheet(point, side * (u * 1.88 - 0.45), rect, color, page_texture)
	if t >= 1900 and t < 3880:
		var stamp: Texture2D = _effect_art.get("fx_stamp_inspiration")
		if stamp != null:
			var stamp_alpha := _unit(t, 1900, 1960) * (1.0 - _unit(t, 3600, 3880))
			draw_texture_rect(stamp, Rect2(290, 320, 1020, 255), false, Color(1, 1, 1, stamp_alpha))
	if t >= 2050 and t < 3000:
		var clip: Texture2D = _effect_art.get("fx_brass_clip")
		if clip != null: draw_texture_rect(clip, Rect2(1131, 142, 62, 204), false, Color(1, 1, 1, _unit(t, 2050, 2200) * (1.0 - _unit(t, 2790, 3000))))
	if t >= 3550 and t < 5140:
		var last_page: Texture2D = _effect_art.get("paper_portrait")
		var u := _unit(t, 3550, 4180)
		var point := Vector2(800 - 310 * sin(PI * u) - 90 * u, 900 - 1150 * u + 730 * u * u)
		var page_scale := lerpf(0.32, 1.0, _ease_out(u))
		var angle := lerpf(-0.64, 0.12, _ease_out(u))
		if t >= 4290:
			var slide := _ease_out(_unit(t, 4290, 4860))
			point = Vector2(710, 480).lerp(Vector2(860, 438), slide)
			angle = lerpf(0.12, 0.0, slide)
		_draw_sheet(point, angle, Rect2(Vector2(-180, -270) * page_scale, Vector2(360, 540) * page_scale), Color(1, 1, 1, 1.0 - _unit(t, 4860, 5140)), last_page)

func _draw_sheet(center: Vector2, angle: float, bounds: Rect2, color: Color, sheet_texture: Texture2D = null) -> void:
	var points := PackedVector2Array()
	for point in [bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)]: points.append(point.rotated(angle) + center)
	draw_polygon(points, PackedColorArray([color]), PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2.ONE, Vector2(0, 1)]), sheet_texture if sheet_texture != null else _paper_texture)

func _draw_progress(t: float) -> void:
	var u := _ease_out(_unit(t, 440, 1060))
	for index in range(mini(source_cards.size(), 2)):
		var start := Vector2(400 + index * 800, 450)
		var end := Vector2(760 + index * 80, 410)
		draw_line(start.lerp(end, u), Vector2(800, 410), Color(0.34, 0.38, 0.27, 1.0 - _unit(t, 1800, 2100)), 4, true)
	if t >= 1520 and t < 2580:
		var circle_texture: Texture2D = _effect_art.get("progress_circle")
		if circle_texture != null:
			var source := circle_texture.get_size()
			var top_width := _unit(t, 1520, 1740)
			var bottom_width := _unit(t, 1740, 1900)
			if top_width > 0:
				draw_texture_rect_region(circle_texture, Rect2(582, 625, 436 * top_width, 77), Rect2(0, 0, source.x * top_width, source.y / 2.0))
			if bottom_width > 0:
				draw_texture_rect_region(circle_texture, Rect2(1018 - 436 * bottom_width, 702, 436 * bottom_width, 77), Rect2(source.x * (1.0 - bottom_width), source.y / 2.0, source.x * bottom_width, source.y / 2.0))

func _layout() -> void:
	if not is_instance_valid(stage): return
	var factor := minf(size.x / STAGE_SIZE.x, size.y / STAGE_SIZE.y)
	stage.scale = Vector2.ONE * factor
	stage.position = (size - STAGE_SIZE * factor) / 2.0
	stage.size = STAGE_SIZE
	queue_redraw()

func _to_reference(global_point: Vector2) -> Vector2:
	var factor := minf(size.x / STAGE_SIZE.x, size.y / STAGE_SIZE.y)
	return (get_global_transform_with_canvas().affine_inverse() * global_point - (size - STAGE_SIZE * factor) / 2.0) / maxf(0.001, factor)

func set_preferences(values: Dictionary) -> void:
	reduced = bool(values.get("reduce_motion", false))
	if active: _update_visuals()

func skip() -> void:
	if active and skippable:
		media_requested.emit({"command": "stop_node"})
		stop()

func _finish_generation(expected: int) -> void:
	# 取消与换演出使旧回执失效，尤其避免低动态模式的延后完成误伤新结果。
	if expected == generation and active: stop()

func stop(notify_completion: bool = true) -> void:
	var was_active := active
	active = false
	_collection_sound_instance = ""
	generation += 1
	if was_active and session != null: session.processing = false
	hide()
	queue_redraw()
	if was_active and notify_completion: finished.emit()

func _input(event: InputEvent) -> void:
	if not active or not is_visible_in_tree() or session == null or session.paused: return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			menu_requested.emit()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_TAB:
			# 模态反馈中的Tab只在当前菜单/跳过之间移动，不聚焦后方收下或出示。
			var choices: Array[Button] = [menu_button]
			if skippable: choices.append(skip_button)
			var current := choices.find(get_viewport().gui_get_focus_owner())
			var direction := -1 if event.shift_pressed else 1
			choices[posmod(current + direction, choices.size())].grab_focus()
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			var owner := get_viewport().gui_get_focus_owner()
			if owner == null or not is_ancestor_of(owner):
				skip()
				get_viewport().set_input_as_handled()
		else:
			get_viewport().set_input_as_handled()
	# 鼠标由真实按钮和全屏Control拦截，不直接将背景点击当作跳过。
func _request_sound() -> void:
	# 声音仍交统一服务，页面不创建自己的播放器或改总线音量。
	var sound := str(effect.get("sound", ""))
	if sound.is_empty():
		sound = {"break": "SFX_CORE_BREAKTHROUGH", "insight": "SFX_CORE_INSIGHT", "progress": "SFX_CORE_PROGRESS", "collect": "SFX_CARD_COLLECT", "acquire": "SFX_CARD_ACQUIRE"}.get(kind, "")
	if sound.is_empty(): return
	var identity := "aurora_result/%d/%d" % [get_instance_id(), generation]
	var request := {"event": "SND_RESULT", "ref": sound, "instance": identity}
	_collection_sound_instance = identity if kind == "collect" else ""
	if kind == "collect": request.pan = 0.0
	media_requested.emit(request)
func _style_label(label: Label, strong: bool = false) -> void:
	label.add_theme_color_override("font_color", INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := _font(strong)
	if font != null: label.add_theme_font_override("font", font)

func _style_button(button: Button) -> void:
	button.add_theme_font_size_override("font_size", 24)
	var font := _font(true)
	if font != null: button.add_theme_font_override("font", font)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var image := _texture("assets/aurora/ui/art7/paper_v2/controls/button_secondary_" + state + ".png")
		if image == null: continue
		var box := StyleBoxTexture.new()
		box.texture = image
		box.texture_margin_left = 16
		box.texture_margin_top = 12
		box.texture_margin_right = 16
		box.texture_margin_bottom = 16
		box.content_margin_left = 20
		box.content_margin_right = 20
		box.content_margin_top = 9
		box.content_margin_bottom = 9
		button.add_theme_stylebox_override(state, box)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_color_override("font_focus_color", INK)
func _texture(relative: String) -> Texture2D:
	var path := str(session.config.definition.root).path_join(relative)
	return load(path) as Texture2D if ResourceLoader.exists(path) else null

func _font(strong: bool) -> Font:
	var path := str(session.config.definition.root).path_join("assets/aurora/ui/a/fonts/DreamHanSansCN-%s.ttf" % ("W16" if strong else "W12"))
	return load(path) as Font if ResourceLoader.exists(path) else null

func _unit(value: float, first: float, last: float) -> float:
	return clampf((value - first) / maxf(last - first, 0.001), 0.0, 1.0)

func _ease_out(value: float) -> float: return 1.0 - pow(1.0 - value, 3)
func _noise(index: int, salt: int) -> float: return fposmod(sin(index * 127.1 + salt * 311.7) * 43758.5453, 1.0)
