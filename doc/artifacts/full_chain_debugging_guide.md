# X1 机器人 — 电机控制全链路排查方法论

> **适用对象**：开发和调试人员
> **所属项目**：zhiyuan-x1-infer（致远 X1 人形机器人推理框架）
> **文档版本**：1.0

---

## 1. 方法论总览

当电机行为与控制指令不符时，采用 **"分层隔离 + 逐层验证"** 的系统化方法，结合软件日志和硬件测量手段，快速定位故障层。

### 1.1 全链路架构

```
┌───────────────────────────────────────────────────────────────────────┐
│  第6层  上层控制 (RL/PD Controller)                                    │
│         ControlModule::MainLoop() — 1kHz, high_resolution_clock       │
│         发布 /joint_cmd (无时间戳)                                     │
├───────────────────────── ROS2 ─────────────────────────────────────────┤
│  第5层  DCU 驱动模块 — 指令接收                                        │
│         DcuDriverModule::JointCmdCallback() — 事件驱动                 │
│         joint_data_space_ 缓存指令                                     │
├───────────────────────── Transmission ─────────────────────────────────┤
│  第4层  传动层变换                                                      │
│         TransmissionManager::TransformJointToActuator()                │
│         关节空间 → 执行器空间 (direction / 并联运动学)                   │
├───────────────────────── SDK API ──────────────────────────────────────┤
│  第3层  XyberController SDK                                            │
│         SetMitCmd() → MIT 编码 (MitFloatToUint, 8字节打包)             │
│         GetPosition/Velocity/Effort() ← MIT 解码                      │
├───────────────────────── EtherCAT ─────────────────────────────────────┤
│  第2层  EtherCAT 通信 (SOEM)                                           │
│         EthercatManager::WorkLoop() — 1kHz, DC PI 同步                 │
│         PDO 过程数据交换, WKC 校验                                      │
├───────────────────────── 硬件总线 ─────────────────────────────────────┤
│  第1层  DCU 板 — CANFD 转发                                            │
│         3路 CANFD 通道, DcuSendPacket / DcuRecvPacket                  │
├───────────────────────── 物理层 ───────────────────────────────────────┤
│  第0层  电机 (PowerFlow R86/R52/L28, OmniPicker)                       │
│         MIT 控制律: τ = τ_ff + kp(p_des - p) + kd(v_des - v)          │
└───────────────────────────────────────────────────────────────────────┘
```

### 1.2 排障核心原则

| 原则 | 说明 |
|---|---|
| **二分法** | 先在链路中部（Transmission 变换后）检查数据。确定问题在上半段还是下半段。 |
| **分层隔离** | 每次只验证一层，用该层的专属工具确认数据正确性。 |
| **先软后硬** | 优先用软件日志和 ROS2 工具排查。仅在软件排查无法定位时引入硬件探测。 |
| **先静后动** | 先检查配置正确性 → 再检查静态数据 → 最后观察动态行为。 |
| **对比法** | 用已知正常工作的关节/电机作为参照，与异常关节对比。 |

---

## 2. 典型案例：实时参数配置错误导致抖动

### 2.1 现象

在 `dcu_driver_module.cc` 中增加了启停命令循环发送逻辑（基于 MIT 参数），启停运行若干次后进入"一直转动"或"一直不转"的状态。

### 2.2 排查过程

| 步骤 | 方法 | 结果 |
|---|---|---|
| 1 | Wireshark 抓 EtherCAT 报文 | 可以看到所有报文，但未发现明显异常 |
| 2 | CAN 盒并联到电机 CAN 线抓包 | 可以看到 CAN 报文内容，但未直接定位根因 |
| 3 | 检查新程序的实时调度参数 | **发现实时参数配置错误，线程优先级/CPU 绑定不正确** |

### 2.3 根因分析

新增的启停循环逻辑没有正确设置实时调度参数（`rt_priority`、`bind_cpu`），导致：

```
正常情况: EtherCAT WorkLoop 以 1ms 严格周期运行，每周期刷新 PDO 数据
                ↓
异常: 新线程抢占了 EtherCAT 线程的 CPU 时间
                ↓
结果: EtherCAT 周期出现毫秒级抖动 → CAN 指令发送不均匀
                ↓
表现: 电机收到的指令出现间歇性丢帧，MIT 控制律执行异常
      → 若干次循环后累积误差，进入「一直转/一直不转」的锁定状态
```

### 2.4 经验教训

