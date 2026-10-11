extends SceneTree
## 目标导航逻辑回归：数据校验、HUD 开合与更新提示、冻结与恢复、回顾状态、单份阅读与前往核对。
## 依据《目标导航系统策划案》与配置表测试组 TEST00-TEST10、测试操作 EX01-EX26；时间由测试显式推进，不依赖真实时钟。

const ServiceScript = preload("res://systems/objective/objective_service.gd")
const DataScript = preload("res://systems/objective/objective_data.gd")
const ProviderScript = preload("res://tests/support/objective_test_provider.gd")

var checks := 0
var failures: Array[String] = []
var service: Node
var provider: RefCounted
var change_count := 0


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
		print("OBJECTIVE_FAIL: " + label)


func start(group := "") -> void:
	# 每项测试独立重建起点：新服务、新提供方，可选先以 initial 建立某个测试组。
	finish()
	service = ServiceScript.new()
	service.log_warnings = false # 本测试会故意送入错误数据，接入报错只通过信号检查，不写引擎警告
	root.add_child(service)
	check(service.setup(), "加载目标导航配置")
	provider = ProviderScript.new()
	check(provider.load_data(), "加载测试数据")
	service.bind_provider(provider)
	change_count = 0
	service.changed.connect(func(): change_count += 1)
	if not group.is_empty():
		give(group, "initial")


func finish() -> void:
	if service != null:
		service.queue_free()
		service = null
	provider = null


func give(group: String, origin := "result") -> bool:
	provider.use_group(group)
	var before: int = service.model.revision
	service.refresh(origin)
	return service.model.revision != before


func view() -> Dictionary:
	return service.hud_view()


func ids(items: Array) -> Array:
	var result: Array = []
	for item in items:
		result.append(item["id"])
	return result


func whole(values: Array) -> Array:
	# JSON 数字读入为浮点，比较前统一取整。
	var result: Array = []
	for value in values:
		result.append(int(value))
	return result


func _run() -> void:
	test_config()
	test_normalize()
	test_test_groups()
	test_basic_display()
	test_update_notice()
	test_expand_collapse_updates()
	test_hidden_and_pause()
	test_scroll_targets()
	test_goal_changes()
	test_review()
	test_review_failures()
	test_read_and_go()
	test_integration_error()
	finish()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("OBJECTIVE_PASS: %d checks" % checks)
		quit(0)
	else:
		print("OBJECTIVE_FAILED: %d of %d checks" % [failures.size(), checks])
		quit(1)


func test_config() -> void:
	start()
	var hud: Dictionary = service.config["hud"]
	var review: Dictionary = service.config["review"]
	check(int(hud["update_notice_ms"]) == 2000 and int(hud["update_glow_ms"]) == 300, "提示 2000ms、提亮 300ms")
	check(int(hud["visible_item_limit"]) == 3 and int(hud["panel_max_height_px"]) == 340 and int(hud["compact_max_height_px"]) == 320, "同屏 3 条、最大高 340/320")
	check(whole(hud["base_panel_rect"]) == [1494, 136, 368] and whole(hud["compact_panel_rect"]) == [932, 100, 300], "两种窗口的面板位置")
	check(whole(hud["base_viewport"]) == [1920, 1080] and whole(hud["compact_viewport"]) == [1280, 800], "两种窗口的参考尺寸")
	check(int(hud["fold_width_px"]) == 174 and int(hud["header_height_px"]) == 36, "收起宽 174、标题高 36")
	check(float(hud["panel_opacity"]) == 0.5 and float(hud["text_opacity"]) == 1.0 and float(hud["text_outline_width_px"]) == 0.0, "底板 50%、文字不透明、无描边")
	check(whole(review["viewport"]) == [1600, 900] and whole(review["main_rect"]) == [68, 245, 430, 400], "回顾 1600x900 与主目标区")
	check(whole(review["pending_rect"]) == [558, 286, 945, 200] and whole(review["progress_rect"]) == [558, 568, 945, 246], "回顾待核与进展区")
	check(service.text_id("error_review") == "UI_OBJECTIVE_OPEN_REVIEW_FAILED" and service.text_id("label_update") == "UI_HANDBOOK_UPDATED", "功能文字键")
	check(service.model.notice_total_ms == 2000.0 and service.model.glow_total_ms == 300.0, "模型读取配置")


