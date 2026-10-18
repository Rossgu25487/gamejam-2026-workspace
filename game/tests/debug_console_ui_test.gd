extends SceneTree
## 调试控制台图形界面回归：口令弹窗与解锁后的 ~ 直开、各页签的真实点击、勾选与表单到命令的映射、
## 自动推进页的运行/取消/报告、实机演示时的面板收起与输入拦截、页面布局不撑破面板。
## 点击一律用真实的鼠标事件，保证按钮没有被遮挡；隔离存储，不读写玩家档案。
const AutoPlay = preload("res://systems/debug_console/debug_auto_play.gd")
const MAX_TAB_HEIGHT := 300.0
var app: Control
var console: CanvasLayer
var commands: RefCounted
var failures: Array[String] = []
var checks := 0
var probe: Node

func _init() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("DEBUG_CONSOLE_UI_FAILED " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.pressed = down
		root.push_input(event)
	await frames()

func click_point(point: Vector2) -> void:
	check(root.get_visible_rect().has_point(point), "点击位置在窗口内 %s" % point)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
	await frames(2)

func click(control: Control) -> void:
	var usable := is_instance_valid(control) and control.is_visible_in_tree()
	check(usable, "点击目标可见：%s" % (str(control.name) if is_instance_valid(control) else "已释放"))
	if not usable: return
	var point := control.get_global_rect().get_center()
	# 先把鼠标移过去，确认悬停的真的是这个控件：被遮挡或被滚动容器裁掉的按钮点不到。
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	var hovered := root.gui_get_hovered_control()
	check(hovered == control or (hovered != null and control.is_ancestor_of(hovered)), "点击位置真的落在目标上：%s（实际悬停 %s）" % [control.name if control.name != &"" else control.get_class(), hovered.get_path() if hovered != null else "无"])
	await click_point(point)

## 等命令和自动推进都结束（按真实时间等，推进的快慢取决于机器）。
func settle(limit_ms: int = 150000) -> void:
	await frames(2)
	var started := Time.get_ticks_msec()
	while (commands.busy or console._submitting) and Time.get_ticks_msec() - started < limit_ms: await process_frame
	check(not commands.busy, "命令在限时内结束")
	await frames(3)

func find_button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if (node as Button).text == text: return node
	check(false, "找不到按钮：" + text)
	return null

func log_since(start: int) -> String:
	return "\n".join(console.log_lines.slice(maxi(0, console.log_lines.size() - (console.log_count - start))))

func data() -> Dictionary: return app.session.case_state.data

func tab(name: String) -> Control: return console.tabs[name]

func show_tab(name: String) -> void:
	await click(console.tab_buttons[name])
	check(console.current_tab == name and tab(name).is_visible_in_tree() and tab(name).built, "点击导航按钮显示页签 " + name)

## 每个已建好的页签最小高度必须小于主体区高度，面板不能越出窗口。
func layout_fits(label: String) -> void:
	for name in console.tabs:
		var page: Control = console.tabs[name]
		if page.built: check(page.get_combined_minimum_size().y <= MAX_TAB_HEIGHT, "%s：%s 页最小高度 %.0f 不超过 %.0f" % [label, name, page.get_combined_minimum_size().y, MAX_TAB_HEIGHT])
	check(root.get_visible_rect().encloses(console.main_panel.get_global_rect()), "%s：面板完整落在窗口内" % label)

func _run() -> void:
	root.size = Vector2i(1280, 800)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://debug_console_ui_test_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(6)
	console = app.debug_console
	commands = console.commands
	check(console != null and commands != null, "控制台已绑定")
	if console == null: quit(1); return
	check(console.tabs.is_empty() and not console.panel_root.visible, "没按过 ~ 键之前界面内容一个都没建")

	await _unlock_flow()
	await _navigation_and_layout()
	await _start_game_from_jump_tab()
	await _items_tab()
	await _jump_tab()
	await _story_tab()
	await _tools_tab()
	await _terminal_tab()
	await _autoplay_form()
	await _autoplay_isolated_run()
	await _autoplay_cancel()
	await _busy_overlay()
	await _live_run()
	await _lock_again()

	app.queue_free()
	await frames(30)
	print("DEBUG_CONSOLE_UI ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

# ---------- 口令弹窗与解锁 ----------

func _unlock_flow() -> void:
	await key(KEY_QUOTELEFT)
	check(console.is_open and console.prompt_box.visible and not console.main_panel.visible, "按 ~ 弹出口令窗口")
	check(console.tabs.keys() == ["terminal"], "未解锁时只建了命令行页（输入框要先存在），其余页签尚未构建")
	var unlock := find_button(console.prompt_box, "解锁")
	console.prompt_edit.text = "nope"
	await click(unlock)
	check(not console.unlocked and console.prompt_message.text.contains("口令不对"), "口令错误给出提示且不解锁")
	console.prompt_edit.text = "Super"
	await click(unlock)
	check(console.unlocked and console.main_panel.visible and not console.prompt_box.visible, "点「解锁」输入 super 后弹出图形面板")
	check(console.tabs.has("overview") and console.tabs.overview.built, "解锁后默认显示概览页")
	await click(find_button(console.main_panel, "关闭"))
	check(not console.is_open and not paused, "点标题栏「关闭」收起面板并恢复游戏")
	await key(KEY_QUOTELEFT)
	check(console.is_open and console.main_panel.visible and not console.prompt_box.visible, "解锁后再按 ~ 直接呼出图形面板，不再要口令")
	await key(KEY_ESCAPE)
	check(not console.is_open, "Esc 关闭面板")
	await key(KEY_QUOTELEFT)

# ---------- 导航与布局 ----------

func _navigation_and_layout() -> void:
	for item in console.TAB_ORDER: await show_tab(str(item[0]))
	check(console.tabs.size() == console.TAB_ORDER.size(), "七个页签都能通过点击导航打开")
	check(console.input_edit != null and console.input_edit == tab("terminal").input_edit, "命令行页的输入框已登记到控制台")
	layout_fits("标题界面")
	for button in tab("items").action_buttons: check(button.disabled, "未开始游戏时物品页「%s」不可用" % button.text)
	for id in tab("jump").scene_buttons: check(tab("jump").scene_buttons[id].disabled, "未开始游戏时场景按钮 %s 不可用" % id)
	await show_tab("terminal")
	await frames(2)
	check(console.input_edit.has_focus(), "进入命令行页后输入框自动获得焦点")

func _start_game_from_jump_tab() -> void:
	await show_tab("jump")
	var jump_tab: Control = tab("jump")
	check(jump_tab.chapter_buttons.size() == 7 and jump_tab.chapter_buttons[1].text.begins_with("CH02"), "跳转页有六个章节按钮和片尾按钮")
	var start: int = console.log_count
	await click(jump_tab.chapter_buttons[1])
	await settle()
	check(data().chapter == "CH02" and app.session.mode == "investigation", "点章节按钮快进到第二章的调查画面")
	check(log_since(start).contains("> jump CH02") and log_since(start).contains("已到达"), "按钮的命令回显进了日志")
	check(commands.undo_snapshot.is_empty(), "从标题界面起跳时没有可撤回的进度")
	await show_tab("overview")
	var overview: Control = tab("overview")
	check(str(overview.values.chapter.text).contains("CH02") and str(overview.values.layer.text).contains("investigation"), "概览页反映当前章节和模式")
	check(int(overview.chapter_rows.CH01.bar.max_value) >= 0 and str(overview.chapter_rows.CH02.count.text).contains("/"), "概览页有各章关卡进度条")
	layout_fits("游戏中概览")

# ---------- 物品页 ----------

func _items_tab() -> void:
	await show_tab("items")
	var items: Control = tab("items")
	var state: RefCounted = app.session.case_state
	var all_materials: int = app.session.config.materials.size()
	check(items.tree.get_root().get_child_count() == all_materials, "物品页列出全部 %d 种材料" % all_materials)
	check(not items.action_buttons[0].disabled, "游戏开始后获得/移除按钮可用")
	items.search.text = "E01"
	items.search.text_changed.emit("E01")
	check(items.tree.get_root().get_child_count() == 1 and items.tree.get_root().get_child(0).get_text(2) == "E01", "搜索按材料 ID 过滤")
	items.search.text = ""
	items.search.text_changed.emit("")
	items.type_option.select(3)
	items.type_option.item_selected.emit(3)
	var inference_total: int = app.session.config.materials.keys().filter(func(id): return str(app.session.config.materials[id].type) == "inference").size()
	check(inference_total > 0 and items.tree.get_root().get_child_count() == inference_total, "类型下拉框按推论过滤")
	items.type_option.select(0)
	items.type_option.item_selected.emit(0)
	await click(find_button(items, "清空全部材料"))
	await settle()
	check(state.data.materials.is_empty(), "一键「清空全部材料」按钮生效")
	items.owned_check.button_pressed = true
	check(items.tree.get_root().get_child_count() == 0, "「只看已持有」在清空后列表为空")
	items.owned_check.button_pressed = false
	check(items.tokens().is_empty(), "没有勾选也没有点选时目标为空")
	var start: int = console.log_count
	await click(items.action_buttons[0])
	check(log_since(start).contains("请先勾选"), "没选任何材料时点「获得所选」给出提示")
	# 勾选材料行：获得最新版本。
	var row: TreeItem = items.tree.get_root().get_child(0)
	row.set_checked(0, true)
	check(items.tokens() == [str(row.get_text(2))], "勾选一行后目标是该材料")
	await click(items.action_buttons[0])
	await settle()
	check(state.data.materials.has(str(row.get_text(2))), "勾选 + 「获得所选（最新版）」获得材料")
	# 勾选具体版本行。
	row.set_checked(0, false)
	var target_row: TreeItem = items.tree.get_root().get_child(1)
	var target_material := str(target_row.get_text(2))
	var versions: Array = target_row.get_children()
	check(versions.size() >= 2, "材料行下挂着各个版本")
	var first_version: TreeItem = versions[0]
	first_version.set_checked(0, true)
	check(items.tokens() == [str(first_version.get_text(2))], "勾选版本行后目标是该内容 ID")
	await click(items.action_buttons[0])
	await settle()
	check(state.owns(str(first_version.get_text(2))) and not state.owns(str(versions.back().get_text(2))), "勾选版本行只获得指定版本，不连带最新版")
	first_version.set_checked(0, false)
	# 全选、全部版本。
	await click(find_button(items, "全选当前列表"))
	check(items.tokens().size() == all_materials, "「全选当前列表」勾上全部材料")
	await click(items.action_buttons[1])
	await settle()
	check(state.data.materials.size() == all_materials and _owned_versions() == app.session.config.contents.size(), "「获得所选（全部版本）」获得每一种材料的每一个版本")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "全部获得后状态仍可校验")
	await click(find_button(items, "取消勾选"))
	check(items.tokens().is_empty(), "「取消勾选」清空勾选")
	row.set_checked(0, true)
	await click(items.action_buttons[2])
	await settle()
	check(not state.data.materials.has(str(row.get_text(2))), "勾选 + 「移除所选」移除材料")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "移除后状态仍可校验")
	row.set_checked(0, false)
	await click(find_button(items, "获得全部推论"))
	await settle()
	check(state.data.materials.keys().filter(func(id): return str(app.session.config.materials[id].type) == "inference").size() == inference_total, "一键「获得全部推论」只补推论")
	layout_fits("物品页")

