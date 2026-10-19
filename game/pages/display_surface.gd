extends Control
## 全部页面共用设置计算的有效显示区域；页面内部只布局自己的本地客户端。
var formal_config: RefCounted
func configure(config: RefCounted) -> void:
	formal_config = config
	theme = preload("res://pages/aurora/aurora_paper_theme.gd").build(config)

func bind_pages(pages: Array) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	for page in pages:
		page.reparent(self, false)
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_display_area(area: Rect2) -> void:
	position = area.position
	size = area.size
	if formal_config != null:
		theme = preload("res://pages/aurora/aurora_paper_theme.gd").build(formal_config, clampf(area.size.y / 900.0, 0.6, 1.4))

func set_preferences(_values: Dictionary) -> void:
	# 亮度由各页的场景图层消费，纸面、正文和按钮保持既定色值。
	modulate = Color.WHITE