func test_normalize() -> void:
	var good := {"goal_id": "G", "goal_text": "主目标", "items": [
		{"id": "B", "order": 2, "text": "乙", "status": "pending"}, {"id": "A", "order": 1, "text": "甲", "status": "checked"}]}
	var result: Dictionary = DataScript.normalize(good)
	check(result["ok"] and ids(result["goal"]["items"]) == ["A", "B"], "事项按提供方顺序号排列")
	check(DataScript.normalize({"goal_id": ""})["ok"] and DataScript.normalize({})["goal"].is_empty(), "无目标编号是正常输入")
	check(not DataScript.normalize({"goal_id": "G", "goal_text": ""})["ok"], "有编号缺主目标文字报错")
	var dup := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x", "status": "pending"}, {"id": "A", "order": 2, "text": "y", "status": "pending"}]}
	check(not DataScript.normalize(dup)["ok"], "事项编号重复报错")
	var no_status := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x"}]}
	check(not DataScript.normalize(no_status)["ok"], "事项状态缺失报错")
	var bad_status := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x", "status": "done"}]}
	check(not DataScript.normalize(bad_status)["ok"], "事项状态无效报错")
	var same_order := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x", "status": "pending"}, {"id": "B", "order": 1, "text": "y", "status": "pending"}]}
	check(not DataScript.normalize(same_order)["ok"], "显示顺序重复报错")
	var dangling := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x", "status": "pending", "basis": ["NOPE"]}]}
	check(not DataScript.normalize(dangling)["ok"], "引用不存在的依据报错")
	var no_reason := {"goal_id": "G", "goal_text": "T", "items": [{"id": "A", "order": 1, "text": "x", "status": "pending"}]}
	var normalized: Dictionary = DataScript.normalize(no_reason)
	check(normalized["ok"] and normalized["goal"]["items"][0]["reason"] == "" and normalized["goal"]["items"][0]["entry"].is_empty(), "公开原因与入口可为空")
	check(DataScript.neighbor_id(["a", "b", "c"], "a", ["b", "c"]) == "b", "首项移除定位后一项")
	check(DataScript.neighbor_id(["a", "b", "c"], "c", ["a", "b"]) == "b", "末项移除定位前一项")
	check(DataScript.neighbor_id(["a"], "a", []) == "", "分区为空时无定位")
	var left: Dictionary = DataScript.normalize(good)["goal"]
	var right: Dictionary = DataScript.normalize(good.duplicate(true))["goal"]
	check(DataScript.content_signature(left) == DataScript.content_signature(right), "相同内容签名一致")
	right["items"][0]["text"] = "改"
	check(DataScript.content_signature(left) != DataScript.content_signature(right), "文字变化签名不同")


func test_test_groups() -> void:
	start()
	for id in provider.data["groups"].keys():
		var result: Dictionary = DataScript.normalize(provider.group_snapshot(id))
		if id == "TEST09":
			check(not result["ok"], "TEST09 有编号缺主目标，接入检查报错")
		elif id == "TEST00":
			check(result["ok"] and result["goal"].is_empty(), "TEST00 空目标为正常无目标")
		else:
			check(result["ok"], id + " 可解析")
	var first: Dictionary = DataScript.normalize(provider.group_snapshot("TEST01"))["goal"]
	check(ids(DataScript.pending_items(first)) == ["TEST_ROOM", "TEST_TALK"], "TEST01 两条待核事项")
	check(provider.group("TEST07")["goal_text"].length() > 80, "TEST07 提供超长主目标")