func _owned_versions() -> int:
	var total := 0
	for id in data().materials: total += data().materials[id].versions.size()
	return total

# ---------- 跳转页 ----------

func _jump_tab() -> void:
	await show_tab("jump")
	var jump_tab: Control = tab("jump")
	var question_total: int = app.session.config.questions.size()
	check(jump_tab.levels.get_root().get_child_count() == question_total, "关卡表列出全部 %d 个关卡" % question_total)
	check(jump_tab.jump_level_button.disabled, "没选关卡时「跳到所选关卡」不可用")
	var scene_id := "SC09"
	check(jump_tab.scene_buttons.has(scene_id) and not jump_tab.scene_buttons[scene_id].disabled, "游戏中场景按钮可用")
	jump_tab.scene_buttons[scene_id].pressed.emit()
	await settle()
	check(data().scene == scene_id, "场景按钮无条件前往场景")
	var actor := "CHR04"
	var destination := "SC06"
	jump_tab.actor_option.select(jump_tab.actor_ids.find(actor))
	jump_tab.scene_option.select(jump_tab.scene_ids.find(destination))
	find_button(jump_tab, "移动").pressed.emit()
	await settle()
	check(data().npc[actor].scene_id == destination, "移动人物按钮把人物移到所选场景")
	data().chances["L01_R01"] = 1
	var first: TreeItem = jump_tab.levels.get_root().get_child(0)
	first.select(0)
	check(not jump_tab.jump_level_button.disabled and str(first.get_metadata(0)) == "L01_R01", "选中关卡后「跳到所选关卡」可用")
	find_button(jump_tab, "补齐所选关卡的机会（3 次）").pressed.emit()
	await settle()
	check(data().chances["L01_R01"] == 3, "补齐机会按钮把所选关卡的机会设回 3")
	var target: TreeItem = jump_tab.levels.get_root().get_child(1)
	target.select(0)
	var level_id := str(target.get_metadata(0))
	await click(jump_tab.jump_level_button)
	await settle()
	check(app.session.mode == "selection" and str(app.session.question) == level_id, "选中关卡后点按钮直接进入该关选材界面")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "关卡跳转后状态可校验")
	await show_tab("overview")
	check(str(tab("overview").values.question.text) == level_id, "概览页显示当前关卡")
	await show_tab("jump")
	var found := false
	for row in jump_tab.levels.get_root().get_children():
		if str(row.get_metadata(0)) == level_id: found = row.get_text(3) == "可进入" or row.get_text(3) == "已完成"
	check(found, "关卡表的状态列反映该关已开放")
	layout_fits("跳转页")

