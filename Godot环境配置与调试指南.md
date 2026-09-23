# Godot 环境配置与调试指南

本文用于十月题目公布前的工具准备：打开工程、运行可操作画面、定位错误、导入素材，并验证导出路径。题前准备单独计时，不占正式额度；正式制作按每人 12 小时基线、必要时扩大且累计最多 24 小时执行，详见[团队准备说明](团队准备说明.md)。首次熟悉可先预留 1.5—2 小时，时间仅供参考。本指南不确定正式玩法、岗位制作任务或制作排期。

核查日期：2026-09-16。下文的练习步骤与命令用于实际操作，尚未执行的步骤不代表已经通过。

## 1. 版本与本机现状

建议统一使用 **Godot 4.7.2 Standard、GDScript、Compatibility 渲染方式**。本次官网 Windows 下载页显示的稳定版为 4.7.2；已有工程应服从团队固定版本，不随提示自动升级。Godot 可解压后直接运行，无需修改全局 PATH。[官方下载与说明](https://godotengine.org/download/windows/)

本机已发现以下文件，其他同学按自己实际存放位置替换路径：

| 项目 | 本机核查结果 |
|---|---|
| Standard 编辑器 | `G:\CodexData\.codex\tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe`，文件存在；同目录控制台版本实测返回 `4.7.2.stable.official.ed1daf0bf` |
| Standard 控制台版本 | 同目录的 `Godot_v4.7.2-stable_win64_console.exe`，文件存在，便于查看终端输出 |
| 已有 .NET 编辑器 | `G:\CodexData\.codex\tools\godot-dotnet\4.7.2\Godot_v4.7.2-stable_mono_win64.exe`；版本命令返回 `4.7.2.stable.mono.official.ed1daf0bf` |
| Standard 导出模板 | `C:\Users\涛涛\AppData\Roaming\Godot\export_templates\4.7.2.stable\` 已有 Windows x86_64 与 Web 模板文件；`version.txt` 为 `4.7.2.stable` |
| PATH | 本机 PATH 未命中 Godot；便携编辑器实际存在，可用绝对路径启动 |

本轮还用临时工程核验了第 3 节的节点结构与脚本，图标采用等价 SVG 占位：无窗口导入与脚本解析通过；模拟左右输入后，图标 X 坐标由 `320 → 317 → 320`，标签更新为 `Ready | X: 320`。真实键盘操作、GUI 显示及 Windows/Web 导出成品的视觉验收尚未执行，需要各自按后文检查。临时验证工程用于核验指南，不作为游戏工程交付。

现有 .NET 版可以保留，本练习使用 Standard；选择 GDScript 可避免增加 C# 与 .NET 配置，同时保留 Godot 4 的 Web 导出路线。[当前 Web 语言限制](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

在 PowerShell 中可先核对版本：

```powershell
$godotExe = 'G:\CodexData\.codex\tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe'
& $godotExe --version
```

其他同学替换为自己的编辑器路径；下文练习目录与输出目录仅作示例。Godot 参数以该编辑器的 `--help` 为准。[官方命令行说明](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)

## 2. 新建或导入一个准备工程

首次打开进入 Project Manager。练习工程可放在 `E:\gamejam\_prep\godot_probe`，与以后正式工程分开。

1. 新建时选择空文件夹，渲染方式选 **Compatibility**。若需要 Git 元数据，可生成 `.gitignore`、`.gitattributes`；用外部 Git 管理文件即可，无需先安装编辑器 Git 插件。
2. 已有工程用 **Import** 选择 `project.godot`。等待资源导入完成，再运行。
3. 打开 **Project → Project Settings → Display → Window**，设置 Viewport Width 为 `640`、Viewport Height 为 `360`，作为本练习的固定画布。

项目创建与导入见[Project Manager](https://docs.godotengine.org/en/stable/tutorials/editor/project_manager.html)；Git 元数据见[版本控制说明](https://docs.godotengine.org/en/stable/tutorials/best_practices/version_control_systems.html)。Compatibility 也适用于 Godot 4 的 Web 导出，网页端使用 WebGL 2.0；不要将网页要求与桌面图形接口混为一项。[Web 渲染限制](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html#webgl-version)

## 3. 做出能看见、能操作的最小测试画面

这是环境测试，只验证显示、输入和脚本运行。无需等待题目，也无需先做正式美术。

1. 新建 **2D Scene**，根节点 `Node2D` 命名为 `Main`。
2. 添加 `Sprite2D` 子节点，命名 `Marker`。将新工程自带的 `icon.svg` 拖入其 Texture；Position 设置为 `(320, 180)`，Scale 设置为 `(0.5, 0.5)`。
3. 添加 `Label` 子节点，命名 `Status`，Position 设置为 `(24, 24)`。
4. 在 **Project → Project Settings → Input Map** 新建 `test_left`，绑定 `A` 与左方向键；新建 `test_right`，绑定 `D` 与右方向键。每个动作可添加多个按键事件。
5. 给 `Main` 附加 GDScript，保存为 `main.gd`，粘贴下面内容；场景保存为 `main.tscn`。

```gdscript
extends Node2D

@onready var marker: Sprite2D = $Marker
@onready var status: Label = $Status

func _process(delta: float) -> void:
    var axis := Input.get_axis("test_left", "test_right")
    marker.position.x = clampf(marker.position.x + axis * 180.0 * delta, 64.0, 576.0)
    status.text = "Ready | X: %.0f" % marker.position.x
```

按 **F6** 运行当前场景；点击运行画面获得焦点，按 A/D 或左右方向键，图标应水平移动，左上角 X 数值同步变化。按 **F8** 停止。按 **F5** 运行项目，首次提示时选择 `main.tscn` 为主场景。以后 F5 从主场景启动，F6 从当前编辑场景启动。[场景与运行](https://docs.godotengine.org/en/stable/getting_started/step_by_step/nodes_and_scenes.html)、[输入映射](https://docs.godotengine.org/en/stable/getting_started/step_by_step/scripting_player_input.html)、[Input.get_axis](https://docs.godotengine.org/en/stable/classes/class_input.html#class-input-method-get-axis)

若系统使用多媒体功能键，按对应工具栏按钮即可。通过标准是“看得到图标、两个方向都有效、数值变化、停止后能重新启动”，空白窗口打开不能代替这项检查。

## 4. 认识调试入口

先复现问题，再看最早出现的有效错误。记录具体操作、错误原文和脚本行号，避免只描述“打不开”或“没反应”。

| 入口 | 这次需要掌握的操作 |
|---|---|
| Output | 查看运行日志、`print()` 输出及资源导入反馈 |
| Debugger / Errors | 展开错误，定位脚本和行号；修复后从原操作重试 |
| 断点 / Stack Trace | 点击脚本行号左侧放置断点；运行后查看变量和调用栈，尝试单步与继续，结束后移除测试断点 |
| Remote 场景树 | 运行时查看实际存在的节点与属性，核对运行中的场景 |
| Profiler | 先运行，再在 Profiler 点 Start，执行一次操作，观察帧耗时和脚本函数耗时 |
| Monitors | 查看 FPS、内存和节点数；在重复操作后观察是否持续增长 |

可在 `var axis` 后一行设置断点，核对 `axis` 和 `marker.position.x`。运行停住时先检查是否命中断点。调试工具详见[Debugger 面板](https://docs.godotengine.org/en/stable/tutorials/scripting/debug/debugger_panel.html)、[Profiler](https://docs.godotengine.org/en/stable/tutorials/scripting/debug/the_profiler.html)。

| 现象 | 先检查 |
|---|---|
| 提示找不到 `Marker` 或 `Status` | 子节点名称、大小写、层级，以及脚本是否挂在 `Main` |
| 图标不动 | 运行窗口焦点、输入动作拼写、按键绑定、当前是否暂停 |
| F6 正常、F5 画面不同 | 项目的主场景是否指向 `main.tscn` |
| 图像缺失 | Texture 是否赋值、源文件是否位于工程中、导入是否完成 |
| 窗口黑屏或图形初始化失败 | 首条错误、实际渲染方式及显卡驱动；用 Compatibility 的空测试工程缩小问题范围 |
| 能运行但明显卡顿 | 在 Profiler 找耗时高的帧与函数；有定位结果后再改，不先堆优化选项 |

命令行适合补充日志和导入检查。先完成第 2 节并确认目录中已有 `project.godot`，再执行：

```powershell
$godotProject = 'E:\gamejam\_prep\godot_probe'
& $godotExe --headless --path $godotProject --import
& $godotExe --path $godotProject --editor
```

`--headless --import` 只检查资源导入过程，不能验证画面、输入和音效；可视检查仍在运行窗口完成。[命令行参数](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)

## 5. 素材导入与交接

**PNG：** 将一张透明 PNG 复制到工程的 `assets` 文件夹，等待导入，再替换 `Marker` 的 Texture。检查透明背景、显示尺寸与边缘；修改源图并保存，回到编辑器确认更新。普通 UI 图片先用默认无损导入设置，按实际效果调整，保留可编辑源图。SVG 可以导入，但复杂效果支持有限，必要时从绘图软件导出 PNG。[图片导入](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html)

**GLB：仅在需要熟悉 3D 资源时做。** 优先拿一件已有 GLB，在单独的 `Node3D` 检查场景中实例化，添加朝向模型的 `Camera3D` 并启用 Current，添加 `DirectionalLight3D`。核对实际比例、朝向和材质，先让模型进入相机视野；后续实际需要阻挡的物体再检查碰撞。Godot 推荐 glTF/GLB；直接导入 `.blend` 会要求接手者也装有 Blender，本次可通过交付 GLB 减少这项依赖。[3D 格式与导入](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/available_formats.html)

项目内资源路径使用 `res://`，读写用户存档或设置使用 `user://`，脚本中统一使用正斜杠。不要把某台电脑的素材绝对路径写进项目脚本。[Godot 文件路径](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html)

| 交给版本控制 | 忽略或不交给版本控制 |
|---|---|
| `project.godot`、场景、脚本、资源源文件 | `.godot/` 导入缓存及编辑器状态 |
| 资源旁的 `*.import`，如 `icon.svg.import` | 缓存中的导入派生文件 |
| 脚本、着色器旁的 `*.uid` | 自动生成的 `*.translation` |
| `.gitignore`、`.gitattributes`、`export_presets.cfg` | 导出成品目录、`.godot/export_credentials.cfg` 中的密码与密钥 |

`*.import` 保存导入设置，`*.uid` 维持资源引用，两者都需要随源文件保留；移动脚本或着色器时同时移动对应 UID。优先在编辑器 FileSystem 中重命名和移动，完成后重新运行涉及的场景。不要把 `.godot/` 与资源旁的 `*.import` 混为同类。[导入元数据](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/import_process.html#files-generated)、[UID 说明](https://godotengine.org/article/uid-changes-coming-to-godot-4-4/)、[版本控制](https://docs.godotengine.org/en/stable/tutorials/best_practices/version_control_systems.html)

## 6. 先验证 Windows 导出

1. 打开 **Editor → Manage Export Templates**，核对模板对应当前固定编辑器版本。缺失时安装同版模板；已有模板直接检查，不重复下载。若模板管理器提供 ICU Data 选项，中文内容需要它，同时项目字体应包含所用中文字形。
2. 打开 **Project → Export → Add → Windows Desktop**，本练习选择 `x86_64`；资源先使用“导出全部资源”。
3. 创建工程外的输出目录，例如 `E:\gamejam\_builds\godot_probe\windows`。选择 **Export Project**，输出为其中的 `godot_probe.exe`。首次排错可保留 Export With Debug，验证后再导出 Release。
4. 将整个输出文件夹复制到另一个位置再打开，验证同一组按键和数值变化；使用分离 PCK 时保留 `.exe` 与 `.pck`，以及导出的其他依赖。交接前让另一位同学打开这个文件夹中的程序。

Export PCK/ZIP 只输出资源包；本步骤需要可执行成品，使用 Export Project。导出设置可提交 `export_presets.cfg`，凭据不要提交。[导出项目与模板](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html)、[Windows 导出](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_windows.html)

已有预设且输出目录存在后，可复用同一配置进行命令行导出。预设名必须与编辑器一致，以下名称对应上面的 `Windows Desktop`：

```powershell
$godotWinDir = 'E:\gamejam\_builds\godot_probe\windows'
New-Item -ItemType Directory -Force -Path $godotWinDir | Out-Null
& $godotExe --headless --path $godotProject --export-debug 'Windows Desktop' (Join-Path $godotWinDir 'godot_probe.exe')
```

确认正式输出时可将 `--export-debug` 换成 `--export-release`；导出命令成功之后仍需打开成品。[命令行导出](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html#exporting)

## 7. 再验证 Web 导出

在 Export 中添加 **Web** 预设，确认渲染方式为 Compatibility。Godot 4 网页端要求浏览器支持 WebAssembly 和 WebGL 2.0，当前官方说明仍不支持 C# 项目导出 Web；本练习保持 GDScript。[Web 要求](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

准备工程保持 **Thread Support 关闭、Extensions Support 关闭**，使用普通单线程导出。先不增加多线程服务配置；以后确需开启线程或扩展时，再核查部署环境和跨源隔离要求。开启相应支持时涉及的响应头为 `Cross-Origin-Opener-Policy: same-origin` 与 `Cross-Origin-Embedder-Policy: require-corp`，当前单线程练习无需预先设置它们。[线程与扩展](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html#thread-and-extension-support)、[导出选项](https://docs.godotengine.org/en/stable/classes/class_editorexportplatformweb.html)

1. 输出目录使用 `E:\gamejam\_builds\godot_probe\web`，在 Export Project 中直接命名为 `index.html`。
2. 保留生成的 HTML、JS、WASM、PCK 等完整文件集，保持文件名。通过 HTTP 服务访问，不双击 HTML 作为最终验证。
3. 可用编辑器的 Run in Browser 测试入口。若电脑已有 Python 3，也可按下列方式只启动本机 HTTP 服务；不必为这一步额外安装 Python。

```powershell
$godotWebDir = 'E:\gamejam\_builds\godot_probe\web'
python -m http.server 8000 --bind 127.0.0.1 --directory $godotWebDir
```

服务保持运行，浏览器打开 [本机测试地址](http://127.0.0.1:8000/index.html)。结束时在终端按 Ctrl+C。端口占用时改用空闲端口，并同步修改浏览器地址；这项本地测试使用 localhost 环境，正式托管再使用 HTTPS。[Web 文件服务](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html#serving-the-files)、[Python 本地服务器参数](https://docs.python.org/3/library/http.server.html#command-line-interface)

按 F12 查看 Console 与 Network：先检查第一条报错及 404，再核对浏览器支持、文件是否齐全和导出选项。`.wasm` 宜由服务器以 `application/wasm` 返回。若看到 SharedArrayBuffer 或跨源隔离错误，先确认这次导出是否误启线程/扩展，重新导出并刷新。[Web 调试与服务要求](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)

有音频的准备场景应由一次明确的点击、触摸或按键开始播放，再判断声音是否正常；浏览器会限制自动播放。测试画面需先点击获得焦点，再验证键盘输入。[浏览器音频限制](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html#audio)

## 8. 完成到什么程度可以停

各自按实测填写，已有通过结果无需反复重做；模板或工具版本变化时重查相关项。

- [ ] 确认编辑器实际路径、完整版本号、GDScript 与 Compatibility 配置。
- [ ] F6 与 F5 都能运行预期场景，图标能双向移动，X 数值同步变化。
- [ ] 用一次断点查看变量，能继续执行；知道从哪里找到错误和性能数据。
- [ ] 一张 PNG 能导入、替换、修改并重新显示；需要 3D 时再加一件 GLB。
- [ ] 工程交接后能重新导入；UID 与导入设置完整，缓存未成为必需依赖。
- [ ] Windows 成品离开源工程目录仍能打开并操作。
- [ ] 若需要保留网页交付能力，Web 成品通过本地 HTTP 打开并能操作；有音频时完成点击后播放测试。

题前只保留这个通用测试工程和必要的版本、操作说明。最终采用哪条技术路线，以及是否需要 3D、音频和网页交付，留待题目公布后根据实际需求确定。