1. **实时参数必须正确**：任何与 EtherCAT 通信竞争 CPU 的线程都必须设置低于 EtherCAT 线程的优先级
2. **Wireshark 能看到报文但不容易发现抖动**：需要关注报文时间间隔的统计分布
3. **CAN 盒可以确认底层数据**，但问题若在更上层（线程调度），CAN 报文本身可能看起来"正常"
4. **环境权限也是关键**：实时调度需要 `sudo` 或 `CAP_SYS_NICE` 权限

---

## 3. 分层排查手册

### 第 0 层：物理层 & 环境检查

> 排查耗时：5 分钟。**每次排障的第一步。**

#### 软件检查

```bash
# 实时内核
uname -a                              # 确认含 PREEMPT_RT
cat /sys/kernel/realtime              # 应为 1

# 运行权限
whoami                                # 需要 root

# 网卡状态
ip link show enp2s0                   # state UP
sudo ethtool enp2s0                   # Speed: 100Mb/s, Link detected: yes

# CPU 隔离和实时调度
cat /proc/cmdline | grep isolcpus     # EtherCAT bind_cpu 是否被隔离
chrt -p $(pgrep -f aimrt)             # 进程调度策略

# 实时性基准测试
sudo cyclictest -m -p 90 -t 1 -i 1000 -D 10s
# 预期: Max latency < 100us。若 > 500us 说明实时性不足。
```

#### 硬件检查

| 检查项 | 方法 | 工具 |
|---|---|---|
| EtherCAT 网线物理连接 | 目视检查网线、水晶头、网口指示灯 | 无 |
| DCU 板供电和指示灯 | 确认 DCU 上电、状态灯正常 | 万用表 |
| CAN 线连接 | 检查 CTRL-1/2/3 接口和端子是否牢固 | 无 |
| 电机物理状态 | 手动转动电机确认无机械卡死 | 无 |
| 终端电阻 | CAN 总线末端是否有 120Ω 终端电阻 | 万用表 |

---

### 第 1 层：DCU 板 & CANFD 通信

> 排查手段：CAN 盒抓包 + 示波器

#### 硬件工具

| 工具 | 用途 | 接入方式 |
|---|---|---|
| **CAN 分析仪 / CAN 盒** | 捕获和解析 CAN 报文内容 | 并联到目标 CAN 通道 |
| **示波器**（双通道） | 观察 CAN-H / CAN-L 信号波形、时序 | 探头接 CAN-H 和 CAN-L |
| **逻辑分析仪** | 记录长时间 CAN 报文序列，分析时间间隔 | 并联到 CAN 信号线 |

#### CAN 盒使用方法

```
1. 确认目标电机的物理位置
    → 参考 doc/dcu_driver_module/hardware_arch.jpg 和 x1_id.jpg
    → 确定目标电机连接在哪个 DCU 的哪路 CANFD (CTRL-1/2/3)

2. 并联 CAN 盒
    → 将 CAN 盒的 CAN-H/CAN-L 并联到目标 CANFD 通道
    → 注意：不要断开原有连接，只是并联监听

3. 配置 CAN 盒
    → 波特率：匹配 CANFD 配置（通常 1Mbps 数据域可能更高）
    → 模式：仅监听（Listen-Only），不发送

4. 观察重点
    → 报文 ID 是否与配置的 can_id 匹配
    → 报文间隔是否均匀（~1ms）
    → 报文内容是否有异常（全 0、全 F、不变化）
```

#### 用 CAN 盒验证 MIT 指令编码

MIT 指令编码格式（对应 `power_flow.cpp` 中的 `SetMitCmd`）：

```
字节布局（8字节）:
  [0] pos[15:8]
  [1] pos[7:0]
  [2] vel[11:4]
  [3] vel[3:0] | kp[11:8]
  [4] kp[7:0]
  [5] kd[11:4]
  [6] kd[3:0] | toq[11:8]
  [7] toq[7:0]

解码公式:
  pos = uint16 → MitUintToFloat(pos, pos_min, pos_max, 16)
  vel = uint12 → MitUintToFloat(vel, vel_min, vel_max, 12)
  kp  = uint12 → MitUintToFloat(kp,  kp_min,  kp_max,  12)
  kd  = uint12 → MitUintToFloat(kd,  kd_min,  kd_max,  12)
  toq = uint12 → MitUintToFloat(toq, toq_min, toq_max, 12)
```

R86 参数范围：`pos ∈ [-2π, 2π], vel ∈ [-4π, 4π], toq ∈ [-100, 100], kp ∈ [0, 500], kd ∈ [0, 8]`

