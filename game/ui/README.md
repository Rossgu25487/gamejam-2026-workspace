# 界面与皮肤

副程序 B 维护 `counter_view.gd`、`counter_view.tscn` 的行为、节点和接线。
美术 A 维护 `theme.tres` 的 SystemFont、颜色、字号与 StyleBox；需要调整场景布局时与副程序 B 协调该场景文件，避免同时保存。

独立运行 `counter_view.tscn` 会显示“尚未连接逻辑”，按钮不伪造计数。
主入口连接 `increment_requested`、`reset_requested` 后调用 `set_connected(true)`，通过 `show_value(value)` 显示实际数值；用 `set_step(step)` 同步按钮与步长提示。视图同时检查真实信号连接，未接线时调用 `set_connected(true)` 也不会启用操作。

测试可通过唯一节点名取得：`%ValueLabel`、`%IncrementButton`、`%ResetButton`、`%ConnectionStatus`、`%StepNote`。
界面用容器布局；图标和背景来自 `art/`，文字使用系统字体，不打包字体文件。
