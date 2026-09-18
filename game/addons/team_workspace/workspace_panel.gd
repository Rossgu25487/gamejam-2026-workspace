@tool
extends PanelContainer

const WorkspaceStore = preload("workspace_store.gd")
const WorkspaceTheme = preload("workspace_theme.gd")
const MarkdownView = preload("markdown_view.gd")
const GITHUB_URL := "https://github.com/Rossgu25487/gamejam-2026-workspace"

var repository_root := ""
var _store = WorkspaceStore.new()
var _roles: Array = []
var _active_role: Dictionary = {}
var _drafts: Dictionary = {}
var _remembered_role := "planner"
var _current: Dictionary = {}
var _selected_brief := ""
var _original_handoff := ""
var _handoff_loaded := false
var _loading_text := false
var _local_state_path := ""
var _persist_local := true
var _tabs: TabContainer
var _pointer_token := ""
var _selected_brief_sha := ""

var _title: Label
var _role_list: ItemList
var _role_heading: Label
var _role_paths: HFlowContainer
var _workflow: RichTextLabel
var _handoff: TextEdit
var _handoff_state: Label
var _save_button: Button
var _reload_button: Button
var _current_label: Label
var _brief_list: ItemList
var _brief_preview: TextEdit
var _brief_caption: Label
var _set_current_button: Button
var _open_brief_button: Button
var _status: Label
var _import_dialog: FileDialog
var _reload_dialog: ConfirmationDialog
var _basis_summary: Label
var _version_label: Label
var _planner_hint: Label
var _import_button: Button
var _github_button: Button
var _join_button: Button
var _refresh_button: Button
var _status_panel: PanelContainer


func setup(root_path: String, persist_local: bool = true) -> void:
	repository_root = root_path
	_persist_local = persist_local
	if is_node_ready():
		_local_state_path = "user://team_workspace_%s.cfg" % repository_root.sha256_text().substr(0, 12)
		_load_local_state()
		refresh_from_disk()


func get_controls() -> Dictionary:
	return {"roles": _role_list, "tabs": _tabs, "workflow": _workflow,
		"handoff": _handoff, "handoff_state": _handoff_state, "save_handoff": _save_button,
		"reload_handoff": _reload_button, "reload_dialog": _reload_dialog,
		"briefs": _brief_list, "brief_preview": _brief_preview, "current": _current_label,
		"set_current": _set_current_button, "open_brief": _open_brief_button,
		"import_dialog": _import_dialog, "status": _status,
		"import_brief": _import_button, "github": _github_button, "join_help": _join_button,
		"refresh": _refresh_button, "version_label": _version_label,
		"basis_summary": _basis_summary, "planner_hint": _planner_hint}


func select_role(role_id: String) -> bool:
	for index in range(_roles.size()):
		if _roles[index].id == role_id:
			_role_list.select(index)
			_on_role_selected(index)
			return true
	_message("找不到岗位：" + role_id, true)
	return false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	theme = WorkspaceTheme.make_theme()
	add_theme_stylebox_override("panel", WorkspaceTheme.box(WorkspaceTheme.PAGE, WorkspaceTheme.PAGE, 0))
	_local_state_path = "user://team_workspace_%s.cfg" % repository_root.sha256_text().substr(0, 12)
	_build_interface()
	_load_local_state()
	refresh_from_disk()


func _exit_tree() -> void:
	if is_instance_valid(_handoff):
		_remember_draft()
		_save_local_state()


