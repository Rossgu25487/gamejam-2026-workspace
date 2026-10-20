extends Node
## 声音播放服务：音景（BGM／环境循环）、操作音、结果与配音、暂停与失焦恢复、设置试听。
## 页面和玩法只提交请求；本服务统一决定能否播放、如何衔接以及何时恢复，不推进剧情也不发起保存。

signal soundscape_changed(info: Dictionary) # 当前音景发生实际变化。
signal production_error(message: String) # 引用非空但资源缺失等制作错误，不会替换为其他曲目。

const CatalogScript = preload("res://systems/audio/audio_catalog.gd")
const DEFAULT_CONFIG := "res://data/audio/audio_config.json"
const UI_EVENTS := {"click": "SND_UI_CLICK", "confirm": "SND_UI_CONFIRM", "feedback": "SND_UI_FEEDBACK"}
const PREVIEW_EVENT := "SND_UI_FEEDBACK" # 试听复用既有反馈事件，不叠加普通点击音。
const SLOT_BUS := {"bgm": "bgm", "ambient": "ambient", "ui": "ui", "result": "result", "voice": "voice", "preview": "ui"}
# music 随菜单倍率保持播放；world 随暂停菜单冻结；ui 只受失焦影响。
const SLOT_CLASS := {"bgm": "music", "ambient": "world", "ui": "ui", "result": "world", "voice": "world", "preview": "ui"}
const BUS_OF_KIND := {"bgm": "BGM", "ambient": "Ambient", "ui": "Effect", "result": "Effect", "voice": "Effect"}
const VOLUME_KEY := {"bgm": "bgm_volume", "ambient": "ambient_volume", "ui": "effect_volume", "result": "effect_volume", "voice": "effect_volume"}
const MIN_LINEAR := 0.0001 # 与设置服务一致：0 对应约 -80 dB，而不是负无穷。
const HANDLED_LIMIT := 256 # 实例去重表上限，超出时丢弃最旧记录。
const ERROR_LIMIT := 64 # 保留的制作错误条数。
const POOL_LIMIT := 8 # 空闲播放器保留数量，其余释放。

enum Focus { ACTIVE, FROZEN, AWAITING_INPUT, UI_RESTORED }


class Track:
	## 一条正在使用的声音轨：持有播放器、淡化状态与实例身份。
	var slot := ""
	var klass := ""
	var bus_kind := ""
	var player: AudioStreamPlayer
	var path := ""
	var resource_key := "" # 逻辑曲目键（如 BGM_PHASE_*、BGM_FINALE_CREDITS_ENTRY），用于按真实实例记录完成；一次性音为空。
	var loop := false
	var event_gain := 1.0
	var instance_id := ""
	var fade_value := 1.0 # 淡化曲线当前值 0-1。
	var fade_mode := 0 # 0 无淡化，1 淡入，2 淡出。
	var fade_base := 1.0
	var fade_elapsed := 0.0
	var fade_total := 0.0
	var pan := 0.0 # 每个播放实例的声像，不改变共享Effect总线。
	var pan_bus := ""
	var panner: AudioEffectPanner
	var preserve_tail := false # 已落定收卡保留120ms自然音尾，不阻下一操作。

	func begin_fade(mode: int, total_ms: float) -> void:
		fade_mode = mode
		fade_base = fade_value
		fade_elapsed = 0.0
		fade_total = total_ms

	func step(delta_ms: float) -> bool:
		# 等功率曲线推进淡化，返回淡化是否已经完成；交叉淡化时总响度不会中途塌陷。
		if fade_mode == 0:
			return true
		fade_elapsed += delta_ms
		var progress := clampf(fade_elapsed / maxf(fade_total, 0.001), 0.0, 1.0)
		if fade_mode == 1:
			fade_value = sin(progress * PI * 0.5)
		else:
			fade_value = fade_base * cos(progress * PI * 0.5)
		if progress >= 1.0:
			fade_value = 1.0 if fade_mode == 1 else 0.0
			fade_mode = 0
			return true
		return false


var catalog: RefCounted # 声音配置目录。
var settings := {"master_volume": 100, "bgm_volume": 70, "ambient_volume": 60, "effect_volume": 80, "mute": false}
var settings_ready := false # 首次收到已生效设置前不播放音景。
var session_id := 1 # 调查会话序号；失效请求按它拒绝。
var menu_open := false # 暂停菜单（含其子页面）是否打开。
var focus_state := Focus.ACTIVE
var current_soundscape := {} # 最近一次实际生效的音景摘要。
var production_errors: Array[String] = []
var log_warnings := true # 制作错误是否同时写引擎警告；故意构造缺失资源的测试可关闭，避免污染标准错误输出。
var config_errors: Array[String] = []
var start_counts := {} # 槽位 -> 实际启动次数，供回归测试和诊断。

var _slots := {} # 槽位 -> {"active": Track, "outgoing": Track}
var _idle: Array[AudioStreamPlayer] = []
var _track_of := {} # 播放器实例号 -> Track
var _wanted := {} # 最近一次请求的音景上下文。
var _handled := {} # 已处理的实例 ID。
var _handled_order: Array[String] = []
var _serial := 0
var _tree: SceneTree
var _completed_narrative_tracks := {}


