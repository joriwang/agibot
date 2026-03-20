# ControlModule 模块规格说明

> **文档版本**: v2.0
> **生成日期**: 2026-03-20
> **最后更新**: 2026-03-20（基于源码全量审阅，补充 Internal Logic、Error Handling、算法描述）
> **适用系统**: AgiBot X1 推理与控制软件（xyber_x1_infer）
> **命名空间**: `xyber_x1_infer::rl_control_module`
> **源码路径**: `src/module/control_module/`
> **配置路径**: `src/module/control_module/cfg/`

---

## 1. 模块定位

ControlModule 是系统的**核心控制模块**，负责：

1. 维护机器人**操作模式状态机**，接收外部触发切换控制策略
2. 按当前状态组合并执行**控制器链**（PDController / RLController）
3. 融合 IMU 和关节状态数据，以 **1000 Hz** 周期发布关节控制指令
4. 在真机和仿真两种部署模式下接口行为一致（仅 Topic 名可配置不同）

该模块作为 AimRT Pkg（`libpkg1.so`）的一部分加载，继承自 `aimrt::ModuleBase`。

---

## 2. 生命周期接口

| 方法 | 触发时机 | 职责 |
|------|---------|------|
| `Initialize(CoreRef)` | AimRT 启动阶段 | 解析 YAML 配置、初始化状态机和控制器、注册 Channel 订阅/发布 |
| `Start()` | 所有模块 Initialize 完成后 | 通过 `executor_.Execute()` 投递 `MainLoop()` 到 `rl_control_pub_thread` |
| `Shutdown()` | 进程退出信号 | 设置 `run_flag_.store(false)`，主循环在当前周期末自然退出 |

---

## 3. Channel 接口契约

### 3.1 订阅（Subscribe）

| Topic（默认） | 消息类型 | 频率 | 说明 |
|--------------|---------|------|------|
| `/cmd_vel_limiter` | `geometry_msgs/Twist` | 20 Hz（JoyStick 发布） | 限幅后的速度指令；仅转发给**当前活跃控制器** |
| `/imu/data` | `sensor_msgs/Imu` | 1000 Hz | 基座姿态四元数 + 角速度；仅转发给**当前活跃控制器** |
| `/joint_states` | `sensor_msgs/JointState` | 1000 Hz | 29 个关节的 position/velocity/effort；转发给**全部控制器**（含非活跃） |
| `/idle_mode` | `std_msgs/Float32` | 事件触发 | 切换到 `idle` |
| `/keep_mode` | `std_msgs/Float32` | 事件触发 | 切换到 `keep` |
| `/zero_mode` | `std_msgs/Float32` | 事件触发 | 切换到 `zero` |
| `/stand_mode` | `std_msgs/Float32` | 事件触发 | 切换到 `stand` |
| `/walk_mode` | `std_msgs/Float32` | 事件触发 | 切换到 `walk_leg` |
| `/walk_mode2` | `std_msgs/Float32` | 事件触发 | 切换到 `walk_leg_arm` |
| `/plan_mode` | `std_msgs/Float32` | 事件触发 | 切换到当前基态对应的 `*_&_plan` |

> **重要区别**：
> - Joint state 回调将数据写入**所有**控制器（`controller_map_` 全量遍历），确保每个控制器内部状态始终是最新的，即使未激活也保持同步。
> - Cmd 和 IMU 回调仅写入**当前活跃控制器**（`state_machine_.GetCurrentControllerNames()` 返回列表）。

### 3.2 发布（Publish）

| Topic（默认） | 消息类型 | 频率 | 说明 |
|--------------|---------|------|------|
| `/joint_cmd` | `my_ros2_proto/JointCommand` | 1000 Hz | 合并后的全关节控制指令 |

> 真机和仿真配置下均发布 `/joint_cmd`（旧版文档中仿真发布 `/effort_controller/commands` 已废弃）。

---

## 4. 状态机规格

### 4.1 状态定义

状态机从 YAML `robot_states` 节点加载，**YAML 中第一个状态为初始状态**（当前为 `idle`）。

