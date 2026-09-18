# 共享边界

本目录由主程序维护，供确有需要的共享协议与少量基础代码使用。当前计数夹具无需公共事件总线。

- 状态：`features/counter_demo/counter_model.gd`，副程序 A。
- 界面请求与显示：`ui/counter_view.gd`、`ui/counter_view.tscn`，副程序 B。
- 初值与步长：`data/demo_config.tres`；配置与接口变化由主程序协调。
- 主入口负责创建模型、应用配置、连接界面，其他模块不互相寻找节点。