R52 参数范围：`pos ∈ [-2π, 2π], vel ∈ [-4π, 4π], toq ∈ [-50, 50], kp ∈ [0, 500], kd ∈ [0, 8]`

#### 示波器使用方法

```
用途：检查 CAN 总线信号质量和时序

1. 差分信号检查
    → CH1 接 CAN-H，CH2 接 CAN-L
    → CH1 - CH2 为差分信号
    → 正常隐性电平：CAN-H ≈ CAN-L ≈ 2.5V
    → 正常显性电平：CAN-H ≈ 3.5V, CAN-L ≈ 1.5V, 差值 ≈ 2V

2. 时序检查
    → 触发模式：边沿触发
    → 时基：500us/div（观察 1ms 周期内的报文分布）
    → 检查报文间隔是否均匀（重点!）

3. 信号质量检查
    → 是否有振铃、过冲（终端电阻问题）
    → 是否有信号衰减（线缆过长 / 分支过多）
    → 眼图分析（如果示波器支持）
```

---

### 第 2 层：EtherCAT 通信

> 排查手段：SDK 日志 + SOEM 工具 + Wireshark + 示波器

#### 软件工具

**1. SOEM slaveinfo（从站发现和状态查询）**

```bash
# 编译 (项目构建时通常已编译)
cd build && make slaveinfo

# 查看从站基本信息
sudo ./slaveinfo enp2s0

# 查看 SDO 字典
sudo ./slaveinfo enp2s0 -sdo

# 查看 PDO 映射
sudo ./slaveinfo enp2s0 -map
```

检查要点：从站数量、状态（OP=8）、IO 大小、DC 支持。

**2. SDK 日志（直接输出到 stdout）**

```bash
# 启动程序并保存日志
sudo ./run_x1.sh 2>&1 | tee ecat_debug.log

# 事后分析
grep "wkc" ecat_debug.log                     # WKC 异常（通信丢帧）
grep "\[ERROR\]" ecat_debug.log                # 错误
grep "Ecat link" ecat_debug.log                # 总线断连/恢复
grep "SAFE_OP\|lost\|reconfigured" ecat_debug.log  # 从站掉线
```

**3. Wireshark（EtherCAT 报文捕获和解码）**

```bash
# 捕获 EtherCAT 报文（需要 root）
sudo tcpdump -i enp2s0 -w ecat_capture.pcap ether proto 0x88a4

# 或直接用 Wireshark GUI
sudo wireshark -i enp2s0 -f "ether proto 0x88a4"
```

Wireshark 分析技巧：

| 分析项 | Wireshark 操作 | 正常值 |
|---|---|---|
| 报文间隔 | Statistics → I/O Graph（1ms 分辨率） | 稳定 1ms 间隔 |
| **时间间隔抖动** | Statistics → I/O Graph → 切换为 MAX/MIN | MAX-MIN < 0.5ms |
| 帧丢失 | 检查 WKC 字段 | WKC 始终等于 expected_wkc |
| 数据帧大小 | 检查 EtherCAT datagram length | 固定值 |
| DC 时钟 | 过滤 DC Sync 报文 | 周期性出现 |

**Wireshark 抓抖动的关键技巧**：

```
问题：之前用 Wireshark 抓包"看到所有报文但没发现抖动"

原因：仅看报文"存在"不够，需要分析报文间的**时间间隔分布**

正确方法：
1. 捕获足够长的数据（至少 10 秒）
2. 导出为 CSV: File → Export Packet Dissections → As CSV
3. 用 Python 分析时间间隔:

   import pandas as pd
   df = pd.read_csv('ecat.csv')
   df['dt'] = df['Time'].diff() * 1000  # ms
   print(f"平均: {df['dt'].mean():.3f} ms")
   print(f"标准差: {df['dt'].std():.3f} ms")
   print(f"最大值: {df['dt'].max():.3f} ms")
   print(f"最小值: {df['dt'].min():.3f} ms")

   # 找到异常间隔
   abnormal = df[df['dt'] > 1.5]  # 超过 1.5ms 就是异常
   print(f"异常帧数: {len(abnormal)}")

4. 或用 Wireshark 的 tshark CLI:
   tshark -r ecat.pcap -T fields -e frame.time_delta_displayed \
       | awk '{print $1*1000}' | sort -n | tail -20
```

#### 硬件工具