func _build_interface() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	margin.add_child(page)
	var heading_row := HBoxContainer.new()
	page.add_child(heading_row)
	_title = _label("Game Jam 协作空间", 24)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	heading_row.add_child(_title)
	_github_button = _button(heading_row, "GitHub 仓库", _open_github)
	_join_button = _button(heading_row, "加入说明", _open_relative.bind("README.md"))
	var basis_row := HBoxContainer.new()
	page.add_child(basis_row)
	_basis_summary = _label("当前依据 · 读取中", 15)
	_basis_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_basis_summary.clip_text = true
	_basis_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	basis_row.add_child(_basis_summary)
	_button(basis_row, "查看依据", func() -> void: _tabs.current_tab = 2)
	var sync_row := HBoxContainer.new()
	page.add_child(sync_row)
	var sync_notice := _label("本机副本 · Git 同步文件 · GitHub 管理成员权限", 13)
	sync_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_notice.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	sync_row.add_child(sync_notice)
	_version_label = _label("本机版本 · 尚未读取", 13)
	_version_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_version_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_version_label.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	sync_row.add_child(_version_label)
	var top_actions := HBoxContainer.new()
	basis_row.add_child(top_actions)
	_refresh_button = _button(top_actions, "刷新本机文件", refresh_from_disk)
	_button(top_actions, "仓库目录", _open_repository)
	_button(top_actions, "工作流目录", _open_relative.bind("岗位工作流"))
	var outer_split := HSplitContainer.new()
	outer_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_split.split_offset = 205
	page.add_child(outer_split)
	var navigation_panel := PanelContainer.new()
	navigation_panel.custom_minimum_size.x = 190
	outer_split.add_child(navigation_panel)
	var navigation := VBoxContainer.new()
	navigation_panel.add_child(navigation)
	navigation.add_child(_label("选择岗位", 17))
	_role_list = ItemList.new()
	_role_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_role_list.custom_minimum_size.y = 180
	_role_list.add_theme_stylebox_override("panel", WorkspaceTheme.box(WorkspaceTheme.SURFACE, WorkspaceTheme.SURFACE, 2))
	_role_list.item_selected.connect(_on_role_selected)
	navigation.add_child(_role_list)
	var role_hint := _label("先看步骤，再写交接。\n草稿保留在本机。\n岗位切换属于协作约定。", 13)
	role_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	role_hint.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	navigation.add_child(role_hint)
	var detail := VBoxContainer.new()
	detail.custom_minimum_size.x = 340
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_split.add_child(detail)
	_role_heading = _label("等待岗位清单", 20)
	detail.add_child(_role_heading)
	_role_paths = HFlowContainer.new()
	detail.add_child(_role_paths)
	var tabs := TabContainer.new()
	_tabs = tabs
	tabs.use_hidden_tabs_for_min_size = false
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(tabs)
	var workflow_tab := VBoxContainer.new()
	workflow_tab.name = "岗位工作流"
	tabs.add_child(workflow_tab)
	var workflow_caption := _label("本岗位工作流 · 只读，可选择并复制文字", 14)
	workflow_caption.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	workflow_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	workflow_tab.add_child(workflow_caption)
	_workflow = MarkdownView.new()
	_workflow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workflow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_workflow.custom_minimum_size.y = 100
	workflow_tab.add_child(_workflow)
	var handoff_tab := VBoxContainer.new()
	handoff_tab.name = "岗位交接"
	tabs.add_child(handoff_tab)
	var handoff_actions := HFlowContainer.new()
	handoff_tab.add_child(handoff_actions)
	_save_button = _button(handoff_actions, "保存交接", _save_handoff)
	_save_button.theme_type_variation = "WorkspacePrimaryButton"
	_reload_button = _button(handoff_actions, "重载磁盘版本", _request_reload_handoff)
	_button(handoff_actions, "复制草稿", _copy_draft)
	_button(handoff_actions, "交接目录", _open_relative.bind("workspace/handoffs"))
	_handoff_state = _label("尚未载入", 14)
	_handoff_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	handoff_tab.add_child(_handoff_state)
	_handoff = _text_area(true)
	_handoff.placeholder_text = "此岗位交接为空。可以写下：当前工作、产物位置、已验证内容、待协助事项。"
	_handoff.text_changed.connect(_on_handoff_changed)
	handoff_tab.add_child(_handoff)
	var planning_tab := VBoxContainer.new()
	planning_tab.name = "策划依据"
	tabs.add_child(planning_tab)
	_current_label = _label("当前依据：读取中", 15)
	_current_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	planning_tab.add_child(_current_label)
	var planning_actions := HFlowContainer.new()
	planning_tab.add_child(planning_actions)
	_import_button = _button(planning_actions, "导入原件…", _show_import_dialog)
	_import_button.theme_type_variation = "WorkspacePrimaryButton"
	_set_current_button = _button(planning_actions, "设为当前依据", _set_current)
	_open_brief_button = _button(planning_actions, "打开所选文件", _open_selected_brief)
	_button(planning_actions, "打开收件箱", _open_relative.bind("planning/inbox"))
	var formats := _label("MD / TXT 可预览；DOCX / PDF 用系统软件打开。导入保留源文件。", 13)
	formats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	formats.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	planning_tab.add_child(formats)
	_planner_hint = _label("当前岗位可查看原件；选择当前依据由策划负责。", 13)
	_planner_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_planner_hint.add_theme_color_override("font_color", WorkspaceTheme.MUTED)
	planning_tab.add_child(_planner_hint)
	var brief_split := HSplitContainer.new()
	brief_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brief_split.split_offset = 185
	planning_tab.add_child(brief_split)
	_brief_list = ItemList.new()
	_brief_list.custom_minimum_size = Vector2(140, 90)
	_brief_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_brief_list.item_selected.connect(_on_brief_selected)
	brief_split.add_child(_brief_list)
	var preview_column := VBoxContainer.new()
	preview_column.custom_minimum_size.x = 170
	preview_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brief_split.add_child(preview_column)
	_brief_caption = _label("选择入库文件后查看", 13)
	_brief_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_column.add_child(_brief_caption)
	_brief_preview = _text_area(false)
	preview_column.add_child(_brief_preview)
	_status_panel = PanelContainer.new()
	_status_panel.add_theme_stylebox_override("panel", WorkspaceTheme.box(WorkspaceTheme.ACCENT_SOFT, WorkspaceTheme.ACCENT_SOFT, 9))
	page.add_child(_status_panel)
	_status = _label("选择左侧岗位 → 查看工作流 → 编辑交接 → 保存后通过 Git 同步。", 14)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	_status_panel.add_child(_status)
	_import_dialog = FileDialog.new()
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.mode_overrides_title = false
	_import_dialog.title = "导入策划原件（保留源文件）"
	_import_dialog.filters = PackedStringArray(["*.md,*.txt,*.docx,*.pdf ; 策划文档"])
	_import_dialog.file_selected.connect(_import_brief)
	add_child(_import_dialog)
	_reload_dialog = ConfirmationDialog.new()
	_reload_dialog.title = "重新载入交接"
	_reload_dialog.dialog_text = "重新载入会放弃本岗位当前未保存的草稿。需要保留文字时，请先取消并复制草稿。"
	_reload_dialog.ok_button_text = "放弃草稿并载入"
	_reload_dialog.cancel_button_text = "保留草稿"
	_reload_dialog.confirmed.connect(_reload_handoff)
	add_child(_reload_dialog)


