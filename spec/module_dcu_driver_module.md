# DcuDriverModule 模块规格说明

> **文档版本**: v2.0
> **生成日期**: 2026-03-20
> **最后更新**: 2026-03-20（基于源码全量审阅，补充 Internal Logic、算法描述、Error Handling，修正多处 v1.0 推断错误）
> **适用系统**: AgiBot X1 推理与控制软件（xyber_x1_infer）
> **命名空间**: `xyber_x1_infer::dcu_driver_module`
> **源码路径**: `src/module/dcu_driver_module/`
> **配置路径**: `src/module/dcu_driver_module/cfg/dcu_x1.yaml`

---

## 相关文档

| 文档 | 说明 | 关系 |
|------|------|------|
| [l0_system_architecture.md](l0_system_architecture.md) | L0 系统架构（§3.2 DcuDriverModule 描述） | 上游架构 |
| [protocol_joint_command.md](protocol_joint_command.md) | JointCommand 协议规格（订阅 `/joint_cmd`） | 消费协议 |
| [module_control_module.md](module_control_module.md) | ControlModule（发布 `/joint_cmd`，消费 `/joint_states` / `/imu/data`） | 协作模块 |

---

## 1. 模块定位

DcuDriverModule 是系统的**硬件驱动模块**，负责：

1. 管理 EtherCAT 总线与两个 DCU（body / hip）的实时通信
2. 以 **1000 Hz**（可配置）从 EtherCAT 缓存读取执行器位置/速度/力矩反馈及 IMU 数据，并发布到 Channel
3. 接收 ControlModule 发来的关节空间指令，经**传动层（TransmissionManager）**转换为执行器空间指令后下发
4. 管理执行器的**使能/失能**生命周期

该模块仅在**真机模式**下部署（配置文件 `x1_cfg.yaml`），仿真模式由 SimModule 替代。作为 AimRT Pkg（`libpkg1.so`）的一部分加载，继承自 `aimrt::ModuleBase`。

---

## 2. 生命周期接口

| 方法 | 触发时机 | 职责 |
|------|---------|------|
| `Initialize(CoreRef)` | AimRT 启动阶段 | 解析 YAML 配置；调用 `InitDcu()`（含 EtherCAT 启动和执行器使能）；调用 `InitTransmission()`；注册 Channel 发布/订阅句柄 |
| `Start()` | 所有模块 Initialize 完成后 | 设置 `is_running_=true`，启动 `publish_thread_` |
| `Shutdown()` | 进程退出信号 | 设置 `is_running_=false`，join `publish_thread_`；调用 `DisableAllActuator()` 再调用 `XyberController::Stop()` |

> **重要**：EtherCAT 通信在 `Initialize()` 阶段的 `InitDcu()` 内部启动，而非 `Start()`。这意味着 EtherCAT 就绪早于 AimRT 发布循环启动。

---

## 3. Channel 接口契约

### 3.1 订阅（Subscribe）

| Topic（默认） | 消息类型 | 来源模块 | 说明 |
|--------------|---------|---------|------|
| `/joint_cmd` | `my_ros2_proto/JointCommand` | ControlModule | 关节空间 PD 指令；回调 `JointCmdCallback()` 触发传动转换并下发执行器 |

### 3.2 发布（Publish）

| Topic（默认） | 消息类型 | 频率 | 说明 |
|--------------|---------|------|------|
| `/joint_states` | `sensor_msgs/JointState` | `publish_frequecy`（默认 1000 Hz） | 31 个关节的 position/velocity/effort，顺序由 `joint_list` 配置决定 |
| `/imu/data` | `sensor_msgs/Imu` | `publish_frequecy`（默认 1000 Hz） | hip DCU 内嵌 IMU；gyro 单位 rad/s（从 deg/s 转换）；acc 单位 m/s²；quat 布局 [w,x,y,z] |
| `/actuator_states` | `sensor_msgs/JointState` | `publish_frequecy`（默认 1000 Hz） | 执行器原始状态；**仅 `actuator_debug: true` 时发布** |
| `/actuator_cmd` | `my_ros2_proto/JointCommand` | `publish_frequecy`（默认 1000 Hz） | 上次下发的执行器指令快照；**仅 `actuator_debug: true` 时发布**；与 `/actuator_states` 同周期，非实时反映每次 JointCmd |