func _init() -> void:
	for slot in SLOT_BUS.keys():
		_slots[slot] = {"active": null, "outgoing": null}
		start_counts[slot] = 0


func _ready() -> void:
	set_process(false) # 只有淡化进行时才需要逐帧推进。


func _exit_tree() -> void:
	shutdown()


func setup(config_path := DEFAULT_CONFIG, extra_paths: Array = [], asset_root := "res://", refs := {}) -> bool:
	# 加载声音配置并确保音频总线存在；extra_paths 用于叠加 EX 测试夹具或试听配置，同时自动挂载备用音效库。
	_ensure_buses()
	catalog = CatalogScript.new()
	catalog.asset_root = asset_root
	catalog.ref_table = refs.duplicate()
	catalog.load_sfx_library()
	var ok: bool = catalog.load_file(config_path)
	for path in extra_paths:
		ok = catalog.load_file(String(path), true) and ok
	config_errors = catalog.errors.duplicate()
	return ok


func setup_package(package: RefCounted) -> bool:
	# 包内声音仍走同一目录校验、通道和播放器，数据直接来自声音工作簿。
	_ensure_buses()
	catalog = CatalogScript.new()
	catalog.asset_root = str(package.definition.root)
	for key in package.definition.get("resources", {}): catalog.ref_table[key] = package.resource_path(str(key))
	# 正式包（aurora）额外消费1020资源清单的 resource_overrides：把 MAP_PAWN_LAND/LIFT 等
	# 逻辑键登记到实际音频路径，而不是把逻辑键拼成路径。旧包无此方法时保持不变。
	if package.has_method("audio_resource_overrides"):
		var overrides: Dictionary = package.audio_resource_overrides()
		for key in overrides: catalog.ref_table[key] = overrides[key]
	var ok: bool = catalog.configure(package.audio_definition())
	config_errors = catalog.errors.duplicate()
	return ok

func shutdown() -> void:
	# 停止全部声音并释放缓存；退出场景树和测试收尾时调用。
	for slot in _slots.keys():
		_release(_slots[slot]["active"])
		_release(_slots[slot]["outgoing"])
	for track in _track_of.values().duplicate(): _release(track)
	for player in _idle:
		if is_instance_valid(player):
			player.queue_free()
	_idle.clear()
	_track_of.clear()
	if catalog != null:
		catalog.clear_cache()
	if _tree != null and _tree.node_added.is_connected(_on_node_added):
		_tree.node_added.disconnect(_on_node_added)
	_tree = null
	set_process(false)


# ---------- 设置与音量 ----------

static func final_multiplier(values: Dictionary, bus_kind: String, event_gain: float, play_factor: float) -> float:
	# 最终输出倍率 = 事件增益 × 总音量/100 × 分项音量/100 × 播放系数；静音时为 0。
	if bool(values.get("mute", false)):
		return 0.0
	var category := float(values.get(VOLUME_KEY[bus_kind], 100)) / 100.0
	var master := float(values.get("master_volume", 100)) / 100.0
	return clampf(event_gain, 0.0, 1.0) * master * category * clampf(play_factor, 0.0, 1.0)


func bind_resource(resource_id: String, resource_path: String) -> bool:
	# 为尚未采用素材的资源临时指定文件（开发试听与试玩台使用）；资源键不存在时返回 false。
	return catalog != null and catalog.bind_resource(resource_id, resource_path)


func apply_settings(values: Dictionary) -> void:
	# 只读取已生效的会话值；设置文件写入失败也继续使用这些值。
	for key in ["master_volume", "bgm_volume", "ambient_volume", "effect_volume"]:
		if values.has(key):
			settings[key] = clampi(int(values[key]), 0, 100)
	if values.has("mute"):
		settings["mute"] = bool(values["mute"])
	_apply_buses()
	var first := not settings_ready
	settings_ready = true
	_refresh_volumes()
	if first and not _wanted.is_empty():
		_apply_soundscape(false)


func output_multiplier(slot: String) -> float:
	# 指定槽位当前轨道应有的最终输出倍率（含淡化），用于诊断与测试。
	var track: Track = _slots[slot]["active"]
	if track == null:
		return 0.0
	return final_multiplier(settings, track.bus_kind, track.event_gain, _play_factor(track)) * track.fade_value


func effective_linear(slot: String) -> float:
	# 由实际播放器和总线音量反算的真实输出倍率；应与 output_multiplier 一致。
	var track: Track = _slots[slot]["active"]
	if track == null or track.player == null:
		return 0.0
	var db: float = track.player.volume_db
	db += AudioServer.get_bus_volume_db(AudioServer.get_bus_index(String(track.player.bus)))
	if not track.pan_bus.is_empty():
		db += AudioServer.get_bus_volume_db(AudioServer.get_bus_index(BUS_OF_KIND[track.bus_kind]))
	db += AudioServer.get_bus_volume_db(0)
	return db_to_linear(db)