func refresh_from_disk() -> void:
	if not is_instance_valid(_role_list):
		return
	_remember_draft()
	var result: Dictionary = _store.read_manifest(repository_root)
	if not result.ok:
		_roles.clear()
		_role_list.clear()
		_active_role.clear()
		_handoff_loaded = false
		_role_heading.text = "岗位清单读取失败"
		_workflow.set_markdown(str(result.error))
		_handoff.editable = false
		_save_button.disabled = true
		_reload_button.disabled = true
		_message(result.error, true)
	else:
		var manifest: Dictionary = result.manifest
		_title.text = str(manifest.get("project_name", "Game Jam 协作空间"))
		_roles = manifest.roles
		_role_list.clear()
		var select_index := 0
		for index in range(_roles.size()):
			var role: Dictionary = _roles[index]
			_role_list.add_item(str(role.name))
			_role_list.set_item_tooltip(index, str(role.id))
			if str(role.id) == _remembered_role:
				select_index = index
		_role_list.select(select_index)
		_load_role(select_index)
	_refresh_planning()
	_refresh_version()


func _on_role_selected(index: int) -> void:
	_remember_draft()
	_load_role(index)
	_save_local_state()


func _load_role(index: int) -> void:
	_active_role = _roles[index]
	_remembered_role = str(_active_role.id)
	_role_heading.text = str(_active_role.name)
	for child in _role_paths.get_children():
		_role_paths.remove_child(child)
		child.queue_free()
	for path in _active_role.owned_paths:
		var path_button := _button(_role_paths, "打开 " + str(path).trim_suffix("/").get_file(), _open_relative.bind(str(path)))
		path_button.tooltip_text = str(path)
	var workflow_result: Dictionary = _store.read_text(repository_root, _active_role.workflow)
	_workflow.set_markdown(workflow_result.text if workflow_result.ok else workflow_result.error)
	if not workflow_result.ok:
		_message(workflow_result.error, true)
	var cached: Dictionary = _drafts.get(_remembered_role, {})
	if not cached.is_empty() and cached.get("path") == _active_role.handoff and str(cached.get("text", "")).replace("\r\n", "\n") != str(cached.get("original", "")).replace("\r\n", "\n"):
		_loading_text = true
		_original_handoff = str(cached.original)
		_handoff.text = str(cached.text)
		_handoff_loaded = true
		_handoff.editable = true
		_loading_text = false
		_update_handoff_state()
	else:
		_loading_text = true
		_handoff.text = ""
		_original_handoff = ""
		_handoff_loaded = false
		_loading_text = false
		_load_handoff_from_disk()
	_reload_button.disabled = false
	_update_planning_buttons()


