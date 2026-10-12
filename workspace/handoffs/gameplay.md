# 副程序 A · 逻辑 · 本机工作续接

任务、负责人和验收状态统一记录在 [GitHub 任务](https://github.com/Rossgu25487/gamejam-2026-workspace/issues?q=is%3Aissue+label%3Arole%3Agameplay)。

此处只保留下一次 Codex 接手需要的上下文：任务链接、本人分支与提交、未提交工作、必要接口或文件、下一步。已有具体任务的成果与验收写回该任务，避免两处状态不一致。

## 撸猫系统（逻辑层，进行中）

- Issue 链接：待本人从 GitHub 认领对应 `role:gameplay` 撸猫任务后补填（本机 `gh` 不可用，未查到）。
- 本机分支/提交：`codex/gameplay/cat`；本轮起点 `8e5cdd8`，新增提交 `feat: 新增撸猫互动状态机、配置目录与联调占位页`。
- 未提交文件：无（原 `.gitignore` 的 `M` 改动已随办案手册轮提交）。
- 本轮新增：`game/features/cat_interaction/{cat_workbook_loader,cat_catalog,cat_service,cat_placeholder_page}.gd(+.tscn)`、`game/tests/cat_service_test.gd(+.uid)`。
- 验证：`cat_service_test.gd` 44 项通过；占位页 headless 实例化无脚本错误；未做 GUI 可视/输入检查。
- 待 lead 协调：①`game/features/cat_interaction/` 写入 manifest 归 gameplay；②`cat_snapshot` 接入 `game_session_service`（接口 `cat_service.export_state()/restore_state()/validate_state()`）；③`main.gd` 增加 `current_layer="cat"` 与入口/暂停来源；④`tools/project.ps1` test 列表加 `cat_service_test.gd`；⑤正式素材（美术B）与场景猫入口（调查交互）。
- 接口（给 integration）：`cat_catalog.resolve(id)->{ok,reason,interaction,view,actions}`、`cat_catalog.ui(key)`、`cat_service.enter/begin_touch/advance/notify_stable_displayed/current_action_kind/caption_text_id`。
- 下一步：等上述 ③④ 与素材就绪后接入正式入口；占位页删除方式见 `cat_placeholder_page.gd` 头注释。

## 办案手册 · 交谈记录（逻辑层，已提交）

- Issue 链接：待本人从 GitHub 认领对应 `role:gameplay` 办案手册任务后补填（本机 `gh` 不可用，未查到）。
- 本机分支/提交：`codex/gameplay/cat`；本轮起点 `3baf34b`，本轮已提交（`feat: 新增办案手册交谈记录模型与回归测试`）。
- 本轮新增（已提交）：`game/features/handbook/talk_records_model.gd`、`game/tests/handbook_talk_records_test.gd`，两者 `.gd.uid` 随源码正常提交；`.gitignore` 新增 `.vscode/*`，`.gd.uid` 维持「随源码提交」约定，并补齐猫占位页 `cat_placeholder_page.gd.uid`。
- 验证：`handbook_talk_records_test.gd` headless 49 项通过（Godot 4.7.2，退出码 0）；另用临时联调占位页绑定真实 `故事配置表.xlsx` 验证模型对真实数据渲染正确（人物名解析、S1→S2 更正链、归纳归属 PERSON 均对），占位页验后已删；未做 GUI/输入/跨机检查。
- 范围（Option A，按策划案第 7 节大砍）：只实现交谈记录页纯逻辑模型，**未做**独立人物档案页、线索来源 tag、话题筛选（`topic_of()` 留空接口）、调查回顾、入口系统、美术，也未改 lead 的 `material_reader_page.gd`。
- 接口（给 integration，模型无 Node/无 `class_name`，用 preload 注入）：
  - 注入 `bind(records, characters, statements, entries, text_resolver)`：分别传 `core.state.talk_records`、`core_catalog.data.{characters,statements,entries}`、`catalog.text`（Callable）；`text_resolver` 无效返回 false。
  - 查询：`records()`（新→旧浅拷贝）、`persons()`（`[{id,name}]`）、`person_name(id)`、`person_of(record)`、`kind(record)`（`statement`/`confirmed`）、`text_of(record)`、`filter(person_id="", topic_id="")`、`corrections(statement_id)`（同 claim 已听版本升序）。
  - 已读：`read_key(record)`/`is_read(record)`/`mark_read(record)`/`unread_count()`；`signal changed` 在 bind/mark_read/restore 时发出。
  - 快照：`export_state()`/`restore_state(snapshot)`/`validate_state(snapshot)`（只持久化已读键）。
- 设计决定（供 lead 核对第 7 节）：① 归纳（confirmed）的交谈对象按成果 `target_ref` 的目标说法推导，推理类成果无交谈对象、只在「全部人物」下显示；② `corrections` 只列实际已听版本（符合「仅显示合法已听原句」）；③ 人物选项按新→旧首次出现排序去重。
- 待 lead 协调：
  1. `game/features/handbook/` 写入 `workspace/manifest.json` 归 gameplay。
  2. **话题筛选数据来源未定（关键缺口）**：`entry_id="result"` 的更正原话与推理类归纳没有话题来源，需 lead 定义话题字段（来源、取值、挂在 entry 还是 question），再回来补 `topic_of()`；第 7 节的「阶段/时点」若需要也一并定。
  3. integration 接线：`material_reader_page.gd` 的 talk 标签从平铺 `talk_records` 改为消费本模型。
  4. 已读快照接入 `game_session_service`（走模型 `export_state/restore_state/validate_state`）。
  5. `tools/project.ps1` test 列表加 `handbook_talk_records_test.gd`（猫测 `cat_service_test.gd` 仍未加）。