| 工具 | 用途 | 方法 |
|---|---|---|
| **网络 TAP（分路器）** | 无损抓取 EtherCAT 报文 | 串联在主站和 DCU 之间 |
| **示波器** | 检查 EtherCAT 物理层信号 | 100BASE-TX 差分信号探测 |

---

### 第 3 层：XyberController SDK

> 排查手段：SDK 日志 + Example 程序独立测试

#### 独立测试（最重要的隔离手段）

修改并使用 `xyber_controller/example/main.cpp`，**绕过整个 AimRT 和 ROS2 框架**，直接测试单个电机：

```cpp
// 最小化测试：读取电机状态
auto state = controller->GetPowerState("motor_name");  // 应为 STATE_ENABLE(1)
auto mode = controller->GetMode("motor_name");          // 应为 MODE_MIT(6)
auto pos = controller->GetPosition("motor_name");
auto vel = controller->GetVelocity("motor_name");
auto eff = controller->GetEffort("motor_name");
auto temp = controller->GetTempure("motor_name");

printf("state=%d mode=%d pos=%.3f vel=%.3f eff=%.3f temp=%.1f\n",
       state, mode, pos, vel, eff, temp);

// 最小化测试：发送零力矩指令（电机应静止或自由转动）
controller->SetMitCmd("motor_name", pos, 0, 0, 0, 0);  // 纯前馈=0，kp=kd=0
```

如果 Example 能正常工作但整体系统不行 → **问题在第 4~6 层**。

#### 排查要点

| 检查项 | API | 正常值 |
|---|---|---|
| 电机使能状态 | `GetPowerState()` | `STATE_ENABLE` (1) |
| 控制模式 | `GetMode()` | `MODE_MIT` (6) |
| 位置是否更新 | `GetPosition()` 连续调用 | 值在变化（即使微小） |
| 温度 | `GetTempure()` | < 80°C（过温保护阈值因型号而异） |
| MIT 参数范围 | 检查 `MitParam` 配置 | 指令值不超出 min/max |

---

### 第 4 层：传动层 (Transmission)

> 排查手段：开启 `actuator_debug` 模式

#### 方法

在 `dcu_x1.yaml` 中设置：

```yaml
actuator_debug: true
```

然后对比：

```bash
# 终端 1：关节空间指令
ros2 topic echo /joint_cmd

# 终端 2：经过 Transmission 变换后的执行器指令
ros2 topic echo /actuator_cmd

# 终端 3：执行器原始状态反馈
ros2 topic echo /actuator_states

# 终端 4：关节空间状态（Transmission 逆变换后）
ros2 topic echo /joint_states
```

#### 检查要点

| 比对项 | 正常情况 | 异常情况和原因 |
|---|---|---|
| `/joint_cmd.position[i]` vs `/actuator_cmd.position[i]` | 数值符号翻转或一致（取决于 direction） | direction 配错 (±1) |
| 并联关节的两个执行器指令 | 两个电机有合理的不同值 | 查找表越界 / 逆运动学 NaN |
| `/actuator_states.position[i]` 是否更新 | 持续变化 | 全 0 或不变 → EtherCAT 数据未到达 |
| 关节名在指令结果中 | 所有名称都存在 | 缺失 → 检查 YAML joint_list/actuator_list |

---

### 第 5 层：ROS2 消息与时序

> 排查手段：ROS2 CLI + 录包分析

#### 频率和延迟

```bash
ros2 topic hz /joint_states -w 100     # 预期 ~1000 Hz
ros2 topic hz /joint_cmd -w 100        # 预期 ~1000 Hz
ros2 topic delay /joint_states         # 时间戳 vs 接收时间
ros2 topic bw /joint_states            # 带宽
```

#### 录包与离线分析

```bash
# 录制 10 秒全量数据
ros2 bag record /joint_states /joint_cmd /imu/data \
    /actuator_cmd /actuator_states -o debug_bag -d 10

# Python 分析脚本（时间戳连续性、指令-状态延迟）
```