func _load_handoff_from_disk() -> bool:
	var result: Dictionary = _store.read_text(repository_root, str(_active_role.handoff))
	if not result.ok:
		_handoff_loaded = false
		_handoff.editable = false
		_save_button.disabled = true
		_handoff_state.text = str(result.error)
		_message(result.error, true)
		return false
	_loading_text = true
	_original_handoff = str(result.text)
	_handoff.text = _original_handoff
	_handoff_loaded = true
	_handoff.editable = true
	_loading_text = false
	_update_handoff_state()
	return true


func _on_handoff_changed() -> void:
	if not _loading_text:
		_update_handoff_state()


func _update_handoff_state() -> void:
	var dirty := _has_unsaved_handoff()
	_save_button.disabled = not _handoff_loaded or not dirty
	_handoff_state.text = "%s · %s" % ["有未保存草稿；保存后仍需 Git 同步" if dirty else "本机交接版本", str(_active_role.get("handoff", ""))]
	_handoff_state.add_theme_color_override("font_color", WorkspaceTheme.ACCENT if dirty else WorkspaceTheme.MUTED)


func _remember_draft() -> void:
	if _handoff_loaded and not _active_role.is_empty() and is_instance_valid(_handoff):
		if _has_unsaved_handoff():
			_drafts[str(_active_role.id)] = {"path": _active_role.handoff, "original": _original_handoff, "text": _handoff.text}
		else:
			_drafts.erase(str(_active_role.id))


func _has_unsaved_handoff() -> bool:
	return _handoff_loaded and _handoff.text.replace("\r\n", "\n") != _original_handoff.replace("\r\n", "\n")


func _save_handoff() -> void:
	if not _handoff_loaded or _active_role.is_empty():
		return
	var result: Dictionary = _store.save_handoff(repository_root, _active_role.handoff, _handoff.text, _original_handoff)
	if result.ok:
		_original_handoff = _handoff.text
		_update_handoff_state()
		_message("岗位交接已保存到本机。需要通过 Git 同步后，其他成员才能取得更新。")
	else:
		_message(result.error, true)
	_remember_draft()
	_save_local_state()


func _request_reload_handoff() -> void:
	if _active_role.is_empty():
		return
	if _has_unsaved_handoff():
		_reload_dialog.popup_centered(Vector2i(480, 180))
	else:
		_reload_handoff()