# ---------- 音景 ----------

func set_soundscape(kind: String, target_ref := "", phase_ref := "", rebuild := false) -> Dictionary:
	# 请求当前标题／场景／结局音景。设置就绪前只记录，不播放；rebuild 用于读档后从头重建。
	if catalog == null:
		return {"status": "disabled"}
	_wanted = {"kind": kind, "target": target_ref, "phase": phase_ref}
	if not settings_ready:
		return {"status": "pending"}
	return _apply_soundscape(rebuild)


func stop_soundscape() -> void:
	# 停止 BGM 与环境循环（淡出后停止）。
	_wanted = {}
	_set_loop("bgm", "", false)
	_set_loop("ambient", "", false)
	current_soundscape = {}

func set_narrative_soundscape(bgm_key: String, rebuild: bool = false) -> void:
	# 章场已在配置层解析；相同曲目沿现有轨道延续，空引用明确停曲。
	# 调查与片尾 BGM 均为单次播放，播完后同阶段不重起；环境循环由 ambient 槽独立维护。
	if catalog == null or not settings_ready: return
	_wanted = {}
	var ending := bgm_key == "BGM_FINALE_CREDITS_ENTRY"
	if rebuild: _completed_narrative_tracks.erase(bgm_key)
	if _completed_narrative_tracks.has(bgm_key): return
	_set_loop("bgm", bgm_key, rebuild, false)
	var track: Track = _slots["bgm"]["active"]
	if track != null: track.klass = "world" if ending else "music"; _apply_pause(track)
	_set_loop("ambient", "", false)
	current_soundscape = {"kind": "narrative", "bgm": _active_path("bgm"), "ambient": ""}


func _apply_soundscape(rebuild: bool) -> Dictionary:
	var row: Dictionary = catalog.match_soundscape(String(_wanted["kind"]), String(_wanted["target"]), String(_wanted["phase"]))
	var result := {"status": "ok", "soundscape": String(row.get("id", "")), "bgm": "", "ambient": ""}
	if row.is_empty():
		# 没有匹配音景：停止对应通道。正式音景为 0 行时整体静音。
		result["status"] = "unmatched"
		result["bgm"] = _set_loop("bgm", "", rebuild)
		result["ambient"] = _set_loop("ambient", "", rebuild)
	else:
		result["bgm"] = _set_loop("bgm", String(row.get("bgm_key", "")), rebuild)
		result["ambient"] = _set_loop("ambient", String(row.get("ambient_key", "")), rebuild)
	catalog.prune_streams(_live_paths())
	var summary := {
		"id": result["soundscape"], "kind": _wanted["kind"], "target": _wanted["target"], "phase": _wanted["phase"],
		"bgm": _active_path("bgm"), "ambient": _active_path("ambient"),
	}
	if summary != current_soundscape:
		current_soundscape = summary
		soundscape_changed.emit(summary.duplicate())
	return result


func _set_loop(slot: String, resource_key: String, rebuild: bool, looping: bool = true) -> String:
	# 更新一条循环轨：空键停轨；同资源延续；不同资源交叉淡化；无效资源保留原声并记录错误。
	var active: Track = _slots[slot]["active"]
	if resource_key.is_empty():
		if active != null:
			_retire_active(slot, _fade_ms(slot))
			_update_processing()
			return "stopped"
		return "empty"
	var info: Dictionary = catalog.resource_state(resource_key)
	if info["state"] == catalog.STATE_UNBOUND:
		return "unbound"
	if info["state"] == catalog.STATE_MISSING:
		_report("音景资源缺失：%s（%s）" % [resource_key, info["path"]])
		return "missing"
	var path: String = info["path"]
	if active != null and active.path == path and active.loop == looping and not rebuild:
		return "same"
	var stream: AudioStream = catalog.get_stream(path, looping)
	if stream == null:
		_report("无法读取音频：" + path)
		return "missing"
	_start_loop(slot, path, stream, _event_gain(slot), looping, resource_key)
	return "started"


func _start_loop(slot: String, path: String, stream: AudioStream, gain: float, looping: bool = true, resource_key: String = "") -> void:
	var fade_ms := _fade_ms(slot)
	_retire_active(slot, fade_ms)
	var track := _create_track(slot, path, stream, gain, looping, resource_key)
	if fade_ms > 0:
		track.fade_value = 0.0
		track.begin_fade(1, float(fade_ms))
	_slots[slot]["active"] = track
	_refresh_volume(track)
	track.player.play()
	_apply_pause(track)
	start_counts[slot] += 1
	_update_processing()


func _retire_active(slot: String, fade_ms: int) -> void:
	# 当前轨让位：每个通道最多两轨，更旧的淡出轨立即停止。
	var entry: Dictionary = _slots[slot]
	var old: Track = entry["active"]
	if old == null:
		return
	_release(entry["outgoing"])
	entry["active"] = null
	if fade_ms <= 0:
		_release(old)
		return
	entry["outgoing"] = old
	old.begin_fade(2, float(fade_ms))


