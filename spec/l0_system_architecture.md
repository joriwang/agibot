# AgiBot X1 推理软件 — L0 系统架构规格说明

> **文档版本**: v1.2
> **生成日期**: 2026-03-19
> **最后更新**: 2026-03-20（新增 §5.1 AimRT 框架核心概念详解）
> **适用系统**: AgiBot X1 人形机器人推理与控制软件（xyber_x1_infer）  
> **许可协议**: MulanPSL-2.0

---

## 相关文档

### L1 模块规格

| 模块 | 规格文档 | 说明 |
|------|---------|------|
| ControlModule | [module_control_module.md](module_control_module.md) | RL 控制、状态机、控制器链 |
| DcuDriverModule | [module_dcu_driver_module.md](module_dcu_driver_module.md) | EtherCAT 驱动、传动层 |
| JoyStickModule | [module_joy_stick_module.md](module_joy_stick_module.md) | 手柄输入、速度限幅 |
| SimModule | [module_sim_module.md](module_sim_module.md) | MuJoCo 物理仿真 |

### L2 协议规格

| 协议 | 规格文档 | 说明 |
|------|---------|------|
| JointCommand | [protocol_joint_command.md](protocol_joint_command.md) | 关节控制指令（ControlModule → DCU/Sim） |
| JoyStickData | [protocol_joystick_data.md](protocol_joystick_data.md) | 手柄原始数据 |
| JoyStickState | [protocol_joystick_state.md](protocol_joystick_state.md) | 手柄连接状态 |

---

## 1. 系统概述

### 1.1 系统定位

