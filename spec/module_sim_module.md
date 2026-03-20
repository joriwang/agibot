# SimModule — 模块规格说明

> **文档版本**: v1.1
> **生成日期**: 2026-03-20
> **信息来源**: 全部源文件、头文件、MJCF 模型、配置文件（完整源码审阅）
> **适用系统**: AgiBot X1 推理软件（xyber_x1_infer）

---

## 1. 模块概述

### 1.1 职责

`SimModule` 是仿真模式下替代 `DcuDriverModule` 的**物理仿真驱动模块**。它的职责是：

1. 加载 MuJoCo MJCF 机器人模型，构建物理仿真环境
2. 以 GLFW 窗口提供实时 3D 可视化渲染（独立渲染线程）
3. 接收来自 `ControlModule` 的关节控制指令，通过 PD 力矩公式写入仿真
4. 每收到一条指令就推进一步仿真（`mj_step`），读取虚拟传感器数据并发布
5. 对外呈现与 `DcuDriverModule` 相同的 Channel 接口，使系统闭环运行

### 1.2 在系统中的定位

```
ControlModule
    │  /joint_cmd
    ▼
SimModule ──► WriteMotorCmd ──► d_->ctrl (PD 力矩)
    │              │
    │         mj_step(m_, d_)
    │              │
    │         ReadSensorData
    │
    ├── /imu/data     ──► ControlModule
    └── /joint_states ──► ControlModule

                    (独立线程)
sim_render_thread ──► mj::Simulate::RenderLoop() ──► GLFW 渲染
```

SimModule **不**与硬件交互，仅运行在仿真配置（`x1_cfg_sim.yaml`）中。

---

## 2. 接口契约

### 2.1 AimRT 模块信息

| 属性 | 值 |
|------|----|
| 模块名 | `SimModule` |
| 命名空间 | `xyber_x1_infer::sim_module` |
| 基类 | `aimrt::ModuleBase` |
| 生命周期方法 | `Initialize()` / `Start()` / `Shutdown()` |

### 2.2 Channel 接口

| 方向 | Topic | 消息类型 | 触发方式 | 说明 |
|------|-------|---------|---------|------|
| 订阅 | `/joint_cmd` | `my_ros2_proto::msg::JointCommand` | 每收到一条消息 | 关节控制指令；触发 `mj_step` 并回发传感器数据 |
| 发布 | `/imu/data` | `sensor_msgs::msg::Imu` | 每次 `mj_step` 后 | 虚拟 IMU 数据（朝向 + 角速度 + 线加速度） |
| 发布 | `/joint_states` | `sensor_msgs::msg::JointState` | 每次 `mj_step` 后 | 虚拟关节状态（位置 + 速度 + 力矩） |

> **注意**：配置文件中声明了 `sub_reset_sim_topic: /reset_sim`，但当前代码**未订阅也未实现**该 Topic 的处理逻辑。该字段被读取但被丢弃。

### 2.3 配置文件接口（`sim_x1.yaml`）

| 字段 | 类型 | 示例值 | 是否实际使用 | 说明 |
|------|------|-------|------------|------|
| `model_file` | string | `cfg/sim_module/model/mjcf/xyber_x1_flat.xml` | ✅ 是 | MuJoCo MJCF 模型路径（`mj_loadXML` 参数） |
| `render_frequecy` | int | `50` | ❌ 否 | 配置被读取但从未使用；渲染频率由 `RenderLoop` 内部基于 VSync 决定 |
| `sub_reset_sim_topic` | string | `/reset_sim` | ❌ 否 | 读取后未注册订阅（功能未实现） |
| `sub_joint_cmd_topic` | string | `/joint_cmd` | ✅ 是 | 关节指令订阅 Topic |
| `pub_imu_data_topic` | string | `/imu/data` | ✅ 是 | IMU 数据发布 Topic |
| `pub_joint_state_topic` | string | `/joint_states` | ✅ 是 | 关节状态发布 Topic |

