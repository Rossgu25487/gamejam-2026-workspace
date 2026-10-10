@tool
extends EditorExportPlugin
## 编辑器专用导出插件：阻止协作工作台脚本进入游戏导出包。


func _get_name() -> String:
	return "TeamWorkspaceEditorOnly"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with("res://addons/team_workspace/"):
		skip()
