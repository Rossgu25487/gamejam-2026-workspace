extends SceneTree
## 自动推进回归：参数解析、各打法与取项方式、目标与起点、可复现性、取消、异常检出、实机演示、报告与存档隔离。
## 隔离存储，不读写玩家档案。图形界面本身见 debug_console_ui_test。
const AutoPlay = preload("res://systems/debug_console/debug_auto_play.gd")
const Commands = preload("res://systems/debug_console/debug_commands.gd")
const STABLE_RANDOM_SEEDS := [1, 3]
const EXPLORED_RANDOM_SEEDS := [2, 4, 5, 6]
var app: Control
var console: CanvasLayer
var commands: RefCounted
var storage := ""
var failures: Array[String] = []
var checks := 0

func _init() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("DEBUG_AUTOPLAY_FAILED " + message)

func frames(count: int = 4) -> void:
	for i in range(count): await process_frame

func data() -> Dictionary: return app.session.case_state.data

## 用与控制台命令相同的解析器得到选项，保证命令行和界面走同一条路径。
func opts(args: Array) -> Dictionary:
	var parsed: Dictionary = commands.parse_auto(PackedStringArray(args))
	check(bool(parsed.ok), "参数可解析：" + " ".join(args.map(func(item): return str(item))))
	return parsed.get("options", {})

func play(args: Array) -> Dictionary:
	return await commands.run_autoplay(opts(args))

func report_of(result: Dictionary) -> Dictionary: return result.get("report", {})

func kinds(report: Dictionary) -> Array:
	return report.get("anomalies", []).map(func(item): return str(item.kind))

func error_count(report: Dictionary) -> int:
	return report.get("anomalies", []).filter(func(item): return str(item.severity) == "error").size()

func run_line(line: String) -> String:
	var start: int = console.log_count
	await console.submit(line)
	await frames(2)
	return "\n".join(console.log_lines.slice(maxi(0, console.log_lines.size() - (console.log_count - start))))

func said(output: String, fragment: String, message: String) -> void:
	check(output.contains(fragment), message + "（输出：" + output.left(160).replace("\n", " / ") + "）")

func engine_for(goal: Dictionary) -> RefCounted:
	var engine: RefCounted = AutoPlay.new()
	engine.host = app
	engine.shared_config = commands.config
	engine.goal = goal
	return engine

func start_in_background(options: Dictionary, holder: Dictionary) -> void:
	holder["result"] = await commands.run_autoplay(options)

func wait_for(holder: Dictionary, limit_ms: int = 120000) -> void:
	var started := Time.get_ticks_msec()
	while not holder.has("result") and Time.get_ticks_msec() - started < limit_ms: await process_frame
	check(holder.has("result"), "后台运行在限时内结束")
	await frames(3)

func save_files() -> Dictionary:
	return _hash_files(storage.path_join("saves"))

func _hash_files(base: String) -> Dictionary:
	var state := {}
	if not DirAccess.dir_exists_absolute(base): return state
	for file in DirAccess.get_files_at(base): state[base.path_join(file)] = FileAccess.get_sha256(base.path_join(file))
	for folder in DirAccess.get_directories_at(base): state.merge(_hash_files(base.path_join(folder)))
	return state

func _remove_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for file in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(file))
	for folder in DirAccess.get_directories_at(path): _remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(path)

func _run() -> void:
	root.size = Vector2i(1280, 800)
	storage = "user://debug_autoplay_test_%d" % Time.get_ticks_usec()
	app = load("res://main/aurora.tscn").instantiate()
	app.test_storage_path = storage
	root.add_child(app)
	await frames(6)
	console = app.debug_console
	check(console != null, "正式入口建立了调试控制台")
	if console == null: quit(1); return
	commands = console.commands
	console.open_console()
	await run_line("super")
	check(console.unlocked, "解锁控制台")

	await _command_surface_before_runs()
	await _parse_options()
	await _isolated_win()
	await _determinism()
	await _strategies()
	await _goals()
	await _checks_and_cancel()
	await _sabotage()
	await _busy_guard()
	await _report_output()
	await _live_run()

	console.close_console()
	app.queue_free()
	await frames(30)
	_remove_dir(storage)
	print("DEBUG_AUTOPLAY ", failures.is_empty(), " checks=", checks)
	quit(0 if failures.is_empty() else 1)

