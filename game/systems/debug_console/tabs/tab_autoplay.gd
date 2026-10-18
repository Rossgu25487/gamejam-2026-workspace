extends "res://systems/debug_console/tabs/tab_base.gd"
## 自动推进页：选好目标与打法，让游戏自己玩；结束后在右侧看报告（异常、逐关过程、覆盖率）。
const AutoPlay = preload("res://systems/debug_console/debug_auto_play.gd")
const STRATEGY_KEYS := ["win", "fail", "random"]
const STRATEGY_TEXT := ["通关打法：按线索出示正确材料，完整通关", "错误尝试：每关先出错并走失败界面再重试，最后通关", "随机打法：随机出错、随机取项，抽测各种走法"]
const CHOICE_KEYS := ["cycle", "first", "last", "random"]
const CHOICE_TEXT := ["循环取项", "总选第一项", "总选最后一项", "随机取项"]
const DELAY_KEYS := [40, 250, 700]
const GOAL_KINDS := ["end", "chapter", "level"]
var goal_kind: OptionButton
var goal_target: OptionButton
var strategy_option: OptionButton
var choice_option: OptionButton
var seed_spin: SpinBox
var seed_random: CheckBox
var mode_option: OptionButton
var delay_option: OptionButton
var start_option: OptionButton
var save_check: CheckBox
var verify_check: CheckBox
var mode_hint: Label
var start_button: Button
var verdict_label: Label
var summary: RichTextLabel
var anomalies: Tree
var anomaly_detail: RichTextLabel
var levels: Tree
var copy_button: Button
var detail_button: Button
var folder_button: Button
var _shown_stamp := ""
var _chapter_ids: Array = []
var _level_ids: Array = []

func build() -> void:
	var body := hbox(self, 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 左列：可滚动的设置表单 + 固定在底部的开始/停止按钮（再矮的窗口也点得到）。
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 400
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)
	var left_scroll := scroll_in(left)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 8)
	left_scroll.add_child(form)
	_build_form(form)
	var actions := hbox(left, 8)
	start_button = make_button("开始自动推进", _start, actions)
	start_button.custom_minimum_size = Vector2(170, 36)
	hint("运行中会出现遮罩，点「取消」或按 Esc 停止。", actions)
	# 右列：报告内容较高，整列可滚动，不撑高整个页面。
	var right_scroll := scroll_in(body)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	right_scroll.add_child(right)
	_build_report(right)
	_update_form()

func _build_form(form: VBoxContainer) -> void:
	heading("一键预设", form)
	var presets := flow(form)
	make_button("通关全流程", _preset.bind("win", "cycle"), presets, "通关打法，直接跑到片尾")
	make_button("总选第一项", _preset.bind("win", "first"), presets)
	make_button("总选最后一项", _preset.bind("win", "last"), presets)
	make_button("随机抽测", _preset.bind("random", "random"), presets, "随机打法 + 随机取项，种子每次不同")
	make_button("错误尝试", _preset.bind("fail", "cycle"), presets)
	form.add_child(HSeparator.new())
	heading("运行设置", form)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	form.add_child(grid)
	caption("目标", grid)
	var goal_row := hbox(grid, 6)
	goal_kind = option_button(["片尾画面（完整流程）", "指定章节", "指定关卡"], goal_row)
	goal_kind.item_selected.connect(func(_index): _update_form())
	goal_target = option_button([], goal_row)
	goal_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id in config().chapters:
		_chapter_ids.append(str(id))
	for id in config().questions:
		_level_ids.append(str(id))
	caption("打法", grid)
	strategy_option = option_button(["通关打法", "错误尝试", "随机打法"], grid)
	strategy_option.item_selected.connect(func(_index): _update_form())
	caption("选项取法", grid)
	choice_option = option_button(CHOICE_TEXT, grid)
	choice_option.item_selected.connect(func(_index): _update_form())
	caption("随机种子", grid)
	var seed_row := hbox(grid, 8)
	seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 99999
	seed_spin.step = 1
	seed_spin.custom_minimum_size.x = 110
	seed_row.add_child(seed_spin)
	console.guard_line_edit(seed_spin.get_line_edit())
	seed_random = check_box("每次随机取一个", seed_row, true)
	seed_random.toggled.connect(func(_on): _update_form())
	caption("运行方式", grid)
	mode_option = option_button(["隔离快速（不影响当前游戏）", "实机演示（在游戏画面里看着推进）"], grid)
	mode_option.item_selected.connect(func(_index): _update_form())
	caption("演示速度", grid)
	delay_option = option_button(["快", "中", "慢"], grid, 1)
	caption("起点", grid)
	start_option = option_button(["新开一局", "从当前进度继续"], grid)
	save_check = check_box("实机演示时写入自动存档", form)
	save_check.tooltip_text = "默认不写存档，免得演示污染你自己的进度"
	verify_check = check_box("逐阶段做存档校验与读档往返核对", form, true)
	mode_hint = hint("", form)

