extends Control
## 文案页面私有逻辑：逐字显示、点击继续、跳转选择和输入焦点。

const UI = preload("res://pages/core/page_controls.gd")
const StageScript = preload("res://pages/narrative/narrative_stage.gd")
const CutinScript = preload("res://pages/narrative/narrative_cutin.gd")
# 人名与正文的区分：更大的字号、暖色和深色描边；内心独白的名字沿用冷色。
const NAME_FONT_SIZE := 36
const NAME_COLOR := Color("f2d8a0")
const INNER_NAME_COLOR := Color("b8cdd8")
const NAME_OUTLINE_COLOR := Color(0.04, 0.07, 0.1, 0.95)
const NAME_OUTLINE_SIZE := 6
# 分页：每页行数，以及自然断点的取舍。
const PAGE_LINES := 2
const SENTENCE_MARKS := "。！？…"
const CLAUSE_MARKS := "，、；："
const LINE_START_FORBIDDEN := "，。、；：！？）》」』”’…—·"
const MIN_SENTENCE_FILL := 0.4 # 句末断点至少要占满本页的这一比例，否则宁可多排一点
const MIN_CLAUSE_FILL := 0.6
const STUB_CHARS := 10 # 末页不足这个字数就算残页，向前借一个断点
signal inspection_close_requested
signal menu_requested
signal handbook_requested
signal records_requested
var stage: Control
var service: Node
var text_label: RichTextLabel
var name_label: Label
var choices: VBoxContainer
var title_label: Label
var background: TextureRect
var actor: TextureRect
var render_queued := false
var fast_button: Button
var skip_button: Button
var pagination_ready := false
var layout_canvas: Control
var status_message := ""
var pending_ending := false
var inspection_close_available := false
var formal_ui: Dictionary = {}
var formal_config: RefCounted
var text_speed_level := 2
var typing_sound_serial := 0
var chapter_fade_elapsed := 0.0
var cutin: TextureRect
var image_brightness := 100
var shared_tools_managed := false

func set_preferences(values: Dictionary) -> void:
	image_brightness = int(values.get("brightness", 100))
	text_speed_level = int(values.get("text_speed", 2))
	if service != null: service.set_text_speed(text_speed_level)
	if is_instance_valid(stage): stage.reduced = bool(values.get("reduce_motion", false))
	if is_instance_valid(stage): stage.set_brightness(image_brightness)

func set_inspection_close_available(value: bool) -> void:
	if inspection_close_available == value: return
	inspection_close_available = value
	_queue_render()

func resume_after_shared_tool() -> void:
	## 共享手册/回顾关闭后强制恢复对白舞台并安排一次完整重绘。
	##
	## 打开目标回顾时 narrative_page 可能仍处在 reading_log 状态；此状态下
	## _render() 会暂时保留现有控件。如果同一帧又切换到新的对白入口，原先
	## 排队的渲染可能已经返回，导致舞台继续隐藏，表现为黑屏，直到 Esc 再次
	## 触发刷新。该公开方法由页面容器在关闭共享工具后调用，避免跨页直接
	## 修改本页的私有控件。
	if is_instance_valid(stage): stage.show()
	render_queued = false
	_queue_render()

func bind(value: Node) -> void:
	service = value
	_load_formal_ui()
	if not service.changed.is_connected(_queue_render): service.changed.connect(_queue_render)
	if not service.progressed.is_connected(_on_progressed): service.progressed.connect(_on_progressed)
	if not service.text_started.is_connected(_on_text_started): service.text_started.connect(_on_text_started)
	if not service.notice.is_connected(_on_notice): service.notice.connect(_on_notice)
	if not service.typing_sound_requested.is_connected(_on_typing_sound): service.typing_sound_requested.connect(_on_typing_sound)
	service.set_text_speed(text_speed_level)
	if is_instance_valid(stage) and formal_config != null: stage.configure_formal(formal_config)
	if is_instance_valid(cutin): cutin.bind(self)
	_queue_render()

