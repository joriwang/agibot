# JointCommand 协议规格说明

> **源文件**: [`JointCommand.msg`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/my_ros2_proto/msg/JointCommand.msg)  
> **包名**: `my_ros2_proto`  
> **协议类型**: ROS2 Message  
> **文档版本**: v1.0 | 2026-03-20

---

## 相关文档

| 文档 | 说明 | 方向 |
|------|------|------|
| [l0_system_architecture.md](l0_system_architecture.md) | L0 系统架构（§6.1 协议定义） | 上游 |
| [module_control_module.md](module_control_module.md) | ControlModule 规格（§3.2 发布接口，§4.3 合并规则） | 生产者 |
| [module_dcu_driver_module.md](module_dcu_driver_module.md) | DcuDriverModule 规格（§3.1 订阅接口，§8.1 关节映射） | 消费者 |
| [module_sim_module.md](module_sim_module.md) | SimModule 规格（§2.2 订阅接口） | 消费者 |

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
| 腰部 | `lumbar_yaw_joint`, `lumbar_roll_joint`, `lumbar_pitch_joint` |
| 左臂 | `left_shoulder_pitch_joint`, `left_shoulder_roll_joint`, `left_shoulder_yaw_joint`, `left_elbow_pitch_joint`, `left_elbow_yaw_joint`, `left_wrist_pitch_joint`, `left_wrist_roll_joint` |
| 右臂 | `right_shoulder_pitch_joint`, `right_shoulder_roll_joint`, `right_shoulder_yaw_joint`, `right_elbow_pitch_joint`, `right_elbow_yaw_joint`, `right_wrist_pitch_joint`, `right_wrist_roll_joint` |
| 左腿 | `left_hip_pitch_joint`, `left_hip_roll_joint`, `left_hip_yaw_joint`, `left_knee_pitch_joint`, `left_ankle_pitch_joint`, `left_ankle_roll_joint` |
| 右腿 | `right_hip_pitch_joint`, `right_hip_roll_joint`, `right_hip_yaw_joint`, `right_knee_pitch_joint`, `right_ankle_pitch_joint`, `right_ankle_roll_joint` |

> **已确认**（P-JC-03）：关节名使用 `left_`/`right_` 前缀（非 `l_`/`r_`），带 `_joint` 后缀。命名与 DcuDriverModule 配置（[§8.1](module_dcu_driver_module.md)）及 ControlModule YAML 中的 `joint_list` 配置一致。夹爪关节（`left_claw_joint` / `right_claw_joint`）参与 DCU 传动但不出现在 ControlModule 的 `/joint_cmd` 中。

## 5. 运行时特征

| 属性 | 值 | 说明 |
|------|-----|------|
| 发布频率 | **1000 Hz** | 与 ControlModule 主循环频率一致（可配置） |
| Topic 名称 | `/joint_cmd` | 通过 AimRT Channel 发布 |
| 通信后端 | Local（进程内） / ROS2（跨进程） | 进程内优先使用零拷贝 Local 后端 |
| 数组长度 | 可变，取决于当前活跃控制器 | `rl_walk_leg`: 12 关节；`rl_walk_leg_shoulder`: 14 关节；全身: 最多 29 关节 |
| 数组排序 | `name` 定义顺序 | `position/velocity/effort/stiffness/damping` 均与 `name` 一一对应 |

> **已确认**（P-JC-04）：当 `ControlModule` 内多个控制器均对同一关节输出指令时，以**控制器链列表中靠后的控制器覆盖靠前的控制器**（无累加/混合/冲突检测）。因此，`stiffness` 和 `damping` 字段的最终值由优先级最高（列表最靠后）的控制器决定。详见 [module_control_module.md §4.3](module_control_module.md)。

## 6. 待确认事项

| 编号 | 事项 | 状态 |
|------|------|------|
| P-JC-01 | 各关节的位置限位范围（`position` 字段的安全取值边界）。参考：执行器层 MIT 位置范围均为 ±2π rad（见 [DcuDriverModule §7.3](module_dcu_driver_module.md)），关节空间精确限位待 URDF 核对。 | **待确认** |
| P-JC-02 | 速度和力矩字段的实际取值范围。参考：R86 执行器 ±100 N·m / ±4π rad/s，R52 执行器 ±50 N·m / ±4π rad/s（执行器层，见 [DcuDriverModule §7.3](module_dcu_driver_module.md)）；关节空间范围因传动比而异。 | **待确认** |
| P-JC-03 | 关节名称前缀（`l_` vs `left_`）及后缀格式 | **✅ 已确认**：`left_`/`right_` 前缀，`_joint` 后缀（见 §4，来源：DcuDriverModule §8.1 + ControlModule YAML） |
| P-JC-04 | 多控制器输出合并时，同一关节的 PD 增益冲突处理策略 | **✅ 已确认**：靠后控制器覆盖靠前，无累加（见 §5 注释，来源：ControlModule §4.3） |

## 7. 测试标准（Test Criteria）

| 编号 | 测试项 | 验证方法 | 通过条件 |
|------|--------|---------|---------|
| TC-JC-01 | 数组长度一致性 | 发布一条 JointCommand，检查各数组长度 | `name.size() == position.size() == velocity.size() == effort.size() == stiffness.size() == damping.size()` |
| TC-JC-02 | 关节名称合法性 | 检查 `name` 字段中每个元素 | 所有名称均在 §4 关节列表中；不包含 `left_claw_joint` / `right_claw_joint` |
| TC-JC-03 | 索引对应正确性 | 订阅 `/joint_cmd`，验证 `name[i]` 对应 `position[i]` 的控制意图 | 在 SimModule 仿真中，joint `name[i]` 的实际关节角向 `position[i]` 收敛（Kp > 0 时） |
| TC-JC-04 | 发布频率 | 以 1 秒为窗口统计 `/joint_cmd` 消息数 | 频率在 1000 ± 50 Hz 范围内 |
| TC-JC-05 | 零力矩空闲模式 | 系统处于 `idle` 状态时订阅 `/joint_cmd` | `stiffness` 和 `damping` 所有分量均为 0 |
| TC-JC-06 | PD 增益覆盖验证 | 配置 `walk_leg` 状态（含 `pd_zero` + `pd_stand` + `rl_walk_leg`） | 腿部关节的 stiffness/damping 与 `rl_walk_leg` 控制器配置一致（非 `pd_zero` 或 `pd_stand` 的值） |