| 状态名 | 触发 Topic | 合法前置状态 | 激活控制器链 |
|--------|-----------|------------|------------|
| `idle` | `/idle_mode` | keep, stand_&_plan, keep_&_plan, walk_leg_&_plan, zero, stand, walk_leg, walk_leg_arm | `[pd_idle]` |
| `keep` | `/keep_mode` | idle, stand_&_plan, keep_&_plan, wa_&_plan, zero, stand, walk_leg, walk_leg_arm | `[pd_keep]` |
| `zero` | `/zero_mode` | idle, keep, stand, stand_&_plan | `[pd_zero]` |
| `stand` | `/stand_mode` | zero, stand_&_plan, keep_&_plan, walk_leg_&_plan, walk_leg, walk_leg_arm | `[pd_zero, pd_stand]` |
| `walk_leg` | `/walk_mode` | stand_&_plan, walk_leg_&_plan, stand, walk_leg_arm | `[pd_zero, pd_stand, rl_walk_leg]` |
| `walk_leg_arm` | `/walk_mode2` | stand_&_plan, walk_leg_&_plan, stand, walk_leg | `[pd_zero, pd_stand, rl_walk_leg_shoulder]` |
| `stand_&_plan` | `/plan_mode` | stand, stand_&_plan | `[pd_zero, pd_stand, pd_plan]` |
| `keep_&_plan` | `/plan_mode` | keep, keep_&_plan | `[pd_keep, pd_plan]` |
| `walk_leg_&_plan` | `/plan_mode` | walk_leg, walk_leg_&_plan | `[pd_zero, pd_stand, rl_walk_leg, pd_plan]` |

### 4.2 状态转换规则

1. 收到触发 Topic 消息时，**节流器**（Throttler）检查距上次状态转换是否已过 **1000 ms**；未到则忽略该消息
2. 通过节流检查后，检查当前状态是否在目标状态的 `pre_states` 列表中
3. 若合法：更新 `current_state_name_`，通过 `shared_mutex` 原子替换 `controllers_` 列表，然后对**新状态的所有控制器**依次调用 `RestartController()`
4. 若非法（前置状态不满足）：静默忽略，不记录日志

> **节流器**（`Throttler`）的作用：防止 1 秒内重复触发状态切换，避免快速连击导致控制器频繁重启。

### 4.3 控制器合并规则

主循环每周期按控制器链顺序依次调用各控制器的 `Update()` 和 `GetJointCmdData()`，然后**按靠后覆盖靠前**的规则写入全局指令数组：

```
for each controller_name in active_controller_list (顺序):
    controller.Update()
    tmp_cmd = controller.GetJointCmdData()
    for each joint in tmp_cmd.name:
        index = joint_cmd_index_map_[joint]
        cmd_msg[index] = tmp_cmd[joint]   // 覆盖，不累加
```

最终 `cmd_msg` 中未被任何控制器覆盖的关节槽位保留上一帧的值（`cmd_msg` 在循环启动前只初始化一次）。

### 4.4 关节偏移透明补偿

```
订阅回调（joint_state）:
    for joint in joint_offset_map_:
        msg.position[joint] -= offset[joint]   // 传给控制器的是补偿后的"理想"角度

主循环（发布）:
    for joint in controller_output:
        cmd_msg.position[joint] = controller_pos + offset[joint]  // 加回偏移发给硬件
```

偏移量对控制器完全透明，控制器始终在"URDF 理想空间"中计算。

---

## 5. 内部逻辑（Internal Logic）

### 5.1 Initialize() 流程

```
Initialize(core):
    1. 保存 core 句柄，设置全局 Logger
    2. 加载 YAML 配置文件：
       - 读取 freq_、use_sim_handles_
       - 初始化 last_trigger_time_ = now()
    3. 初始化状态机（StateMachine::Init）：
       - 遍历 robot_states，构建 trigger_topic → [State] 映射
       - 初始状态 = YAML 第一个状态（idle）
    4. 注册模式切换 Topic 订阅（去重，同一 topic 只注册一次）：
       - 回调闭包：Throttler(1s) + StateMachine::OnEvent + RestartController
    5. 按控制器名前缀创建控制器实例并调用 Init：
       - 前缀 "rl_" → RLController（含 LoadModel）
       - 前缀 "pd_" → PDController
       - 其他前缀 → AIMRT_ERROR 日志，跳过创建
    6. 初始化 joint_state_index_map_（全部置 -1，首次 JointState 消息到来时填充）
    7. 初始化 joint_cmd_index_map_（joint_list 顺序 → 0..N-1）
    8. 加载 joint_offset_map_
    9. 注册 cmd_vel、imu、joint_state 订阅回调
    10. 获取 rl_control_pub_thread 执行器（不存在则抛异常）
    11. 注册 JointCommand 发布类型
```

### 5.2 MainLoop() 流程

