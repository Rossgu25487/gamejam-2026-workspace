extends Control
## 声音试玩台：在 Godot 编辑器中打开本场景后按 F6 运行，可直接听十首古典乐与圣咏，
## 检查交叉淡化、菜单降音、失焦冻结与恢复、四项音量、静音、试听与单次声音的去重。
## 它使用正式的 AudioService 与试听配置，不属于正式游戏流程，也不会进入正式导出。

const AudioScript = preload("res://systems/audio/audio_service.gd")
const DEMO_CONFIG := "res://tests/fixtures/audio/audio_demo_config.json"
const MANIFEST := "res://tests/fixtures/music/manifest.json"
const PULSE := "res://tests/fixtures/design/basic/test_assets/audio/ex_bgm_pulse.wav"
const UI_SOUNDS := { # 试听用操作音，与开发运行的 Main 相同；正式配置里这三个资源尚未采用素材
	"SFX_UI_CLICK": "res://tests/fixtures/audio/ui_demo/ui_click.wav",
	"SFX_UI_CONFIRM": "res://tests/fixtures/audio/ui_demo/ui_confirm.wav",
	"SFX_UI_FEEDBACK": "res://tests/fixtures/audio/ui_demo/ui_feedback.wav",
}
const STATUS_INTERVAL := 0.2 # 状态面板的刷新间隔（秒），不逐帧刷新
const VOLUMES := [["master_volume", "总音量"], ["bgm_volume", "BGM 音量"], ["ambient_volume", "环境音量"], ["effect_volume", "效果音量"]]

@onready var side: VBoxContainer = $Side/Scroll/Box
@onready var credit: RichTextLabel = $Info/Column/Credit
@onready var status: Label = $Info/Column/Status
@onready var last: Label = $Info/Column/Last

var service: Node
var settings := {"master_volume": 100, "bgm_volume": 70, "ambient_volume": 60, "effect_volume": 80, "mute": false}
var manifest: Dictionary = {} # 音频文件名 -> 曲目清单条目
var scapes: Array = [] # 试听配置里的音景行
var resource_paths: Dictionary = {} # 试听配置里的资源键 -> 文件路径
var ui_bound := true
var request_count := 0
var session_at_start := 1
var last_text := "尚未操作"
var _elapsed := 0.0


func _ready() -> void:
	DisplayServer.window_set_title("声音试玩台")
	service = AudioScript.new()
	add_child(service)
	if not service.setup(AudioScript.DEFAULT_CONFIG, [DEMO_CONFIG]):
		push_warning("声音配置存在问题：" + str(service.config_errors))
	_load_manifest()
	_bind_ui(true)
	service.apply_settings(settings)
	service.attach_ui_hook(get_tree()) # 与正式游戏相同：被接受的按钮操作触发点击音与失焦后的有效输入恢复
	get_window().focus_exited.connect(service.notify_window_focus.bind(false))
	get_window().focus_entered.connect(service.notify_window_focus.bind(true))
	session_at_start = service.session_id
	_build()
	_refresh_status()


func _exit_tree() -> void:
	if service != null:
		service.shutdown()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= STATUS_INTERVAL:
		_elapsed = 0.0
		_refresh_status()


# ---------- 数据 ----------

func _load_manifest() -> void:
	var rows = _read_json(MANIFEST)
	if rows is Dictionary:
		for row in rows.get("tracks", []):
			manifest[String(row["file"])] = row
	var demo = _read_json(DEMO_CONFIG)
	if demo is Dictionary:
		scapes = demo.get("soundscapes", [])
		for row in demo.get("resources", []):
			resource_paths[String(row["id"])] = String(row["resource_path"])


func _read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text()) if file != null else null


func _manifest_row(resource_key: String) -> Dictionary:
	var path := String(resource_paths.get(resource_key, ""))
	return manifest.get(path.get_file(), {})


