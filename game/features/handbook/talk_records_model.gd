extends RefCounted
## 交谈记录（办案手册策划案第 7 节）纯逻辑模型：数据与文本解析由外部注入，便于无窗口回归测试。
## 只读取、筛选与维护已读标记，不执行对白、更正或结果；正文与顺序由核心玩法唯一维护。
## 消费来源：core.state.talk_records 与 core_catalog.data.{characters,statements,entries}。
## 话题筛选尚未接入（字段来源待 lead 定义），topic_of 与 filter 的话题参数为预留接口。

signal changed  # 绑定、标记已读或恢复快照后发出，页面据此刷新

var _records: Array = []         # 会面段记录，新→旧（bind 时倒序）
var _characters: Dictionary = {} # 人物表（id -> {name: text_id}）
var _statements: Dictionary = {} # 说法表（statement_id -> 记录）
var _entries: Dictionary = {}    # 调查入口表（话题字段接入时使用）
var _text: Callable              # text_id -> 显示文字
var _read: Dictionary = {}       # 已读键 -> true


func bind(records: Array, characters: Dictionary, statements: Dictionary, entries: Dictionary, text_resolver: Callable) -> bool:
	# 冻结一份快照；记录内容的合法性由核心玩法负责，这里只校验文本解析器有效。
	if not text_resolver.is_valid(): return false
	_records = records.duplicate(false)
	_records.reverse()
	_characters = characters
	_statements = statements
	_entries = entries
	_text = text_resolver
	_read.clear()
	changed.emit()
	return true


func records() -> Array:
	# 返回新→旧记录的浅拷贝；记录本身只读，调用方不应修改。
	return _records.duplicate(false)


func persons() -> Array:
	# 交谈对象：只从实际已取得记录中读取，按新→旧首次出现排序并去重；返回 [{id, name}]。
	var seen := {}
	var result: Array = []
	for record in _records:
		var id := person_of(record)
		if id.is_empty() or seen.has(id): continue
		seen[id] = true
		result.append({"id": id, "name": person_name(id)})
	return result


func person_name(id: String) -> String:
	var character: Dictionary = _characters.get(id, {})
	var name_id: String = str(character.get("name", ""))
	if name_id.is_empty() or not _text.is_valid(): return id
	return str(_text.call(name_id))


func person_of(record: Dictionary) -> String:
	# 原话直接取发言者；归纳按成果的目标说法推导发言者；推理成果没有交谈对象。
	match str(record.get("kind", "")):
		"statement":
			return str(record.get("speaker", ""))
		"confirmed":
			var target: Dictionary = record.get("record", {}).get("target_ref", {})
			if str(target.get("target_kind", "")) == "statement":
				var sid: String = str(target.get("statement_ref", {}).get("statement_id", ""))
				return str(_statements.get(sid, {}).get("speaker", ""))
	return ""


func topic_of(_record: Dictionary) -> String:
	# 【预留】话题筛选的数据来源待 lead 定义；当前一律返回空，非空话题筛选无匹配。
	return ""


func kind(record: Dictionary) -> String:
	# 原话（statement）与归纳（confirmed）的分区依据。
	match str(record.get("kind", "")):
		"statement": return "statement"
		"confirmed": return "confirmed"
	return ""


func text_of(record: Dictionary) -> String:
	var text_id: String = str(record.get("text_id", ""))
	if text_id.is_empty() or not _text.is_valid(): return ""
	return str(_text.call(text_id))


func filter(person_id: String = "", topic_id: String = "") -> Array:
	# 人物与话题取交集；空值表示不筛选。没有交谈对象的成果只在“全部人物”下显示。
	var result: Array = []
	for record in _records:
		if not person_id.is_empty() and person_of(record) != person_id: continue
		if not topic_id.is_empty() and topic_of(record) != topic_id: continue
		result.append(record)
	return result


func corrections(statement_id: String) -> Array:
	# 同一 claim 下、实际已听的全部说法版本（版本升序，含本句）；未听过的版本不返回。
	if not _statements.has(statement_id): return []
	var claim: String = str(_statements[statement_id].get("claim_id", ""))
	if claim.is_empty(): return []
	var heard := {}
	for record in _records:
		if kind(record) == "statement": heard[str(record.get("statement_id", ""))] = true
	var ids: Array = []
	for sid in _statements:
		if str(_statements[sid].get("claim_id", "")) == claim and heard.has(str(sid)): ids.append(str(sid))
	ids.sort_custom(func(a: String, b: String): return int(_statements[a].get("version", 0)) < int(_statements[b].get("version", 0)))
	return ids


func read_key(record: Dictionary) -> String:
	# 已读键：原话按 statement_id，归纳按 result_id，两者独立。
	match kind(record):
		"statement": return "s:" + str(record.get("statement_id", ""))
		"confirmed": return "c:" + str(record.get("result_id", ""))
	return ""


func is_read(record: Dictionary) -> bool:
	var key := read_key(record)
	return not key.is_empty() and _read.has(key)


func mark_read(record: Dictionary) -> void:
	var key := read_key(record)
	if key.is_empty() or _read.has(key): return
	_read[key] = true
	changed.emit()


func unread_count() -> int:
	var count := 0
	for record in _records:
		if not is_read(record): count += 1
	return count


func export_state() -> Dictionary:
	# 只持久化已读键；记录正文与顺序由核心玩法维护。
	return {"read": _read.keys()}


func validate_state(snapshot: Dictionary) -> bool:
	if not snapshot is Dictionary or not snapshot.get("read") is Array: return false
	for key in snapshot.read:
		if not key is String or str(key).is_empty(): return false
	return true


func restore_state(snapshot: Dictionary) -> bool:
	if not validate_state(snapshot): return false
	_read.clear()
	for key in snapshot.read: _read[str(key)] = true
	changed.emit()
	return true