func _ready() -> void:
	stage = StageScript.new()
	stage.name = "NarrativeStage"
	stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(stage)
	stage.set_brightness(image_brightness)
	cutin = CutinScript.new()
	cutin.name = "NarrativeCutin"
	stage.add_child(cutin)
	cutin.bind(self)
	if formal_config != null: stage.configure_formal(formal_config)
	resized.connect(_queue_render)
	set_process(true)
	mouse_filter = Control.MOUSE_FILTER_STOP

func _process(delta: float) -> void:
	if service != null and is_visible_in_tree() and not service.hidden and not service.reading_log and is_instance_valid(text_label) and str(service.current_record().get("text_type", "")) == "章节字幕":
		chapter_fade_elapsed += delta
		text_label.modulate.a = _chapter_fade_alpha()
	# 页末等待也需要时钟；只在逐字期间 tick 会让快读永远停在第一页。
	if pagination_ready and is_visible_in_tree() and service != null and not service.state.is_empty() and not (is_instance_valid(cutin) and cutin.is_blocking()) and (service.is_typing() or not service.fast_mode.is_empty() or service.stage_wait_left > 0): service.tick(delta)

func _queue_render(_unused = null) -> void:
	if not is_inside_tree() or render_queued: return
	render_queued = true
	call_deferred("_render")

