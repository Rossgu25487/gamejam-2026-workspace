# CE跑测反馈 14–26 整改方案（代码改动草案）

> 性质：本文件是 **14–26 条反馈中“程序可修改”部分的精确改动方案**，已核实并提交。
> **已实际落库并提交**：#14、#18、#19、#20、#21 五处代码已改入源码并通过 headless 测试；#24 代码布线正确、属配置问题不改码；其余为待核实建议。
>
> - 基准分支：`codex/lead/local-setup`
> - 基准提交：`91cae10 feat(narrative): enhance scene management and pagination for narrative flow`
> - 本轮提交文件：`game/systems/objective/objective_service.gd`（#14）、`game/pages/aurora/aurora_scene_page.gd`（#18）、`game/pages/aurora/aurora_handbook_page.gd`（#19）、`game/pages/map_navigation/map_navigation_page.gd` + `map_board.gd`（#20/#21）、本文件
> - 状态标注：**已核实** = 已从代码定位并确认；**需实测** = 需 GUI 复现才能最终确认；**推断** = 逻辑推断，未见运行态证据。
> - **回炉加固（本次自检）**：#19 滚动时机由 `call_deferred` 改为下一帧 `process_frame`（`call_deferred` 仍可能早于容器排序）；#20 列表标题跳过空 `group_id`；#21 目标层无棋盘定义时回退整页重建。三处已重新通过 headless 测试。
>
> **本轮实测（headless，Godot 4.7.2 stable）**：import/parse EXITCODE=0 无解析错误；`aurora_page_test`（57）、`scene_interaction_test`（29）、`handbook_talk_records_test`（54）、`aurora_session_test`（CH02/SC02）、`aurora_core_test`（97 关系 / 18 问题）、`objective_navigation_test`（248）、`objective_navigation_page_test`（241）、`map_navigation_test`（7）、`map_input_test`（121）均 EXITCODE=0。#18/#19/#20/#21 为页面/棋盘层改动，行为与过渡观感仍需 GUI 点一遍确认。

## 0. 速览

| # | 问题 | 归属 | 类型 | 本文件处理方式 |
|---|---|---|---|---|
| 14 | 回顾展开时浮窗应收起 | integration（目标导航） | 代码 | ✅ 已落库并提交 |
| 15 | 检查货单黑屏 | 主程序/资源 | 资源 | 排查方法（非代码） |
| 16 | 点开默认已读 | gameplay + 策划 | 代码/决策 | 需策划拍板，附两种改法 |
| 17 | 地图快捷移动 | gameplay+美术+integration | 新功能 | 方案说明（不做） |
| 18 | 检查物件后应返回检查列表 | **gameplay** | 代码 | ✅ 已落库并提交 |
| 19 | 交谈记录默认最新 | **gameplay** | 代码 | ✅ 已落库并提交 |
| 20 | 地点列表分区楼层 | integration（地图） | 代码 | ✅ 已落库并提交 |
| 21 | 跨层地图花屏 | integration（地图） | 代码 | ✅ 已落库并提交 |
| 22 | 对白立绘错配 | 策划/美术配置 | 配置 | 排查方法（非代码） |
| 23 | 调查信息展示参考 | 策划/美术 | 设计 | 非代码 |
| 24 | 点角色重播 BGM | integration（音频）+配置 | 代码/配置 | 代码无 bug（配置排查） |
| 25 | 角色出场太多 | 策划 | 文本 | 非代码 |
| 26 | 点老头出帅哥 | 策划/美术配置 | 配置 | 排查方法（非代码） |

---

## 0. 逐条评价结论（贴云表格用）