```
MainLoop():
    period = 1,000,000,000 ns / freq_   // 1ms @ 1000Hz
    next_time = now()
    预分配 cmd_msg（全关节槽位，初始全 0）

    while run_flag_:
        next_time += period
        sleep_until(next_time)           // 绝对时间定时，防累积漂移

        controller_names = state_machine_.GetCurrentControllerNames()
        for name in controller_names:
            controller_map_[name]->Update()
            tmp_cmd = controller_map_[name]->GetJointCmdData()
            for ii in tmp_cmd.name:
                index = joint_cmd_index_map_[tmp_cmd.name[ii]]
                cmd_msg.position[index] = tmp_cmd.position[ii] + joint_offset_map_[name]
                cmd_msg.stiffness[index] = tmp_cmd.stiffness[ii]
                cmd_msg.damping[index]   = tmp_cmd.damping[ii]
                // velocity, effort 同样覆盖

        Publish(joint_cmd_pub_, cmd_msg)

    // 异常退出：catch → AIMRT_ERROR，返回 false
```

### 5.3 JointState 订阅回调流程

```
on_joint_state(msg):
    // 首次消息：建立名称→索引映射（只执行一次，以 index == -1 为标志）
    if joint_state_index_map_.begin()->second == -1:
        for i, name in msg.name:
            joint_state_index_map_[name] = i

    // 创建带偏移补偿的副本
    temp_msg = *msg
    for joint, offset in joint_offset_map_:
        temp_msg.position[joint_state_index_map_[joint]] -= offset

    // 转发给所有控制器（含非活跃）
    for controller in controller_map_:
        controller.SetJointStateData(temp_msg, joint_state_index_map_)
```

---

## 6. 控制器规格

### 6.1 公共基类：ControllerBase

```
ControllerBase（抽象基类）
├── Init(YAML::Node)         — 从配置初始化 joint_list, init_state, stiffness, damping
├── RestartController()      — 重置控制器内部状态（纯虚）
├── SetCmdData(Twist)        — unique_lock(joy_mutex_) 后写入 joy_data_
├── SetImuData(Imu)          — unique_lock(imu_mutex_) 后写入 imu_data_
├── SetJointStateData(...)   — unique_lock(joint_state_mutex_) 后按 joint_state_index_map_
│                              逐关节拷贝 position/velocity/effort（at() 访问，键不存在抛异常）
├── GetJointList()           — 返回 joint_names_
├── Update()                 — 执行一步控制计算（纯虚）
└── GetJointCmdData()        — 返回本周期关节指令（纯虚）
```

### 6.2 PDController

#### 6.2.1 初始化（Init）

- 从 YAML 加载 `joint_list`、`init_state`、`stiffness`、`damping`
- 检查 `is_keep_controller` 字段（可选，默认 false）
- 检查 `plan_conf` 字段：若存在，`is_plan_controller_ = true`，加载 `trajectory_interpolator` 矩阵，并在矩阵**首尾各插入一个空占位行** `{0.0}`（`RestartController` 时会替换为实际起点）

#### 6.2.2 RestartController()

```
RestartController():
    lock(joint_state_mutex_)
    start_joint_angles_ = joint_state_data_.position  // 快照当前关节角
    trans_mode_percent_ = 0.0

    if is_plan_controller_:
        temp = [1.0] + start_joint_angles_        // 首行：1s 过渡 + 当前位置
        to_interpolate_data_[0] = temp
        to_interpolate_data_.back() = temp         // 末行：回到当前位置
        trajectory_generator_.Init(to_interpolate_data_)
        // Interpolator::Init 用 Ruckig 预计算全部插值点
```

#### 6.2.3 Update()

| 模式 | 行为 |
|------|------|
| keep 模式 | 立即返回，不更新任何状态 |
| plan 模式 | `trajectory_generator_.GetNextPoint(start_joint_angles_)`：从预计算序列取下一帧，写入 `start_joint_angles_`；轨迹结束后 `GetNextPoint` 返回 false，`start_joint_angles_` 保持末态不变 |
| 过渡模式（默认） | `trans_mode_percent_ += 1.0 / (2.0s × 1000Hz) = 0.0005`；上限 1.0 |

#### 6.2.4 GetJointCmdData()