func _render() -> void:
	render_queued = false
	if pending_ending: return
	if service == null or service.state.is_empty(): return
	# 全局工具保留当前舞台和阅读控件；reading_log只负责冻结正文时钟。
	if shared_tools_managed and service.reading_log: return
	service.set_text_speed(text_speed_level) # 读档恢复阅读进度时仍沿当前独立设置，不继承旧档字速。
	stage.visible = not service.reading_log
	for child in get_children():
		if child == stage: continue
		remove_child(child)
		child.queue_free()
	_render_scene_information()
	if service.hidden:
		var restore := _button(self, "显示对白", service.set_hidden.bind(false))
		restore.z_index = 20
		restore.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		restore.position = Vector2(24, size.y - 64)
		restore.grab_focus()
		return
	if service.reading_log:
		_render_log()
		return
	# 全部阅读组件共用 1600×900 逻辑画布，窗口留边与舞台保持一致。
	layout_canvas = Control.new()
	layout_canvas.size = Vector2(1600, 900)
	var factor := minf(size.x / 1600.0, size.y / 900.0)
	layout_canvas.scale = Vector2.ONE * factor
	layout_canvas.position = (size - layout_canvas.size * factor) / 2
	layout_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout_canvas.z_index = 20
	add_child(layout_canvas)
	var row: Dictionary = service.current_record()
	var kind := str(row.get("text_type", ""))
	var formal := not formal_ui.is_empty()
	# 正式时地页沿下方阅读带显示；章节标题仍使用原中央字幕位置。
	var subtitle := kind in ["章节字幕", "字幕"] or (not formal and kind == "时间字幕")
	var time_place := kind == "时间字幕"
	var avatar := _avatar_for(row) if not subtitle and kind not in ["旁白", "narration"] else null
	if formal and (time_place or kind in ["内心", "inner"] and str(row.get("character_id", "")) == "CHR01"): avatar = null
	var left := 224.0 if avatar != null else 96.0
	if formal:
		_paper(Rect2(200, 200, 1200, 200) if subtitle else Rect2(0, 633.333, 1600, 266.667))
	elif not subtitle:
		var band := TextureRect.new()
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0, 0.32, 1])
		gradient.colors = PackedColorArray([Color(0.063, 0.106, 0.145, 0), Color(0.063, 0.106, 0.145, 0.82), Color(0.063, 0.106, 0.145, 0.9)])
		var texture := GradientTexture2D.new()
		texture.gradient = gradient
		texture.fill_from = Vector2(0, 0)
		texture.fill_to = Vector2(0, 1)
		band.texture = texture
		_place(band, Rect2(0, 622, 1600, 278))
		band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if avatar != null:
		var portrait := TextureRect.new()
		portrait.name = "DialogueAvatar"
		portrait.texture = avatar
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(portrait, _dialogue_rect("avatar_rect_default_px", Rect2(80, 694, 112, 112)) if formal else Rect2(80, 694, 112, 112))
	var inner := kind in ["内心", "inner"]
	var speaker := str(row.get("speaker_name", row.get("character_name", "")))
	if formal and inner and str(row.get("character_id", "")) == "CHR01": speaker = "艾琳（心声）"
	name_label = UI.label(layout_canvas, speaker + (" · 内心" if inner and not formal else ""), NAME_FONT_SIZE)
	name_label.add_theme_color_override("font_color", INNER_NAME_COLOR if inner else NAME_COLOR)
	name_label.add_theme_color_override("font_outline_color", NAME_OUTLINE_COLOR)
	name_label.add_theme_constant_override("outline_size", NAME_OUTLINE_SIZE)
	_place(name_label, Rect2(left, 650, 600, 50))
	if formal:
		_place(name_label, _dialogue_rect("name_rect_default_px" if avatar != null else "no_avatar_name_rect_default_px", Rect2(left, 683.333, 1416 - left, 30)))
		name_label.add_theme_font_size_override("font_size", int(formal_ui.get("font_size_default_px", {}).get("speaker", 24)))
		name_label.add_theme_color_override("font_color", Color(str(formal_ui.get("colors", {}).get("speaker", "#3F6B4C"))))
		name_label.add_theme_constant_override("outline_size", 0)
		_apply_formal_font(name_label, "font", "font_emphasis")
	# 姓名和正文是阅读画布的装饰/文本层；点击它们也要交给本页继续阅读，
	# 不能让 RichTextLabel 把鼠标事件截在自己内部。
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.visible = kind not in ["旁白", "narration", "章节字幕", "时间字幕", "字幕"]
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.tooltip_text = name_label.text
	text_label = UI.body(layout_canvas, service.visible_text(), 0)
	_place(text_label, Rect2(left, 710, 1416 - left, 96))
	if formal:
		_place(text_label, _dialogue_rect("body_rect_default_px" if avatar != null else "no_avatar_body_rect_default_px", Rect2(left, 736.667, 1416 - left, 86)))
	text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_label.bbcode_enabled = false
	text_label.scroll_active = false
	text_label.add_theme_font_size_override("normal_font_size", 32)
	if formal:
		text_label.add_theme_font_size_override("normal_font_size", int(formal_ui.get("font_size_default_px", {}).get("time_location" if time_place else "dialogue", 28)))
		_apply_formal_font(text_label, "normal_font", "font_regular")
	text_label.add_theme_color_override("default_color", Color("f0ede5"))
	if kind in ["内心", "inner"]: text_label.add_theme_color_override("default_color", Color("b8cdd8"))
	elif kind in ["旁白", "narration"]: text_label.add_theme_color_override("default_color", Color("d7dfe3"))
	if formal:
		text_label.add_theme_color_override("default_color", Color(str(formal_ui.get("colors", {}).get("time_location" if time_place else "body", "#34413F"))))
		# 两行正文按公参43px行高排版；不能继承主题的旧行距。
		var font_height := text_label.get_theme_font("normal_font").get_height(text_label.get_theme_font_size("normal_font_size"))
		text_label.add_theme_constant_override("line_separation", maxi(0, roundi(float(formal_ui.get("line_height_default_px", {}).get("body", 43)) - font_height)))
	# 正式表逐条声明颜色；旧表没有此列时保留原来的类型配色。
	var configured_color := str(row.get("font_color", ""))
	if not configured_color.is_empty() and Color.html_is_valid(configured_color): text_label.add_theme_color_override("default_color", Color(configured_color))
	if subtitle:
		_place(text_label, Rect2(200, 220, 1200, 160))
		text_label.add_theme_font_size_override("normal_font_size", 44 if kind == "章节字幕" else 32)
		if kind == "章节字幕": text_label.modulate.a = _chapter_fade_alpha()
	# 按实际字体的字形宽度计算两行分页；正文区不滚动、不截断长句。
	call_deferred("_paginate", text_label)
	choices = VBoxContainer.new()
	choices.visible = false
	_place(choices, Rect2(1130, 300, 400, 250) if formal else Rect2(600, 340, 720, 200))
	choices.add_theme_constant_override("separation", 16)
	var footer := HBoxContainer.new()
	_place(footer, Rect2(224, 828, 920, 48) if formal else Rect2(900, 850, 676, 36))
	footer.add_theme_constant_override("separation", 12)
	if not formal: _button(footer, "记录", service.set_log_open.bind(true))
	_button(footer, "隐藏", service.set_hidden.bind(true), not service.state.get("waiting_for_choice", false))
	fast_button = _button(footer, "加速", func(): pass, service.fast_read_available())
	fast_button.button_down.connect(service.begin_fast_read.bind("accelerate"))
	fast_button.button_up.connect(service.stop_fast_read)
	skip_button = _button(footer, "停止跳过" if service.fast_mode == "skip" else "跳过", _toggle_skip, service.fast_read_available())
	skip_button.name = "DialogueSkip"
	_button(footer, "菜单", menu_requested.emit)
	if formal:
		var handbook := _button(layout_canvas, "手册", handbook_requested.emit)
		_place(handbook, Rect2(1216, 820, 170, 48))
		var record := _button(layout_canvas, "对白记录", _open_records)
		_place(record, Rect2(1398, 820, 170, 48))
	for control in [fast_button, skip_button]: control.tooltip_text = "仅可用于已看过的对话"
	if inspection_close_available:
		var close := _button(layout_canvas, "返回调查", inspection_close_requested.emit)
		_place(close, Rect2(28, 832, 180, 48))
	_render_choices()
	if not status_message.is_empty():
		var status := UI.label(layout_canvas, status_message, 22)
		_place(status, Rect2(96, 580, 1320, 40))

