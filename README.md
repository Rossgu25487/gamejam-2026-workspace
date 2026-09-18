# Game Jam 八人协作空间

这是题目前的共同工作区：用同一份策划依据连接八个岗位，让逻辑、界面、美术、测试与发布材料能够独立维护并接入同一个工程。

**GitHub 私有仓库：** [Rossgu25487/gamejam-2026-workspace](https://github.com/Rossgu25487/gamejam-2026-workspace)。八个岗位已预留，成员名单由队长后续提供后邀请。仓库同步使用 Git，Godot 中显示的是各人本机副本。

**技术基线：** Godot **4.7.2 Standard / GDScript / Compatibility**。当前计数界面是协作接口演练，正式题材、玩法和内容尚未确定；预制代码能否带入比赛仍需按赛事规则确认。

## 从这里开始

1. 每位成员取得仓库访问权限后，在自己的电脑独立克隆：

   ```powershell
   git clone https://github.com/Rossgu25487/gamejam-2026-workspace.git
   Set-Location gamejam-2026-workspace
   ```

2. 在仓库根目录打开 Codex，告诉它你的角色，并让它读取 [AGENTS.md](AGENTS.md) 和对应的[岗位工作流](岗位工作流/00_分发与使用说明.md)。一句启动话术：

   > 我的角色是“副程序 A / gameplay”（按本人岗位替换）。请读取本仓库 AGENTS.md、岗位清单和我的工作流，检查当前依据及我的交接记录，从已有工程继续完成本轮准备。先说明当前可做的步骤，再直接推进已明确的本地工作。

3. 用 Godot 4.7.2 Standard 导入 **[game/project.godot](game/project.godot)**。顶部切到 **“协作空间”**；如果没有显示，在 `Project → Project Settings → Plugins` 中检查 `协作空间` 是否启用。
4. 左侧选择自己的岗位，查看工作流、负责路径及交接记录。每次具体任务新建 `codex/<role>/<task>` 分支，避免多人同时写同一个工作目录。
5. 按 **F5** 运行接口演练：加 1、重置、观察界面与模型同步。真实游戏以后在明确需求下接入。

已有本地完整工作区时，可直接从第 2 步开始。原 Three.js 与 Godot 配置指南保留作工具参考，进入本仓库后优先沿用现成版本与目录。

同一台电脑要同时开多个岗位任务时，先运行 `./tools/start-role.ps1 -Role gameplay`（替换为自己的角色），再在返回的独立目录打开 Codex 与 Godot。脚本为该角色保留专属分支和 worktree，重复运行会核对并复用，保留已有修改。成员加入与正常同步步骤见 [加入与同步](docs/加入与同步.md)。

## 策划案放在哪里，怎样让大家使用

在“协作空间”选择 **策划 / 队长 → 策划依据**：

1. 点击 **导入策划案**，选择 `.md`、`.txt`、`.docx` 或 `.pdf`。插件把原件复制到 `planning/inbox/`，保留源文件，同名文件另加编号。
2. 在列表中查看文件；Markdown/TXT 可预览，Word/PDF 用系统软件打开。原件只保存，不由插件自动解析或改写。
3. 确认本次采用的版本后，点击 **设为当前依据**。这会更新 `planning/current.json` 的路径、版本和时间；单纯导入不会激活方案。
4. 将新原件和 `planning/current.json` 一起提交并合入，其他成员同步后，点击“刷新本机文件”读取同一版本。
5. 需要补齐可执行规则时，使用 [简版策划模板](planning/简版策划模板.md)；明确需求 ID、操作、结果、资源和验收。原始上传件保持不变。

也可以直接将原件放进收件目录，再从协作空间选择。当前依据仍由策划明确指定，不根据文件名里的“最终版”自动判断。

## 八个岗位如何接上

| 岗位 | 主要工作位置 | 交给谁 |
|---|---|---|
| 策划 / 队长 `planner` | `planning/`、练习参数 `game/data/demo_config.tres` | 给全队规则、范围、验收与决策 |
| 主程序 `lead` | `game/main/`、项目与导出设置、公共工具 | 把各部分接成可运行版本交测试 |
| 副程序 A `gameplay` | `game/features/counter_demo/` | 给副程序 B 真实逻辑接口 |
| 副程序 B `integration` | `game/ui/counter_view.*` | 接逻辑、美术资源，反馈实际显示与交互结果 |
| 美术 A `ui_art` | `game/ui/theme.tres`、`game/art/ui/` | 给副程序 B 布局、主题与组件表现 |
| 美术 B `visual_art` | `game/art/visual/` | 给副程序 B 图标、背景与二维物件 |
| 测试 `qa` | `qa/`、`game/tests/` | 给作者可复现问题，给队长指定版本的验证结果 |
| 运营 `ops` | `release/` | 给队长与已验收版本对应的展示、声明和提交材料 |

每人只维护自己的 `workspace/handoffs/<role>.md`。协作空间可编辑并保存，保存前会检查磁盘内容是否已被修改；有冲突时保留草稿并提示核对，不覆盖别人的更新。岗位选择是协作约定，仓库访问权限由 GitHub 管理。

具体规则：[协作协议](docs/协作协议.md) · [接口与交接](docs/接口与交接.md) · [岗位分发](岗位工作流/00_分发与使用说明.md)。

## 目录分工

```text
planning/                 策划原件、工作稿与当前依据
workspace/manifest.json   八岗位路由；由主程序维护
workspace/handoffs/       每人独占的交接记录
岗位工作流/               八个岗位的 Codex 指令
game/                    真正的 Godot 工程
  main/                  主程序接线
  features/counter_demo/  副程序 A 的演练逻辑
  ui/                    副程序 B 的界面，美术 A 的主题
  art/ui/                美术 A 组件源资源
  art/visual/            美术 B 二维图形
  data/                  参数及其类型定义
  addons/team_workspace/ 只在编辑器使用的协作入口
  tests/                 接口、集成及协作工具检查
docs/                    共用约定与接口合同
qa/                      测试工作说明与必要证据
release/                 运营与队长的提交材料区
tools/                   可复用运行、检查及导出命令
builds/                  本地生成包，不提交 Git
.local/                  本机日志、验证缓存，不提交 Git
```

## 验证与运行

Windows PowerShell 示例；将路径换为自己的 Godot 4.7.2。已设置 `GODOT_BIN` 时可省略 `-Godot`。

```powershell
$godotExe = 'D:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe'
./tools/project.ps1 -Action check -Godot $godotExe
./tools/project.ps1 -Action test -Godot $godotExe
./tools/project.ps1 -Action editor -Godot $godotExe
```

- `check`：导入并检查项目加载，错误会返回失败。
- `test`：检查配置、逻辑信号、真实界面接线、重载、八岗位路由、原件导入、依据切换及交接冲突。
- `run`：运行接口演练。
- `export`：使用同版导出模板生成 `builds/windows/`，应整目录交给测试；构建成功后继续验证实际成品。

导出的游戏只含运行内容。协作插件、岗位记录、原始策划案和测试工具不进入游戏包。本轮已验证范围与尚待人工/跨机器检查的项目见 [测试说明](qa/README.md)。

## 开赛之后

正式制作工时每人累计最多 12 小时，题前准备单独计。队内首次提交最晚为 **北京时间 2026-10-19 00:00**，建议 10 月 17 日先送审；官方有效投稿需在 10 月 21 日 12:00 前完成审核与活动投稿。

题目公布后，策划建立明确依据和需求，再分配具体模块。届时可以替换演练模块，保留已经验证的目录、交接和运行方式。八名成员的岗位、设计依据与预算都由实际信息驱动，不按日期自动开始制作。