# ---------- 命令入口（还没有任何报告时） ----------

func _command_surface_before_runs() -> void:
	var out := await run_line("auto report")
	said(out, "还没有自动推进报告", "没有跑过时 auto report 给出提示")
	out = await run_line("help auto")
	said(out, "-seed", "help auto 说明随机种子")
	said(out, "-live", "help auto 说明实机演示")
	out = await run_line("auto -s bogus")
	said(out, "未知打法", "未知打法给出提示")
	check(commands.last_report.is_empty() and not commands.busy, "参数错误不会开始运行")

# ---------- 参数解析 ----------

func _parse_options() -> void:
	var base: Dictionary = opts([])
	check(str(base.goal.kind) == "ending" and base.strategy == "win" and base.choice == "cycle", "默认：通关打法、循环取项、目标片尾")
	check(int(base.seed) == -1 and not base.live and not base.here and not base.save and base.checks and int(base.delay) == 0, "默认：不实机、不从当前进度、不存档、做校验、无延迟")
	var chapter: Dictionary = opts(["3"])
	check(chapter.goal.kind == "chapter" and chapter.goal.chapter == "CH03", "数字目标指向章节")
	check(opts(["CH05"]).goal.chapter == "CH05" and opts(["ch06"]).goal.chapter == "CH06", "章节 ID 不分大小写")
	check(opts(["L07_R02"]).goal.kind == "level" and opts(["l07_r02"]).goal.question == "L07_R02", "关卡 ID 不分大小写")
	check(opts(["end"]).goal.kind == "ending" and opts(["片尾"]).goal.kind == "ending" and opts(["结局"]).goal.kind == "ending", "end 与中文别名指向片尾")
	var custom: Dictionary = opts(["-s", "random", "-c", "last", "-seed", "7"])
	check(custom.strategy == "random" and custom.choice == "last" and int(custom.seed) == 7, "打法、取项与种子可同时指定")
	check(opts(["-s", "通关"]).strategy == "win" and opts(["-s", "错误"]).strategy == "fail" and opts(["-s", "随机"]).strategy == "random", "打法支持中文别名")
	check(opts(["-c", "第一"]).choice == "first" and opts(["-c", "最后"]).choice == "last" and opts(["-c", "循环"]).choice == "cycle", "取项支持中文别名")
	check(opts(["-strategy", "fail", "-choice", "first"]).strategy == "fail", "长选项名可用")
	var live: Dictionary = opts(["-live"])
	check(live.live and int(live.delay) == Commands.DELAY_PRESETS.normal, "实机演示默认用正常速度")
	check(int(opts(["-live", "-slow"]).delay) == Commands.DELAY_PRESETS.slow and int(opts(["-fast"]).delay) == Commands.DELAY_PRESETS.fast, "-slow / -fast 调整速度")
	check(int(opts(["-live", "-delay", "99"]).delay) == 99 and int(opts(["-delay", "0"]).delay) == 0, "-delay 自定毫秒")
	var flags: Dictionary = opts(["-here", "-save", "-nocheck"])
	check(flags.here and flags.save and not flags.checks, "-here / -save / -nocheck 生效")
	check(opts(["L02_R01", "-s", "fail"]).goal.question == "L02_R01", "目标和选项顺序不限")
	for bad in [["-x"], ["-s"], ["-s", "bogus"], ["-c", "bogus"], ["-seed", "-1"], ["-seed", "abc"], ["-delay", "5001"], ["-delay", "-5"], ["3", "4"], ["NO_SUCH_GOAL"]]:
		var parsed: Dictionary = commands.parse_auto(PackedStringArray(bad))
		check(not bool(parsed.ok) and not str(parsed.get("error", "")).is_empty(), "拒绝非法参数：" + " ".join(bad))