func _build_report(right: VBoxContainer) -> void:
	heading("运行报告", right)
	verdict_label = Label.new()
	verdict_label.add_theme_font_size_override("font_size", 16)
	verdict_label.text = "还没有运行过。"
	right.add_child(verdict_label)
	# 报告按钮放在判定下面：报告很高，放在列尾会被滚到看不见。
	var buttons := flow(right)
	copy_button = make_button("复制报告文字", _copy_report, buttons)
	detail_button = make_button("在日志里展开详细报告", func(): console.run("auto report"), buttons)
	folder_button = make_button("打开报告文件夹", _open_folder, buttons, "完整报告 autoplay_last.json 保存在这里")
	for button in [copy_button, detail_button, folder_button]: button.disabled = true
	summary = RichTextLabel.new()
	summary.bbcode_enabled = false
	summary.fit_content = true
	summary.scroll_active = false
	summary.custom_minimum_size.y = 60
	right.add_child(summary)
	caption("异常（点选一行看发生位置和最近动作）", right)
	anomalies = make_tree([{"title": "级别", "width": 52}, {"title": "类型", "width": 64}, {"title": "内容", "width": 330, "expand": true}, {"title": "次数", "width": 48}, {"title": "章节", "width": 52}], right)
	anomalies.custom_minimum_size.y = 120
	anomalies.item_selected.connect(_show_anomaly)
	anomaly_detail = RichTextLabel.new()
	anomaly_detail.custom_minimum_size.y = 74
	anomaly_detail.size_flags_vertical = Control.SIZE_FILL
	right.add_child(anomaly_detail)
	caption("逐关过程", right)
	levels = make_tree([{"title": "关卡", "width": 70}, {"title": "出示", "width": 48}, {"title": "错误", "width": 48}, {"title": "失败", "width": 48}, {"title": "结果", "width": 200, "expand": true}], right)
	levels.custom_minimum_size.y = 100

# ---------- 选项 ----------

func _fill_targets() -> void:
	var kind: int = goal_kind.selected
	goal_target.clear()
	goal_target.visible = kind != 0
	if kind == 1:
		for id in _chapter_ids: goal_target.add_item("%s %s" % [id, config().chapters[id].name])
	elif kind == 2:
		for id in _level_ids: goal_target.add_item(id)
	if goal_target.item_count > 0: goal_target.select(0)

func _update_form() -> void:
	if goal_target == null: return
	if goal_target.get_meta("kind", -1) != goal_kind.selected:
		goal_target.set_meta("kind", goal_kind.selected)
		_fill_targets()
	var live: bool = mode_option.selected == 1
	var random_used: bool = strategy_option.selected == 2 or choice_option.selected == 3
	delay_option.disabled = not live
	save_check.disabled = not live
	seed_spin.editable = not seed_random.button_pressed
	seed_random.disabled = not random_used
	seed_spin.get_line_edit().editable = random_used and not seed_random.button_pressed
	mode_hint.text = "%s\n%s" % [STRATEGY_TEXT[strategy_option.selected], "实机演示：游戏画面里亲眼看着推进，面板会暂时收起，Esc 随时停止；默认不写存档，演示前的进度可用 undo 撤回。" if live else "隔离快速：在临时会话里秒跑，不碰当前游戏，适合批量验证。"]

## 界面当前选择对应的 auto 选项；与命令行的 parse_auto 产出同一格式。
func current_options() -> Dictionary:
	var goal := {"kind": "ending", "label": "片尾演职员画面"}
	if goal_kind.selected == 1 and goal_target.selected >= 0:
		var chapter: String = _chapter_ids[goal_target.selected]
		goal = {"kind": "chapter", "chapter": chapter, "label": "%s %s" % [chapter, config().chapters[chapter].name]}
	elif goal_kind.selected == 2 and goal_target.selected >= 0:
		var question: String = _level_ids[goal_target.selected]
		goal = {"kind": "level", "question": question, "label": "关卡 " + question}
	var live: bool = mode_option.selected == 1
	var random_used: bool = strategy_option.selected == 2 or choice_option.selected == 3
	return {"goal": goal, "strategy": STRATEGY_KEYS[strategy_option.selected], "choice": CHOICE_KEYS[choice_option.selected],
		"seed": -1 if (seed_random.button_pressed or not random_used) else int(seed_spin.value), "live": live, "delay": int(DELAY_KEYS[delay_option.selected]) if live else 0,
		"here": start_option.selected == 1, "save": live and save_check.button_pressed, "checks": verify_check.button_pressed}

