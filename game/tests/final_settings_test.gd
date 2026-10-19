extends SceneTree
const Settings = preload("res://systems/game_settings/settings_service.gd")
var failures: Array[String] = []
func check(value: bool, label: String) -> void:
 if not value: failures.append(label); push_error(label)
func _initialize() -> void:
 call_deferred("_run")

func _run() -> void:
 var s := Settings.new()
 root.add_child(s)
 s.storage_path = "user://final_settings_regression.json"
 DirAccess.remove_absolute(ProjectSettings.globalize_path(s.storage_path))
 s.initialize()
 check(s.values.size() == 12 and s.values.window_width == 1600 and s.values.text_speed == 2, "正式设置十二项默认")
 check(s.set_value("brightness", 125, false) and s.set_value("text_speed", 3, false), "亮度与文字速度即时偏好")
 check(s.begin_display_preview({"display_mode": 2, "window_width": 1280, "window_height": 720, "aspect_ratio": 3}), "显示预览形成候选")
 check(s.values.display_mode == 1 and s.values.aspect_ratio == 0, "预览不写已确认显示")
 check(s.save(), "预览期间安全偏好可保存")
 var data = JSON.parse_string(FileAccess.get_file_as_string(s.storage_path))
 check(data.display_mode == 1 and data.brightness == 125 and data.version == 2, "保存排除未确认显示候选")
 s.cancel_display_preview()
 check(not s.display_preview_active and s.values.display_mode == 1, "回退撤销候选")
 s.begin_display_preview({"display_mode": 2})
 check(s.keep_display_preview() and s.values.display_mode == 2, "保留后提交显示")
 var old := {"version": 1, "master_volume": 47, "bgm_volume": 35, "ambient_volume": 61, "effect_volume": 89, "mute": true, "reduce_motion": false}
 var file := FileAccess.open(s.storage_path, FileAccess.WRITE)
 file.store_string(JSON.stringify(old)); file.close()
 var restored := Settings.new()
 root.add_child(restored)
 restored.storage_path = s.storage_path
 restored.initialize()
 check(restored.values.master_volume == 47 and restored.values.mute and restored.values.window_width == 1600 and restored.values.text_speed == 2, "格式一保留六项补新增默认")
 check(not restored.set_value("brightness", 49) and not restored.set_value("text_speed", 4), "新增字段拒绝无效值")
 DirAccess.remove_absolute(ProjectSettings.globalize_path(s.storage_path))
 var page := preload("res://pages/settings_page.tscn").instantiate()
 root.add_child(page)
 page.open(restored)
 await process_frame
 page._switch_tab("display")
 await process_frame
 check(page.mode_option.is_visible_in_tree() and not page.sliders.master_volume.is_visible_in_tree(), "设置显示页签独占控件")
 page.candidate_display = restored.confirmed_display()
 page.candidate_display.aspect_ratio = 3
 page._apply_display()
 await process_frame
 check(restored.display_preview_active and page.display_confirm.visible and page.close_button.disabled and not page.brightness_slider.editable, "显示预览阻断下层控件")
 page._revert_display()
 await process_frame
 await process_frame
 check(not restored.display_preview_active and not page.display_confirm.visible and page.close_button.disabled == false, "主动回退恢复设置操作")
 check(restored.effective_display_area(Vector2(1600, 900), 3) == Rect2(200, 0, 1200, 900), "四比三有效区居中")
 check(restored.effective_display_area(Vector2(1600, 900), 0) == Rect2(0, 0, 1600, 900), "自动比例使用完整客户区")
 check(restored.available_window_sizes(Vector2i(1024, 768)) == [Vector2i(960, 540), Vector2i(1024, 768)], "窗口预设按桌面过滤")
 page.close_page(); page.queue_free()
 s.queue_free(); restored.queue_free()
 if failures.is_empty(): print("FINAL_SETTINGS_PASS: 16 checks")
 quit(0 if failures.is_empty() else 1)