> **注意**：`/actuator_cmd` 消息类型为 `my_ros2_proto/JointCommand`（含 stiffness/damping 字段），而非 `sensor_msgs/JointState`——v1.0 推断有误。
>
> `/imu/data` 和 `/joint_states` 在 `publish_thread_` 的同一个循环迭代中先后发布，时间戳均来自 `gettimeofday()`（墙上时钟），而非 `steady_clock`。

---

## 4. Internal Logic

### 4.1 初始化流程（Initialize）

```
Initialize()
├── 读取 YAML 配置（imu_dcu_name, actuator_debug, enable_actuator,
│   publish_frequecy, joint_list, actuator_list）
├── InitDcu()
│   ├── 解析 ethercat 和 dcu_network 配置
│   ├── XyberController::GetInstance()（单例）
│   ├── 遍历 dcu_network_cfg_：
│   │   ├── 跳过 enable=false 的 DCU
│   │   ├── CreateDcu(name, ecat_id)
│   │   └── 遍历 3 个通道的所有执行器：
│   │       ├── 检查执行器名是否在 actuator_name_list_ 中
│   │       │   └── 不在则 WARN 并跳过（容错）
│   │       └── AttachActuator(dcu_name, channel, type, name, can_id)
│   ├── SetRealtime(rt_priority, bind_cpu)
│   ├── Start(ifname, cycle_ns, enable_dc)  ← EtherCAT 在此启动
│   ├── 若 enable_actuator：
│   │   ├── 逐个 EnableActuator(name)，有失败则累积 ret=false
│   │   ├── 若任何一个使能失败 → AIMRT_ERROR_THROW（中止）
│   │   └── 所有执行器 SetMitCmd(name, 0,0,0,0,0)（预填零指令缓存）
│   └── 遍历 dcu_network_cfg_：imu_enable=true → ApplyDcuImuOffset(name)
├── InitTransmission()
│   ├── 为所有 joint_list 和 actuator_list 创建 DataSpace 条目（默认零值）
│   └── 遍历 transmission 配置节点：
│       ├── SimpleTransmission：解析 joint/actuator/direction，查找 data_space
│       │   └── 未找到关节或执行器 → WARN 并 continue（跳过该传动，不中止）
│       ├── [Left/Right]AnkleParallelTransmission：同上，另加载 param_path 查表文件
│       ├── [Left/Right]WristParallelTransmission：同上（param_path 被忽略）
│       ├── LumbarParallelTransmission：同上（param_path 被忽略）
│       └── 未知 type → AIMRT_ERROR_THROW（中止）
└── 注册 5 个 Channel 句柄（4 发布 + 1 订阅）
```

### 4.2 PublishLoop 主循环

```
PublishLoop()（publish_thread_ 中运行）

预分配消息结构体：
  js_msg.name ← joint_name_list_（有序，按配置顺序）
  actr_state.name ← actuator_name_list_
  actr_cmd.name ← actuator_name_list_

period = 1 / publish_frequecy_ 秒（纳秒精度）
next_loop_time = steady_clock::now()

while (is_running_):
  1. 获取时间戳：gettimeofday() → builtin_interfaces::Time
  2. 刷新执行器状态（无锁）：
       for each actuator in actuator_data_space_:
           data.state.effort   ← xyber_ctrl_->GetEffort(name)
           data.state.velocity ← xyber_ctrl_->GetVelocity(name)
           data.state.position ← xyber_ctrl_->GetPosition(name)
  3. 传动转换（加锁）：
       lock(rw_mtx_)
       transmission_.TransformActuatorToJoint()
       unlock
  4. 发布 /joint_states：
       for i in [0, joint_name_list_.size()):
           js_msg[i] ← joint_data_space_[joint_name_list_[i]].state
       js_msg.header.stamp = stamp
       pub_joint_state.Publish(js_msg)
  5. 若 actuator_debug：
       for i in [0, actuator_name_list_.size()):
           actr_state[i] ← actuator_data_space_[name].state
           actr_cmd[i] ← actuator_data_space_[name].cmd  （上次 JointCmdCallback 设置的值）
       pub_actuator_state.Publish(actr_state)
       pub_actuator_cmd.Publish(actr_cmd)
  6. 发布 /imu/data：
       imu = xyber_ctrl_->GetDcuImuData(imu_dcu_name_)
       angular_velocity.{x,y,z} = imu.gyro[0,1,2] / 180 * π  （deg/s → rad/s）
       linear_acceleration.{x,y,z} = imu.acc[0,1,2]           （单位不变）
       orientation.{w,x,y,z} = imu.quat[0,1,2,3]
       imu_msg.header.stamp = stamp
       pub_imu.Publish(imu_msg)
  7. 定时：
       next_loop_time += period
       sleep_until(next_loop_time)                              （绝对定时，无累积漂移）
```

