@tool
extends RefCounted
## All paths returned to callers are repository-relative unless explicitly named absolute_path.

const BRIEF_EXTENSIONS := ["md", "txt", "docx", "pdf"]
const ROLE_IDS := ["planner", "lead", "gameplay", "integration", "ui_art", "visual_art", "qa", "ops"]


func read_manifest(root: String) -> Dictionary:
	var result := _read_json(root, "workspace/manifest.json")
	if not result.ok:
		return result
	var manifest: Dictionary = result.data
	if manifest.get("schema_version") != 1 or not manifest.get("roles") is Array:
		return _failure("岗位清单格式不正确：需要 schema_version 为 1，以及 roles 数组。")
	var seen: Dictionary = {}
	for value in manifest.roles:
		if not value is Dictionary:
			return _failure("岗位清单中存在无效的岗位记录。")
		var role: Dictionary = value
		var role_id := str(role.get("id", ""))
		if role_id not in ROLE_IDS or seen.has(role_id):
			return _failure("岗位编号无效或重复：%s" % role_id)
		seen[role_id] = true
		if str(role.get("name", "")).is_empty():
			return _failure("岗位 %s 缺少名称。" % role_id)
		for field in ["workflow", "handoff"]:
			var checked := resolve_path(root, str(role.get(field, "")))
			if not checked.ok:
				return _failure("岗位 %s 的 %s 路径无效：%s" % [role_id, field, checked.error])
		if not role.get("owned_paths") is Array:
			return _failure("岗位 %s 缺少 owned_paths 数组。" % role_id)
		for owned_path in role.owned_paths:
			var checked := resolve_path(root, str(owned_path))
			if not checked.ok:
				return _failure("岗位 %s 的负责目录无效：%s" % [role_id, checked.error])
	if seen.size() != ROLE_IDS.size():
		return _failure("岗位清单需要包含策划、主程序、两名副程序、两名美术、测试和运营共 8 个岗位。")
	return {"ok": true, "error": "", "manifest": manifest}


func import_brief(root: String, source: String) -> Dictionary:
	var normalized_source := source.replace("\\", "/")
	if not normalized_source.is_absolute_path() or not FileAccess.file_exists(normalized_source):
		return _failure("无法读取导入原件，请选择一个存在的文件。")
	var extension := normalized_source.get_extension().to_lower()
	if extension not in BRIEF_EXTENSIONS:
		return _failure("仅支持导入 .md、.txt、.docx 和 .pdf 文件。")
	var checked := resolve_path(root, "planning/inbox")
	if not checked.ok:
		return checked
	var inbox: String = checked.absolute_path
	var create_error := DirAccess.make_dir_recursive_absolute(inbox)
	if create_error != OK:
		return _failure("无法创建策划案收件目录：%s" % error_string(create_error))
	var filename := normalized_source.get_file()
	var basename := filename.get_basename()
	var index := 2
	while FileAccess.file_exists(inbox.path_join(filename)) or DirAccess.dir_exists_absolute(inbox.path_join(filename)):
		filename = "%s_%d.%s" % [basename, index, extension]
		index += 1
	var destination := inbox.path_join(filename)
	var copy_error := DirAccess.copy_absolute(normalized_source, destination)
	if copy_error != OK:
		return _failure("原件复制失败：%s。原文件未修改。" % error_string(copy_error))
	return {"ok": true, "error": "", "path": "planning/inbox/" + filename}


func set_current(root: String, relative_path: String, expected_original_pointer: String = "", expected_source_sha256: String = "") -> Dictionary:
	var checked := _brief_path(root, relative_path)
	if not checked.ok:
		return checked
	var previous := read_current(root)
	if not previous.ok:
		return previous
	if not expected_original_pointer.is_empty() and previous.pointer_text != expected_original_pointer:
		return {"ok": false, "error": "当前依据已被其他修改更新。请刷新并核对后再确认；所选文档仍保留，未覆盖当前依据。", "conflict": true}
	var source_result := get_brief_sha256(root, checked.path)
	if not source_result.ok:
		return source_result
	if not expected_source_sha256.is_empty() and source_result.sha256 != expected_source_sha256:
		return {"ok": false, "error": "所选原件在预览后发生变化。请重新选择并查看内容，再设为当前依据。", "content_changed": true}
	var current := {
		"status": "active",
		"path": checked.path,
		"title": str(checked.path).get_file().get_basename(),
		"revision": int(previous.current.revision) + 1,
		"updated_at": Time.get_datetime_string_from_system(true) + "Z",
		"sha256": source_result.sha256,
	}
	var write_result := _atomic_write(root, "planning/current.json", JSON.stringify(current, "\t") + "\n", previous.pointer_text)
	if not write_result.ok:
		return write_result
	return {"ok": true, "error": "", "current": current}