# ---------- 通关全流程（隔离） ----------

func _isolated_win() -> void:
	# 先开一局真实游戏：隔离运行不应改动它。
	check(app.debug_new_game(), "开一局真实游戏作为对照")
	await frames(3)
	var state_before: int = data().hash()
	var layer_before: String = app.current_layer
	var saves_before := save_files()
	var app_children: int = app.get_child_count()
	var console_children: int = console.get_child_count()
	var started := Time.get_ticks_msec()
	var result: Dictionary = await play([])
	var elapsed := Time.get_ticks_msec() - started
	var report := report_of(result)
	check(bool(result.get("ok", false)) and bool(report.get("reached", false)) and str(result.get("mode", "")) == "credits", "通关打法到达片尾演职员画面（原因：%s）" % str(report.get("reason", "")))
	check(error_count(report) == 0, "通关全流程没有错误级异常：%s" % str(report.get("anomalies", [])).left(300))
	check(str(report.mode) == "隔离快速" and str(report.strategy) == "win" and str(report.choice) == "cycle" and int(report.seed) == 0, "报告记录模式、打法、取项和种子")
	var coverage: Dictionary = report.coverage
	check(coverage["关卡"] == [18, 18], "全部 18 个关卡完成：%s" % str(coverage["关卡"]))
	check(int(coverage["章节"][0]) >= 5, "至少经过 5 个章节（第五章没有稳定调查阶段）：%s" % str(coverage["章节"]))
	check(report.levels.size() == 18 and report.levels.values().all(func(level): return int(level.done_step) > 0 and int(level.wrong) == 0 and int(level.failures) == 0), "通关打法每关都一次过、没有错误出示")
	check(str(report.timeline[0].chapter) == "CH01" and str(report.timeline[report.timeline.size() - 1].chapter) == "CH06", "章节时间线从 CH01 到 CH06")
	check(int(report.stats.paragraphs) > 100 and int(report.stats.choices) > 0 and int(report.stats.presents) >= 18, "对白、选项、出示都有实际推进：%s" % str(report.stats))
	check(int(report.stats.checkpoints) > 5 and int(report.stats.roundtrips) == int(report.stats.checkpoints), "每个存档校验点都做了读档往返")
	check(str(report.final.mode) == "credits" and not report.decisions.is_empty() and int(report.steps) > 0 and int(report.actions) > 0, "报告含最终状态与决策记录")
	check(not result.snapshot.is_empty() and app.session.validate_snapshot(result.snapshot), "结果存档通过校验")
	check(elapsed < 60000, "隔离运行在 60 秒内完成（实际 %.1f 秒）" % (elapsed / 1000.0))
	check(data().hash() == state_before and app.current_layer == layer_before, "隔离运行没有改动真实游戏")
	check(save_files() == saves_before, "隔离运行没有写任何存档文件")
	await frames(3)
	check(app.get_child_count() == app_children and console.get_child_count() == console_children, "临时会话已全部清理")
	check(not commands.busy and not commands.live_run, "运行结束后命令层不再忙碌")
	check(commands.last_report.get("serial", 0) == report.serial and not str(report.get("file", "")).is_empty(), "报告登记为最近一次并带文件路径")

# ---------- 可复现性 ----------

func _determinism() -> void:
	var first: Dictionary = report_of(await play(["-s", "random", "-seed", "7", "3"]))
	var second: Dictionary = report_of(await play(["-s", "random", "-seed", "7", "3"]))
	check(JSON.stringify(first.decisions) == JSON.stringify(second.decisions) and JSON.stringify(first.stats) == JSON.stringify(second.stats), "同一随机种子的决策序列完全一致")
	check(int(first.seed) == 7 and int(second.seed) == 7, "报告记录种子")
	var other: Dictionary = report_of(await play(["-s", "random", "-seed", "8", "3"]))
	check(JSON.stringify(first.decisions) != JSON.stringify(other.decisions), "不同种子走出不同的决策序列")
	var win_a: Dictionary = report_of(await play(["3"]))
	var win_b: Dictionary = report_of(await play(["3"]))
	check(JSON.stringify(win_a.decisions) == JSON.stringify(win_b.decisions), "通关打法本身是确定的")
	var auto_seed: Dictionary = report_of(await play(["-s", "random", "2"]))
	check(int(auto_seed.seed) >= 0 and bool(auto_seed.reached), "随机打法不写种子时自动取一个并记录")
	var plain: Dictionary = report_of(await play(["2"]))
	check(int(plain.seed) == 0, "非随机打法的种子固定为 0")