func _title_of(row: Dictionary) -> String:
	if row.is_empty():
		return "（无）"
	return "%s · %s" % [row["composer"], row["work"]]


func _bind_ui(on: bool) -> void:
	# 正式配置里三个 UI 效果尚未采用素材；试玩台临时绑定试听操作音，便于听到点击、确认与文件反馈。
	ui_bound = on
	for key in UI_SOUNDS:
		service.bind_resource(key, String(UI_SOUNDS[key]) if on else "")


# ---------- 界面 ----------

func _build() -> void:
	_title("声音试玩台")
	_note("右侧显示当前曲目的来源与授权，以及实时状态；所有按钮都会走正式的 AudioService。")
	_title("音景（点击即切换，同曲的场景之间不会重启）")
	for row in scapes:
		var label: String = "%s\n  BGM：%s" % [row["id"], _title_of(_manifest_row(String(row["bgm_key"])))]
		if not String(row["ambient_key"]).is_empty():
			label += "\n  环境：" + _title_of(_manifest_row(String(row["ambient_key"])))
		_button(label, _play_scape.bind(row))
	_button("停止音景（淡出）", _stop_scape)
	_title("音量与静音（先全局，再分项）")
	for pair in VOLUMES:
		_slider(String(pair[0]), String(pair[1]))
	_check("静音", false, func(on: bool): _change("mute", on))
	_title("暂停、失焦与恢复")
	_check("暂停菜单已打开（BGM 降为 50%，环境冻结）", false, func(on: bool): service.set_menu_open(on))
	_button("模拟窗口失焦（全部声音冻结）", func(): service.notify_window_focus(false))
	_button("模拟窗口回焦（仍等待有效输入）", func(): service.notify_window_focus(true))
	_button("模拟一次有效输入", func(): service.notify_valid_input())
	_title("单次声音（结果音与配音使用测试脉冲）")
	_check("三个 UI 效果绑定试听操作音（正式配置尚未采用素材）", true, func(on: bool): _bind_ui(on))
	_button("点击音", func(): _do("点击音", service.play_ui("click")))
	_button("确认音", func(): _do("确认音", service.play_ui("confirm")))
	_button("文件反馈音", func(): _do("文件反馈音", service.play_ui("feedback")))
	_button("结果音（新实例）", func(): _one_shot("结果音", "play_result"))
	_button("配音（新实例）", func(): _one_shot("配音", "play_voice"))
	_button("同一实例重复请求（只响一次）", _duplicate)
	_button("过期会话请求（应被拒绝）", func(): _do("过期会话请求", service.request_event("SND_RESULT", "bench/stale", PULSE, {"session": session_at_start - 1})))
	_button("新调查会话（旧请求失效）", _new_session)
	_title("设置页试听")
	_button("试听反馈音", func(): _do("试听", service.preview_effect()))
	_button("停止试听", func(): service.stop_preview())


func _title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(0.87, 0.78, 0.61))
	side.add_child(label)


func _note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 320
	side.add_child(label)


func _button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART # 曲名较长时换行，避免侧栏出现横向滚动
	button.pressed.connect(action)
	side.add_child(button)


func _check(text: String, value: bool, action: Callable) -> void:
	var check := CheckButton.new()
	check.text = text
	check.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	check.button_pressed = value
	check.toggled.connect(action)
	side.add_child(check)


func _slider(key: String, text: String) -> void:
	var label := Label.new()
	label.text = "%s：%d" % [text, int(settings[key])]
	side.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = int(settings[key])
	slider.custom_minimum_size.x = 320
	slider.value_changed.connect(func(value: float):
		label.text = "%s：%d" % [text, int(value)]
		_change(key, int(value)))
	side.add_child(slider)


# ---------- 操作 ----------

func _change(key: String, value: Variant) -> void:
	settings[key] = value
	service.apply_settings(settings)


func _play_scape(row: Dictionary) -> void:
	var result: Dictionary = service.set_soundscape(String(row["context_kind"]), String(row["target_ref"]), String(row["phase_ref"]))
	_do("音景 " + String(row["id"]), result)
	_show_credit()