func _reload_handoff() -> void:
	if _load_handoff_from_disk():
		_remember_draft()
		_save_local_state()
		_message("已载入磁盘上的最新交接记录。")


func _copy_draft() -> void:
	DisplayServer.clipboard_set(_handoff.text)
	_message("当前草稿已复制，可先保留再重新载入磁盘版本。")


func _refresh_planning(select_path: String = "") -> void:
	var current_result: Dictionary = _store.read_current(repository_root)
	_current.clear()
	_pointer_token = ""
	if current_result.ok:
		_current = current_result.current
		_pointer_token = current_result.pointer_text
		if _current.status == "pending":
			_current_label.text = "当前依据：待定。入库文档由策划选择后生效。"
			_basis_summary.text = "当前依据 · 待定"
		else:
			_current_label.text = "当前依据：%s · 第 %d 版" % [_current.title, int(_current.revision)]
			_current_label.tooltip_text = str(_current.path)
			_basis_summary.text = "当前依据 · %s · v%d" % [_current.title, int(_current.revision)]
		_basis_summary.add_theme_color_override("font_color", WorkspaceTheme.INK)
		if current_result.source_changed:
			_current_label.text += "\n" + str(current_result.notice)
			_basis_summary.text += " · 原件待核对"
			_basis_summary.add_theme_color_override("font_color", WorkspaceTheme.ERROR)
			_message(current_result.notice, true)
	else:
		_current_label.text = "当前依据读取失败：" + str(current_result.error)
		_basis_summary.text = "当前依据 · 读取失败，请查看策划依据页"
		_basis_summary.add_theme_color_override("font_color", WorkspaceTheme.ERROR)
		_message(current_result.error, true)
	_basis_summary.tooltip_text = _current_label.text
	var result: Dictionary = _store.list_briefs(repository_root)
	var restore_path := select_path if not select_path.is_empty() else _selected_brief
	_brief_list.clear()
	_selected_brief = ""
	_selected_brief_sha = ""
	if not result.ok:
		_brief_preview.text = str(result.error)
		_brief_caption.text = "策划案列表读取失败"
		_message(result.error, true)
		_update_planning_buttons()
		return
	var restore_index := -1
	for path in result.paths:
		var index := _brief_list.add_item(str(path).get_file())
		_brief_list.set_item_metadata(index, path)
		_brief_list.set_item_tooltip(index, path)
		if path == restore_path:
			restore_index = index
	if restore_index < 0 and not _current.is_empty():
		for index in range(_brief_list.item_count):
			if _brief_list.get_item_metadata(index) == _current.path:
				restore_index = index
	if restore_index >= 0:
		_brief_list.select(restore_index)
		_on_brief_selected(restore_index)
	else:
		_brief_preview.text = ""
		_brief_preview.placeholder_text = "还没有入库文档。\n\n第一步：点击上方“导入原件…”。\n第二步：选择文档并查看。\n第三步：由策划设为当前依据。" if _brief_list.item_count == 0 else "从左侧选择一份策划案。"
		_brief_caption.text = "尚无入库文档" if _brief_list.item_count == 0 else "选择后预览"
	_update_planning_buttons()


func _on_brief_selected(index: int) -> void:
	_selected_brief = str(_brief_list.get_item_metadata(index))
	_selected_brief_sha = ""
	var hash_result: Dictionary = _store.get_brief_sha256(repository_root, _selected_brief)
	if hash_result.ok:
		_selected_brief_sha = str(hash_result.sha256)
	else:
		_message(hash_result.error, true)
	_brief_caption.text = _selected_brief.get_file()
	_brief_caption.tooltip_text = _selected_brief + "\nSHA-256: " + _selected_brief_sha
	if _selected_brief.get_extension().to_lower() in ["md", "txt"]:
		var result: Dictionary = _store.read_text(repository_root, _selected_brief)
		_brief_preview.text = str(result.text) if result.ok else str(result.error)
		_brief_preview.placeholder_text = "此文档内容为空。"
		if not result.ok:
			_message(result.error, true)
	else:
		_brief_preview.text = "此处保留入库原件，不自动解析 Office 或 PDF。\n\n请点击上方“打开所选文件”。"
	_update_planning_buttons()


