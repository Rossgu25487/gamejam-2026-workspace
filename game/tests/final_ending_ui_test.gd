extends SceneTree
## 正式片尾：现行署名、可读纸面、跨比例滚动，以及结束动作只提交一次。
const Session = preload("res://systems/aurora/aurora_session.gd")
const Page = preload("res://pages/aurora/aurora_ending_page.gd")
const PaperTheme = preload("res://pages/aurora/aurora_paper_theme.gd")
var checks := 0
var failures: Array[String] = []
var menu_requests := 0
var completions := 0
var checkpoints := 0

func _init() -> void: call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		printerr("FINAL_ENDING_UI_FAIL: " + message)

func frames() -> void:
	for index in range(8): await process_frame

func click(control: Control) -> void:
	var point := control.get_global_transform_with_canvas() * (control.size / 2)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event)
		await process_frame
	await frames()

func run() -> void:
	root.size = Vector2i(1600, 900)
	var session := Session.new()
	root.add_child(session)
	check(session.initialize(), "正式配置加载")
	if not failures.is_empty(): quit(1); return
	session.mode = "credits"
	session.case_state.data.ending_started = true
	session.ending_checkpoint_requested.connect(func(): checkpoints += 1)
	var page := Page.new()
	page.theme = PaperTheme.build(session.config)
	root.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.bind(session)
	page.menu_requested.connect(func(): menu_requests += 1)
	page.completed.connect(func(): completions += 1)
	page.open()
	await frames()
	check("未配置" not in page.credits_text.text, "现行交付读取完整署名")
	for name in ["Alexander Holm", "kinwie", "Sonatina Symphonic Orchestra", "Signal Experiments", "Kenney", "FreeSFX", "Joseph SARDIN"]:
		check(name in page.credits_text.text, "保留已交付署名：" + name)
	check("E:/" not in page.credits_text.text and "E:\\" not in page.credits_text.text, "不显示制作者本机路径")
	check(page.find_child("EndingCreditsPaper", true, false) != null and page.credits_text.get_theme_color("default_color") == Color("34413F"), "浅色纸面承托深墨正文")
	for dimensions in [Vector2i(1600, 900), Vector2i(1440, 900), Vector2i(1200, 900), Vector2i(2100, 900), Vector2i(960, 720)]:
		root.size = dimensions
		page.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		page.size = Vector2(dimensions)
		await frames()
		var available := Rect2(Vector2.ZERO, Vector2(dimensions)).grow(1)
		check(available.encloses(page.credits_scroll.get_global_rect()) and available.encloses(page.complete_button.get_global_rect()), "片尾正文和操作完整位于显示区：" + str(dimensions))
		check(page.credits_text.size.x <= page.credits_scroll.size.x + 1, "长来源链接在正文宽度内换行：" + str(dimensions))
		check(page.credits_scroll.get_v_scroll_bar().max_value > page.credits_scroll.size.y, "长署名完整滚动：" + str(dimensions))
	root.size = Vector2i(1600, 900)
	page.size = Vector2(1600, 900)
	await frames()
	page.credits_scroll.scroll_vertical = 320
	await frames()
	var scroll_before := page.credits_scroll.scroll_vertical
	page.hide()
	page.open()
	await frames()
	check(page.credits_scroll.scroll_vertical == scroll_before, "菜单返回保留署名阅读位置")
	await click(page.menu_button)
	check(menu_requests == 1 and not session.case_state.data.ending_completed, "真实点击菜单只请求菜单")
	if OS.get_cmdline_user_args().has("--capture"):
		page.credits_scroll.scroll_vertical = 0
		await frames()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://../.local/final-ending-ui.png")
	await click(page.complete_button)
	check(session.case_state.data.ending_completed and checkpoints == 1 and completions == 1, "真实点击结束提交片尾完成并返回标题")
	await click(page.complete_button)
	check(checkpoints == 1 and completions == 1, "重复点击不重复提交片尾")
	page.reset_page()
	check(not page.built and not page.visible and page.get_child_count() == 0, "重开案件清理片尾页面")
	print("FINAL_ENDING_UI: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
