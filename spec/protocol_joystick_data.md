# JoyStickData 协议规格说明

> **源文件**: [`JoyStickData.msg`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/my_ros2_proto/msg/JoyStickData.msg)  
> **包名**: `my_ros2_proto`  
> **协议类型**: ROS2 Message  
> **文档版本**: v1.0 | 2026-03-20

---

> [!WARNING]
> **当前代码状态**：此消息在 C++ 代码中**无任何引用**。可能为预留协议或早期设计遗留，实际未被使用。

## 1. 消息用途

传递手柄（Joystick）的原始轴数据，用于表示手柄输入的三维轴信息。[NEEDS VERIFICATION: 是否在生产环境中使用]

## 2. 数据流

```
[NEEDS VERIFICATION]
JoyStickModule ──── ??? ────► ???
```

| 角色 | 模块 | 说明 |
|------|------|------|
| **生产者** | `JoyStickModule`（推测） | [NEEDS VERIFICATION] 代码中未找到实际发布点 |
| **消费者** | 未知 | [NEEDS VERIFICATION] 代码中未找到订阅方 |

> **注**：当前 `JoyStickModule` 实际使用 `geometry_msgs/Twist`（`/cmd_vel`）和 `std_msgs/Float32`（模式切换 Topic）发布指令，并未使用此自定义消息。

## 3. 字段定义

| # | 字段名 | ROS2 类型 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|----------|---------|------|---------|------|
| 1 | `name` | `string` | 手柄设备名称标识 | — | — | 用于区分不同手柄设备 |
| 2 | `x` | `int32` | X 轴数据 | [NEEDS VERIFICATION] | [NEEDS VERIFICATION] | 可能对应水平轴摇杆 |
| 3 | `y` | `int32` | Y 轴数据 | [NEEDS VERIFICATION] | [NEEDS VERIFICATION] | 可能对应垂直轴摇杆 |
| 4 | `z` | `int32` | Z 轴数据 | [NEEDS VERIFICATION] | [NEEDS VERIFICATION] | 可能对应扳机/旋转轴 |

## 4. 运行时特征

| 属性 | 值 | 说明 |
|------|-----|------|
| 发布频率 | [NEEDS VERIFICATION] | 若与 JoyStickModule 关联，推测为 20 Hz |
| Topic 名称 | [NEEDS VERIFICATION] | — |

## 5. 待确认事项

| 编号 | 事项 |
|------|------|
| P-JD-01 | 此消息是否已废弃？是否有计划在未来版本使用？ |
| P-JD-02 | `x/y/z` 字段的具体语义、单位和取值范围 |
| P-JD-03 | 生产者和消费者模块的确认 |
| P-JD-04 | 对应的 Topic 名称 |