| # | 问题 | 归类 | 处理 | 一句话结论 |
|---|---|---|---|---|
| 14 | 回顾展开时浮窗应收起 | 有bug，需要修复 | 已进行优化 | 展开回顾自动收起 HUD，返回调查恢复展开 |
| 15 | 检查货单黑屏 | 资源范畴 | 需主程序排查 | 会话逻辑正常，疑似资源缺失，需资源引用审计 |
| 16 | 点开默认已读 | 可以考虑，但是需要决策 | 待策划拍板 | 需明确“点开是否等于读完” |
| 17 | 地图快捷移动 | 可以考虑，但是需要决策 | 本次不做 | 新功能，需 gameplay/美术/integration 协同 |
| 18 | 检查物件后应返回检查列表 | 有bug，需要修复 | 已进行优化 | 读完单物件回到“检查物件”目录 |
| 19 | 交谈记录默认最新 | 有bug，需要修复 | 已进行优化 | 首次打开定位到最新段落 |
| 20 | 地点列表分区楼层 | 有bug，需要修复 | 已进行优化 | 列表按楼层分组插入标题 |
| 21 | 跨层地图花屏 | 有bug，需要修复 | 已进行优化 | 跨层中点原地换背景，不整页重建 |
| 22 | 对白立绘错配 | 策划美术范畴 | 配置核对 | 文案表 portrait_path/avatar_ref 逐条核对 |
| 23 | 调查信息展示参考 | 策划美术范畴 | 设计决策 | 非代码 |
| 24 | 点角色重播 BGM | 配置范畴，代码无bug | 配置核对 | 代码布线正确，核对角色话题 bgm_mode |
| 25 | 角色出场太多 | 策划美术范畴 | 文本项 | 非代码 |
| 26 | 点老头出帅哥 | 策划美术范畴 | 配置核对 | 人物字典立绘配置核对 |

> 归类沿用 Jerry 1–13 的标注口径：“已进行优化”= 已改码并通过 headless 测试；“可以考虑，但是需要决策”= 待拍板；“策划美术范畴”= 非代码、需对应岗位处理。程序侧处理者为 bcynuaa（副程序 A/B），日期 20261018。

---

## 1. #18 检查物件后直接返回“检查物件”目录（gameplay，✅ 已落库并提交）

**已核实**。根因：单一观察对象（`options.size() == 1`，或带 `inspect_entry_ref` 的物件）从场景热点进入时，`inspect()` 直接 `activate_entry(entry, context)`，其中 `context.kind == "inspection"`。读完回 `_show_context` 时，`inspection` 分支因 `options.size() <= 1` 直接 `current_context.clear()`，于是掉回主场景；玩家要继续看别的物件，就得再点一次“检查物件”。

**文件**：`game/pages/aurora/aurora_scene_page.gd`，`_show_context()`（约 129–131 行）。

**原代码**：
```gdscript
	elif context.get("kind") == "inspection":
		options = model.observation_options(str(context.get("object", "")))
		if options.size() <= 1: current_context.clear(); return
```

**改为**：
```gdscript
	elif context.get("kind") == "inspection":
		options = model.observation_options(str(context.get("object", "")))
		if options.size() <= 1:
			# 单一观察对象读完直接回到“检查物件”目录，而不是清空回主场景（反馈#18）。
			current_context = {"kind": "scene_items", "scene": context.get("scene", ""), "view": context.get("view", "")}
			_show_context(current_context)
			return
```

**说明**：
- 复用 `scene_items` 分支（`model.scene_options()`）重建目录覆盖层；该分支里按钮闭包捕获的 `context` 已是 `scene_items`，读完自然回到目录而非旧物件，返回路径正确。
- 递归深度恒为 1（`inspection` → `scene_items` → 建覆盖层即返回），无风险。
- 与“从目录点进单物件”的既有正确路径（`context` 为 `scene_items`）行为对齐，两路径统一。

**验证**：GUI 进入第一章，点一个只有单个观察项的物件热点 → 读完 → 应回到“检查物件”列表；再点“返回调查”才回主场景。headless 无需脚本变化，但 `aurora_session_test.gd` 应仍通过。

---

## 2. #19 交谈记录默认显示最新段落（gameplay，✅ 已落库并提交）

**已核实**。根因：手册“交谈记录”页签是滚动列表，`_library()` 对所有页签统一 `scroll.set_deferred("scroll_vertical", library_positions.get(scroll_key, 0))`，无存档位置时滚到顶部（最早）。`visible_history()` 为时间正序追加，最早在上、最新在下。

**文件**：`game/pages/aurora/aurora_handbook_page.gd`。

**(2a)** `_library()` 中 `else`（records）分支，追加一行默认定位（约 163–167 行之后）：

