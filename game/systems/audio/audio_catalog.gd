extends RefCounted
## 声音配置目录：加载总控、资源、事件与音景，负责校验、音景匹配、资源就绪判定与流缓存。
## 配置来自《声音播放系统配置表》导入结果；运行时不读取 Excel。

const BUS_KINDS := ["bgm", "ambient", "ui", "result", "voice"]
const SOURCE_KINDS := ["fixed", "scene_bgm", "scene_ambient", "node_sound", "node_voice"]
const CONTEXT_KINDS := ["title", "scene", "ending"]
const STATE_UNBOUND := "unbound" # 用途已定、素材尚未采用：不发声，也不算制作错误。
const STATE_READY := "ready" # 引用有效且资源可读取。
const STATE_MISSING := "missing" # 引用非空但资源不存在：属于制作错误。
const DEFAULT_SFX_LIBRARY := "res://data/audio/sfx_library.json" # 备用音效库目录（由 tools/import_sfx_library.py 生成）。
const MIN_FADE_MS := 0
const MAX_FADE_MS := 5000

var control := {"bgm_crossfade_ms": 800, "ambient_fade_ms": 300, "menu_bgm_factor": 0.5} # 总控初值。
var resources := {} # id -> {id, bus, resource_ref, resource_path}
var events := {} # id -> {id, bus, source_kind, resource_key, loop, event_gain}
var soundscapes: Array = [] # 保持配置顺序的音景记录。
var ref_table := {} # 程序声音来源的“资源编号 -> 相对路径”映射，可为空。
var sfx_entries: Array = [] # 备用音效条目列表（保持来源包与分类顺序）。
var sfx_by_id := {} # 备用音效 ID -> 条目字典。
var sfx_packs: Array = [] # 备用音效来源包列表。
var sfx_categories: Array = [] # 备用音效分类列表。
var asset_root := "res://" # resource_path 与相对引用的根目录；测试可指向夹具目录。
var errors: Array[String] = [] # 最近一次加载的校验错误。

var _scape_index := {} # "类型|目标|阶段" -> 音景记录，匹配只做两次字典查找。
var _streams := {} # "路径" 或 "路径:loop" -> AudioStream。
var _sfx_alias_to_id := {} # 别名／文件名／路径 -> 备用音效标准 ID。


func load_file(path: String, merge := false) -> bool:
	# 读取一个 JSON 配置；merge 为真时叠加到当前配置（例如 EX 测试夹具）。
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("无法读取声音配置：" + path)
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("声音配置不是有效 JSON 对象：" + path)
		return false
	return configure(parsed, merge)


func configure(data: Dictionary, merge := false) -> bool:
	# 先在候选副本上合并并整体校验，通过后一次提交，失败不留下半份配置。
	var next_control: Dictionary = control.duplicate() if merge else {"bgm_crossfade_ms": 800, "ambient_fade_ms": 300, "menu_bgm_factor": 0.5}
	var next_resources: Dictionary = resources.duplicate(true) if merge else {}
	var next_events: Dictionary = events.duplicate(true) if merge else {}
	var next_scapes: Array = soundscapes.duplicate(true) if merge else []
	var found: Array[String] = []
	_merge_control(next_control, data.get("control", {}), found)
	for record in data.get("resources", []):
		_add_resource(next_resources, record, found)
	for record in data.get("events", []):
		_add_event(next_events, record, found)
	for record in data.get("soundscapes", []):
		next_scapes.append(record)
	_check_cross_references(next_resources, next_events, next_scapes, found)
	if not found.is_empty():
		errors.append_array(found)
		return false
	control = next_control
	resources = next_resources
	events = next_events
	soundscapes = next_scapes
	_rebuild_index()
	return true


func resolve_path(resource_ref: String, resource_path := "") -> String:
	# resource_path 直接相对资源根；resource_ref 先查程序映射，再按相对路径解释，无法解析返回空串。
	if not resource_path.is_empty():
		return _absolute(resource_path)
	if resource_ref.is_empty():
		return ""
	if ref_table.has(resource_ref):
		return _absolute(String(ref_table[resource_ref]))
	if resource_ref.contains("/") or resource_ref.contains("."):
		return _absolute(resource_ref)
	return ""


func describe(resource_ref: String, resource_path := "", bus := "") -> Dictionary:
	# 判定一条引用的状态：未绑定（两项都空）、就绪或缺失。
	if resource_ref.is_empty() and resource_path.is_empty():
		return {"state": STATE_UNBOUND, "path": "", "bus": bus}
	var resolved := resolve_path(resource_ref, resource_path)
	if resolved.is_empty() or not ResourceLoader.exists(resolved):
		return {"state": STATE_MISSING, "path": resolved, "bus": bus}
	return {"state": STATE_READY, "path": resolved, "bus": bus}


func resource_state(resource_id: String) -> Dictionary:
	# 按资源逻辑键判定状态；键不存在按缺失处理。
	var record: Dictionary = resources.get(resource_id, {})
	if record.is_empty():
		return {"state": STATE_MISSING, "path": "", "bus": ""}
	return describe(String(record.get("resource_ref", "")), String(record.get("resource_path", "")), String(record.get("bus", "")))