# ---------- 打法与取项 ----------

func _strategies() -> void:
	var fail: Dictionary = report_of(await play(["-s", "fail"]))
	check(bool(fail.reached) and bool(fail.ok), "错误尝试最终仍能通关（原因：%s）" % str(fail.get("reason", "")))
	check(int(fail.stats.wrong) > 0 and int(fail.stats.failures) > 0 and int(fail.stats.retries) > 0, "错误尝试真的走了错误出示、失败界面和重试：%s" % str(fail.stats))
	check(fail.coverage["关卡"] == [18, 18] and error_count(fail) == 0, "错误尝试走完全部关卡且无错误级异常：%s" % str(fail.anomalies).left(300))
	var first: Dictionary = report_of(await play(["-c", "first"]))
	check(bool(first.reached) and bool(first.ok) and error_count(first) == 0, "取项「总选第一项」也能通关（原因：%s）" % str(first.get("reason", "")))
	check(first.coverage["关卡"] == [18, 18], "取项「总选第一项」完成全部关卡：%s" % str(first.coverage["关卡"]))
	for seed_value in STABLE_RANDOM_SEEDS:
		var stable: Dictionary = report_of(await play(["-s", "random", "-seed", str(seed_value)]))
		check(bool(stable.reached) and bool(stable.ok) and error_count(stable) == 0, "随机打法种子 %d 通关（原因：%s；异常：%s）" % [seed_value, str(stable.get("reason", "")), str(stable.anomalies).left(200)])
	# 下面这些走法会撞上游戏本身尚未修复的缺陷（见 print 出的 INFO 行）：不要求通关，
	# 但引擎必须如实判定、给出原因、不卡死也不残留，缺陷修好后自然转为通关。
	await explore("取项「总选最后一项」", ["-c", "last"])
	for seed_value in EXPLORED_RANDOM_SEEDS:
		var args: Array = ["-s", "random", "-seed", str(seed_value)]
		if seed_value % 2 == 0: args.append_array(["-c", "random"])
		await explore("随机打法种子 %d" % seed_value, args)

## 探索性走法：只验证引擎的判定自洽，并把游戏侧发现的问题打印出来。
func explore(label: String, args: Array) -> void:
	var children: int = console.get_child_count()
	var started := Time.get_ticks_msec()
	var result: Dictionary = await play(args)
	var report := report_of(result)
	check(not report.is_empty() and report.has("coverage") and not report.timeline.is_empty(), label + "：产生了完整的报告")
	if report.is_empty(): return
	var reached: bool = bool(report.reached)
	var errors := error_count(report)
	check(bool(result.ok) == (reached and errors == 0), "%s：通过与否只取决于是否到达目标且没有错误级异常（到达 %s，错误 %d，判定 %s）" % [label, reached, errors, result.ok])
	check(bool(result.ok) or not str(report.reason).is_empty(), label + "：未通过时写明了原因（%s）" % str(report.reason).left(60))
	if reached and errors > 0: check(str(report.reason).contains("错误级异常"), label + "：到达目标但有错误级异常时，原因说明这一点")
	check(str(AutoPlay.report_lines(report, false)[1].text).contains("未到达目标") != reached, label + "：简要报告的结果行与实际一致")
	check(Time.get_ticks_msec() - started < 120000, label + "：在限时内结束")
	check(console.get_child_count() == children and not commands.busy, label + "：没有残留的临时会话")
	var found: Array = []
	for item in report.anomalies: found.append("%s/%s %s" % [item.kind, item.severity, str(item.message).left(70)])
	print("DEBUG_AUTOPLAY_INFO %s：%s，覆盖关卡 %s%s" % [label, "通关" if bool(result.ok) else "未通过（%s）" % str(report.reason).left(70), str(report.coverage["关卡"]), "；发现 " + "；".join(found) if not found.is_empty() else ""])

