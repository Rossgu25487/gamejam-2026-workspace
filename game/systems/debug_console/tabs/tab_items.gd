extends "res://systems/debug_console/tabs/tab_base.gd"
## 物品页：按类型和关键词浏览全部材料及其版本，勾选后一键获得或移除。
const TYPE_LABELS := {"evidence": "证物", "testimony": "证言", "inference": "推论"}
const TYPE_KEYS := ["", "evidence", "testimony", "inference"]
var search: LineEdit
var type_option: OptionButton
var owned_check: CheckBox
var tree: Tree
var status_label: Label
var action_buttons: Array[Button] = []
var _expanded := {}

func build() -> void:
	var top := hbox(self)
	search = line_edit("搜索材料 ID 或名称，如 E01、手帕", top)
	search.text_changed.connect(func(_text): _rebuild())
	type_option = option_button(["全部类型", "证物", "证言", "推论"], top)
	type_option.item_selected.connect(func(_index): _rebuild())
	owned_check = check_box("只看已持有", top)
	owned_check.toggled.connect(func(_on): _rebuild())
	tree = make_tree([{"title": "选", "width": 38}, {"title": "持有", "width": 70}, {"title": "ID", "width": 90}, {"title": "类型", "width": 60}, {"title": "名称", "width": 240, "expand": true}, {"title": "版本说明", "width": 200}], self)
	tree.item_edited.connect(_update_status)
	tree.item_selected.connect(_update_status)
	tree.item_collapsed.connect(_remember_collapse)
	status_label = hint("", self)
	var buttons := flow(self)
	action_buttons.append(make_button("获得所选（最新版）", _give.bind(false), buttons, "勾选的材料取最新版本；点选版本行则取该版本"))
	action_buttons.append(make_button("获得所选（全部版本）", _give.bind(true), buttons))
	action_buttons.append(make_button("移除所选", _take, buttons))
	make_button("全选当前列表", _check_all.bind(true), buttons)
	make_button("取消勾选", _check_all.bind(false), buttons)
	var quick := flow(self)
	caption("一键：", quick)
	action_buttons.append(run_button("获得全部证物", "give evidence", quick))
	action_buttons.append(run_button("获得全部证言", "give testimony", quick))
	action_buttons.append(run_button("获得全部推论", "give inference", quick))
	action_buttons.append(run_button("获得全部材料", "give all", quick))
	action_buttons.append(run_button("清空全部材料", "take all", quick))
	_rebuild()

## 重建列表时沿用各材料的展开状态。
func _remember_collapse(item: TreeItem) -> void:
	var meta = item.get_metadata(0)
	if meta is Dictionary and str(meta.get("kind", "")) == "material": _expanded[str(meta.id)] = not item.collapsed

func _versions_of(material_id: String) -> Array:
	var found: Array = []
	for id in config().contents:
		if config().contents[id].material_id == material_id: found.append(str(id))
	found.sort_custom(func(a, b): return int(config().contents[a].version) < int(config().contents[b].version))
	return found

func _rebuild() -> void:
	tree.clear()
	var root := tree.create_item()
	var needle := search.text.strip_edges().to_lower()
	var type_key: String = TYPE_KEYS[type_option.selected]
	var state: RefCounted = session().case_state
	for material in config().materials:
		var material_id := str(material)
		var kind := str(config().materials[material].type)
		if not type_key.is_empty() and kind != type_key: continue
		var versions := _versions_of(material_id)
		if versions.is_empty(): continue
		var title := str(config().contents[versions.back()].name)
		var owned := versions.filter(func(id): return state.owns(id))
		if owned_check.button_pressed and owned.is_empty(): continue
		if not needle.is_empty() and ("%s %s %s" % [material_id, title, TYPE_LABELS.get(kind, kind)]).to_lower().find(needle) < 0: continue
		var item := tree.create_item(root)
		item.set_metadata(0, {"kind": "material", "id": material_id})
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)
		item.set_text(2, material_id)
		item.set_text(3, str(TYPE_LABELS.get(kind, kind)))
		item.set_text(4, title)
		for id in versions:
			var child := tree.create_item(item)
			child.set_metadata(0, {"kind": "content", "id": id, "material": material_id})
			child.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			child.set_editable(0, true)
			child.set_text(2, id)
			child.set_text(4, "第 %d 版  %s" % [int(config().contents[id].version), config().contents[id].name])
		item.collapsed = not bool(_expanded.get(material_id, false))
	_mark_owned()
	_update_status()

## 只更新持有标记和着色，不重建，避免打断勾选和滚动位置。
func _mark_owned() -> void:
	var state: RefCounted = session().case_state
	var root := tree.get_root()
	if root == null: return
	for item in root.get_children():
		var meta: Dictionary = item.get_metadata(0)
		var versions := _versions_of(str(meta.id))
		var owned := 0
		for child in item.get_children():
			var has: bool = state.owns(str(child.get_metadata(0).id))
			child.set_text(1, "已持有" if has else "-")
			color_item(child, 6, DebugTheme.OK if has else DebugTheme.DIM)
			if has: owned += 1
		item.set_text(1, "%d/%d" % [owned, versions.size()])
		item.set_text(5, "" if owned == 0 else "最新 第 %d 版" % int(config().contents[str(state.data.materials.get(meta.id, {}).get("current", versions.back()))].version))
		color_item(item, 6, DebugTheme.OK if owned == versions.size() else (DebugTheme.TEXT if owned > 0 else DebugTheme.DIM))

func refresh() -> void:
	if not built: return
	_mark_owned()
	var active := in_game()
	for button in action_buttons: button.disabled = not active
	_update_status()

func _rows() -> Array:
	var rows: Array = []
	var root := tree.get_root()
	if root == null: return rows
	for item in root.get_children():
		rows.append(item)
		for child in item.get_children(): rows.append(child)
	return rows

## 勾选的行；一行都没勾时取当前点选的行。
func targets() -> Array:
	var picked: Array = _rows().filter(func(item): return item.is_checked(0))
	if picked.is_empty() and tree.get_selected() != null: picked.append(tree.get_selected())
	return picked

func tokens() -> Array:
	var found: Array = []
	for item in targets():
		var meta: Dictionary = item.get_metadata(0)
		if str(meta.id) not in found: found.append(str(meta.id))
	return found

func _check_all(on: bool) -> void:
	for item in tree.get_root().get_children(): item.set_checked(0, on)
	_update_status()

func _update_status(_arg = null) -> void:
	if status_label == null or tree.get_root() == null: return
	var listed: int = tree.get_root().get_child_count()
	var picked: int = _rows().filter(func(item): return item.is_checked(0)).size()
	status_label.text = "列表 %d 项；已勾选 %d 项（点材料行左侧的复选框，或点选一行）。%s" % [listed, picked, "" if in_game() else "  尚未开始游戏，获得或移除物品前请先开始游戏或跳转。"]

func _give(every_version: bool) -> void:
	var list := tokens()
	if list.is_empty():
		console.say("请先勾选或点选要获得的材料。", "warn")
		return
	console.run("give %s%s" % [" ".join(list), " -a" if every_version else ""])

func _take() -> void:
	var list := tokens()
	if list.is_empty():
		console.say("请先勾选或点选要移除的材料。", "warn")
		return
	console.run("take " + " ".join(list))