func test_basic_display() -> void:
	# EX01：首次进入，默认展开，两条待核事项，没有更新提示。
	start("TEST01")
	var v := view()
	check(v["shown"] and v["expanded"] and ids(v["items"]) == ["TEST_ROOM", "TEST_TALK"], "EX01 默认展开且两条待核")
	check(not v["notice"] and not v["marker"] and v["glow"] == 0.0, "EX01 首次显示没有更新提示")
	# EX02：点击标题只改变开合。
	service.toggle_expanded()
	check(not view()["expanded"], "EX02 收起")
	service.toggle_expanded()
	check(view()["expanded"] and not view()["notice"], "EX02 展开且不产生提示")
	# EX06/EX07/EX13：长列表、全部核查与超长主目标。
	start("TEST03")
	check(ids(view()["items"]).size() == 4 and service.model.visible_item_limit == 3, "EX06 四条待核，同屏上限 3 条")
	start("TEST04")
	check(view()["shown"] and view()["items"].is_empty() and view()["goal_text"] == "查明发生了什么", "EX07 全部核查后仍保留主目标")
	start("TEST07")
	check(view()["goal_text"].length() > 80, "EX13 超长主目标原样保留")
	# EX08：无目标隐藏并清除旧标记、计时和位置。
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	check(view()["marker"], "EX08 先有未查看标记")
	give("TEST00")
	var empty := view()
	check(not empty["shown"] and not empty["marker"] and not empty["notice"], "EX08 无目标隐藏并清除提示")
	check(service.take_scroll()["mode"] == "top", "EX08 清除列表位置")


func test_update_notice() -> void:
	# EX09：一直展开，两次结果相隔 1000ms。
	start("TEST01")
	give("TEST02")
	check(view()["notice"] and service.model.notice_ms == 2000.0 and service.model.glow_ms == 300.0, "EX09 结果生效直接提示并提亮")
	service.advance(300.0)
	check(service.model.glow_ms == 0.0 and view()["notice"], "EX09 提亮 300ms 结束后文字提示仍在")
	service.advance(700.0)
	check(service.model.notice_ms == 1000.0, "EX09 1000ms 后剩余 1000ms")
	give("TEST08")
	check(service.model.notice_ms == 2000.0, "EX09 第二次变化重新计 2000ms")
	check(service.model.glow_ms == 0.0, "EX09 同一段连续提示最多提亮一次")
	check(ids(view()["items"]) == ["TEST_TALK", "TEST_RECORD"], "EX09 只显示最新内容")
	service.advance(2000.0)
	check(not view()["notice"] and not service.model.glow_used, "EX09 提示结束后连续段结束")
	give("TEST02")
	check(service.model.glow_ms == 300.0, "EX09 新的连续段可再次提亮")
	# EX17：提示剩 1000ms 时再次送达完全相同内容，不重新计时也不提亮。
	start("TEST01")
	give("TEST02")
	service.advance(1000.0)
	var emitted := change_count
	check(not give("TEST02"), "EX17 完全相同的内容不改变可见内容")
	check(service.model.notice_ms == 1000.0 and service.model.glow_ms == 0.0, "EX17 剩余 1000ms 保持且不再提亮")
	check(change_count == emitted, "EX17 重复送达不触发刷新")
	# 首次建立与读档成功不提示。
	start()
	give("TEST01", "initial")
	check(not view()["notice"] and not view()["marker"], "初始建立不提示")
	give("TEST02", "restore")
	check(not view()["notice"] and not view()["marker"] and service.model.glow_ms == 0.0, "读档成功不提示")