> **配置拼写错误**：`render_frequecy` 应为 `render_frequency`，属模块内笔误，不影响运行（值未被使用）。

### 2.4 执行器依赖

| 执行器名 | 类型 | 用途 |
|---------|------|------|
| `sim_render_thread` | AimRT `simple_thread` | 运行 GLFW 渲染循环（`mj::Simulate::RenderLoop()`），不参与仿真步进 |

### 2.5 构建产物

| 属性 | 值 |
|------|----|
| 编译类型 | **静态库**（`add_library(... STATIC)`） |
| 链接依赖 | `libmujoco.so.3.1.3`（内嵌于 `third_party/lib/`）、`glfw`、`dart-external-lodepng`、多个 ROS2 消息库 |
| 安装内容 | `cfg/` 配置目录 + `model/` MJCF 模型目录 → `bin/cfg/sim_module/` |

---

## 3. 物理模型

### 3.1 MJCF 模型结构

顶层文件：`model/mjcf/xyber_x1_flat.xml`，`include` 两个子文件：

| 子文件 | 内容 |
|--------|------|
| `robot/xyber_x1/xyber_x1_serial.xml` | 机器人关节/连杆/惯量/执行器/传感器完整定义 |
| `environment/flat.xml` | 平地地形环境 |

### 3.2 仿真参数

| 参数 | 值 | 说明 |
|------|----|----|
| 物理时间步长 | `0.001 s`（1 kHz） | `<option timestep="0.001"/>`；与控制频率精确对应 |
| 机器人初始高度 | `0.7 m` | `<body pos="0 0 0.7">`，在平地上方 |
| 根关节类型 | `freejoint`（`floating_base`） | 6 自由度浮动基座，占 qpos[0..6]（3平移 + 4四元数）和 qvel[0..5] |
| 可控关节数 | 29 个（全 hinge 类型） | 不含 freejoint |
| 执行器数量 | 29 个 `motor` | 与关节一一对应，直接输出力矩 |
| 碰撞求解器参数 | `solref="0.005 1"` `condim=3` `friction="1 1"` | 默认几何与 equality 约束均使用 |

### 3.3 关节与执行器列表

| 部位 | 关节名（`_joint` 后缀） | 执行器力矩范围 |
|------|--------|--------------|
| 腰部（3） | `lumbar_yaw/roll/pitch` | ±150 N·m |
| 左肩（3） | `left_shoulder_pitch/roll/yaw` | ±150 N·m |
| 左肘（2） | `left_elbow_pitch/yaw` | ±150 N·m |
| 左腕（2） | `left_wrist_pitch/roll` | ±150 N·m |
| 右臂（对称，7） | `right_shoulder/elbow/wrist_*` | ±150 N·m |
| 左髋（3） | `left_hip_pitch/roll/yaw` | pitch: ±150，roll/yaw: ±50 N·m |
| 左膝（1） | `left_knee_pitch` | ±150 N·m |
| 左踝（2） | `left_ankle_pitch/roll` | ±18 N·m |
| 右腿（对称，6） | `right_hip/knee/ankle_*` | 同左腿 |

### 3.4 IMU 传感器定义与数组布局

IMU 挂载在 `x1-body` 根连杆上的 `imu` site（位置 `0 0 0`）。传感器定义顺序决定 `d_->sensordata` 的索引：

| 索引 | 传感器名 | 类型 | 代码字段 | 噪声 |
|------|---------|------|---------|------|
| [0–3] | `body-orientation` | `framequat` | `imu_data.orientation.{w,x,y,z}` | 0 |
| [4–6] | `body-angular-velocity` | `gyro` | `imu_data.angular_velocity.{x,y,z}` | 0.001 |
| [7–9] | `body-linear-pos` | `framepos` | **未使用** | 0 |
| [10–12] | `body-linear-vel` | `velocimeter` | **未使用** | 0 |
| [13–15] | `body-linear-acceleration` | `accelerometer` | `imu_data.linear_acceleration.{x,y,z}` | 0.001 |
| [16–44] | `jointpos_*`（29个） | `jointpos` | 未使用（关节位置直接从 `qpos` 读取） | 0 |
| [45–73] | `jointvel_*`（29个） | `jointvel` | 未使用 | 0 |
| [74–102] | `jointeffort_*`（29个） | `jointactuatorfrc` | 未使用 | 0 |