func _fade_ms(slot: String) -> int:
	return int(catalog.control["bgm_crossfade_ms"] if slot == "bgm" else catalog.control["ambient_fade_ms"])


func _event_gain(slot: String) -> float:
	var event_key := "SND_SCENE_BGM" if slot == "bgm" else "SND_SCENE_AMBIENT"
	return float(catalog.events.get(event_key, {}).get("event_gain", 1.0))


# ---------- 事件 ----------

func begin_session() -> void:
	# 新调查或读档成功：旧会话请求失效，去重表清空，节点声音与配音停止；不补播历史声音。
	session_id += 1
	_completed_narrative_tracks.clear()
	_handled.clear()
	_handled_order.clear()
	stop_node_media()
	for track in _track_of.values().duplicate():
		if track.preserve_tail: _release(track)


func stop_node_media() -> void:
	# 换节点或离开会话：停止旧的结果／节点声音与配音。
	_release(_slots["result"]["active"])
	_release(_slots["voice"]["active"])
	for track in _track_of.values().duplicate():
		if track.slot in ["result", "voice"]: _release(track)

func export_narrative_media(key: String) -> Dictionary:
	var track: Track = _slots["bgm"]["active"]
	return {"key": key, "position": track.player.get_playback_position() if track != null else 0.0,
		"completed": _completed_narrative_tracks.has(key)}

func restore_narrative_media(data: Dictionary) -> void:
	var key := str(data.get("key", ""))
	if data.get("completed", false):
		_completed_narrative_tracks[key] = true
		_set_loop("bgm", "", false)
		return
	set_narrative_soundscape(key, true)
	var track: Track = _slots["bgm"]["active"]
	if track != null:
		track.player.seek(clampf(float(data.get("position", 0)), 0, track.player.stream.get_length()))


func play_ui(kind: String, instance_id := "") -> Dictionary:
	# 普通点击、确认、文件反馈；未传实例 ID 时每次调用视为新实例。
	if not UI_EVENTS.has(kind):
		return {"status": "unknown", "event": kind}
	var identity := instance_id
	if identity.is_empty():
		_serial += 1
		identity = "ui/%d" % _serial
	return request_event(UI_EVENTS[kind], identity)


func play_result(instance_id: String, ref: String, options := {}) -> Dictionary:
	return request_event("SND_RESULT", instance_id, ref, options)


func play_node_sound(instance_id: String, ref: String, options := {}) -> Dictionary:
	return request_event("SND_NODE_SOUND", instance_id, ref, options)


func play_voice(instance_id: String, ref: String, options := {}) -> Dictionary:
	return request_event("SND_NODE_VOICE", instance_id, ref, options)


func play_sfx(sfx_ref: String, slot := "", instance_id := "", options := {}) -> Dictionary:
	# 备用音效库快捷播放：任意模块可传入标准 ID（如 SFX_AVAIL_DIALOGUE_SHOW）、中文／简写名（如 对白显示音效、bookFlip1）或路径。
	# 未传 slot 时按条目推荐通道（ui 或 result）播放；未传 instance_id 时每次视为新请求。
	if catalog == null:
		return {"status": "unknown", "ref": sfx_ref}
	var target_slot := slot.strip_edges()
	if target_slot.is_empty():
		var entry: Dictionary = catalog.sfx_entry(sfx_ref)
		target_slot = String(catalog.resources.get(sfx_ref, entry).get("bus", "result"))
	if target_slot == "preview":
		return preview_sfx(sfx_ref)
	var identity := instance_id
	if identity.is_empty():
		_serial += 1
		identity = "sfx/%d" % _serial
	if target_slot == "ui":
		return _play_dynamic_ui(sfx_ref, identity, options)
	if target_slot == "voice":
		return request_event("SND_NODE_VOICE", identity, sfx_ref, options)
	return request_event("SND_RESULT", identity, sfx_ref, options)


func _play_dynamic_ui(sfx_ref: String, instance_id: String, options := {}) -> Dictionary:
	# 界面通道动态播放一次备用音效：受失焦、静音与效果音音量约束，在暂停菜单中仍可发声。
	var result := {"status": "unknown", "event": "SND_SFX_UI", "instance": instance_id}
	if int(options.get("session", session_id)) != session_id:
		result["status"] = "stale"
		return result
	if not instance_id.is_empty() and _handled.has(instance_id):
		result["status"] = "duplicate"
		return result
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		result["status"] = "frozen"
		return result
	if sfx_ref.is_empty():
		_mark_handled(instance_id)
		result["status"] = "empty"
		return result
	var info: Dictionary = _dynamic_resource(sfx_ref, "ui")
	if info["state"] == catalog.STATE_UNBOUND:
		_mark_handled(instance_id)
		result["status"] = "unbound"
		return result
	if info["state"] == catalog.STATE_MISSING:
		_mark_handled(instance_id)
		_report("声音资源缺失：SND_SFX_UI（%s）" % info["path"])
		result["status"] = "missing"
		return result
	if final_multiplier(settings, "ui", float(options.get("gain", 1.0)), 1.0) <= 0.0:
		_mark_handled(instance_id)
		result["status"] = "silent"
		return result
	var playback: Dictionary = options.duplicate()
	if sfx_ref == "SFX_CARD_COLLECT": playback.preserve_tail = true
	var started := _start_one_shot("ui", String(info["path"]), float(options.get("gain", 1.0)), instance_id, playback)
	_mark_handled(instance_id)
	result["status"] = started["status"]
	return result