func bind_resource(resource_id: String, resource_path: String) -> bool:
	# 为用途已定、素材尚未采用的资源临时指定文件或备用音效键（开发试听、音效管理与试玩台使用）；资源键必须已存在。
	if not resources.has(resource_id):
		return false
	if not resource_path.is_empty() and ref_table.has(resource_path):
		resources[resource_id]["resource_path"] = String(ref_table[resource_path])
	else:
		resources[resource_id]["resource_path"] = resource_path
	return true


func load_sfx_library(path := DEFAULT_SFX_LIBRARY) -> bool:
	# 读取备用音效库目录（sfx_library.json），把全部备用音效的标准 ID、文件名与别名登记到映射表，供任意模块随时调用。
	if not FileAccess.file_exists(path):
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	sfx_entries = parsed.get("entries", []).duplicate(true)
	sfx_packs = parsed.get("packs", []).duplicate(true)
	sfx_categories = parsed.get("categories", []).duplicate(true)
	sfx_by_id.clear()
	_sfx_alias_to_id.clear()
	for entry in sfx_entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var sfx_id := String(entry.get("id", ""))
		var sfx_path := String(entry.get("path", ""))
		if sfx_id.is_empty() or sfx_path.is_empty():
			continue
		sfx_by_id[sfx_id] = entry
		_register_sfx_key(sfx_id, sfx_id, sfx_path)
		_register_sfx_key(sfx_path, sfx_id, sfx_path)
		_register_sfx_key(sfx_path.trim_prefix("res://"), sfx_id, sfx_path)
		for alias in entry.get("aliases", []):
			_register_sfx_key(String(alias), sfx_id, sfx_path)
	return true


func _register_sfx_key(key: String, sfx_id: String, sfx_path: String) -> void:
	if key.is_empty():
		return
	if not _sfx_alias_to_id.has(key):
		_sfx_alias_to_id[key] = sfx_id
	if not ref_table.has(key):
		ref_table[key] = sfx_path


func sfx_entry(key_or_ref: String) -> Dictionary:
	# 按备用音效标准 ID、简写文件名、中文别名或路径查询条目元信息。
	if key_or_ref.is_empty():
		return {}
	if sfx_by_id.has(key_or_ref):
		return sfx_by_id[key_or_ref]
	if _sfx_alias_to_id.has(key_or_ref):
		return sfx_by_id.get(String(_sfx_alias_to_id[key_or_ref]), {})
	return {}


func filter_sfx(pack_filter := "", category_filter := "", query := "") -> Array:
	# 按来源包、分类与关键词筛选备用音效条目；空串或 all 表示不限。
	var pack_key := "" if pack_filter == "all" else pack_filter.strip_edges()
	var cat_key := "" if category_filter == "all" else category_filter.strip_edges()
	var keyword := query.strip_edges().to_lower()
	var matched: Array = []
	for entry in sfx_entries:
		if not pack_key.is_empty() and String(entry.get("pack", "")) != pack_key:
			continue
		if not cat_key.is_empty() and String(entry.get("category", "")) != cat_key:
			continue
		if not keyword.is_empty() and not _sfx_matches_query(entry, keyword):
			continue
		matched.append(entry)
	return matched


func _sfx_matches_query(entry: Dictionary, keyword: String) -> bool:
	for field in ["id", "name", "stem", "pack", "pack_label", "category", "category_label", "usage", "path"]:
		if String(entry.get(field, "")).to_lower().contains(keyword):
			return true
	for alias in entry.get("aliases", []):
		if String(alias).to_lower().contains(keyword):
			return true
	return false


func match_soundscape(kind: String, target_ref := "", phase_ref := "") -> Dictionary:
	# 准确阶段行优先于同场景通用行；标题不使用目标。没有匹配返回空字典。
	var target := "" if kind == "title" else target_ref
	if not phase_ref.is_empty():
		var exact: Dictionary = _scape_index.get(_key(kind, target, phase_ref), {})
		if not exact.is_empty():
			return exact
	return _scape_index.get(_key(kind, target, ""), {})


func get_stream(path: String, looping: bool) -> AudioStream:
	# 读取并缓存音频；循环使用独立副本，不改动共享的原始资源。
	var key := path + (":loop" if looping else "")
	if _streams.has(key):
		return _streams[key]
	var loaded = load(path)
	if not loaded is AudioStream:
		return null
	var stream: AudioStream = loaded
	if looping:
		stream = _looped_copy(stream)
	_streams[key] = stream
	return stream


func prune_streams(keep_paths: Array) -> void:
	# 释放不再使用的循环流缓存（背景音乐体积较大）；一次性短音效继续缓存。
	for key in _streams.keys():
		var text := String(key)
		if text.ends_with(":loop") and not keep_paths.has(text.trim_suffix(":loop")):
			_streams.erase(key)


func clear_cache() -> void:
	_streams.clear()


