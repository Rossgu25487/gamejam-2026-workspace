extends "res://systems/debug_console/tabs/tab_base.gd"
## 调试页：关卡机会、游戏速度、屏幕状态信息，以及控制台自身的锁定与日志。
var chance_option: OptionButton
var chance_value: OptionButton
const CHANCE_VALUES := [0, 1, 2, 999]
var level_ids: Array = []
var speed_slider: HSlider
var speed_label: Label
var hud_check: CheckBox
var _syncing := false

func build() -> void:
	var content := scrolled()
	heading("关卡机会", content)
	hint("每个关卡有 999 次出错机会，机会为 0 会进入失败界面。用来测试失败与重试流程。", content)
	var row := hbox(content)
	chance_option = option_button(["全部关卡"], row)
	for id in config().questions:
		level_ids.append(str(id))
		chance_option.add_item(str(id))
	caption("设为", row)
	chance_value = option_button(["0 次", "1 次", "2 次", "999 次"], row, 3)
	make_button("应用", _apply_chances, row)
	var quick := flow(content)
	run_button("全部关卡补满 999 次", "chances all 999", quick)
	run_button("全部关卡清零（走失败界面）", "chances all 0", quick)
	run_button("查看各关卡机会", "chances", quick)
	content.add_child(HSeparator.new())
	heading("游戏速度", content)
	hint("加快或放慢游戏时间（对白打字、动画、计时），调试时可以加速等待。", content)
	var speed_row := hbox(content)
	speed_slider = HSlider.new()
	speed_slider.min_value = 0.1
	speed_slider.max_value = 8.0
	speed_slider.step = 0.1
	speed_slider.value = 1.0
	speed_slider.custom_minimum_size.x = 320
	speed_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	speed_slider.focus_mode = Control.FOCUS_NONE
	speed_slider.value_changed.connect(_slider_preview)
	speed_slider.drag_ended.connect(_slider_commit)
	speed_row.add_child(speed_slider)
	speed_label = Label.new()
	speed_label.custom_minimum_size.x = 80
	speed_row.add_child(speed_label)
	var presets := flow(content)
	for value in ["0.5", "1", "2", "4", "8"]: run_button("%s 倍" % value, "speed " + value, presets)
	content.add_child(HSeparator.new())
	heading("屏幕状态信息", content)
	hud_check = check_box("在屏幕左下角显示章节、地点、模式、帧率等", content)
	hud_check.toggled.connect(func(on): if not _syncing and on != console.hud_enabled: console.run("hud on" if on else "hud off"))
	content.add_child(HSeparator.new())
	heading("控制台", content)
	var tools := flow(content)
	make_button("锁定控制台（需再输入 super）", func(): console.run("lock"), tools)
	make_button("清空日志", func(): console.clear_log(), tools)
	make_button("复制日志", func(): console.copy_log(), tools)
	run_button("显示全部命令（help）", "help", tools)

func refresh() -> void:
	if not built: return
	_syncing = true
	speed_slider.set_value_no_signal(Engine.time_scale)
	speed_label.text = "%.1f 倍" % Engine.time_scale
	hud_check.set_pressed_no_signal(console.hud_enabled)
	_syncing = false
	var active := in_game()
	chance_option.disabled = not active
	chance_value.disabled = not active

func _slider_preview(value: float) -> void:
	if not _syncing: speed_label.text = "%.1f 倍" % value

## 拖动过程中只预览数字，松手时才真正设置并写一行日志。
func _slider_commit(changed: bool) -> void:
	if changed and not _syncing: console.run("speed %.1f" % speed_slider.value)

func _apply_chances() -> void:
	var target: String = "all" if chance_option.selected <= 0 else str(level_ids[chance_option.selected - 1])
	var value: int = int(CHANCE_VALUES[clampi(chance_value.selected, 0, CHANCE_VALUES.size() - 1)])
	console.run("chances %s %d" % [target, value])