> **总 sensordata 长度**：16 + 29×3 = 103 个 `mjtNum`。代码只访问 [0–6] 和 [13–15]，其余传感器定义仅供 MuJoCo GUI 的 Sensor 面板显示使用。

### 3.5 关节状态数据来源

| `joint_state` 字段 | MuJoCo 数据源 | 偏移 | 说明 |
|-------------------|--------------|------|------|
| `position` | `d_->qpos + 7` | 跳过 freejoint（3平移+4四元数） | 关节角（rad） |
| `velocity` | `d_->qvel + 6` | 跳过 freejoint（6速度自由度） | 关节角速度（rad/s） |
| `effort` | `d_->qfrc_actuator + 6` | 跳过 freejoint | 执行器施加的广义关节力矩（N·m） |

### 3.6 碰撞模型

足底碰撞通过球形 geom 近似，每只脚踝 roll 连杆上有 **4 个小球**（半径 0.002 m，`class="collision"`），分布在前后左右四角（±0.03 m, ±0.07 m），模拟足底四角接触点。另有 4 个半径 0.02 的可视化球（红色半透明，不参与碰撞）用于渲染显示。

### 3.7 关键帧（Keyframe）

MJCF 定义了两个关键帧，可通过 MuJoCo GUI 的 Simulation → Key 滑块加载：

| 帧名 | 描述 |
|------|------|
| `home_default` | 所有关节归零，机体在 z=0.7 m |
| `check_pose` | 上肢各关节 0.3 rad，下肢为站立姿态（髋/膝/踝按正常站立角度设置） |

---

## 4. 内部逻辑

### 4.1 生命周期初始化流程

#### Initialize()

```
输入：AimRT CoreRef
返回：bool（成功/失败）

1. 记录 start_time_ = high_resolution_clock::now()
2. 保存 core_ 句柄
3. 读取配置文件路径 → 若为空，AIMRT_ERROR + return false
4. YAML::LoadFile(path)：
   a. 读取 filename_（model_file 字段）
   b. 获取 joint_cmd 订阅者，注册 CmdCallback
   c. 注册 /imu/data 发布者（sensor_msgs::Imu 类型）
   d. 注册 /joint_states 发布者（sensor_msgs::JointState 类型）
   e. 获取 sim_render_thread 执行器句柄
5. 若 YAML 解析抛出异常 → AIMRT_ERROR + return false
6. return true
```

> `render_frequecy` 和 `sub_reset_sim_topic` 字段虽在配置中存在，但 `Initialize()` 代码**不读取**这两个字段。

#### Start()

