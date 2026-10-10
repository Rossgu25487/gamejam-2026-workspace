class_name DemoConfig
extends Resource
## 计数器演示配置资源，由主场景读取后应用到 CounterModel。

@export var initial_value: int = 0 # 新游戏和重置使用的初始值。
@export var step: int = 1 # 每次递增的数量。