func _load_formal_ui() -> void:
	formal_ui.clear()
	formal_config = null
	if service == null or service.get("session") == null: return
	formal_config = service.session.config
	var path: String = str(formal_config.definition.root).path_join("02_文案/文案UI资源配置.json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return
	var data = JSON.parse_string(file.get_as_text())
	if data is Dictionary: formal_ui = data
	service.configure_playback(formal_ui.get("text_playback", {}))
	service.set_text_speed(text_speed_level)

func _on_typing_sound(resource_ref: String) -> void:
	if service == null or service.get("session") == null: return
	typing_sound_serial += 1
	service.session.media_requested.emit({"event": "SND_NODE_SOUND", "instance": "typing/%d/%d" % [get_instance_id(), typing_sound_serial], "ref": resource_ref, "options": {"drop_if_busy": true}})

func _render_scene_information() -> void:
	if formal_config == null or service == null or service.get("session") == null: return
	var id: String = service.session.display_scene()
	var name_id := str(formal_config.scenes.get(id, {}).get("name_text_id", ""))
	if name_id.is_empty(): return
	var info := UI.label(self, formal_config.text(name_id), int(formal_ui.get("scene_info", {}).get("font_size_default_px", 24)))
	info.name = "SceneInformation"
	info.autowrap_mode = TextServer.AUTOWRAP_OFF
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.z_index = 25
	var factor := minf(size.x / 1600.0, size.y / 900.0)
	info.position = (size - Vector2(1600, 900) * factor) / 2.0 + Vector2(28, 24) * factor
	info.scale = Vector2.ONE * factor
	info.add_theme_color_override("font_color", Color("#34413F"))
	_apply_formal_font(info, "font", "font_emphasis")
	# 场景明暗变化很大；同一浅纸信息底保证雪景和室内都能读清地点。
	var plate := PanelContainer.new()
	plate.name = "SceneInformationPaper"
	plate.position = info.position
	plate.scale = info.scale
	plate.z_index = 24
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var surface: Dictionary = formal_ui.get("surfaces", {}).get("small", {})
	var skin := StyleBoxTexture.new()
	var path: String = formal_config.resource_path(str(surface.get("resource_path", "")))
	if ResourceLoader.exists(path): skin.texture = load(path) as Texture2D
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		skin.set_texture_margin(side, float(surface.get("nine_slice_native_ltrb_px", [16, 12, 16, 12])[side]))
		skin.set_content_margin(side, 12 if side in [SIDE_LEFT, SIDE_RIGHT] else 9)
	plate.add_theme_stylebox_override("panel", skin)
	add_child(plate)
	remove_child(info)
	plate.add_child(info)
	info.position = Vector2.ZERO
	info.scale = Vector2.ONE

func _button(parent: Node, caption: String, action: Callable, enabled: bool = true) -> Button:
	var button := UI.button(parent, caption, action, enabled)
	if formal_config == null or formal_ui.is_empty(): return button
	var surface: Dictionary = formal_ui.get("surfaces", {}).get("secondary_button", {})
	var paths: Dictionary = surface.get("state_resource_paths", {})
	var margins: Array = surface.get("nine_slice_native_ltrb_px", [16, 12, 16, 16])
	var padding: Array = surface.get("content_padding_default_ltrb_px", [20, 9, 20, 9])
	for state in ["normal", "hover", "pressed", "disabled"]:
		var path: String = formal_config.resource_path(str(paths.get(state, surface.get("resource_path", ""))))
		if not ResourceLoader.exists(path): continue
		var skin := StyleBoxTexture.new()
		skin.texture = load(path) as Texture2D
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			skin.set_texture_margin(side, float(margins[side]))
			skin.set_content_margin(side, float(padding[side]))
		button.add_theme_stylebox_override(state, skin)
	button.custom_minimum_size.y = 48
	button.add_theme_font_size_override("font_size", int(formal_ui.get("font_size_default_px", {}).get("controls", 24)))
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]: button.add_theme_color_override(state, Color("#34413F"))
	button.add_theme_color_override("font_disabled_color", Color("#737B70"))
	_apply_formal_font(button, "font", "font_emphasis")
	return button