# ---------- 目标与起点 ----------

func _goals() -> void:
	var chapter: Dictionary = await play(["3"])
	var report := report_of(chapter)
	check(bool(chapter.ok) and str(chapter.mode) == "investigation" and str(chapter.chapter) == "CH03", "目标第三章：停在第三章的调查画面")
	check(str(report.timeline[report.timeline.size() - 1].chapter) == "CH03" and str(report.goal).contains("CH03"), "报告写明目标与时间线终点")
	check(app.session.validate_snapshot(chapter.snapshot) and chapter.snapshot.case_state.chapter == "CH03", "结果存档可校验且在第三章")
	var fifth: Dictionary = await play(["5"])
	check(bool(fifth.ok) and str(fifth.chapter) == "CH06" and str(fifth.mode) == "investigation", "第五章没有稳定调查阶段时停在其后第一个可操作点")
	var level: Dictionary = await play(["L07_R02"])
	var level_report := report_of(level)
	check(bool(level.ok) and str(level.mode) == "investigation", "目标关卡：停在调查画面等关卡开放")
	check(not level_report.levels.has("L07_R02") or int(level_report.levels.L07_R02.done_step) == 0, "到达关卡开放点时该关尚未完成")
	var earlier: Dictionary = await play(["L02_R01"])
	check(bool(earlier.ok) and int(report_of(earlier).levels.size()) < 18, "更靠前的关卡用更少的步数到达")
	check(int(report_of(earlier).steps) < int(level_report.steps), "靠前目标的步数少于靠后目标")
	# 从当前进度继续：隔离模式取当前存档作起点，但不改动真实游戏。
	await run_line("jump 3")
	check(data().chapter == "CH03" and app.session.mode == "investigation", "先把真实游戏快进到第三章")
	var state_before: int = data().hash()
	var here: Dictionary = await play(["5", "-here"])
	var here_report := report_of(here)
	check(bool(here.ok) and str(here_report.timeline[0].chapter) == "CH03" and str(here.chapter) == "CH06", "-here 从当前进度（第三章）继续推进")
	check(data().hash() == state_before, "-here 的隔离运行没有改动真实游戏")
	var fresh: Dictionary = report_of(await play(["5"]))
	check(int(here_report.steps) < int(fresh.steps), "从中途开始比从头开始步数少")
	# 当前已在第三章，目标是第二章：目标已被越过，按「已到达」处理，不应空转。
	var past: Dictionary = await play(["2", "-here"])
	check(bool(past.get("ok", false)), "目标章节不晚于当前章节时立即视为到达")

# ---------- 校验开关与取消 ----------

func _checks_and_cancel() -> void:
	var unchecked: Dictionary = report_of(await play(["3", "-nocheck"]))
	check(bool(unchecked.reached) and int(unchecked.stats.checkpoints) == 0 and int(unchecked.stats.roundtrips) == 0, "-nocheck 不做存档校验和读档往返")
	var engine := engine_for({"kind": "ending", "label": "片尾演职员画面"})
	engine.step_hook = func(step, _session): if step == 120: engine.cancel()
	var result: Dictionary = await engine.run()
	engine.step_hook = Callable()  # 钩子捕获了引擎自己，不解开会形成引用环而泄漏
	var report := report_of(result)
	check(not bool(result.ok) and bool(report.cancelled) and not bool(report.reached) and str(report.reason) == "已取消。", "取消后结果为未到达、已取消")
	check(result.snapshot.is_empty() and int(report.steps) >= 120 and int(report.steps) < 400, "取消发生在预定步数附近：%d 步" % int(report.steps))
	var lines := AutoPlay.report_lines(report, false)
	check(str(lines[0].kind) == "error" and str(lines[0].text).contains("未通过") and str(lines[1].text).contains("未到达目标"), "取消的报告标为未通过")
	await frames(3)
	check(not commands.busy and not is_instance_valid(engine.session), "取消后临时会话已销毁")