```python
#!/usr/bin/env python3
"""分析 /joint_states 时间戳抖动和端到端延迟"""
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import JointState
import time, statistics

class TimingAnalyzer(Node):
    def __init__(self):
        super().__init__('timing_analyzer')
        self.stamps = []
        self.delays = []
        self.sub = self.create_subscription(
            JointState, '/joint_states', self.cb, 10)

    def cb(self, msg):
        now = time.time()
        stamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        self.stamps.append(stamp)
        self.delays.append((now - stamp) * 1000)  # ms

        if len(self.stamps) >= 1001:
            dts = [(self.stamps[i] - self.stamps[i-1]) * 1000
                   for i in range(1, len(self.stamps))]
            print(f"\n=== 时序统计 ({len(dts)} 帧) ===")
            print(f"帧间隔: 均值={statistics.mean(dts):.3f}ms "
                  f"标准差={statistics.stdev(dts):.3f}ms "
                  f"最大={max(dts):.3f}ms 最小={min(dts):.3f}ms")
            print(f"传输延迟: 均值={statistics.mean(self.delays):.3f}ms "
                  f"最大={max(self.delays):.3f}ms")
            jitter_count = sum(1 for dt in dts if abs(dt - 1.0) > 0.5)
            print(f"抖动异常帧 (>0.5ms偏离): {jitter_count}/{len(dts)}")
            self.stamps.clear()
            self.delays.clear()

rclpy.init()
rclpy.spin(TimingAnalyzer())
```

---

### 第 6 层：上层控制逻辑

> 排查手段：日志 + 数据录制

```bash
# 检查 /joint_cmd 内容是否合理
ros2 topic echo /joint_cmd --once

# 检查关键指标
# kp, kd 是否为 0（会导致电机无力矩）
# position 是否为 NaN 或 Inf
# effort 是否超出电机范围
```

---

## 4. 时序专项排查

### 4.1 时序关键路径

```
    各环节独立定时器，无全局同步:

    EtherCAT WorkLoop   PublishLoop   ControlModule MainLoop
    ┌──┐ ┌──┐ ┌──┐    ┌──┐ ┌──┐     ┌──┐ ┌──┐ ┌──┐
    │  │ │  │ │  │    │  │ │  │     │  │ │  │ │  │
    └──┘ └──┘ └──┘    └──┘ └──┘     └──┘ └──┘ └──┘
    ← 1ms →           ← 1ms →       ← 1ms →
    (DC PI同步)       (steady_clock) (high_res_clock)

    三个 1kHz 循环各自独立，存在相位漂移
```

### 4.2 实时性排查决策树

```
线程调度抖动?
├── cyclictest max_latency > 100us?
│   ├── 是 → 实时内核问题
│   │   ├── uname -a 没有 PREEMPT_RT → 安装实时内核
│   │   └── 有 PREEMPT_RT → 检查 isolcpus，检查是否有其他高优线程
│   └── 否 → 进一步检查
│
├── EtherCAT WorkLoop 是否设置了正确的实时参数？
│   ├── rt_priority: 90  (足够高)
│   ├── bind_cpu: 9       (与其他线程隔离)
│   └── ★ 新增的线程是否也竞争了同一个 CPU 核心或使用了更高的优先级？
│       → 这是实时参数配置错误的典型根因
│
├── 是否以 root 权限运行？
│   └── 非 root → 实时调度设置会静默失败
│
└── 是否有后台进程抢占 CPU？
    ├── top / htop 查看 CPU 使用率
    └── stress-ng 压测验证
```

### 4.3 实时参数配置检查清单

```yaml
# dcu_x1.yaml — EtherCAT 线程
ethercat:
  bind_cpu: 9            # ← 必须与其他线程隔离
  rt_priority: 90        # ← 应为系统最高优先级

# 自定义线程（如启停循环）必须满足：
# 1. rt_priority < 90 (低于 EtherCAT 线程)
# 2. bind_cpu ≠ 9 (不与 EtherCAT 线程竞争)
# 3. 以 root 运行或有 CAP_SYS_NICE 权限
```

验证代码：

```cpp
// 检查当前线程的实时参数
struct sched_param param;
int policy;
pthread_getschedparam(pthread_self(), &policy, &param);
printf("Policy: %s, Priority: %d\n",
       policy == SCHED_FIFO ? "FIFO" :
       policy == SCHED_RR ? "RR" : "OTHER",
       param.sched_priority);

// 检查绑核
cpu_set_t cpuset;
pthread_getaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);
for (int i = 0; i < CPU_SETSIZE; i++) {
    if (CPU_ISSET(i, &cpuset)) printf("Bound to CPU %d\n", i);
}
```

---

## 5. 快速定位决策树