func _stop_scape() -> void:
	service.stop_soundscape()
	_do("停止音景", "淡出后停止")
	_show_credit()


func _one_shot(text: String, method: String) -> void:
	request_count += 1
	_do(text, service.call(method, "bench/%d" % request_count, PULSE))


func _duplicate() -> void:
	_do("同一实例 bench/dup", service.play_result("bench/dup", PULSE))


func _new_session() -> void:
	service.begin_session()
	session_at_start = service.session_id
	_do("新调查会话", {"status": "ok", "session": service.session_id})


func _do(text: String, result: Variant) -> void:
	last_text = "%s -> %s" % [text, str(result)]
	_refresh_status()


# ---------- 状态 ----------

func _show_credit() -> void:
	var lines: Array[String] = []
	for slot in ["bgm", "ambient"]:
		var state: Dictionary = service.track_state(slot)
		if state.is_empty():
			continue
		var row: Dictionary = manifest.get(String(state["path"]).get_file(), {})
		if row.is_empty():
			lines.append("%s：%s" % [slot.to_upper(), state["path"]])
			continue
		lines.append("[b]%s[/b]  %s\n传统：%s\n演奏：%s\n授权：%s（%s）\n来源页面：%s\n截取：从 %.0f 秒起，共 %.0f 秒" % [slot.to_upper(), _title_of(row), row["tradition"], _clip(String(row["performer"])), row["license"], _clip(String(row["credit"])), row["page_url"], float(row["clip_start"]), float(row["clip_length"])])
	credit.text = "\n\n".join(lines) if not lines.is_empty() else "当前没有音景在播放。"


func _clip(text: String, limit := 120) -> String:
	# 维基共享资源的署名文字可能很长；面板里只显示开头，完整内容见清单与来源页面。
	var flat := text.replace("\n", " ")
	return flat if flat.length() <= limit else flat.substr(0, limit) + "…"


func _refresh_status() -> void:
	if service == null or status == null:
		return
	var lines: Array[String] = []
	var scape: Dictionary = service.current_soundscape
	lines.append("音景：%s" % (String(scape.get("id", "")) if not scape.is_empty() else "（无）"))
	for slot in ["bgm", "ambient"]:
		var state: Dictionary = service.track_state(slot)
		var out: Dictionary = service.track_state(slot, true)
		if state.is_empty():
			lines.append("%s：空闲" % slot.to_upper())
			continue
		lines.append("%s：%s  暂停=%s  淡化=%.2f  输出倍率=%.3f  实际=%.3f%s" % [slot.to_upper(), String(state["path"]).get_file(), state["paused"], float(state["fade"]), service.output_multiplier(slot), service.effective_linear(slot), "  （上一曲淡出中）" if not out.is_empty() else ""])
	lines.append("焦点状态：%s    菜单：%s    会话：%d" % [["正常", "失焦冻结", "等待有效输入", "已恢复界面声音"][int(service.focus_state)], "打开" if service.menu_open else "关闭", int(service.session_id)])
	lines.append("轨道：BGM %d / 环境 %d / UI %d / 结果 %d / 配音 %d / 试听 %d    活动总数 %d    空闲播放器 %d" % [service.live_track_count("bgm"), service.live_track_count("ambient"), service.live_track_count("ui"), service.live_track_count("result"), service.live_track_count("voice"), service.live_track_count("preview"), service.total_live_tracks(), service.idle_player_count()])
	lines.append("累计启动：%s" % str(service.start_counts))
	lines.append("制作错误：%d 条%s" % [service.production_errors.size(), "" if service.production_errors.is_empty() else "（" + service.production_errors[-1] + "）"])
	status.text = "\n".join(lines)
	last.text = "最近操作：" + last_text
	if credit.text.is_empty():
		credit.text = "点击左侧的音景开始试听。"