func _dialogue_rect(key: String, fallback: Rect2) -> Rect2:
	var value = formal_ui.get("dialogue", {}).get(key, [])
	if not value is Array or value.size() != 4: return fallback
	return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))

func _apply_formal_font(control: Control, theme_name: String, font_key: String) -> void:
	var path: String = formal_config.resource_path(str(formal_ui.get(font_key, "")))
	if not path.is_empty() and ResourceLoader.exists(path):
		var font := load(path) as Font
		if font != null: control.add_theme_font_override(theme_name, font)

func _paper(rect: Rect2, surface_name: String = "dialogue") -> void:
	var surface: Dictionary = formal_ui.get("surfaces", {}).get(surface_name, {})
	var path: String = formal_config.resource_path(str(surface.get("resource_path", "")))
	var texture: Texture2D = load(path) as Texture2D if not path.is_empty() and ResourceLoader.exists(path) else null
	if texture == null:
		var fallback := ColorRect.new()
		fallback.name = "DialoguePaper"
		fallback.color = Color("e7e4d8")
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_place(fallback, rect)
		return
	var paper := NinePatchRect.new()
	paper.name = "DialoguePaper"
	paper.texture = texture
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margins: Array = surface.get("nine_slice_native_ltrb_px", [36, 32, 36, 36])
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]: paper.set_patch_margin(side, int(margins[side]))
	_place(paper, rect)

func _on_notice(message: String) -> void:
	status_message = message
	_queue_render()

func _place(control: Control, rect: Rect2) -> void:
	if control.get_parent() == null: layout_canvas.add_child(control)
	control.position = rect.position
	control.size = rect.size

func _avatar_for(row: Dictionary) -> Texture2D:
	# 头像是独立身份，空值不继承立绘；缺少映射只省略头像。
	var id := str(row.get("avatar_id", ""))
	if id.is_empty(): return null
	var record: Dictionary = service.catalog.data.get("avatars", {}).get(id, {})
	var path := str(record.get("image", record.get("path", "")))
	if path.is_empty() or not ResourceLoader.exists(path): return null
	return load(path) as Texture2D

func _paginate(label: RichTextLabel) -> void:
	# 等容器完成布局后再按实际宽度分页；首帧不得先把整句打进正文。
	await get_tree().process_frame
	if not is_instance_valid(label) or service == null: return
	var text: String = service.current_text()
	service.set_page_ends(page_ends(text, label.get_theme_font("normal_font"), label.get_theme_font_size("normal_font_size"), label.size.x))
	pagination_ready = true

