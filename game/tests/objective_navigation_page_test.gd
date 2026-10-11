extends SceneTree
## 目标导航页面回归：用真实鼠标与键盘事件检查 HUD、调查回顾与单份阅读，再经 Main 走一遍案件接入。
## 这是注入输入事件的程序测试，不代替人工键鼠验收。

const BenchScene = preload("res://tests/bench/objective_bench.tscn")
const MainScene = preload("res://main/main.tscn")

var checks := 0
var failures: Array[String] = []
var bench: Control
var service: Node
var provider: RefCounted
var hud: Control
var review: Control


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		printerr("OBJECTIVE_PAGE_FAILED: " + message)


func frames(count: int = 4) -> void:
	for i in range(count):
		await process_frame


# ---------- 输入 ----------

func center_of(control: Control) -> Vector2:
	# 控件中心的窗口坐标，包含回顾页画布的等比缩放。
	return control.get_global_transform() * (control.size * 0.5)


func move_mouse(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	await process_frame


func click_at(point: Vector2) -> void:
	await move_mouse(point)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event)
		await process_frame
	await frames()


func scroller_of(target: Control) -> ScrollContainer:
	var node: Node = target.get_parent()
	while node != null and not node is ScrollContainer:
		node = node.get_parent()
	return node as ScrollContainer


func click(target: Control) -> void:
	var usable := is_instance_valid(target) and target.is_visible_in_tree()
	check(usable, "点击目标存在且可见")
	if usable:
		var scroller := scroller_of(target)
		if scroller != null:
			scroller.ensure_control_visible(target) # 分区内的按钮先滚到可见，再像玩家一样点击
			await process_frame
		await click_at(center_of(target))


func wheel(point: Vector2, up: bool) -> void:
	await move_mouse(point)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
		event.pressed = down
		event.factor = 1.0
		root.push_input(event)
	await frames(2)


