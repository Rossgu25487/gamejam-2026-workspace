extends SceneTree
## 正式特写与内嵌交谈的行为测试，不调用额外事件、不用虚构背景代替正式资源。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Conversation = preload("res://systems/aurora/aurora_conversation.gd")
const Page = preload("res://pages/narrative/narrative_page.gd")
var checks := 0
var failures: Array[String] = []
var session: Node

func _initialize() -> void: call_deferred("_run")
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label); push_error(label)
func frames(count: int = 4) -> void:
	for index in range(count): await process_frame

func _row(actor: String, position: String = "center", kind: String = "dialogue", clear: bool = false) -> Dictionary:
	return {"text_id": "TEST_" + actor, "character_id": actor, "position": position, "text_type": kind,
		"avatar_path": str(session.config.actors.get(actor, {}).get("default_portrait_path", "")),
		"background_path": session.background_path(), "embedded_actor_refs": ["CHR05", "CHR06"],
		"scene_layers": [{"character_id": actor}, {"character_id": "CHR07"}], "clear_positions": clear}

func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.content_scale_size = Vector2i(1600, 900)
	session = Session.new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "最终正式配置初始化")
	if not failures.is_empty(): quit(1); return
	session.case_state.reset()
	var page := Page.new()
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session.narrative)
	await frames()
	page.set_process(false)
	page.cutin.set_process(false)
	session.paused = false
	page.cutin.show_record({"text_id": "TXT_CAT_DRY_MARK_001"})
	check(page.cutin.current_id == "CUE_CAT_WATER_01" and page.cutin.is_blocking(), "猫第一页先显示水碟原位500ms")
	var first_texture: Texture2D = page.cutin.texture
	page.cutin._process(0.499)
	check(page.cutin.current_id == "CUE_CAT_WATER_01", "499ms不提前切猫图")
	session.paused = true
	page.cutin._process(1.0)
	check(page.cutin.current_id == "CUE_CAT_WATER_01", "暂停冻结猫特写")
	session.paused = false
	session.narrative.reading_log = true
	page.cutin._process(1.0)
	check(page.cutin.current_id == "CUE_CAT_WATER_01", "对白记录冻结猫特写")
	session.narrative.reading_log = false
	session.narrative.hidden = true
	page.cutin._process(1.0)
	check(page.cutin.current_id == "CUE_CAT_WATER_01", "隐藏阅读冻结猫特写")
	session.narrative.hidden = false
	page.cutin._process(0.002)
	check(page.cutin.current_id == "CUE_CAT_WATER_02" and not page.cutin.is_blocking(), "500ms后自动切泼水图并允许阅读")
	check(page.cutin.texture != first_texture, "猫前两帧使用不同已交PNG")
	page.cutin.show_record({"text_id": "TXT_CAT_DRY_MARK_002"})
	check(page.cutin.current_id == "CUE_CAT_WATER_03", "第二页切干印第三图")
	page.cutin.show_record({"text_id": "TXT_CAT_DRY_MARK_003"})
	page.cutin._process(100)
	check(page.cutin.current_id == "CUE_CAT_WATER_03" and page.cutin.visible, "第三图持续至猫观察完整结束")
	page.cutin.show_record({"text_id": "TXT_CH01_0001"})
	check(not page.cutin.visible, "离开彩蛋正文清特写")
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_001"})
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_003"})
	check(page.cutin.current_id == "CUE_YURI_MONEY", "尤里钞票特写持续至明确结束点")
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_004"})
	check(not page.cutin.visible, "结束引用之前清钞票特写")
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_015"})
	check(page.cutin.current_id == "CUE_YURI_HAND", "尤里握扳手绑定实际文本")
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_019"})
	check(not page.cutin.visible, "手部特写准确还原")
	page.cutin.show_record({"text_id": "TXT_CH03_YURI_MEMORY_CURRENT_021"})
	page.cutin._process(0.479)
	check(page.cutin.visible and page.cutin.is_blocking(), "扳手落下完整480ms前保持")
	page.cutin._process(0.002)
	check(not page.cutin.visible, "扳手落下480ms结束即还原")
	check(page.cutin.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "特写等比留边不裁线索")
	check(page.cutin.z_index > 3, "特写覆盖舞台所有人物层级")
	page.cutin.show_record({"text_id": "TXT_CAT_DRY_MARK_001"})
	page.cutin.bind(page)
	check(not page.cutin.visible and page.cutin.current_id.is_empty() and page.cutin.pending.is_empty(), "重绑页面清理旧镜头和队列")
	var conversation := Conversation.new()
	conversation.bind(session)
	session.case_state.data.scene = "SC07"
	session.case_state.data.view = "VIEW_SC07_MAIN"
	session.case_state.data.chapter = "CH02"
	session.case_state.data.npc.CHR05 = {"scene_id": "SC07"}
	session.case_state.data.npc.CHR06 = {"scene_id": "SC07"}
	session.active_entry = "ENTRY_CH02_COUPLE_INITIAL_TOGETHER"
	var state_before: Dictionary = session.case_state.data.duplicate(true)
	var vera := _row("CHR05", "left", "dialogue", true)
	conversation.apply(vera)
	check(str(vera.background_path).ends_with("SC07_与薇拉交谈_仅尤里在场.png"), "仅薇拉前景时只从底图移除薇拉")
	check(vera.embedded_actor_refs == ["CHR06"], "同机位背景继续保留尤里")
	check(vera.scene_layers.size() == 1 and vera.scene_layers[0].character_id == "CHR07", "清除前景重复图层并保留其他对象")
	var yuri := _row("CHR06", "right")
	yuri.scene_layers = [{"character_id": "CHR05"}, {"character_id": "CHR06"}, {"character_id": "CHR07"}]
	conversation.apply(yuri)
	check(str(yuri.background_path) == str(conversation.model.view_resource("VIEW_SC07_MAIN").resource_or_text_ref), "双方实际进入前景时选择同时去人的同机位图")
	check(yuri.embedded_actor_refs.is_empty() and yuri.scene_layers.size() == 1, "双人前景没有背景内重复人物")
	var leave := _row("CHR06", "", "inner")
	leave.exit_characters = ["CHR06"]
	conversation.apply(leave)
	check(str(leave.background_path).ends_with("SC07_与薇拉交谈_仅尤里在场.png"), "实际离前景后按剩余集合重新配图")
	var inner := _row("CHR01", "", "inner", true)
	session.return_context = {"object": "CHR05"}
	conversation.apply(inner)
	check(str(inner.background_path).ends_with("SC07_薇拉尤里_案后在场.png") and not inner.has("conversation_actor"), "纯心声保留母图，不因点击者拉出立绘")
	check(session.case_state.data == state_before, "背景配对不改变剧情实际人物地点")
	# 大厅与柜台两机位各用自己的无人图，尼娜真实位置一直是厨房。
	session.case_state.data.scene = "SC02"
	session.case_state.data.chapter = "CH01"
	session.case_state.data.npc.CHR03 = {"scene_id": "SC03"}
	session.active_entry = "ENTRY_CH01_SIDE_SCARF"
	for view in ["VIEW_SC02_MAIN", "VIEW_SC02_COUNTER"]:
		session.case_state.data.view = view
		conversation.clear()
		var nina := _row("CHR03", "center", "dialogue", true)
		conversation.apply(nina)
		check(nina.has("conversation_actor") and nina.conversation_actor.character_id == "CHR03", "尼娜真实对话使用中央独立立绘：" + view)
		check(str(nina.background_path).ends_with("SC02_大厅_厨房无人.png" if view == "VIEW_SC02_MAIN" else "SC02_柜台交接_厨房无人.png"), "尼娜采用当前机位配对：" + view)
		check(session.case_state.data.npc.CHR03.scene_id == "SC03", "尼娜表现不移往大厅：" + view)
		session.active_entry = "ENTRY_SC02_NINA_BUSY"
		var busy := _row("CHR01", "", "inner", true)
		conversation.apply(busy)
		check(not busy.has("conversation_actor") and not str(busy.background_path).ends_with("厨房无人.png"), "忙碌反馈不启临时人物/无人图：" + view)
		session.active_entry = "ENTRY_CH01_SIDE_SCARF"
	# 结案双胞胎只有观察，没有虚构新交谈。
	session.case_state.data.scene = "SC10"
	session.case_state.data.view = "VIEW_SC10_MAIN"
	session.case_state.data.chapter = "CH06"
	session.active_entry = "ENTRY_CLICK_CHR11_CH06_1717"
	var twins := _row("CHR01", "", "inner", true)
	conversation.apply(twins)
	check(str(twins.background_path).ends_with("SC10_兄弟并坐_结案后.png") and twins.position.is_empty(), "双胞胎结案观察保留同画面")
	# 临时走廊取景不搬动玩家或尤里。
	session.case_state.data.scene = "SC07"
	session.case_state.data.view = "VIEW_SC07_MAIN"
	session.case_state.data.npc.CHR06 = {"scene_id": "SC05"}
	session.active_entry = "ENTRY_CH06_COUPLE_FIRST"
	var door := _row("CHR01", "", "narration", true)
	door.text_id = "TXT_CH06_0109"
	conversation.apply(door)
	check(str(door.background_path).ends_with("SC05_尤里扶客房门框_在场.png"), "明确短演出切到门外扶框机位")
	check(session.case_state.data.scene == "SC07" and session.case_state.data.npc.CHR06.scene_id == "SC05", "短演出不改变caller及人物实际地点")
	var restored := _row("CHR01", "", "narration")
	restored.text_id = "TXT_CH06_0111"
	conversation.apply(restored)
	check(conversation.temporary_group.is_empty() and not str(restored.background_path).ends_with("SC05_尤里扶客房门框_在场.png"), "放手引用前准确退出临时取景")
	if "--capture" in OS.get_cmdline_user_args():
		session.case_state.data.scene = "SC02"
		session.case_state.data.view = "VIEW_SC02_MAIN"
		session.case_state.data.npc.CHR03 = {"scene_id": "SC03"}
		session.active_entry = "ENTRY_CH01_SIDE_SCARF"
		check(session.narrative.show_text("F7_CH01_SIDE_SCARF_001"), "实际文案页可播放尼娜交谈")
		await frames()
		session.narrative.advance()
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-conversation-nina.png"))
		check(session.narrative.show_text("TXT_CAT_DRY_MARK_002"), "实际文案页播放猫特写而非直接叠图")
		await frames()
		session.narrative.advance()
		await frames()
		check(page.cutin.current_id == "CUE_CAT_WATER_03" and page.cutin.get_index() == page.stage.get_child_count() - 1, "实际文本事件将特写提升至舞台上方")
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../.local/final-cutin-cat.png"))
	page.queue_free()
	session.queue_free()
	await frames()
	print("FINAL_CUTIN_CONVERSATION_PASS %d checks" % checks if failures.is_empty() else "FINAL_CUTIN_CONVERSATION_FAIL %d/%d" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
