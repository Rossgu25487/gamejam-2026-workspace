extends "res://systems/debug_console/tabs/tab_base.gd"
## 跳转页：快进到章节、关卡或片尾；无条件前往场景；移动人物；撤回。
const AutoPlay = preload("res://systems/debug_console/debug_auto_play.gd")
var levels: Tree
var jump_level_button: Button
var arrive_check: CheckBox
var actor_option: OptionButton
var scene_option: OptionButton
var chapter_buttons: Array[Button] = []
var scene_buttons := {}
var actor_ids: Array = []
var scene_ids: Array = []

func build() -> void:
	var content := scrolled()
	heading("快进到章节", content)
	hint("在隔离会话里沿真实玩家流程推进，事件和材料由游戏规则产生。当前进度会被替换，跳转前自动留存，可随时「撤回」。", content)
	var chapters := flow(content)
	for id in config().chapters:
		var button := run_button("%s  %s" % [id, config().chapters[id].name], "jump " + str(id), chapters)
		chapter_buttons.append(button)
	var ending := run_button("片尾演职员画面", "jump end", chapters)
	chapter_buttons.append(ending)
	run_button("撤回上一次跳转", "undo", chapters)
	content.add_child(HSeparator.new())
	heading("快进到关卡", content)
	hint("双击一行或点「跳到所选关卡」：到该关卡刚开放时，并直接进入选材界面。", content)
	levels = make_tree([{"title": "关卡", "width": 90}, {"title": "章节", "width": 60}, {"title": "类型", "width": 90}, {"title": "状态", "width": 80}, {"title": "机会", "width": 50}, {"title": "入口", "width": 200, "expand": true}], content)
	levels.custom_minimum_size.y = 230
	levels.size_flags_vertical = Control.SIZE_FILL
	levels.item_activated.connect(_jump_selected)
	levels.item_selected.connect(_update_buttons)
	var level_row := hbox(content)
	jump_level_button = make_button("跳到所选关卡", _jump_selected, level_row)
	make_button("补齐所选关卡的机会（999 次）", _restore_chances, level_row)
	content.add_child(HSeparator.new())
	heading("前往场景（无条件）", content)
	hint("需要在可操作的调查画面使用；不检查场景是否已开放。", content)
	var scenes := flow(content)
	for id in config().scenes:
		scene_ids.append(str(id))
		scene_buttons[str(id)] = make_button("%s %s" % [id, config().text(str(config().scenes[id].name_text_id))], _go_scene.bind(str(id)), scenes)
	arrive_check = check_box("同时触发到达短场", content)
	content.add_child(HSeparator.new())
	heading("移动人物", content)
	var mover := hbox(content)
	actor_option = option_button([], mover)
	for id in config().actors:
		actor_ids.append(str(id))
		actor_option.add_item("%s %s" % [id, config().actors[id].get("name", "")])
	caption("移到", mover)
	scene_option = option_button([], mover)
	for id in config().scenes: scene_option.add_item("%s %s" % [id, config().text(str(config().scenes[id].name_text_id))])
	make_button("移动", _move_actor, mover)
	run_button("列出人物位置", "npc", mover)
	_fill_levels()

func _fill_levels() -> void:
	levels.clear()
	var root := levels.create_item()
	for id in config().questions:
		var row: Dictionary = config().questions[id]
		var entry: Dictionary = config().entries.get(str(row.get("entry_ref", "")), {})
		var item := levels.create_item(root)
		item.set_metadata(0, str(id))
		item.set_text(0, str(id))
		item.set_text(1, str(entry.get("chapter_id", "-")))
		item.set_text(2, "说法质询" if row.get("interaction_kind") == "statement" else "自主推理")
		item.set_text(5, str(row.get("entry_ref", "")))

func refresh() -> void:
	if not built: return
	var active := in_game()
	var data: Dictionary = session().case_state.data
	for item in levels.get_root().get_children():
		var id := str(item.get_metadata(0))
		var done: bool = data.completed_questions.has(id)
		var open: bool = not done and AutoPlay.level_open(session(), id)
		item.set_text(3, "已完成" if done else ("可进入" if open else "未开放"))
		item.set_text(4, str(int(data.chances.get(id, 999))))
		color_item(item, 6, DebugTheme.OK if done else (DebugTheme.ACCENT_TEXT if open else DebugTheme.DIM))
	for id in scene_buttons:
		var status: Dictionary = session().scene_status(id)
		scene_buttons[id].disabled = not active
		scene_buttons[id].tooltip_text = "当前所在" if str(data.scene) == id and active else ("已开放" if status.available else "尚未开放（仍可无条件前往）")
	_update_buttons()

func _update_buttons() -> void:
	if jump_level_button != null: jump_level_button.disabled = levels.get_selected() == null

func _selected_level() -> String:
	var item := levels.get_selected()
	return str(item.get_metadata(0)) if item != null else ""

func _jump_selected() -> void:
	var id := _selected_level()
	if not id.is_empty(): console.run("jump " + id)

func _restore_chances() -> void:
	var id := _selected_level()
	if not id.is_empty(): console.run("chances %s 999" % id)

func _go_scene(id: String) -> void:
	console.run("scene %s%s" % [id, " arrive" if arrive_check.button_pressed else ""])

func _move_actor() -> void:
	if actor_option.selected < 0 or scene_option.selected < 0: return
	console.run("npc %s %s" % [actor_ids[actor_option.selected], scene_ids[scene_option.selected]])
