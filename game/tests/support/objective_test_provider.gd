extends "res://systems/objective/objective_provider.gd"
## 目标导航测试提供方：读取 TEST00-TEST10 测试组与测试依据，并可模拟准备失败、异步准备和入口复查结果。
## 仅用于回归与试玩台，不属于正式剧情。

const DATA_PATH := "res://tests/fixtures/objective/objective_test_data.json"

var data: Dictionary = {}
var current_group := "TEST00"
var fail_prepare := false
var async_prepare := false
var fail_read := false
var async_read := false
var go_ok := true
var entry_recheck: Dictionary = {} # 入口 ID -> {"available","reason"}，覆盖提供方的复查结果
var go_log: Array[String] = []
var read_log: Array[String] = []
var prepare_count := 0
var end_count := 0


func load_data(path := DATA_PATH) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return false
	data = parsed
	return true


func group(id: String) -> Dictionary:
	return data["groups"][id]


func group_snapshot(id: String) -> Dictionary:
	# 把测试组适配成提供方的一份目标显示结果。
	var source: Dictionary = group(id)
	return {"goal_id": source["goal_id"], "goal_text": source["goal_text"], "items": source["items"].duplicate(true), "bases": data["bases"].duplicate(true)}


func use_group(id: String, notify := false) -> void:
	current_group = id
	if notify:
		objective_changed.emit()


func objective_snapshot() -> Dictionary:
	return group_snapshot(current_group)


func prepare_review() -> Variant:
	prepare_count += 1
	if async_prepare:
		return null
	return not fail_prepare


func end_review() -> void:
	end_count += 1


func read_basis(basis_id: String) -> Variant:
	if async_read:
		return null
	if fail_read or not data["bases"].has(basis_id):
		return {"ok": false}
	read_log.append(basis_id)
	return {"ok": true, "doc": document(basis_id)}


func document(basis_id: String) -> Dictionary:
	var base: Dictionary = data["bases"][basis_id]
	var sources: Array = []
	if not String(base["source_id"]).is_empty():
		var source: Dictionary = data["bases"][base["source_id"]]
		sources.append({"id": source["id"], "title": "%s · %s" % [source["name"], source["version_text"]]})
	return {"id": basis_id, "kind": base["kind"], "title": base["name"], "version_text": base["version_text"], "body": base["body"], "sources": sources}


func recheck_entry(entry_id: String) -> Dictionary:
	if entry_recheck.has(entry_id):
		return entry_recheck[entry_id]
	for item in group(current_group)["items"]:
		if item.has("entry") and item["entry"]["id"] == entry_id:
			return {"available": item["entry"]["available"], "reason": item["entry"]["reason"]}
	return {"available": false, "reason": ""}


func go_entry(entry_id: String) -> Dictionary:
	go_log.append(entry_id)
	return {"ok": go_ok, "reason": "" if go_ok else "入口暂时无法进入"}