```
for ii in joint_names_:
    if keep_mode:
        pos_des = start_joint_angles_[ii]           // 锁定位置（RestartController 时采样）
    elif plan_mode:
        pos_des = start_joint_angles_[ii]           // Interpolator 已更新此值
    else:  // 过渡模式
        pos_des = start[ii] * (1 - pct) + init_state[ii] * pct

    joint_cmd.position[ii] = pos_des
    joint_cmd.stiffness[ii] = Kp[ii]
    joint_cmd.damping[ii]   = Kd[ii]
    joint_cmd.velocity[ii]  = 0.0
    joint_cmd.effort[ii]    = 0.0
```

> `trans_mode_duration_s_ = 2.0` 是硬编码常量，不可通过 YAML 配置。过渡时间固定 2 秒。

### 6.3 RLController

#### 6.3.1 初始化（Init）

```
Init(cfg_node):
    加载 joint_list, init_state, stiffness, damping
    加载 walk_step_conf, obs_scales, onnx_conf, lpf_conf
    LoadModel()           // 加载 ONNX 模型，提取 input/output 名称和 shape
    初始化向量：
        actions_[actions_size]
        observations_[observations_size × num_hist]
        last_actions_[actions_size] = 0
        propri_history_buffer_[observations_size × num_hist]
        loop_count_ = 0
        为每个关节创建 digital_lp_filter(wc=100, ts=0.001)
        propri_.joint_pos/vel.resize(actions_size)
```

#### 6.3.2 RestartController()

```
RestartController():
    is_first_frame_ = true   // 下次 ComputeObservation 时触发首帧初始化
    // 注意：loop_count_ 不重置，actions_ 不清零，LPF 状态不清零
    // 首帧初始化会在 ComputeObservation 中处理 LPF 状态
```

#### 6.3.3 Update()

```
Update():
    UpdateStateEstimation()
    if loop_count_ % decimation == 0:   // 每 10 帧推理一次
        ComputeObservation()
        ComputeActions()
    loop_count_++
```

#### 6.3.4 UpdateStateEstimation()

```
UpdateStateEstimation():
    shared_lock(joint_state_mutex_)
    for ii in [0, actions_size):
        propri_.joint_pos[ii] = joint_state_data_.position[ii]  // 按索引顺序，非按名称
        propri_.joint_vel[ii] = joint_state_data_.velocity[ii]

    shared_lock(imu_mutex_)
    propri_.base_ang_vel = [imu.angular_velocity.x, y, z]
    quat = [imu.orientation.x, y, z, w]
    R = GetRotationMatrixFromZyxEulerAngles(QuatToZyx(quat))
    propri_.projected_gravity = R⁻¹ * [0, 0, -1]   // 重力在基座坐标系的投影
    propri_.base_euler_xyz = QuatToXyz(quat)         // RPY 欧拉角（X-Y-Z 顺序）
```

#### 6.3.5 ComputeObservation() — 观测向量精确布局

观测向量共 `observations_size` 维（`rl_walk_leg`=47，`rl_walk_leg_shoulder`=53），每次推理使用最近 `num_hist=66` 帧拼接的历史 buffer 作为 ONNX 输入。

**单帧观测布局**（以 `rl_walk_leg`，`actions_size=12` 为例）：

| 索引 | 内容 | 缩放 | 维度 |
|------|------|------|------|
| 0 | `sin(2π × phase)` | — | 1 |
| 1 | `cos(2π × phase)` | — | 1 |
| 2 | `joy_data_.linear.x` | `× obs_scales_.lin_vel` | 1 |
| 3 | `joy_data_.linear.y` | `× obs_scales_.lin_vel` | 1 |
| 4 | `joy_data_.angular.z` | **无缩放** | 1 |
| 5..16 | `propri_.joint_pos - joint_conf_.init_state` | `× obs_scales_.dof_pos` | 12 |
| 17..28 | `propri_.joint_vel` | `× obs_scales_.dof_vel` | 12 |
| 29..40 | `last_actions_` | — | 12 |
| 41..43 | `propri_.base_ang_vel` | `× obs_scales_.ang_vel` | 3 |
| 44..46 | `propri_.base_euler_xyz` | `× obs_scales_.quat` | 3 |

> **注意**：`angular.z`（索引 4）未乘以 `obs_scales_.ang_vel`，与其他角速度项处理不一致。这是源码中的现有行为，非规格要求。

**步态相位（phase）计算**：

```
phase_raw = wall_clock_time_seconds / cycle_time   // 连续增长的相位计数

if sw_mode AND ||(vx, vy, ωz)|| <= cmd_threshold:
    phase = 0       // 静止时冻结相位（无原地踏步）
else:
    phase = phase_raw

observation[0] = sin(2π × phase)
observation[1] = cos(2π × phase)
```