# ---------- 剧情页 ----------

func _story_tab() -> void:
	# 先回到调查画面：撤回到关卡跳转之前，保证入口可以触发。
	await show_tab("overview")
	await click(find_button(tab("overview"), "撤回上次跳转（undo）"))
	await settle()
	check(app.session.mode == "investigation", "撤回回到调查画面")
	await show_tab("story")
	var story: Control = tab("story")
	check(story.entries.get_root().get_child_count() == app.session.config.entries.size(), "入口表列出全部入口")
	story.entry_search.text = "L07"
	story.entry_search.text_changed.emit("L07")
	var filtered: int = story.entries.get_root().get_child_count()
	check(filtered > 0 and filtered < app.session.config.entries.size(), "入口表按关键词过滤")
	story.entry_search.text = ""
	story.entry_search.text_changed.emit("")
	story.ready_only.button_pressed = true
	var ready_count: int = story.entries.get_root().get_child_count()
	check(ready_count > 0 and ready_count < app.session.config.entries.size(), "「只看条件成立」只留当前可触发的入口")
	var ready_entry: TreeItem = story.entries.get_root().get_child(0)
	ready_entry.select(0)
	check(not story.fire_button.disabled and not story.why_button.disabled, "选中入口后触发和解释按钮可用")
	var start: int = console.log_count
	await click(story.why_button)
	await settle()
	check(log_since(start).contains("> cond ") or log_since(start).contains("没有开放条件"), "「解释入口条件」走 cond 命令")
	story.ready_only.button_pressed = false
	story.sub_tabs.current_tab = 1
	story.event_search.text = "CASE_INVESTIGATION_OPEN"
	story.event_search.text_changed.emit(story.event_search.text)
	check(story.events.get_root().get_child_count() >= 1, "事件表按关键词过滤")
	var event_row: TreeItem = story.events.get_root().get_child(0)
	event_row.select(0)
	check(not story.event_button.disabled, "选中事件后执行按钮可用")
	start = console.log_count
	await frames()  # 切页和选中会改变布局，等排版稳定再取按钮位置
	await click(story.event_button)
	await settle()
	check(log_since(start).contains("> event ") and log_since(start).contains("已执行"), "事件按钮执行事件（日志：%s）" % log_since(start).replace("\n", " / ").left(240))
	story.sub_tabs.current_tab = 2
	start = console.log_count
	story.cond_edit.text = "COND_CH03_L07_AVAILABLE"
	story.cond_edit.text_submitted.emit(story.cond_edit.text)
	await settle()
	check(log_since(start).contains("分支"), "条件诊断页逐项解释条件")
	story.sub_tabs.current_tab = 0
	# 触发一个当前可触发的入口：命令按游戏规则执行，界面只负责发出命令。
	start = console.log_count
	story.ready_only.button_pressed = true
	var fired: TreeItem = story.entries.get_root().get_child(0)
	fired.select(0)
	var entry_id := str(fired.get_metadata(0))
	await click(story.fire_button)
	await settle()
	check(log_since(start).contains("> entry " + entry_id), "「触发所选入口」走 entry 命令")
	story.ready_only.button_pressed = false
	layout_fits("剧情页")
	# 触发入口可能进入剧情；回到干净的第二章调查画面，后面的页签都从这里开始。
	await console.run("jump 2")
	await settle()
	check(app.session.mode == "investigation" and data().chapter == "CH02", "回到第二章调查画面")

