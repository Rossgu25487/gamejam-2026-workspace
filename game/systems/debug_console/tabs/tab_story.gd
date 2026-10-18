extends "res://systems/debug_console/tabs/tab_base.gd"
## 剧情页：浏览并触发剧情入口、执行案件事件，查看条件为什么成立或不成立。
var sub_tabs: TabContainer
var entry_search: LineEdit
var ready_only: CheckBox
var chapter_only: CheckBox
var entries: Tree
var entry_info: Label
var travel_check: CheckBox
var fire_button: Button
var why_button: Button
var event_search: LineEdit
var happened_only: CheckBox
var events: Tree
var event_info: Label
var event_button: Button
var cond_edit: LineEdit

func build() -> void:
	var quick := hbox(self)
	run_button("读完当前对白（skip）", "skip", quick, "快速读完对白与原件，停在选项或调查画面")
	hint("入口和事件都按游戏自己的规则执行：条件不满足时会如实报错，不会强行改状态。", quick)
	sub_tabs = TabContainer.new()
	sub_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(sub_tabs)
	_build_entries()
	_build_events()
	_build_conditions()

func _build_entries() -> void:
	var page := VBoxContainer.new()
	page.name = "剧情入口"
	page.add_theme_constant_override("separation", 8)
	sub_tabs.add_child(page)
	var filters := hbox(page)
	entry_search = line_edit("按入口 ID 或名称过滤，如 L07、INV_SC02", filters)
	entry_search.text_changed.connect(func(_text): _fill_entries())
	ready_only = check_box("只看条件成立", filters)
	ready_only.toggled.connect(func(_on): _fill_entries())
	chapter_only = check_box("只看当前章节", filters)
	chapter_only.toggled.connect(func(_on): _fill_entries())
	entries = make_tree([{"title": "条件", "width": 54}, {"title": "入口 ID", "width": 250, "expand": true}, {"title": "章节", "width": 56}, {"title": "地点", "width": 70}, {"title": "名称", "width": 220, "expand": true}], page)
	entries.item_selected.connect(_update_entry_info)
	entries.item_activated.connect(_fire_entry)
	entry_info = hint("", page)
	var actions := hbox(page)
	fire_button = make_button("触发所选入口", _fire_entry, actions, "双击入口行同样触发")
	travel_check = check_box("先前往入口所在场景", actions)
	why_button = make_button("解释入口条件", _explain_entry, actions, "逐项显示条件卡在哪一项")

func _build_events() -> void:
	var page := VBoxContainer.new()
	page.name = "案件事件"
	page.add_theme_constant_override("separation", 8)
	sub_tabs.add_child(page)
	var filters := hbox(page)
	event_search = line_edit("按事件 ID 过滤，如 SHARED_MEAL", filters)
	event_search.text_changed.connect(func(_text): _fill_events())
	happened_only = check_box("只看已发生", filters)
	happened_only.toggled.connect(func(_on): _fill_events())
	events = make_tree([{"title": "已发生", "width": 66}, {"title": "事件 ID", "width": 420, "expand": true}, {"title": "动作数", "width": 66}], page)
	events.item_selected.connect(_update_event_info)
	events.item_activated.connect(_fire_event)
	event_info = hint("", page)
	var actions := hbox(page)
	event_button = make_button("执行所选事件", _fire_event, actions, "按游戏规则执行；条件不成立时会报错")

func _build_conditions() -> void:
	var page := VBoxContainer.new()
	page.name = "条件诊断"
	page.add_theme_constant_override("separation", 8)
	sub_tabs.add_child(page)
	hint("输入条件 ID（入口和事件页里都能看到），逐项显示每个分支为什么成立或不成立。", page)
	var row := hbox(page)
	cond_edit = line_edit("条件 ID，如 COND_CH03_L07_AVAILABLE", row)
	cond_edit.text_submitted.connect(func(_text): _explain_condition())
	make_button("解释", _explain_condition, row)
	hint("解释结果显示在下方日志里。", page)
	_fill_entries()
	_fill_events()