**首帧初始化**（`is_first_frame_ == true` 时，在 `ComputeObservation` 内执行）：

```
首帧处理：
    for joint ii:
        if joint 非并联（不在 paralle_list）:
            low_pass_filters_[ii].init(current_joint_pos[ii])  // LPF 初始化为当前位置
        else（并联/踝关节）:
            low_pass_filters_[ii].init(0)                       // LPF 初始化为 0 力矩

    将观测向量中 last_actions_ 字段强制置零（即使 last_actions_ 非零）
    将当前帧复制填充全部 66 个历史槽（不等历史积累）
    is_first_frame_ = false
```

**历史 buffer 更新**（首帧后每次调用）：

```
propri_history_buffer_.head(total - obs_size) = propri_history_buffer_.tail(total - obs_size)
propri_history_buffer_.tail(obs_size) = current_obs    // 新帧追加到末尾
observations_clip_and_copy()                            // 限幅到 ±observations_clip
```

#### 6.3.6 ComputeActions()

```
ComputeActions():
    input_tensor = observations_  // shape: [1, observations_size × num_hist]
    output = onnx_session.Run(input_tensor)
    actions_ = output[0][0..actions_size-1]
    actions_ = clip(actions_, -actions_clip, +actions_clip)
    // actions_ 在下一次 GetJointCmdData() 调用前保持不变
```

#### 6.3.7 GetJointCmdData() — 双模式输出

**串联关节**（非 `paralle_list`，即除踝关节外的所有 RL 关节）：

```
pos_des = actions_[ii] × action_scale + init_state[ii]
low_pass_filters_[ii].input(pos_des)
pos_des_lp = low_pass_filters_[ii].output()

joint_cmd.position[ii]  = pos_des_lp
joint_cmd.stiffness[ii] = Kp[ii]
joint_cmd.damping[ii]   = Kd[ii]
joint_cmd.effort[ii]    = 0.0     // 位置控制模式
```

**并联关节**（踝关节：`*_ankle_pitch`、`*_ankle_roll`）：

```
pos_des = actions_[ii] × action_scale + init_state[ii]
tau_des = Kp[ii] × (pos_des - propri_.joint_pos[ii]) + Kd[ii] × (0 - propri_.joint_vel[ii])
low_pass_filters_[ii].input(tau_des)
tau_des_lp = low_pass_filters_[ii].output()

joint_cmd.position[ii]  = 0.0
joint_cmd.stiffness[ii] = 0.0
joint_cmd.damping[ii]   = 0.0
joint_cmd.effort[ii]    = tau_des_lp   // 力矩控制模式
```

> 并联踝关节使用**力矩前馈控制**：RLController 自行计算 PD 力矩，并施加低通滤波，以 `effort` 字段下发给 DCU，DCU 直接透传力矩指令。

执行完毕后：`last_actions_[ii] = actions_[ii]`（下帧观测向量使用）。

---

## 7. 关键子系统

### 7.1 数字低通滤波器（digital_lp_filter）

二阶 Butterworth 低通滤波器，双线性变换（Tustin 法）离散化。

**差分方程**（已预计算系数）：

```
den = 2500·ts²·ωc² + 7071·ts·ωc + 10000

b0 = b1/2 = b2 = 2500·ts²·ωc² / den        // 分子系数（对称）
a1 = -(5000·ts²·ωc² - 20000) / den          // 一阶反馈系数
a2 = -(2500·ts²·ωc² - 7071·ts·ωc + 10000) / den  // 二阶反馈系数

y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] + a1·y[n-1] + a2·y[n-2]
```

**初始化**：`init(v)` 将 x[-1]=x[-2]=y[-1]=y[-2] 全部设为 `v`，避免启动瞬态。

参数：`wc=100 rad/s`，`ts=0.001 s` → 截止频率约 15.9 Hz。

### 7.2 轨迹插值器（Interpolator）

**输入格式**：`[[t0, j1_0, j2_0, j3_0], [t1, j1_1, ...], ...]`

第一列为段持续时间（秒），其余列为目标关节角。

**实现**：始终使用 **Ruckig** 生成平滑轨迹（`linearInterpolate` 已注释）。

```
Ruckig 约束（硬编码）：
    max_velocity     = 3.0   rad/s（每自由度）
    max_acceleration = 20.0  rad/s²
    max_jerk         = 20.0  rad/s³
    minimum_duration = t_segment（段持续时间）
    起点/终点速度 = 0，加速度 = 0
```