# ---------- 调试页 ----------

func _tools_tab() -> void:
	# 入口可能已进入剧情；机会和速度与当前模式无关。
	await show_tab("tools")
	var tools: Control = tab("tools")
	var level_index: int = tools.level_ids.find("L01_R01")
	check(level_index >= 0, "调试页的关卡下拉框含 L01_R01")
	tools.chance_option.select(level_index + 1)
	tools.chance_value.select(1)
	await click(find_button(tools, "应用"))
	await settle()
	check(data().chances["L01_R01"] == 1, "「应用」设置所选关卡的机会")
	await click(find_button(tools, "全部关卡补满 3 次"))
	await settle()
	check(data().chances["L01_R01"] == 3 and data().chances["L07_R02"] == 3, "「全部关卡补满」设置全部关卡")
	tools.speed_slider.set_value_no_signal(2.0)
	tools.speed_slider.drag_ended.emit(true)
	await settle()
	check(is_equal_approx(Engine.time_scale, 2.0), "拖动速度滑块松手后生效")
	await click(find_button(tools, "1 倍"))
	await settle()
	check(is_equal_approx(Engine.time_scale, 1.0) and is_equal_approx(tools.speed_slider.value, 1.0), "预设按钮恢复 1 倍并同步滑块")
	tools.hud_check.button_pressed = true
	await settle()
	check(console.hud_enabled and console.hud_label.visible, "勾选「屏幕状态信息」显示状态条")
	tools.hud_check.button_pressed = false
	await settle()
	check(not console.hud_enabled, "取消勾选隐藏状态条")
	var before: int = console.log_count
	await click(find_button(tools, "清空日志"))
	check(console.log_lines.is_empty() and console.output_label.get_parsed_text().strip_edges().is_empty(), "「清空日志」清空日志区")
	layout_fits("调试页")