func list_sfx(pack_filter := "", category_filter := "", query := "") -> Array:
	# 按来源包、分类和关键词查询备用音效条目列表。
	if catalog == null:
		return []
	return catalog.filter_sfx(pack_filter, category_filter, query)


func sfx_info(sfx_ref: String) -> Dictionary:
	# 查询单条备用音效的完整元信息与当前就绪状态。
	if catalog == null:
		return {}
	var entry: Dictionary = catalog.sfx_entry(sfx_ref).duplicate(true)
	var bus := String(entry.get("bus", "result"))
	var info: Dictionary = catalog.describe(sfx_ref, String(entry.get("path", "")), bus)
	entry["state"] = info["state"]
	entry["resolved_path"] = info["path"]
	return entry


func sfx_summary() -> Dictionary:
	# 返回备用音效库统计摘要（总数、就绪数、来源包、分类），供管理界面与诊断使用。
	if catalog == null:
		return {"total": 0, "ready": 0, "packs": [], "categories": []}
	var ready := 0
	for entry in catalog.sfx_entries:
		var info: Dictionary = catalog.describe("", String(entry.get("path", "")), String(entry.get("bus", "result")))
		if info["state"] == catalog.STATE_READY:
			ready += 1
	return {
		"total": catalog.sfx_entries.size(),
		"ready": ready,
		"packs": catalog.sfx_packs.duplicate(true),
		"categories": catalog.sfx_categories.duplicate(true),
	}


func request_media(request: Dictionary) -> Dictionary:
	# 玩法、剧情、猫互动、结局等模块的统一入口：
	# 既支持 {"event": 事件键, "instance": 实例ID, "ref": 资源引用, "session": 会话号}，
	# 也支持 {"sfx": 备用音效ID或名称, "slot": "ui"/"result", "instance": 实例ID, "session": 会话号}。
	if request.get("command") == "stop_node":
		stop_node_media()
		return {"status": "stopped"}
	if request.get("command") == "set_pan":
		return set_instance_pan(str(request.get("instance", "")), request.get("pan", 0.0))
	var options := {}
	# 逐字提示等可丢弃声音不能打断正在播放的剧情声音，也不能排队补播。
	if request.get("options", {}) is Dictionary and request.get("options", {}).get("drop_if_busy", false) is bool:
		options["drop_if_busy"] = bool(request.get("options", {}).get("drop_if_busy", false))
	if request.has("gain"):
		var request_gain = request.gain
		if not (request_gain is int or request_gain is float) or not is_finite(float(request_gain)) or request_gain < 0.0 or request_gain > 1.0: return {"status": "invalid_gain"}
		options["gain"] = float(request_gain)
	if request.has("session"):
		options["session"] = request["session"]
	if request.has("pan"):
		if not _valid_pan(request.pan): return {"status": "invalid_pan"}
		options["pan"] = float(request.pan)
	if request.has("sfx") or String(request.get("event", "")) == "SND_SFX":
		var ref_key := String(request.get("sfx", request.get("ref", "")))
		return play_sfx(ref_key, String(request.get("slot", "")), String(request.get("instance", "")), options)
	return request_event(String(request.get("event", "")), String(request.get("instance", "")), String(request.get("ref", "")), options)


func request_event(event_key: String, instance_id := "", ref := "", options := {}) -> Dictionary:
	# 一次事件请求：按会话、实例、时点、资源、音量依次检查，通过后沿对应轨道播放一次。
	var result := {"status": "unknown", "event": event_key, "instance": instance_id}
	if catalog == null:
		return result
	var event: Dictionary = catalog.events.get(event_key, {})
	if event.is_empty() or not ["ui", "result", "voice"].has(String(event["bus"])):
		return result
	if int(options.get("session", session_id)) != session_id:
		result["status"] = "stale" # 对象已离开当前会话，拒绝且不排队。
		return result
	if not instance_id.is_empty() and _handled.has(instance_id):
		result["status"] = "duplicate" # 同一实例只处理一次。
		return result
	var slot: String = String(event["bus"])
	var active: Track = _slots[slot]["active"]
	if bool(options.get("drop_if_busy", false)) and active != null and is_instance_valid(active.player) and active.player.playing:
		_mark_handled(instance_id)
		result["status"] = "busy"
		return result
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		result["status"] = "frozen" # 失焦期间的新请求过早，不排队补播。
		return result
	if SLOT_CLASS[slot] == "world" and menu_open:
		result["status"] = "held" # 菜单中世界声音不建立新实例。
		return result
	var info: Dictionary
	if event["source_kind"] == "fixed":
		info = catalog.resource_state(String(event["resource_key"]))
	elif ref.is_empty():
		_mark_handled(instance_id)
		result["status"] = "empty" # 可选引用为空：不建立声音，正文和操作保持完整。
		return result
	else:
		info = _dynamic_resource(ref, slot)
	if info["state"] == catalog.STATE_UNBOUND:
		_mark_handled(instance_id)
		result["status"] = "unbound" # 用途已定、素材未采用：当前不发声。
		return result
	if info["state"] == catalog.STATE_MISSING:
		_mark_handled(instance_id)
		_report("声音资源缺失：%s（%s）" % [event_key, info["path"]])
		result["status"] = "missing"
		return result
	var gain := float(event["event_gain"]) * float(options.get("gain", 1.0))
	if final_multiplier(settings, slot, gain, 1.0) <= 0.0:
		_mark_handled(instance_id)
		result["status"] = "silent" # 静音或分项为 0：不播放，也不在恢复后补播。
		return result
	var playback: Dictionary = options.duplicate()
	if ref == "SFX_CARD_COLLECT": playback.preserve_tail = true
	var started := _start_one_shot(slot, String(info["path"]), gain, instance_id, playback)
	_mark_handled(instance_id)
	result["status"] = started["status"]
	return result


