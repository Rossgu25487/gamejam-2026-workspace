extends Control
signal resume_requested
signal save_requested
signal load_requested
signal settings_requested
signal return_title_requested
signal exit_requested
@onready var resume_button: Button = $PanelContainer/VBoxContainer/Resume
@onready var save_button: Button = $PanelContainer/VBoxContainer/Save
@onready var load_button: Button = $PanelContainer/VBoxContainer/Load
@onready var settings_button: Button = $PanelContainer/VBoxContainer/Settings
@onready var return_title_button: Button = $PanelContainer/VBoxContainer/ReturnTitle
@onready var exit_button: Button = $PanelContainer/VBoxContainer/Exit
func _ready() -> void:
 resume_button.pressed.connect(resume_requested.emit); save_button.pressed.connect(save_requested.emit); load_button.pressed.connect(load_requested.emit); settings_button.pressed.connect(settings_requested.emit); return_title_button.pressed.connect(return_title_requested.emit); exit_button.pressed.connect(exit_requested.emit); save_button.disabled = true; hide()
func show_page() -> void:
 show()
 if is_instance_valid(resume_button): resume_button.grab_focus()
func hide_page() -> void: hide()
func set_save_available(enabled: bool, reason: String = "") -> void: save_button.disabled = not enabled; save_button.tooltip_text = reason
