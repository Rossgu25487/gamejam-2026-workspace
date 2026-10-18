extends SceneTree
## 调试控制台回归：按键呼出与解锁、跳关与关卡跳转、物品、调试命令；隔离存储，不读写玩家档案。
## 命令走 console.submit（图形按钮也走这条路径）；图形界面本身见 debug_console_ui_test。
const AutoPlay = preload("res://systems/debug_console/debug_auto_play.gd")
var app: Control
var console: CanvasLayer
var commands: RefCounted
var failures: Array[String] = []
var checks := 0

func _init() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("DEBUG_CONSOLE_FAILED " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func press(code: Key, unicode: int = 0) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code; event.physical_keycode = code; event.unicode = unicode; event.pressed = down
		root.push_input(event)
	await frames()

## 执行一条命令并返回它产生的全部输出行。
func run_command(line: String) -> String:
	var start: int = console.log_lines.size()
	await console.submit(line)
	await frames(2)
	return "\n".join(console.log_lines.slice(start))

func said(output: String, fragment: String, message: String) -> void:
	check(output.contains(fragment), message + "（输出：" + output.left(160).replace("\n", " / ") + "）")

func data() -> Dictionary: return app.session.case_state.data

func _run() -> void:
	root.size = Vector2i(1280, 800)
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = "user://debug_console_test_%d" % Time.get_ticks_usec()
	root.add_child(app)
	await frames(6)
	console = app.debug_console
	check(console != null and console.get_parent() == app, "正式入口建立了调试控制台")
	if console == null: quit(1); return
	commands = console.commands
	check(app.get_children().back() == console, "控制台是入口最后一个子节点，先于页面收到按键")
	check(not console.is_open and not console.panel_root.visible and not paused, "启动时控制台关闭且游戏未冻结")
	check(app.current_layer == "title" and app.title_page.visible, "起点是标题界面")

	# ---- 呼出、解锁、关闭 ----
	await press(KEY_QUOTELEFT)
	check(console.is_open and console.panel_root.visible and paused, "标题界面按 ~ 键呼出控制台并冻结游戏")
	check(not console.unlocked, "初次呼出处于未解锁状态")
	check(console.prompt_box.visible and not console.main_panel.visible, "未解锁只显示口令弹窗，不显示功能面板")
	var out := await run_command("help")
	said(out, "未知命令", "未解锁时不执行任何命令")
	check(not console.unlocked and not console.main_panel.visible, "输错口令不解锁")
	out = await run_command("jump 3")
	check(app.current_layer == "title", "未解锁时 jump 不生效")
	await run_command("SUPER")
	check(console.unlocked, "输入 super（不分大小写）后解锁")
	check(console.main_panel.visible and not console.prompt_box.visible, "解锁后直接弹出图形功能面板")
	await press(KEY_QUOTELEFT)
	check(not console.is_open and not paused and not console.panel_root.visible, "再按 ~ 键关闭并恢复游戏")
	await press(KEY_ASCIITILDE)
	check(console.is_open and console.unlocked, "~ 键重新呼出，解锁状态保持")
	check(console.main_panel.visible and not console.prompt_box.visible, "解锁后再按 ~ 键直接呼出图形面板，不再要口令")
	await press(KEY_ESCAPE)
	check(not console.is_open and not paused, "Esc 关闭控制台")
	check(app.current_layer == "title", "Esc 被控制台吞掉，没有触发游戏菜单")
	await press(KEY_NONE, 183)
	check(console.is_open, "输入法产生的间隔号也能呼出")
	var edit: LineEdit = console.input_edit
	edit.text = "gi`ve"
	edit.text_changed.emit(edit.text)
	check(edit.text == "give", "输入框过滤掉切换键字符")
	edit.clear()
	check(commands.completions("gi").has("give") and commands.completions("give E0").has("E01"), "Tab 补全命令和材料 ID")
	check(commands.completions("jump ").has("end") and commands.completions("scene SC02 ").has("arrive"), "Tab 补全跳转目标")
	check(commands.tokenize("items \"证物 清单\" x").size() == 3, "命令行支持引号分组")
	out = await run_command("give E01")
	said(out, "尚未开始游戏", "标题界面不能直接给物品")
	out = await run_command("nosuchcommand")
	said(out, "未知命令", "未知命令给出提示")
	out = await run_command("help")
	said(out, "[跳转]", "help 列出分组命令")
	out = await run_command("help jump")
	said(out, "undo", "help <命令> 给出详细用法")

	# ---- 章节快进 ----
	out = await run_command("jump 3")
	said(out, "已到达", "jump 3 报告到达")
	check(app.current_layer == "game" and data().chapter == "CH03" and app.session.mode == "investigation", "jump 3 到第三章的可操作调查点")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "快进得到的状态可通过存档校验")
	check(console.is_open and paused, "跳转后控制台保持打开")
	check(data().events.get("EV_CASE_INVESTIGATION_OPEN", false) and data().events.get("EV_CH02_OPEN_CH03", false), "前序章节事件由真实流程产生")
	check(data().materials.size() > 10, "前序章节的材料由真实流程取得")
	await frames(3)
	check(console.get_children().filter(func(node): return node is Node and node.get_script() != null).is_empty(), "隔离会话已清理")
	await press(KEY_QUOTELEFT)
	check(not paused and app.gameplay_page.visible, "关闭控制台后游戏恢复并显示调查画面")
	await press(KEY_QUOTELEFT)

	# ---- 查看类命令 ----
	out = await run_command("status")
	said(out, "CH03", "status 显示当前章节")
	out = await run_command("chapters")
	said(out, "第六章", "chapters 列出章节")
	out = await run_command("levels")
	said(out, "L07_R02", "levels 列出关卡")
	out = await run_command("scenes")
	said(out, "站长室", "scenes 列出场景")
	out = await run_command("items")
	said(out, "已持有材料", "items 列出已持有材料")
	out = await run_command("items 证物")
	said(out, "E01", "items 支持按类型过滤整个目录")
	out = await run_command("entries INV_SC02")
	said(out, "INV_SC02", "entries 支持过滤")
	out = await run_command("events SHARED_MEAL")
	said(out, "EV_SHARED_MEAL_FINISHED", "events 支持过滤")
	out = await run_command("cond COND_CH03_L07_AVAILABLE")
	said(out, "分支", "cond 逐项解释条件")
	out = await run_command("cond COND_NOT_EXISTS")
	said(out, "没有这个条件", "cond 对未知条件报错")

	# ---- 物品 ----
	var state: RefCounted = app.session.case_state
	await run_command("take all")
	check(state.data.materials.is_empty(), "take all 清空全部材料")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "清空材料后状态仍可校验")
	out = await run_command("give E01")
	check(state.owns("E01_V1"), "give 材料 ID 获得材料")
	said(out, "获得", "give 报告获得内容")
	await run_command("give E02")
	var latest := "E02_V%d" % _versions_total("E02")
	check(_versions_total("E02") > 1 and state.owns(latest) and not state.owns("E02_V1"), "give 材料 ID 默认只取最新版本")
	await run_command("give E02_V1")
	check(state.owns("E02_V1") and state.data.materials.E02.current == latest, "give 内容 ID 取指定版本且不降级当前版本")
	await run_command("give T01 -a")
	check(_versions_owned("T01") == _versions_total("T01"), "give -a 取得全部版本")
	await run_command("give inference")
	check(state.owns("P01_V1") or state.data.materials.has("P01"), "give inference 获得全部推论")
	await run_command("give all")
	check(state.data.materials.size() == app.session.config.materials.size(), "give all 获得全部材料")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "获得全部材料后状态仍可校验")
	out = await run_command("give ZZ99")
	said(out, "未知物品", "give 未知物品报错")
	await run_command("take E02_V4")
	check(not state.owns("E02_V4") and state.data.materials.E02.current != "E02_V4" and state.owns("E02_V1"), "take 内容 ID 只移除该版本并修正当前版本")
	await run_command("take E01")
	check(not state.data.materials.has("E01"), "take 材料 ID 移除该材料")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "移除材料后状态仍可校验")

	# ---- 地点、人物、事件、机会、速度、状态信息 ----
	out = await run_command("scene SC09")
	check(data().scene == "SC09" and app.session.return_context.scene == "SC09", "scene 无条件前往场景")
	await run_command("scene 大厅")
	check(data().scene == "SC02", "scene 支持按场景名称前往")
	out = await run_command("scene SC99")
	said(out, "没有这个场景", "scene 未知场景报错")
	await run_command("npc CHR04 SC06")
	check(data().npc.CHR04.scene_id == "SC06", "npc 移动人物位置")
	out = await run_command("npc")
	said(out, "伊万", "npc 列出人物位置")
	out = await run_command("event EV_CASE_INVESTIGATION_OPEN")
	said(out, "已执行", "event 重复执行已发生事件不破坏状态")
	out = await run_command("event EV_NOT_EXISTS")
	said(out, "没有这个事件", "event 未知事件报错")
	await run_command("chances L01_R01 1")
	check(data().chances.L01_R01 == 1, "chances 设置单个关卡机会")
	await run_command("chances all 3")
	check(data().chances.L07_R02 == 3, "chances all 设置全部关卡机会")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "改动机会后状态仍可校验")
	await run_command("speed 2")
	check(is_equal_approx(Engine.time_scale, 2.0), "speed 设置时间倍率")
	await run_command("speed 1")
	check(is_equal_approx(Engine.time_scale, 1.0), "speed 1 恢复倍率")
	await run_command("hud on")
	await create_timer(0.4, true, false, true).timeout
	check(console.hud_enabled and console.hud_label.visible and console.hud_label.text.contains("CH03"), "hud 显示章节等状态信息")
	await run_command("hud off")
	check(not console.hud_label.visible, "hud off 隐藏状态信息")

	# ---- 关卡跳转 ----
	out = await run_command("jump L07_R02")
	said(out, "已到达", "jump 关卡报告到达")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "关卡跳转得到的状态可校验")
	# L07_R02 的入口先播一段剧情，结尾才是进入本关的选项；跳关必须替测试者选中，直接落在选材界面。
	check(app.session.mode == "selection" and app.session.question == "L07_R02", "jump 入口带剧情的关卡也直接进入选材界面")
	said(out, "入口剧情读完", "jump 报告入口剧情已读完")
	var level_chapter: String = data().chapter
	out = await run_command("skip")
	said(out, "读完", "skip 读完当前对白")
	out = await run_command("jump L02_R01")
	check(app.session.mode == "selection" and app.session.question == "L02_R01", "jump 直接进入关卡选材界面")
	check(not AutoPlay.solvable_rows(app.session, "L02_R01").is_empty(), "关卡跳转时已持有可过关的材料")
	check(app.gameplay_page.card_page.visible, "选材界面实际显示")

	# ---- 撤回 ----
	out = await run_command("jump 5")
	said(out, "已到达", "jump 5 在没有稳定第五章时仍能到达")
	check(data().chapter == "CH06" and app.session.mode == "investigation", "第五章直接衔接第六章，停在其后第一个可操作点")
	out = await run_command("undo")
	said(out, "已回到", "undo 回到跳转前")
	check(app.session.mode == "selection" and app.session.question == "L02_R01", "undo 恢复到关卡选材界面")
	out = await run_command("undo")
	said(out, "没有可撤回", "undo 只撤回一次")

	# ---- 在子页面中跳转 ----
	await press(KEY_QUOTELEFT)
	app._resume()
	app.pause_page.settings_requested.emit()
	await frames(2)
	check(app.current_layer == "subpage" and app.settings_page.visible, "进入设置子页面")
	await press(KEY_QUOTELEFT)
	check(console.is_open, "设置页内也能呼出控制台")
	await run_command("jump 2")
	check(not app.settings_page.visible and app.current_layer == "game" and data().chapter == "CH02", "子页面中跳转会收起子页面并进入游戏")

	# ---- 取消快进 ----
	var chapter_before: String = data().chapter
	var snapshot_before: Dictionary = app.session.export_snapshot()
	var before_lines: int = console.log_lines.size()
	commands.execute("jump 6")
	await frames(2)
	check(commands.busy, "快进进行中控制台处于忙碌状态")
	await press(KEY_QUOTELEFT)
	check(console.is_open, "快进进行中不能用 ~ 键关闭控制台")
	var busy_out := await run_command("status")
	check(console.log_lines.slice(before_lines).any(func(line): return line.contains("仍在执行")), "快进进行中拒绝其他命令")
	await press(KEY_ESCAPE)
	for i in range(300):
		if not commands.busy: break
		await process_frame
	check(not commands.busy, "Esc 取消后快进结束")
	check("\n".join(console.log_lines.slice(before_lines)).contains("已取消"), "取消后给出提示")
	check(data().chapter == chapter_before and app.session.export_snapshot().case_state.hash() == snapshot_before.case_state.hash(), "取消快进不改变当前进度")
	check(console.is_open, "取消快进不关闭控制台")

	# ---- 片尾 ----
	out = await run_command("jump end")
	said(out, "已到达", "jump end 到片尾")
	check(app.session.mode == "credits", "jump end 进入演职员画面")
	check(app.session.validate_snapshot(app.session.export_snapshot()), "片尾状态可校验")

	# ---- 锁定与收尾 ----
	await run_command("lock")
	check(not console.unlocked, "lock 重新锁定")
	check(console.prompt_box.visible and not console.main_panel.visible, "锁定后面板换回口令弹窗")
	out = await run_command("status")
	said(out, "未知命令", "锁定后命令不再可用")
	await press(KEY_ESCAPE)
	check(not console.is_open and not paused and is_equal_approx(Engine.time_scale, 1.0), "关闭后游戏恢复且倍率为 1")
	app.queue_free()
	await frames(30)
	print("DEBUG_CONSOLE ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

func _versions_total(material: String) -> int:
	return app.session.config.contents.keys().filter(func(id): return app.session.config.contents[id].material_id == material).size()

func _versions_owned(material: String) -> int:
	return app.session.case_state.data.materials.get(material, {}).get("versions", {}).size()
