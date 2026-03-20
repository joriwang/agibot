# JointCommand 协议规格说明

> **源文件**: [`JointCommand.msg`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/my_ros2_proto/msg/JointCommand.msg)  
> **包名**: `my_ros2_proto`  
> **协议类型**: ROS2 Message  
> **文档版本**: v1.0 | 2026-03-20

---

## 1. 消息用途

传递关节级运动控制指令（目标位置、速度、力矩及 PD 增益），是控制模块与驱动/仿真模块之间的**唯一下行控制通道**。

## 2. 数据流

```
ControlModule ──── /joint_cmd ────► DcuDriverModule（真机模式）
                                  ► SimModule（仿真模式）
```

| 角色 | 模块 | 说明 |
|------|------|------|
| **生产者** | `ControlModule`（`PDController` / `RLController`） | 控制器通过 `GetJointCmdData()` 生成指令，主循环合并后发布 |
| **消费者** | `DcuDriverModule` | 回调 `JointCmdCallback()` → 传动转换 → EtherCAT 下发 |
| **消费者** | `SimModule` | 回调 `CmdCallback()` → `WriteMotorCmd()` → MuJoCo PD 力矩施加 |

## 3. 字段定义

| # | 字段名 | ROS2 类型 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|----------|---------|------|---------|------|
| 1 | `header` | `std_msgs/Header` | 消息头，含时间戳和 frame_id | — | — | `stamp` 为消息生成时刻 |
| 2 | `name` | `string[]` | 关节名称列表 | — | 见 §4 关节列表 | 数组长度 = 活跃关节数 |
| 3 | `position` | `float64[]` | 目标关节角度 | rad | 关节限位范围内 [NEEDS VERIFICATION: 各关节具体限位值] | 与 `name` 等长、按序对应 |
| 4 | `velocity` | `float64[]` | 目标关节角速度 | rad/s | [NEEDS VERIFICATION: 具体范围] | 前馈速度分量 |
| 5 | `effort` | `float64[]` | 目标关节力矩 | N·m | [NEEDS VERIFICATION: 具体范围] | 前馈力矩分量 |
| 6 | `stiffness` | `float64[]` | PD 控制刚度系数 Kp | N·m/rad | ≥ 0 | 不同控制器使用不同 Kp 配置 |
| 7 | `damping` | `float64[]` | PD 控制阻尼系数 Kd | N·m·s/rad | ≥ 0 | 不同控制器使用不同 Kd 配置 |

> **PD 力矩计算公式（消费侧）**：  
> `τ = Kp × (position_cmd − position_fb) + Kd × (velocity_cmd − velocity_fb) + effort`

## 4. 关节名称列表

消息中的 `name` 字段可包含以下关节名称（共 29 个，按配置选择子集）：

| 部位 | 关节名 |
|------|--------|
| 腰部 | `lumbar_yaw`, `lumbar_roll`, `lumbar_pitch` |
| 左臂 | `l_shoulder_pitch`, `l_shoulder_roll`, `l_shoulder_yaw`, `l_elbow_pitch`, `l_elbow_yaw`, `l_wrist_pitch`, `l_wrist_roll` |
| 右臂 | `r_shoulder_pitch`, `r_shoulder_roll`, `r_shoulder_yaw`, `r_elbow_pitch`, `r_elbow_yaw`, `r_wrist_pitch`, `r_wrist_roll` |
| 左腿 | `l_hip_pitch`, `l_hip_roll`, `l_hip_yaw`, `l_knee_pitch`, `l_ankle_pitch`, `l_ankle_roll` |
| 右腿 | `r_hip_pitch`, `r_hip_roll`, `r_hip_yaw`, `r_knee_pitch`, `r_ankle_pitch`, `r_ankle_roll` |

> [NEEDS VERIFICATION] 以上关节名称前缀（`l_` / `r_`）需与实际配置文件中的命名核对。

## 5. 运行时特征

| 属性 | 值 | 说明 |
|------|-----|------|
| 发布频率 | **1000 Hz** | 与 ControlModule 主循环频率一致（可配置） |
| Topic 名称 | `/joint_cmd` | 通过 AimRT Channel 发布 |
| 通信后端 | Local（进程内） / ROS2（跨进程） | 进程内优先使用零拷贝 Local 后端 |
| 数组长度 | 可变，取决于当前活跃控制器 | `rl_walk_leg`: 12 关节；`rl_walk_leg_shoulder`: 14 关节；全身: 最多 29 关节 |
| 数组排序 | `name` 定义顺序 | `position/velocity/effort/stiffness/damping` 均与 `name` 一一对应 |

## 6. 待确认事项

| 编号 | 事项 |
|------|------|
| P-JC-01 | 各关节的位置限位范围（`position` 字段的安全取值边界） |
| P-JC-02 | 速度和力矩字段的实际取值范围 |
| P-JC-03 | 关节名称的精确前缀格式（`l_` vs `left_` 等） |
| P-JC-04 | 多个控制器输出合并时，同一关节的 PD 增益冲突处理策略 |
