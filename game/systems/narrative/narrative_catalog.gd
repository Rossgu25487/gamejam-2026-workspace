extends RefCounted
## 文案目录：只负责保存已解析的脚本、字典和跳转，不推进玩家状态。

var data: Dictionary = {}
var errors: Array[String] = []

func configure(definition: Dictionary) -> bool:
	data = definition.duplicate(true)
	errors.clear()
	for section in ["texts", "chapters", "scenes", "locations", "backgrounds", "transitions", "states", "state_values", "events", "performance_events"]:
		if not data.get(section, {}) is Dictionary and not data.get(section, []) is Array:
			errors.append("文案配置缺少栏目：" + section)
	for id in data.get("texts", {}):
		var row: Dictionary = data.texts[id]
		_check(not str(id).is_empty(), "文本ID为空")
		_check(not str(row.get("text", "")).is_empty(), "文本正文为空：" + str(id))
		_check(str(row.get("next_text_id", "")).is_empty() or data.texts.has(row.next_text_id), "下一文本不存在：" + str(id))
		_check(str(row.get("chapter_id", "")).is_empty() or data.chapters.has(row.chapter_id), "章节不存在：" + str(id))
		_check(str(row.get("scene_id", "")).is_empty() or data.scenes.has(row.scene_id), "场景不存在：" + str(id))
	for id in data.get("transitions", {}):
		var row: Dictionary = data.transitions[id]
		_check(not str(row.get("target_text_id", "")).is_empty() or not str(row.get("target_event_id", "")).is_empty() or bool(row.get("ends", false)), "跳转没有目标：" + str(id))
		_check(str(row.get("target_text_id", "")).is_empty() or data.texts.has(row.target_text_id), "跳转目标文本不存在：" + str(id))
		_check(str(row.get("target_event_id", "")).is_empty() or data.events.has(row.target_event_id), "跳转目标事件不存在：" + str(id))
	for id in data.get("events", {}):
		var row: Dictionary = data.events[id]
		_check(str(row.get("chapter_id", "")).is_empty() or data.chapters.has(row.chapter_id), "事件章节不存在：" + str(id))
	for id in data.get("performance_events", {}):
		var row: Dictionary = data.performance_events[id]
		_check(data.events.has(row.get("event_id", "")), "演出事件不存在：" + str(id))
		_check(int(row.get("order", 0)) > 0, "演出顺序无效：" + str(id))
	return errors.is_empty()

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

func text(id: String) -> String:
	return str(data.get("texts", {}).get(id, {}).get("text", ""))

func text_record(id: String) -> Dictionary:
	return data.get("texts", {}).get(id, {}).duplicate(true)

func transitions_from_text(text_id: String) -> Array:
	var result: Array = []
	for id in data.get("transitions", {}):
		var row: Dictionary = data.transitions[id]
		if str(row.get("source_text_id", "")) == text_id: result.append(row.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	return result

func transitions_from_event(event_id: String) -> Array:
	var result: Array = []
	for id in data.get("transitions", {}):
		var row: Dictionary = data.transitions[id]
		if str(row.get("source_event_id", "")) == event_id: result.append(row.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("order", 0)) < int(b.get("order", 0)))
	return result

func has_text(text_id: String) -> bool:
	return data.get("texts", {}).has(text_id)

func choices_from_text(text_id: String) -> Array:
	var result := transitions_from_text(text_id)
	var choices: Array = []
	for row in result:
		var transition_type := str(row.get("transition_type", "")).to_lower()
		if transition_type in ["choice", "选项", "按钮", "button"]:
			choices.append(row)
	return choices