func test_expand_collapse_updates() -> void:
	# EX03：先收起，再送入 TEST02，保持收起并只留一个更新标记。
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	var v := view()
	check(not v["expanded"] and v["marker"] and not v["notice"], "EX03 收起期间只留更新标记")
	give("TEST08")
	check(view()["marker"] and not view()["expanded"], "EX03 连续变化仍只有一个标记")
	# EX04：展开后标记清除，已更新显示 2000ms。
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	service.toggle_expanded()
	var opened := view()
	check(opened["expanded"] and not opened["marker"] and opened["notice"] and service.model.notice_ms == 2000.0, "EX04 展开后标记清除并显示已更新")
	check(ids(opened["items"]) == ["TEST_TALK", "TEST_RECORD"], "EX04 显示交谈和记录两条待核")
	service.advance(2000.0)
	check(not view()["notice"], "EX04 已更新 2000ms 后消失")
	# 展开期间收起，提示取消；再次展开无标记则无提示。
	give("TEST08")
	service.toggle_expanded()
	check(not view()["notice"] and service.model.glow_ms == 0.0, "收起时取消提示与提亮")
	service.toggle_expanded()
	check(not view()["notice"] and not view()["marker"], "无标记时再展开不提示")
	# EX14：收起时读档成功，以 TEST01 重建，仍收起，无动画。
	start("TEST02")
	service.toggle_expanded()
	give("TEST01", "restore")
	var restored := view()
	check(not restored["expanded"] and not restored["marker"] and not restored["notice"] and restored["goal_id"] == "TEST_GOAL_01", "EX14 读档重建、保留收起且无更新动画")
	check(ids(Array(DataScript.pending_items(service.model.goal))) == ["TEST_ROOM", "TEST_TALK"], "EX14 以 TEST01 的两条事项重建")
	check(service.take_scroll()["mode"] == "top", "EX14 清旧滚动位置")
	# 展开选择在更换目标后保留；首次运行默认展开。
	start("TEST01")
	check(service.model.expanded, "首次运行默认展开")
	service.toggle_expanded()
	give("TEST05")
	check(not view()["expanded"], "更换主目标保留收起选择")


func test_hidden_and_pause() -> void:
	# EX10：不允许显示期间连续刷新，隐藏期间不计提示过期，返回后启动一次提示。
	start("TEST02")
	service.set_display_allowed(false)
	give("TEST08")
	give("TEST02")
	check(service.model.pending_notice and service.model.notice_ms == 0.0, "EX10 遮挡期间只保留最新变化")
	service.advance(5000.0)
	check(service.model.notice_ms == 0.0 and service.model.pending_notice, "EX10 隐藏期间不计时")
	service.set_display_allowed(true)
	check(view()["notice"] and service.model.notice_ms == 2000.0 and service.model.glow_ms == 300.0, "EX10 返回后显示最新内容并启动一次提示")
	check(not service.model.pending_notice, "EX10 提示只启动一次")
	# 遮挡时在收起状态：返回后只留标记。
	start("TEST01")
	service.toggle_expanded()
	service.set_display_allowed(false)
	give("TEST02")
	service.set_display_allowed(true)
	check(view()["marker"] and not view()["expanded"], "收起并被遮挡后返回只留标记")
	# 遮挡中的提示计时冻结，被打断的提亮不补播。
	start("TEST01")
	give("TEST02")
	service.advance(100.0)
	service.set_display_allowed(false)
	check(service.model.glow_ms == 0.0 and service.model.notice_ms == 1900.0, "遮挡打断提亮并保留剩余提示")
	service.advance(5000.0)
	check(service.model.notice_ms == 1900.0, "遮挡期间提示计时不推进")
	service.set_display_allowed(true)
	check(service.model.glow_ms == 0.0 and service.model.notice_ms == 1900.0, "返回后不补播提亮，剩余提示继续")
	# EX21：暂停期间计时冻结，减弱动态只取消提亮。
	start("TEST01")
	give("TEST02")
	service.advance(1000.0)
	service.set_paused(true)
	service.advance(5000.0)
	check(service.model.notice_ms == 1000.0, "EX21 暂停期间剩余 1000ms 不减少")
	service.set_paused(false)
	service.advance(1000.0)
	check(service.model.notice_ms == 0.0, "EX21 继续后剩余时间结束")
	start("TEST01")
	service.set_reduce_motion(true)
	give("TEST02")
	check(view()["notice"] and service.model.glow_ms == 0.0, "EX21 减弱动态刷新只留文字不提亮")
	service.set_reduce_motion(false)
	check(service.model.glow_ms == 0.0, "EX21 关闭减弱动态不补播提亮")
	start("TEST01")
	give("TEST02")
	service.advance(100.0)
	service.set_paused(true)
	service.set_paused(false)
	check(service.model.glow_ms == 0.0, "暂停打断的提亮不补播")
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	service.set_paused(true)
	check(view()["marker"], "暂停期间未查看的更新标记保留")
	# 处理中的提示与逐帧推进：只有提示或提亮进行时才需要 _process。
	start("TEST01")
	check(not service.is_processing(), "没有提示时不逐帧处理")
	give("TEST02")
	check(service.is_processing(), "提示进行时逐帧处理")
	service.advance(2000.0)
	check(not service.is_processing(), "提示结束后停止逐帧处理")


