# JoyStickModule 模块规格说明

> **文档版本**: v1.1
> **生成日期**: 2026-03-20
> **适用系统**: AgiBot X1 推理软件（xyber_x1_infer）
> **参考架构**: [l0_system_architecture.md](l0_system_architecture.md) §3.3
> **源码路径**: `src/module/joy_stick_module/`

---

## 1. 模块概述

### 1.1 职责

`JoyStickModule` 是系统的**人机交互入口**，负责：

1. 通过 SDL2 读取物理游戏手柄的按键和摇杆输入
2. 将按键事件映射为**模式切换指令**，发布到对应 Topic（值固定为 `0.0`，仅作触发信号）
3. 将摇杆轴数据转换为 `geometry_msgs/Twist` **速度指令**，直接发布原始值
4. 对速度指令进行基于二次规划（qpOASES）的**速度限幅**，发布平滑限幅速度
5. （可选）将按键事件映射为 **shell 服务调用**（`ros2 service call`）
6. 以固定频率（默认 **20 Hz**，`sleep_for` 相对定时）驱动主循环

### 1.2 在系统中的位置

```
物理手柄 (SDL2)
      │
      ▼
JoyStickModule
      │ /idle_mode, /zero_mode, /stand_mode
      │ /walk_mode, /walk_mode2, /keep_mode, /plan_mode  (Float32, 值=0.0)
      ├──────────────────────────────────────────────► ControlModule
      │ /cmd_vel                                        (Twist, 原始轴值)
      ├──────────────────────────────────────────────► 外部监控/记录
      │ /cmd_vel_limiter                               (Twist, QP 限幅后)
      └──────────────────────────────────────────────► ControlModule
```

### 1.3 运行模式

| 模式 | 说明 |
|------|------|
| 真机部署 | 启用，读取实体手柄（SDL 设备 ID 0） |
| 仿真调试 | 可选；不启用时可通过外部 ROS2 节点直接发布指令替代 |

---

## 2. 子组件说明

### 2.1 `Joy`（SDL2 手柄驱动）

**职责**：封装 SDL2 手柄事件循环，提供线程安全的手柄数据快照接口。

**数据结构**：

```cpp
struct JoyStruct {
  std::vector<double>  axis;     // 各摇杆轴归一化值，范围 [-1.0, 1.0]
  std::vector<int32_t> buttons;  // 各按键状态（0=未按，1=按下）
};
```

**硬编码初始化参数**（全部在构造函数中固定，不从 YAML 读取）：

| 参数 | 值 | 说明 |
|------|----|------|
| `dev_id_` | 0 | 使用第一个 SDL 设备 |
| `scaled_deadzone_` | 0.05 | 归一化死区（5%） |
| `unscaled_deadzone_` | 32767 × 0.05 ≈ 1638.35 | 原始死区阈值 |
| `scale_` | −1.0 / (1 − 0.05) / 32767 | 轴缩放系数（含符号反转） |
| `autorepeat_rate_` | 20 Hz | 自动重复发布频率 |
| `autorepeat_interval_ms_` | 50 ms | 自动重复间隔 |
| `sticky_buttons_` | `false` | 普通按键（按下=1，释放=0） |
| `coalesce_interval_ms_` | 1 ms | 轴事件合并窗口 |

**线程安全**：`event_thread_` 通过 `joy_msg_mutex_` 保护 `joy_msg_`；`GetJoyData()` 加锁后拷贝整个结构体。`is_update_` 为 `atomic_bool`，当前主循环中等待逻辑已注释掉，`GetJoyData()` 不阻塞，直接返回最近快照。

### 2.2 `JoyVelLimiter`（速度限幅器）

**职责**：基于 qpOASES 二次规划对速度指令进行有界平滑限幅，防止速度突变。

**接口**：

```cpp
// 构造：dim=轴数, dt=时间步长, lb/ub=各轴速度上下界
JoyVelLimiter(int32_t dim, double dt, array_t lb, array_t ub);

void reset();                  // 将内部积分状态置零
array_t update(array_t target_pos);  // 输入目标位置，返回限幅后的当前位置
```

**QP 问题描述（算法核心）**：

每次 `update(target_pos)` 求解如下带简单边界约束的 QP：

