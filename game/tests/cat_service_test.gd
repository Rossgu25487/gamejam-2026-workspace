extends SceneTree
## 撸猫配置目录与状态机回归测试（无窗口，时间注入，不依赖正式素材）。

const CatalogScript = preload("res://features/cat_interaction/cat_catalog.gd")
const ServiceScript = preload("res://features/cat_interaction/cat_service.gd")

var _checks := 0
var _failed := 0
var _purr_calls: Array = []
var _finished_count := 0

func _init() -> void:
	_test_config()
	_test_service()
	_test_planning_boundaries()
	if _failed == 0:
		print("CAT_SERVICE_PASS %d checks" % _checks)
	else:
		print("CAT_SERVICE_FAIL %d failed / %d checks" % [_failed, _checks])
	quit(1 if _failed else 0)

func expect(ok: bool, detail: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: " + detail)

func _on_purr(sound_ref: String, gain: float) -> void:
	_purr_calls.append([sound_ref, gain])

func _on_finished() -> void:
	_finished_count += 1

func _make_interaction() -> Dictionary:
	return {"id": "cat_test", "view_profile_ref": "view_test", "pet_ms": 600, "response_ms": 1200,
		"purr_gain": 0.35, "sound_ref": "purr_ref", "first_caption_text_id": "CAP_FIRST", "repeat_caption_text_id": "CAP_REPEAT"}

func _test_config() -> void:
	var c = CatalogScript.new()
	expect(c.load_files(), "加载正式配置表")
	expect(c.errors.is_empty(), "配置无错误：" + str(c.errors))
	expect(c.interactions.has("cat_stove_head"), "存在互动记录")
	var it: Dictionary = c.interaction("cat_stove_head")
	expect(int(it.pet_ms) == 600 and int(it.response_ms) == 1200, "pet/response 时长读取")
	expect(absf(float(it.purr_gain) - 0.35) < 0.0001, "purr_gain 读取")
	expect(c.views.has("cat_view_default"), "存在正式展示记录")
	expect(str(c.view("cat_view_default").get("visual_host_ref", "")).is_empty(), "正式载体未就绪（空）")
	var a = c.test_view("EX_CAT_VIEW_A")
	var b = c.test_view("EX_CAT_VIEW_B")
	expect(not a.is_empty() and not b.is_empty(), "EX 联调展示行存在")
	expect(absf(float(a.screen_x) - 0.22) < 0.0001, "EX 屏幕槽读取")
	expect(a.flip_horizontal == false and b.flip_horizontal == true, "EX 水平镜像读取")
	expect(c.actions_for("cat_stove_head").size() == 7, "七种动作键齐备")
	expect(c.ui("CAT_ENTRY") == "摸摸猫", "入口文字")
	expect(c.ui("CAT_RETURN") == "返回调查", "返回文字")
	expect(c.ui("CAT_ENTRY_UNREADY") == "互动素材未就绪", "禁用原因文字")
	var r = c.resolve("cat_stove_head")
	expect(not r.ok, "正式素材未就绪时入口禁用")
	expect(not str(r.reason).is_empty(), "禁用原因非空")

func _test_service() -> void:
	var inter := _make_interaction()
	# 进入与无效配置
	var s = ServiceScript.new()
	expect(s.enter(inter, {}, {}), "有效配置进入")
	expect(s.phase == "waiting" and s.is_active(), "进入后处于等待态")
	var bad = ServiceScript.new()
	expect(not bad.enter({"pet_ms": 0, "response_ms": 1200}, {}, {}), "缺少时长拒绝进入")
	# 触摸与去重
	s.purr_requested.connect(_on_purr)
	s.finished.connect(_on_finished)
	expect(s.begin_touch(false), "等待态首次触摸成功")
	expect(not s.begin_touch(false), "手势中重复触摸被拒")
	expect(s.phase == "gesture" and s.response_kind == "first", "手势阶段且选首次回应")
	expect(s.current_action_kind() == "gesture", "手势动作键")
	expect(_purr_calls.size() == 1 and _purr_calls[0][0] == "purr_ref" and absf(float(_purr_calls[0][1]) - 0.35) < 0.0001, "有效触摸请求一次呼噜")
	# 计时与首见
	s.advance(599.0)
	expect(s.phase == "gesture", "手势未满时长仍手势")
	s.advance(1.0)
	expect(s.phase == "response", "手势满时进入回应")
	expect(s.current_action_kind() == "response_first", "普通回应动作键")
	s.notify_stable_displayed()
	expect(s.first_seen, "稳定画面实际显示后记录首见")
	s.notify_stable_displayed()
	expect(s.first_seen, "重复通知不重复记录")
	s.advance(1200.0)
	expect(s.phase == "returned" and not s.is_active(), "回应结束自然归位")
	expect(_finished_count == 1, "自然结束发一次信号")
	# 已首见 → 再次回应
	var r = ServiceScript.new()
	r.first_seen = true
	r.enter(inter, {}, {})
	r.begin_touch(false)
	expect(r.response_kind == "repeat", "已首见选再次回应")
	r.advance(600.0)
	expect(r.current_action_kind() == "response_repeat", "再次普通回应")
	r.notify_stable_displayed()
	expect(r.first_seen, "再次回应不改变首见")
	# 减弱动态
	var m1 = ServiceScript.new()
	m1.enter(inter, {}, {})
	m1.begin_touch(true)
	m1.advance(600.0)
	expect(m1.current_action_kind() == "stable_first", "减弱动态首次显示稳定姿态")
	var m2 = ServiceScript.new()
	m2.first_seen = true
	m2.enter(inter, {}, {})
	m2.begin_touch(true)
	m2.advance(600.0)
	expect(m2.current_action_kind() == "stable_repeat", "减弱动态再次显示稳定姿态")
	# 暂停与恢复
	var p = ServiceScript.new()
	p.enter(inter, {}, {})
	p.begin_touch(false)
	p.pause()
	p.advance(600.0)
	expect(p.phase == "gesture", "暂停中不计时")
	p.resume()
	p.advance(600.0)
	expect(p.phase == "response", "恢复后计时推进")
	# 主动返回
	var f = ServiceScript.new()
	f.enter(inter, {}, {})
	f.begin_touch(false)
	f.finish()
	expect(f.phase == "returned" and not f.first_seen, "主动返回归位且不记首见")
	# 快照
	var x = ServiceScript.new()
	x.enter(inter, {}, {})
	x.begin_touch(false)
	x.advance(600.0)
	x.notify_stable_displayed()
	var snap = x.export_state()
	expect(snap.first_seen, "导出首见记录")
	expect(x.validate_state(snap), "快照可校验")
	var y = ServiceScript.new()
	expect(y.restore_state(snap) and y.first_seen, "恢复快照")
	expect(not y.validate_state({}), "空快照不可校验")
	expect(not y.restore_state({}), "空快照拒绝恢复")

func _test_planning_boundaries() -> void:
	# 进入时冻结配置、等待也能暂停、重复进入不能重置当前互动。
	var inter := _make_interaction()
	var s = ServiceScript.new()
	expect(s.enter(inter, {"slot": {"x": 1}}, {}), "边界夹具进入")
	inter.pet_ms = 1
	expect(not s.enter(_make_interaction(), {}, {}), "活动互动不能再次进入重置")
	s.pause()
	expect(not s.begin_touch(false) and s.phase == "waiting", "等待态暂停拒绝触摸")
	s.resume()
	expect(s.begin_touch(false), "等待态继续后可触摸")
	s.advance(100.0)
	expect(s.phase == "gesture" and s.remaining_ms() == 500.0, "外部修改时长不影响冻结配置")
	s.set_reduce_motion(true)
	expect(s.current_action_kind() == "stable_first" and s.remaining_ms() == 500.0, "中途减弱立即显示稳定姿态且保留剩余时长")
	s.set_reduce_motion(false)
	expect(s.current_action_kind() == "stable_first", "本回关闭减弱不补播动作")
	s.pause()
	s.notify_stable_displayed()
	expect(not s.first_seen, "暂停中不提交未显示的首见")
	s.resume()
	s.notify_stable_displayed()
	expect(s.first_seen, "减弱动态手势段实际显示稳定帧即可记录首见")
	s.advance(-10.0)
	s.advance(NAN)
	expect(s.remaining_ms() == 500.0, "无效时间不改变时钟")
	s.advance(700.0)
	expect(s.phase == "response" and s.remaining_ms() == 1000.0, "跨段余量计入回应时间")
	expect(not s.restore_state({"first_seen": "false"}) and s.first_seen and s.phase == "response", "损坏首见类型拒绝且保留原互动")
	expect(s.restore_state({"first_seen": false}) and not s.first_seen and s.phase == "idle" and s.remaining_ms() == 0.0, "读档恢复首见并丢弃旧动作时钟")
	expect(s.enter(_make_interaction(), {}, {}) and s.begin_touch(false) and not s.reduce_motion, "下一回恢复普通动态")
	s.advance(1800.0)
	expect(s.phase == "returned" and not s.first_seen, "整段跨帧结束但未实际显示画面时不记首见")
