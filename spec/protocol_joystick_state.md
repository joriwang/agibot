# JoyStickState 协议规格说明

> **源文件**: [`JoyStickState.msg`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/my_ros2_proto/msg/JoyStickState.msg)  
> **包名**: `my_ros2_proto`  
> **协议类型**: ROS2 Message  
> **文档版本**: v1.0 | 2026-03-20

---

> [!WARNING]
> **当前代码状态**：此消息在 C++ 代码中**无任何引用**。可能为预留协议或早期设计遗留，实际未被使用。

## 1. 消息用途

报告手柄设备的连接状态和健康信息，用于系统监控或 UI 显示手柄在线/离线状态。[NEEDS VERIFICATION: 是否在生产环境中使用]

## 2. 数据流

```
[NEEDS VERIFICATION]
JoyStickModule ──── ??? ────► 监控/UI 模块
```

| 角色 | 模块 | 说明 |
|------|------|------|
| **生产者** | `JoyStickModule`（推测） | [NEEDS VERIFICATION] 代码中未找到实际发布点 |
| **消费者** | 未知 | [NEEDS VERIFICATION] 可能为外部监控系统或 UI |

## 3. 字段定义

| # | 字段名 | ROS2 类型 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|----------|---------|------|---------|------|
| 1 | `is_alive` | `bool` | 手柄设备连接状态 | — | `true`（在线）/ `false`（离线） | 反映物理连接是否有效 |
| 2 | `detail` | `string` | 状态详情描述 | — | 自由文本 | 可包含错误信息或设备名称等 |

## 4. 运行时特征

| 属性 | 值 | 说明 |
|------|-----|------|
| 发布频率 | [NEEDS VERIFICATION] | 推测为事件驱动（连接/断开时发布）或低频轮询 |
| Topic 名称 | [NEEDS VERIFICATION] | — |

## 5. 待确认事项

| 编号 | 事项 |
|------|------|
| P-JS-01 | 此消息是否已废弃？是否有计划在未来版本使用？ |
| P-JS-02 | 发布模式：事件驱动还是周期轮询？ |
| P-JS-03 | 生产者和消费者模块的确认 |
| P-JS-04 | 对应的 Topic 名称 |