static func _text_lines(text: String, font: Font, font_size: int, width: float) -> TextParagraph:
	# 与 RichTextLabel 的自动换行同一套断行规则，分页看到的行就是正文实际排出的行。
	var paragraph := TextParagraph.new()
	paragraph.width = width
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	paragraph.add_string(text, font, font_size)
	return paragraph

static func _is_alnum(character: String) -> bool:
	return (character >= "0" and character <= "9") or (character >= "A" and character <= "Z") or (character >= "a" and character <= "z")

static func _can_start_page(text: String, index: int) -> bool:
	# 新页开头不能是句末或收尾标点，也不能把一串字母数字从中间劈开。
	if index <= 0 or index >= text.length(): return true
	if LINE_START_FORBIDDEN.contains(text[index]): return false
	return not (_is_alnum(text[index - 1]) and _is_alnum(text[index]))

static func _natural_break(text: String, start: int, window: int, marks: String, min_fill: float, limit: int = -1) -> int:
	# 在 [start, window] 内找最靠后的自然断点：断在 marks 之后，且至少占满本页 min_fill。
	var upper := window if limit < 0 else mini(window, limit)
	var lower := start + ceili((window - start) * min_fill)
	for index in range(upper, lower - 1, -1):
		if index > start and marks.contains(text[index - 1]) and _can_start_page(text, index): return index
	return -1

static func page_ends(text: String, font: Font, font_size: int, width: float) -> Array[int]:
	## 返回每页结束的字符位置。每页至多 PAGE_LINES 行；优先在句末、其次在句内停顿处翻页，
	## 末页不留只有几个字的残页，新页不以标点开头。
	var ends: Array[int] = []
	var length := text.length()
	var start := 0
	while start < length:
		var paragraph := _text_lines(text.substr(start), font, font_size, width)
		if paragraph.get_line_count() <= PAGE_LINES: break
		var window := start + mini(paragraph.get_line_range(PAGE_LINES - 1).y, length - start)
		if window >= length: break
		var end := _natural_break(text, start, window, SENTENCE_MARKS, MIN_SENTENCE_FILL)
		if end < 0: end = _natural_break(text, start, window, CLAUSE_MARKS, MIN_CLAUSE_FILL)
		if end < 0:
			# 没有自然断点就硬切，但把会落在新页开头的标点连同前一个字一起带到下一页。
			end = window
			while end - 1 > start and not _can_start_page(text, end): end -= 1
		# 余下内容还不够一个残页的字数时，向前借一个断点，让最后两页分得均匀些。
		if length - end < STUB_CHARS:
			var earlier := _natural_break(text, start, window, SENTENCE_MARKS, MIN_SENTENCE_FILL, length - STUB_CHARS)
			if earlier < 0: earlier = _natural_break(text, start, window, CLAUSE_MARKS, MIN_CLAUSE_FILL, length - STUB_CHARS)
			if earlier > start: end = earlier
		ends.append(end)
		start = end
	ends.append(length)
	return ends

func _render_log() -> void:
	if not formal_ui.is_empty():
		_render_formal_log()
		return
	var panel := VBoxContainer.new()
	panel.z_index = 20
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 96
	panel.offset_top = 64
	panel.offset_right = -96
	panel.offset_bottom = -40
	add_child(panel)
	UI.label(panel, "交谈记录", 28)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var records := VBoxContainer.new()
	records.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(records)
	for item in service.visible_history():
		if str(item.get("text", "")).is_empty(): continue
		UI.label(records, str(item.get("speaker_name", "")), 22)
		var body := UI.label(records, str(item.text), 22)
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var close := UI.button(panel, "返回对白", service.set_log_open.bind(false))
	close.grab_focus()