# ---------- 异常检出 ----------

func _sabotage() -> void:
	# 每步清空材料：玩家永远凑不齐出示材料，应报告走不下去，而不是死循环。
	var stuck := engine_for({"kind": "ending", "label": "片尾演职员画面"})
	stuck.step_hook = func(_step, target): if str(target.mode) == "investigation": target.case_state.data.materials.clear()
	var stuck_result: Dictionary = await stuck.run()
	var stuck_report := report_of(stuck_result)
	check(not bool(stuck_result.ok) and not bool(stuck_report.reached), "每步清空材料时不会被判通过")
	check(kinds(stuck_report).has("stuck") and error_count(stuck_report) >= 1, "检出「走不下去」并定为错误级：%s" % str(kinds(stuck_report)))
	check(str(stuck_report.reason).contains("没有可继续推进") or str(stuck_report.reason).contains("无法") or str(stuck_report.reason).contains("循环"), "失败原因写明卡点：%s" % str(stuck_report.reason).left(120))
	var stuck_lines := AutoPlay.report_lines(stuck_report, true)
	check(stuck_lines.any(func(line): return str(line.text).contains("停止前最近的动作")), "详细报告附上停止前最近的动作")

	# 中途塞进一个不存在的事件：存档校验必须报错，并且最终判定不通过。
	var corrupt := engine_for({"kind": "chapter", "chapter": "CH02", "label": "CH02"})
	corrupt.step_hook = func(step, target): if step == 30: target.case_state.data.events["EV_BOGUS_SABOTAGE"] = true
	var corrupt_result: Dictionary = await corrupt.run()
	var corrupt_report := report_of(corrupt_result)
	check(kinds(corrupt_report).has("snapshot") and error_count(corrupt_report) >= 1, "存档快照损坏被检出为错误：%s" % str(kinds(corrupt_report)))
	check(not bool(corrupt_result.ok), "快照损坏时最终判定不通过")
	var tolerant := engine_for({"kind": "chapter", "chapter": "CH02", "label": "CH02"})
	tolerant.checks = false
	tolerant.step_hook = func(step, target): if step == 30: target.case_state.data.events["EV_BOGUS_SABOTAGE"] = true
	var tolerant_result: Dictionary = await tolerant.run()
	check(not bool(tolerant_result.ok) and not report_of(tolerant_result).anomalies.any(func(item): return str(item.kind) == "snapshot"), "关闭校验后不再记录快照异常，但结果存档完整性仍会被拒绝")

# ---------- 并发保护 ----------

func _busy_guard() -> void:
	var holder := {}
	var game_state: int = data().hash()
	start_in_background(opts(["3"]), holder)
	check(commands.busy, "后台运行时命令层忙碌")
	var start: int = console.log_count
	var again: Dictionary = await commands.run_autoplay(opts(["2"]))
	check(again.is_empty() and console.log_lines.slice(maxi(0, console.log_lines.size() - (console.log_count - start))).any(func(line): return str(line).contains("仍在执行")), "忙碌时拒绝第二次运行并提示")
	var refused := await run_line("jump 2")
	said(refused, "仍在执行", "忙碌时其他命令也被拒绝")
	commands.cancel()
	await wait_for(holder)
	var report := report_of(holder.get("result", {}))
	check(bool(report.get("cancelled", false)) and not bool(report.get("reached", true)), "取消后第一次运行以已取消结束")
	check(not commands.busy and data().hash() == game_state, "取消不改变真实游戏")

# ---------- 报告输出 ----------