func read_current(root: String) -> Dictionary:
	var result := _read_json(root, "planning/current.json")
	if not result.ok:
		return result
	var current: Dictionary = result.data
	if current.get("status") not in ["pending", "active"]:
		return _failure("当前依据文件的 status 需要为 pending 或 active。")
	if not current.get("revision") is float and not current.get("revision") is int:
		return _failure("当前依据文件缺少有效的 revision。")
	if int(current.revision) < 0 or float(current.revision) != float(int(current.revision)):
		return _failure("当前依据的 revision 需要为非负整数。")
	for field in ["path", "title", "updated_at"]:
		if not current.get(field) is String:
			return _failure("当前依据文件缺少字符串字段：%s" % field)
	if current.status == "active":
		var checked := _brief_path(root, current.path, false)
		if not checked.ok:
			return checked
	elif not str(current.path).is_empty():
		return _failure("待定依据的 path 应为空。")
	var source_changed := false
	var source_sha256 := ""
	var notice := ""
	if current.status == "active":
		var source_result := get_brief_sha256(root, current.path)
		if not source_result.ok:
			source_changed = true
			notice = "当前依据原件无法读取，请策划核对后重新选择。" + str(source_result.error)
		else:
			source_sha256 = source_result.sha256
			if str(current.get("sha256", "")).is_empty():
				source_changed = true
				notice = "当前依据尚未记录内容指纹，请策划核对原件后重新确认。"
			elif current.sha256 != source_sha256:
				source_changed = true
				notice = "当前依据原件已变化，现有版本号不再代表盘上的内容。请策划核对后重新确认。"
	return {"ok": true, "error": "", "current": current, "pointer_text": result.pointer_text,
		"source_changed": source_changed, "source_sha256": source_sha256, "notice": notice}


func get_brief_sha256(root: String, relative_path: String) -> Dictionary:
	var checked := _brief_path(root, relative_path)
	if not checked.ok:
		return checked
	var sha256 := FileAccess.get_sha256(checked.absolute_path)
	if sha256.is_empty():
		return _failure("无法读取策划原件的内容指纹：%s" % checked.path)
	return {"ok": true, "error": "", "path": checked.path, "sha256": sha256}


func save_handoff(root: String, relative_path: String, text: String, expected_original: String) -> Dictionary:
	var checked := resolve_path(root, relative_path)
	if not checked.ok:
		return checked
	if not str(checked.path).begins_with("workspace/handoffs/") or str(checked.path).get_extension().to_lower() != "md":
		return _failure("交接记录只能保存到 workspace/handoffs/ 下的 Markdown 文件。")
	var current := read_text(root, checked.path)
	if not current.ok:
		return current
	if current.text != expected_original:
		return {"ok": false, "error": "磁盘上的交接记录已被修改。当前草稿已保留，请先核对后重新载入，未覆盖他人内容。", "conflict": true}
	return _atomic_write(root, checked.path, text, expected_original)


func read_text(root: String, relative_path: String) -> Dictionary:
	var checked := resolve_path(root, relative_path)
	if not checked.ok:
		return checked
	var file := FileAccess.open(checked.absolute_path, FileAccess.READ)
	if file == null:
		return _failure("读取失败：%s（%s）" % [checked.path, error_string(FileAccess.get_open_error())])
	var length := file.get_length()
	var bytes := file.get_buffer(length)
	var read_error := file.get_error()
	file.close()
	if bytes.size() != length or read_error not in [OK, ERR_FILE_EOF]:
		return _failure("文件未能完整读取：%s（%s）" % [checked.path, error_string(read_error)])
	var utf8_bytes := bytes
	if bytes.size() >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf:
		utf8_bytes = bytes.slice(3)
	var text := utf8_bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != utf8_bytes:
		return _failure("文件不是有效的 UTF-8 文本：%s。请先确认编码。" % checked.path)
	return {"ok": true, "error": "", "path": checked.path, "text": text}


