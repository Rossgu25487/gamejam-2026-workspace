# 主程序 · 本机工作续接

任务： https://github.com/Rossgu25487/gamejam-2026-workspace/issues/5

本机分支：`codex/lead/local-setup`；当前提交用 `git log -1` 查询。

本轮将标题页落为 `game/main/main.tscn` 的 `TitlePage` 节点；标题状态隐藏 `CounterView`，进入调查再显示。原有计数界面的布局偏移保留。导航测试覆盖启动、进入调查、返回标题的显示切换。

恢复入口：`game/main/main.gd`、`game/main/main.tscn`、`game/tests/navigation_checks.gd`；日志在 `.local/`。编辑器如有未保存场景，先核对磁盘更改再重新加载。
