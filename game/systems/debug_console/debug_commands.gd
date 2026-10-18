extends RefCounted
## 调试控制台命令表：解析命令行并操作正式会话，不含任何界面，便于无头回归。
## 所有状态修改都经游戏自己的接口（grant / event / activate_entry / force_travel），
## 快进跳关走 debug_fast_forward.gd 的隔离会话，不直接篡改章节或事件。
signal output_requested(kind: String, text: String)
const FastForward = preload("res://systems/debug_console/debug_fast_forward.gd")
const SOURCE_ENTRY := "调试控制台"
const TYPE_LABELS := {"evidence": "证物", "testimony": "证言", "inference": "推论"}
const LIST_LIMIT := 60
const FLOW_MODES := ["investigation", "selection", "failure"]

var app: Control
var ui: Node
var registry := {}
var aliases := {}
var undo_snapshot := {}
var busy := false
var speed_changed := false
var _fast_forward: RefCounted
var session: Node:
	get:
		return app.session
var config: RefCounted:
	get:
		return app.session.config

func _init(host: Control, console: Node = null) -> void:
	app = host
	ui = console
	_register()

# ---------- 解析与分发 ----------

static func tokenize(line: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var current := ""
	var quoted := false
	var started := false
	for ch in line:
		if ch == "\"":
			quoted = not quoted
			started = true
		elif (ch == " " or ch == "\t" or ch == "\u3000") and not quoted:
			if started: tokens.append(current)
			current = ""
			started = false
		else:
			current += ch
			started = true
	if started: tokens.append(current)
	return tokens

func resolve_command(token: String) -> String:
	var name := token.to_lower()
	name = str(aliases.get(name, name))
	return name if registry.has(name) else ""

func execute(line: String) -> void:
	var tokens := tokenize(line)
	if tokens.is_empty(): return
	var name := resolve_command(tokens[0])
	if name.is_empty():
		_err("未知命令：%s。输入 help 查看全部命令。" % tokens[0])
		return
	if busy:
		_err("上一条命令仍在执行，按 Esc 可取消。")
		return
	tokens.remove_at(0)
	await registry[name].fn.call(tokens)

func cancel() -> void:
	if _fast_forward != null: _fast_forward.cancel()

func _out(text: String, kind: String = "info") -> void: output_requested.emit(kind, text)
func _ok(text: String) -> void: output_requested.emit("ok", text)
func _warn(text: String) -> void: output_requested.emit("warn", text)
func _err(text: String) -> void: output_requested.emit("error", text)

func _add(name: String, group: String, usage: String, brief: String, fn: Callable, extra: Array = [], detail: String = "") -> void:
	registry[name] = {"name": name, "group": group, "usage": usage, "brief": brief, "fn": fn, "detail": detail}
	for alias in extra: aliases[str(alias)] = name

func _register() -> void:
	_add("help", "通用", "help [命令]", "列出命令，或查看某条命令的用法", _cmd_help, ["?", "h"])
	_add("clear", "通用", "clear", "清空控制台输出", _cmd_clear, ["cls"])
	_add("copy", "通用", "copy", "把控制台输出复制到剪贴板，便于提交问题", _cmd_copy)
	_add("close", "通用", "close", "关闭控制台（也可再按一次 ~ 键或 Esc）", _cmd_close, ["exit"])
	_add("lock", "通用", "lock", "重新锁定控制台，需再次输入 super", _cmd_lock)
	_add("super", "通用", "super", "解锁控制台（已解锁时无操作）", _cmd_super)
	_add("status", "查看", "status", "查看章节、地点、模式、材料与事件进度", _cmd_status, ["st", "info"])
	_add("chapters", "查看", "chapters", "列出全部章节", _cmd_chapters)
	_add("levels", "查看", "levels", "列出全部推理关卡及当前状态", _cmd_levels)
	_add("scenes", "查看", "scenes", "列出全部场景及开放状态", _cmd_scenes)
	_add("items", "查看", "items [all|关键词]", "查看已持有材料；all 或关键词查看全部材料目录", _cmd_items, ["inv"])
	_add("entries", "查看", "entries [关键词]", "查看剧情入口及其条件是否满足", _cmd_entries)
	_add("events", "查看", "events [关键词]", "查看案件事件及其是否已发生", _cmd_events)
	_add("npc", "查看", "npc [人物ID 场景ID]", "查看人物位置；带参数时移动人物", _cmd_npc)
	_add("cond", "查看", "cond <条件ID>", "逐项解释某个案件条件为什么成立或不成立", _cmd_cond, ["why"])
	_add("jump", "跳转", "jump <章节|关卡|end>", "快进跳关：章节 1-6、关卡 ID（如 L07_R02）或片尾", _cmd_jump, ["chapter", "level"],
		"章节：jump 3 或 jump CH03，到该章第一个可操作调查点。\n关卡：jump L07_R02 或 jump L07，到该关卡刚开放时并尝试触发其入口。\n片尾：jump end，直接到演职员画面。\n快进在隔离会话中沿真实玩家流程推进，事件和材料由游戏规则产生。\n当前进度会被替换；jump 前自动留存，可用 undo 撤回。")
	_add("undo", "跳转", "undo", "撤回上一次 jump，回到跳转前的进度", _cmd_undo)
	_add("scene", "跳转", "scene <场景ID|名称> [arrive]", "无条件前往场景；加 arrive 则触发到达短场", _cmd_scene, ["goto"])
	_add("entry", "跳转", "entry <入口ID> [-s]", "触发剧情入口；-s 先移动到入口允许的场景", _cmd_entry)
	_add("event", "跳转", "event <事件ID>", "按游戏规则执行案件事件（受事件条件约束）", _cmd_event)
	_add("skip", "跳转", "skip", "快速读完当前对白与原件，停在选项或调查画面", _cmd_skip)
	_add("give", "物品", "give <物品ID|all|evidence|testimony|inference> [-a]", "获得材料；材料 ID 取最新版，具体版本用内容 ID（如 E02_V3），-a 取全部版本", _cmd_give, ["get"],
		"give E01        获得 E01 的最新版本。\ngive E02_V3     获得指定版本。\ngive E02 -a     获得 E02 的全部版本。\ngive evidence   获得全部证物（testimony 证言、inference 推论、all 全部）。\n可一次写多个：give E01 T01 P01。")
	_add("take", "物品", "take <物品ID|all>", "移除材料（材料 ID 移除全部版本，内容 ID 移除单个版本）", _cmd_take, ["drop"])
	_add("chances", "调试", "chances [关卡ID|all 次数]", "查看或设置关卡剩余机会（0-3）", _cmd_chances)
	_add("speed", "调试", "speed [倍率]", "设置游戏时间倍率 0.1-8，speed 1 恢复", _cmd_speed)
	_add("hud", "调试", "hud [on|off]", "显示或隐藏屏幕角落的状态信息与帧率", _cmd_hud)

# ---------- 查找辅助 ----------

func _find_id(table: Dictionary, token: String) -> String:
	if table.has(token): return token
	var upper := token.to_upper()
	if table.has(upper): return upper
	for key in table:
		if str(key).to_upper() == upper: return str(key)
	return ""

func _flags(args: PackedStringArray) -> Dictionary:
	var values: Array = []
	var flags := {}
	for token in args:
		if token.length() > 1 and token.begins_with("-") and not token.is_valid_float(): flags[token.substr(1).to_lower()] = true
		else: values.append(token)
	return {"args": values, "flags": flags}

func _scene_label(id: String) -> String:
	return "%s %s" % [id, config.text(str(config.scenes.get(id, {}).get("name_text_id", "")))] if config.scenes.has(id) else id

func _find_scene(token: String) -> String:
	var found := _find_id(config.scenes, token)
	if not found.is_empty(): return found
	for id in config.scenes:
		if config.text(str(config.scenes[id].name_text_id)) == token: return str(id)
	return ""

func _versions_of(material_id: String) -> Array:
	var found: Array = []
	for id in config.contents:
		if config.contents[id].material_id == material_id: found.append(str(id))
	found.sort_custom(func(a, b): return int(config.contents[a].version) < int(config.contents[b].version))
	return found

func _owned_versions(material_id: String) -> Array:
	return _versions_of(material_id).filter(func(id): return session.case_state.owns(id))

func _material_name(material_id: String) -> String:
	var versions := _versions_of(material_id)
	return str(config.contents[versions.back()].name) if not versions.is_empty() else material_id

func _type_label(material_id: String) -> String:
	return str(TYPE_LABELS.get(str(config.materials[material_id].type), config.materials[material_id].type))

func _content_label(id: String) -> String:
	return "%s %s 第%d版" % [id, config.contents[id].name, int(config.contents[id].version)]

func _group_of_type(token: String) -> String:
	var lower := token.to_lower()
	for key in TYPE_LABELS:
		if lower == key or token == TYPE_LABELS[key]: return str(key)
	return ""

## 把一个物品参数展开成内容 ID 列表；owned_only 用于 take，只展开已持有的版本。
func _expand_items(token: String, every_version: bool, owned_only: bool) -> Array:
	var result: Array = []
	var upper := token.to_upper()
	var type_key := _group_of_type(token)
	if upper == "ALL" or not type_key.is_empty():
		for material in config.materials:
			if not type_key.is_empty() and str(config.materials[material].type) != type_key: continue
			result.append_array(_pick_versions(str(material), every_version or owned_only, owned_only))
		return result
	var content := _find_id(config.contents, token)
	if not content.is_empty():
		if not owned_only or session.case_state.owns(content): result.append(content)
		return result
	var material := _find_id(config.materials, token)
	if not material.is_empty(): result.append_array(_pick_versions(material, every_version or owned_only, owned_only))
	return result

func _pick_versions(material_id: String, every_version: bool, owned_only: bool) -> Array:
	var versions: Array = _owned_versions(material_id) if owned_only else _versions_of(material_id)
	if versions.is_empty() or every_version: return versions
	return [versions.back()]

func _require_flow(action: String) -> bool:
	if app.current_layer == "title" or session.run_id.is_empty():
		_err("%s：尚未开始游戏。可先用 jump 1 进入调查，或从标题开始新游戏。" % action)
		return false
	return true

func _refresh_pages() -> void:
	session.changed.emit()
	if app.gameplay_page != null: app.gameplay_page.refresh()

# ---------- 通用命令 ----------

func _cmd_help(args: PackedStringArray) -> void:
	if not args.is_empty():
		var name := resolve_command(args[0])
		if name.is_empty():
			_err("没有这条命令：" + args[0])
			return
		var entry: Dictionary = registry[name]
		_out("%s  —  %s" % [entry.usage, entry.brief], "title")
		for line in str(entry.detail).split("\n", false): _out("  " + line)
		return
	var group := ""
	for name in registry:
		var entry: Dictionary = registry[name]
		if entry.group != group:
			group = str(entry.group)
			_out("[%s]" % group, "title")
		_out("  %-9s %s" % [name, entry.brief])
	_out("Tab 补全命令与 ID，上下键翻历史，Esc 或 ~ 关闭。help <命令> 查看详细用法。", "dim")

func _cmd_clear(_args: PackedStringArray) -> void:
	if ui != null: ui.clear_log()

func _cmd_copy(_args: PackedStringArray) -> void:
	if ui == null: return
	ui.copy_log()
	_ok("控制台输出已复制到剪贴板。")

func _cmd_close(_args: PackedStringArray) -> void:
	if ui != null: ui.call_deferred("close_console")

func _cmd_lock(_args: PackedStringArray) -> void:
	if ui != null: ui.lock()
	_out("控制台已锁定。")

func _cmd_super(_args: PackedStringArray) -> void:
	_out("控制台已处于解锁状态。")

# ---------- 查看 ----------

func _cmd_status(_args: PackedStringArray) -> void:
	var data: Dictionary = session.case_state.data
	var chapter: Dictionary = config.chapters.get(data.chapter, {})
	_out("章节  %s %s" % [data.chapter, chapter.get("name", "")])
	_out("地点  %s   视图 %s" % [_scene_label(str(data.scene)), data.view])
	_out("状态  界面层=%s  会话模式=%s  可保存=%s" % [app.current_layer, session.mode, session.can_save()])
	_out("当前  入口=%s  关卡=%s" % [session.active_entry if not session.active_entry.is_empty() else "-", session.question if not session.question.is_empty() else "-"])
	var versions := 0
	for id in data.materials: versions += data.materials[id].versions.size()
	_out("进度  材料 %d/%d（版本 %d/%d）  事件 %d/%d  已听原话 %d  已完成关卡 %d/%d" % [data.materials.size(), config.materials.size(), versions, config.contents.size(), data.events.size(), config.events.size(), data.texts.size(), data.completed_questions.size(), config.questions.size()])
	var seconds := int(session.elapsed_seconds)
	_out("时长  %02d:%02d:%02d   存档版本 %s   run=%s" % [floori(seconds / 3600.0), floori(seconds / 60.0) % 60, seconds % 60, config.content_revision, session.run_id if not session.run_id.is_empty() else "-"])
	if not session.last_notice.is_empty(): _out("提示  " + session.last_notice, "dim")

func _cmd_chapters(_args: PackedStringArray) -> void:
	for id in config.chapters:
		_out("%s %s %s" % ["*" if str(session.case_state.data.chapter) == str(id) else " ", id, config.chapters[id].name])
	_out("jump <序号|CHxx> 跳到该章。* 为当前章节。", "dim")

func _level_status(id: String) -> String:
	if session.case_state.data.completed_questions.has(id): return "已完成"
	return "可进入" if FastForward.level_open(session, id) else "未开放"

func _cmd_levels(_args: PackedStringArray) -> void:
	for id in config.questions:
		var row: Dictionary = config.questions[id]
		var entry: Dictionary = config.entries.get(str(row.get("entry_ref", "")), {})
		var kind := "说法质询" if row.get("interaction_kind") == "statement" else "自主推理"
		_out("  %-8s %s  %s  %s  机会 %d" % [id, entry.get("chapter_id", "-"), kind, _level_status(str(id)), int(session.case_state.data.chances.get(id, 3))])
	_out("jump <关卡ID> 跳到关卡刚开放时；也可写关卡组如 L07。", "dim")

func _cmd_scenes(_args: PackedStringArray) -> void:
	for id in config.scenes:
		var status: Dictionary = session.scene_status(str(id))
		var mark := "当前" if str(session.case_state.data.scene) == str(id) else ("开放" if status.available else ("已知未开放" if status.known else "未知"))
		_out("  %-5s %-8s %s" % [id, config.text(str(config.scenes[id].name_text_id)), mark])

func _cmd_items(args: PackedStringArray) -> void:
	var keyword := " ".join(args).strip_edges()
	var catalogue := not keyword.is_empty()
	var needle := "" if keyword.to_lower() == "all" else keyword
	var shown := 0
	var owned_total := 0
	for material in config.materials:
		var owned := _owned_versions(str(material))
		if not owned.is_empty(): owned_total += 1
		if not catalogue and owned.is_empty(): continue
		if not needle.is_empty():
			var haystack := "%s %s %s %s" % [material, _material_name(str(material)), _type_label(str(material)), config.materials[material].type]
			if haystack.to_lower().find(needle.to_lower()) < 0: continue
		shown += 1
		if shown > LIST_LIMIT: continue
		var versions := ",".join(owned.map(func(id): return "V%d" % int(config.contents[id].version))) if not owned.is_empty() else "-"
		_out("  [%s] %-4s %s  %s  持有版本 %s / 共%d版" % ["x" if not owned.is_empty() else " ", material, _type_label(str(material)), _material_name(str(material)), versions, _versions_of(str(material)).size()])
	if shown > LIST_LIMIT: _out("  ……还有 %d 项未显示，请加关键词过滤。" % (shown - LIST_LIMIT), "dim")
	_out("已持有材料 %d/%d。" % [owned_total, config.materials.size()], "dim")

func _gate_mark(entry: Dictionary) -> String:
	return "x" if session.condition(str(entry.get("condition_id", ""))) else " "

func _cmd_entries(args: PackedStringArray) -> void:
	var keyword := " ".join(args).strip_edges().to_lower()
	var shown := 0
	for id in config.entries:
		var entry: Dictionary = config.entries[id]
		if not keyword.is_empty() and ("%s %s" % [id, entry.get("name", "")]).to_lower().find(keyword) < 0: continue
		shown += 1
		if shown > LIST_LIMIT: continue
		_out("  [%s] %s  %s  地点 %s" % [_gate_mark(entry), id, entry.get("chapter_id", "-"), str(entry.get("allowed_scene_ids", "")) if not str(entry.get("allowed_scene_ids", "")).is_empty() else "不限"])
	if shown > LIST_LIMIT: _out("  ……还有 %d 项未显示，请加关键词过滤。" % (shown - LIST_LIMIT), "dim")
	_out("[x] 表示入口条件当前成立；共 %d 个入口。" % config.entries.size(), "dim")

func _cmd_events(args: PackedStringArray) -> void:
	var keyword := " ".join(args).strip_edges().to_lower()
	var shown := 0
	for id in config.events:
		if not keyword.is_empty() and str(id).to_lower().find(keyword) < 0: continue
		shown += 1
		if shown > LIST_LIMIT: continue
		_out("  [%s] %s" % ["x" if session.case_state.data.events.get(id, false) else " ", id])
	if shown > LIST_LIMIT: _out("  ……还有 %d 项未显示，请加关键词过滤。" % (shown - LIST_LIMIT), "dim")
	_out("[x] 表示已发生；已发生 %d/%d。" % [session.case_state.data.events.size(), config.events.size()], "dim")

func _cmd_npc(args: PackedStringArray) -> void:
	if args.is_empty():
		for id in config.actors:
			var place := str(session.case_state.data.npc.get(id, {}).get("scene_id", ""))
			_out("  %-6s %-6s %s" % [id, config.actors[id].get("name", ""), _scene_label(place) if not place.is_empty() else "不在场景中"])
		return
	if args.size() != 2:
		_err("用法：npc <人物ID> <场景ID>")
		return
	var actor := _find_id(config.actors, args[0])
	var scene := _find_scene(args[1])
	if actor.is_empty() or scene.is_empty():
		_err("未知的人物或场景：%s %s（用 npc / scenes 查看）" % [args[0], args[1]])
		return
	session.case_state.data.npc[actor] = {"scene_id": scene}
	_refresh_pages()
	_ok("%s 已移动到 %s。" % [config.actors[actor].get("name", actor), _scene_label(scene)])

func _term_actual(term: Dictionary) -> bool:
	var data: Dictionary = session.case_state.data
	var ref := str(term.get("ref", ""))
	match str(term.kind):
		"event": return bool(data.events.get(ref, false))
		"text": return bool(data.texts.get(ref, false))
		"entry":
			var entry: Dictionary = config.entries.get(ref, {})
			var scenes: Array = config.ids(str(entry.get("allowed_scene_ids", "")))
			var actual: bool = not entry.is_empty() and session.condition(str(entry.get("condition_id", "")))
			if entry.get("location_mode") == "caller" and not scenes.is_empty(): actual = actual and str(data.scene) in scenes
			return actual
		"chapter": return str(data.chapter) == ref
		"current_scene": return str(data.scene) == ref
		"npc_scene": return str(data.npc.get(ref, {}).get("scene_id", "")) == str(term.get("scene_id", ""))
	return false

func _cmd_cond(args: PackedStringArray) -> void:
	if args.is_empty():
		_err("用法：cond <条件ID>")
		return
	var id := _find_id(config.conditions, args[0])
	if id.is_empty():
		_err("没有这个条件：" + args[0])
		return
	_out("%s = %s" % [id, "成立" if session.condition(id) else "不成立"], "ok" if session.condition(id) else "warn")
	for branch in config.conditions[id]:
		var terms: Array = config.conditions[id][branch]
		var all_met := terms.all(func(term): return _term_actual(term) == bool(term.get("expected", true)))
		_out("  分支 %s（分支内全部满足才成立）：%s" % [branch, "满足" if all_met else "未满足"])
		for term in terms:
			var expected := bool(term.get("expected", true))
			var actual := _term_actual(term)
			var detail := str(term.get("ref", ""))
			if str(term.kind) == "npc_scene": detail += " 在 " + str(term.get("scene_id", ""))
			_out("    %s %s %s：期望 %s，实际 %s" % ["通过" if actual == expected else "卡住", term.kind, detail, expected, actual], "dim" if actual == expected else "warn")

# ---------- 跳转 ----------

func _parse_goal(token: String) -> Dictionary:
	var upper := token.strip_edges().to_upper()
	if upper in ["END", "ENDING", "CREDITS", "片尾", "结局"]: return {"kind": "ending", "label": "片尾演职员画面"}
	var chapter := ""
	if upper.is_valid_int(): chapter = "CH%02d" % int(upper)
	elif config.chapters.has(upper): chapter = upper
	if not chapter.is_empty() and config.chapters.has(chapter):
		return {"kind": "chapter", "chapter": chapter, "label": "%s %s" % [chapter, config.chapters[chapter].name]}
	var question := _find_id(config.questions, token)
	if question.is_empty():
		for id in config.questions:
			if str(config.questions[id].get("group_ref", "")).to_upper() == upper:
				question = str(id)
				break
	if not question.is_empty(): return {"kind": "level", "question": question, "label": "关卡 " + question}
	return {}

func _remember_undo() -> void:
	undo_snapshot = {}
	if app.current_layer == "title" or session.run_id.is_empty(): return
	var snapshot: Dictionary = session.export_snapshot()
	if session.validate_snapshot(snapshot): undo_snapshot = snapshot

func _cmd_jump(args: PackedStringArray) -> void:
	if args.is_empty():
		_err("用法：jump <章节序号|CHxx|关卡ID|end>。用 chapters / levels 查看可选目标。")
		return
	var goal := _parse_goal(args[0])
	if goal.is_empty():
		_err("无法识别的跳转目标：%s。可用 chapters / levels 查看。" % args[0])
		return
	_remember_undo()
	busy = true
	_warn("快进到 %s：在隔离会话中沿真实流程推进，当前进度将被替换（undo 可撤回）。Esc 取消。" % goal.label)
	_fast_forward = FastForward.new()
	_fast_forward.host = ui if ui != null else app
	_fast_forward.shared_config = config
	_fast_forward.progress = func(text): output_requested.emit("progress", text)
	var result: Dictionary = await _fast_forward.run(goal)
	_fast_forward = null
	busy = false
	output_requested.emit("progress", "")
	if not is_instance_valid(app): return
	if not result.ok:
		undo_snapshot = {}
		_err("快进失败：" + str(result.message))
		return
	if not app.debug_load_snapshot(result.snapshot):
		_err("快进得到的存档无法载入当前游戏，进度保持不变。")
		return
	_ok("已到达 %s：%s，%s，共执行 %d 步。" % [goal.label, result.chapter, _scene_label(str(result.scene)), result.actions])
	if goal.kind == "chapter" and str(result.chapter) != str(goal.chapter):
		_warn("%s 没有可操作的调查阶段，剧情直接衔接下一章，已停在 %s 的第一个可操作点。" % [goal.chapter, result.chapter])
	if goal.kind == "level": _open_level(str(goal.question))

func _open_level(question_id: String) -> void:
	if session.mode == "selection" and str(session.question) == question_id:
		_ok("已直接进入关卡选材界面。")
		return
	if session.mode != "investigation":
		_warn("已到达关卡开放点，但当前处于 %s 模式，请手动触发入口。" % session.mode)
		return
	var row: Dictionary = config.questions[question_id]
	var entry_id := str(row.get("entry_ref", ""))
	var entry: Dictionary = config.entries.get(entry_id, {})
	var allowed: Array = config.ids(str(entry.get("allowed_scene_ids", "")))
	if entry.get("location_mode", "caller") == "caller" and not allowed.is_empty() and str(session.case_state.data.scene) not in allowed:
		session.force_travel(str(allowed[0]))
	session.last_notice = ""
	var context := {"kind": "scene", "scene": session.case_state.data.scene, "view": session.case_state.data.view}
	if session.activate_entry(entry_id, context):
		_ok("已触发关卡入口 %s。" % entry_id)
		# 个别关卡（如 L07_R02）的入口先播一段剧情，结尾才是进入本关的选项；读完并选中，让跳关统一落在选材界面。
		if session.mode == "narrative":
			var steps := _read_through(question_id)
			if session.mode == "selection" and str(session.question) == question_id: _ok("入口剧情读完 %d 段，已进入关卡选材界面。" % steps)
			else: _warn("入口剧情停在选项处，请自行选择（skip 可读完选项以外的段落）。")
	else: _warn("关卡已开放，但入口 %s 没有自动触发%s；可前往 %s 后重试 entry。" % [entry_id, "（" + session.last_notice + "）" if not session.last_notice.is_empty() else "", ", ".join(allowed) if not allowed.is_empty() else "对应场景"])
	_refresh_pages()

func _cmd_undo(_args: PackedStringArray) -> void:
	if undo_snapshot.is_empty():
		_err("没有可撤回的跳转。")
		return
	if not app.debug_load_snapshot(undo_snapshot):
		_err("留存的进度无法载入。")
		return
	undo_snapshot = {}
	_ok("已回到跳转前的进度。")

func _cmd_scene(args: PackedStringArray) -> void:
	if args.is_empty():
		_cmd_scenes(args)
		return
	if not _require_flow("scene"): return
	var id := _find_scene(args[0])
	if id.is_empty():
		_err("没有这个场景：%s（用 scenes 查看）" % args[0])
		return
	if session.mode != "investigation":
		_err("scene 只能在可操作的调查画面使用，当前为 %s。可先用 skip 读完对白。" % session.mode)
		return
	if not session.force_travel(id):
		_err("无法前往 %s：%s" % [id, session.last_notice])
		return
	_ok("已前往 " + _scene_label(id))
	if args.size() > 1 and args[1].to_lower() == "arrive":
		if session.arrive(): _out("触发了到达短场。")
	_refresh_pages()

func _cmd_entry(args: PackedStringArray) -> void:
	var parsed := _flags(args)
	if parsed.args.is_empty():
		_err("用法：entry <入口ID> [-s]。用 entries 查看，[x] 为条件成立。")
		return
	if not _require_flow("entry"): return
	var id := _find_id(config.entries, str(parsed.args[0]))
	if id.is_empty():
		_err("没有这个入口：%s" % parsed.args[0])
		return
	if session.mode != "investigation":
		_err("entry 只能在可操作的调查画面使用，当前为 %s。" % session.mode)
		return
	var entry: Dictionary = config.entries[id]
	var allowed: Array = config.ids(str(entry.get("allowed_scene_ids", "")))
	var located: bool = entry.get("location_mode") == "fixed" or allowed.is_empty() or str(session.case_state.data.scene) in allowed
	if not located and parsed.flags.has("s"): located = session.force_travel(str(allowed[0]))
	if not located:
		_err("入口 %s 只能在 %s 触发，当前在 %s。加 -s 可自动前往。" % [id, ", ".join(allowed), session.case_state.data.scene])
		return
	if not session.condition(str(entry.get("condition_id", ""))):
		_err("入口 %s 的条件 %s 当前不成立。用 cond %s 查看卡在哪一项。" % [id, entry.get("condition_id", ""), entry.get("condition_id", "")])
		return
	session.last_notice = ""
	var context := {"kind": "scene", "scene": session.case_state.data.scene, "view": session.case_state.data.view}
	if session.activate_entry(id, context): _ok("已触发入口 " + id)
	else: _err("入口 %s 没有执行成功%s。" % [id, "：" + session.last_notice if not session.last_notice.is_empty() else "（可能没有可展示的内容）"])
	_refresh_pages()

func _cmd_event(args: PackedStringArray) -> void:
	if args.is_empty():
		_err("用法：event <事件ID>。用 events 查看。")
		return
	if not _require_flow("event"): return
	var id := _find_id(config.events, args[0])
	if id.is_empty():
		_err("没有这个事件：" + args[0])
		return
	var before := bool(session.case_state.data.events.get(id, false))
	var gate_ok: bool = config.events[id].all(func(row): return session.condition(str(row.get("condition_id", ""))))
	if not gate_ok and not before:
		_err("事件 %s 的触发条件不成立；用 cond 查看其条件。" % id)
		for row in config.events[id]:
			if not str(row.get("condition_id", "")).is_empty() and not session.condition(str(row.condition_id)): _out("  卡在条件 " + str(row.condition_id), "dim")
		return
	var applied: bool = session.case_state.event(id, {"entry": SOURCE_ENTRY})
	_refresh_pages()
	if applied: _ok("事件 %s 已执行%s。" % [id, "（此前已发生过）" if before else ""])
	else: _err("事件 %s 执行失败，已回滚：%s" % [id, session.last_notice if not session.last_notice.is_empty() else "其中的动作未通过校验"])

func _cmd_skip(_args: PackedStringArray) -> void:
	if app.current_layer != "game":
		_err("skip 只能在游戏中使用。")
		return
	var steps := _read_through()
	var stopped := ""
	if session.mode == "narrative" and session.narrative.state.waiting_for_choice: stopped = "停在选项处，请自行选择。"
	else: stopped = {"investigation": "已回到调查画面。", "credits": "已到片尾画面。", "selection": "停在选材界面。", "result": "停在结果界面。", "failure": "停在失败界面。"}.get(str(session.mode), "当前模式 %s。" % session.mode)
	_refresh_pages()
	_ok("读完 %d 段。%s" % [steps, stopped])

## 读完剧情和原件，遇到选项停下。给了 enter_question 时，若选项里恰有进入该关的一项则自动选中并继续。
func _read_through(enter_question: String = "") -> int:
	var steps := 0
	for step in range(3000):
		if session.mode == "narrative":
			session.narrative.tick(100)
			if session.narrative.state.waiting_for_choice:
				var index := _question_choice_index(enter_question)
				if index < 0 or not session.narrative.choose_transition(index): break
			else: session.narrative.advance()
		elif session.mode == "material":
			if not session.material_read_complete(): break
		else: break
		steps += 1
	return steps

func _question_choice_index(question_id: String) -> int:
	if question_id.is_empty(): return -1
	var choices: Array = session.narrative.available_choices
	for index in range(choices.size()):
		if str(choices[index].get("target_kind", "")) == "question" and str(choices[index].get("target_ref", "")) == question_id: return index
	return -1

# ---------- 物品 ----------

func _cmd_give(args: PackedStringArray) -> void:
	var parsed := _flags(args)
	if parsed.args.is_empty():
		_err("用法：give <物品ID|all|evidence|testimony|inference> [-a]。用 items all 查看目录。")
		return
	if not _require_flow("give"): return
	var every_version: bool = parsed.flags.has("a")
	var wanted: Array = []
	for token in parsed.args:
		var expanded := _expand_items(str(token), every_version, false)
		if expanded.is_empty(): _err("未知物品：%s（用 items all 查看目录）" % token)
		for id in expanded:
			if id not in wanted: wanted.append(id)
	var granted := 0
	var owned := 0
	for id in wanted:
		if session.case_state.owns(id):
			owned += 1
		elif session.case_state.grant(id, {"entry": SOURCE_ENTRY}):
			granted += 1
			if wanted.size() <= 8: _ok("获得 " + _content_label(id))
	if granted > 0: _refresh_pages()
	if wanted.size() > 8 or granted == 0: _ok("新获得 %d 项，已持有 %d 项。" % [granted, owned])

func _cmd_take(args: PackedStringArray) -> void:
	var parsed := _flags(args)
	if parsed.args.is_empty():
		_err("用法：take <物品ID|all>。")
		return
	if not _require_flow("take"): return
	if str(session.mode) not in FLOW_MODES:
		_err("take 只能在调查、选材或失败界面使用，当前为 %s。" % session.mode)
		return
	var wanted: Array = []
	for token in parsed.args:
		var expanded := _expand_items(str(token), false, true)
		if expanded.is_empty():
			if str(token).to_upper() == "ALL": _err("当前没有持有任何物品。")
			elif not _group_of_type(str(token)).is_empty(): _err("当前没有持有任何「%s」类物品。" % token)
			else: _err("没有持有 %s。" % token)
		for id in expanded:
			if id not in wanted: wanted.append(id)
	if wanted.is_empty(): return
	if app.gameplay_page.handbook_overlay: app.gameplay_page.reader_page.close_page()
	for id in wanted: _remove_content(str(id))
	_refresh_pages()
	_ok("已移除 %d 项。" % wanted.size())

func _remove_content(content_id: String) -> void:
	var data: Dictionary = session.case_state.data
	var material := str(config.contents[content_id].material_id)
	var record: Dictionary = data.materials.get(material, {})
	if record.is_empty() or not record.versions.has(content_id): return
	record.versions.erase(content_id)
	record.read.erase(content_id)
	if record.versions.is_empty():
		data.materials.erase(material)
	else:
		var best := ""
		for id in record.versions:
			if best.is_empty() or int(config.contents[id].version) > int(config.contents[best].version): best = str(id)
		record.current = best
	# 已选入槽位和草稿里引用该版本的位置一并清空，否则存档校验会拒绝。
	for index in range(session.slots.size()):
		if str(session.slots[index]) == content_id: session.slots[index] = ""
	for question in data.drafts:
		var slots: Array = data.drafts[question].get("slots", [])
		for index in range(slots.size()):
			if str(slots[index]) == content_id: slots[index] = ""

# ---------- 调试 ----------

func _cmd_chances(args: PackedStringArray) -> void:
	if args.is_empty():
		for id in config.questions:
			_out("  %-8s 机会 %d%s" % [id, int(session.case_state.data.chances.get(id, 3)), "  已完成" if session.case_state.data.completed_questions.has(id) else ""])
		return
	if args.size() != 2 or not args[1].is_valid_int():
		_err("用法：chances <关卡ID|all> <0-3>")
		return
	var value := clampi(int(args[1]), 0, 3)
	if args[0].to_upper() == "ALL":
		for id in config.questions: session.case_state.data.chances[id] = value
		_ok("全部关卡机会设为 %d。" % value)
	else:
		var id := _find_id(config.questions, args[0])
		if id.is_empty():
			_err("没有这个关卡：" + args[0])
			return
		session.case_state.data.chances[id] = value
		_ok("关卡 %s 机会设为 %d。" % [id, value])
	_refresh_pages()

func _cmd_speed(args: PackedStringArray) -> void:
	if args.is_empty():
		_out("当前游戏速度 %.2f 倍。" % Engine.time_scale)
		return
	if not args[0].is_valid_float():
		_err("用法：speed <0.1-8>，speed 1 恢复。")
		return
	Engine.time_scale = clampf(float(args[0]), 0.1, 8.0)
	speed_changed = not is_equal_approx(Engine.time_scale, 1.0)
	_ok("游戏速度已设为 %.2f 倍。" % Engine.time_scale)

func _cmd_hud(args: PackedStringArray) -> void:
	if ui == null: return
	var enable: bool = not ui.hud_enabled if args.is_empty() else args[0].to_lower() in ["on", "1", "true", "开"]
	ui.set_hud(enable)
	_ok("状态信息已%s。" % ("显示" if enable else "隐藏"))

# ---------- Tab 补全 ----------

func completions(line: String) -> Array:
	var tokens := tokenize(line)
	var trailing := line.ends_with(" ") or line.ends_with("\u3000")
	if tokens.is_empty() or (tokens.size() == 1 and not trailing):
		return _prefixed(_command_names(), tokens[0] if not tokens.is_empty() else "")
	var name := resolve_command(tokens[0])
	if name.is_empty(): return []
	var index := tokens.size() - 1 if not trailing else tokens.size()
	var partial := "" if trailing else tokens[tokens.size() - 1]
	return _prefixed(_arg_candidates(name, index), partial)

func _command_names() -> Array:
	var names: Array = registry.keys()
	names.append_array(aliases.keys())
	return names

func _prefixed(pool: Array, partial: String) -> Array:
	var found: Array = []
	var lower := partial.to_lower()
	for item in pool:
		if str(item).to_lower().begins_with(lower) and str(item) not in found: found.append(str(item))
	found.sort()
	return found

func _arg_candidates(name: String, index: int) -> Array:
	var pool: Array = []
	match name:
		"give":
			pool = ["all", "evidence", "testimony", "inference", "-a"]
			pool.append_array(config.materials.keys())
			pool.append_array(config.contents.keys())
		"take": pool = ["all"] + session.case_state.data.materials.keys()
		"scene": pool = config.scenes.keys() if index == 1 else ["arrive"]
		"jump": pool = ["end"] + config.chapters.keys() + config.questions.keys()
		"entry": pool = config.entries.keys() + ["-s"]
		"event": pool = config.events.keys()
		"cond": pool = config.conditions.keys()
		"npc": pool = config.actors.keys() if index == 1 else config.scenes.keys()
		"chances": pool = ["all"] + config.questions.keys() if index == 1 else []
		"items": pool = ["all"]
		"hud": pool = ["on", "off"]
		"speed": pool = ["0.5", "1", "2", "4"]
		"help": pool = _command_names()
	return pool