```
最小化  0.5 * xᵀ H x + gᵀ x
约束    lb ≤ x ≤ ub

其中：
  H = dt² × I（对角矩阵，dim×dim）
  g = (state - target_pos) × dt
  x 为本周期的速度增量（每轴，单位 m/s 或 rad/s）
  lb, ub 为速度上下界
```

展开目标函数：

```
min  0.5 * dt² * ||x||²  +  (state - target_pos) * dt * x
```

物理含义：在速度约束内，以最小速度代价使 `state` 向 `target_pos` 靠近。

**更新步骤（伪代码）**：

```
function update(target_pos):
    g = (state - target_pos) * dt
    x_opt = solve_QP(H, g, lb, ub)   // qpOASES，最多 10 次 working-set 迭代
    state = state + x_opt * dt
    return state
```

**关键参数**（来自 YAML 配置，由 `JoyStickModule::Initialize` 传入）：

| 参数 | 值（joy_x1.yaml） | 说明 |
|------|-------------------|------|
| `dim` | 3 | axis 数量（linear-x/y, angular-z） |
| `dt` | 1.0 / 20 = 0.05 s | 与主循环频率绑定 |
| `lb` | [−0.5, −0.3, −0.5] | 速度下界（m/s, m/s, rad/s） |
| `ub` | [0.5, 0.3, 0.5] | 速度上界 |

**状态**：`state_` 初始为零向量。`reset()` 将其归零，应在速度指令不连续（模式切换、手柄离手）时调用，否则会产生速度跳变。当前主循环中**没有自动调用 `reset()`**。

**qpOASES 选项**：
- `printLevel = PL_NONE`（无控制台输出）
- `initialStatusBounds = ST_INACTIVE`（所有约束初始为非激活）
- `numRefinementSteps = 1`
- `enableCholeskyRefactorisation = 1`
- 每次 `update` 均调用 `solver_.init()`（冷启动，不热启动）

### 2.3 `JoyStickModule`（主模块）

**AimRT 生命周期**：

| 方法 | 职责 |
|------|------|
| `Initialize(CoreRef)` | 解析 YAML；注册所有 Channel Publisher；创建 `Joy` 和 `JoyVelLimiter` |
| `Start()` | 向 `joy_stick_pub_thread` executor 投递 `MainLoop()` |
| `Shutdown()` | 设 `run_flag_ = false`，阻塞等待 `stop_sig_` future（主循环结束后 `set_value`） |

---

## 3. 内部逻辑

### 3.1 初始化流程

```
Initialize(core):
  core_ = core
  joy_ = new Joy()          // 立即启动 SDL 事件线程
  读取 YAML 配置文件:
    freq_  ← cfg["freq"]
    executor_ ← GetExecutor("joy_stick_pub_thread")
    若 executor_ 为空 → 抛出异常，Initialize 返回 false

  遍历 cfg["float_pubs"]:
    构造 FloatPub { topic_name, buttons }
    注册 Publisher<std_msgs::Float32>(topic_name)
    加入 float_pubs_

  遍历 cfg["twist_pubs"]:
    构造 TwistPub { topic_name, buttons, axis_map }
    注册 Publisher<geometry_msgs::Twist>(topic_name)        → /cmd_vel
    若配置了 velocity_limit_lb/ub:
      注册 Publisher<geometry_msgs::Twist>(topic_name + "_limiter")  → /cmd_vel_limiter
      limiter_ = new JoyVelLimiter(axis_count, 1.0/freq_, lb, ub)
    加入 twist_pubs_

  遍历 cfg["rpc_clients"]:
    构造 ServiceClient { service_name, buttons, interface_type }
    加入 srv_clients_
    // AimRT RPC 注册逻辑已注释掉，当前不做任何框架注册

  return true
```

### 3.2 主循环逻辑

