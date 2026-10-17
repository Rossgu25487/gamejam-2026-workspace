extends RefCounted
## 猫手共用一根2800ms时轴；显示回执与计时分离，未显示稳定帧不记录首见。
var active := false
var touching := false
var elapsed := 0.0
var total_ms := 2800.0
var reduced := false
var reduced_latched := false
var purr_sent := false
var first_seen := false
var frame := 0
var config := {}

func enter(row: Dictionary, seen: bool, reduce_motion: bool) -> void:
	config = row.duplicate(true)
	first_seen = seen
	active = true
	touching = false
	elapsed = 0
	frame = 0
	reduced = reduce_motion
	reduced_latched = false
	purr_sent = false
	total_ms = float(row.pet_ms) + float(row.response_ms)

func touch() -> bool:
	if not active or touching: return false
	touching = true
	reduced_latched = reduced
	frame = 24 if reduced_latched else 0
	return true

func preferences(value: bool) -> void:
	reduced = value
	if touching and value: reduced_latched = true; frame = 24

func tick(ms: float) -> Dictionary:
	if not active or not touching: return {}
	elapsed = minf(total_ms, elapsed + ms)
	frame = 24 if reduced_latched else mini(55, int(elapsed / 50))
	var purr := elapsed >= 640 and not purr_sent
	if purr: purr_sent = true
	return {"purr": purr, "finished": elapsed >= total_ms, "frame": frame}

func displayed_frame(index: int) -> void:
	if touching and index >= 24: first_seen = true

func finish() -> void:
	active = false
	touching = false
	frame = 0
