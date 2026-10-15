extends RefCounted
## 地图接入前检查只分析结构与引用；实际必需文件由目的地准备复核。

func validate(definition: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for section in ["boards", "groups", "scenes", "resources", "nodes"]:
		if not definition.get(section, {}) is Dictionary: errors.append("地图段必须为字典：" + section)
	if not definition.get("transitions", []) is Array: errors.append("地点连接必须为列表")
	if not errors.is_empty(): return errors
	var boards: Dictionary = definition.get("boards", {})
	var scenes: Dictionary = definition.get("scenes", {})
	var occupied := {}
	var rectangles := {}
	for id in boards:
		var board = boards[id]
		if not board is Dictionary:
			errors.append("棋盘记录格式无效：" + str(id)); continue
		for key in ["rows", "cols"]:
			if not _integer(board.get(key), 1): errors.append("棋盘行列无效：%s / %s" % [id, key])
		if not _number(board.get("cell_size", 100), 1): errors.append("棋盘格尺寸无效：" + str(id))
	if not errors.is_empty(): return errors
	for id in definition.get("nodes", {}):
		var node = definition.nodes[id]
		if not node is Dictionary:
			errors.append("地点节点格式无效：" + str(id)); continue
		var group := str(node.get("group_id", ""))
		var scene := str(node.get("scene_id", ""))
		if not boards.has(group):
			errors.append("地点节点棋盘缺失：%s / %s" % [id, group]); continue
		if not definition.get("groups", {}).is_empty() and not definition.groups.has(group): errors.append("地点节点分组缺失：" + str(id))
		if scene.is_empty() or not scenes.has(scene): errors.append("地点节点场景缺失：" + str(id))
		if occupied.has(scene): errors.append("同场景存在多个地点节点：%s / %s" % [occupied[scene], id])
		occupied[scene] = id
		var board: Dictionary = boards[group]
		if not _integer(node.get("grid_col"), 0) or not _integer(node.get("grid_row"), 0):
			errors.append("地点落点必须为非负整数：" + str(id)); continue
		if int(node.grid_col) >= int(board.cols) or int(node.grid_row) >= int(board.rows): errors.append("地点落点越界：" + str(id))
		if not _number(node.get("w", 76), 1) or not _number(node.get("h", 48), 1):
			errors.append("地点点击区尺寸无效：" + str(id)); continue
		var cell := float(board.get("cell_size", 100))
		var dimensions := Vector2(float(node.get("w", 76)), float(node.get("h", 48)))
		var rect := Rect2((Vector2(float(node.grid_col), float(node.grid_row)) + Vector2.ONE * 0.5) * cell - dimensions / 2, dimensions)
		for previous in rectangles.get(group, []):
			if rect.intersects(previous.rect): errors.append("地点点击区重叠：%s / %s" % [previous.id, id])
		if not rectangles.has(group): rectangles[group] = []
		rectangles[group].append({"id": id, "rect": rect})
	var links := {}
	for row in definition.get("transitions", []):
		if not row is Dictionary:
			errors.append("地点连接记录格式无效"); continue
		var id := str(row.get("transition_id", row.get("link_id", "")))
		if id.is_empty() or links.has(id): errors.append("地点连接ID重复或为空：" + id)
		links[id] = true
	for id in scenes:
		var scene = scenes[id]
		if not scene is Dictionary:
			errors.append("场景记录格式无效：" + str(id)); continue
		for key in ["background_ref", "scene_resource_ref"]:
			var ref := str(scene.get(key, ""))
			if not ref.is_empty() and not definition.get("resources", {}).has(ref): errors.append("场景资源引用缺失：%s / %s" % [id, ref])
	return errors

func _number(value, minimum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum

func _integer(value, minimum: int) -> bool:
	return _number(value, minimum) and floor(float(value)) == float(value)