# ---------- 命令行页 ----------

func _terminal_tab() -> void:
	await show_tab("terminal")
	var terminal: Control = tab("terminal")
	check(terminal.reference.get_root().get_child_count() == commands.registry.size(), "命令表列出全部命令")
	var start: int = console.log_count
	console.input_edit.text = "status"
	console.input_edit.text_submitted.emit("status")
	await settle()
	check(log_since(start).contains("> status") and log_since(start).contains("章节"), "回车执行命令并输出到日志")
	check(console.input_edit.text.is_empty(), "执行后输入框清空")
	var up := InputEventKey.new()
	up.keycode = KEY_UP; up.pressed = true
	terminal._on_gui_input(up)
	check(console.input_edit.text == "status", "上键调出上一条命令")
	console.input_edit.clear()
	console.input_edit.text = "gi"
	terminal._complete()
	check(console.input_edit.text == "give ", "Tab 补全命令名")
	console.input_edit.text = "give E0"
	terminal._complete()
	check(console.input_edit.text.begins_with("give E0"), "Tab 补全材料 ID（多个候选时补到公共前缀）")
	console.input_edit.clear()
	var give_row: TreeItem
	for row in terminal.reference.get_root().get_children():
		if str(row.get_metadata(0)) == "give": give_row = row
	check(give_row != null, "命令表里有 give")
	if give_row != null:
		give_row.select(0)
		terminal.reference.item_activated.emit()
		check(console.input_edit.text == "give ", "双击命令表的一行把命令填进输入框")
	console.input_edit.clear()
	layout_fits("命令行页")

