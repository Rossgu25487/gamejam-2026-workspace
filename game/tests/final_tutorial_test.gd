extends SceneTree
## 引导行为回归：只读真实状态、按实际业务完成、取消不完成、原始几何命中与存档。
var failures: Array[String] = []
var checks := 0
class Pages extends Control:
	var scene_page: Control
	var card_page: Control
	var reader_page: Control
	var map_page: Control
	signal menu_requested
class Handbook extends Control:
	var reading_content := ""
	var selected_material := ""
class MapPage extends Control:
	var selected_group := "MAP01"

func _init() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("TUTORIAL_FAIL: " + message)
func run() -> void:
	var session := preload("res://systems/aurora/aurora_session.gd").new()
	root.add_child(session)
	session.seen_storage_path = ""
	check(session.initialize(), "最终包可载入")
	session.case_state.reset()
	session.run_id = "tutorial-test"
	session.mode = "investigation"
	var gameplay := Pages.new()
	root.add_child(gameplay)
	gameplay.size = Vector2(1600, 900)
	gameplay.scene_page = Control.new()
	gameplay.card_page = Control.new()
	gameplay.reader_page = Handbook.new()
	gameplay.map_page = MapPage.new()
	for page in [gameplay.scene_page, gameplay.card_page, gameplay.reader_page, gameplay.map_page]: gameplay.add_child(page)
	gameplay.reader_page.hide()
	gameplay.map_page.hide()
	var bridge := preload("res://systems/aurora/aurora_map_bridge.gd").new()
	root.add_child(bridge)
	bridge.bind(session)
	var map := preload("res://systems/map_navigation/map_navigation_service.gd").new()
	root.add_child(map)
	map.bind_core(bridge)
	check(map.configure(bridge.definition()), "地图配置")
	map.initialize("SC01")
	var tutorial := preload("res://systems/aurora/aurora_tutorial.gd").new()
	root.add_child(tutorial)
	tutorial.bind(session, gameplay, map)
	tutorial.set_process(false)
	check(tutorial.current_step.get("target_ref") == "HS_SC01_SIGN", "开场调查指向真实站名牌")
	var sign := Button.new()
	sign.name = "HS_SC01_SIGN"
	sign.size = Vector2(160, 90)
	gameplay.scene_page.add_child(sign)
	check(tutorial.target_control() == sign, "目标绑定真实节点")
	check(not tutorial.completed(tutorial.current_step), "出现引导不自动完成")
	session.mode = "narrative"
	session.active_entry = "ENTRY_CH01_SIGN"
	session.narrative.state = {"current_text_id": "TXT_CH01_0001"}
	tutorial.refresh()
	check(session.case_state.data.tutorial_completed_steps.has("TUT_INV_SIGN:1"), "观察正文真正出现才完成")
	check(tutorial.current_step.is_empty(), "阅读开始立即撤去调查引导")
	session.mode = "selection"
	session.question = "T00_R01"
	session.current_statement = "TXT_QUESTION_T00_R01"
	session.selected_target = false
	session.slots = ["", ""]
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "TXT_QUESTION_T00_R01", "T00必须先选原话")
	session.selected_target = true
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "E28_V1", "原话选定后才指内页卡")
	session.slots = ["E28_V1", ""]
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "CORE_LAYOUT_PRESENT", "单卡入槽指向主动出示")
	check(not session.case_state.data.tutorial_completed_steps.has("TUT_T00_ONE:3"), "入槽不等于判定")
	session.pending_result = {"question": "T00_R01", "complete": true, "feedback": "exclude"}
	session.mode = "result"
	tutorial.refresh()
	check(session.case_state.data.tutorial_completed_steps.has("TUT_T00_ONE:3"), "实际正确出示结束单卡指引")
	session.mode = "selection"
	session.pending_result.clear()
	session.question = "T00_R02"
	session.selected_target = true
	session.slots = ["", ""]
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "E01_V1", "双卡先选清单")
	session.slots = ["E01_V1", ""]
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "E28_V1", "第一卡真实落槽才指第二卡")
	session.slots = ["", ""]
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "E01_V1", "撤回后重新指缺失材料")
	session.mode = "investigation"
	session.case_state.data.scene = "SC06"
	gameplay.reader_page.show()
	gameplay.reader_page.selected_material = "E01_V1"
	session.case_state.grant("E01_V1", {"test":true})
	tutorial.previous_owns_first = true
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "handbook.current_detail", "手册已选中直接指向真实详察")
	gameplay.reader_page.reading_content = "E01_V1"
	tutorial.refresh()
	check(session.case_state.data.tutorial_completed_steps.has("TUT_MANUAL_FIRST:2"), "手册正文打开结束教学")
	gameplay.reader_page.hide()
	var polygon := preload("res://pages/map_navigation/map_polygon_button.gd").new()
	polygon.hit_polygon = PackedVector2Array([Vector2(0, 20), Vector2(20, 0), Vector2(40, 20), Vector2(20, 40)])
	polygon.position = Vector2(300, 300)
	polygon.size = Vector2(40, 40)
	polygon.rotation = 0.2
	gameplay.add_child(polygon)
	var transform := polygon.get_global_transform_with_canvas()
	check(tutorial.original_hit(polygon, transform * Vector2(20,20)), "旋转后按原多边形内部命中")
	check(not tutorial.original_hit(polygon, transform * Vector2(0,0)), "高亮包围盒空角仍不可点")
	var page := preload("res://pages/aurora/aurora_tutorial_page.gd").new()
	gameplay.add_child(page)
	page.bind(tutorial)
	await process_frame
	check(page != null and page.shade.material is ShaderMaterial, "真实覆盖层与背景虚化材质初始化")
	var saved: Array = session.case_state.data.tutorial_completed_steps.duplicate()
	check(saved.has("TUT_T00_ONE:3") and saved.has("TUT_MANUAL_FIRST:2"), "步骤保存在案件状态")
	tutorial.current_step = {"group_id":"TUT_MAP_FIRST", "step":3, "completion_kind":"arrived", "completion_ref":"SC06"}
	map.state.phase = "failure"
	session.case_state.data.scene = "SC02"
	check(not tutorial._succeeded(tutorial.current_step), "取消或切换失败不标记到达")
	session.case_state.data.scene = "SC06"
	map.state.phase = "arrival_hold"
	check(tutorial._succeeded(tutorial.current_step), "真实到达提交才完成地图")
	session.mode = "selection"
	session.question = "L01_R01"
	session.current_statement = "F7_CH02_L01_R01_ST1_01"
	session.question_reading.clear()
	for option in session.statement_options(): session.case_state.data.texts[option.id] = true
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "F7_CH02_L01_R01_ST3_01", "听全证言后指向正确追问句")
	session.current_statement = "F7_CH02_L01_R01_ST3_01"
	tutorial.refresh()
	check(tutorial.current_step.get("target_ref") == "core.current_press", "选择原句后才指向追问")
	session.case_state.data.events.EV_F7_CH02_L01_R01_PRESS_3 = true
	session.mode = "narrative"
	tutorial.refresh()
	check(not session.case_state.data.tutorial_completed_steps.has("TUT_PRESS_FIRST:2"), "回应未返回时不完成追问教学")
	session.mode = "selection"
	tutorial.refresh()
	check(session.case_state.data.tutorial_completed_steps.has("TUT_PRESS_FIRST:2"), "实际回应事件且返回原句才完成")
	print("FINAL_TUTORIAL_TEST: %d checks, %d failures" % [checks, failures.size()])
	gameplay.free()
	tutorial.free()
	map.free()
	bridge.free()
	session.free()
	quit(0 if failures.is_empty() else 1)