func _render_formal_log() -> void:
	# 记录模态使用独立纸面和滚动区；不让正文背后的控件接收点击或焦点。
	layout_canvas = Control.new()
	layout_canvas.size = Vector2(1600, 900)
	var factor := minf(size.x / 1600.0, size.y / 900.0)
	layout_canvas.scale = Vector2.ONE * factor
	layout_canvas.position = (size - layout_canvas.size * factor) / 2.0
	layout_canvas.z_index = 20
	layout_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(layout_canvas)
	_paper(Rect2(240, 82, 1120, 736), "panel")
	var panel := VBoxContainer.new()
	_place(panel, Rect2(288, 122, 1024, 648))
	panel.add_theme_constant_override("separation", 18)
	var heading := HBoxContainer.new()
	panel.add_child(heading)
	var title := UI.label(heading, "对白记录", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", Color("#34413F"))
	_apply_formal_font(title, "font", "font_emphasis")
	var close := _button(heading, "返回对白", service.set_log_open.bind(false))
	var scroll := ScrollContainer.new()
	scroll.name = "DialogueLogScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var records := VBoxContainer.new()
	records.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	records.add_theme_constant_override("separation", 16)
	scroll.add_child(records)
	for item in service.visible_history():
		if str(item.get("text", "")).is_empty(): continue
		var speaker := str(item.get("speaker_name", ""))
		if not speaker.is_empty():
			var name := UI.label(records, speaker, 24)
			name.add_theme_color_override("font_color", Color("#3F6B4C"))
			_apply_formal_font(name, "font", "font_emphasis")
		var body := UI.label(records, str(item.text), 28)
		body.add_theme_color_override("font_color", Color("#34413F"))
		_apply_formal_font(body, "font", "font_regular")
	var latest := _button(panel, "回到最新", func(): scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value))
	latest.size_flags_horizontal = Control.SIZE_SHRINK_END
	close.grab_focus()

func _toggle_skip() -> void:
	if service.fast_mode == "skip": service.stop_fast_read()
	else: service.begin_fast_read("skip")
	if is_instance_valid(skip_button): skip_button.text = "停止跳过" if service.fast_mode == "skip" else "跳过"

func _render_choices() -> void:
	if service == null or service.is_typing() or not service.state.get("waiting_for_choice", false): return
	var transitions: Array = service.catalog.choices_from_text(str(service.state.get("current_text_id", "")))
	if transitions.is_empty(): return
	choices.visible = true
	for index in range(transitions.size()):
		var row: Dictionary = transitions[index]
		var label := str(row.get("choice_text", row.get("target_text_id", "继续")))
		_button(choices, label, service.choose_transition.bind(index))
	if choices.is_visible_in_tree() and choices.get_child_count() > 0 and is_instance_valid(choices.get_child(0)): choices.get_child(0).grab_focus()

func _advance() -> void:
	if is_instance_valid(cutin) and cutin.is_blocking(): return
	if service != null: service.advance()

func _on_text_started(_record: Dictionary) -> void:
	pending_ending = false
	pagination_ready = false
	status_message = ""
	chapter_fade_elapsed = 0.0
	if is_instance_valid(stage): stage.apply_record(_record, service.catalog)
	if is_instance_valid(cutin):
		cutin.show_record(_record)
		stage.move_child(cutin, -1)
	_confirm_visible_actors(str(_record.get("text_id", "")))
	_queue_render()

func _chapter_fade_alpha() -> float:
	if is_instance_valid(stage) and stage.reduced: return 1.0
	return clampf(chapter_fade_elapsed / 0.3, 0, 1)

func reset_stage() -> void:
	pending_ending = false
	if is_instance_valid(cutin): cutin.clear()
	if is_instance_valid(stage): stage.reset_stage()

func _confirm_visible_actors(text_id: String) -> void:
	if DisplayServer.get_name() == "headless" or service == null or service.get("session") == null: return
	await RenderingServer.frame_post_draw
	if not is_visible_in_tree() or service.reading_log or service.hidden or service.state.get("current_text_id") != text_id or cutin.visible: return
	var session: Node = service.session
	var scene := str(session.case_state.data.scene)
	for actor in service.current_record().get("embedded_actor_refs", []):
		_confirm_actor_at_visible_location(str(actor), scene)
	var visible_people: Array = stage.occupants.values() + stage.scene_layers
	for person in visible_people:
		var actor_id := str(person.get("character_id", ""))
		var node = person.get("node")
		if actor_id.is_empty() or not is_instance_valid(node) or not node.is_visible_in_tree() or node.modulate.a < 0.05: continue
		if Rect2(Vector2.ZERO, size).intersects(Rect2(node.position, node.size)):
			_confirm_actor_at_visible_location(actor_id, scene)