# ---------- 自动推进页：表单到命令选项的映射 ----------

func _same_options(a: Dictionary, b: Dictionary, label: String) -> void:
	for name in ["strategy", "choice", "seed", "live", "delay", "here", "save", "checks"]:
		check(a[name] == b[name], "%s：选项 %s 一致（界面 %s / 命令 %s）" % [label, name, a[name], b[name]])
	var kind_a := str(a.goal.kind)
	check(kind_a == str(b.goal.kind) and str(a.goal.get("chapter", "")) == str(b.goal.get("chapter", "")) and str(a.goal.get("question", "")) == str(b.goal.get("question", "")), "%s：目标一致（%s / %s）" % [label, a.goal, b.goal])

func _autoplay_form() -> void:
	await show_tab("autoplay")
	var auto: Control = tab("autoplay")
	var parsed := func(args: Array) -> Dictionary:
		var result: Dictionary = commands.parse_auto(PackedStringArray(args))
		check(bool(result.ok), "命令行解析 %s" % [args])
		return result.options
	_same_options(auto.current_options(), parsed.call([]), "默认值")
	auto.strategy_option.select(2)
	auto.choice_option.select(3)
	auto._update_form()
	_same_options(auto.current_options(), parsed.call(["-s", "random", "-c", "random"]), "随机打法")
	auto.seed_random.button_pressed = false
	auto.seed_spin.value = 42
	_same_options(auto.current_options(), parsed.call(["-s", "random", "-c", "random", "-seed", "42"]), "固定种子")
	auto.mode_option.select(1)
	auto.delay_option.select(2)
	auto.start_option.select(1)
	auto.save_check.button_pressed = true
	auto._update_form()
	_same_options(auto.current_options(), parsed.call(["-s", "random", "-c", "random", "-seed", "42", "-live", "-slow", "-here", "-save"]), "实机演示")
	check(not auto.delay_option.disabled and not auto.save_check.disabled, "实机演示时速度和存档选项可用")
	auto.goal_kind.select(1)
	auto.goal_kind.item_selected.emit(1)
	auto.goal_target.select(2)
	check(auto.current_options().goal.chapter == "CH03", "目标选「指定章节」后下拉框列出章节")
	_same_options(auto.current_options(), parsed.call(["CH03", "-s", "random", "-c", "random", "-seed", "42", "-live", "-slow", "-here", "-save"]), "指定章节")
	auto.goal_kind.select(2)
	auto.goal_kind.item_selected.emit(2)
	auto.goal_target.select(auto._level_ids.find("L07_R02"))
	_same_options(auto.current_options(), parsed.call(["L07_R02", "-s", "random", "-c", "random", "-seed", "42", "-live", "-slow", "-here", "-save"]), "指定关卡")
	check(str(auto.describe(auto.current_options())).begins_with("auto "), "describe 给出等价的 auto 命令说明")
	# 还原成默认再往下测。
	auto.goal_kind.select(0)
	auto.goal_kind.item_selected.emit(0)
	for option in [auto.strategy_option, auto.choice_option, auto.mode_option, auto.start_option]: option.select(0)
	auto.delay_option.select(1)
	auto.seed_random.button_pressed = true
	auto.save_check.button_pressed = false
	auto._update_form()
	_same_options(auto.current_options(), parsed.call([]), "还原后")
	check(not commands.parse_auto(PackedStringArray(["-s", "nonsense"])).ok, "命令行拒绝未知打法")
	check(not commands.parse_auto(PackedStringArray(["L99_R99"])).ok, "命令行拒绝未知目标")
	check(not commands.parse_auto(PackedStringArray(["-seed", "-3"])).ok, "命令行拒绝负的种子")
	check(not commands.parse_auto(PackedStringArray(["-delay"])).ok, "命令行拒绝缺少取值的选项")