```
输入：无
返回：bool（成功/失败）

── 阶段 1：渲染线程初始化（主线程侧准备）──
1. mjv_defaultCamera/Option/Perturb 初始化相机、渲染选项、扰动对象

── 阶段 2：在 sim_render_thread 上异步执行 ──
2. 创建 mj::Simulate 对象，传入 GlfwAdapter（非 passive 模式）
3. sim_->LoadMessage(filename_)  → 显示 "loading..." UI 标签
   （内部设置 loadrequest = 3，渲染线程会显示 loading 消息）
4. mj_loadXML(filename_, nullptr, loadError, 1024) → m_
5. 将 loadError 拷贝到 sim_->load_error
6. 若 m_ 非空：
   a. 锁定 sim_->mtx
   b. d_ = mj_makeData(m_)
7. 设置 is_render_thread_running_ = true
8. sim_->RenderLoop()  ← 进入渲染主循环（阻塞直到窗口关闭）

── 阶段 3：主线程等待渲染线程就绪 ──
9. 自旋等待 is_render_thread_running_ == true（每 1ms 检查一次）

── 阶段 4：主线程完成初始化 ──
10. 若 d_ 非空（模型加载成功）：
    a. sim_->Load(m_, d_, filename_)  → 通知渲染线程加载模型
       （内部 loadrequest 经历 2→1→LoadOnRenderThread 状态机，并等待完成）
    b. 锁定 sim_->mtx
    c. mj_forward(m_, d_)  ← 初始前向动力学（计算初始状态）
    d. 分配并清零 ctrl_noise_ 数组（大小 m_->nu = 29）
11. 若 d_ 为空（模型加载失败）：
    a. sim_->LoadMessageClear()  ← 清除 loading 标签
    b. ⚠️ 继续执行 m_->njnt 访问 → 空指针解引用崩溃（见 §6.E-03）
12. 构建 joint_names_：遍历 m_->njnt，跳过 mjJNT_FREE 类型，收集关节名
13. 按 joint_names_.size() resize 所有 PD 数组
    （target_q_, target_dq_, target_tq_, kp_, kd_, motor_torque_）
14. AIMRT_INFO + return true
```

#### Shutdown()

```
1. free(ctrl_noise_)   ← 若 Start() 成功前 Shutdown 被调用，ctrl_noise_ 为 nullptr，free(nullptr) 安全
2. mj_deleteData(d_)   ← 同上，若 d_ 为 nullptr 则 MuJoCo 内部处理（行为依赖 MuJoCo 版本）
3. mj_deleteModel(m_)  ← 同上
4. AIMRT_INFO
```

### 4.2 渲染线程主循环（RenderLoop）

运行于 `sim_render_thread`，是 `mj::Simulate` 类的成员函数。

```
初始化阶段：
  1. 设置 MuJoCo 定时器回调（用于性能分析）
  2. mjv_defaultCamera/Option 初始化
  3. 初始化 Profiler 图表（Constraint / Cost / Timer / Size 四个面板）
  4. 初始化 Sensor 面板
  5. mjv_makeScene(nullptr, &scn, 20000)  ← 创建空场景（最大 20000 个几何体）
  6. 创建 GLFW 窗口（2/3 主显示器分辨率），启用 4x MSAA 多重采样
  7. 建立 OpenGL 上下文，注册鼠标/键盘/滚轮/文件拖放等 GLFW 回调
  8. 构建左侧 UI（文件/选项/仿真/监视面板）

主循环（直到窗口关闭或 exitrequest != 0）：
  锁定 sim_->mtx
    1. 处理 loadrequest 状态机：
       - loadrequest == 2 → 置为 1（下一帧处理）
       - loadrequest == 1 → 调用 LoadOnRenderThread()（更新 OpenGL 模型）
    2. PollEvents()  ← 处理 GLFW 输入事件
    3. 处理资产上传请求（hfield / mesh / texture）
    4. Sync()  ← 将 mjData 最新状态同步到可视化场景
  释放锁
  Render()  ← 渲染当前帧并 SwapBuffers
  FPS 统计（每 0.2 秒更新一次）

退出：
  mjv_freeScene()
  exitrequest.store(2)  ← 通知外部线程渲染已退出
```

> **Sync() 的作用**：将 `d_->qpos`/`ctrl` 等最新状态拷贝到渲染场景，并应用 GUI 中的用户修改（Reset / Copy pose / Load key 等 `pending_` 操作）。这是 `CmdCallback` 与渲染线程共享 `mjData` 的同步点，由 `sim_->mtx` 互斥锁保护。

### 4.3 控制回调（CmdCallback）

每收到一条 `/joint_cmd` 时，在 AimRT 回调线程上执行：

