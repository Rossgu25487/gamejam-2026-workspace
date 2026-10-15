extends SceneTree
## 交谈记录模型回归测试（无窗口）：验证新→旧排序、人物筛选、原话/归纳分区、更正链与已读快照。

const ModelScript = preload("res://features/handbook/talk_records_model.gd")

var _checks := 0
var _failed := 0
var _changed := 0

func _init() -> void:
	_test_bind()
	_test_order_and_kind()
	_test_persons()
	_test_filter()
	_test_corrections()
	_test_read_and_snapshot()
	if _failed == 0:
		print("HANDBOOK_TALK_PASS %d checks" % _checks)
	else:
		print("HANDBOOK_TALK_FAIL %d failed / %d checks" % [_failed, _checks])
	quit(1 if _failed else 0)

func expect(ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: " + detail)

func _on_changed() -> void:
	_changed += 1

func _fixture_texts() -> Dictionary:
	return {"nm_p": "甲", "nm_q": "乙", "tx_s1": "原话一", "tx_s2": "更正话", "tx_s3": "另一人原话", "res1": "归纳文字"}

func _fixture_characters() -> Dictionary:
	return {"P": {"name": "nm_p"}, "Q": {"name": "nm_q"}}

func _fixture_statements() -> Dictionary:
	return {
		"S1": {"claim_id": "C1", "speaker": "P", "version": 1, "text": "tx_s1", "record_content": "TALK1"},
		"S2": {"claim_id": "C1", "speaker": "P", "version": 2, "text": "tx_s2", "record_content": "TALK2"},
		"S3": {"claim_id": "C2", "speaker": "Q", "version": 1, "text": "tx_s3", "record_content": "TALK3"},
	}

func _fixture_entries() -> Dictionary:
	return {"E1": {"title": "tp_e1"}, "E2": {"title": "tp_e2"}}

func _fixture_records() -> Array:
	# 按实际取得顺序追加：S1 先听到，R1 归纳，S2 更正后补听，S3 另一人。
	return [
		{"kind": "statement", "statement_id": "S1", "claim_id": "C1", "speaker": "P", "text_id": "tx_s1", "entry_id": "E1"},
		{"kind": "confirmed", "result_id": "R1", "text_id": "res1", "record": {"target_ref": {"target_kind": "statement", "question_id": "Q1", "statement_ref": {"claim_id": "C1", "statement_id": "S1"}}}},
		{"kind": "statement", "statement_id": "S2", "claim_id": "C1", "speaker": "P", "text_id": "tx_s2", "entry_id": "result"},
		{"kind": "statement", "statement_id": "S3", "claim_id": "C2", "speaker": "Q", "text_id": "tx_s3", "entry_id": "E2"},
	]

func _make_model() -> RefCounted:
	var model = ModelScript.new()
	var texts: Dictionary = _fixture_texts()
	expect(model.bind(_fixture_records(), _fixture_characters(), _fixture_statements(), _fixture_entries(), func(id: String) -> String: return str(texts.get(id, id))), "绑定夹具")
	return model

func _test_bind() -> void:
	var model = ModelScript.new()
	var ok: bool = model.bind(_fixture_records(), _fixture_characters(), _fixture_statements(), _fixture_entries(), func(id: String) -> String: return id)
	expect(ok, "有效解析器绑定成功")
	expect(not model.bind(_fixture_records(), _fixture_characters(), _fixture_statements(), _fixture_entries(), Callable()), "空文本解析器拒绝绑定")

func _test_order_and_kind() -> void:
	var model = _make_model()
	var recs = model.records()
	expect(recs.size() == 4, "共四条记录")
	expect(recs[0].statement_id == "S3" and recs[1].statement_id == "S2", "新→旧前两条")
	expect(recs[2].result_id == "R1" and recs[3].statement_id == "S1", "新→旧后两条")
	expect(model.kind(recs[0]) == "statement" and model.kind(recs[2]) == "confirmed", "原话/归纳分区")
	expect(model.kind({}) == "", "未知记录为空 kind")
	expect(model.text_of(recs[0]) == "另一人原话", "原话文字解析")
	expect(model.text_of(recs[2]) == "归纳文字", "归纳文字解析")

func _test_persons() -> void:
	var model = _make_model()
	var persons = model.persons()
	expect(persons.size() == 2, "两个交谈对象")
	expect(persons[0].id == "Q" and persons[0].name == "乙", "新→旧首个对象")
	expect(persons[1].id == "P" and persons[1].name == "甲", "第二个对象")
	expect(model.person_name("P") == "甲", "姓名解析")
	expect(model.person_name("UNKNOWN") == "UNKNOWN", "未知人物回退 ID")
	var recs = model.records()
	expect(model.person_of(recs[0]) == "Q", "S3 发言者 Q")
	expect(model.person_of(recs[1]) == "P", "S2 发言者 P")
	expect(model.person_of(recs[2]) == "P", "归纳按目标说法推导 P")
	expect(model.person_of(recs[3]) == "P", "S1 发言者 P")
	expect(model.person_of({}) == "", "未知记录无交谈对象")

func _test_filter() -> void:
	var model = _make_model()
	expect(model.filter().size() == 4, "全部人物四条")
	var p = model.filter("P")
	expect(p.size() == 3 and p[0].statement_id == "S2" and p[1].result_id == "R1" and p[2].statement_id == "S1", "人物 P 筛选且保新→旧序")
	var q = model.filter("Q")
	expect(q.size() == 1 and q[0].statement_id == "S3", "人物 Q 筛选")
	expect(model.filter("NONEXIST").is_empty(), "未知人物无匹配")
	expect(model.filter("", "X").is_empty(), "话题预留：非空话题当前无匹配")

func _test_corrections() -> void:
	var model = _make_model()
	var c1 = model.corrections("S1")
	expect(c1.size() == 2 and c1[0] == "S1" and c1[1] == "S2", "同 claim 已听版本升序")
	var c2 = model.corrections("S2")
	expect(c2.size() == 2 and c2[1] == "S2", "更正句同样列出旧话")
	var c3 = model.corrections("S3")
	expect(c3.size() == 1 and c3[0] == "S3", "另一 claim 仅一句")
	expect(model.corrections("UNKNOWN").is_empty(), "未知说法空更正链")

func _test_read_and_snapshot() -> void:
	var model = _make_model()
	model.changed.connect(_on_changed)
	var recs = model.records()
	expect(model.unread_count() == 4, "初始全部未读")
	expect(model.read_key(recs[0]) == "s:S3", "原话已读键")
	expect(model.read_key(recs[2]) == "c:R1", "归纳已读键")
	expect(model.read_key({}).is_empty(), "未知记录无已读键")
	model.mark_read(recs[3])  # S1
	model.mark_read(recs[3])  # 重复标记
	expect(model.is_read(recs[3]) and model.unread_count() == 3, "标记已读且去重")
	model.mark_read(recs[2])  # R1
	expect(model.unread_count() == 2, "两处已读")
	var snap = model.export_state()
	expect(snap.has("read") and snap.read.size() == 2, "导出两个已读键")
	expect(("s:S1" in snap.read) and ("c:R1" in snap.read), "已读键内容")
	expect(model.validate_state(snap), "快照可校验")
	expect(not model.validate_state({}), "空快照不可校验")
	expect(not model.validate_state({"read": "s:S1"}), "非数组拒绝")
	expect(not model.validate_state({"read": [1]}), "非字符串元素拒绝")
	var restored = ModelScript.new()
	expect(restored.bind(_fixture_records(), _fixture_characters(), _fixture_statements(), _fixture_entries(), func(id: String) -> String: return id), "恢复模型绑定")
	expect(restored.restore_state(snap) and restored.unread_count() == 2, "恢复已读快照")
	expect(not restored.restore_state({}), "无效快照拒绝恢复")
	expect(_changed == 2, "标记已读发出 changed")
