# Game Jam 团队工作台

**[打开团队工作台 →](https://rossgu25487.github.io/gamejam-2026-workspace/)**

大家日常只需看三件事：**当前工程版本、待完成与已完成任务、项目节点**。网页可以直接打开，任务统一保存在 GitHub，工程仍使用 Godot。

## 怎样开始

1. 打开工作台，按本人岗位筛选任务，查看当前阶段和下一节点。
2. 进入任务了解完成条件，使用已经收到的岗位 MD，让 Codex 在自己的副本里协助执行。
3. 在任务中附上成果位置与验证结果；验收后关闭任务，网页会显示为已完成。

[使用说明](docs/协作空间使用指南.md) · [任务列表](https://github.com/Rossgu25487/gamejam-2026-workspace/issues) · [策划资料](planning/) · [成员与版本同步](docs/加入与同步.md)

当前使用 Rossgu25487 的个人仓库，尚未建立 Organization。已确定分工：Rossgu25487（唯一策划／队长）、follerdf（主程序）、bcynuaa（副程序 A）、wangruijie21（副程序 B）、Aprilwwwang（美术 A：UI 布局／组件／二维资源）、stephaniez1（美术 B：二维图标／背景／物件及源资源交接）；其余岗位待名单。[查看成员与邀请（队长）](https://github.com/Rossgu25487/gamejam-2026-workspace/settings/access)

工程版本显示共同 `main` 提交，不代表每位成员的本机已同步。代码下载与可试玩版本分开列出；尚无发布包时会明确显示。网页给出最近获取数据的时间，刷新失败会保留原数据和失败提示。

## 当前阶段与时间

当前为命题前准备，题材和正式制作任务待公布。题前学习与准备单独计；2026 年 10 月 1—21 日正式制作每人累计最多 **12 小时**。

队内首次提交最晚 **北京时间 10 月 19 日 00:00，即 10 月 18 日结束前**。网页区分建议送审日期、队内截止和官方截止；到日期不会自动代表工作完成。[排期维护源](workspace/roadmap.json)

## 需要开发或检查游戏时

每人在自己的电脑上独立克隆；仓库公开，接受协作者邀请后可向团队仓库推送修改。

```powershell
git clone https://github.com/Rossgu25487/gamejam-2026-workspace.git
```

使用 **Godot 4.7.2 Standard / GDScript / Compatibility** 打开 `game/project.godot`，F5 运行现有接口演练。Godot 顶部“协作空间”现在只是网页快捷入口及本机版本提示，岗位长文已从日常界面移除。

在仓库根打开 Codex，读取 `AGENTS.md` 和本人的岗位文件。在本人分支继续工作；同机确需多个独立工作目录时使用 `tools/start-role.ps1`，详见[加入与同步](docs/加入与同步.md)。

## 维护入口

| 内容 | 维护位置 |
|---|---|
| 任务、负责人、验收结果 | GitHub Issues；网页自动汇总 |
| 排期与当前阶段 | `workspace/roadmap.json` |
| 当前正式策划依据 | `planning/current.json` 与 `planning/inbox/` |
| 本人分支的恢复线索 | `workspace/handoffs/<role>.md`；引用任务，不重复维护全队状态 |
| 网页与数据构建 | `site/`、`tools/build-dashboard.mjs` |
| 游戏与接口 | `game/`、[接口与交接](docs/接口与交接.md) |
| 本机音效素材库 | [FreeSFX 目录、来源与使用说明](docs/音效素材库.md) |

岗位长 MD 保留为已分发的 Codex 工作参考：[文件目录](岗位工作流/)。其中旧版 Godot 三页操作以当前使用说明为准。

工程检查入口为 `tools/project.ps1 -Action check/test -Godot '本机路径'`；网页数据检查使用 `node --test tools/test-dashboard.mjs`。构建和发布说明见[工作台维护](docs/工作台维护.md)。