func test_scroll_targets() -> void:
	# EX12：待核首项被核查，同一位置由后一项占据；进展区保留该事项。
	start("TEST03")
	service.report_scroll("TEST_TALK")
	give("TEST06")
	check(ids(view()["items"])[0] == "TEST_RECORD", "EX12 HUD 待核区由 TEST_RECORD 占原位置")
	var target: Dictionary = service.take_scroll()
	check(target["mode"] == "item" and target["item"] == "TEST_RECORD", "EX12 列表位置定位到后一项")
	var review: Dictionary = service.review_view()
	check(ids(review["pending"])[0] == "TEST_RECORD" and ids(review["progress"]).has("TEST_TALK"), "EX12 回顾待核区与进展区同步")
	check(service.take_scroll()["mode"] == "keep", "位置目标只取一次")
	# 第一条可见内容未变化时保持位置。
	start("TEST03")
	service.report_scroll("TEST_RECORD")
	give("TEST06")
	check(service.take_scroll()["mode"] == "keep", "第一条可见内容未变化时位置保持")
	# 没有后一项时显示前一项；全部核查后位置回顶部。
	start("TEST03")
	service.report_scroll("TEST_COMPARE")
	var raw: Dictionary = provider.group_snapshot("TEST03")
	raw["items"].pop_back()
	service.deliver(raw, "result")
	check(service.take_scroll()["mode"] == "item" and service.model.scroll.is_empty() == false, "末项移除时仍给出位置目标")
	start("TEST03")
	give("TEST04")
	check(service.take_scroll()["mode"] == "top", "全部核查后位置回到顶部")
	# EX11：更换主目标编号，从首项开始，不保留旧位置。
	start("TEST02")
	service.report_scroll("TEST_RECORD")
	give("TEST05")
	var changed_goal: Dictionary = view()
	check(changed_goal["goal_id"] == "TEST_GOAL_02" and ids(changed_goal["items"])[0] == "TEST_RECORD", "EX11 显示新目标并从首项开始")
	check(service.take_scroll()["mode"] == "top", "EX11 不保留旧列表位置")


func test_goal_changes() -> void:
	# 新目标的提示按当前开合处理，旧目标的标记不保留。
	start("TEST02")
	service.toggle_expanded()
	give("TEST03")
	check(view()["marker"], "同目标内容更新留下标记")
	give("TEST05")
	check(view()["marker"] and view()["goal_id"] == "TEST_GOAL_02", "新目标按收起状态留下新的标记")
	service.toggle_expanded()
	check(view()["notice"] and not view()["marker"], "展开后新目标显示已更新")
	# 无目标 -> 新目标出现：从第一条开始，保留展开选择并提示。
	start("TEST00")
	give("TEST01")
	check(view()["shown"] and view()["notice"], "无目标后出现公开目标时提示")
	# 回顾中看到最新目标后标记消失。
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	check(view()["marker"], "收起时留下标记")
	check(service.request_review() == "opened", "打开回顾")
	check(not service.hud_view()["marker"], "在回顾中看到最新目标后标记消失")