### 4.3 JointCmdCallback 回调

```
JointCmdCallback(msg)

if !is_running_: return  （Shutdown 后静默丢弃）

for i in [0, msg->name.size()):
    it = joint_data_space_.find(msg->name[i])
    if not found:
        WARN("joint {} not found")
        continue          （跳过单个未知关节，继续处理后续关节）
    it->second.cmd = { effort=msg->effort[i], velocity=msg->velocity[i],
                       position=msg->position[i], kp=msg->stiffness[i],
                       kd=msg->damping[i] }

lock(rw_mtx_)
transmission_.TransformJointToActuator()
unlock

for each (name, data) in actuator_data_space_:
    xyber_ctrl_->SetMitCmd(name, data.cmd.position, data.cmd.velocity,
                           data.cmd.effort, data.cmd.kp, data.cmd.kd)
```

> `JointCmdCallback` 中**不发布** `/actuator_cmd`，该 Topic 仅在 `PublishLoop` 中发布，因此调试 Topic 反映的是上一次 `PublishLoop` 迭代时执行器指令的快照，存在最多一个发布周期（1ms）的时间差。

---

## 5. 传动层算法详解

### 5.1 SimpleTransmission

最简单的传动，1:1 带方向系数：

```
状态（执行器 → 关节）：
  joint.state = actuator.state × direction

指令（关节 → 执行器）：
  actuator.cmd.pos/vel/effort = joint.cmd.pos/vel/effort × direction
  actuator.cmd.kp = joint.cmd.kp   （刚度不乘方向）
  actuator.cmd.kd = joint.cmd.kd   （阻尼不乘方向）
```

### 5.2 AnkleParallelTransmission（脚踝并联传动）

脚踝是唯一有完整非线性运动学的传动，左右脚踝逻辑对称但有符号差异。

**物理参数**（硬编码，单位 m/rad）：

| 符号 | 值 | 含义 |
|------|-----|------|
| `r` | 0.025 m | 曲柄半径 |
| `l` | 0.025 m（50mm/2） | 半跨距 |
| `l_p1p2` | 0.195 m | 连杆 1 长度 |
| `l_p3p4` | 0.14 m | 连杆 2 长度 |
| `p_4m5_4_z` | 0.195 m | 连接点 Z 坐标 |
| `p_4m6_4_z` | 0.14 m | 连接点 Z 坐标 |
| `p_4p2_6_y`（左） | ±0.025 m | 连接点 Y 坐标（左右符号相反） |
| 零位偏置 qm5 | ±1.2028 rad | 左/右脚踝 qm5 机构零位偏置 |
| 零位偏置 qm6 | ∓1.2030 rad | 左/右脚踝 qm6 机构零位偏置 |

**执行器角度定义（LeftAnkle）**：
```
qm5 = -actr_right.state.position × actr_right.direction   （注意取负）
qm6 = -actr_left.state.position  × actr_left.direction    （注意取负）
```

**RightAnkle** 执行器映射相反：`qm5 = actr_left`, `qm6 = actr_right`，且无取负操作。

**位置：执行器 → 关节（查表 + 线性插值）**

