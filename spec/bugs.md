# Bug 追踪记录

> **文档版本**: v1.2
> **创建日期**: 2026-03-20
> **最后更新**: 2026-03-20（新增 BUG-06、BUG-07，来自 sim_module 审阅）

---

## 总览

| ID | 模块 | 严重程度 | 状态 | 概述 |
|----|------|---------|------|------|
| [BUG-01](#bug-01并联传动力矩输入-copy-paste-错误) | DcuDriverModule | 中 | 待修复 | 并联传动 roll 轴力矩读取了 velocity 字段 |
| [BUG-02](#bug-02脚踝查表越界无保护) | DcuDriverModule | 中 | 待修复 | 脚踝查表越界后位置静默置零 |
| [BUG-03](#bug-03并联传动奇异构型时分母为零无-naninf-保护) | DcuDriverModule | 高 | 待修复 | Jacobian 奇异时产生 NaN/Inf 下发执行器 |
| [BUG-04](#bug-04手柄未连接或拔出时主循环越界访问) | JoyStickModule | 高 | 待修复 | 手柄未连接时按固定索引访问空 vector，未定义行为 |
| [BUG-05](#bug-05速度限幅器状态在使能键松开后未重置) | JoyStickModule | 低 | 待修复 | 限幅器积分状态持续保留，重新使能后可能输出非零初始速度 |
| [BUG-06](#bug-06模型加载失败后空指针解引用崩溃) | SimModule | 高 | 待修复 | MJCF 加载失败时 `m_` 为 nullptr，后续访问 `m_->njnt` 导致崩溃 |
| [BUG-07](#bug-07关节名不匹配时静默错误控制) | SimModule | 中 | 待修复 | `/joint_cmd` 缺失关节名时 `unordered_map::operator[]` 返回 0，用第一个关节指令控制错误关节 |

---

## DcuDriverModule

### BUG-01：并联传动力矩输入 copy-paste 错误

**严重程度**: 中（运行时量纲错误，当前控制链路中未暴露）
**状态**: 待修复

#### 问题描述

所有并联传动类的 `TransformActuatorToJoint()` 在计算第二个执行器（roll 轴）的力矩时，错误地读取了 `state.velocity` 而非 `state.effort`。

#### 涉及文件

| 文件 | 行号 | 错误代码 |
|------|------|---------|
| [ankle_transmission.cc:135](../src/module/dcu_driver_module/src/ankle_transmission.cc#L135) | 135 | `double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;` |
| [ankle_transmission.cc:487](../src/module/dcu_driver_module/src/ankle_transmission.cc#L487) | 487 | `double taum6 = actr_right_.handle->state.velocity * actr_right_.direction;` |
| [wrist_transmission.cc:33](../src/module/dcu_driver_module/src/wrist_transmission.cc#L33) | 33 | `double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;` |
| [wrist_transmission.cc:90](../src/module/dcu_driver_module/src/wrist_transmission.cc#L90) | 90 | `double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;` |
| [lumbar_transmission.cc:27](../src/module/dcu_driver_module/src/lumbar_transmission.cc#L27) | 27 | `double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;` |

#### 修复方案

将所有 5 处 `state.velocity` 替换为 `state.effort`：

```cpp
// 错误
double taum6 = actr_left_.handle->state.velocity * actr_left_.direction;
// 修复
double taum6 = actr_left_.handle->state.effort * actr_left_.direction;
```

#### 影响范围分析

- **脚踝**：`tauj6`（roll 轴关节力矩）由 Jacobian 变换计算，其中 `taum6` 量纲错误（速度 rad/s 当力矩 N·m 用）。发布到 `/joint_states` 的 effort 字段错误。
- **腕部/腰部**：`joint_roll.state.effort` 直接被赋为速度值。
- **当前未暴露原因**：RL 控制器（`RLController`）的观测量仅使用 `/joint_states` 中的 `position` 和 `velocity` 字段，不使用 `effort`，因此该 bug 目前对控制输出无直接影响。若后续引入基于力矩的观测或保护逻辑，将产生问题。

---

### BUG-02：脚踝查表越界无保护

**严重程度**: 中（极端姿态下可能导致位置输出跳变为零）
**状态**: 待修复

#### 问题描述

脚踝并联传动在执行器角度超出查表范围时，仅向 `std::cout` 打印错误信息，不阻止后续计算，也不 clamp 输入。

查表范围：
- qm5：`[-1.4, 1.0]` rad
- qm6：`[-1.0, 1.4]` rad

#### 涉及文件

| 文件 | 行号 |
|------|------|
| [ankle_transmission.cc:92](../src/module/dcu_driver_module/src/ankle_transmission.cc#L92) | 越界检测（Left） |
| [ankle_transmission.cc:125](../src/module/dcu_driver_module/src/ankle_transmission.cc#L125) | 查表失败处理（Left） |
| [ankle_transmission.cc:448](../src/module/dcu_driver_module/src/ankle_transmission.cc#L448) | 越界检测（Right） |
| [ankle_transmission.cc:472](../src/module/dcu_driver_module/src/ankle_transmission.cc#L472) | 查表失败处理（Right） |

#### 越界时的实际行为

```
if (qm5_num_int < 0):
    std::cout << "qm5_num_int is error"   ← 仅打印，继续执行

if iter1 or iter2 not found:
    std::cout << "actuator_to_joint_data_ out of range"
    q5 = 0, q6 = 0                         ← 位置静默置零
    ← 后续 Jacobian 仍用这个 q5/q6 计算力矩和速度
```

#### 影响范围

- 超出范围时关节位置输出为 `0.0`（而非合理估计值），将导致 RL 控制器收到跳变的位置输入
- Jacobian 矩阵以 `q5=0, q6=0` 计算，可能导致力矩/速度变换异常

#### 修复方案

```
// 方案 A：clamp 输入（推荐，保持连续性）
qm5 = std::clamp(qm5, QM5_ANGLE_MIN, QM5_ANGLE_MAX - epsilon)
qm6 = std::clamp(qm6, QM6_ANGLE_MIN, QM6_ANGLE_MAX - epsilon)

// 方案 B：保持上次有效值（防抖）
if out_of_range: keep previous q5, q6
```

---

### BUG-03：并联传动奇异构型时分母为零，无 NaN/Inf 保护

**严重程度**: 高（会产生 NaN/Inf 并下发至执行器，可能导致硬件异常）
**状态**: 待修复

#### 问题描述

脚踝传动的 Jacobian 矩阵行列式（`f2b*f1a - f1b*f2a`）在机构奇异构型时趋近于零，会导致除零，产生 `NaN` 或 `Inf`。这些异常值随后会通过 `SetMitCmd()` 直接下发至执行器。

涉及的两处除法：
- 速度变换：`J.inverse()`（`Eigen::Matrix::inverse()` 对奇异矩阵不报错，返回未定义值）
- 力矩变换：手动计算的 Cramer 法则分母 `f2b*f1a - f1b*f2a`

#### 涉及文件

| 文件 | 行号 | 说明 |
|------|------|------|
| [ankle_transmission.cc:224](../src/module/dcu_driver_module/src/ankle_transmission.cc#L224) | Cramer 法则分母（Left, A→J） |
| [ankle_transmission.cc:390](../src/module/dcu_driver_module/src/ankle_transmission.cc#L390) | `J.inverse()`（Left, J→A），有注释掉的行列式检查 |
| [ankle_transmission.cc:573](../src/module/dcu_driver_module/src/ankle_transmission.cc#L573) | Cramer 法则分母（Right, A→J） |
| [ankle_transmission.cc:730](../src/module/dcu_driver_module/src/ankle_transmission.cc#L730) | `J.inverse()`（Right, J→A），同上 |

代码中存在被注释掉的行列式检查（`// if (determinant == 0)`），说明开发者曾意识到此问题但未完成实现。

#### 修复方案

```cpp
// 在 J.inverse() 前检查行列式
double det = J_T.determinant();
if (std::abs(det) < 1e-6) {
    // 保持上次速度输出或输出零
    return;
}
// 同样对 Cramer 法则分母做检查
```

---

## JoyStickModule

### BUG-04：手柄未连接或拔出时主循环越界访问

**严重程度**: 高（未定义行为，可能导致进程崩溃）
**状态**: 待修复

#### 问题描述

`Joy` 类在手柄未连接或被拔出时，会将 `joy_msg_.buttons` 和 `joy_msg_.axis` 清空为空 vector（`resize(0)`）。但 `JoyStickModule::MainLoop()` 在读取 `joy_data.buttons[button]` 时**不做边界检查**，直接用 YAML 配置中的固定索引（如 `buttons[7]`）访问。

两种触发场景：
1. **启动时无手柄**：`Joy` 构造完成，`joy_msg_` 中 buttons/axis 均为空 vector，`MainLoop` 立即越界
2. **运行时热拔出**：`handleJoyDeviceRemoved` 将 buttons/axis 清零，下一个主循环周期即越界

#### 涉及文件

| 文件 | 位置 | 说明 |
|------|------|------|
| [joy_stick_module.cc:108](../src/module/joy_stick_module/src/joy_stick_module.cc#L108) | `for auto button : float_pub.buttons` | 访问 `joy_data.buttons[button]`，无边界检查 |
| [joy_stick_module.cc:118](../src/module/joy_stick_module/src/joy_stick_module.cc#L118) | `for auto button : twist_pub.buttons` | 同上 |
| [joy_stick_module.cc:178](../src/module/joy_stick_module/src/joy_stick_module.cc#L178) | `for auto button : srv_client.buttons` | 同上 |
| [joy.cc:350](../src/module/joy_stick_module/src/joy.cc#L350) | `handleJoyDeviceRemoved` | `joy_msg_.buttons.resize(0)` |

#### 影响范围

- 访问空 vector 的任意索引为**未定义行为**，在多数平台上表现为段错误（SIGSEGV），进程崩溃
- 手柄拔出时整个推理进程退出，机器人失去控制（真机场景高危）

#### 修复方案

```
// 方案 A：在主循环中做防御性检查（最小改动）
if joy_data.buttons.empty() or joy_data.axis.empty():
    sleep_for(1000/freq_ ms)
    continue

// 方案 B：对每次索引访问做边界检查
if button < joy_data.buttons.size() and joy_data.buttons[button]:
    ...

// 方案 C：在 Joy 中维护"设备已连接"标志，GetJoyData 返回时附带连接状态
```

---

### BUG-05：速度限幅器状态在使能键松开后未重置

**严重程度**: 低（行为异常，不影响安全性）
**状态**: 待修复

#### 问题描述

`JoyVelLimiter` 内部维护积分状态 `state_`，每次 `update()` 在其基础上累加速度增量。当使能键（button[4]）松开时，主循环跳过限幅器调用，`state_` 保持上次的非零值。当使能键再次按下时，限幅器从非零状态继续积分，**第一个输出周期即为非零速度**，而操作者预期摇杆回中后速度应为零。

#### 复现条件

1. 按住 button[4] 并推动摇杆，发布非零速度
2. 松开 button[4]（速度停止发布）
3. 等待一段时间后再次按住 button[4]（摇杆在回中位置）
4. `/cmd_vel_limiter` 输出瞬间为非零（上次残留状态），而非预期的 0.0

#### 涉及文件

| 文件 | 位置 | 说明 |
|------|------|------|
| [joy_stick_module.cc:121](../src/module/joy_stick_module/src/joy_stick_module.cc#L121) | 使能键判断 | `if (ret && limiter_)` 为 false 时不调用 limiter，也不重置 |
| [joy_vel_limiter.cc:40](../src/module/joy_stick_module/src/joy_vel_limiter.cc#L40) | `reset()` | `state_.setZero()`，已有接口但未被调用 |

#### 修复方案

```
// 检测使能键从 "按下" 变为 "未按下" 的下降沿，调用 reset()
bool prev_enabled = false;
while run_flag_:
    ...
    bool cur_enabled = all(joy_data.buttons[btn] for btn in twist_pub.buttons)
    if prev_enabled and not cur_enabled:
        limiter_->reset()
    prev_enabled = cur_enabled
    ...
```

---

## SimModule

### BUG-06：模型加载失败后空指针解引用崩溃

**严重程度**: 高（进程崩溃，无法优雅失败）
**状态**: 待修复

#### 问题描述

`SimModule::Start()` 在渲染线程中调用 `mj_loadXML()` 加载 MJCF 模型。若加载失败（文件不存在、XML 格式错误等），`m_` 保持 `nullptr`。但随后主线程在检查 `d_`（而非 `m_`）后，继续访问 `m_->njnt` 遍历关节列表，触发空指针解引用。

#### 涉及文件

| 文件 | 行号 | 说明 |
|------|------|------|
| [sim_module.cc:51](../src/module/sim_module/src/sim_module.cc#L51) | `m_ = mj_loadXML(...)` | 返回 nullptr 时无错误返回 |
| [sim_module.cc:76](../src/module/sim_module/src/sim_module.cc#L76) | `for (int i = 0; i < m_->njnt; ++i)` | `m_` 为 nullptr 时崩溃 |

#### 错误路径

```
mj_loadXML() 失败 → m_ = nullptr, d_ = nullptr
  ↓
if (d_) → false
  sim_->LoadMessageClear()   ← 清除 loading 标签，正确
  （跳过 Load/forward/ctrl_noise 初始化）
  ↓
for (int i = 0; i < m_->njnt; ...)  ← 空指针解引用，SIGSEGV
```

#### 与 BUG-04 的区别

BUG-04 需要运行时手柄事件触发；本 bug 在配置文件路径错误时**启动即崩溃**，且崩溃发生在主线程，AimRT 框架无法捕获。

#### 修复方案

```cpp
// Start() 中，渲染线程完成后立即检查 m_
if (!m_) {
    AIMRT_ERROR("Failed to load MuJoCo model: {}", sim_->load_error);
    return false;
}
// 之后再继续访问 m_->njnt
```

---

### BUG-07：关节名不匹配时静默错误控制

**严重程度**: 中（无崩溃，但输出错误控制指令，难以排查）
**状态**: 待修复

#### 问题描述

`WriteMotorCmd()` 通过 `joint_state_index_map_` 将关节名映射到 `/joint_cmd` 中的索引。该映射使用 `std::unordered_map<std::string, int>`，当通过 `operator[]` 查询一个不存在的关节名时，会**自动插入默认值 `0`**，导致用 `cmd.position[0]`（第一个关节的指令）控制该关节，既无日志输出，也无异常。

#### 触发条件

- `/joint_cmd` 中缺少 SimModule 模型中的某个关节名（如 ControlModule 只发部分关节指令）
- 关节名拼写不一致（大小写、下划线等）

#### 涉及文件

| 文件 | 行号 | 说明 |
|------|------|------|
| [sim_module.cc:156](../src/module/sim_module/src/sim_module.cc#L156) | `int index = joint_state_index_map_[joint_names_[ii]]` | `operator[]` 对缺失 key 插入默认值 0 |

#### 错误行为示例

```
joint_names_ = ["lumbar_yaw", "lumbar_roll", ...]   // SimModule 模型中的关节
joint_cmd.name = ["lumbar_yaw", ...]                  // 缺少 "lumbar_roll"

joint_state_index_map_["lumbar_roll"]  → 不存在 → 插入 0 并返回 0
target_q_("lumbar_roll") = cmd.position[0]            // 实际用 lumbar_yaw 的指令！
```

#### 修复方案

```cpp
// 将 operator[] 替换为 find()，缺失时跳过或保持上次值
auto it = joint_state_index_map_.find(joint_names_[ii]);
if (it == joint_state_index_map_.end()) {
    AIMRT_WARN("Joint '{}' not found in cmd, skipping", joint_names_[ii]);
    continue;  // 或保持 target_q_(ii) 不变
}
int index = it->second;
```