func test_review() -> void:
	# EX05：回顾、单份依据、来源逐层读取；目标与两槽不变。
	start("TEST02")
	var goal_before: String = DataScript.full_signature(service.model.goal)
	check(service.request_review() == "opened" and service.review_state == "open", "EX05 回顾准备成功后打开")
	check(provider.prepare_count == 1, "EX05 准备只发起一次")
	var review: Dictionary = service.review_view()
	check(review["open"] and ids(review["pending"]) == ["TEST_TALK", "TEST_RECORD"] and ids(review["progress"]) == ["TEST_ROOM"], "EX05 回顾待核与进展分区")
	check(review["goal_text"] == "查明发生了什么", "EX05 左侧显示主目标全文")
	var room: Dictionary = review["progress"][0]
	check(room["bases"].size() == 1 and room["bases"][0]["id"] == "TEST_READ_01" and room["bases"][0]["version_text"] == "第1版", "EX05 依据显示名称与准确版本")
	check(room["bases"][0]["has_source"] and room["entry"]["available"], "EX05 依据有来源，入口可用")
	var read: Dictionary = service.request_read("TEST_READ_01")
	check(read["status"] == "ok" and read["doc"]["version_text"] == "第1版" and read["doc"]["body"].begins_with("这是一份用于阅读"), "EX05 读取准确第 1 版")
	check(read["doc"]["sources"].size() == 1 and read["doc"]["sources"][0]["id"] == "TEST_READ_03", "EX05 来源沿来源依据 ID")
	var source: Dictionary = service.request_read("TEST_READ_03")
	check(source["status"] == "ok" and source["doc"]["sources"].is_empty(), "EX05 来源叶项没有更深来源")
	check(provider.read_log == ["TEST_READ_01", "TEST_READ_03"] and provider.go_log.is_empty(), "EX05 阅读不发起其他请求")
	service.close_review()
	check(service.review_state == "closed" and provider.end_count == 1, "EX05 返回调查结束回顾占用")
	check(DataScript.full_signature(service.model.goal) == goal_before, "EX05 目标与进展不变")
	service.close_review()
	check(provider.end_count == 1, "重复关闭不重复结束")
	# 单项没有依据或来源时的展示数据。
	start("TEST05")
	var plain: Dictionary = service.review_view()
	check(plain["pending"][0]["entry"].is_empty(), "无调查入口的事项没有入口数据")
	# EX23：回顾已打开时目标变空，两区清空并保留返回。
	start("TEST02")
	service.request_review()
	give("TEST00")
	var emptied: Dictionary = service.review_view()
	check(emptied["empty"] and emptied["pending"].is_empty() and emptied["progress"].is_empty() and emptied["open"], "EX23 目标变空时回顾清空并保持打开")
	check(not service.hud_view()["shown"], "EX23 HUD 隐藏")
	service.close_review()
	# EX24：从待核事项打开原话期间该项变为已核查，同一事项在进展区定位。
	start("TEST03")
	service.request_review()
	var talk_basis: String = service.review_view()["pending"][0]["bases"][0]["id"]
	check(service.request_read(talk_basis)["status"] == "ok", "EX24 打开原话")
	give("TEST06")
	var after: Dictionary = service.review_view()
	check(ids(after["progress"]).has("TEST_TALK") and not ids(after["pending"]).has("TEST_TALK"), "EX24 同一事项移入进展区")
	check(provider.go_log.is_empty(), "EX24 阅读不发完成请求")
	check(DataScript.neighbor_id(ids(DataScript.pending_items(provider_goal("TEST03"))), "TEST_TALK", ids(after["pending"])) == "TEST_RECORD", "EX24 待核区后一项定位")