```
MainLoop():
  while run_flag_:
    joy_data ← joy_.GetJoyData()    // 加锁快照，不阻塞

    // --- 模式切换发布 ---
    for each float_pub in float_pubs_:
      ok = true
      for each btn in float_pub.buttons:
        ok &= joy_data.buttons[btn]    // AND 逻辑：所有配置按键必须同时按下
      if ok:
        Publish<Float32>(float_pub.pub, {data=0.0})  // 值恒为 0.0

    // --- 速度指令发布 ---
    for each twist_pub in twist_pubs_:
      ok = true
      for each btn in twist_pub.buttons:
        ok &= joy_data.buttons[btn]    // AND 逻辑
      if ok AND limiter_ != null:
        // 1. 从轴索引读取各分量，构造原始 Twist 和 target_pos 数组
        //    按 linear-x → linear-y → linear-z → angular-x → angular-y → angular-z 顺序
        //    只处理 YAML 中声明的轴，其余分量保留上一周期值（vel_msgs 不重置）
        Publish<Twist>(twist_pub.pub, vel_msgs)        // 发布原始值

        // 2. 将 target_pos 送入限幅器
        state = limiter_.update(target_pos)
        // 3. 用 state 覆写 vel_msgs 对应分量
        Publish<Twist>(twist_pub.pub_limiter, vel_msgs)  // 发布限幅值

      // 若 ok=false（使能键未按）或 limiter_=null，本周期不发布任何 Twist

    // --- RPC 服务调用 ---
    for each srv in srv_clients_:
      ok = true
      for each btn in srv.buttons:
        ok &= joy_data.buttons[btn]
      if ok:
        cmd = "ros2 service call /" + srv.service_name + " " + srv.interface_type + " > /dev/null &"
        system(cmd)    // 通过 shell 子进程调用，异步（& 后台执行）

    sleep_for(1000 / freq_ ms)   // 相对休眠，存在累积漂移

  stop_sig_.set_value()   // 通知 Shutdown() 可以返回
```

### 3.3 SDL 事件线程逻辑

```
eventThread():
  while is_running_:
    wait_ms = autorepeat_interval_ms_  // 50ms
    若 publish_soon_: wait_ms = min(wait_ms, coalesce_interval_ms_=1ms)

    event ← SDL_WaitEventTimeout(wait_ms)  // 阻塞等待，超时自动唤醒
    lock(joy_msg_mutex_)

    if 事件到达:
      SDL_JOYAXISMOTION    → handleJoyAxis()     // 带合并窗口（1ms）
      SDL_JOYBUTTONDOWN    → handleJoyButtonDown()
      SDL_JOYBUTTONUP      → handleJoyButtonUp()
      SDL_JOYHATMOTION     → handleJoyHatMotion()
      SDL_JOYDEVICEADDED   → handleJoyDeviceAdded()   // 打开设备，初始化 axis/buttons
      SDL_JOYDEVICEREMOVED → handleJoyDeviceRemoved() // 关闭设备，清空 axis/buttons
    else (超时):
      若 autorepeat 间隔到期 或 publish_soon_:
        应发布（更新 is_update_ = true）

    若 joystick_ 非空 且 should_publish:
      is_update_.store(true)   // 当前未被 MainLoop 使用
```

### 3.4 轴值归一化算法

SDL2 原始轴值范围 [−32768, 32767]，转换为 ROS 约定的 [−1.0, 1.0]：

```
function convertRawAxisValueToROS(val: int16):
  若 val == -32768: val = -32767    // 修正边界

  double_val = float(val)

  // 死区处理（平滑死区，非跳变）
  若 double_val > unscaled_deadzone_:
      double_val -= unscaled_deadzone_
  elif double_val < -unscaled_deadzone_:
      double_val += unscaled_deadzone_
  else:
      return 0.0

  // 缩放 + 符号反转（SDL 前进/左转为负，ROS 为正）
  return double_val * scale_
  // scale_ = -1.0 / (1 - 0.05) / 32767 ≈ -3.208e-5
```

结果：死区内输出 0.0；死区外输出 [−1.0, 1.0]（含符号反转）。

### 3.5 Hat（方向键）到轴的映射

每个 hat 占 `axis` 末尾连续 2 个位置（索引 `num_axes + hat_id*2`）：

| Hat 方向 | axis[N] | axis[N+1] |
|----------|---------|-----------|
| 左 / 右  | +1.0 / −1.0 | 0.0 |
| 上 / 下  | 0.0 | +1.0 / −1.0 |
| 居中     | 0.0 | 0.0 |

---

## 4. 接口契约（Channel）

### 4.1 发布 Topics