func _confirm_actor_at_visible_location(actor_id: String, scene: String) -> void:
	var session: Node = service.session
	var actual := str(session.case_state.data.npc.get(actor_id, {}).get("scene_id", ""))
	if actual == scene:
		session.case_state.set_confirmed_actor_location(actor_id, actual)
		return
	# 大厅可看见厨房的尼娜；只采用正式表显式声明的可视关系，不能改人物真实地点。
	for binding in session.narrative.conversation.actor_config.get("embedded_character_views", []):
		if str(binding.get("character_id", "")) != actor_id or str(binding.get("scene_id", "")) != scene or str(binding.get("view_id", "")) != session.investigation_view(): continue
		if actual == str(binding.get("actual_scene_id", "")):
			session.case_state.set_confirmed_actor_location(actor_id, actual)
			return

func show_pending_ending() -> void:
	pending_ending = true
	for child in get_children():
		if child == stage: continue
		remove_child(child)
		child.queue_free()
	stage.reset_stage()
	stage.hide()
	var center := CenterContainer.new()
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	UI.label(box, "测试正文已结束", 32)
	UI.label(box, "已到达原片尾入口9000488。\n片尾片段、字幕、名单及续播步骤仍待配置。", 22)
	UI.button(box, "打开菜单 / 返回标题", menu_requested.emit)
	show()

func _on_progressed(value: String, _typing: bool) -> void:
	if is_instance_valid(text_label): text_label.text = value
	# 已读资格及选项改变后同步按钮；逐字刷新不能重建控件或移动焦点。
	for control in [fast_button, skip_button]:
		if is_instance_valid(control): control.disabled = not service.fast_read_available()
	if is_instance_valid(skip_button): skip_button.text = "停止跳过" if service.fast_mode == "skip" else "跳过"

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or service == null or not event is InputEventKey: return
	# Ctrl 松开即结束按住加速，即使焦点控件消费按键也不会继续快读。
	if event.keycode == KEY_CTRL and not event.pressed and service.fast_mode == "accelerate": service.stop_fast_read()
	# Tab和Shift+Tab交给Control的标准焦点导航；跳过只来自独立按钮。

func _gui_input(event: InputEvent) -> void:
	if shared_tools_managed and service.reading_log: return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if service.hidden: service.set_hidden(false)
		elif not service.reading_log and not service.state.get("waiting_for_choice", false): _advance()
		accept_event()

func _open_records() -> void:
	if shared_tools_managed: records_requested.emit()
	else: service.set_log_open(true)

func handle_escape() -> bool:
	# Esc只关闭当前阅读层或停止快读；调用者据返回值决定是否打开暂停。
	if service.hidden: service.set_hidden(false); return true
	if service.reading_log: service.set_log_open(false); return true
	if not service.fast_mode.is_empty(): service.stop_fast_read(); return true
	return false

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if shared_tools_managed and service.reading_log: return
	if not event is InputEventKey or event.echo: return
	# 记录层只接收自己的返回操作，不能用H修改被覆盖的正文。
	if service.reading_log:
		if event.pressed and event.keycode == KEY_L:
			service.set_log_open(false)
			get_viewport().set_input_as_handled()
		return
	if event.keycode == KEY_CTRL:
		if event.pressed: service.begin_fast_read("accelerate")
		else: service.stop_fast_read()
	elif not event.pressed: return
	elif service.hidden:
		if event.keycode not in [KEY_H, KEY_ENTER, KEY_SPACE]: return
		service.set_hidden(false)
	elif event.keycode == KEY_H: service.set_hidden(true)
	elif event.keycode == KEY_L and not shared_tools_managed: service.set_log_open(true)
	elif event.keycode in [KEY_ENTER, KEY_SPACE]: _advance()
	else: return
	get_viewport().set_input_as_handled()