> 当前 Ruckig 调用硬编码了 3-DOF 的 `current_velocity`/`current_acceleration` 初始化（`{0.0, 0.0, 0.0}`），仅与 `pd_plan`（3 关节）匹配。若未来 `plan_conf` 控制不同数量关节，此处需要修改。

**使用方式**：`RestartController()` 时一次性预计算所有插值点存入 `data_`，`Update()` 每帧调用 `GetNextPoint()` 取下一帧，轨迹结束后返回 `false`，控制器保持末态。

### 7.3 状态机（StateMachine）

```
Init(YAML):
    trigger_topic → [State1, State2, ...] 多对多映射
    初始状态 = YAML 首条目

OnEvent(trigger_topic):
    candidates = trigger_state_map_[trigger_topic]
    for state in candidates:
        if current_state in state.pre_states:
            current_state = state
            unique_lock: controllers_ = state.controllers
            return true
    return false   // 无合法转换，静默忽略
```

---

## 8. 错误处理（Error Handling）

| 场景 | 处理方式 |
|------|---------|
| YAML 配置文件路径为空 | `Initialize()` 跳过配置解析，以默认值（空状态机）返回 true |
| YAML 解析异常（格式错误、字段缺失） | `catch(std::exception)` → `AIMRT_ERROR` 日志，`Initialize()` 返回 false |
| 未知控制器前缀（非 `rl_`/`pd_`） | `AIMRT_ERROR` 日志，跳过该控制器；状态机中引用此控制器将在运行时崩溃 |
| Channel 订阅失败 | `AIMRT_CHECK_ERROR_THROW` → 抛出异常，`Initialize()` 捕获返回 false |
| 执行器 `rl_control_pub_thread` 不存在 | `AIMRT_CHECK_ERROR_THROW` → 抛出异常，`Initialize()` 返回 false |
| ONNX 模型文件不存在/格式错误 | `LoadModel()` 抛出 ONNX 异常，`Initialize()` 捕获返回 false |
| `SetJointStateData` 中关节名不在 `joint_state_index_map_` | `std::unordered_map::at()` 抛出 `std::out_of_range`；若发生在回调线程，AimRT 框架可能崩溃 |
| 状态切换节流（1s 内重复触发） | `Throttler` 返回 false，回调直接返回，无日志 |
| 非法状态转换（前置状态不符） | `StateMachine::OnEvent` 返回 false，回调直接返回，无日志 |
| `MainLoop` 内部异常 | `catch(std::exception)` → `AIMRT_ERROR` 日志，MainLoop 返回 false，`run_flag_` 不复位（模块停止但不 abort） |
| `Interpolator` 输入数据为空 | `Init()` 抛出 `std::runtime_error`；由 `RestartController()` 的调用链传播 |
| 关节状态首帧未到达时 `Update()` 被调用 | 控制器使用 `Init()` 时分配的全零初始关节状态（非预期，但不崩溃） |

---

## 9. 配置规格

### 9.1 顶层字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `control_frequecy` | int | 主循环频率（Hz），通常 1000 |
| `use_sim_handles` | bool | true = 仿真模式 |
| `sub_joy_vel_name` | string | 速度指令 Topic 名 |
| `sub_imu_data_name` | string | IMU Topic 名 |
| `sub_joint_state_name` | string | 关节状态 Topic 名 |
| `pub_joint_cmd_name` | string | 关节指令发布 Topic 名 |

### 9.2 robot_states 字段

```yaml
<state_name>:
  trigger_topic: <string>
  pre_states: [<string>, ...]
  controllers: [<string>, ...]   # 有序，靠后覆盖靠前
```

### 9.3 joint_list / joint_offset

```yaml
joint_list:               # 29 关节，顺序决定 joint_cmd 数组索引
  - lumbar_yaw_joint
  - ...

joint_offset:
  <joint_name>: <double>  # 真机装配偏差 [rad]，仿真全 0.0
```

### 9.4 PDController 配置

```yaml
<name>:
  joint_list: [...]
  init_state: [...]           # 目标角 [rad]
  stiffness: [...]            # Kp
  damping: [...]              # Kd
  is_keep_controller: bool    # 可选，默认 false
  plan_conf:                  # 可选；存在时激活 plan 模式
    trajectory_interpolator:
      - [trans_time, j1, j2, ...]   # 每段：持续时间(s) + 各关节目标角
```

