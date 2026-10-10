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
	if not result.is_empty():
		UI.body(self, core.catalog.text(core.catalog.data.nodes[result.node].text), 190)
		if not str(result.get("inference_content_id", "")).is_empty():
			var c: Dictionary = core.catalog.data.contents[result.inference_content_id]
			UI.label(self, core.catalog.text(c.title), 24)
			UI.body(self, core.catalog.text(c.body), 170)
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