func key(code: Key, shift: bool = false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		event.shift_pressed = shift
		root.push_input(event)
	await frames(3)


func focus_owner() -> Control:
	return root.gui_get_focus_owner()


# ---------- 试玩台 ----------

func start_bench(group: String = "TEST01") -> void:
	bench = BenchScene.instantiate()
	root.add_child(bench)
	await frames()
	service = bench.service
	provider = bench.provider
	hud = bench.hud
	review = bench.review
	if group != "TEST01":
		bench._apply_group(group, "initial")
		await frames(5)


func stop_bench() -> void:
	bench.queue_free()
	await frames()


func notes_of(block: Node) -> Array[String]:
	var found: Array[String] = []
	for node in block.find_children("Note", "Label", true, false):
		found.append((node as Label).text)
	return found


func button_named(parent: Node, text: String) -> Button:
	for child in parent.get_children():
		if child is Button and child.text == text:
			return child
		var found := button_named(child, text)
		if found != null:
			return found
	return null


func title_text() -> String:
	return String((review.reading.header_box.get_node("Title") as Label).text)


# ---------- 目标面板 ----------

func test_hud() -> void:
	await start_bench("TEST01")
	var hud_config: Dictionary = service.config["hud"]
	var view: Dictionary = service.hud_view()
	check(hud.visible and bool(view["shown"]) and bool(view["expanded"]), "EX01 首次进入默认展开并显示")
	check((view["items"] as Array).size() == 2 and hud.blocks.size() == 2, "EX01 两条待核事项")
	check(not bool(view["marker"]) and not bool(view["notice"]) and not hud.tag.visible, "EX01 没有更新提示")
	check(hud.panel.position.is_equal_approx(Vector2(932, 100)), "紧凑窗口目标面板位于 (932,100)")
	check(is_equal_approx(hud.panel.size.x, 300.0), "紧凑窗口目标面板宽 300")
	check(hud.panel.size.y <= 320.5, "紧凑窗口目标面板不高于 320")
	check(hud.header.text.ends_with(service.label("label_current_goal")), "标题为当前目标")
	check(hud.review_button.text == service.label("label_review"), "回顾入口文字为调查回顾")
	check(hud.list.focus_mode == Control.FOCUS_NONE, "内容不需要滚动的列表不参与 Tab")
	hud.header.grab_focus()
	await key(KEY_TAB)
	check(focus_owner() == hud.review_button, "Tab 从标题直接到调查回顾入口")

	# EX02：标题只改变开合，当次点击不触发下层物件。
	await click(hud.header)
	check(not bool(service.model.expanded) and not hud.body.visible, "EX02 点击标题收起")
	check(is_equal_approx(hud.panel.size.x, float(hud_config["fold_width_px"])), "EX02 收起后宽度为折叠宽度")
	check(bench.scene_clicks == 0, "EX02 收起点击不触发下层物件")
	await click(hud.header)
	check(bool(service.model.expanded) and hud.body.visible, "EX02 再点标题展开")
	check(bench.scene_clicks == 0, "EX02 展开点击不触发下层物件")
	await wheel(center_of(hud.header), false)
	check(bench.scene_wheels == 0, "滚轮落在面板标题上不穿透到背后的场景")

	# EX03 / EX04：收起时来结果只留标记；展开后清标记并显示已更新 2000ms。
	await click(hud.header)
	bench._apply_group("TEST02", "")
	await frames(3)
	view = service.hud_view()
	check(not bool(view["expanded"]) and bool(view["marker"]) and not bool(view["notice"]), "EX03 收起时只留更新标记")
	check(hud.tag.visible and hud.tag.text == service.label("label_update"), "EX03 标题旁显示更新")
	check(not hud.body.visible, "EX03 保持收起")
	await click(hud.header)
	view = service.hud_view()
	check(bool(view["expanded"]) and not bool(view["marker"]) and bool(view["notice"]), "EX04 展开后标记清除并显示已更新")
	check(hud.tag.visible and hud.tag.text == service.label("label_updated"), "EX04 标题旁显示已更新")
	check((view["items"] as Array).size() == 2 and hud.blocks.size() == 2, "EX04 交谈和记录两条待核")
	check(float(view["glow"]) > 0.0, "EX04 新内容提亮一次")
	service.advance(1000.0)
	check(bool(service.hud_view()["notice"]), "EX04 已更新在 2000ms 内保留")
	service.advance(1200.0)
	await frames(2)
	check(not bool(service.hud_view()["notice"]) and not hud.tag.visible, "EX04 已更新满 2000ms 后消失")

	# EX06：最多同时显示 3 条，第 4 条滚动查看；滚轮、方向键、翻页键都只作用于本区。
	bench._apply_group("TEST03", "")
	await frames(5)
	var list: ScrollContainer = hud.list
	check(hud.blocks.size() == 4, "EX06 四条待核事项")
	var third: Control = hud.blocks[2]
	var fourth: Control = hud.blocks[3]
	check(list.size.y <= third.position.y + third.size.y + 1.0, "EX06 面板最多同时显示三条")
	check(list.is_scrollable() and fourth.position.y + fourth.size.y > list.size.y, "EX06 第四条需要滚动查看")
	check(list.focus_mode == Control.FOCUS_ALL, "EX22 可滚动列表允许 Tab 选中")
	var point := center_of(list)
	await wheel(point, false)
	check(list.scroll_vertical > 0, "EX22 滚轮在目标列表内滚动")
	check(bench.scene_wheels == 0, "EX22 滚轮不穿透到背后的场景")
	for i in range(8):
		await wheel(point, false)
	check(list.scroll_vertical == list.max_scroll(), "EX22 滚到末尾")
	check(bench.scene_wheels == 0, "EX22 末尾继续向下滚动仍不穿透")
	check(fourth.position.y + fourth.size.y - list.scroll_vertical <= list.size.y + 1.0, "EX06 滚到末尾后第四条完整可见")
	for i in range(8):
		await wheel(point, true)
	check(list.scroll_vertical == 0 and bench.scene_wheels == 0, "EX22 回到开头后继续向上滚动不穿透")
	hud.header.grab_focus()
	await key(KEY_TAB)
	check(focus_owner() == list, "EX22 Tab 选中目标列表")
	await key(KEY_DOWN)
	check(list.scroll_vertical == mini(list.line_px, list.max_scroll()), "EX22 方向键下滚一行")
	var page_step := maxi(list.line_px, list.page_px() - list.line_px)
	await key(KEY_PAGEDOWN)
	check(list.scroll_vertical == mini(list.line_px + page_step, list.max_scroll()), "EX22 PageDown 滚一屏并保留一行衔接")
	await key(KEY_PAGEUP)
	check(list.scroll_vertical == maxi(0, mini(list.line_px + page_step, list.max_scroll()) - page_step), "EX22 PageUp 反向滚一屏")
	await key(KEY_TAB)
	check(focus_owner() == hud.review_button, "Tab 离开列表后到调查回顾入口")

	# EX13：超长主目标使面板达到上限后正文一起滚动。
	bench._apply_group("TEST07", "")
	await frames(5)
	check(absf(hud.panel.size.y - 320.0) <= 1.0 and hud.list.is_scrollable(), "EX13 紧凑窗口面板达到 320 后正文滚动")
	check(hud.review_button.is_visible_in_tree() and hud.panel.size.y <= 320.5, "EX13 回顾入口仍在面板内")

	# 1920x1080 基准窗口：面板位置、宽度与最大高度按配置表。
	hud.viewport_override = Vector2(1920, 1080)
	hud._refresh()
	await frames(5)
	check(hud.panel.position.is_equal_approx(Vector2(1494, 136)), "1920x1080 目标面板位于 (1494,136)")
	check(is_equal_approx(hud.panel.size.x, 368.0), "1920x1080 目标面板宽 368")
	check(absf(hud.panel.size.y - 340.0) <= 1.0, "1920x1080 超长目标面板高 340")
	hud.viewport_override = Vector2.ZERO
	hud._refresh()
	await stop_bench()


# ---------- 调查回顾 ----------

func test_review() -> void:
	await start_bench("TEST02")
	check(hud.visible, "回顾前目标面板可见")
	await click(hud.review_button)
	check(service.review_state == "open" and review.visible, "点击调查回顾打开回顾页")
	check(not hud.visible, "回顾期间目标面板隐藏")
	check(is_equal_approx(review.canvas.scale.x, 0.8) and review.canvas.position.is_equal_approx(Vector2(0, 40)), "紧凑窗口回顾画布缩放 0.8 并垂直居中")
	await frames(3)
	check(focus_owner() == review.return_button, "打开回顾后焦点在返回调查")
	check(review.main_list.position.is_equal_approx(Vector2(68, 245)) and review.main_list.size.is_equal_approx(Vector2(430, 400)), "主目标区按配置表 68,245,430,400")
	check(review.pending_list.position.is_equal_approx(Vector2(558, 286)) and review.pending_list.size.is_equal_approx(Vector2(945, 200)), "待核区按配置表 558,286,945,200")
	check(review.progress_list.position.is_equal_approx(Vector2(558, 568)) and review.progress_list.size.is_equal_approx(Vector2(945, 246)), "进展区按配置表 558,568,945,246")
	check(review.pending_list.content.get_child_count() == 2 and review.progress_list.content.get_child_count() == 1, "待核两项，进展一项")
	check(not review.main_list.is_scrollable() and not review.progress_list.is_scrollable(), "主目标区与单项进展区无需滚动")
	for region in [review.main_list, review.pending_list, review.progress_list]:
		check((region.focus_mode == Control.FOCUS_ALL) == region.is_scrollable(), "只有需要滚动的分区才参与 Tab")

	# EX05：读取准确的第 1 版，来源逐层返回，结束后回到原回顾项与位置。
	var scroll_before: int = review.progress_list.scroll_vertical
	var original: Button = review.find_button("orig:TEST_ROOM:TEST_READ_01")
	await click(original)
	check(review.reading.visible, "EX05 查看原文打开单份阅读")
	check(title_text() == "现场记录" and String(review.reading.body.text) == "这是一份用于阅读与返回检查的测试记录。", "EX05 显示准确的依据全文")
	check((review.reading.content.get_child(0) as Label).text == "第1版", "EX05 显示准确版本")
	check(provider.read_log == ["TEST_READ_01"], "EX05 只读取这一份依据")
	await click(review.reading.content.get_node("SourceButton"))
	check(review.reading.stack.size() == 2 and title_text() == service.resolve("UI_HANDBOOK_SOURCE"), "EX05 查看来源进入来源层")
	await click(review.reading.content.find_child("Source_TEST_READ_03", true, false))
	check(review.reading.stack.size() == 3 and String(review.reading.body.text) == "测试来源正文，仅用于检查来源逐层关闭。", "EX05 来源正文逐层打开")
	await click(review.reading.up_button)
	check(review.reading.stack.size() == 2, "EX05 上一级回到来源层")
	await click(review.reading.up_button)
	check(review.reading.stack.size() == 1 and title_text() == "现场记录", "EX05 再上一级回到该依据")
	await click(review.reading.content.get_node("SourceButton"))
	await click(review.reading.content.find_child("Source_TEST_READ_03", true, false))
	await click(review.reading.close_button)
	check(review.reading.stack.size() == 1 and title_text() == "现场记录", "EX05 关闭来源回到该依据")
	await click(review.reading.return_button)
	await frames(3)
	check(not review.reading.visible and review.visible and service.review_state == "open", "EX05 结束单份阅读回到调查回顾")
	check(focus_owner() == review.find_button("orig:TEST_ROOM:TEST_READ_01"), "EX05 焦点回到原回顾项的查看原文")
	check(review.progress_list.scroll_vertical == scroll_before, "EX05 回顾位置保持")
	check(String(service.hud_view()["goal_id"]) == "TEST_GOAL_01" and provider.go_log.is_empty(), "EX05 阅读不改变目标，也不发起调查入口")

	# EX25：较长待核事项换行不截断；该区独立滚动，分区标题与返回按钮固定。
	bench._apply_group("TEST10", "")
	await frames(6)
	var pending: ScrollContainer = review.pending_list
	check(pending.is_scrollable() and pending.focus_mode == Control.FOCUS_ALL, "EX25 较长事项使待核区独立滚动并允许 Tab")
	var talk_text := review._block_in(pending, "TEST_TALK").find_child("Text", true, false) as Label
	check(talk_text.get_line_count() > 1 and talk_text.size.y + 1.0 >= talk_text.get_combined_minimum_size().y, "EX25 长事项按字号换行且不截断")
	var pending_title_at: Vector2 = review.pending_title.global_position
	var return_at: Vector2 = review.return_button.global_position
	await wheel(center_of(pending), false)
	check(pending.scroll_vertical > 0, "EX25 滚轮滚动待核区")
	check(review.pending_title.global_position == pending_title_at and review.return_button.global_position == return_at, "EX25 分区标题与返回按钮固定不动")
	check(review.progress_list.scroll_vertical == 0 and review.main_list.scroll_vertical == 0 and bench.scene_wheels == 0, "EX22 滚轮只作用于所在分区")
	for i in range(10):
		await wheel(center_of(pending), false)
	check(pending.scroll_vertical == pending.max_scroll() and bench.scene_wheels == 0, "EX22 到末尾继续滚动不穿透")
	pending.scroll_to(0)
	review.return_button.grab_focus()
	var reached := false
	for i in range(8):
		await key(KEY_TAB)
		if focus_owner() == pending:
			reached = true
			break
	check(reached, "EX22 Tab 能选中待核区")
	var line: int = pending.line_px
	await key(KEY_DOWN)
	check(pending.scroll_vertical == line, "EX22 键盘下滚一行只滚待核区")
	var step := maxi(line, pending.page_px() - line)
	await key(KEY_PAGEDOWN)
	check(pending.scroll_vertical == mini(line + step, pending.max_scroll()), "EX22 PageDown 滚一屏并保留一行衔接")
	await key(KEY_PAGEUP)
	check(pending.scroll_vertical == maxi(0, mini(line + step, pending.max_scroll()) - step), "EX22 PageUp 反向滚一屏")
	check(review.progress_list.scroll_vertical == 0 and review.main_list.scroll_vertical == 0, "EX22 键盘滚动不影响其他分区")

	# EX24：从待核事项读原话期间该项被核查，返回后在进展区定位同一事项。
	bench._apply_group("TEST03", "")
	await frames(5)
	await click(review.find_button("orig:TEST_TALK:TEST_READ_02"))
	check(review.reading.visible and provider.read_log.back() == "TEST_READ_02", "EX24 待核事项打开原话")
	bench._apply_group("TEST06", "")
	await frames(3)
	check(review.reading.visible, "EX24 阅读期间目标变化不打断阅读")
	await click(review.reading.return_button)
	await frames(4)
	check(review._block_in(review.progress_list, "TEST_TALK") != null and review._block_in(review.pending_list, "TEST_TALK") == null, "EX24 同一事项移入进展区")
	var focused := focus_owner()
	check(focused != null and review.progress_list.is_ancestor_of(focused), "EX24 焦点跟随该事项到进展区")
	check(provider.go_log.is_empty(), "EX24 阅读不发起调查入口，也不发完成请求")

	# EX23：回顾打开期间目标变空，回顾显示空内容且仍可返回。
	bench._apply_group("TEST00", "")
	await frames(4)
	check(review.visible and service.review_state == "open", "EX23 目标变空后回顾保持打开")
	check((review.main_list.content.get_child(0) as Label).text == service.label("empty_goal"), "EX23 主目标区显示空目标")
	check((review.pending_list.content.get_child(0) as Label).text == service.label("empty_pending"), "EX23 待核区为空")
	check((review.progress_list.content.get_child(0) as Label).text == service.label("empty_progress"), "EX23 进展区为空")
	check(not bool(service.hud_view()["shown"]) and not hud.visible, "EX23 目标面板隐藏")
	await click(review.return_button)
	check(service.review_state == "closed" and not review.visible, "EX23 返回调查仍可操作")
	await stop_bench()

	# 1920x1080 基准窗口：回顾画布缩放 1.2。
	await start_bench("TEST02")
	review.viewport_override = Vector2(1920, 1080)
	await click(hud.review_button)
	check(absf(review.canvas.scale.x - 1.2) < 0.001 and review.canvas.position.length() < 0.01, "1920x1080 回顾画布缩放 1.2 并铺满窗口")
	await stop_bench()


# ---------- 失败、不可用与键盘 ----------

func test_failures() -> void:
	await start_bench("TEST02")
	var error_review: String = service.resolve(service.text_id("error_review"))
	var error_read: String = service.resolve(service.text_id("error_read"))
	provider.fail_prepare = true
	await click(hud.review_button)
	check(service.review_state == "closed" and not review.visible and hud.visible, "EX18 准备失败时原页保持")
	check(hud.error_label.visible and hud.error_label.text == error_review, "EX18 回顾入口附近显示失败原因")
	service.advance(5000.0)
	await frames(2)
	check(hud.error_label.visible and hud.error_label.text == error_review, "EX18 5000ms 后失败原因仍显示")
	provider.fail_prepare = false
	await click(hud.review_button)
	check(service.review_state == "open" and String(service.hud_view()["error"]).is_empty(), "EX18 重试开始即清除原因并打开回顾")
	await click(review.return_button)
	provider.fail_prepare = true
	await click(hud.review_button)
	check(hud.error_label.visible, "EX18 再次失败重新显示原因")
	bench.allowed_check.button_pressed = false
	await frames(2)
	bench.allowed_check.button_pressed = true
	await frames(3)
	check(not hud.error_label.visible, "EX18 离开当前场景后清除失败原因")
	provider.fail_prepare = false
	provider.async_prepare = true
	var prepared: int = provider.prepare_count
	await click(hud.review_button)
	check(service.review_state == "preparing" and provider.prepare_count == prepared + 1, "EX18 准备中只发一份请求")
	await click(hud.review_button)
	check(provider.prepare_count == prepared + 1, "EX18 同一准备中再次点击不重复请求")
	service.complete_review(true)
	await frames(3)
	check(service.review_state == "open" and review.visible, "EX18 准备完成后进入回顾")
	provider.async_prepare = false

	# EX19：依据读取失败时留在原回顾项，原因持续显示到重试或离开。
	provider.fail_read = true
	await click(review.find_button("orig:TEST_ROOM:TEST_READ_01"))
	check(not review.reading.visible and review.message_label.visible and review.message_label.text == error_read, "EX19 读取失败留在回顾并显示原因")
	check(focus_owner() == review.find_button("orig:TEST_ROOM:TEST_READ_01"), "EX19 焦点保持在同一回顾项")
	service.advance(5000.0)
	await frames(2)
	check(review.message_label.visible and review.message_label.text == error_read, "EX19 5000ms 后原因仍显示")
	provider.fail_read = false
	await click(review.find_button("orig:TEST_ROOM:TEST_READ_01"))
	check(review.reading.visible and not review.message_label.visible, "EX19 重试开始即清除原因")
	await click(review.reading.return_button)
	provider.fail_read = true
	await click(review.find_button("orig:TEST_ROOM:TEST_READ_01"))
	check(review.message_label.visible, "EX19 再次失败重新显示原因")
	await click(review.return_button)
	await click(hud.review_button)
	check(not review.message_label.visible and provider.go_log.is_empty(), "EX19 返回调查后清除原因且不发起入口")
	await stop_bench()

	# EX26：提供方复查为不可用时回顾保持，显示公开原因，不切换入口。
	await start_bench("TEST02")
	provider.entry_recheck["TEST_ENTRY_02"] = {"available": false, "reason": "对方暂时无法交谈"}
	await click(hud.review_button)
	var go: Button = review.find_button("go:TEST_TALK")
	check(go != null and not go.disabled, "入口按提供方给出的状态显示可点击")
	await click(go)
	check(provider.go_log.is_empty(), "EX26 复查为不可用时不发起调查入口")
	check(review.message_label.visible and review.message_label.text == "对方暂时无法交谈", "EX26 显示公开原因")
	check(service.review_state == "open" and String(service.hud_view()["goal_id"]) == "TEST_GOAL_01", "EX26 回顾与当前目标保持")
	provider.entry_recheck.erase("TEST_ENTRY_02")
	await click(review.find_button("go:TEST_TALK"))
	check(provider.go_log == ["TEST_ENTRY_02"] and service.review_state == "closed" and not review.visible, "前往核对成功后回到调查")
	await stop_bench()

	# EX16：不可用入口按钮禁用并显示原因，文字仍可读。
	await start_bench("TEST08")
	await click(hud.review_button)
	var blocked: Button = review.find_button("go:TEST_TALK")
	check(blocked != null and blocked.disabled, "EX16 不可用入口的前往核对禁用")
	check(notes_of(review._block_in(review.pending_list, "TEST_TALK")).has("对方暂时无法交谈"), "EX16 显示公开原因")
	await click(blocked)
	check(provider.go_log.is_empty(), "EX16 点击不可用入口不发起调查入口请求")
	await click(review.find_button("orig:TEST_TALK:TEST_READ_02"))
	check(review.reading.visible and String(review.reading.body.text) == "测试原话，仅用于检查已经呈现内容的查阅与返回。", "EX16 待核问题的文字正常可读")
	await stop_bench()


func test_keys() -> void:
	await start_bench("TEST02")
	hud.review_button.grab_focus()
	await key(KEY_ENTER)
	check(service.review_state == "open", "键盘 Enter 打开调查回顾")
	await key(KEY_I)
	check(review.visible and service.review_state == "open", "I 不在回顾内另开手册，也不关闭回顾")
	await click(review.find_button("orig:TEST_ROOM:TEST_READ_01"))
	await click(review.reading.content.get_node("SourceButton"))
	check(review.reading.stack.size() == 2, "键盘用例：进入来源层")
	await key(KEY_ESCAPE)
	check(review.reading.visible and review.reading.stack.size() == 1, "Esc 先退一层来源")
	await key(KEY_ESCAPE)
	check(not review.reading.visible and review.visible, "Esc 再结束单份阅读")
	await key(KEY_ESCAPE)
	check(service.review_state == "closed" and not review.visible, "Esc 在回顾列表上等同返回调查")
	await stop_bench()


# ---------- 案件接入（经真实 Main） ----------

func test_main() -> void:
	root.size = Vector2i(1280, 800)
	var scene: Control = MainScene.instantiate()
	scene.test_storage_path = "user://objective-page/%d" % Time.get_ticks_usec()
	root.add_child(scene)
	await frames()
	var page: Control = scene.gameplay_page
	var objectives: Node = scene.objective_service
	var core: Node = scene.session_service.core
	var panel_hud: Control = page.objective_hud
	var panel_review: Control = page.objective_review
	check(not panel_hud.visible and not panel_review.visible, "标题页不显示目标")
	await click(scene.title_page.new_game_button)
	await frames(5)
	check(scene.current_layer == "investigation" and panel_hud.visible, "新游戏后显示当前目标")
	var view: Dictionary = objectives.hud_view()
	check(String(view["goal_text"]) == core.catalog.text("obj_goal"), "目标主文来自案件配置")
	check((view["items"] as Array).size() == 4, "初始四条待核事项")
	check(not bool(view["notice"]) and not bool(view["marker"]), "新游戏不弹更新提示")
	check(panel_hud.panel.position.is_equal_approx(Vector2(932, 100)), "目标面板在紧凑窗口右侧")
	check(page.investigation.get_global_rect().end.x <= panel_hud.panel.global_position.x + 0.5, "调查页让出目标面板宽度，二者不重叠")

	# 取得材料：对白期间隐藏，返回调查后显示最新目标并提示一次。
	await click(button_named(page.investigation, "检查占位资料"))
	check(core.state.mode == "dialogue" and not panel_hud.visible, "对白期间目标面板隐藏")
	await click(button_named(page.investigation, core.ui("UI_RETURN_INVESTIGATION")))
	await frames(5)
	view = objectives.hud_view()
	check(panel_hud.visible and core.state.mode == "investigation", "返回调查后目标面板回来")
	check((view["items"] as Array).size() == 3 and bool(view["notice"]), "取得材料后已核查事项移出待核并提示已更新")

	# 调查回顾：借用检视占用、焦点不越过回顾、读取准确材料与来源。
	await click(panel_hud.review_button)
	check(objectives.review_state == "open" and panel_review.visible, "点击调查回顾打开回顾")
	check(core.inspection_depth == 1 and not core.can_save(), "回顾期间借用检视占用，不能新建存档")
	check(not page.margin.visible, "回顾期间调查页隐藏")
	check(panel_review.pending_list.content.get_child_count() == 3 and panel_review.progress_list.content.get_child_count() == 1, "回顾待核三项、进展一项")
	var escaped := ""
	for i in range(14):
		await key(KEY_TAB)
		var owner_control := focus_owner()
		if owner_control != null and not panel_review.is_ancestor_of(owner_control):
			escaped = str(owner_control.get_path())
	check(escaped.is_empty(), "Tab 焦点不会越过回顾走到背后的按钮：" + escaped)
	var a1: Dictionary = core.catalog.data.contents["A1"]
	var inspect_ref: Dictionary = core.catalog.material_ref("A1")
	check(not core.store.entities["A"]["viewed_content_ids"].has("A1"), "读取前材料 A1 尚未阅读")
	await click(panel_review.find_button("orig:OBJ_INSPECT:BASIS_A1"))
	check(panel_review.reading.visible, "查看原文打开单份阅读")
	review = panel_review
	check(title_text() == core.catalog.text(String(a1["title"])) and String(panel_review.reading.body.text) == core.catalog.text(String(a1["body"])), "原文显示准确的材料版本与全文")
	check(core.store.entities["A"]["viewed_content_ids"].has("A1"), "阅读成功沿核心更新已读")
	await click(panel_review.reading.content.get_node("SourceButton"))
	var origins: Array = panel_review.reading.content.find_children("Source_*", "Button", true, false)
	check(origins.size() == core.store.sources(inspect_ref).size() and origins.size() > 0, "来源层按材料取得时冻结的路径列出")
	await click(origins[0])
	check(panel_review.reading.stack.size() == 3, "来源逐层打开")
	var acquisition: Dictionary = core.store.sources(inspect_ref)[0]
	check(String(panel_review.reading.body.text) == core.catalog.text(String(acquisition["text_id"])), "取得来源正文来自材料的实际取得路径")
	await click(panel_review.reading.close_button)
	await click(panel_review.reading.return_button)
	await frames(3)
	check(panel_review.visible and not panel_review.reading.visible and core.inspection_depth == 1, "结束单份阅读后仍在回顾")
	var talk_go: Button = panel_review.find_button("go:OBJ_TALK")
	check(talk_go != null and not talk_go.disabled, "交谈事项可前往核对")
	var q1_go: Button = panel_review.find_button("go:OBJ_Q1")
	check(q1_go != null and q1_go.disabled and notes_of(panel_review._block_in(panel_review.pending_list, "OBJ_Q1")).has(core.catalog.text("obj_reason_q1")), "未听到说法时核对问题禁用并显示公开原因")
	await click(talk_go)
	check(objectives.review_state == "closed" and not panel_review.visible and page.margin.visible, "前往核对后关闭回顾")
	check(core.inspection_depth == 0 and core.state.mode == "dialogue" and core.condition_met("HEARD"), "前往交谈入口：占用已归还并进入对白")
	await click(button_named(page.investigation, core.ui("UI_RETURN_INVESTIGATION")))
	await frames(5)
	view = objectives.hud_view()
	check((view["items"] as Array).size() == 2, "交谈后待核剩两项")

	# 键盘：Enter 打开、I 不另开手册、Esc 返回并回到调查回顾入口。
	panel_hud.review_button.grab_focus()
	await key(KEY_ENTER)
	check(objectives.review_state == "open", "键盘打开调查回顾")
	await key(KEY_I)
	check(objectives.review_state == "open" and not page.reader.visible and not page.inspection_reader.visible, "回顾内按 I 不另开办案手册")
	await key(KEY_ESCAPE)
	await frames(3)
	check(objectives.review_state == "closed" and scene.current_layer == "investigation", "Esc 只返回调查，不打开暂停菜单")
	check(core.inspection_depth == 0 and focus_owner() == panel_hud.review_button, "返回后焦点回到调查回顾入口")

	# 暂停与继续：隐藏并冻结计时，继续后回来。
	scene._open_pause()
	await frames(2)
	check(scene.current_layer == "pause" and not panel_hud.visible and objectives.model.paused, "暂停时目标面板隐藏并冻结计时")
	scene._on_resume()
	await frames(4)
	check(scene.current_layer == "investigation" and panel_hud.visible and not objectives.model.paused, "继续后目标面板返回")

	# 读档：按已有进度重建，不补播更新提示。
	var saved_items: Array = (objectives.hud_view()["items"] as Array).duplicate(true)
	var snapshot: Dictionary = scene.session_service.export_snapshot()
	scene._on_loaded(snapshot)
	await frames(5)
	view = objectives.hud_view()
	check(view["items"] == saved_items and not bool(view["notice"]) and not bool(view["marker"]), "读档按已有进度重建目标且不提示更新")

	# EX15：读取另一档失败时不向目标导航提交新输入，原目标、开合与标记保持。
	var before_fail: Dictionary = objectives.hud_view().duplicate(true)
	var change_count := [0]
	var counter := func(): change_count[0] += 1
	objectives.changed.connect(counter)
	scene._on_loaded({"broken": true})
	await frames(3)
	objectives.changed.disconnect(counter)
	check(change_count[0] == 0 and objectives.hud_view() == before_fail, "EX15 读取失败时目标内容、开合与标记保持不变")
	check(scene.current_layer == "investigation" and panel_hud.visible and core.state.mode == "investigation", "EX15 读取失败后仍停留在原调查并显示目标面板")

	# 前往核对问题：问题可用后进入对应选材。
	await click(panel_hud.review_button)
	var q1_ready: Button = panel_review.find_button("go:OBJ_Q1")
	check(q1_ready != null and not q1_ready.disabled, "听到说法后核对问题可前往")
	var q2_wait: Button = panel_review.find_button("go:OBJ_Q2")
	check(q2_wait != null and q2_wait.disabled and notes_of(panel_review._block_in(panel_review.pending_list, "OBJ_Q2")).has(core.catalog.text("obj_reason_q2")), "后续问题条件未达时禁用并显示公开原因")
	await click(q1_ready)
	check(core.state.mode == "selection" and objectives.review_state == "closed" and core.inspection_depth == 0, "前往核对进入对应问题的选材")
	check(not panel_hud.visible, "选材期间目标面板隐藏")
	await key(KEY_ESCAPE)
	await frames(4)
	check(core.state.mode == "investigation" and panel_hud.visible, "离开选材回到调查后目标面板返回")

	# 回到标题：丢弃回顾占用；再次新游戏回到初始目标。
	await click(panel_hud.review_button)
	check(objectives.review_state == "open" and core.inspection_depth == 1, "再次打开回顾")
	scene.confirm_exits = false
	scene._on_confirm_direct()
	await frames(4)
	check(scene.current_layer == "title" and objectives.review_state == "closed" and core.inspection_depth == 0, "返回标题时清除回顾占用")
	check(not panel_hud.visible and not panel_review.visible and page.margin.visible, "标题页没有残留的目标界面")
	await click(scene.title_page.new_game_button)
	await frames(5)
	view = objectives.hud_view()
	check(panel_hud.visible and (view["items"] as Array).size() == 4 and not bool(view["notice"]), "再次新游戏回到初始目标且不提示更新")

	scene.queue_free()
	await frames(3)
	await create_timer(0.5).timeout


func _run() -> void:
	root.size = Vector2i(1280, 800)
	await test_hud()
	await test_review()
	await test_failures()
	await test_keys()
	await test_main()
	if failures.is_empty():
		print("OBJECTIVE_PAGE_PASS: %d checks; dispatched mouse/key events at 1280x800 and layout checks at 1920x1080." % checks)
	else:
		printerr("OBJECTIVE_PAGE_FAIL: %d of %d checks failed" % [failures.size(), checks])
	quit(0 if failures.is_empty() else 1)