func provider_goal(group: String) -> Dictionary:
	return DataScript.normalize(provider.group_snapshot(group))["goal"]


func test_review_failures() -> void:
	# EX18：回顾准备失败，原因持续显示，重试开始或离开原页清除。
	start("TEST02")
	service.toggle_expanded()
	give("TEST03")
	var before: Dictionary = service.hud_view()
	provider.fail_prepare = true
	check(service.request_review() == "failed" and service.review_state == "closed", "EX18 准备失败保持原页")
	var failed: Dictionary = service.hud_view()
	check(failed["error"] == "UI_OBJECTIVE_OPEN_REVIEW_FAILED", "EX18 原入口显示 error_review")
	check(failed["expanded"] == before["expanded"] and failed["marker"] == before["marker"] and failed["items"] == before["items"], "EX18 开合、标记与内容保持")
	service.advance(5000.0)
	check(service.hud_view()["error"] == "UI_OBJECTIVE_OPEN_REVIEW_FAILED", "EX18 5000ms 后原因仍显示")
	provider.fail_prepare = false
	check(service.request_review() == "opened" and service.hud_view()["error"] == "", "EX18 重试开始清除原因并成功")
	service.close_review()
	provider.fail_prepare = true
	service.request_review()
	service.set_display_allowed(false)
	check(service.hud_view()["error"] == "", "EX18 离开原页清除原因")
	service.set_display_allowed(true)
	provider.fail_prepare = false
	# 同一准备中只发一份请求；异步准备成功后才进入。
	start("TEST02")
	provider.async_prepare = true
	check(service.request_review() == "preparing" and service.review_state == "preparing", "EX18 异步准备中")
	check(service.request_review() == "ignored" and provider.prepare_count == 1, "EX18 同一准备中只发一份请求")
	check(service.review_state != "open", "EX18 准备成功前不切页")
	service.complete_review(true)
	check(service.review_state == "open" and provider.prepare_count == 1, "EX18 准备成功后进入")
	service.close_review()
	provider.async_prepare = true
	service.request_review()
	service.complete_review(false)
	check(service.review_state == "closed" and service.hud_view()["error"] == "UI_OBJECTIVE_OPEN_REVIEW_FAILED", "EX18 异步准备失败显示原因")
	# 同一回顾状态下重复请求无副作用。
	start("TEST02")
	service.request_review()
	check(service.request_review() == "ignored" and provider.prepare_count == 1, "回顾已打开时重复请求被忽略")


