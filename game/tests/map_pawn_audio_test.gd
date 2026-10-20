extends SceneTree
## 地图抬起/落下音效别名经1020资源清单 resource_overrides 解析为实际OGG并可播放。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Audio = preload("res://systems/audio/audio_service.gd")
var checks := 0
var failures: Array[String] = []

func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func run() -> void:
	var session := Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "正式配置成功载入")
	if not failures.is_empty(): session.queue_free(); quit(1); return
	var audio := Audio.new()
	root.add_child(audio)
	audio.log_warnings = false
	check(audio.setup_package(session.config), "正式声音工作簿可用")
	audio.apply_settings({"master_volume": 100, "effect_volume": 80, "mute": false})

	var overrides: Dictionary = session.config.audio_resource_overrides()
	check(overrides.has("MAP_PAWN_LAND") and overrides.has("SFX_MAP_LAND"), "资源清单登记落子别名：" + str(overrides.get("MAP_PAWN_LAND", "")))
	check(overrides.has("MAP_PAWN_LIFT") and overrides.has("SFX_MAP_LIFT"), "资源清单登记抬起别名：" + str(overrides.get("MAP_PAWN_LIFT", "")))
	for id in ["MAP_PAWN_LAND", "MAP_PAWN_LIFT"]:
		var path := str(overrides.get(id, ""))
		check(path.contains("assets/aurora/audio/") and ResourceLoader.exists(path), id + "迁移到实际OGG且可读：" + path)

	for resource_id in ["SFX_MAP_LAND", "SFX_MAP_LIFT"]:
		var info: Dictionary = audio.catalog.resource_state(resource_id)
		check(info.state == "ready" and ResourceLoader.exists(info.path), resource_id + "别名解析为ready：" + str(info.path))
		var resolved: String = audio.catalog.resolve_path(str(audio.catalog.resources[resource_id].get("resource_ref", "")), "")
		check(resolved == info.path and not resolved.is_empty(), resource_id + "逻辑ref与ready路径一致：" + resolved)

	for event_id in ["SND_MAP_LAND", "SND_MAP_LIFT"]:
		var reply: Dictionary = audio.request_media({"event": event_id, "instance": "formal/" + event_id})
		check(reply.status == "played", event_id + "真实播放：" + str(reply))
	check(audio.production_errors.is_empty(), "地图音效接入没有缺失或空路径警告：" + str(audio.production_errors))

	audio.shutdown()
	audio.queue_free()
	session.queue_free()
	await process_frame
	print("MAP_PAWN_AUDIO_PASS %d checks" % checks if failures.is_empty() else "MAP_PAWN_AUDIO_FAIL %d/%d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