func _dynamic_resource(ref: String, slot: String) -> Dictionary:
	# 交付表的SFX_*是资源逻辑键；先沿声音资源表取实际路径，保留未绑定状态。
	return catalog.resource_state(ref) if catalog.resources.has(ref) else catalog.describe(ref, "", slot)


func _valid_pan(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= -1.0 and float(value) <= 1.0


func set_instance_pan(instance_id: String, value: Variant) -> Dictionary:
	# 只更新仍存活的准确声音实例；陈旧的动画不能移动后来开始的声音。
	if not _valid_pan(value): return {"status": "invalid_pan"}
	if instance_id.is_empty(): return {"status": "stale"}
	for track in _track_of.values():
		if track.instance_id == instance_id:
			_apply_instance_pan(track, float(value))
			return {"status": "updated"}
	return {"status": "stale"}


func _apply_instance_pan(track: Track, value: float) -> void:
	if track.panner == null:
		# 独立子总线只服务当前实例，回收时删除，不影响其他UI声音。
		track.pan_bus = "AuroraPan_%d_%d" % [get_instance_id(), track.player.get_instance_id()]
		AudioServer.add_bus()
		var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, track.pan_bus)
		AudioServer.set_bus_send(index, BUS_OF_KIND[track.bus_kind])
		track.panner = AudioEffectPanner.new()
		AudioServer.add_bus_effect(index, track.panner)
		track.player.bus = track.pan_bus
	track.pan = clampf(value, -1.0, 1.0)
	track.panner.pan = track.pan


func _start_one_shot(slot: String, path: String, gain: float, instance_id: String, options := {}) -> Dictionary:
	var stream: AudioStream = catalog.get_stream(path, false)
	if stream == null:
		_report("无法读取音频：" + path)
		return {"status": "missing"}
	var previous: Track = _slots[slot]["active"]
	if previous != null and previous.preserve_tail:
		_slots[slot]["active"] = null # 声音实例继续自然结束；不占后续操作的当前轨。
	else:
		_release(previous) # 普通一次音仍沿既有替换规则。
	var track := _create_track(slot, path, stream, gain, false)
	track.instance_id = instance_id
	track.preserve_tail = bool(options.get("preserve_tail", false))
	if options.has("pan"): _apply_instance_pan(track, float(options.pan))
	_slots[slot]["active"] = track
	_refresh_volume(track)
	track.player.play()
	_apply_pause(track)
	start_counts[slot] += 1
	return {"status": "played"}


func _mark_handled(instance_id: String) -> void:
	if instance_id.is_empty() or _handled.has(instance_id):
		return
	_handled[instance_id] = true
	_handled_order.append(instance_id)
	if _handled_order.size() > HANDLED_LIMIT:
		_handled.erase(_handled_order.pop_front())


# ---------- 试听 ----------