### 9.5 RLController 配置

```yaml
<name>:
  joint_list: [...]
  init_state: [...]
  stiffness: [...]
  damping: [...]
  walk_step_conf:
    action_scale: 0.5        # 动作缩放系数
    decimation: 10           # 推理降采样（每 N 帧推理一次）
    cycle_time: 0.7          # 步态周期 [s]
    sw_mode: true            # true = 静止时冻结相位
    cmd_threshold: 0.05      # 静止判断阈值（速度范数）
  obs_scales:
    lin_vel: 2.0             # vx, vy 缩放
    ang_vel: 1.0             # 角速度缩放（base_ang_vel 使用；angular.z 未使用此值）
    dof_pos: 1.0             # 关节角偏差缩放
    dof_vel: 0.05            # 关节速度缩放
    quat: 1.0                # 欧拉角缩放
  onnx_conf:
    policy_file: <path>      # 相对运行目录的 ONNX 路径
    actions_size: 12         # 输出动作维度
    observations_size: 47   # 单帧观测维度
    num_hist: 66             # 历史帧数
    observations_clip: 100.  # 观测值限幅
    actions_clip: 100.       # 动作限幅
  lpf_conf:
    wc: 100.                 # 截止角频率 [rad/s]
    ts: 0.001                # 采样时间 [s]
    paralle_list: [...]      # 使用力矩模式的关节名（踝关节）
```

---

## 10. 主循环时序

```
rl_control_pub_thread（1000 Hz，AimRT simple_thread）
│
├── [AimRT 回调线程，异步] ─────────────────────────────────────┐
│   ├── joint_state 回调：                                       │
│   │   ├── 首次：建立 joint_state_index_map_                    │
│   │   ├── 应用 offset 补偿（减去）                            │
│   │   └── SetJointStateData → 所有控制器（含非活跃）          │
│   ├── imu 回调：SetImuData → 当前活跃控制器                   │
│   └── cmd_vel 回调：SetCmdData → 当前活跃控制器               │
│                                                                │
│   ├── 模式触发 Topic 回调（1s 节流）：                         │
│   │   ├── Throttler 检查                                       │
│   │   ├── StateMachine::OnEvent（shared_mutex 保护）           │
│   │   └── RestartController（新状态所有控制器）                │
│   └───────────────────────────────────────────────────────────┘
│
├── sleep_until(next_time)    // 绝对定时，1ms 周期
│
├── GetCurrentControllerNames()  // shared_lock 读取活跃控制器列表
│
├── for each active_controller:
│   ├── Update()              // PDController 或 RLController 计算
│   └── GetJointCmdData()     // 读取本帧指令
│
├── 合并关节指令（按 joint_cmd_index_map_ 写入 cmd_msg）
│   └── position += joint_offset_map_  // 加回硬件偏移
│
└── Publish(joint_cmd_pub_, cmd_msg)
```

---

## 11. 接口约束与已知限制

### 11.1 前提条件

| 条件 | 说明 |
|------|------|
| IMU 数据就绪 | `Start()` 后立即开始，首帧前控制器使用零初值 IMU 数据 |
| 关节状态就绪且名称完整 | JointState 消息中必须包含 `joint_state_index_map_` 中所有关节名；缺失会导致 `at()` 抛异常 |
| ONNX 模型文件存在 | `Initialize()` 阶段加载，路径相对于运行目录 |
| 执行器配置存在 | AimRT 配置文件中必须有名为 `rl_control_pub_thread` 的执行器 |
| 状态机初始为 idle | Kp=Kd=0，系统上电安全；必须 idle→zero→stand→walk 顺序进入行走 |

### 11.2 已知限制