```
函数：CmdCallback(JointCommand msg)

1. 检查启动冷却：
   elapsed = now() - start_time_
   if elapsed ≤ 3000ms → return（丢弃，不步进）

2. 锁定 sim_->mtx（递归互斥锁，与渲染线程竞争）

3. WriteMotorCmd(msg)：← 见 §4.4

4. mj_step(m_, d_)：← 推进一步物理仿真（1 ms 时间步）

5. ReadSensorData(imu_data_msg, joint_states_msg)：← 见 §4.5

6. 释放锁（自动，unique_lock 析构）

7. 发布 /imu/data（sensor_msgs::Imu）
8. 发布 /joint_states（sensor_msgs::JointState）
```

### 4.4 关键算法：PD 力矩计算（WriteMotorCmd）

```
输入：JointCommand { name[], position[], velocity[], effort[], stiffness[], damping[] }

步骤 1 — 建立名称到索引的映射：
  for ii in 0..cmd.name.size():
    joint_state_index_map_[cmd.name[ii]] = ii

步骤 2 — 按 joint_names_ 顺序提取指令（名称对齐）：
  for ii in 0..joint_names_.size():
    index = joint_state_index_map_[joint_names_[ii]]
    target_q_[ii]  = cmd.position[index]   // 目标位置 [rad]
    target_dq_[ii] = cmd.velocity[index]   // 目标速度 [rad/s]
    target_tq_[ii] = cmd.effort[index]     // 前馈力矩 [N·m]
    kp_[ii]        = cmd.stiffness[index]  // 位置增益
    kd_[ii]        = cmd.damping[index]    // 速度增益

步骤 3 — 读取当前状态（Eigen Array，按元素操作）：
  q  = d_->qpos[7 .. 7+N]   // 当前关节位置
  dq = d_->qvel[6 .. 6+N]   // 当前关节速度

步骤 4 — 计算 PD 力矩：
  motor_torque_ = target_tq_
               + kp_ * (target_q_ - q)
               + kd_ * (target_dq_ - dq)

步骤 5 — 写入 MuJoCo 控制数组：
  d_->ctrl = motor_torque_.data()
  （注意：d_->ctrl 是指针，此处赋值为 motor_torque_ 内部数据指针）

步骤 6 — [可选] 叠加 Ornstein-Uhlenbeck 控制噪声：
  若 sim_->ctrl_noise_std > 0：
    rate  = exp(-timestep / max(ctrl_noise_rate, ε))
    scale = ctrl_noise_std * sqrt(1 - rate²)
    for i in 0..nu:
      ctrl_noise_[i] = rate * ctrl_noise_[i] + scale * N(0,1)
      d_->ctrl[i]   += ctrl_noise_[i]
```

> **噪声模型**：Ornstein-Uhlenbeck 过程，具有均值回归特性（rate 控制自相关时间）。`ctrl_noise_std` 和 `ctrl_noise_rate` 可在 MuJoCo GUI 的 Simulation 面板实时调节。

### 4.5 关键算法：传感器数据读取（ReadSensorData）

```
输入：（引用）imu_data, joint_state

时间戳（系统时钟，非仿真时钟）：
  duration = high_resolution_clock::now().time_since_epoch()
  sec      = duration_cast<seconds>(duration)
  nanosec  = duration_cast<nanoseconds>(duration - sec)

IMU 数据（固定索引访问 d_->sensordata）：
  orientation.{w,x,y,z}        = sensordata[0..3]  // framequat
  angular_velocity.{x,y,z}     = sensordata[4..6]  // gyro
  linear_acceleration.{x,y,z}  = sensordata[13..15] // accelerometer
  （sensordata[7..12] 跳过：framepos + velocimeter，未使用）
  header.stamp = {sec, nanosec}

关节状态（memcpy 批量拷贝）：
  name     = joint_names_（29 个关节名，顺序与 MJCF 定义一致）
  position = memcpy from d_->qpos+7,           长度 N*8 bytes
  velocity = memcpy from d_->qvel+6,           长度 N*8 bytes
  effort   = memcpy from d_->qfrc_actuator+6,  长度 N*8 bytes
  （N = joint_names_.size() = 29）
  header.stamp = {sec, nanosec}
```

