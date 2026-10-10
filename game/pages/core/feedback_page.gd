extends PanelContainer
## 可暂停的纸面白模。只播放显示时钟，业务提交由玩法服务执行。

signal completed
const UI = preload("res://pages/core/page_controls.gd")
var elapsed := 0.0
var duration := 1.0
var active := false
var paused := false
var reduce_motion := false
var bar: ProgressBar
var sheet: VBoxContainer

func _ready() -> void:
	sheet = VBoxContainer.new()
	add_child(sheet)
	hide()
	set_process(false)

func play(display: Dictionary) -> void:
	UI.clear(sheet)
	elapsed = 0
	duration = maxf(0.01, float(display.duration_ms) / 1000.0)
	active = true
	UI.label(sheet, {"key_break": "击破", "key_inference": "涌现", "key_insight_fact": "新确认", "progress": "递进核明", "collect": "收卡", "retry": "重新起稿"}.get(display.kind, "核对反馈"), 34)
	UI.label(sheet, "纸面白模 · 演出完成后显示完整内容", 18)
	bar = ProgressBar.new()
	sheet.add_child(bar)
	UI.button(sheet, "跳过表现", finish)
	show()
	set_process(true)

func _process(delta: float) -> void:
	if not active or paused: return
	elapsed += delta
	bar.value = 100 * elapsed / duration
	if not reduce_motion:
		var pulse := 1.0 + sin(elapsed / duration * PI) * 0.04
		sheet.scale = Vector2(pulse, pulse)
	if elapsed >= duration: finish()

func finish() -> void:
	if not active or paused: return
	active = false
	set_process(false)
	sheet.scale = Vector2.ONE
	hide()
	completed.emit()

func cancel() -> void:
	active = false
	set_process(false)
	hide()