| Topic | 消息类型 | 触发条件 | 发布值 | 频率上限 |
|-------|---------|---------|--------|---------|
| `/idle_mode` | `std_msgs/Float32` | button[7] 按下（AND） | `data = 0.0` | 20 Hz |
| `/zero_mode` | `std_msgs/Float32` | button[1] 按下 | `data = 0.0` | 20 Hz |
| `/stand_mode` | `std_msgs/Float32` | button[0] 按下 | `data = 0.0` | 20 Hz |
| `/walk_mode` | `std_msgs/Float32` | button[2] 按下 | `data = 0.0` | 20 Hz |
| `/walk_mode2` | `std_msgs/Float32` | button[3] 按下 | `data = 0.0` | 20 Hz |
| `/keep_mode` | `std_msgs/Float32` | button[6] 按下 | `data = 0.0` | 20 Hz |
| `/plan_mode` | `std_msgs/Float32` | button[5] 按下 | `data = 0.0` | 20 Hz |
| `/cmd_vel` | `geometry_msgs/Twist` | button[4] 按住 | 归一化轴值（无单位缩放） | 20 Hz |
| `/cmd_vel_limiter` | `geometry_msgs/Twist` | button[4] 按住 | QP 限幅后位置状态 | 20 Hz |

**注意**：
- 模式 Topic 的 `Float32.data = 0.0` 是固定值，接收方（`ControlModule`）仅用 Topic 到达事件触发状态切换，不读取值。
- `/cmd_vel` 发布的是归一化轴值（最大 ±1.0），**不是实际速度单位的值**；而 `/cmd_vel_limiter` 经过限幅器后输出的是以限幅边界为上限的平滑值，单位约束由 `velocity_limit_lb/ub` 配置决定。
- button[4] **松开**时，本周期内 `/cmd_vel` 和 `/cmd_vel_limiter` 均**不发布**，但限幅器状态不重置，下次按下时从上次状态继续积分。

### 4.2 订阅 Topics

本模块**不订阅任何 Topic**，是系统的纯输入端。

### 4.3 RPC / 服务调用

`rpc_clients` 配置项触发通过 **`system()` shell 子进程**调用：

```bash
ros2 service call /<service_name> <interface_type> > /dev/null &
```

- 异步执行（`&`），不阻塞主循环
- AimRT RPC 调用路径已注释，当前为 shell 调用实现
- 当前 YAML 配置（`joy_x1.yaml`）**未包含 `rpc_clients` 字段**，此功能处于预留状态

---

## 5. 配置参考（`cfg/joy_x1.yaml`）

```yaml
freq: 20   # 主循环频率（Hz），同时决定 JoyVelLimiter 的 dt = 1/freq

float_pubs:
  - { topic_name: /idle_mode,   buttons: [7] }
  - { topic_name: /zero_mode,   buttons: [1] }
  - { topic_name: /stand_mode,  buttons: [0] }
  - { topic_name: /walk_mode,   buttons: [2] }
  - { topic_name: /walk_mode2,  buttons: [3] }
  - { topic_name: /keep_mode,   buttons: [6] }
  - { topic_name: /plan_mode,   buttons: [5] }

twist_pubs:
  - topic_name: /cmd_vel
    buttons: [4]             # 长按使能键
    axis:
      linear-x: 1            # SDL 轴索引
      linear-y: 0
      angular-z: 3
    velocity_limit_lb: [-0.5, -0.3, -0.5]   # 限幅下界 [vx, vy, wz]
    velocity_limit_ub: [0.5,  0.3,  0.5]    # 限幅上界

# rpc_clients:  （未使用，字段预留）
# - service_name: reset_world
#   buttons: [...]
#   interface_type: std_srvs/srv/Empty
```

### 5.1 `_limiter` Topic 命名规则

限幅后 Topic 名 = `twist_pubs[].topic_name + "_limiter"`（代码硬编码拼接），不可单独配置。

---

## 6. 线程模型

| 线程 | 创建方式 | 生命周期 | 职责 |
|------|---------|---------|------|
| `joy_stick_pub_thread` | AimRT `simple_thread` executor | `Start()` 到 `Shutdown()` 阻塞完成 | 主循环，20 Hz 周期发布；以 `sleep_for` 相对定时（有漂移） |
| `event_thread_`（`Joy` 内部） | `std::thread` | `Joy` 构造到析构 | SDL2 事件轮询，`SDL_WaitEventTimeout` 阻塞，持续更新 `joy_msg_` |

