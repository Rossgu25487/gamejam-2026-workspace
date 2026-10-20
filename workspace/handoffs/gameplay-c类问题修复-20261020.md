# 副程序A/gameplay · 本轮 C 类问题修复说明（2026-10-20）

> 给 lead 接手用的本轮改动清单：每条对应 `极光_问题清单_程序本身导致的_20261020.xlsx` 的一个问题 ID，写清改了什么、动了哪些文件、验证到什么程度、还差什么。

## 概览

- 分支：`codex/lead/local-setup`
- 本地提交：`6b12637 fix: 修复 12 项程序主责问题（02/03/06/10/14/16/18/19/V03/V04/V05/D05）`
- 推送状态：**尚未推送**（由 bcynuaa 本人上传；本说明只描述本地提交内容）
- 工作区：已干净（`git status` 无未提交改动）
- 改动量：17 文件，+484 / −45，新增 3 个回归测试

验证口径：本轮只做了 headless 脚本回归（`--headless --script`），**未做** GUI、实际输入、跨机器检查；这些按 AGENTS.md 保留未执行，需 lead/测试岗在实机补验。

---

## 逐项说明

### 02 · 取证/收卡过快，需 0.75 倍速（P1）

- 改动：普通取得反馈与成卡动画时长从 `400ms` 改为 `400.0 / 0.75`（≈533ms）；推论收卡（collect）从固定 `900ms` 改为 `900.0 / 0.75`，并让 collect 的收尾判断改用 `duration_ms` 而不是写死的 `900`。
- 文件：`game/pages/aurora/aurora_acquisition_feedback.gd`、`aurora_result_effect.gd`、`game/systems/aurora/aurora_session.gd`（`accept_inference`）、`game/tests/final_result_effects_test.gd`（断言同步改为 0.75 倍速时长）。
- 验证：`final_result_effects_test.gd` 52 项通过。

### 03 · 调查/返回场景后物件金色 focus 框残留（P1）

- 改动：在热点按钮上识别指针输入，鼠标点查返回后不再调用 `grab_focus` 抢占焦点；键盘导航仍保留可见焦点。新增 `_keyboard_nav` 状态在 `_unhandled_input` 里由按键/鼠标移动切换。
- 文件：`game/pages/aurora/aurora_scene_page.gd`（`_note_pointer_input`、`_unhandled_input`、`_restore_focus`）。
- 验证：无独立专项测试；依赖 `aurora_page_test.gd` 等既有页面回归（本轮未单独跑，见「已知遗留」）。

### 06 · 同一证言详情反复显示相同「取得记录」（P1）

- 改动：核心详情渲染「取得记录」时按最终展示文案去重（`seen_sources`），同句只列一次，不同来源字典解析成同一句不再重复显示。
- 文件：`game/pages/aurora/aurora_card_page.gd`（`_render_detail`）。
- 验证：无独立专项测试；依赖既有页面回归。

### 10 · 站长室机位按钮与右上目标 HUD 重叠（P1）

- 改动：目标 HUD 展开/收起时，把需让出的宽度通过 `hud_reserve` 回调注入调查页；机位按钮绘制时按让出宽度左移避让。目标页 `changed` 信号触发场景页重排。
- 文件：`game/pages/aurora/aurora_gameplay_page.gd`（`bind` 里绑 `hud_reserve` + `objectives.changed`）、`aurora_scene_page.gd`（`_draw_view_switches` 的 reserve）。
- 验证：无独立专项测试；依赖页面回归 + 实机画幅核对。

### 14 · 材料更新后缺「手册已更新」下方提示（P1）

- 改动：`aurora_case_state` 新增 `content_updated(content_id)` 信号，只在材料当前版**真正前进**（新取得或更高版本）时发出，同版重复授予不重复提示；`aurora_session` 接信号后调 `narrative.queue_manual_update`；`aurora_narrative` 新增无头像提示队列 `__MANUAL_UPDATE__`，等当前文本结束后按序排入正文，播完再续原剧情；读档恢复与离开对白（`end_reading`）都会清空队列，避免把本次对话的提示带到无关下一段。
- 文件：`game/systems/aurora/aurora_case_state.gd`、`aurora_session.gd`、`aurora_narrative.gd`。
- 验证：新增 `game/tests/manual_update_hint_test.gd` 23 项通过。

### 16 · 调试自动推进未覆盖容器文书/人物话题（P1）

- 改动（三块）：
  1. **遍历**：`_external` 重写为递归 `_scan_view`，沿真实玩家路径补上本视图热区（inspect）、可交谈候选与话题、观察选项、可达机位（`view_switch_controls`）与容器子视图（`detail_view_ref`）。容器只在「开箱」入口完成回执成立后才打开并递归扫其内部；进入子视图后恢复原视图再扫交谈候选（默认视图才有近景人物）。
  2. **停止报告**：`_conclude` 在非到达、非取消时把 `_stuck_report` 的「未满足前置」追加进失败原因，使超时/循环等非「走不下去」的失败也能看到卡点。
  3. **结果演出收尾**：`_advance_result` 开头在 `effect_pending` 为真时先 `finish_result_effect()` 再推进，修隔离模式下结果演出无人收尾导致的「回应无法开始」（T00_R01 复现点）。
- 文件：`game/systems/debug_console/debug_auto_play.gd`。
- 验证：`debug_autoplay_test.gd` 从「T00_R01 回应无法开始、覆盖 [0/37]」推进到「通过 T00 教程（8 问）、在 CH02 停止、覆盖 [8/37]」。**仍有 CH02 卡点，见「已知遗留」。**

### 18 · 来源页按钮被挤成竖条（P1）