> **时间戳说明**：使用**系统实时时钟**而非 MuJoCo 仿真时间 `d_->time`。这意味着时间戳反映的是数据发布的墙钟时间，而非仿真内的物理时间。在仿真降速播放时，两者会产生偏差。

### 4.6 GLFW 初始化细节

```
GlfwAdapter 构造：
1. 懒加载初始化 GLFW（全局单次，线程安全）：
   glfwInit() → 成功则注册 atexit(glfwTerminate)
2. glfwWindowHint(GLFW_SAMPLES, 4)  ← 4x MSAA 多重采样抗锯齿
3. glfwWindowHint(GLFW_VISIBLE, 1)  ← 窗口可见
4. 查询主显示器分辨率（vidmode_）
5. 创建窗口：大小为主显示器的 2/3（如 1920x1080 → 1280x720）
   窗口标题：固定为 "MuJoCo"
6. 注册回调：键盘、鼠标按键、鼠标移动、滚轮、窗口刷新、窗口大小变化、文件拖放
7. glfwMakeContextCurrent(window_)  ← 绑定 OpenGL 上下文到当前线程
```

> **GLFW 动态调度**：通过 `glfw_dispatch.h` 中的 `Glfw()` 函数返回动态加载的函数指针表，避免编译时与 GLFW 库的静态链接依赖（为 Python 绑定场景设计）。

---

## 5. 错误处理

### 5.1 Initialize() 错误处理

| 错误场景 | 处理方式 | 系统影响 |
|---------|---------|---------|
| 配置文件路径为空 | `AIMRT_ERROR` + `return false` | 模块初始化失败，AimRT 停止启动 |
| YAML 解析异常 | `catch(std::exception)` → `AIMRT_ERROR` + `return false` | 同上 |
| Channel 注册失败 | 无显式处理，异常会被 catch 捕获 | 同上 |
| `sim_render_thread` 执行器不存在 | 无显式检查，`render_executor_` 为无效句柄 | Start() 时调用 Execute 会失败 |

### 5.2 Start() 错误处理

| 错误场景 | 处理方式 | 严重程度 |
|---------|---------|---------|
| GLFW 初始化失败 | `mju_error("could not initialize GLFW")` → 调用 `exit(1)` | ☠️ 进程终止 |
| GLFW 窗口创建失败 | `mju_error("could not create window")` → 调用 `exit(1)` | ☠️ 进程终止 |
| `mj_loadXML` 失败（模型文件不存在/格式错误） | 错误字符串写入 `sim_->load_error`，`m_` 为 nullptr | ⚠️ **见 §6.E-03 已知 Bug** |
| `mj_makeData` 失败（内存不足） | `d_` 为 nullptr，走 `LoadMessageClear` 分支 | ⚠️ **见 §6.E-03 已知 Bug** |

### 5.3 CmdCallback() 错误处理

| 错误场景 | 处理方式 | 说明 |
|---------|---------|------|
| 启动冷却期内收到消息 | 静默丢弃，直接 return | 正常行为，非错误 |
| `joint_state_index_map_` 中不存在关节名 | `std::unordered_map::operator[]` 返回默认值 0，**不报错** | 可能导致错误关节被控制，无保护 |
| `mj_step` 内部约束求解失败 | MuJoCo 内部警告，不抛出异常 | 仿真继续但结果可能不可靠 |
| 发布 Channel 异常 | 无显式处理 | 依赖 AimRT 框架处理 |

### 5.4 Shutdown() 错误处理

`Shutdown()` 直接释放资源，不检查指针有效性。`free(nullptr)` 在 C 标准中是安全的；`mj_deleteData(nullptr)` 和 `mj_deleteModel(nullptr)` 的行为取决于 MuJoCo 实现（通常安全）。

---

## 6. 约束与已知问题