本系统是 [AgiBot X1](https://www.zhiyuan-robot.com/qzproduct/169.html) 人形机器人的**推理与运动控制软件**。它负责：

1. 接收操作员指令（手柄/脚本），转化为机器人运动意图
2. 通过强化学习（RL）策略推理实时生成步态动作
3. 经传动转换后，驱动硬件执行器完成运动
4. 提供 MuJoCo 物理仿真环境用于离线验证

系统运行在 **AimRT** 中间件框架之上，采用模块化、消息驱动架构。

### 1.2 目标硬件

| 属性 | 描述 |
|------|------|
| 机器人平台 | AgiBot X1 高自由度模块化人形机器人 |
| 关节数量 | 29 个关节（腰部 3、双臂各 7、双腿各 6） |
| 执行器数量 | 31 个执行器（含并联传动） |
| 通信总线 | EtherCAT（DCU 驱动） |
| IMU | 集成于下肢 DCU（hip DCU） |
| 运行操作系统 | Ubuntu 22.04（推荐 RT 实时内核补丁） |

### 1.3 系统边界

```
┌─────────────────────────────────────────────────────┐
│         操作员 / 脚本 / 外部 ROS2 节点               │
└────────────────────┬────────────────────────────────┘
                     │ ROS2 / Local Channel
┌────────────────────▼────────────────────────────────┐
│            xyber_x1_infer 系统                       │
│  ┌─────────────┬──────────────┬──────────────────┐  │
│  │ JoyStick    │ Control      │ DCU Driver       │  │
│  │ Module      │ Module       │ Module           │  │
│  └─────────────┴──────────────┴──────────────────┘  │
│  ┌───────────────────────────────────────────────┐   │
│  │         AimRT 中间件框架                       │   │
│  └───────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────┘
                     │ EtherCAT
┌────────────────────▼────────────────────────────────┐
│          X1 硬件（DCU + 执行器 + IMU）               │
└─────────────────────────────────────────────────────┘
```

仿真模式下，`DCU Driver Module` 被替换为 `Sim Module`（MuJoCo），系统边界内闭环。

---

## 2. 架构总览

### 2.1 架构分层

系统采用**三层架构**：

| 层次 | 组成 | 职责 |
|------|------|------|
| **应用层** | ControlModule, JoyStickModule | 运动控制算法、用户指令处理 |
| **驱动层** | DcuDriverModule / SimModule | 硬件驱动/仿真环境 |
| **中间件层** | AimRT（Channel + RPC + Executor + Logger） | 模块间通信、调度、日志 |

### 2.2 模块组成

系统包含 **4 个功能模块**，编译为单一动态库 `libpkg1.so`，由 AimRT 运行时按配置加载：

| 模块 | 类名 | 运行模式 | 功能概述 |
|------|------|---------|---------|
| **ControlModule** | `ControlModule` | 真机 + 仿真 | RL 策略推理 + 状态机 + 关节指令生成 |
| **DcuDriverModule** | `DcuDriverModule` | 仅真机 | EtherCAT 通信、执行器驱动、传动转换 |
| **JoyStickModule** | `JoyStickModule` | 真机（可选） | 手柄输入解析、模式切换、速度指令发布 |
| **SimModule** | `SimModule` | 仅仿真 | MuJoCo 物理仿真、虚拟传感器数据发布 |

### 2.3 部署配置

| 配置文件 | 启用模块 | 场景 |
|---------|----------|------|
| `x1_cfg.yaml` | JoyStick + Control + DcuDriver | 真机部署 |
| `x1_cfg_sim.yaml` | Control + Sim（JoyStick 可选） | 仿真调试 |

---

## 3. 模块详细说明

### 3.1 ControlModule（RL 控制模块）

#### 3.1.1 职责

- 维护**机器人状态机**，管理操作模式转换
- 根据当前状态选择并执行对应的**控制器组合**
- 接收 IMU 数据和关节状态，输出关节控制指令
- 以 **1000 Hz**（可配置）的控制频率运行主循环

#### 3.1.2 状态机

状态机通过 YAML 配置驱动，支持以下状态：

| 状态名 | 触发 Topic | 控制器组合 | 说明 |
|--------|-----------|-----------|------|
| `idle` | `/idle_mode` | pd_idle | 空闲卸力 |
| `keep` | `/keep_mode` | pd_keep | 保持当前姿态 |
| `zero` | `/zero_mode` | pd_zero | 回归零位 |
| `stand` | `/stand_mode` | pd_zero → pd_stand | 站立姿态 |
| `walk_leg` | `/walk_mode` | pd_zero → pd_stand → rl_walk_leg | 下肢行走 |
| `walk_leg_arm` | `/walk_mode2` | pd_zero → pd_stand → rl_walk_leg_shoulder | 全身行走 |
| `*_&_plan` | `/plan_mode` | 对应基态 + pd_plan | 附加轨迹规划 |

每个状态定义了**前置状态列表**（`pre_states`），只有从合法前置状态才能转换到目标状态。

> **多控制器合并规则**：当一个状态包含多个控制器时，系统按列表顺序依次执行每个控制器的 `Update()` 并收集其输出。对于**同一关节**，列表中**靠后的控制器会覆盖前面控制器**的指令，不存在累加、混合或冲突检测逻辑。这是一种**有意的分层覆盖设计**：全身 PD 基础 → 局部 PD 覆盖 → RL 策略覆盖 → 轨迹规划覆盖。
>
> 详细分析参见 [joint_controller_conflict_analysis.md](../doc/artifacts/joint_controller_conflict_analysis.md)。

#### 3.1.3 控制器层级

```
ControllerBase（抽象基类）
├── PDController       ——  PD 位控（含过渡模式、保持模式、轨迹插值模式）
└── RLController       ——  强化学习策略推理控制器
```

**PDController** 提供三种工作模式：
- **过渡模式（trans mode）**：在 2 秒内平滑插值到目标关节角
- **保持模式（keep mode）**：锁定当前关节位置
- **轨迹规划模式（plan mode）**：按预定义插值轨迹执行运动序列（基于 Ruckig 库）

**RLController** 执行强化学习策略推理：
1. **状态估计**（UpdateStateEstimation）：融合 IMU + 关节状态
2. **观测量计算**（ComputeObservation）：构建策略网络输入向量
3. **动作推理**（ComputeActions）：调用 ONNX Runtime 推理 RL 策略模型
4. 输出经低通滤波和裁剪后的关节增量指令

#### 3.1.4 RL 推理参数

| 参数 | rl_walk_leg | rl_walk_leg_shoulder |
|------|-------------|----------------------|
| 控制关节数 | 12（双腿） | 14（双腿 + 双肩） |
| 观测维度 | 47 | 53 |
| 历史帧数 | 66 | 66 |
| 步态周期 | 0.7s | 1.0s |
| 策略模型 | `rl_walk_leg.onnx` | `rl_walk_leg_shoulder.onnx` |
| 动作缩放系数 | 0.5 | 0.5 |
| 推理降采样 | 每 10 个控制周期推理一次 | 每 10 个控制周期推理一次 |

#### 3.1.5 输入/输出

| 方向 | Topic | 消息类型 | 说明 |
|------|-------|---------|------|
| 订阅 | `/cmd_vel_limiter` | `geometry_msgs/Twist` | 限幅后的速度指令 |
| 订阅 | `/imu/data` | `sensor_msgs/Imu` | IMU 数据 |
| 订阅 | `/joint_states` | `sensor_msgs/JointState` | 关节状态反馈 |
| 订阅 | `/idle_mode` 等模式 Topic | `std_msgs/Float32` | 状态切换触发 |
| 发布 | `/joint_cmd` | `JointCommand`（自定义） | 关节控制指令 |

---

### 3.2 DcuDriverModule（DCU 驱动模块）

#### 3.2.1 职责

- 管理 EtherCAT 总线硬件通信
- 读取执行器位置/速度/力矩反馈和 IMU 数据
- 将关节空间指令通过**传动层**转换为执行器空间指令，下发至硬件
- 以 **1000 Hz**（可配置）发布传感器数据

#### 3.2.2 EtherCAT 网络拓扑

| DCU 名称 | EtherCAT ID | 通道数 | 挂载执行器 | IMU |
|----------|-------------|--------|-----------|-----|
| `body` | 1 | 3 | 上身（双臂 + 腰部左右） | 无 |
| `hip` | 2 | 3 | 下身（双腿 + 腰部偏航） | 有 |

EtherCAT 配置：
- 网卡接口：`enp2s0`
- 绑定 CPU 核心：#9
- 实时线程优先级：90
- DC 同步使能
- 刷新周期：1 ms（1 kHz）

#### 3.2.3 传动层

传动层负责**关节空间 ↔ 执行器空间**双向转换：

| 传动类型 | 应用关节 | 说明 |
|---------|---------|------|
| `SimpleTransmission` | 大部分关节 | 简单 1:1 传动（带方向） |
| `LeftAnkleParallelTransmission` | 左脚踝 pitch/roll | 并联连杆机构 |
| `RightAnkleParallelTransmission` | 右脚踝 pitch/roll | 并联连杆机构 |
| `LeftWristParallelTransmission` | 左腕 pitch/roll | 并联传动 |
| `RightWristParallelTransmission` | 右腕 pitch/roll | 并联传动 |
| `LumbarParallelTransmission` | 腰部 pitch/roll | 并联传动 |

#### 3.2.4 执行器类型

| 类型标识 | 应用部位 |
|---------|---------|
| `POWER_FLOW_R86` | 大力矩关节（髋、肩、膝、腰） |
| `POWER_FLOW_R52` | 中力矩关节（踝、肘、肩偏航） |
| `POWER_FLOW_L28` | 小力矩关节（腕部） |
| `OMNI_PICKER` | 夹爪 |

#### 3.2.5 输入/输出

| 方向 | Topic | 消息类型 | 说明 |
|------|-------|---------|------|
| 订阅 | `/joint_cmd` | `JointCommand` | 关节控制指令 |
| 发布 | `/imu/data` | `sensor_msgs/Imu` | IMU 数据 |
| 发布 | `/joint_states` | `sensor_msgs/JointState` | 关节状态 |
| 发布 | `/actuator_states` | `sensor_msgs/JointState` | 调试用：执行器状态（仅 `actuator_debug: true` 时） |
| 发布 | `/actuator_cmd` | `sensor_msgs/JointState` | 调试用：执行器指令（仅 `actuator_debug: true` 时） |

---

### 3.3 JoyStickModule（手柄控制模块）

#### 3.3.1 职责

- 读取物理游戏手柄（Joystick）的按键和摇杆输入
- 将按键事件映射为**模式切换指令**
- 将摇杆数据转换为**速度指令**（线速度 + 角速度）
- 对速度指令进行限幅处理（基于 qpOASES 二次规划库）
- 以 **20 Hz** 发布数据

#### 3.3.2 按键映射

| 按键 ID | 发布 Topic | 功能 |
|---------|-----------|------|
| 7 | `/idle_mode` | 切换到空闲 |
| 6 | `/keep_mode` | 切换到保持 |
| 1 | `/zero_mode` | 切换到零位 |
| 0 | `/stand_mode` | 切换到站立 |
| 2 | `/walk_mode` | 切换到下肢行走 |
| 3 | `/walk_mode2` | 切换到全身行走 |
| 5 | `/plan_mode` | 切换到轨迹规划 |
| 4（长按） | `/cmd_vel` | 发布速度指令 |

#### 3.3.3 速度限幅

| 轴 | 下界 | 上界 | 单位 |
|----|------|------|------|
| 线速度 X（前进） | -0.5 | 0.5 | m/s |
| 线速度 Y（横移） | -0.3 | 0.3 | m/s |
| 角速度 Z（转向） | -0.5 | 0.5 | rad/s |

#### 3.3.4 输入/输出

| 方向 | Topic | 消息类型 | 说明 |
|------|-------|---------|------|
| 发布 | `/idle_mode` 等 | `std_msgs/Float32` | 模式切换触发 |
| 发布 | `/cmd_vel` | `geometry_msgs/Twist` | 原始速度指令 |
| 发布 | `/cmd_vel_limiter` | `geometry_msgs/Twist` | 限幅后速度指令 |

---

### 3.4 SimModule（仿真模块）

#### 3.4.1 职责

- 加载 MuJoCo MJCF 机器人模型，运行物理仿真
- 接收关节指令，计算 PD 力矩并施加到仿真模型
- 从仿真中读取虚拟 IMU 和关节状态数据并发布
- 提供 GLFW 可视化渲染窗口（50 Hz 渲染频率）
- 替代 DcuDriverModule 实现闭环仿真

#### 3.4.2 输入/输出

| 方向 | Topic | 消息类型 | 说明 |
|------|-------|---------|------|
| 订阅 | `/joint_cmd` | `JointCommand` | 关节控制指令 |
| 订阅 | `/reset_sim` | 待定 | 仿真重置信号（已配置 Topic 名，但尚未实现具体逻辑） |
| 发布 | `/imu/data` | `sensor_msgs/Imu` | 虚拟 IMU 数据 |
| 发布 | `/joint_states` | `sensor_msgs/JointState` | 虚拟关节状态 |

---

## 4. 数据流

### 4.1 真机模式数据流

```
手柄/脚本                  ControlModule               DcuDriverModule
   │                           │                           │
   │  /cmd_vel, /xxx_mode      │                           │
   ├──────────────────────────►│                           │
   │                           │      /imu/data            │
   │                           │◄──────────────────────────┤
   │                           │    /joint_states           │
   │                           │◄──────────────────────────┤
   │                           │                           │
   │                           │── RL推理/PD计算 ──►       │
   │                           │                           │
   │                           │      /joint_cmd           │
   │                           ├──────────────────────────►│
   │                           │                    传动转换 │
   │                           │                  EtherCAT │
   │                           │                      ▼    │
   │                           │                   硬件执行 │
```

### 4.2 仿真模式数据流

```
手柄/脚本                  ControlModule               SimModule
   │                           │                           │
   │  /cmd_vel, /xxx_mode      │                           │
   ├──────────────────────────►│                           │
   │                           │      /imu/data            │
   │                           │◄──────────────────────────┤
   │                           │    /joint_states           │
   │                           │◄──────────────────────────┤
   │                           │                           │
   │                           │── RL推理/PD计算 ──►       │
   │                           │                           │
   │                           │      /joint_cmd           │
   │                           ├──────────────────────────►│
   │                           │                MuJoCo仿真  │
   │                           │               GLFW可视化   │
```

---

## 5. 通信机制

### 5.1 AimRT 框架核心概念

#### 5.1.1 Module（模块）

Module 是一个**逻辑层面**的概念，代表一个逻辑上内聚的功能块。通常对应一个硬件抽象、一个独立算法或一项业务功能。Module 之间可以在逻辑层通过 Channel 和 RPC 两种抽象接口通信。框架给每个 Module 提供独立的句柄，用于访问配置、日志、执行器等运行时功能，并实现资源统计与管理。

本项目中的四个 Module：`ControlModule`、`DcuDriverModule`、`JoyStickModule`、`SimModule`。

#### 5.1.2 Node（节点）

Node 是一个**部署、运行层面**的概念，代表一个可以部署启动的进程，其中运行了一个 AimRT 框架的 Runtime 实例。一个 Node 中可能存在多个 Module。Node 在启动时通过配置文件（YAML）设置日志、插件、执行器等运行参数。

本项目使用 AimRT 提供的 `aimrt_main` 可执行程序作为 Node 入口，配置文件为 `x1_cfg.yaml` 或 `x1_cfg_sim.yaml`。

#### 5.1.3 Pkg（包）

Pkg 是 AimRT 框架运行 Module 的一种途径，代表一个**包含单个或多个 Module 的动态库**。Node 在运行时根据配置文件加载一个或多个 Pkg，导入其中的 Module 类。

Pkg 模式的优势：
- 编译业务 Module 时只需链接轻量的 AimRT 接口层，不需要链接 AimRT 运行时库
- 可以二进制发布 `.so`，独立性较好
- 不同 Pkg 理论上可使用不同版本编译器独立编译，不同 Pkg 里的 Module 也可使用相互冲突的第三方依赖

本项目将全部 4 个 Module 编译进单一 Pkg：`libpkg1.so`，同 Pkg 内通信走 Local 后端有零拷贝优化。

#### 5.1.4 Protocol（协议）

Protocol 代表 Module 之间通信的**数据格式**，描述字段信息以及序列化/反序列化方式，通常由 IDL（接口描述语言）定义后转换为各语言代码。

AimRT 官方支持两种 IDL：
- **Protobuf**：用于 AimRT 内部通信，本项目中 `my_proto`（生产）和 `example_proto`（示例）
- **ROS2 msg/srv**：本项目中 `JointCommand.msg`、`JoyStickData.msg`、`JoyStickState.msg`、`MyRosRpc.srv`

#### 5.1.5 Channel（数据通道）

Channel 是一种典型的**发布-订阅**通信拓扑，通过 Topic 标识单个数据通道，支持多对多结构。Module 可以向任意数量的 Topic 发布数据，同时订阅任意数量的 Topic。

Channel 由**接口层**和**后端**两部分解耦组成：
- 接口层定义抽象 API，表示逻辑层面的 Channel
- 后端负责实际数据传输（Local、ROS2 等）

本项目中所有 `/joint_cmd`、`/imu/data`、`/joint_states`、`/cmd_vel`、`/xxx_mode` 等消息均通过 Channel 传输。

#### 5.1.6 RPC（远程过程调用）

RPC 基于**请求-响应**模型，由 Client 和 Server 组成。Module 可创建 Client 句柄发起 RPC 请求，也可创建 Server 句柄提供服务。

RPC 同样由接口层和后端解耦组成，官方提供 http、ros2 等后端。本项目通过 `MyRosRpc.srv` 定义 ROS2 RPC 接口（`byte[] data` 请求，`int64 code` 响应）。

#### 5.1.7 Filter（过滤器）

Filter 是贴着接口层的**用户可自定义逻辑插接点**，用于增强 RPC 或 Channel 的能力。按位置分为框架侧 Filter 和用户侧 Filter，按功能分为 RPC Filter 和 Channel Filter。

Filter 在每次 RPC 或 Channel 调用时以"洋葱"结构触发，可在调用前后执行自定义动作（如计时、监控上报）。本项目当前未显式配置自定义 Filter。

#### 5.1.8 Executor（执行器）

Executor 是一个可以**运行任务的抽象概念**，可以是 Fiber、Thread 或 Thread Pool。提供两类接口：
- `Execute(task)`：立即投递任务
- `ExecuteAt(tp, task)` / `ExecuteAfter(dt, task)`：定时执行

AimRT 官方提供基于 Asio 的线程池、基于 TBB 的无锁线程池、基于时间轮的定时执行器等。本项目中 `rl_control_pub_thread`、`joy_stick_pub_thread`、`sim_render_thread` 均为 AimRT `simple_thread` 类型执行器（见 §5.4）。

#### 5.1.9 Plugin（插件）

Plugin 是可以向 AimRT 框架**注册各种自定义功能**的动态库，可被框架运行时加载。框架暴露大量插接点，包括：日志后端注册、Channel/RPC 后端注册、组件启动 hook 点、RPC/Channel 调用过滤器、执行器注册等。

本项目使用 `ros2_plugin` 插件，提供 ROS2 Channel 后端和 ROS2 RPC 后端，使系统能够与外部 ROS2 节点通信。

---

### 5.2 AimRT 中间件能力汇总

| 能力 | 说明 |
|------|------|
| **Channel（消息通道）** | 发布-订阅模式的消息传输 |
| **RPC** | 请求-响应模式的远程过程调用 |
| **Executor** | 线程管理和调度执行器 |
| **Logger** | 分级日志（Console + 滚动文件） |
| **Plugin** | 动态加载插件（如 ros2_plugin） |
| **Filter** | RPC/Channel 调用前后的自定义逻辑插接点 |

### 5.3 通信后端

| 后端 | 用途 |
|------|------|
| **Local** | 进程内通信（零拷贝优化） |
| **ROS2** | 与外部 ROS2 节点通信 |

进程内模块间通信优先使用 Local 后端；与外部节点交互使用 ROS2 后端。

### 5.4 线程模型

| 线程名称 | 创建方式 | 调度策略 | 用途 |
|---------|---------|---------|------|
| `rl_control_pub_thread` | AimRT simple_thread | 普通 | 控制模块主循环（1000 Hz） |
| `joy_stick_pub_thread` | AimRT simple_thread | 普通 | 手柄模块主循环（20 Hz） |
| `sim_render_thread` | AimRT simple_thread | 普通 | 仿真渲染（仅仿真模式，50 Hz） |
| ROS2 Executor | AimRT ros2_plugin | MultiThreaded（4线程） | ROS2 通信处理 |
| `publish_thread_` | `std::thread` | 普通 `SCHED_OTHER` | DCU 数据发布（1000 Hz），非实时 |
| EtherCAT IO Thread | `XyberController` 内部 | RT 优先级 90 + CPU 绑核 #9 | EtherCAT 帧收发 |
| AimRT 回调线程 | 框架管理 | 框架决定 | 执行 `JointCmdCallback` |

> DCU 驱动模块采用**双线程 + 共享内存**并发模型：`publish_thread_` 周期性从 EtherCAT 缓存读取传感器数据并发布，AimRT 回调线程接收关节指令并下发。两者通过 `rw_mtx_` 互斥锁保护传动层坐标变换的原子性。详见 [dcu_publish_thread_analysis.md](../doc/artifacts/dcu_publish_thread_analysis.md)。

### 5.5 实时性保障措施

| 措施 | 状态 | 说明 |
|------|------|------|
| RT 内核补丁 | ✅ 推荐 | Linux PREEMPT-RT 实时内核 |
| 线程优先级 | ✅ 已实现 | EtherCAT IO 线程 RT 优先级 90 |
| CPU 核心绑定 | ✅ 已实现 | `pthread_setaffinity_np` 绑定 CPU #9 |
| EtherCAT DC 同步 | ✅ 已实现 | PI 控制器补偿主从站时钟漂移 |
| 原子变量 | ✅ 已实现 | `std::atomic_bool` 无锁线程标志 |
| `sleep_until` 绝对定时 | ✅ 已实现 | 避免 `sleep_for` 累积漂移 |
| `mlockall` 内存锁定 | ❌ 未实现 | **最关键的遗漏**，可能引起毫秒级缺页抖动 |
| 线程栈预故障 | ❌ 未实现 | 运行时可能触发缺页中断 |
| 无锁队列 | ❌ 未实现 | 关键路径仍可能使用 mutex |

> 详细分析参见 [realtime_measures_analysis.md](../doc/artifacts/realtime_measures_analysis.md)。

---

## 6. 协议定义

### 6.1 自定义 ROS2 消息

#### `JointCommand.msg`

```
std_msgs/Header header
string[]  name        # 关节名称列表
float64[] position    # 目标位置 [rad]
float64[] velocity    # 目标速度 [rad/s]
float64[] effort      # 目标力矩 [N·m]
float64[] stiffness   # PD 刚度 Kp
float64[] damping     # PD 阻尼 Kd
```

#### `JoyStickData.msg`

```
string name           # 手柄名称标识
int32  x              # X 轴数据
int32  y              # Y 轴数据
int32  z              # Z 轴数据
```

#### `JoyStickState.msg`

```
bool   is_alive       # 手柄连接状态
string detail         # 状态详情
```

### 6.2 ROS2 服务

#### `MyRosRpc.srv`

```
byte[] data           # 请求数据
---
int64  code           # 响应码
```

### 6.3 Protobuf

项目包含 `my_proto` 和 `example_proto`，用于 AimRT 内部 Protobuf 序列化通信。`my_proto` 在生产环境中使用，`example_proto` 为示例模板。

---

## 7. 关节拓扑

### 7.1 关节列表（29 个关节）

| 部位 | 关节名 | 数量 |
|------|--------|------|
| **腰部** | lumbar_yaw, lumbar_roll, lumbar_pitch | 3 |
| **左臂** | shoulder_pitch/roll/yaw, elbow_pitch/yaw, wrist_pitch/roll | 7 |
| **右臂** | shoulder_pitch/roll/yaw, elbow_pitch/yaw, wrist_pitch/roll | 7 |
| **左腿** | hip_pitch/roll/yaw, knee_pitch, ankle_pitch/roll | 6 |
| **右腿** | hip_pitch/roll/yaw, knee_pitch, ankle_pitch/roll | 6 |

> **注**：夹爪关节（left_claw_joint / right_claw_joint）在 DCU 配置中存在，但不参与控制模块的 RL 推理。

---

## 8. 构建与部署

### 8.1 构建工具链

| 项目 | 版本要求 |
|------|---------|
| OS | Ubuntu 22.04 |
| 编译器 | GCC-13 |
| CMake | ≥ 3.26 |
| C++ 标准 | C++20 |
| 中间件 | AimRT（通过 CMake 自动拉取） |

### 8.2 外部依赖

| 依赖 | 用途 | 版本 |
|------|------|------|
| **AimRT** | 中间件框架 | 通过 `GetAimRT.cmake` 拉取 |
| **ONNX Runtime** | RL 策略模型推理 | v1.19.2（项目内嵌）/ v1.22.2（系统安装） |
| **ROS2 Humble** | 通信后端 | Humble |
| **MuJoCo** | 物理仿真引擎 | v3.1.3（mjVERSION_HEADER 313） |
| **Eigen3** | 线性代数计算 | 系统包 |
| **yaml-cpp** | 配置文件解析 | 随 AimRT 安装 |
| **Ruckig** | 平滑轨迹生成 | 项目内嵌 |
| **qpOASES** | 二次规划（速度限幅） | v3.2（项目内嵌） |
| **SOEM** | EtherCAT 主站开源库 | 项目内嵌 |
| **GLFW** | 仿真可视化窗口 | 系统包 |
| **GTest** | 单元测试 | 通过 CMake 可选拉取 |

### 8.3 构建产物

```
build/
├── libpkg1.so              # 模块动态库（包含全部 4 个模块）
├── aimrt::runtime::main    # AimRT 运行时可执行文件
├── cfg/                    # 运行时配置文件
│   ├── control_module/
│   ├── dcu_driver_module/
│   ├── joy_stick_module/
│   └── sim_module/
├── run.sh                  # 真机启动脚本
└── run_sim.sh              # 仿真启动脚本
```

---

## 9. 运行时序

### 9.1 典型启动序列（仿真模式行走）

```
1. AimRT Runtime 启动 → 加载 libpkg1.so
2. 各模块 Initialize() → 解析配置、注册 Channel/RPC
3. 各模块 Start() → 启动主循环线程
4. 初始状态 = idle
5. 触发 /zero_mode  → 状态切换至 zero，PD 控制回归零位
6. 触发 /stand_mode → 状态切换至 stand，PD 控制站立
7. 等待 3-5 秒稳定
8. 触发 /walk_mode  → 状态切换至 walk_leg
9. 控制循环（1000 Hz）：
   a. 接收 IMU + JointState
   b. 每 10 个周期执行一次 RL 推理
   c. PD 控制器平滑输出
   d. 发布 JointCommand
10. SimModule 接收 JointCommand → MuJoCo 仿真 → 发布传感器数据
```

### 9.2 控制循环时序

```
1 ms 控制周期
├── 读取最新 IMU 数据
├── 读取最新关节状态
├── 获取当前活跃控制器列表
├── 对每个控制器执行 Update()
│   └── [每 10ms] RLController: ONNX 推理
├── 合并各控制器输出的 JointCommand
└── 发布 /joint_cmd
```

---

## 10. 验证记录

> 以下事项已于 v1.1 版本中全部确认并合入正文。

| 编号 | 事项 | 结论 |
|------|------|------|
| V-01 | MuJoCo 版本 | **v3.1.3**（mjVERSION_HEADER 313），已更新至 §8.2 |
| V-02 | 执行器调试 Topic | `/actuator_states` 和 `/actuator_cmd`，消息类型 `sensor_msgs/JointState`，已更新至 §3.2.5 |
| V-03 | Protobuf 使用场景 | `my_proto` 在生产中使用，`example_proto` 为示例模板，已更新至 §6.3 |
| V-04 | DCU Publish Thread | 独立 `std::thread`，普通调度，双线程 + 共享内存模型，已更新至 §5.3 |
| V-05 | `/reset_sim` 消息类型 | 已配置 Topic 名但尚未实现具体逻辑，保留待定标注，已更新至 §3.4.2 |
| V-06 | 控制器合并策略 | **列表靠后覆盖靠前**，无累加/混合/冲突检测，分层覆盖设计，已更新至 §3.1.2 |
| V-07 | 实时性措施 | 已实现 CPU 绑核、DC 同步、原子变量、绝对定时；缺少 `mlockall` 等，已新增 §5.4 |
| V-08 | 关节偏移量 | 执行器零位已与 URDF 完全一致，无需补偿（`joint_offset` 全 0.0 为正确值） |

---

## 附录

### A. 架构图

参见 [sw_arch.png](../doc/sw_arch.png)

### B. 参考链接

- [AimRT 官方文档](https://docs.aimrt.org/)
- [AimRT 配置指南](https://docs.aimrt.org/tutorials/index.html#id3)
- [ROS2 Humble 安装](https://docs.ros.org/en/humble/Installation/Ubuntu-Install-Debians.html)
- [AgiBot X1 产品页](https://www.zhiyuan-robot.com/qzproduct/169.html)