# ---------- 自动推进页：隔离运行、报告、取消 ----------

func _autoplay_isolated_run() -> void:
	var auto: Control = tab("autoplay")
	var hash_before: int = app.session.export_snapshot().case_state.hash()
	var chapter_before: String = data().chapter
	await click(find_button(auto, "通关全流程"))
	await frames(3)
	check(commands.busy and console.busy_overlay.visible, "运行时出现忙碌遮罩")
	check(auto.start_button.disabled, "运行时开始按钮禁用，不能重复开始")
	var saw_progress := false
	for i in range(400):
		if not console.busy_label.text.is_empty(): saw_progress = true; break
		await process_frame
	check(saw_progress, "运行时遮罩上有进度文字")
	await settle()
	check(not console.busy_overlay.visible and not auto.start_button.disabled, "运行结束后遮罩消失、按钮恢复")
	var report: Dictionary = commands.last_report
	check(bool(report.get("ok", false)) and bool(report.get("reached", false)), "通关打法隔离运行到达片尾")
	check(str(auto.verdict_label.text).contains("通过"), "报告区显示判定「通过」")
	check(auto.levels.get_root().get_child_count() == app.session.config.questions.size(), "逐关表列出全部关卡")
	check(auto.anomalies.get_root().get_child_count() == report.anomalies.size(), "异常表条数与报告一致")
	check(not auto.copy_button.disabled and not auto.detail_button.disabled, "报告出来后「复制报告文字」可用")
	check(data().chapter == chapter_before and app.session.export_snapshot().case_state.hash() == hash_before, "隔离运行没有改动当前游戏进度")
	check(FileAccess.file_exists(commands.REPORT_PATH), "报告已写入文件")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(commands.REPORT_PATH))
	check(parsed is Dictionary and bool(parsed.get("ok", false)) and str(parsed.get("strategy", "")) == "win", "报告文件是合法 JSON 且与界面一致")
	var start: int = console.log_count
	await click(auto.detail_button)
	await settle()
	check(console.log_count > start, "「在日志里展开详细报告」把详细报告写进日志")
	layout_fits("自动推进页（有报告）")

func _autoplay_cancel() -> void:
	var auto: Control = tab("autoplay")
	await click(find_button(auto, "随机抽测"))
	await frames(6)
	check(commands.busy and console.busy_overlay.visible, "随机抽测开始后处于忙碌状态")
	await click(find_button(console.busy_overlay, "取消（Esc）"))
	await settle()
	check(not commands.busy and bool(commands.last_report.get("cancelled", false)), "点遮罩上的取消按钮取消自动推进，报告标注已取消")
	check(str(auto.verdict_label.text).contains("未通过") or str(auto.verdict_label.text).contains("取消"), "取消后判定不是「通过」")

func _busy_overlay() -> void:
	# 快进命令进行中：遮罩出现，点遮罩上的取消按钮取消。
	await show_tab("jump")
	var chapter_before: String = data().chapter
	commands.execute("jump 6")
	await frames(4)
	check(commands.busy and console.busy_overlay.visible, "快进命令进行中出现忙碌遮罩")
	await click(find_button(console.busy_overlay, "取消（Esc）"))
	await settle()
	check(not commands.busy and not console.busy_overlay.visible, "点遮罩上的取消按钮后快进结束、遮罩消失")
	check(data().chapter == chapter_before, "取消快进不改变进度")

# ---------- 实机演示 ----------

