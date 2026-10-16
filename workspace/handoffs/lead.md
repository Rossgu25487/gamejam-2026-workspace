# 主程序 · 本机工作续接

任务： https://github.com/Rossgu25487/gamejam-2026-workspace/issues/5

本机分支：`codex/lead/local-setup`；当前提交用 `git log -1` 查询。

本轮用户任务：接入测试用资源配置并制作Demo、统一填写规范，代码基准 `aed58a6`。本机分支沿用上方；本轮提交查 `git log -1`，仅本地保存提交，未推送远端。

恢复入口：`docs/测试资源Demo试玩说明.md`、`docs/配置表统一填写规范.md`、`game/examples/system_test_demo.tscn`及两个`system_test*`回归。原包哈希在`game/data/system_test/source_manifest.json`。固定片尾9000488缺可执行步骤，仍列待配；完整事件执行器继续沿原核对报告。

统一回归入口 `tools/project.ps1 -Action test`；本地证据在 `.local/`。用户原有未跟踪的地图、文案、测试用资源策划目录保持原位且不加入提交；本轮独立运行副本位于`game/data/system_test/`。F5仍为占位故事。编辑器若出现未保存标记，先核对内存与磁盘再重新加载；本轮通过磁盘脚本与测试引擎保存，没有操作用户编辑器内存。