func _update_planning_buttons() -> void:
	_set_current_button.disabled = _active_role.get("id", "") != "planner" or _selected_brief_sha.is_empty() or _current.is_empty()
	_set_current_button.tooltip_text = "当前岗位为策划时可选择依据。这是协作约定，不是安全权限。"
	_open_brief_button.disabled = _selected_brief.is_empty()
	_planner_hint.text = "策划岗位：核对所选文档后，可设为当前依据。" if _active_role.get("id", "") == "planner" else "当前岗位只读查看依据；由策划确认版本。这是协作约定。"


func _show_import_dialog() -> void:
	_import_dialog.current_dir = repository_root
	_import_dialog.popup_centered_clamped(Vector2i(900, 600), 0.8)


func _import_brief(source: String) -> void:
	var result: Dictionary = _store.import_brief(repository_root, source)
	if not result.ok:
		_message(result.error, true)
		return
	_refresh_planning(result.path)
	_message("已复制原件至 %s；源文件未修改，同名文件不会被覆盖。" % result.path)


func _set_current() -> void:
	if _active_role.get("id", "") != "planner":
		_message("请由策划岗位选择当前依据。此限制属于团队协作约定。", true)
		return
	if _pointer_token.is_empty() or _selected_brief_sha.is_empty():
		_message("请先刷新并选择一份可读取的入库文档。", true)
		return
	var result: Dictionary = _store.set_current(repository_root, _selected_brief, _pointer_token, _selected_brief_sha)
	if result.ok:
		_refresh_planning(_selected_brief)
		_message("当前依据已更新到本机；请通过 Git 同步 planning/current.json 与入库文件。")
	else:
		_message(result.error, true)


func _open_selected_brief() -> void:
	if not _selected_brief.is_empty():
		_open_relative(_selected_brief)


func _open_repository() -> void:
	_shell_open(repository_root)


func _open_github() -> void:
	var result := OS.shell_open(GITHUB_URL)
	if result != OK:
		_message("无法打开 GitHub 仓库链接：%s" % error_string(result), true)


func _refresh_version() -> void:
	var git_marker := repository_root.path_join(".git")
	if not FileAccess.file_exists(git_marker) and not DirAccess.dir_exists_absolute(git_marker):
		_version_label.text = "版本状态未读取 · 此目录没有 Git 信息"
		_version_label.tooltip_text = "仅检查当前工作区，不借用父目录的仓库状态。文件浏览仍可使用。"
		return
	var git_executable := _find_git()
	if git_executable.is_empty():
		_version_label.text = "版本状态未读取 · 未找到可用 Git"
		_version_label.tooltip_text = "当前进程的 PATH 中未找到 Git 可执行文件。未执行同步或切换。"
		return
	var status := _run_git(git_executable, ["status", "--porcelain", "--untracked-files=normal"])
	var branch := _run_git(git_executable, ["symbolic-ref", "--quiet", "--short", "HEAD"])
	var commit := _run_git(git_executable, ["rev-parse", "--short=8", "--verify", "--quiet", "HEAD"])
	if status.code != 0 or branch.code not in [0, 1] or commit.code not in [0, 1]:
		_version_label.text = "版本状态未读取 · Git 检查未成功"
		_version_label.tooltip_text = "本地 Git 命令未成功。文件浏览仍可使用；没有执行联网、分支切换或重置。"
		return
	if commit.code == 1 and branch.code != 0:
		_version_label.text = "版本状态未读取 · 无法确认当前分支与提交"
		return
	var branch_name := str(branch.output) if branch.code == 0 else "分离 HEAD"
	var commit_name := str(commit.output) if commit.code == 0 else "尚无提交"
	var changes := "有未提交改动" if not str(status.output).is_empty() else "工作区干净"
	_version_label.text = "%s · %s · %s" % [branch_name, commit_name, changes]
	_version_label.tooltip_text = "本机版本：" + _version_label.text + "\n刷新时读取本地状态，不自动联网同步。"