func list_briefs(root: String) -> Dictionary:
	var checked := resolve_path(root, "planning/inbox")
	if not checked.ok:
		return checked
	var directory := DirAccess.open(checked.absolute_path)
	if directory == null:
		return _failure("无法打开策划案收件目录：%s" % error_string(DirAccess.get_open_error()))
	var files := directory.get_files()
	files.sort()
	var paths: Array[String] = []
	for filename in files:
		if filename.to_lower() != "readme.md" and filename.get_extension().to_lower() in BRIEF_EXTENSIONS:
			paths.append("planning/inbox/" + filename)
	return {"ok": true, "error": "", "paths": paths}


func resolve_path(root: String, relative_path: String) -> Dictionary:
	var base := root.replace("\\", "/").simplify_path().trim_suffix("/")
	var relative := relative_path.replace("\\", "/")
	if base.is_empty() or not base.is_absolute_path() or base.begins_with("res://") or base.begins_with("user://"):
		return _failure("需要明确的仓库绝对路径。")
	if relative.is_empty() or relative.is_absolute_path() or relative.contains(":"):
		return _failure("需要仓库内的相对路径。")
	for part in relative.split("/", false):
		if part in ["..", "."]:
			return _failure("路径不得使用上级目录或当前目录跳转。")
	var absolute := base.path_join(relative).simplify_path()
	if not absolute.begins_with(base + "/"):
		return _failure("路径超出仓库范围。")
	return {"ok": true, "error": "", "path": relative.trim_suffix("/"), "absolute_path": absolute}


func _brief_path(root: String, relative_path: String, require_file: bool = true) -> Dictionary:
	var checked := resolve_path(root, relative_path)
	if not checked.ok:
		return checked
	if str(checked.path).get_file().to_lower() == "readme.md":
		return _failure("README.md 是收件箱使用说明，不能设为当前策划依据。")
	if not str(checked.path).begins_with("planning/inbox/") or str(checked.path).get_extension().to_lower() not in BRIEF_EXTENSIONS:
		return _failure("当前依据必须选择 planning/inbox/ 中已入库的策划文件。")
	if require_file and not FileAccess.file_exists(checked.absolute_path):
		return _failure("策划文件不存在：%s" % checked.path)
	return checked


func _read_json(root: String, relative_path: String) -> Dictionary:
	var result := read_text(root, relative_path)
	if not result.ok:
		return result
	var parser := JSON.new()
	var parse_error := parser.parse(str(result.text).trim_prefix("\ufeff"))
	if parse_error != OK:
		return _failure("JSON 读取失败：%s，第 %d 行：%s" % [relative_path, parser.get_error_line(), parser.get_error_message()])
	if not parser.data is Dictionary:
		return _failure("JSON 顶层需要为对象：%s" % relative_path)
	return {"ok": true, "error": "", "data": parser.data, "pointer_text": result.text}


func _atomic_write(root: String, relative_path: String, text: String, expected_original: Variant = null) -> Dictionary:
	var checked := resolve_path(root, relative_path)
	if not checked.ok:
		return checked
	var destination: String = checked.absolute_path
	var temporary := destination + ".tmp-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _failure("无法创建写入文件：%s（%s）" % [relative_path, error_string(FileAccess.get_open_error())])
	var written := file.store_string(text)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if not written or write_error != OK:
		DirAccess.remove_absolute(temporary)
		return _failure("UTF-8 保存失败：%s（%s）。原文件未替换。" % [relative_path, error_string(write_error) if write_error != OK else "未能完整写入"])
	if expected_original != null:
		var latest := read_text(root, relative_path)
		if not latest.ok or latest.text != expected_original:
			DirAccess.remove_absolute(temporary)
			return {"ok": false, "error": "保存前发现磁盘文件已变化或无法读取；草稿已保留，原文件未覆盖，请重新载入核对。", "conflict": true}
	var replace_error := DirAccess.rename_absolute(temporary, destination)
	if replace_error != OK:
		DirAccess.remove_absolute(temporary)
		return _failure("替换文件失败：%s（%s）。原文件未替换。" % [relative_path, error_string(replace_error)])
	return {"ok": true, "error": "", "path": checked.path}


func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "path": ""}