1. 构建查表索引：
   ```
   QM5 range: [-1.4, 1.0] rad，步长 0.4/180×π rad（≈6.98 mrad）
   QM6 range: [-1.0, 1.4] rad，步长相同
   i = int((qm5 - QM5_MIN) / step)
   j = int((qm6 - QM6_MIN) / step)
   ```
2. 查表键：`"qm5qm6_{i+1}_{j+1}"` 和 `"qm5qm6_{i+2}_{j+2}"`（对角邻格）
3. 线性插值（**注意：不是双线性，是沿对角线方向各自独立插值**）：
   ```
   lerp5 = qm5 的小数部分（在格子内的位置）
   lerp6 = qm6 的小数部分
   q5 = lerp5 × (table[i+1,j+1].q5 - table[i,j].q5) + table[i,j].q5
   q6 = lerp6 × (table[i+1,j+1].q6 - table[i,j].q6) + table[i,j].q6
   左踝结果额外处理：q6 *= -1
   ```

**力矩：执行器 → 关节（Jacobian 变换）**

通过机构运动学推导的雅可比矩阵 `J`（含 `f1a, f1b, f2a, f2b` 4 个分量，依赖当前关节角 q5/q6 和执行器角 qm5/qm6）：
```
[tauj5]   [f1a  f1b] [taum5]
[tauj6] = [f2a  f2b] [taum6]
```

**速度：执行器 → 关节（Jacobian 转置的逆）**

```
[qd5]             [qdm5]
[qd6] = (J^T)^T × [qdm6]   其中 J^T 与力矩变换矩阵相同
```

**位置：关节 → 执行器（逆运动学，闭合解）**

对每条连杆建立约束方程 `a·cos(qm) + b·sin(qm) = c`，解为：
```
左踝：
  qm5Des = acos(c1/√(a1²+b1²)) + atan2(a1, b1) - 1.2028
  qm6Des = -acos(c2/√(a2²+b2²)) + atan2(a2, b2) + 1.2030
右踝：符号相反
```

**力矩和速度：关节 → 执行器（Jacobian 逆变换）**

使用当前 `state` 中的关节角/执行器角重新计算 Jacobian，然后：
```
[taum5Des]   J^{-1}   [tau5Des]
[taum6Des] =        × [tau6Des]

[qdm5Des]   J^{-1}   [qd5Des]
[qdm6Des] =        × [qd6Des]   （J_T.transpose().inverse()）
```

### 5.3 WristParallelTransmission 和 LumbarParallelTransmission

**源码实际实现为直通映射（与类名"Parallel"不符）**，`param_path` 在构造时被完全忽略：

```
状态（执行器 → 关节）：
  joint_pitch.state = actr_right.state × actr_right.direction
  joint_roll.state  = actr_left.state  × actr_left.direction

指令（关节 → 执行器）：
  actr_right.cmd = joint_pitch.cmd × actr_right.direction
  actr_left.cmd  = joint_roll.cmd  × actr_left.direction
```

这两类传动与 `SimpleTransmission` 在功能上完全等价，只是使用了 2×1 到 2×1 的分开映射而非单个关节映射。

---

## 6. 已知缺陷（源码审阅发现）

### 6.1 力矩输入 copy-paste 错误（[NEEDS VERIFICATION]）

在以下所有并联传动类的 `TransformActuatorToJoint()` 中，`taum6`（roll 轴执行器力矩）被错误地从 `state.velocity` 读取而非 `state.effort`：