func _find_git() -> String:
	var windows := OS.get_name() == "Windows"
	var separator := ";" if windows else ":"
	var filename := "git.exe" if windows else "git"
	for entry in OS.get_environment("PATH").split(separator, false):
		var directory := entry.strip_edges().trim_prefix("\"").trim_suffix("\"")
		if directory.is_absolute_path():
			var candidate := directory.path_join(filename)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


func _run_git(executable: String, arguments: Array) -> Dictionary:
	var output: Array = []
	var command := PackedStringArray(["--no-optional-locks", "-C", repository_root])
	for argument in arguments:
		command.append(str(argument))
	var code := OS.execute(executable, command, output, true, false)
	return {"code": code, "output": "".join(output).strip_edges()}


func _open_relative(relative_path: String) -> void:
	var checked: Dictionary = _store.resolve_path(repository_root, relative_path)
	if checked.ok:
		_shell_open(checked.absolute_path)
	else:
		_message(checked.error, true)


func _shell_open(absolute_path: String) -> void:
	if not FileAccess.file_exists(absolute_path) and not DirAccess.dir_exists_absolute(absolute_path):
		_message("文件或目录不存在：%s" % absolute_path, true)
		return
	var result := OS.shell_open(absolute_path)
	if result != OK:
		_message("无法用系统软件打开：%s（%s）" % [absolute_path, error_string(result)], true)


func _load_local_state() -> void:
	if not _persist_local:
		return
	if not FileAccess.file_exists(_local_state_path):
		return
	var config := ConfigFile.new()
	var result := config.load(_local_state_path)
	if result != OK:
		_message("本机岗位偏好或草稿读取失败：%s" % error_string(result), true)
		return
	_remembered_role = str(config.get_value("workspace", "role", "planner"))
	var value: Variant = config.get_value("workspace", "drafts", {})
	if value is Dictionary:
		_drafts = value
	else:
		_message("本机草稿格式有误；共享交接文件未修改。", true)


func _save_local_state() -> void:
	if not _persist_local:
		return
	var config := ConfigFile.new()
	config.set_value("workspace", "role", _remembered_role)
	config.set_value("workspace", "drafts", _drafts)
	var result := config.save(_local_state_path)
	if result != OK:
		push_warning("协作空间：本机岗位偏好或草稿保存失败：%s" % error_string(result))
		if is_instance_valid(_status):
			_message("本机岗位偏好或草稿保存失败：%s。当前编辑内容仍保留在界面。" % error_string(result), true)


func _message(message: String, is_error := false) -> void:
	_status.text = ("需要处理：" if is_error else "") + message
	_status.add_theme_color_override("font_color", WorkspaceTheme.ERROR if is_error else WorkspaceTheme.INK)
	var background := Color("f8eae4") if is_error else WorkspaceTheme.ACCENT_SOFT
	_status_panel.add_theme_stylebox_override("panel", WorkspaceTheme.box(background, background, 9))


func _label(text: String, font_size := 0) -> Label:
	var label := Label.new()
	label.text = text
	if font_size > 0:
		label.add_theme_font_size_override("font_size", font_size)
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 34
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _text_area(editable: bool) -> TextEdit:
	var editor := TextEdit.new()
	editor.editable = editable
	editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size.y = 90
	editor.add_theme_font_size_override("font_size", 16)
	editor.add_theme_color_override("font_color", WorkspaceTheme.INK)
	editor.add_theme_color_override("font_readonly_color", WorkspaceTheme.INK)
	editor.add_theme_color_override("font_selected_color", WorkspaceTheme.INK)
	editor.add_theme_color_override("selection_color", Color("cfe3da"))
	editor.add_theme_constant_override("line_spacing", 4)
	return editor