func _absolute(relative: String) -> String:
	if relative.begins_with("res://") or relative.begins_with("user://"):
		return relative
	return asset_root.path_join(relative)


func _key(kind: String, target: String, phase: String) -> String:
	return "%s|%s|%s" % [kind, target, phase]


func _rebuild_index() -> void:
	_scape_index.clear()
	for row in soundscapes:
		var kind := String(row.get("context_kind", ""))
		var target := "" if kind == "title" else String(row.get("target_ref", ""))
		_scape_index[_key(kind, target, String(row.get("phase_ref", "")))] = row


func _merge_control(target: Dictionary, incoming: Dictionary, found: Array[String]) -> void:
	for key in ["bgm_crossfade_ms", "ambient_fade_ms"]:
		if incoming.has(key):
			var value := int(incoming[key])
			if value < MIN_FADE_MS or value > MAX_FADE_MS:
				found.append("总控 %s 超出 0-5000：%s" % [key, str(incoming[key])])
			target[key] = value
	if incoming.has("menu_bgm_factor"):
		var factor := float(incoming["menu_bgm_factor"])
		if factor < 0.0 or factor > 1.0:
			found.append("总控 menu_bgm_factor 超出 0-1：" + str(factor))
		target["menu_bgm_factor"] = factor


func _add_resource(target: Dictionary, record: Dictionary, found: Array[String]) -> void:
	var identity := String(record.get("id", ""))
	if identity.is_empty() or target.has(identity):
		found.append("声音资源 id 为空或重复：" + identity)
		return
	if not BUS_KINDS.has(String(record.get("bus", ""))):
		found.append("声音资源 %s 的类别无效" % identity)
		return
	var reference := String(record.get("resource_ref", ""))
	var path := String(record.get("resource_path", ""))
	if not reference.is_empty() and not path.is_empty():
		found.append("声音资源 %s 不能同时填写 resource_ref 与 resource_path" % identity)
		return
	target[identity] = {"id": identity, "bus": String(record["bus"]), "resource_ref": reference, "resource_path": path}


func _add_event(target: Dictionary, record: Dictionary, found: Array[String]) -> void:
	var identity := String(record.get("id", ""))
	if identity.is_empty() or target.has(identity):
		found.append("声音事件 id 为空或重复：" + identity)
		return
	var gain := float(record.get("event_gain", 1.0))
	if not BUS_KINDS.has(String(record.get("bus", ""))) or not SOURCE_KINDS.has(String(record.get("source_kind", ""))) or gain < 0.0 or gain > 1.0:
		found.append("声音事件 %s 的类别、来源方式或增益无效" % identity)
		return
	target[identity] = {
		"id": identity, "bus": String(record["bus"]), "source_kind": String(record["source_kind"]),
		"resource_key": String(record.get("resource_key", "")), "loop": bool(record.get("loop", false)), "event_gain": gain,
	}


func _check_cross_references(next_resources: Dictionary, next_events: Dictionary, next_scapes: Array, found: Array[String]) -> void:
	# 事件的固定资源、音景的轨道键必须引用存在且类别一致的资源；音景组合不可重复。
	for event in next_events.values():
		var key: String = event["resource_key"]
		if event["source_kind"] == "fixed":
			if not next_resources.has(key) or next_resources[key]["bus"] != event["bus"]:
				found.append("事件 %s 的固定资源 %s 不存在或类别不一致" % [event["id"], key])
		elif not key.is_empty():
			found.append("动态事件 %s 的 resource_key 必须留空" % event["id"])
	var seen := {}
	for row in next_scapes:
		var kind := String(row.get("context_kind", ""))
		if not CONTEXT_KINDS.has(kind):
			found.append("音景 %s 的上下文类型无效" % String(row.get("id", "")))
			continue
		var target := "" if kind == "title" else String(row.get("target_ref", ""))
		if kind != "title" and target.is_empty():
			found.append("音景 %s 缺少 target_ref" % String(row.get("id", "")))
		var combination := _key(kind, target, String(row.get("phase_ref", "")))
		if seen.has(combination):
			found.append("音景组合重复：" + combination)
		seen[combination] = true
		for pair in [["bgm_key", "bgm"], ["ambient_key", "ambient"]]:
			var resource_key := String(row.get(pair[0], ""))
			if not resource_key.is_empty() and (not next_resources.has(resource_key) or next_resources[resource_key]["bus"] != pair[1]):
				found.append("音景 %s 的 %s 必须引用类别为 %s 的资源" % [String(row.get("id", "")), pair[0], pair[1]])


static func _looped_copy(stream: AudioStream) -> AudioStream:
	# 生成带循环标记的副本。WAV 的终点按“时长×采样率”计算，兼容 QOA 等压缩导入格式。
	if stream is AudioStreamWAV:
		var wav := stream.duplicate() as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(round(wav.get_length() * wav.mix_rate))
		return wav
	if "loop" in stream:
		var copy := stream.duplicate() as AudioStream
		copy.set("loop", true)
		return copy
	return stream