**原代码**：
```gdscript
	else:
		UI.button(root_box, "回到最新", func(): scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value)), not session.narrative.visible_history().is_empty())
		for row in session.narrative.visible_history():
			if str(row.get("text", "")).is_empty(): continue
			UI.label(list, str(row.get("speaker_name", "")), 22)
			_prose(list, str(row.text))
```

**改为**：
```gdscript
	else:
		UI.button(root_box, "回到最新", func(): scroll.set_deferred("scroll_vertical", int(scroll.get_v_scroll_bar().max_value)), not session.narrative.visible_history().is_empty())
		for row in session.narrative.visible_history():
			if str(row.get("text", "")).is_empty(): continue
			UI.label(list, str(row.get("speaker_name", "")), 22)
			_prose(list, str(row.text))
		# 交谈记录默认定位到最新段落，而不是停在最早处（反馈#19）。
		if not library_positions.has(scroll_key): _scroll_records_to_latest()
```

**(2b)** 新增辅助方法（可放在 `_library()` 之后）：
```gdscript
func _scroll_records_to_latest() -> void:
	# 滚动条 max_value 要等本帧布局完成后才正确；call_deferred 仍可能早于容器排序，等到下一帧再读。
	if is_instance_valid(library_scroll) and library_scroll.is_inside_tree():
		library_scroll.get_tree().process_frame.connect(_apply_records_latest, CONNECT_ONE_SHOT)

func _apply_records_latest() -> void:
	if is_instance_valid(library_scroll):
		library_scroll.scroll_vertical = int(library_scroll.get_v_scroll_bar().max_value)
```

**说明**：
- 只有“该页签无存档滚动位置”（首次打开）才跳到底部；用户手动滚过并保存过的位置仍保留。
- 用 `process_frame` 等下一帧再读 `max_value`，与 `objective_style.next_frame` 一致；`call_deferred` 在帧尾空闲期执行，可能仍早于 `ScrollContainer` 的子项排序，读到 0 导致滚动到底失效（回炉修正）。
- `library_scroll` 在 `_library()` 里已赋值（第 126 行），`is_instance_valid` / `is_inside_tree` 兜底。

**CORE 系统同类问题（次要，可选）**：`game/pages/core/talk_records_page.gd` 第 47 行 `var selected: Dictionary = filtered[0]` 默认取首段（最早）。该页由 CORE 系统的 `material_reader_page.gd` 使用，极光正式流程走 `aurora_handbook_page.gd`，不经过它；若 CORE 系统仍会打包，可把 `filtered[0]` 改为 `filtered.back()`（需确认 `TalkStore.segments` 返回时间正序后一并处理）。

**验证**：GUI 打开手册→交谈记录→应显示在最新段落附近（滚动条在底部）；首次打开、已有历史时生效。

---

## 3. #16 点开默认已读、无需二次确认（gameplay + 策划拍板）

**已核实，但属产品决策**。当前“二次确认”是有意设计：`aurora_handbook_page.gd` `_reading()` 第 194–195 行注释明确“未阅读就返回不会触发 completion_event 或发卡”，材料入口 `reading_entry=true` 时必须在全文底部点“已读完这份原件”才回执。

**文件**：`game/pages/aurora/aurora_handbook_page.gd`，`_reading()`（约 194–195 行）与 `_back()`/`close_page()`。

**需策划明确一件事**：“点开一次”是否等价于“读完”。两种改法：

- **A. 维持现状（保留确认）**：不满足反馈，但守住“读到全文底部才算读完”的设计。
- **B. “关闭阅读即视为已读”**：去掉底部确认按钮，改为在 `_back()` / `close_page()` / `handle_escape()` 离开阅读时，若 `reading_entry` 为真则调用 `session.material_read_complete()`（并在已读时不再触发“取消”分支）。改动点：
  - 删除 `_reading()` 里 `if reading_entry: UI.button(pages, "已读完这份原件", _complete_reading)` 一行；
  - 在 `_back()` / `close_page()` 里，`reading_entry` 为真时改走 `_complete_reading()` 而非 `session.cancel_material()`。

**结论**：本岗不擅自选 B。请策划拍板后我再出最终 diff。若选 B，需一并确认“直接点关闭未滚动到底”也记为已读是否可接受。

