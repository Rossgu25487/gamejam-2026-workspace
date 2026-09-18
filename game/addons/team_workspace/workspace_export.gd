@tool
extends EditorExportPlugin


func _get_name() -> String:
	return "TeamWorkspaceEditorOnly"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with("res://addons/team_workspace/"):
		skip()