func preview_state() -> Dictionary:
	# 试听条件按顺序检查：静音、总音量、效果音、资源就绪；返回功能文字键作为禁用原因。
	if bool(settings.get("mute", false)):
		return {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_MUTED"}
	if int(settings.get("master_volume", 0)) <= 0:
		return {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_MASTER_ZERO"}
	if int(settings.get("effect_volume", 0)) <= 0:
		return {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_EFFECT_ZERO"}
	if catalog == null:
		return {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_UNREADY"}
	var event: Dictionary = catalog.events.get(PREVIEW_EVENT, {})
	var info: Dictionary = catalog.resource_state(String(event.get("resource_key", "")))
	if info["state"] != catalog.STATE_READY:
		return {"enabled": false, "reason": "UI_SETTINGS_PREVIEW_UNREADY"}
	return {"enabled": true, "reason": ""}


func preview_effect() -> Dictionary:
	# 满足条件后只发一次既有反馈事件；新试听替换旧试听，离开设置时停止。
	var state := preview_state()
	if not state["enabled"]:
		return {"status": "disabled", "reason": state["reason"]}
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		return {"status": "frozen"}
	var event: Dictionary = catalog.events[PREVIEW_EVENT]
	var info: Dictionary = catalog.resource_state(String(event["resource_key"]))
	return _start_one_shot("preview", String(info["path"]), float(event["event_gain"]), "")


func preview_sfx(sfx_ref: String, gain := 1.0) -> Dictionary:
	# 音效管理界面专用试听：按总音量、效果音与静音条件检查，在 preview 通道播放指定备用音效，新试听替换旧试听。
	if bool(settings.get("mute", false)):
		return {"status": "disabled", "reason": "UI_SETTINGS_PREVIEW_MUTED"}
	if int(settings.get("master_volume", 0)) <= 0:
		return {"status": "disabled", "reason": "UI_SETTINGS_PREVIEW_MASTER_ZERO"}
	if int(settings.get("effect_volume", 0)) <= 0:
		return {"status": "disabled", "reason": "UI_SETTINGS_PREVIEW_EFFECT_ZERO"}
	if catalog == null:
		return {"status": "disabled", "reason": "UI_SETTINGS_PREVIEW_UNREADY"}
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		return {"status": "frozen"}
	var info: Dictionary = _dynamic_resource(sfx_ref, "ui")
	if info["state"] == catalog.STATE_UNBOUND:
		return {"status": "unbound"}
	if info["state"] == catalog.STATE_MISSING:
		_report("试听音效缺失：%s（%s）" % [sfx_ref, info["path"]])
		return {"status": "missing"}
	return _start_one_shot("preview", String(info["path"]), clampf(gain, 0.0, 1.0), sfx_ref)


func stop_preview() -> void:
	_release(_slots["preview"]["active"])


# ---------- 暂停、失焦与输入 ----------

func set_menu_open(open: bool) -> void:
	# 打开菜单：BGM 采用菜单倍率继续，环境与世界声音冻结；继续原调查后移除倍率并恢复。
	if menu_open == open:
		return
	menu_open = open
	if not open and focus_state == Focus.UI_RESTORED:
		focus_state = Focus.ACTIVE # 第二级恢复：所属流程已继续。
	_refresh_volumes()
	_apply_pause_states()
	_update_processing()


func notify_window_focus(has_focus: bool) -> void:
	# 窗口失焦：全部声音冻结；回焦后仍等待有效输入。
	if not has_focus:
		focus_state = Focus.FROZEN
	elif focus_state == Focus.FROZEN:
		focus_state = Focus.AWAITING_INPUT
	_apply_pause_states()
	_update_processing()


func notify_valid_input() -> void:
	# 回焦后的有效输入（由原界面接受，不绕过禁用或遮罩）：第一级恢复菜单／标题 BGM 与新界面声音。
	# 若不在暂停菜单中，输入本身就是所属流程的继续，同次完成两级恢复。
	if focus_state != Focus.AWAITING_INPUT:
		return
	focus_state = Focus.UI_RESTORED if menu_open else Focus.ACTIVE
	_apply_pause_states()
	_update_processing()


func attach_ui_hook(tree: SceneTree) -> void:
	# 全局按钮钩子：被接受的按钮操作触发有效输入恢复与普通点击音；meta ui_sound 可指定 confirm 或 none。
	if _tree != null:
		return
	_tree = tree
	tree.node_added.connect(_on_node_added)
	for button in tree.root.find_children("*", "BaseButton", true, false):
		_hook_button(button)


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		_hook_button(node)


func _hook_button(button: BaseButton) -> void:
	var handler := _on_button_pressed.bind(button)
	if not button.pressed.is_connected(handler):
		button.pressed.connect(handler)


func _on_button_pressed(button: BaseButton) -> void:
	notify_valid_input()
	var kind := String(button.get_meta("ui_sound", "click"))
	if kind != "none":
		play_ui(kind)


# ---------- 状态查询 ----------

func track_state(slot: String, outgoing := false) -> Dictionary:
	var track: Track = _slots[slot]["outgoing" if outgoing else "active"]
	if track == null or track.player == null:
		return {}
	return {
		"path": track.path, "paused": track.player.stream_paused, "volume_db": track.player.volume_db,
		"fade": track.fade_value, "loop": track.loop, "instance": track.instance_id, "bus": String(track.player.bus),
		"event_gain": track.event_gain,
		"pan": track.pan,
	}


func live_track_count(slot: String) -> int:
	var count := 0
	for key in ["active", "outgoing"]:
		if _slots[slot][key] != null:
			count += 1
	return count


func total_live_tracks() -> int:
	return _track_of.size()


func idle_player_count() -> int:
	return _idle.size()


# ---------- 内部：轨道与播放器 ----------

func advance(delta_ms: float) -> void:
	# 推进淡化。失焦冻结全部淡化；暂停菜单中环境轨的淡化保持原位。
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		return
	for slot in ["bgm", "ambient"]:
		for key in ["active", "outgoing"]:
			var track: Track = _slots[slot][key]
			if track == null or track.fade_mode == 0:
				continue
			if track.klass == "world" and menu_open:
				continue
			var fading_out := track.fade_mode == 2
			var done := track.step(delta_ms)
			_refresh_volume(track)
			if done and fading_out:
				_release(track)
	_update_processing()


func _process(delta: float) -> void:
	advance(delta * 1000.0)


func _update_processing() -> void:
	set_process(_has_runnable_fade())


func _has_runnable_fade() -> bool:
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		return false
	for slot in ["bgm", "ambient"]:
		for key in ["active", "outgoing"]:
			var track: Track = _slots[slot][key]
			if track != null and track.fade_mode != 0 and not (track.klass == "world" and menu_open):
				return true
	return false


func _create_track(slot: String, path: String, stream: AudioStream, gain: float, looping: bool, resource_key: String = "") -> Track:
	var track := Track.new()
	track.slot = slot
	track.klass = SLOT_CLASS[slot]
	track.bus_kind = SLOT_BUS[slot]
	track.path = path
	track.resource_key = resource_key
	track.loop = looping
	track.event_gain = gain
	var player := _acquire_player()
	player.stream = stream
	player.bus = BUS_OF_KIND[track.bus_kind]
	player.stream_paused = false
	track.player = player
	_track_of[player.get_instance_id()] = track
	return track


func _acquire_player() -> AudioStreamPlayer:
	if not _idle.is_empty():
		return _idle.pop_back()
	var player := AudioStreamPlayer.new()
	player.finished.connect(_on_player_finished.bind(player))
	add_child(player)
	return player


func _release(track: Track) -> void:
	# 停止并回收播放器；同时清除槽位引用。播放器复用，避免频繁创建和释放节点。
	if track == null or track.player == null:
		return
	var player := track.player
	player.stop()
	player.stream = null
	player.stream_paused = false
	if not track.pan_bus.is_empty():
		player.bus = BUS_OF_KIND[track.bus_kind]
		var pan_index := AudioServer.get_bus_index(track.pan_bus)
		if pan_index >= 0: AudioServer.remove_bus(pan_index)
		track.panner = null
		track.pan_bus = ""
	_track_of.erase(player.get_instance_id())
	track.player = null
	var entry: Dictionary = _slots[track.slot]
	if entry["active"] == track:
		entry["active"] = null
	if entry["outgoing"] == track:
		entry["outgoing"] = null
	if _idle.size() < POOL_LIMIT:
		_idle.append(player)
	else:
		player.queue_free()


func _on_player_finished(player: AudioStreamPlayer) -> void:
	# 一次性声音自然结束：清理轨道，继续时不补播。循环流若意外结束则重新开始。
	var track: Track = _track_of.get(player.get_instance_id())
	if track == null:
		return
	if track.loop:
		player.play()
	else:
		if track.slot == "bgm" and not track.resource_key.is_empty():
			_completed_narrative_tracks[track.resource_key] = true
		_release(track)


func _play_factor(track: Track) -> float:
	if menu_open and track.slot == "bgm":
		return float(catalog.control["menu_bgm_factor"])
	return 1.0


func _refresh_volume(track: Track) -> void:
	if track.player == null:
		return
	var linear := track.event_gain * track.fade_value * _play_factor(track)
	track.player.volume_db = linear_to_db(maxf(linear, MIN_LINEAR))


func _refresh_volumes() -> void:
	for track in _track_of.values():
		_refresh_volume(track)


func _should_pause(track: Track) -> bool:
	if focus_state == Focus.FROZEN or focus_state == Focus.AWAITING_INPUT:
		return true
	return track.klass == "world" and menu_open


func _apply_pause(track: Track) -> void:
	if track.player != null:
		track.player.stream_paused = _should_pause(track)


func _apply_pause_states() -> void:
	for track in _track_of.values():
		_apply_pause(track)


func _live_paths() -> Array:
	var paths: Array = []
	for track in _track_of.values():
		paths.append(track.path)
	return paths


func _active_path(slot: String) -> String:
	var track: Track = _slots[slot]["active"]
	return "" if track == null else track.path


func _ensure_buses() -> void:
	# 工程自带 default_bus_layout.tres；这里兜底，保证脱离布局文件也能运行。
	for bus_name in ["BGM", "Ambient", "Effect"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")


func _apply_buses() -> void:
	# 总音量与静音落在 Master；三个分项落在各自子总线。
	var master := 0.0 if settings["mute"] else float(settings["master_volume"]) / 100.0
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master, MIN_LINEAR)))
	for pair in [["BGM", "bgm_volume"], ["Ambient", "ambient_volume"], ["Effect", "effect_volume"]]:
		var index := AudioServer.get_bus_index(pair[0])
		if index != -1:
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(float(settings[pair[1]]) / 100.0, MIN_LINEAR)))


func _report(message: String) -> void:
	# 记录制作错误并通知；不会替换为随机曲目，也不影响业务结果。
	production_errors.append(message)
	if production_errors.size() > ERROR_LIMIT:
		production_errors.pop_front()
	if log_warnings:
		push_warning("[Audio] " + message)
	production_error.emit(message)
