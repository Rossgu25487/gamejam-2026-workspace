extends RefCounted
## 目标导航的纯布局计算：HUD 面板位置与最大高度、回顾逻辑画布的缩放与居中。
## 不含节点，便于用任意窗口尺寸直接回归两种参考窗口的数值。

const BOTTOM_MARGIN := 20.0 # 面板下边距，窗口很矮时压缩最大高度


static func vec(values: Array) -> Vector2:
	return Vector2(float(values[0]), float(values[1]))


static func hud_layout(viewport: Vector2, hud: Dictionary) -> Dictionary:
	if hud.get("final_paper", false):
		var factor := viewport.y / 900.0
		var margin := float(hud.get("safe_margin_px", 24)) * factor
		var width := minf(float(hud.get("hud_expand_max_width_px", 520)) * factor, viewport.x - margin * 2)
		return {"compact": viewport.x / maxf(1, viewport.y) < 1.5, "left": maxf(margin, viewport.x - margin - width), "top": margin,
			"width": width, "max_height": minf(430 * factor, viewport.y - margin * 2)}
	# 在 1920x1080 与 1280x800 两种参考窗口之间按宽度选取；其他尺寸保持右侧边距并限制在可视范围内。
	var base_viewport := vec(hud["base_viewport"])
	var compact_viewport := vec(hud["compact_viewport"])
	var compact := viewport.x < (base_viewport.x + compact_viewport.x) * 0.5
	var reference := compact_viewport if compact else base_viewport
	var rect: Array = hud["compact_panel_rect"] if compact else hud["base_panel_rect"]
	var width := float(rect[2])
	var right_margin := reference.x - float(rect[0]) - width # 两种窗口各自的右边距：58 与 48
	var left := maxf(0.0, viewport.x - right_margin - width)
	var top := float(rect[1])
	var max_height := float(hud["compact_max_height_px"] if compact else hud["panel_max_height_px"])
	max_height = minf(max_height, maxf(0.0, viewport.y - top - BOTTOM_MARGIN))
	return {"compact": compact, "left": left, "top": top, "width": width, "max_height": max_height}


static func review_transform(viewport: Vector2, logical: Vector2) -> Dictionary:
	# 回顾按 1600x900 逻辑窗口设计，按共用适配规则等比缩放并居中。
	var factor := minf(viewport.x / logical.x, viewport.y / logical.y)
	return {"scale": factor, "origin": (viewport - logical * factor) * 0.5}