---

## 4. #14 回顾展开时 HUD 浮窗收起（integration，✅ 已落库并提交）

**已核实**。`objective_service.request_review()` → `_finish_review(ok)` 进入“open”时没有收起 HUD 浮窗；`model.expanded` 默认 `true`，展开的浮窗留在全屏回顾页后面；且 `review_button` 藏在 `body` 里，随展开状态显隐（收起后若不复原，按钮永久消失）。

**文件**：`game/systems/objective/objective_service.gd`。

**最终改动（已落库，含“返回调查恢复展开”）**：
1. `_finish_review(ok)` ok 分支：进入 open 后若展开则收起，并记 `_review_folded_hud = true`。
2. 新增 `_restore_folded_hud()`：若因回顾主动收起过则恢复展开。
3. 在 `close_review()`、`request_go()` 成功、`reset()` 三处调用恢复，避免“看完回顾 HUD 永远收起”。

```gdscript
	# _finish_review 内
	if ok:
		model.mark_seen()
		_set_review_state("open")
		if model.expanded:
			model.toggle()
			_review_folded_hud = true  # 打开全屏回顾时收起 HUD 浮窗（反馈#14）
		_update_processing()
		changed.emit()
		return "opened"

func _restore_folded_hud() -> void:
	if _review_folded_hud:
		_review_folded_hud = false
		model.toggle()
```

**说明**：只在“因打开回顾主动收起”时才恢复，玩家自己收起的开合选择不受影响；`_review_folded_hud` 为 false 时 `_restore_folded_hud()` 无副作用。归属 integration（目标导航）。

---

## 5. #20 地点列表按楼层分区（integration，✅ 已落库并提交）

**已核实**。`game/pages/map_navigation/map_navigation_page.gd` 侧栏“地点列表”是平铺 `VBoxContainer`，未按 `group_id` 分组；顶部已有分组按钮但只作用于棋盘，列表未分区。

**最终改动（已落库）**：`_render()` 里 `for target in [nodes, list]` 合并循环中，`target == list` 分支按 `item.node.group_id` 变化插入楼层标题（复用顶部 `region_name_text_id` + `floor_name_text_id` 解析），棋盘分支不动。

```gdscript
	var selected_button: Button
	var last_list_group := ""
	for item in records:
		...
		for target in [nodes, list]:
			if target == nodes and has_board and item.node.get("group_id", "") != group_id: continue
			# 侧栏地点列表按楼层分区，每组前插入楼层标题（反馈#20）。
			if target == list:
				var list_group := str(item.node.get("group_id", ""))
				if not list_group.is_empty() and list_group != last_list_group:
					last_list_group = list_group
					var gdef: Dictionary = service.map_definition.get("groups", {}).get(list_group, {})
					...
					UI.label(list, gtitle, 18)
			var button := UI.button(target, ...)
```

**说明**：与顶部楼层按钮一致，跳过空 `group_id`（回炉补上，避免空标题行）。`location_records()` 的转场按 `order` 排序而非按组归并，若配置里同一楼层被 `order` 拆开，会出现同组标题重复出现（每段自带头、不影响功能，仅多表头）；正式配置通常按楼层连续编号，故不为此改动共享的 `location_records()`/`available_transitions()`（属 integration 共享服务，留主程序定夺是否按组排序）。归属 integration（地图）。

---

## 6. #21 跨层地图花屏几帧（integration，✅ 已落库并提交）

**已核实（根因）**。`map_navigation_page.gd` `_process()` cross 动画 `amount >= 0.5` 时 `_queue_render(true)` 强制整页重建（`_queue_render` 对 `force=true` 跳过动画期保护），`_render()` 里 `UI.clear(self)` 清空后重建 `board_view`，重建瞬间出现空帧 → 花屏。

**最终改动（已落库）**：跨层中点不再整页重建，改为给棋盘加原地切换。

1. `map_board.gd`：`configure_art()` 额外保存完整 `map_definition`；新增 `switch_group(group_id)` 只更新 `selected_group`、`group_definition` 与 `layout_definition`（rows/cols/cell_size）后 `queue_redraw()`。
2. `map_navigation_page.gd` `_process()`：cross 中点把 `_queue_render(true)` 换成 `board_view.switch_group(selected_group)`。