```
电机行为异常
│
├─ [静态检查] 配置和环境是否正确？
│  ├── 实时内核? uname -a → PREEMPT_RT
│  ├── Root 权限? whoami → root
│  ├── 网卡 UP? ip link show enp2s0
│  ├── YAML 配置? 检查 dcu_x1.yaml 中 dcu_network / transmission
│  └── ★ 所有线程的实时参数? rt_priority、bind_cpu 不冲突
│
├─ [通信检查] EtherCAT 是否正常？
│  ├── slaveinfo → 从站数量和状态
│  ├── SDK 日志 → WKC 错误
│  └── Wireshark → 报文间隔分布（不要只看"有没有报文"）
│
├─ [数据检查] 数据是否正确？
│  ├── actuator_debug: true → /actuator_cmd 和 /actuator_states
│  ├── 对比 /joint_cmd 和 /actuator_cmd → Transmission 正确性
│  ├── GetMode() == 6 (MIT)? GetPowerState() == 1 (ENABLE)?
│  └── CAN 盒抓包 → 解码 MIT 8 字节指令确认编码正确
│
├─ [时序检查] 时序是否正常？
│  ├── ros2 topic hz → 频率是否稳定
│  ├── cyclictest → 系统实时性基准
│  ├── 代码插桩 → 循环耗时监控
│  └── Wireshark → 报文间隔统计分析（均值/标准差/最大值）
│
└─ [独立测试] SDK Example 绕过上层直接控制电机
   ├── 能正常控制 → 问题在上层 (Transmission / ROS2 / 控制模块)
   └── 不能正常控制 → 问题在底层 (EtherCAT / DCU / CAN / 电机)
```

---

## 6. 工具箱速查表

### 6.1 软件工具

| 工具 | 层级 | 用途 | 命令 |
|---|---|---|---|
| `cyclictest` | 第0层 | 系统实时性基准测试 | `sudo cyclictest -m -p 90 -i 1000 -D 10s` |
| `slaveinfo` | 第2层 | EtherCAT 从站发现 | `sudo ./slaveinfo enp2s0` |
| SDK Example | 第3层 | 独立电机测试 | 修改 `example/main.cpp` 编译运行 |
| `actuator_debug` | 第4层 | 查看执行器数据 | YAML 中设 `actuator_debug: true` |
| `ros2 topic hz` | 第5层 | 频率检测 | `ros2 topic hz /joint_states` |
| `ros2 topic delay` | 第5层 | 延迟检测 | `ros2 topic delay /joint_states` |
| `ros2 bag record` | 第5层 | 数据录制 | `ros2 bag record /joint_states /joint_cmd` |
| Wireshark | 第2层 | 报文分析 | `sudo wireshark -i enp2s0` |
| AIMRT 日志 | 第5/6层 | 模块级日志 | `tail -f ./log/x1_rl_ctrl.log` |
| SDK 日志 | 第2/3层 | 底层通信日志 | 程序 stdout，`grep "[ERROR]"` |

### 6.2 硬件工具

| 工具 | 层级 | 用途 | 接入方式 |
|---|---|---|---|
| **CAN 分析仪** | 第1层 | 抓取/解码 CAN 报文 | 并联到 DCU CANFD 通道 |
| **示波器** | 第1/2层 | 信号质量、时序波形 | 探头接 CAN-H/L 或 EtherCAT 差分 |
| **逻辑分析仪** | 第1层 | 长时间 CAN 时序记录 | 并联到 CAN 信号线 |
| **网络 TAP** | 第2层 | 无损 EtherCAT 报文捕获 | 串联在主站和 DCU 之间 |
| **万用表** | 第0/1层 | 电压、终端电阻检查 | 测量 CAN 总线电阻和 DCU 供电 |
| **信号发生器** | 第1层 | 注入特定 CAN 报文测试 | 替代主站发送测试帧 |

---

## 7. 预防措施

### 7.1 代码开发规范

```
1. 任何新增线程必须声明实时参数：
   - 明确设置 rt_priority（且低于 EtherCAT 线程的 90）
   - 明确设置 bind_cpu（且不与 EtherCAT 线程的绑核冲突）
   - 使用 xyber_utils::SetRealTimeThread() 统一API

2. 新增定时循环必须加入抖动监控日志

3. 修改 EtherCAT 相关代码后必须做 cyclictest 回归测试
```

### 7.2 上线前检查清单

- [ ] `cyclictest` 最大延迟 < 100us
- [ ] `slaveinfo` 所有从站 OP 状态
- [ ] `ros2 topic hz /joint_states` 稳定 1kHz
- [ ] `actuator_debug` 模式下 `/actuator_cmd` 数据正确
- [ ] 所有自定义线程的 `rt_priority` 和 `bind_cpu` 已验证
- [ ] 以 `root` 权限运行
