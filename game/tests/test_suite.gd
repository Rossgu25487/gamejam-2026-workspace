extends SceneTree

const CounterChecks = preload("res://tests/counter_checks.gd")
const Store = preload("res://addons/team_workspace/workspace_store.gd")
const WorkspacePanel = preload("res://addons/team_workspace/workspace_panel.gd")

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var counter_failures: Array[String] = await CounterChecks.new().run(self)
	failures.append_array(counter_failures)
	await _check_workspace()
	for failure in failures:
		printerr("CHECK FAILED: " + failure)
	if failures.is_empty():
		print("PASS: counter contracts, UI integration, eight-role routing, document import, current reference, handoff conflict protection and workspace controls.")
	else:
		printerr("FAIL: %d checks failed." % failures.size())
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failures.append("Cannot create test fixture " + path)
		return
	file.store_string(text)
	file.close()


func _check_workspace() -> void:
	var repo := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	var store := Store.new()
	var manifest_result: Dictionary = store.read_manifest(repo)
	_expect(manifest_result.ok, "real manifest loads")
	if not manifest_result.ok:
		return
	var manifest: Dictionary = manifest_result.manifest
	_expect(manifest.roles.size() == 8, "exactly eight roles")
	for role: Dictionary in manifest.roles:
		_expect(FileAccess.file_exists(repo.path_join(role.workflow)), "workflow exists: " + role.id)
		_expect(FileAccess.file_exists(repo.path_join(role.handoff)), "handoff exists: " + role.id)
	var sandbox := repo.path_join(".local/workspace-tests")
	DirAccess.make_dir_recursive_absolute(sandbox)
	_write(sandbox.path_join("workspace/manifest.json"), JSON.stringify(manifest))
	_write(sandbox.path_join("planning/current.json"), JSON.stringify({"status":"pending","path":"","title":"测试待定","revision":0,"updated_at":""}))
	for role: Dictionary in manifest.roles:
		_write(sandbox.path_join(role.workflow), "# " + role.name + "\n测试岗位说明\n")
		_write(sandbox.path_join(role.handoff), "# " + role.name + "\n未开始\n")
	_write(sandbox.path_join("workspace/handoffs/planner.md"), "# 策划\r\n未开始\r\n")
	_write(sandbox.path_join("sources/测试策划案.md"), "# 测试策划案\nREQ-TEST-001：一次输入加一。\n")
	_write(sandbox.path_join("planning/inbox/README.md"), "# 收件目录说明\n")
	_write(sandbox.path_join("sources/不支持.exe"), "fixture only")
	var original_hash := FileAccess.get_sha256(sandbox.path_join("sources/测试策划案.md"))
	var first: Dictionary = store.import_brief(sandbox, sandbox.path_join("sources/测试策划案.md"))
	var second: Dictionary = store.import_brief(sandbox, sandbox.path_join("sources/测试策划案.md"))
	_expect(first.ok and second.ok, "two original imports succeed")
	if not first.ok or not second.ok:
		return
	_expect(first.path != second.path, "same-name import never overwrites")
	_expect(FileAccess.get_sha256(sandbox.path_join(first.path)) == original_hash, "import preserves source bytes")
	_expect(FileAccess.get_sha256(sandbox.path_join("sources/测试策划案.md")) == original_hash, "source remains unchanged")
	_expect(store.read_current(sandbox).current.status == "pending", "import does not activate a design")
	_expect(not store.import_brief(sandbox, sandbox.path_join("sources/不支持.exe")).ok, "unsupported file rejected")
	_expect(not store.set_current(sandbox, "../outside.md").ok, "outside reference rejected")
	_expect(not store.set_current(sandbox, "planning/inbox/missing.md").ok, "missing reference rejected")
	_expect(not store.set_current(sandbox, "planning/inbox/README.md").ok, "instructions cannot become current design")
	_expect(not store.list_briefs(sandbox).paths.has("planning/inbox/README.md"), "instructions are hidden from design list")
	var selected: Dictionary = store.set_current(sandbox, first.path)
	_expect(selected.ok and selected.current.revision == 1, "explicit activation increments revision")
	_expect(store.read_current(sandbox).current.path == first.path, "current reference persists")
	_expect(selected.current.sha256 == original_hash, "active reference binds original bytes")
	var first_pointer: String = store.read_current(sandbox).pointer_text
	var previous_sha: String = store.get_brief_sha256(sandbox, second.path).sha256
	var second_selected: Dictionary = store.set_current(sandbox, second.path, first_pointer, previous_sha)
	_expect(second_selected.ok, "fresh pointer can activate another source")
	var stale_pointer: Dictionary = store.set_current(sandbox, first.path, first_pointer, original_hash)
	_expect(not stale_pointer.ok and stale_pointer.get("conflict", false), "old window cannot overwrite new current reference")
	_expect(store.read_current(sandbox).current.path == second.path, "new pointer preserved after stale attempt")
	var second_pointer: String = store.read_current(sandbox).pointer_text
	_write(sandbox.path_join(second.path), "# 原件已被外部修改\n")
	_expect(store.read_current(sandbox).source_changed, "source edit invalidates confirmed fingerprint")
	var changed_source: Dictionary = store.set_current(sandbox, second.path, second_pointer, previous_sha)
	_expect(not changed_source.ok and changed_source.get("content_changed", false), "changed preview cannot be silently confirmed")
	var confirmed: Dictionary = store.set_current(sandbox, second.path, second_pointer, store.get_brief_sha256(sandbox, second.path).sha256)
	_expect(confirmed.ok and not store.read_current(sandbox).source_changed, "explicitly reconfirmed source recovers")
	var path: String = "workspace/handoffs/gameplay.md"
	var before: String = store.read_text(sandbox, path).text
	_expect(store.save_handoff(sandbox, path, "# 外部先更新\n", before).ok, "handoff writes UTF8")
	var stale: Dictionary = store.save_handoff(sandbox, path, "# 旧稿\n", before)
	_expect(not stale.ok and stale.get("conflict", false), "stale handoff is rejected")
	_expect(store.read_text(sandbox, path).text == "# 外部先更新\n", "external update preserved")
	_expect(not store.save_handoff(sandbox, "planning/current.json", "bad", "").ok, "handoff cannot overwrite planning data")
	var panel := WorkspacePanel.new()
	panel.setup(sandbox, false)
	root.add_child(panel)
	await process_frame
	panel.select_role("planner")
	var controls: Dictionary = panel.get_controls()
	_expect(controls.roles.item_count == 8, "panel presents all eight roles")
	_expect(controls.save_handoff.disabled, "fresh Windows line endings do not create a false dirty draft")
	controls.import_dialog.file_selected.emit(sandbox.path_join("sources/测试策划案.md"))
	_expect(controls.briefs.item_count >= 3, "file dialog selection imports and refreshes")
	controls.briefs.select(0)
	controls.briefs.item_selected.emit(0)
	_expect(not controls.set_current.disabled, "planner can explicitly activate selected document")
	var revision_before: int = store.read_current(sandbox).current.revision
	controls.set_current.pressed.emit()
	_expect(store.read_current(sandbox).current.revision == revision_before + 1, "panel activation updates reference revision")
	controls.handoff.text = "# 通过界面保存的交接\n"
	controls.handoff.text_changed.emit()
	controls.save_handoff.pressed.emit()
	_expect(store.read_text(sandbox, "workspace/handoffs/planner.md").text == controls.handoff.text, "panel save reaches the correct role file")
	controls.handoff.text = "# 尚未保存的界面草稿\n"
	controls.handoff.text_changed.emit()
	_write(sandbox.path_join("workspace/handoffs/planner.md"), "# 并行修改\n")
	controls.save_handoff.pressed.emit()
	_expect(store.read_text(sandbox, "workspace/handoffs/planner.md").text == "# 并行修改\n", "panel cannot overwrite external changes")
	_expect(controls.handoff.text == "# 尚未保存的界面草稿\n", "conflicted local draft survives")
	panel.select_role("qa")
	_expect(controls.set_current.disabled, "non-planner cannot activate reference in panel")
	panel.queue_free()
	await process_frame
