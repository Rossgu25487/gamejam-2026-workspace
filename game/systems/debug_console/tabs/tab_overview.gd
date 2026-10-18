extends "res://systems/debug_console/tabs/tab_base.gd"
## 概览页：当前章节、地点、模式和各项进度，外加最常用的快捷操作。
const FIELDS := [["chapter", "章节"], ["scene", "地点"], ["layer", "界面 / 模式"], ["entry", "当前入口"], ["question", "当前关卡"], ["save", "可保存"],
	["materials", "材料"], ["events", "事件"], ["texts", "已听原话"], ["levels", "已完成关卡"], ["time", "游戏时长"], ["speed", "时间倍率"]]
var values := {}
var chapter_rows := {}
var report_label: Label
var hud_check: CheckBox
var note_label: Label

func build() -> void:
	var content := scrolled()
	heading("当前状态", content)
	note_label = hint("", content)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	content.add_child(grid)
	for field in FIELDS:
		caption(str(field[1]), grid)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		grid.add_child(label)
		values[field[0]] = label
	content.add_child(HSeparator.new())
	heading("章节进度（关卡）", content)
	var chapters := VBoxContainer.new()
	chapters.add_theme_constant_override("separation", 4)
	content.add_child(chapters)
	for id in config().chapters:
		var row := hbox(chapters, 10)
		var title := Label.new()
		title.custom_minimum_size.x = 220
		title.text = "%s %s" % [id, config().chapters[id].name]
		row.add_child(title)
		var bar := ProgressBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.custom_minimum_size.y = 18
		bar.show_percentage = false
		row.add_child(bar)
		var count := Label.new()
		count.custom_minimum_size.x = 90
		row.add_child(count)
		chapter_rows[str(id)] = {"title": title, "bar": bar, "count": count}
	content.add_child(HSeparator.new())
	heading("快捷操作", content)
	var actions := flow(content)
	run_button("读完当前对白（skip）", "skip", actions, "快速读完对白与原件，停在选项或调查画面")
	run_button("撤回上次跳转（undo）", "undo", actions)
	run_button("查看关卡状态（levels）", "levels", actions)
	run_button("查看场景（scenes）", "scenes", actions)
	run_button("查看人物位置（npc）", "npc", actions)
	hud_check = check_box("在屏幕角落显示状态信息与帧率", content)
	hud_check.toggled.connect(func(on): if on != console.hud_enabled: console.run("hud on" if on else "hud off"))
	content.add_child(HSeparator.new())
	heading("最近一次自动推进", content)
	report_label = hint("", content)

func refresh() -> void:
	if not built: return
	var data: Dictionary = session().case_state.data
	var cfg := config()
	var active := in_game()
	note_label.text = "" if active else "还没有开始游戏：可在「跳转」页直接快进到某章或某关，或在「自动推进」页让游戏自己玩一遍。"
	var chapter: Dictionary = cfg.chapters.get(data.chapter, {})
	var place := str(data.scene)
	if cfg.scenes.has(place): place = "%s %s" % [place, cfg.text(str(cfg.scenes[place].name_text_id))]
	var versions := 0
	for id in data.materials: versions += data.materials[id].versions.size()
	var happened := 0
	for id in data.events:
		if data.events[id]: happened += 1
	var seconds := int(session().elapsed_seconds)
	var text := {
		"chapter": "%s %s" % [data.chapter, chapter.get("name", "")] if active else "-",
		"scene": place if active else "-",
		"layer": "%s / %s" % [app().current_layer, session().mode] if active else "%s（未开始游戏）" % app().current_layer,
		"entry": str(session().active_entry) if active and not str(session().active_entry).is_empty() else "-",
		"question": str(session().question) if active and not str(session().question).is_empty() else "-",
		"save": ("是" if session().can_save() else "否") if active else "-",
		"materials": "%d/%d（版本 %d/%d）" % [data.materials.size(), cfg.materials.size(), versions, cfg.contents.size()],
		"events": "%d/%d" % [happened, cfg.events.size()],
		"texts": "%d/%d" % [data.texts.size(), cfg.texts.size()],
		"levels": "%d/%d" % [data.completed_questions.size(), cfg.questions.size()],
		"time": "%02d:%02d:%02d" % [floori(seconds / 3600.0), floori(seconds / 60.0) % 60, seconds % 60],
		"speed": "%.2f 倍" % Engine.time_scale}
	for key in values: values[key].text = text[key]
	var totals := {}
	var done := {}
	for id in cfg.questions:
		var entry: Dictionary = cfg.entries.get(str(cfg.questions[id].get("entry_ref", "")), {})
		var chapter_id := str(entry.get("chapter_id", ""))
		totals[chapter_id] = int(totals.get(chapter_id, 0)) + 1
		if data.completed_questions.has(id): done[chapter_id] = int(done.get(chapter_id, 0)) + 1
	for id in chapter_rows:
		var row: Dictionary = chapter_rows[id]
		var total := int(totals.get(id, 0))
		var finished := int(done.get(id, 0))
		row.bar.max_value = maxi(total, 1)
		row.bar.value = finished
		row.count.text = "%d/%d" % [finished, total] if total > 0 else "无关卡"
		row.title.add_theme_color_override("font_color", DebugTheme.ACCENT_TEXT if active and str(data.chapter) == id else DebugTheme.TEXT)
	hud_check.set_pressed_no_signal(console.hud_enabled)
	var report: Dictionary = console.commands.last_report if console.commands != null else {}
	report_label.text = "尚未运行。" if report.is_empty() else "%s · %s · 目标 %s：%s，耗时 %.1f 秒，%d 类异常。" % [console.AutoPlayScript.STRATEGIES.get(str(report.strategy), report.strategy), report.mode, report.goal, "已到达" if bool(report.reached) else "未到达", int(report.elapsed_ms) / 1000.0, report.anomalies.size()]