- 改动：标题限两行并省略（`max_lines_visible=2` + `OVERRUN_TRIM_ELLIPSIS`），上/关闭/返回按钮关自动换行并设最小宽度 120px，保证长标题下按钮仍显示完整文字。
- 文件：`game/pages/objective/objective_reading_view.gd`。
- 验证：无独立专项测试；依赖页面回归。

### 19 · 持续调查 BGM 循环/反复起播（P1）

- 改动：调查与片尾 BGM 改为**单次播放**（`loop=false`）；自然播完后按**真实曲目键**（新增 `Track.resource_key`）记录完成，同阶段不重起；`_set_loop` 的 same 短路增加 `active.loop == looping` 判断，避免同路径不同循环策略被误判为同曲短路。环境槽 ambient 循环保持不变。
- 文件：`game/systems/audio/audio_service.gd`。
- 验证：新增 `game/tests/bgm_single_play_test.gd` 22 项通过。

### V03 · 核查结果页关键文字低对比（P1）

- 改动：结果标题、原话、反馈与依据统一垫不透明纸面 `PanelContainer`，避免深色字叠场景底色后难读。
- 文件：`game/pages/aurora/aurora_card_page.gd`（`_result`）。
- 验证：无独立专项测试；依赖页面回归 + 实机画幅。

### V04 · 地图长目的地名换行压住「不可前往」提示（P2）

- 改动：按标题真实换行高度计算 `title_bottom`，状态提示若被压到标题下方则下移 `6 * spatial_scale`，不遮地名末字。
- 文件：`game/pages/map_navigation/map_navigation_page.gd`（`_render_spatial`）。
- 验证：无独立专项测试；依赖页面回归。

### V05 · 货车场景名称纸条为空、存档地点摘要同源缺名（P2）

- 改动：`aurora_session` 新增 `scene_name(scene_id)` 统一解析：`name_text_id` 有效先取译文，否则回退 `display_name`，两者都缺记录校验错误并返回「未知地点」；站名牌与存档 `progress_summary` 都改走这个接口。
- 文件：`game/systems/aurora/aurora_session.gd`、`game/pages/aurora/aurora_scene_page.gd`（`_draw_tools`）。
- 验证：无独立专项测试；依赖既有配置/页面回归。

### D05 · 地图抬起/落下音效别名未解析（P2）

- 改动：`aurora_configuration` 新增 `audio_resource_overrides()`，运行时读 `资源清单.json` 的 `resource_overrides`（`mapping_reference` 为 resource_overrides 且路径含 `/audio/`）把逻辑键映射到实际 `res://` 路径；`audio_service.setup_package` 在 `ref_table` 上消费这些覆盖（旧包无此方法时保持不变）。不再把逻辑键拼成路径或只靠备用库模糊找文件。
- 文件：`game/systems/aurora/aurora_configuration.gd`、`game/systems/audio/audio_service.gd`。
- 验证：新增 `game/tests/map_pawn_audio_test.gd` 13 项通过。

---

## 验证汇总

| 测试 | 结果 |
|---|---|
| `bgm_single_play_test.gd`（新） | PASS 22 |
| `map_pawn_audio_test.gd`（新） | PASS 13 |
| `manual_update_hint_test.gd`（新） | PASS 23 |
| `final_result_effects_test.gd`（改） | PASS 52 |
| `debug_autoplay_test.gd` | 见下方「已知遗留」 |

上述 4 个通过项均为本轮改动直接覆盖的回归；其余页面类改动（03/06/10/18/V03/V04/V05）没有独立专项测试，依赖既有 `aurora_page_test.gd` 等页面回归与实机检查。

---

## 已知遗留（lead 接手后需处理）

1. **调试自动推进仍在 CH02 停止**：`debug_autoplay_test.gd` 通关流程现能过 T00 教程（8 问），但随后停在 CH02，覆盖 `[8/37]`，停止报告显示 L01–L15 各关卡被「关卡条件 `COND_F7_CH02_*`」或「未听过原话 `TXT_*`」挡住。这说明自动推进在 CH02 找不到能解锁这些关卡条件的入口。需 lead 核对该章**调查入口→关卡条件的配置链路**（这些条件是否由可达入口正确置位），或确认自动推进是否还漏扫某类入口。issue 16 的遍历/停止报告/结果收尾三块代码已就位，此卡点更像配置或剩余遍历缺口，非本轮已修三块的功能回退。
2. **`debug_autoplay_test.gd` 预期过期**：该 QA 测试仍断言 `coverage["关卡"] == [18,18]`、`report.levels.size() == 18`，但现配置已 37 问。即使自动推进全通也会因这些断言失败。属测试预期未随配置更新，建议测试岗/lead 同步。
3. **3 个新测试缺 `.uid`**：`bgm_single_play_test.gd`、`map_pawn_audio_test.gd`、`manual_update_hint_test.gd` 用 headless 运行未生成 `.uid`，本提交未含。仓库约定 `.gd.uid` 随源码提交（现 tests 下已跟踪 72 个），lead 开编辑器后会生成这 3 个 `.uid`，请一并提交。
4. **GUI/输入/跨机器未验**：本轮仅 headless 脚本回归；金框、机位避让、纸面对比、地图换行等视觉项需实机画幅与鼠标/键盘操作复核（对应 AGENTS.md 的「未做 GUI、输入或跨机器检查时保留未执行」）。

---

## 交接提示

- 本轮改动已全部本地提交，工作区干净；**上传（push）由 bcynuaa 本人执行**，本说明不含上传操作。
- 若要回退，用新的撤销提交（`git revert 6b12637`）即可，不要强推或强 reset。
- 各问题的验收状态与是否关闭继续以 GitHub Issue 为准，本说明只描述本地改动与验证，不代替 Issue 记录。