**锁协议**：`joy_msg_mutex_` 由 `event_thread_` 在事件处理时持有，由 `MainLoop` 在 `GetJoyData()` 时持有。持锁时间均极短（拷贝结构体 / 更新单个字段），无死锁风险。

---

## 7. 错误处理

| 位置 | 错误条件 | 处理方式 |
|------|---------|---------|
| `Joy::Joy()` | `SDL_Init` 失败 | 抛出 `std::runtime_error`，异常传播到 `JoyStickModule::Initialize`，初始化失败返回 `false` |
| `Joy::Joy()` | `autorepeat_rate_` < 0 或 > 1000 | 抛出 `std::runtime_error` |
| `JoyVelLimiter` 构造 | `lb.size() != dim` 或 `ub.size() != dim` | 抛出 `std::runtime_error` |
| `JoyStickModule::Initialize` | YAML 解析异常 / executor 获取失败 | `catch(std::exception)` → `AIMRT_ERROR` 日志 → 返回 `false` |
| `Joy::handleJoyDeviceAdded` | SDL_JoystickOpen / 获取轴数/按键数失败 | `std::cerr` 输出，`joystick_` 置 `nullptr`，继续运行（无手柄） |
| `Joy::handleJoyAxis/Button` | 轴/按键索引超出 `joy_msg_` 范围 | `std::cerr` 输出，忽略该事件，不崩溃 |
| 主循环访问空 `joy_data` | 手柄未连接时 `buttons`/`axis` 为空 vector | **未做边界检查**，`joy_data.buttons[button]` 可能越界（未定义行为）——详见 §8 已知问题 |
| `srv_clients_` shell 调用 | `system()` 返回非零 | 当前**不检查返回值**，失败静默忽略 |

---

## 8. 已知问题与约束

| 编号 | 问题 | 影响 | 建议 |
|------|------|------|------|
| P-01 | 手柄未连接时 `joy_msg_.buttons`/`axis` 为空，主循环按固定索引访问会**越界** | 启动时或手柄拔出后可能 crash | 访问前检查 `joy_data.buttons.size()` |
| P-02 | 手柄拔出（`handleJoyDeviceRemoved`）后 `buttons`/`axis` 被清零，但主循环**不感知**此状态变化，下次循环直接越界访问 | 同 P-01 | 同 P-01 |
| P-03 | `JoyVelLimiter` 在使能键松开再按下时**不重置状态**，从上次位置继续积分，可能产生非零初始速度输出 | 操作间隔后重新按键会有速度跳变 | 考虑在使能键由 0→1 时调用 `limiter_->reset()` |
| P-04 | 主循环使用 `sleep_for(1000/freq_ ms)` **相对定时**，存在累积漂移 | 实际频率可能略低于 20 Hz | 改用 `sleep_until` 绝对定时 |
| P-05 | `vel_msgs`（Twist 消息）在主循环中**不重置**，当 twist_pub 未触发时，残留上次的值；若 axis 配置不完整，某分量可能保留旧值 | 边缘场景数据污染 | 每周期重新初始化 `vel_msgs` |
| P-06 | `rpc_clients` 调用使用 `system()` 执行 shell 命令，`service_name` 和 `interface_type` 来自 YAML 配置文件，若配置文件被篡改存在命令注入风险 | 安全性问题（仅本地配置场景风险较低） | 改用 AimRT RPC（已预留注释代码） |
| P-07 | SDL `autorepeat_rate_`、`sticky_buttons_`、`coalesce_interval_ms_`、`dev_id_` 等参数**硬编码**，不支持运行时配置 | 手柄适配灵活性低 | 从 YAML 读取 |

---

## 9. 依赖

| 依赖 | 用途 |
|------|------|
| **SDL2** | 跨平台手柄输入（按键、摇杆、hat、热插拔、震动反馈） |
| **qpOASES** | 速度限幅二次规划求解（`QProblemB` 简单边界变体） |
| **Eigen3** | qpOASES 数据接口（`Eigen::Array`, `Eigen::MatrixXd`） |
| **yaml-cpp** | 读取 `joy_x1.yaml` 配置 |
| **AimRT** | 模块生命周期、Channel Publisher、Executor |
| **ROS2 msgs** | `std_msgs/Float32`, `geometry_msgs/Twist`, `std_srvs/Empty` |