| 编号 | 类型 | 描述 |
|------|------|------|
| **E-01** | **设计约束** | 仿真频率与控制频率严格绑定：每条 `/joint_cmd` 推进一步仿真，不能独立配置仿真速率 |
| **E-02** | **功能缺失** | `/reset_sim` Topic 已在配置中声明但代码完全未实现（未订阅、无处理逻辑） |
| **E-03** | **已知 Bug** | `mj_loadXML` 失败时 `m_` 为 nullptr，但 `Start()` 随后访问 `m_->njnt` 会触发**空指针解引用崩溃**，进程无法优雅失败 |
| **E-04** | **已知 Bug** | `WriteMotorCmd` 中通过 `operator[]` 查找关节名索引，若 `/joint_cmd` 中缺少某关节名，会插入 index=0，导致**错误关节被控制**，无日志警告 |
| **E-05** | **精度说明** | IMU 时间戳使用系统墙钟（`high_resolution_clock`）而非仿真时间 `d_->time`，仿真降速时二者存在偏差 |
| **E-06** | **配置无效** | `render_frequecy: 50` 字段被读取到 YAML 节点但从未使用，实际渲染帧率由操作系统 VSync 决定 |
| **E-07** | **模型拼写错误** | MJCF 中左膝 body 命名为 `link_lleft_knee_pitch`（双 l），为模型笔误，不影响关节名 `left_knee_pitch_joint` |
| **E-08** | **并发安全** | `d_->ctrl` 赋值为 `motor_torque_.data()` 的内部指针，锁释放后渲染线程的 `Sync()` 可能读取已被修改的 `d_->ctrl`（虽有 mtx 保护，但赋值操作是指针赋值而非数据复制，存在微妙的生命周期问题） |

---

## 7. 线程模型与并发

| 线程 | 来源 | 职责 | 持锁时机 |
|------|------|------|---------|
| `sim_render_thread` | AimRT `simple_thread` | 初始化 GLFW + 运行 `RenderLoop()`（事件处理 + Sync + Render） | 每帧持有 `sim_->mtx` 一次（Sync 期间） |
| AimRT 回调线程 | 框架管理 | 执行 `CmdCallback`（`mj_step` + 传感器读取 + 发布） | 每次回调持有 `sim_->mtx` |
| 主线程（Start 阶段） | AimRT 框架 | 等待渲染就绪 + `mj_forward` 初始化 | Start 阶段持有一次 `sim_->mtx` |

**锁类型**：`SimulateMutex`（`std::recursive_mutex` 子类），允许同一线程多次加锁。

**竞争分析**：
- `CmdCallback` 修改 `d_->ctrl` 并调用 `mj_step`（需要锁）
- `RenderLoop` 的 `Sync()` 读取 `d_->qpos`/`ctrl` 进行可视化（需要锁）
- 两者通过 `sim_->mtx` 互斥，`mj_step` 期间渲染线程阻塞

---

## 8. 与 DcuDriverModule 的接口对比

| 维度 | SimModule | DcuDriverModule |
|------|----------|----------------|
| 驱动方式 | `mj_step`（软件仿真） | EtherCAT 总线（硬件） |
| 仿真步进触发 | 收到 `/joint_cmd` 时**同步**触发 | 独立 `publish_thread_` 以 1000 Hz 周期运行 |
| 传动层 | 无（直接关节空间操作） | 有（关节 ↔ 执行器空间转换） |
| IMU 来源 | MJCF `framequat/gyro/accelerometer` 虚拟传感器 | 真实 IMU 硬件（hip DCU） |
| 渲染 | GLFW 实时 3D 窗口（独立渲染线程） | 无 |
| 执行器力矩范围 | MJCF 中定义（各关节 ±18~150 N·m） | 硬件执行器物理限制 |
| 噪声建模 | OU 过程控制噪声（GUI 实时可调） | 无 |
| 关节索引 | 由 `joint_names_` 顺序决定 | 由 DCU 配置文件的 `actuator_list` 决定 |