func _fill_entries() -> void:
	entries.clear()
	var root := entries.create_item()
	var needle := entry_search.text.strip_edges().to_lower()
	var data: Dictionary = session().case_state.data
	for id in config().entries:
		var row: Dictionary = config().entries[id]
		if not needle.is_empty() and ("%s %s" % [id, row.get("name", "")]).to_lower().find(needle) < 0: continue
		if chapter_only.button_pressed and str(row.get("chapter_id", "")) != str(data.chapter): continue
		var ready: bool = session().condition(str(row.get("condition_id", "")))
		if ready_only.button_pressed and not ready: continue
		var item := entries.create_item(root)
		item.set_metadata(0, str(id))
		item.set_text(1, str(id))
		item.set_text(2, str(row.get("chapter_id", "-")))
		var places := str(row.get("allowed_scene_ids", ""))
		item.set_text(3, places if not places.is_empty() else "不限")
		item.set_text(4, str(row.get("name", "")))
	_mark_entries()
	_update_entry_info()

func _mark_entries() -> void:
	var root := entries.get_root()
	if root == null: return
	for item in root.get_children():
		var row: Dictionary = config().entries[str(item.get_metadata(0))]
		var ready: bool = session().condition(str(row.get("condition_id", "")))
		item.set_text(0, "成立" if ready else "-")
		color_item(item, 5, DebugTheme.TEXT if ready else DebugTheme.DIM)

func _fill_events() -> void:
	events.clear()
	var root := events.create_item()
	var needle := event_search.text.strip_edges().to_lower()
	for id in config().events:
		if not needle.is_empty() and str(id).to_lower().find(needle) < 0: continue
		if happened_only.button_pressed and not bool(session().case_state.data.events.get(id, false)): continue
		var item := events.create_item(root)
		item.set_metadata(0, str(id))
		item.set_text(1, str(id))
		item.set_text(2, str(config().events[id].size()))
	_mark_events()
	_update_event_info()

func _mark_events() -> void:
	var root := events.get_root()
	if root == null: return
	for item in root.get_children():
		var done: bool = bool(session().case_state.data.events.get(str(item.get_metadata(0)), false))
		item.set_text(0, "已发生" if done else "-")
		color_item(item, 3, DebugTheme.OK if done else DebugTheme.DIM)

func refresh() -> void:
	if not built: return
	_mark_entries()
	_mark_events()
	_update_entry_info()
	_update_event_info()

func _selected_entry() -> String:
	var item := entries.get_selected()
	return str(item.get_metadata(0)) if item != null else ""

func _selected_event() -> String:
	var item := events.get_selected()
	return str(item.get_metadata(0)) if item != null else ""

func _update_entry_info() -> void:
	var id := _selected_entry()
	var active: bool = in_game() and str(session().mode) == "investigation"
	fire_button.disabled = id.is_empty() or not active
	why_button.disabled = id.is_empty()
	if id.is_empty():
		entry_info.text = "点选一个入口查看它的条件；双击直接触发。%s" % ("" if active else "  只能在可操作的调查画面触发入口。")
		return
	var row: Dictionary = config().entries[id]
	entry_info.text = "%s    条件 %s    类型 %s    地点模式 %s%s" % [id, row.get("condition_id", "") if not str(row.get("condition_id", "")).is_empty() else "无", row.get("entry_kind", "-"), row.get("location_mode", "-"), "" if active else "    （当前不在可操作的调查画面）"]

func _update_event_info() -> void:
	var id := _selected_event()
	event_button.disabled = id.is_empty() or not in_game()
	if id.is_empty():
		event_info.text = "点选一个事件；双击或点按钮执行。%s" % ("" if in_game() else "  尚未开始游戏。")
		return
	var gates: Array = []
	for row in config().events[id]:
		var gate := str(row.get("condition_id", ""))
		if not gate.is_empty() and gate not in gates: gates.append(gate)
	event_info.text = "%s    触发条件 %s" % [id, "、".join(gates) if not gates.is_empty() else "无"]

func _fire_entry(_arg = null) -> void:
	var id := _selected_entry()
	if id.is_empty(): return
	console.run("entry %s%s" % [id, " -s" if travel_check.button_pressed else ""])

func _explain_entry() -> void:
	var id := _selected_entry()
	if id.is_empty(): return
	var gate := str(config().entries[id].get("condition_id", ""))
	if gate.is_empty():
		console.say("入口 %s 没有开放条件。" % id, "info")
		return
	console.run("cond " + gate)

func _fire_event(_arg = null) -> void:
	var id := _selected_event()
	if not id.is_empty(): console.run("event " + id)

func _explain_condition() -> void:
	var id := cond_edit.text.strip_edges()
	if id.is_empty():
		console.say("请先输入条件 ID。", "warn")
		return
	console.run("cond " + id)