func test_read_and_go() -> void:
	# EX19：依据准备失败，原因文字来自功能文字，不新增已读或案件结果。
	start("TEST02")
	service.request_review()
	provider.fail_read = true
	var failed: Dictionary = service.request_read("TEST_READ_01")
	check(failed["status"] == "failed" and failed["error"] == "UI_OBJECTIVE_OPEN_READ_FAILED", "EX19 读取失败返回 error_read")
	check(provider.read_log.is_empty() and provider.go_log.is_empty(), "EX19 不新增已读或案件结果")
	check(service.review_state == "open", "EX19 失败后保留回顾")
	provider.fail_read = false
	check(service.request_read("TEST_READ_01")["status"] == "ok", "EX19 重试成功")
	# 异步读取同一请求只处理一次。
	provider.async_read = true
	var reads: Array = []
	service.read_completed.connect(func(id: String, result: Dictionary): reads.append([id, result["status"]]))
	check(service.request_read("TEST_READ_01")["status"] == "preparing", "异步读取准备中")
	check(service.request_read("TEST_READ_02")["status"] == "busy", "准备中的第二份读取被忽略")
	service.complete_read("TEST_READ_01", {"ok": true, "doc": {"id": "TEST_READ_01"}})
	check(reads == [["TEST_READ_01", "ok"]], "异步读取完成回调")
	provider.async_read = false
	# EX16：待核事项文字正常可读，入口不可用时不发起调查入口请求。
	start("TEST08")
	service.request_review()
	var talk: Dictionary = service.review_view()["pending"][0]
	check(talk["id"] == "TEST_TALK" and talk["reason"] == "对方暂时无法交谈" and not talk["entry"]["available"], "EX16 显示已公开原因，入口不可用")
	var blocked: Dictionary = service.request_go("TEST_ENTRY_02")
	check(blocked["status"] == "unavailable" and blocked["reason"] == "对方暂时无法交谈", "EX16 点击不可用的前往核对返回公开原因")
	check(provider.go_log.is_empty() and talk["bases"].size() == 1, "EX16 不发起入口请求，依据仍可读")
	# EX26：提供方重新检查为不可用，保持回顾与完成状态。
	start("TEST02")
	service.request_review()
	provider.entry_recheck["TEST_ENTRY_02"] = {"available": false, "reason": "对方暂时无法交谈"}
	var goal_before: String = DataScript.full_signature(service.model.goal)
	var rechecked: Dictionary = service.request_go("TEST_ENTRY_02")
	check(rechecked["status"] == "unavailable" and rechecked["reason"] == "对方暂时无法交谈", "EX26 复查不可用返回公开原因")
	check(provider.go_log.is_empty() and service.review_state == "open", "EX26 不切换调查入口，回顾保持")
	check(DataScript.full_signature(service.model.goal) == goal_before, "EX26 不改变目标完成状态")
	# 前往核对成功：回顾占用已结束；失败：回顾原状保持。
	start("TEST02")
	service.request_review()
	var went: Dictionary = service.request_go("TEST_ENTRY_01")
	check(went["status"] == "ok" and provider.go_log == ["TEST_ENTRY_01"] and service.review_state == "closed", "前往核对成功后关闭回顾")
	start("TEST02")
	service.request_review()
	provider.go_ok = false
	var refused: Dictionary = service.request_go("TEST_ENTRY_01")
	check(refused["status"] == "failed" and service.review_state == "open", "前往核对失败保持回顾")
	check(service.request_go("NO_SUCH_ENTRY")["status"] == "unavailable", "不存在的入口不可前往")


func test_integration_error() -> void:
	# EX20：有编号缺主目标全文，接入检查报错，隐藏该组并清旧提示，不以测试值替代。
	start("TEST01")
	service.toggle_expanded()
	give("TEST02")
	check(view()["marker"], "EX20 先有旧提示")
	var errors: Array = []
	service.integration_error.connect(func(list: Array): errors.assign(list))
	provider.use_group("TEST09")
	service.refresh("result")
	check(errors.size() == 1 and "TEST_GOAL_INVALID" in String(errors[0]), "EX20 接入检查报错并指出目标编号")
	var v := view()
	check(not v["shown"] and not v["marker"] and not v["notice"] and v["goal_text"] == "", "EX20 隐藏该组并清除旧提示，不显示替代文字")
	check(service.review_view()["invalid"], "EX20 回顾提示无效数据")
	# 已打开的回顾清掉该组内容与动作，保留返回。
	start("TEST02")
	service.request_review()
	provider.use_group("TEST09")
	service.refresh("result")
	var broken: Dictionary = service.review_view()
	check(broken["invalid"] and broken["pending"].is_empty() and broken["progress"].is_empty() and broken["open"], "EX20 打开中的回顾清空内容并保留返回")
	check(service.request_go("TEST_ENTRY_01")["status"] == "unavailable", "EX20 失效后不再提供前往核对")
	service.close_review()
	# 恢复有效数据后回到正常显示。
	provider.use_group("TEST02")
	service.refresh("result")
	check(view()["shown"] and service.integration_errors.is_empty(), "有效数据恢复后正常显示")
