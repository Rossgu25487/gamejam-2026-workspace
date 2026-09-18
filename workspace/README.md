# 本机协作状态与路由

从仓库根打开 Codex；Godot 工程位于 [game/project.godot](../game/project.godot)。
本目录把角色、文件和交接连起来，不保存第二套产品规则。

## 1. 路由与当前依据

- [manifest.json](manifest.json)：由 lead 维护基础路由、阶段、岗位与路径。字段以实际文件及插件实现为准。
- [planning/current.json](../planning/current.json)：只有 planner 明确指定后才更新当前策划依据。
- 具体接口：[docs/接口与交接.md](../docs/接口与交接.md)；共同规则：[docs/协作协议.md](../docs/协作协议.md)。

路由缺项只影响对应入口，先记录差异并继续已明确工作；不擅自用其他资料取代当前依据。

## 2. 每人一份交接

| 角色 | 独占记录 |
|---|---|
| planner | [handoffs/planner.md](handoffs/planner.md) |
| lead | [handoffs/lead.md](handoffs/lead.md) |
| gameplay | [handoffs/gameplay.md](handoffs/gameplay.md) |
| integration | [handoffs/integration.md](handoffs/integration.md) |
| ui_art | [handoffs/ui_art.md](handoffs/ui_art.md) |
| visual_art | [handoffs/visual_art.md](handoffs/visual_art.md) |
| qa | [handoffs/qa.md](handoffs/qa.md) |
| ops | [handoffs/ops.md](handoffs/ops.md) |

内容保持简短：当前目标与需求 ID/依据版本、分支及相关版本、改动文件、实际验证、卡点、接收者与下一步；正式制作时另记本人确认的实际工时。
持续更新本人的文件，不替别人改状态，不另造个人 README、逐日报告或重复断点表。
交接可以写“已完成本地实现，待接入/待独立验收”，避免将局部成功当作全队完成。

## 3. Godot“协作空间”

插件读取当前 clone 的路由和策划指针，可导入原件、查看依据、编辑本人的交接文件。编辑前核对当前角色。
原件导入只落到 planning/inbox；设当前依据须由 planner 明确执行。
保存发生在本机，其他成员需要通过 Git 提交、拉取和合并取得更新；多人不得共享一个可写工作目录。
没有插件或图形环境时，直接使用对应文件继续工作，不能把未执行的界面操作记为成功。

## 4. 恢复

先读自己的交接记录，再核对当前分支、工作区变化、当前依据和直接依赖。复用未变内容的通过结果，从下一步继续。
没有新包或新信息时保留成果并结束本轮等待，不做无限轮询；恢复后确认新旧版本再接着验证。