| 类 | 错误位置 |
|----|---------|
| `LeftAnkleParallelTransmission` | [ankle_transmission.cc:135](../src/module/dcu_driver_module/src/ankle_transmission.cc#L135) |
| `RightAnkleParallelTransmission` | [ankle_transmission.cc:487](../src/module/dcu_driver_module/src/ankle_transmission.cc#L487) |
| `LeftWristParallelTransmission` | [wrist_transmission.cc:33](../src/module/dcu_driver_module/src/wrist_transmission.cc#L33) |
| `RightWristParallelTransmission` | [wrist_transmission.cc:90](../src/module/dcu_driver_module/src/wrist_transmission.cc#L90) |
| `LumbarParallelTransmission` | [lumbar_transmission.cc:27](../src/module/dcu_driver_module/src/lumbar_transmission.cc#L27) |

```cpp
// 错误代码（5 处相同）：
double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;
//                                  ^^^^^^^^ 应为 effort
```

**影响**：
- 脚踝：传递到 roll 轴的关节力矩（`tauj6`）使用速度数据计算，量纲错误，但由于 RL 控制器本身不依赖 `/joint_states` 中的 effort 字段（仅使用 position 和 velocity），实际控制效果中该错误**可能未被显现**。
- 腕部/腰部：力矩直通赋值，`joint_roll.state.effort` 被赋值为速度值，但同上，RL 推理也不使用 effort 字段。

### 6.2 脚踝查表越界无保护

当执行器角度超出查表范围（qm5 < -1.4 或 > 1.0，qm6 < -1.0 或 > 1.4）时：
- `qm5_num_int < 0`：仅打印 `std::cout`，不阻止后续计算
- 查表键找不到：输出 `std::cout`，`q5 = q6 = 0.0`（保留为零，不再更新）

超出范围时位置输出为 0，力矩和速度仍按上一个有效值的 Jacobian 计算，可能导致控制异常。

---

## 7. EtherCAT 网络拓扑

### 7.1 EtherCAT 全局配置

| 参数 | 默认值 | 说明 |
|-----|--------|------|
| `ifname` | `enp2s0` | 网卡接口名 |
| `bind_cpu` | `9` | EtherCAT IO 线程绑定 CPU 核心 |
| `rt_priority` | `90` | EtherCAT IO 线程实时优先级（SCHED_FIFO） |
| `enable_dc` | `true` | 启用 Distributed Clock 主从站同步 |
| `cycle_time_ns` | `1000000`（1 ms） | EtherCAT 帧刷新周期 |

### 7.2 DCU 拓扑

| DCU 名 | EtherCAT ID | 通道数 | 挂载执行器 | IMU |
|--------|-------------|--------|-----------|-----|
| `body` | 1 | 3 | CH1: 左臂 8 个（含夹爪）；CH2: 右臂 8 个（含夹爪）；CH3: 腰部 left/right | 无 |
| `hip` | 2 | 3 | CH1: 左腿 6 个；CH2: 右腿 6 个；CH3: 腰部 yaw | 有（`imu_dcu_name: hip`） |

### 7.3 执行器类型与 MIT 参数范围

| 类型标识 | 应用部位 | 力矩范围 | 位置范围 | 速度范围 |
|---------|---------|---------|---------|---------|
| `POWER_FLOW_R86` | 髋、肩、膝、腰 | ±100 N·m | ±2π rad | ±4π rad/s |
| `POWER_FLOW_R52` | 踝、肘、肩偏航 | ±50 N·m | ±2π rad | ±4π rad/s |
| `POWER_FLOW_L28` | 腕部 | [NEEDS VERIFICATION] | — | — |
| `OMNI_PICKER` | 夹爪 | 仅 pos/effort 有效 | — | — |

所有执行器控制模式：**MIT 模式**（`MODE_MIT = 6`），通过 `SetMitCmd(pos, vel, effort, kp, kd)` 下发。

---

## 8. 关节与执行器映射总表

### 8.1 完整映射（31 个关节）

| 部位 | 关节名 | 对应执行器 | 传动类型 | 方向 |
|------|--------|-----------|---------|------|
| 左腿 | left_hip_pitch_joint | left_hip_pitch_actuator | Simple | -1.0 |
| 左腿 | left_hip_roll_joint | left_hip_roll_actuator | Simple | -1.0 |
| 左腿 | left_hip_yaw_joint | left_hip_yaw_actuator | Simple | -1.0 |
| 左腿 | left_knee_pitch_joint | left_knee_pitch_actuator | Simple | -1.0 |
| 左腿 | left_ankle_pitch_joint | left_ankle_left/right_actuator | LeftAnkleParallel | left:1.0, right:1.0 |
| 左腿 | left_ankle_roll_joint | left_ankle_left/right_actuator | LeftAnkleParallel | （同上） |
| 右腿 | right_hip_pitch_joint | right_hip_pitch_actuator | Simple | -1.0 |
| 右腿 | right_hip_roll_joint | right_hip_roll_actuator | Simple | -1.0 |
| 右腿 | right_hip_yaw_joint | right_hip_yaw_actuator | Simple | -1.0 |
| 右腿 | right_knee_pitch_joint | right_knee_pitch_actuator | Simple | **+1.0**（与左腿异号） |
| 右腿 | right_ankle_pitch_joint | right_ankle_left/right_actuator | RightAnkleParallel | left:1.0, right:1.0 |
| 右腿 | right_ankle_roll_joint | right_ankle_left/right_actuator | RightAnkleParallel | （同上） |
| 腰部 | lumbar_roll_joint | lumbar_left/right_actuator | LumbarParallel（直通） | left:1.0, right:1.0 |
| 腰部 | lumbar_pitch_joint | lumbar_left/right_actuator | LumbarParallel（直通） | （同上） |
| 腰部 | lumbar_yaw_joint | lumbar_yaw_actuator | Simple | +1.0 |
| 左臂 | left_shoulder_pitch_joint | left_shoulder_pitch_actuator | Simple | +1.0 |
| 左臂 | left_shoulder_roll_joint | left_shoulder_roll_actuator | Simple | -1.0 |
| 左臂 | left_shoulder_yaw_joint | left_shoulder_yaw_actuator | Simple | +1.0 |
| 左臂 | left_elbow_pitch_joint | left_elbow_pitch_actuator | Simple | +1.0 |
| 左臂 | left_elbow_yaw_joint | left_elbow_yaw_actuator | Simple | +1.0 |
| 左臂 | left_wrist_pitch_joint | left_wrist_front_actuator（right handle） | WristParallel（直通） | front:1.0, back:1.0 |
| 左臂 | left_wrist_roll_joint | left_wrist_back_actuator（left handle） | WristParallel（直通） | （同上） |
| 左臂 | left_claw_joint | left_claw_actuator | Simple | +1.0 |
| 右臂 | right_shoulder_pitch_joint | right_shoulder_pitch_actuator | Simple | -1.0 |
| 右臂 | right_shoulder_roll_joint | right_shoulder_roll_actuator | Simple | +1.0 |
| 右臂 | right_shoulder_yaw_joint | right_shoulder_yaw_actuator | Simple | +1.0 |
| 右臂 | right_elbow_pitch_joint | right_elbow_pitch_actuator | Simple | -1.0 |
| 右臂 | right_elbow_yaw_joint | right_elbow_yaw_actuator | Simple | +1.0 |
| 右臂 | right_wrist_pitch_joint | right_wrist_front_actuator（right handle） | WristParallel（直通） | front:1.0, back:1.0 |
| 右臂 | right_wrist_roll_joint | right_wrist_back_actuator（left handle） | WristParallel（直通） | （同上） |
| 右臂 | right_claw_joint | right_claw_actuator | Simple | +1.0 |

> 夹爪关节（`left/right_claw_joint`）参与 DCU 传动，但不参与 ControlModule 的 RL 推理。

---

## 9. 线程模型与并发保护

| 线程 | 创建方式 | 调度策略 | 频率 | 职责 |
|------|---------|---------|------|------|
| EtherCAT IO Thread | `XyberController` 内部 | `SCHED_FIFO` RT 优先级 90，绑 CPU #9 | 1000 Hz | EtherCAT 帧收发，更新执行器内部缓存 |
| `publish_thread_` | `std::thread` | `SCHED_OTHER`（普通调度） | 1000 Hz（可配置） | 读缓存→传动转换→发布 Topic，使用 `sleep_until` 绝对定时 |
| AimRT 回调线程 | AimRT 框架 | 框架决定 | 事件驱动 | 执行 `JointCmdCallback`，更新指令缓存→传动转换→调用 SetMitCmd |

**`rw_mtx_` 保护范围**：仅 `TransformActuatorToJoint()` 和 `TransformJointToActuator()` 调用期间（即 DataSpace 被并联传动数学读写时）。以下操作在锁外进行：

- `GetEffort/Velocity/Position()`：从 EtherCAT 缓存读取（XyberController 内部有自己的线程安全机制）
- `SetMitCmd()`：向 EtherCAT 缓存写入
- `actuator_data_space_` 的 state 字段写入（在 publish_thread_ 中）
- `joint_data_space_` 的 cmd 字段写入（在 JointCmdCallback 中）

---

## 10. Error Handling

| 情形 | 处理方式 | 影响 |
|------|---------|------|
| YAML 配置解析失败 | `catch(std::exception)` → `AIMRT_ERROR` → `Initialize()` 返回 false | 模块不启动 |
| DCU 注册失败 | `AIMRT_CHECK_ERROR_THROW` → 抛出异常 → Initialize 失败 | 模块不启动 |
| 执行器注册失败 | `AIMRT_CHECK_ERROR_THROW` → 同上 | 模块不启动 |
| EtherCAT Start 失败 | `AIMRT_ERROR_THROW` → 同上 | 模块不启动 |
| 执行器使能失败（任意一个） | 累积 `ret=false`，遍历完成后 `AIMRT_ERROR_THROW` | 模块不启动；**不会跳过失败继续使能其他** |
| 传动中关节/执行器名查不到 | `AIMRT_WARN` + `continue`（跳过该传动对象） | 该关节的传动静默丢失，但模块正常启动 |
| 未知传动类型 | `AIMRT_ERROR_THROW` → Initialize 失败 | 模块不启动 |
| JointCmdCallback 中关节名查不到 | `AIMRT_WARN` + `continue`（跳过单个关节） | 该关节保持上次指令（或零指令） |
| `is_running_=false` 时收到 JointCmd | 函数头返回，不处理 | 安全丢弃 |
| 脚踝查表索引越界 | `std::cout` 输出，位置输出保持 0.0 | 力矩/速度仍按当前 Jacobian 计算，可能控制异常 |
| 传动转换分母为零（奇异构型） | **无保护**（会产生 NaN/Inf） | 指令可能异常，下发至执行器 |

---

## 11. 配置参数参考

配置文件：[cfg/dcu_x1.yaml](../src/module/dcu_driver_module/cfg/dcu_x1.yaml)

| 参数键 | 类型 | 默认值 | 说明 |
|-------|------|--------|------|
| `publish_frequecy` | float | 1000.0 | 传感器数据发布频率（Hz）。注意原始代码中有拼写错误（frequency） |
| `imu_dcu_name` | string | `"hip"` | 提供 IMU 数据的 DCU 名称 |
| `enable_actuator` | bool | true | Initialize 时是否逐个调用 `EnableActuator()` |
| `actuator_debug` | bool | true | 是否以相同频率发布 `/actuator_states` 和 `/actuator_cmd` |
| `joint_list` | string[] | 31 项 | 关节名称有序列表，决定 `/joint_states` 消息中的索引顺序 |
| `actuator_list` | string[] | 32 项 | 执行器名称有序列表；同时作为执行器使能和 SetMitCmd 的遍历列表 |
| `ethercat.ifname` | string | `"enp2s0"` | 网卡接口 |
| `ethercat.bind_cpu` | int | 9 | EtherCAT IO 线程绑定 CPU 核心 |
| `ethercat.rt_priority` | int | 90 | EtherCAT IO 线程 RT 优先级 |
| `ethercat.enable_dc` | bool | true | 启用 Distributed Clock |
| `ethercat.cycle_time_ns` | uint64 | 1000000 | EtherCAT 帧周期（ns） |
| `dcu_network[].name` | string | — | DCU 索引名 |
| `dcu_network[].ecat_id` | uint32 | — | EtherCAT 从站 ID（从 1 开始） |
| `dcu_network[].enable` | bool | — | 是否启用该 DCU |
| `dcu_network[].imu_enable` | bool | — | 该 DCU 是否调用 ApplyDcuImuOffset |
| `dcu_network[].channel_N[].name` | string | — | 执行器索引名（需在 `actuator_list` 中存在，否则跳过） |
| `dcu_network[].channel_N[].type` | string | — | 执行器类型（见 §7.3） |
| `dcu_network[].channel_N[].can_id` | uint32 | — | 执行器 CAN ID |
| `transmission[].type` | string | — | 传动类型（见 §5） |
| `transmission[].direction` | float | — | SimpleTransmission 方向系数（±1.0） |
| `transmission[].param_path` | string\|null | — | 脚踝传动查表文件路径（腕/腰传动中被忽略） |

---

## 12. 验证记录

| 编号 | v1.0 推断 | 源码实际 | 状态 |
|------|----------|---------|------|
| V-01 | EtherCAT 在 Start() 启动 | 在 Initialize() 的 InitDcu() 内启动 | **已修正** |
| V-02 | Shutdown 只调 Stop() | 先 DisableAllActuator() 后 Stop() | **已修正** |
| V-03 | /actuator_cmd 消息类型为 JointState | 实为 `my_ros2_proto/JointCommand`（含 stiffness/damping） | **已修正** |
| V-04 | /actuator_cmd 在 JointCmdCallback 发布 | 在 PublishLoop 发布（与 joint_states 同周期） | **已修正** |
| V-05 | publish_thread_ 可能用 sleep_for | 使用 sleep_until(next_loop_time) 绝对定时 | **已确认** |
| V-06 | WristParallel 有实际并联运动学 | 实为直通映射（SimpleTransmission 等价） | **已修正** |
| V-07 | LumbarParallel 有实际并联运动学 | 实为直通映射，param_path 被忽略 | **已修正** |
| V-08 | IMU gyro 单位待确认 | deg/s 转 rad/s（除以 180 乘以 π） | **已确认** |
| V-09 | 关节偏移量 | 无任何偏移量处理（与 L0 文档 V-08 一致） | **已确认** |
| BUG-01 | — | 所有并联传动的 taum6 使用 state.velocity 而非 state.effort | **新发现** |
| BUG-02 | — | 脚踝越界时无异常处理，位置输出为 0 | **新发现** |
| BUG-03 | — | 传动奇异构型时分母为零无保护 | **新发现** |

## 13. 测试标准（Test Criteria）

| 编号 | 测试项 | 验证方法 | 通过条件 |
|------|--------|---------|---------|
| TC-DCU-01 | SimpleTransmission 正确性 | 对已知执行器角度输入，检查 `/joint_states` 中对应关节角 | `joint_angle = actuator_angle × direction`（误差 < 1e-6 rad） |
| TC-DCU-02 | JointState 完整性 | 订阅 `/joint_states` 消息，检查 `name` 字段 | 包含 `joint_list` 配置中的全部 31 个关节名，顺序一致 |
| TC-DCU-03 | IMU 单位转换 | 对比 hip DCU 原始 gyro 数据（deg/s）与 `/imu/data` 中 `angular_velocity` | `angular_velocity = gyro_raw × π / 180`（误差 < 1e-6 rad/s） |
| TC-DCU-04 | 发布频率 | 以 1 秒为窗口统计 `/joint_states` 和 `/imu/data` 消息数 | 两个 Topic 频率均在 1000 ± 50 Hz 范围内 |
| TC-DCU-05 | 关节指令透传 | 发布已知的 `/joint_cmd`，验证 EtherCAT SetMitCmd 调用参数 | 执行器收到的位置/速度/力矩指令与 JointCommand 消息经传动转换后的期望值一致 |
| TC-DCU-06 | 未知关节容错 | 在 `/joint_cmd` 中包含 `joint_list` 之外的关节名 | 模块发出 WARN 日志，跳过该关节，其余关节正常处理 |
| TC-DCU-07 | 脚踝并联传动位置正确性 | 在已知执行器角度（查表范围内）下检查脚踝关节角输出 | 与离线查表计算结果误差 < 0.01 rad |
| TC-DCU-08 | Shutdown 安全 | 正常启动后发送终止信号 | `DisableAllActuator()` 被调用（执行器失能），后 `XyberController::Stop()` 完成，无崩溃 |

---