func _live_options(delay: int) -> Dictionary:
	return {"goal": {"kind": "ending", "label": "片尾演职员画面"}, "strategy": "win", "choice": "cycle", "seed": -1, "live": true, "delay": delay, "here": false, "save": false, "checks": true}

func _live_run() -> void:
	# 隔着一个探针节点验证按键是否被拦截：探针排在控制台之前，控制台没吞掉的按键才会到它。
	var script := GDScript.new()
	script.source_code = "extends Node\nvar hits := 0\nfunc _input(event):\n\tif event is InputEventKey and event.pressed and event.keycode == KEY_A: hits += 1\n"
	script.reload()
	probe = Node.new()
	probe.set_script(script)
	probe.process_mode = Node.PROCESS_MODE_ALWAYS
	app.add_child(probe)
	app.move_child(probe, console.get_index())
	await key(KEY_A)
	check(int(probe.hits) == 1, "对照：非演示状态下探针能收到按键")
	var writer_before: Callable = app.session.save_writer
	var chapter_before: String = data().chapter
	await show_tab("autoplay")
	console.run_autoplay(_live_options(40), "live")
	var started := false
	for i in range(300):
		if console.live_mode: started = true; break
		await process_frame
	check(started and commands.live_run, "实机演示开始")
	await frames(10)
	check(not console.panel_root.visible and console.banner.visible and not paused and not console.is_open, "实机演示时面板收起、横幅出现、游戏解冻")
	check(app.current_layer == "game" and app.gameplay_page.visible and not app.session.run_id.is_empty(), "演示在真实游戏界面里推进")
	check(not app.session.save_writer.is_valid(), "演示期间自动存档被关闭")
	var hits_before: int = probe.hits
	await key(KEY_A)
	check(probe.hits == hits_before, "演示期间按键被拦截，不会干扰推进")
	await click_point(Vector2(640, 400))
	check(console.live_mode, "演示期间点击游戏画面不会停止演示")
	var progressed := false
	for i in range(1500):
		if str(console.banner_label.text).contains("第"): progressed = true; break
		await process_frame
	check(progressed, "横幅显示推进进度")
	await click(console.banner.find_children("*", "Button", true, false)[0])
	await settle()
	check(not console.live_mode and console.is_open and console.current_tab == "autoplay", "点横幅停止后面板重新打开并停在自动推进页")
	check(not console.banner.visible and not commands.live_run, "停止后横幅消失")
	check(bool(commands.last_report.get("cancelled", false)) and str(commands.last_report.get("mode", "")) == "实机演示", "实机演示的报告标注已取消")
	check(str(tab("autoplay").verdict_label.text).length() > 0, "报告区已更新")
	await frames(10)
	check(app.session.save_writer == writer_before or app.session.save_writer.is_valid() == writer_before.is_valid(), "演示结束后自动存档写入已恢复")
	check(commands.undo_snapshot.size() > 0, "演示前的进度可 undo")
	var start: int = console.log_count
	await console.run("undo")
	check(log_since(start).contains("已回到") and data().chapter == chapter_before, "undo 回到演示前的章节")
	# Esc 停止。
	console.run_autoplay(_live_options(40), "live")
	for i in range(300):
		if console.live_mode: break
		await process_frame
	await frames(20)
	check(console.live_mode, "第二次实机演示开始")
	await key(KEY_ESCAPE)
	await settle()
	check(not console.live_mode and console.is_open and bool(commands.last_report.get("cancelled", false)), "演示期间按 Esc 停止并重新打开面板")
	layout_fits("演示结束后")
	if is_instance_valid(probe): probe.queue_free()

# ---------- 锁定 ----------

func _lock_again() -> void:
	await show_tab("tools")
	await click(find_button(tab("tools"), "锁定控制台（需再输入 super）"))
	await settle()
	check(not console.unlocked and console.prompt_box.visible and not console.main_panel.visible, "「锁定控制台」换回口令弹窗")
	await key(KEY_ESCAPE)
	check(not console.is_open and not paused and is_equal_approx(Engine.time_scale, 1.0), "关闭后游戏恢复且倍率为 1")