func _report_output() -> void:
	var out := await run_line("auto 3")
	said(out, "自动推进报告 [通过", "auto 命令输出报告标题")
	said(out, "覆盖", "报告含覆盖统计")
	said(out, "完整报告", "命令提示完整报告的文件位置")
	check(not out.contains("  关卡 L01_R01"), "通过时默认只显示简要报告")
	var detail := await run_line("auto report")
	said(detail, "关卡 L01_R01", "auto report 展开逐关明细")
	var report: Dictionary = commands.last_report
	check(str(report.goal).contains("CH03"), "最近报告对应刚才的目标")
	var brief := AutoPlay.report_lines(report, false)
	var full := AutoPlay.report_lines(report, true)
	check(full.size() > brief.size() and str(brief[0].kind) == "title" and str(brief[0].text).contains("通过"), "详细版比简要版多出明细行")
	check(AutoPlay.report_lines({}, true).is_empty(), "空报告没有输出行")
	check(FileAccess.file_exists(Commands.REPORT_PATH), "报告文件已写入")
	var file := FileAccess.open(Commands.REPORT_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(file.get_as_text()) if file != null else null
	if file != null: file.close()
	check(parsed is Dictionary and str(parsed.get("goal", "")) == str(report.goal) and int(parsed.get("serial", 0)) == int(report.serial), "报告文件是合法 JSON 且与最近一次一致")
	check(parsed is Dictionary and parsed.get("anomalies") is Array and parsed.get("coverage") is Dictionary and parsed.get("levels") is Dictionary, "报告文件含异常、覆盖、逐关记录")

# ---------- 实机演示 ----------

func _live_run() -> void:
	await run_line("jump 2")
	var chapter_before: String = data().chapter
	var holder := {}
	start_in_background(opts(["3", "-live", "-delay", "0"]), holder)
	check(commands.busy and commands.live_run, "实机演示开始")
	check(not app.session.save_writer.is_valid(), "实机演示期间自动存档被关闭")
	var saves_during := save_files()
	await wait_for(holder)
	var result: Dictionary = holder.get("result", {})
	var report := report_of(result)
	check(bool(result.get("ok", false)) and bool(report.get("reached", false)) and str(report.get("mode", "")) == "实机演示", "实机演示到达目标章节（原因：%s）" % str(report.get("reason", "")))
	check(not kinds(report).has("ui") and error_count(report) == 0, "演示过程中界面始终跟上会话模式、没有错误级异常：%s" % str(report.get("anomalies", [])).left(300))
	check(app.current_layer == "game" and app.session.mode == "investigation" and data().chapter == "CH03", "演示结束停在真实游戏的第三章调查画面")
	check(console.is_open and console.current_tab == "autoplay", "演示结束后控制台重新打开并停在自动推进页")
	console.close_console()
	await frames(2)
	check(app.gameplay_page.scene_page.is_visible_in_tree() and not paused, "关闭控制台后调查画面可见且游戏没有被冻结")
	check(save_files() == saves_during, "演示期间没有写任何存档文件")
	await frames(5)
	check(app.session.save_writer.is_valid(), "演示结束后自动存档写入已恢复")
	check(not commands.live_run and not commands.busy, "演示结束后状态复位")
	check(not commands.undo_snapshot.is_empty() and commands.undo_snapshot.case_state.chapter == chapter_before, "演示前的进度可以撤回")
	var out := await run_line("undo")
	said(out, "已回到", "undo 回到演示前的进度")
	check(data().chapter == chapter_before, "undo 后章节恢复为 " + chapter_before)
	# 演示中途取消。
	holder = {}
	start_in_background(opts(["end", "-live", "-delay", "0"]), holder)
	await frames(30)
	check(commands.live_run, "第二次演示进行中")
	commands.cancel()
	await wait_for(holder)
	var cancelled := report_of(holder.get("result", {}))
	check(bool(cancelled.get("cancelled", false)) and not bool(cancelled.get("ok", true)), "实机演示可中途取消")
	check(not commands.live_run and not commands.busy and app.session.save_writer.is_valid(), "取消后存档写入恢复、状态复位")