| 限制 | 说明 |
|------|------|
| 状态切换节流 1s | 快速连续切换会被吞掉，操作员需等待 1 秒 |
| 无传感器超时检测 | IMU 或关节状态停止发布时，控制器继续使用最后一帧数据，无告警 |
| 无关节限位检查 | 目标角不经过 URDF 限位裁剪，依赖 DCU 驱动层硬件保护 |
| 过渡时间 2s 硬编码 | `trans_mode_duration_s_` 不可配置 |
| Ruckig DOF 为 3 硬编码 | `pd_plan`（3 关节）正常；若 `plan_conf` 用于其他关节数控制器，`Init()` 会崩溃 |
| `loop_count_` 不随状态切换重置 | 推理时机与状态切换时刻无关；切换后首次推理可能延迟最多 `decimation-1` 帧 |
| ONNX Env 生命周期 | `LoadModel()` 中 `Ort::Env` 以局部 `shared_ptr` 持有，函数退出后析构；推理期间 Env 不存在。C++ wrapper 仅将 env 值传递给 C API `CreateSession()`，Session 内部（`OrtSession*`）不保存 Env 引用。`SetInterOpNumThreads(1)` 时使用 per-session 线程池而非 env 级全局池，Env 销毁后线程池/日志器对已初始化的 session 无影响。实测正常，但依赖 ORT 内部实现细节，属于 C++ 层面的未定义行为，升级 ORT 版本时需关注。 |
| `angular.z` 无缩放 | 观测向量索引 4 未乘以 `obs_scales_.ang_vel`，与 `base_ang_vel` 的处理不一致，为现有行为 |

---

## 12. 与其他模块的依赖关系

```
JoyStickModule ──► /cmd_vel_limiter ──► ControlModule（活跃控制器）
DcuDriverModule ──► /imu/data       ──► ControlModule（活跃控制器）
DcuDriverModule ──► /joint_states   ──► ControlModule（全部控制器）
SimModule       ──► /imu/data       ──► ControlModule（活跃控制器，仿真模式）
SimModule       ──► /joint_states   ──► ControlModule（全部控制器，仿真模式）

ControlModule   ──► /joint_cmd      ──► DcuDriverModule（真机）
ControlModule   ──► /joint_cmd      ──► SimModule（仿真）

外部 ROS2 节点  ──► /xxx_mode       ──► ControlModule（状态切换，1s 节流）
外部 ROS2 节点  ──► /cmd_vel_limiter ──► ControlModule（直接速度控制）
```

---

## 附录

### A. 控制器参数速查

#### 站立姿态目标角（pd_stand.init_state）

| 关节 | 目标角 [rad] |
|------|------------|
| left_shoulder_pitch | 0.15 |
| left_shoulder_roll | -0.10 |
| left_elbow_pitch | 0.30 |
| right_shoulder_pitch | 0.15 |
| right_shoulder_roll | -0.10 |
| right_elbow_pitch | 0.30 |
| left_hip_pitch | 0.40 |
| left_hip_roll | 0.05 |
| left_hip_yaw | -0.31 |
| left_knee_pitch | 0.49 |
| left_ankle_pitch | -0.21 |
| right_hip_pitch | -0.40 |
| right_hip_roll | -0.05 |
| right_hip_yaw | 0.31 |
| right_knee_pitch | 0.49 |
| right_ankle_pitch | -0.21 |

#### RL 控制器关键参数

| 参数 | rl_walk_leg | rl_walk_leg_shoulder |
|------|------------|---------------------|
| 关节数 | 12（双腿） | 14（双腿 + 双肩） |
| 观测维度（单帧） | 47 | 53 |
| 历史帧数 | 66 | 66 |
| 推理间隔 | 10 帧（10 ms） | 10 帧（10 ms） |
| 步态周期 | 0.7 s | 1.0 s |
| 动作缩放 | 0.5 | 0.5 |
| 速度阈值 | 0.05 | 0.05 |
| 策略文件 | `rl_walk_leg.onnx` | `rl_walk_leg_shoulder.onnx` |
| LPF 关节 | 4 踝关节（力矩模式） | 4 踝关节（力矩模式） |

### B. 参考文件

| 文件 | 说明 |
|------|------|
| [control_module.cc](../src/module/control_module/src/control_module.cc) | 模块主逻辑 |
| [pd_controller.cc](../src/module/control_module/src/pd_controller.cc) | PD 控制器实现 |
| [rl_controller.cc](../src/module/control_module/src/rl_controller.cc) | RL 控制器实现 |
| [controller_base.cc](../src/module/control_module/src/controller_base.cc) | 基类线程安全数据管理 |
| [utilities.cc](../src/module/control_module/src/utilities.cc) | 低通滤波器 + Ruckig 插值器 |
| [rl_x1_sim.yaml](../src/module/control_module/cfg/rl_x1_sim.yaml) | 仿真配置（含全部控制器参数） |
| [l0_system_architecture.md](l0_system_architecture.md) | 系统架构规格（§3.1） |

### C. 标注说明

本文档所有行为均已通过源码审阅确认，不含 `[NEEDS SOURCE REVIEW]` 或 `[NEEDS VERIFICATION]` 标注。
