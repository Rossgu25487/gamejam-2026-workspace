@tool
extends EditorPlugin

const WorkspacePanel = preload("workspace_panel.gd")
const WorkspaceExport = preload("workspace_export.gd")

var _panel: Control
var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_panel = WorkspacePanel.new()
	_panel.setup(ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir())
	EditorInterface.get_editor_main_screen().add_child(_panel)
	_export_plugin = WorkspaceExport.new()
	add_export_plugin(_export_plugin)
	_make_visible(false)


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)


func _has_main_screen() -> bool:
	return true


func _make_visible(is_visible: bool) -> void:
	if is_instance_valid(_panel):
		_panel.visible = is_visible


func _get_plugin_name() -> String:
	return "协作空间"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("FileList", "EditorIcons")