```gdscript
	# map_board.gd
	func switch_group(group_id: String) -> void:
		if group_id == selected_group: return
		var layout: Dictionary = map_definition.get("boards", {}).get(group_id, {})
		if layout.is_empty(): return # 目标层无棋盘定义，不切换（由页面走整页重建）
		selected_group = group_id
		group_definition = map_definition.get("groups", {}).get(group_id, {})
		layout_definition = layout
		rows = maxi(1, int(layout.get("rows", 5)))
		cols = maxi(1, int(layout.get("cols", 8)))
		logical_cell_size = float(layout.get("cell_size", 100))
		queue_redraw()

	# map_navigation_page.gd _process cross 分支
	if is_instance_valid(board_view) and service.map_definition.get("boards", {}).has(selected_group):
		board_view.switch_group(selected_group)
	else:
		_queue_render(true)  # 目标层无棋盘定义时仍整页重建
```

**需实测的局限**：棋盘节点按钮由页面在 `_render()` 里创建，`switch_group` 只换背景与格子，不重建按钮——跨层中点后到地图关闭前的过渡期内，按钮仍是原层按钮（位置在原层格子上），但该窗口很短且 pawn 渐显 + 整页淡出，观感需 GUI 确认。若验收不通过，再改为“board 区域局部重建”的更大改动。

**回炉补充**：`switch_group` 目标层若没有 `boards` 定义（`layout.is_empty()`）会直接返回、不再改 `group_definition`/`layout_definition`（避免背景与格子定义不一致）；页面在 cross 中点先判 `boards.has(selected_group)`，无棋盘时回退 `_queue_render(true)` 整页重建，保留原代码对“无棋盘目标层”的处理，不引入回归。归属 integration（地图）。

---

## 7. #24 点角色重播 BGM（integration + 配置，代码无 bug → 不改码）

**已核实（布线正确，无需代码改动）**。已确认的布线：
- `game/systems/aurora/aurora_session.gd` `_apply_music()` `if key != last_bgm` 才 `music_requested.emit(key)`，同曲不重复 emit。
- `game/main/aurora_main.gd` `session.music_requested.connect(audio_service.set_narrative_soundscape)`（默认 `rebuild=false`）。
- `game/systems/audio/audio_service.gd` `_set_loop()` `active.path == path and not rebuild` 返回 `"same"`，同曲不重启。
- 读档路径 `set_narrative_soundscape(session.last_bgm, true)` 才 `rebuild=true` 从头重建。

**结论（推断）**：正常交互路径同曲不会重头播放；症状更可能来自 **角色话题入口 `bgm_mode/bgm_id` 与当前场景章节默认 BGM 不同**（点话题切走、退出未切回，被感知为“重头/换曲”），或个别入口 `bgm_mode="specified"` 误配了角色主题曲。

**建议排查（配置层）**：在 `02_文案/文案配置表.xlsx` 中核对角色话题入口的 `bgm_mode`、`bgm_id`、`chapter_id`；对话应与场景共用 BGM 时，确保为 `inherit_chapter` 且 `chapter_id` 正确。归属 integration（音频）+ 配置核对。

---

## 8. 非代码项（资源 / 配置 / 策划）

- **#15 货单黑屏（P0）**：`aurora_session_test.gd` 已覆盖 `ENTRY_CH01_READ_E01 → material_read_complete → E01` 且通过，会话逻辑无碍；黑屏属资源/渲染层（PCK 缺失或某立绘/背景/文书图损坏）。建议主程序牵头做一次“配置引用 → 实际文件存在性”审计，再 GUI 复现定位具体缺失资源。
- **#22 / #26 立绘错配**：`_relocate_resources()` 已把 `texts.portrait_path / avatar_ref`、`actors.default_portrait_path` 迁移解析；错配应在文案表（人物字典 / 文本的 `portrait_path`、`avatar_ref`）逐条核对，非玩法代码。
- **#17 地图快捷移动**：新功能，跨场景热点 + `map_service.travel`/`force_travel` + 门的美术资源，需 gameplay/美术/integration 协同，本次不实现。
- **#23 / #25**：设计/叙事决策，非代码。