func describe(options: Dictionary) -> String:
	return "auto %s -s %s -c %s%s%s%s" % [options.goal.label, options.strategy, options.choice, " -seed %d" % int(options.seed) if int(options.seed) >= 0 else "", " -live" if options.live else "", " -here" if options.here else ""]

func _preset(strategy: String, choice: String) -> void:
	strategy_option.select(STRATEGY_KEYS.find(strategy))
	choice_option.select(CHOICE_KEYS.find(choice))
	goal_kind.select(0)
	_update_form()
	_start()

func _start() -> void:
	if console.commands == null or console.commands.busy: return
	var options := current_options()
	console.run_autoplay(options, describe(options))

func busy_changed(busy: bool) -> void:
	if not built: return
	start_button.disabled = busy

# ---------- 报告 ----------

func refresh() -> void:
	if not built: return
	var data: Dictionary = console.commands.last_report if console.commands != null else {}
	start_option.set_item_disabled(1, not in_game())
	if not in_game() and start_option.selected == 1: start_option.select(0)
	if data.is_empty():
		for button in [copy_button, detail_button, folder_button]: button.disabled = true
		return
	var stamp := str(data.get("serial", ""))
	if stamp == _shown_stamp: return
	_shown_stamp = stamp
	_show_report(data)

func _show_report(data: Dictionary) -> void:
	var lines: Array = AutoPlay.report_lines(data, false)
	var ok: bool = bool(data.get("ok", false))
	verdict_label.text = str(lines[0].text) if not lines.is_empty() else ""
	verdict_label.add_theme_color_override("font_color", DebugTheme.OK if ok else DebugTheme.ERROR)
	summary.clear()
	for line in lines.slice(1, 6):
		summary.push_color(DebugTheme.LOG_COLORS.get(str(line.kind), DebugTheme.TEXT))
		summary.add_text(str(line.text))
		summary.pop()
		summary.newline()
	anomalies.clear()
	var root := anomalies.create_item()
	for item in data.anomalies:
		var node := anomalies.create_item(root)
		node.set_metadata(0, item)
		node.set_text(0, "错误" if str(item.severity) == "error" else "提示")
		node.set_text(1, str(item.kind))
		node.set_text(2, str(item.message))
		node.set_text(3, str(int(item.count)))
		node.set_text(4, str(item.chapter))
		node.set_tooltip_text(2, str(item.message))
		color_item(node, 5, DebugTheme.ERROR if str(item.severity) == "error" else DebugTheme.WARN)
	anomaly_detail.clear()
	anomaly_detail.add_text("没有异常。" if data.anomalies.is_empty() else "点选上面的异常查看发生位置与最近的动作。")
	levels.clear()
	var level_root := levels.create_item()
	for id in data.levels:
		var level: Dictionary = data.levels[id]
		var node := levels.create_item(level_root)
		node.set_text(0, str(id))
		node.set_text(1, str(int(level.presents)))
		node.set_text(2, str(int(level.wrong)))
		node.set_text(3, str(int(level.failures)))
		var done: bool = int(level.done_step) > 0
		node.set_text(4, ("第 %d 步完成：%s" % [int(level.done_step), level.result]) if done else "未完成")
		color_item(node, 5, DebugTheme.TEXT if done else DebugTheme.DIM)
	for button in [copy_button, detail_button]: button.disabled = false
	folder_button.disabled = str(data.get("file", "")).is_empty()

func _show_anomaly() -> void:
	var node := anomalies.get_selected()
	if node == null: return
	var item: Dictionary = node.get_metadata(0)
	anomaly_detail.clear()
	anomaly_detail.add_text("位置：%s %s 模式 %s%s%s（第 %d 步）\n" % [item.chapter, item.scene, item.mode, " 入口 " + str(item.entry) if not str(item.entry).is_empty() else "", " 关卡 " + str(item.question) if not str(item.question).is_empty() else "", int(item.step)])
	for trace in item.trace: anomaly_detail.add_text("  " + str(trace) + "\n")

func _copy_report() -> void:
	var data: Dictionary = console.commands.last_report
	if data.is_empty(): return
	var lines: Array = []
	for line in AutoPlay.report_lines(data, true): lines.append(str(line.text))
	DisplayServer.clipboard_set("\n".join(lines))
	console.say("报告文字已复制到剪贴板。", "ok")

func _open_folder() -> void:
	var path := str(console.commands.last_report.get("file", ""))
	if not path.is_empty(): OS.shell_open(path.get_base_dir())
