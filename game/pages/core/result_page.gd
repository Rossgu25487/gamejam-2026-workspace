extends VBoxContainer
## 完整回应／待收／已收／失败页。动画结束只开放操作，不替玩家确认或收下。

signal basis_requested(sources: Array)
const UI = preload("res://pages/core/page_controls.gd")
var service: Node

func render(core: Node) -> void:
	service = core
	UI.clear(self)
	var result: Dictionary = core.state.current_result
	if core.state.mode == "failure": UI.label(self, core.ui("UI_CORE_FAILURE_TITLE"), 30)
	else: UI.label(self, "等待收下推论" if core.state.mode == "pending" else ("已收下推论" if core.state.mode == "collected" else "核对回应"), 28)
	# 长依据、回应与新推论只滚动正文区；收下／重试等操作固定在底部。
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	if not result.is_empty():
		var package = core.get_parent().get("configuration")
		var portrait: String = str(package.definition.get("response_portraits", {}).get(str(result.get("node", "")), "")) if package != null else ""
		if not portrait.is_empty():
			var path: String = package.resource_path(portrait)
			if ResourceLoader.exists(path):
				var image := TextureRect.new()
				image.texture = load(path)
				image.custom_minimum_size = Vector2(112, 112)
				image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				image.mouse_filter = Control.MOUSE_FILTER_IGNORE
				content.add_child(image)
		var comparison: Dictionary = result.get("comparison", {})
		var target: Dictionary = result.get("target_ref", {})
		var target_text := ""
		if target.get("target_kind") == "statement": target_text = core.catalog.text(core.catalog.data.statements[target.statement_ref.statement_id].text)
		elif target.get("target_kind") == "reasoning": target_text = core.catalog.text(target.get("question_text_id", ""))
		UI.label(content, "核对目标：" + target_text, 18)
		if not str(comparison.get("statement_quote", "")).is_empty(): UI.label(content, "对应句段：" + comparison.statement_quote, 18)
		for item in comparison.get("quotes", []):
			UI.label(content, core.catalog.text(core.catalog.data.contents[item.ref.content_id].title) + "：" + item.quote, 18)
		if not str(result.get("confirmed_scope", "")).is_empty(): UI.label(content, "成立范围：" + result.confirmed_scope, 18)
		_result_text(content, core.catalog.text(core.catalog.data.nodes[result.node].text))
		if result.get("feedback", "") == "incorrect" and not str(result.get("reason_text_id", "")).is_empty():
			UI.label(content, core.ui("UI_CORE_ERROR_REASON_TITLE"), 22)
			_result_text(content, core.catalog.text(result.reason_text_id))
		if not str(result.get("inference_content_id", "")).is_empty():
			var c: Dictionary = core.catalog.data.contents[result.inference_content_id]
			UI.label(content, core.catalog.text(c.title), 24)
			_result_text(content, core.catalog.text(c.body))
		UI.button(self, core.ui("UI_CORE_REVIEW_BASIS"), basis_requested.emit.bind(result.used_sources))
	UI.label(self, "%s：%d / 3" % [core.ui("UI_CORE_CHANCES_LABEL"), int(core.state.chances[core.state.question_id])], 18)
	var enabled: bool = not core.presenting
	if core.state.mode == "pending":
		UI.button(self, core.ui("UI_CORE_COLLECT_INFERENCE"), core.collect_inference.bind(result.result_id, result.inference_content_id), enabled)
	elif core.state.mode == "failure":
		UI.button(self, core.ui("UI_COMMON_RETRY"), core.retry_question, enabled)
		UI.button(self, core.ui("UI_CORE_DEFER"), core.continue_result.bind("defer"), enabled)
	elif result.get("feedback") == "full":
		UI.button(self, core.ui("UI_TITLE_CONTINUE"), core.continue_result, enabled)
		for id in core.catalog.data.nodes[result.node].get("next_questions", []):
			UI.button(self, core.catalog.text(core.catalog.data.questions[id].title), core.next_question.bind(id), enabled)
	else:
		UI.button(self, core.ui("UI_CORE_RESELECT"), core.continue_result.bind("reselect"), enabled)
		UI.button(self, core.ui("UI_CORE_DEFER"), core.continue_result.bind("defer"), enabled)
		if result.get("feedback") == "partial":
			for ref in core.store.list_refs({}):
				if ref not in core.draft().slots:
					UI.button(self, "补入 " + core.catalog.text(core.catalog.data.contents[ref.content_id].title), core.supplement_source.bind(ref.content_id), enabled)

func _result_text(parent: Control, text: String) -> void:
	var body := UI.body(parent, text, 0)
	body.fit_content = true
	body.scroll_active = false
