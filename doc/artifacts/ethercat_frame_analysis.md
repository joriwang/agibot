# EtherCAT 帧结构分析（基于 dcu_driver_module 源码）

本文档基于 `src/module/dcu_driver_module` 及其 `xyber_controller` 子项目的源码，分析从以太网帧到应用层执行器指令的完整 EtherCAT 帧结构。**可作为上下文直接用于分析 Wireshark / tcpdump 抓包字节流**。

---

## 1. 总体协议栈（由外到内）

```
┌────────────────────────────────────────────────────────────┐
│ Layer 1: Ethernet II 帧头 (14 bytes)                       │
├────────────────────────────────────────────────────────────┤
│ Layer 2: EtherCAT 帧头 (2 bytes)                           │
├────────────────────────────────────────────────────────────┤
│ Layer 3: EtherCAT Datagram(s)                              │
│   ├─ Datagram 头 (10 bytes)                                │
│   ├─ PDO 数据区 (N bytes) ← 业务负载                        │
│   └─ WKC (2 bytes)                                         │
│   └─ [可选：更多 Datagram …]                                │
├────────────────────────────────────────────────────────────┤
│ Layer 4: FCS (4 bytes, 由网卡自动处理)                       │
└────────────────────────────────────────────────────────────┘
```

> [!IMPORTANT]
> 在正常的 OP 态周期性 PDO 通信中，SOEM 使用 **LRW (Logical Read Write)** 命令，一个 LRW datagram 同时完成对所有从站的过程数据读写。PDO 数据区即 `DcuSendPacket`（输出）和 `DcuRecvPacket`（输入）。

---

## 2. Layer 1: Ethernet II 帧头（14 bytes）

源码：[ethercattype.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/third_party/soem/soem/ethercattype.h#L90-L100)

```c
typedef struct PACKED {
   uint16  da0, da1, da2;  // 目标 MAC (6 bytes)
   uint16  sa0, sa1, sa2;  // 源 MAC (6 bytes)
   uint16  etype;          // EtherType (2 bytes) = 0x88A4
} ec_etherheadert;
```

| 偏移 (byte) | 长度 | 字段 | 说明 |
|:---:|:---:|:---|:---|
| 0–5 | 6 | Destination MAC | 通常为 `ff:ff:ff:ff:ff:ff`（广播）或从站 MAC |
| 6–11 | 6 | Source MAC | 主站网卡 MAC |
| 12–13 | 2 | EtherType | **`0x88A4`** = EtherCAT 协议标识 |

> [!TIP]
> 在 Wireshark 中可通过过滤 `eth.type == 0x88a4` 或 `ecat` 来定位 EtherCAT 帧。

---

## 3. Layer 2: EtherCAT 帧头（2 bytes）

EtherCAT 帧头紧跟在 Ethernet 帧头之后，即偏移 14–15 字节处。它是 `ec_comt` 结构的 `elength` 字段：

| 偏移 | 长度 | 字段 | 各 bit 含义 |
|:---:|:---:|:---|:---|
| 14–15 | 2 | `elength` | bit[10:0] = EtherCAT 数据总长度（不含帧头自身的 2 字节）；bit[15:12] = 协议类型（固定为 `0x1` = EtherCAT Commands） |

实际抓包中，此字段的**高 4 位**通常为 `0x1`，即 `elength` 的原始值形如 `0x10xx`。

---

## 4. Layer 3: EtherCAT Datagram 头（10 bytes）

源码：[ethercattype.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/third_party/soem/soem/ethercattype.h#L106-L124)

```c
typedef struct PACKED {
   uint8   command;   // EtherCAT 命令类型
   uint8   index;     // SOEM 内部索引
   uint16  ADP;       // 地址字段 1
   uint16  ADO;       // 地址字段 2
   uint16  dlength;   // 数据部分长度 + M flag
   uint16  irpt;      // 中断（通常未使用 = 0x0000）
} // 注：elength 已在上一层处理
```

| 偏移 (相对 datagram 起始) | 长度 | 字段 | 说明 |
|:---:|:---:|:---|:---|
| 0 | 1 | `command` | 命令类型，见下表 |
| 1 | 1 | `index` | SOEM 帧索引，用于 Tx/Rx 匹配 |
| 2–3 | 2 | `ADP` | 自动增量地址 / 配置地址（取决于命令类型） |
| 4–5 | 2 | `ADO` | 物理内存偏移 / 逻辑地址偏移 |
| 6–7 | 2 | `dlength` | bit[10:0] = 数据长度；**bit[15] = M（More）标志**（1=后面还有 datagram） |
| 8–9 | 2 | `irpt` | 中断位，通常为 `0x0000` |

### 常用命令类型（`command` 字段）

| 值 | 名称 | 说明 |
|:---:|:---|:---|
| `0x00` | NOP | 无操作 |
| `0x01` | APRD | 自动增量读 |
| `0x02` | APWR | 自动增量写 |
| `0x04` | FPRD | 配置地址读 |
| `0x05` | FPWR | 配置地址写 |
| `0x07` | BRD | 广播读 |
| `0x08` | BWR | 广播写 |
| **`0x0C`** | **LRW** | **逻辑内存读写 ← 正常 OP 态 PDO 通信的主要命令** |
| `0x0A` | LRD | 逻辑内存读 |
| `0x0B` | LWR | 逻辑内存写 |

> [!IMPORTANT]
> **周期性 PDO 交换使用 LRW (0x0C) 命令**。此时 ADP+ADO 组合成 32 位逻辑地址，指向 FMMU/SM 映射的 IO 空间。

### Datagram 尾部

紧跟数据区之后是 **WKC (Working Counter)**，2 bytes。每个从站成功处理后会递增 WKC。

---

## 5. PDO 数据区：DCU 帧结构（应用层核心）

每个 DCU 从站在 IO Map 中占有固定大小的输入/输出过程映像。DCU 的 PDO 映射由 SOEM `ec_config_map()` 在初始化时配置。

源码：[dcu.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/dcu.h#L21-L42)

### 5.1 DcuSendPacket — 主站 → 从站（输出 PDO, 240 bytes）

```c
#pragma pack(1)
struct DcuSendPacket {   // 总计 240 bytes
  struct {
    uint8_t ctrl;         //  1 byte:  通道控制字
    uint8_t data[64];     // 64 bytes: CAN-FD 数据域
  } canfd[3];            // × 3 通道 = 3 × 65 = 195 bytes
  uint8_t imu_cmd;       //  1 byte:  IMU 命令
  uint8_t reserved[44];  // 44 bytes: 保留对齐
};
```

**字节级布局**：

| 偏移 (byte) | 长度 | 字段 | 说明 |
|:---:|:---:|:---|:---|
| **0** | **1** | `canfd[0].ctrl` | **通道 1 控制字（选择执行器）** |
| 1–64 | 64 | `canfd[0].data` | 通道 1 CAN-FD 数据区（最多 8 个执行器 × 8 字节） |
| **65** | **1** | `canfd[1].ctrl` | **通道 2 控制字** |
| 66–129 | 64 | `canfd[1].data` | 通道 2 CAN-FD 数据区 |
| **130** | **1** | `canfd[2].ctrl` | **通道 3 控制字** |
| 131–194 | 64 | `canfd[2].data` | 通道 3 CAN-FD 数据区 |
| **195** | **1** | `imu_cmd` | IMU 命令（0=无操作, 1=应用偏置校准） |
| 196–239 | 44 | `reserved` | 保留，全 0 |

#### `ctrl` 控制字解析

源码：[dcu.cpp](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/src/dcu.cpp#L74-L76)

```c
void Dcu::SetChannelId(CtrlChannel ch, uint8_t id) {
  send_buf_.canfd[(int)ch].ctrl = id == 0xFF ? id : 1 << (id - 1);
}
```

| ctrl 值 | 含义 |
|:---:|:---|
| `0xFF` | **广播模式**：该通道所有执行器同时接收（用于 MIT 模式批量指令） |
| `0x01` | 选中 CAN ID=1 的执行器 |
| `0x02` | 选中 CAN ID=2 的执行器 |
| `0x04` | 选中 CAN ID=3 的执行器 |
| ... | 以此类推，每个 bit 对应一个 CAN ID |

### 5.2 DcuRecvPacket — 从站 → 主站（输入 PDO, 240 bytes）

```c
#pragma pack(1)
struct DcuRecvPacket {   // 总计 240 bytes
  uint8_t canfd[3][64]; // 3 通道 × 64 bytes = 192 bytes
  struct {
    uint32_t acc[3];     // 加速度 (3 × 4 = 12 bytes)
    uint32_t gyro[3];    // 陀螺仪 (3 × 4 = 12 bytes)
    uint32_t quat[4];    // 四元数 (4 × 4 = 16 bytes)
  } imu;                // IMU 数据，共 40 bytes
  uint8_t reserved[8];  //  8 bytes 保留
};
```

**字节级布局**：

| 偏移 (byte) | 长度 | 字段 | 说明 |
|:---:|:---:|:---|:---|
| 0–63 | 64 | `canfd[0]` | 通道 1 执行器反馈数据 |
| 64–127 | 64 | `canfd[1]` | 通道 2 执行器反馈数据 |
| 128–191 | 64 | `canfd[2]` | 通道 3 执行器反馈数据 |
| 192–203 | 12 | `imu.acc[3]` | 加速度 X/Y/Z，每个 4 字节（IEEE 754 float，**大端序**） |
| 204–215 | 12 | `imu.gyro[3]` | 陀螺仪 X/Y/Z，每个 4 字节（IEEE 754 float，大端序） |
| 216–231 | 16 | `imu.quat[4]` | 四元数 W/X/Y/Z，每个 4 字节（IEEE 754 float，大端序） |
| 232–239 | 8 | `reserved` | 保留 |

> [!WARNING]
> IMU 数据使用**大端序（Big-Endian）**存储！源码注释 `// TODO: imu data in buf is big endian`。需用 `BytesToFloat()` 做字节序转换后才能正确读取 float 值。

---

## 6. 执行器帧结构（8 bytes / 每执行器）

每个通道的 64 字节 CAN-FD 数据区可容纳最多 **8 个执行器**，每个执行器占 **8 字节**，按 CAN ID 顺序排列。

源码：[actuator_base.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/actuator_base.h#L30-L33)

```c
#define ACTUATOR_FRAME_SIZE 8

send_buf_ = send + ACTUATOR_FRAME_SIZE * (id_ - 1);
recv_buf_ = recv + ACTUATOR_FRAME_SIZE * (id_ - 1);
```

即：通道数据区内，CAN ID `n` 的执行器数据位于偏移 `(n-1) × 8` 处。

### 6.1 PowerFlow R86/R52 — MIT 模式发送帧（8 bytes）

源码：[power_flow.cpp → SetMitCmd()](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/src/power_flow.cpp#L94-L109)

MIT 模式下，8 字节被编码为 5 个紧密排列的位域（总计 64 bits）：

```
位域编码（大端序排列，高位在前）：

Byte[0]  Byte[1]  Byte[2]  Byte[3]  Byte[4]  Byte[5]  Byte[6]  Byte[7]
PPPPPPPP PPPPPPPP VVVVVVVV VVVVkkkk kkkkkkkk dddddddd DDDDtttt tttttttt

P = pos  (16 bit)
V = vel  (12 bit)
k = kp   (12 bit)
d = kd   (12 bit) ← 注意代码中先放 kd 再放 tor
t = tor  (12 bit)
```

**逐字节解析**：

| Byte | bit 范围 | 字段 | 描述 |
|:---:|:---|:---|:---|
| `[0]` | 全 8 bit | `pos[15:8]` | 位置高 8 位 |
| `[1]` | 全 8 bit | `pos[7:0]` | 位置低 8 位 |
| `[2]` | 全 8 bit | `vel[11:4]` | 速度高 8 位 |
| `[3]` | bit[7:4] | `vel[3:0]` | 速度低 4 位 |
| `[3]` | bit[3:0] | `kp[11:8]` | Kp 高 4 位 |
| `[4]` | 全 8 bit | `kp[7:0]` | Kp 低 8 位 |
| `[5]` | 全 8 bit | `kd[11:4]` | Kd 高 8 位 |
| `[6]` | bit[7:4] | `kd[3:0]` | Kd 低 4 位 |
| `[6]` | bit[3:0] | `tor[11:8]` | 力矩高 4 位 |
| `[7]` | 全 8 bit | `tor[7:0]` | 力矩低 8 位 |

**值域映射（量化公式）**：

```
uint_value = (float_value - float_min) / (float_max - float_min) × (2^bits - 1)
```

| 参数 | 量化位数 | R86 范围 | R52 范围 |
|:---:|:---:|:---|:---|
| pos | 16 bit | [-2π, +2π] | [-2π, +2π] |
| vel | 12 bit | [-4π, +4π] | [-4π, +4π] |
| kp | 12 bit | [0, 500] | [0, 500] |
| kd | 12 bit | [0, 8] | [0, 8] |
| tor | 12 bit | [-100, +100] | [-50, +50] |

### 6.2 PowerFlow R86/R52 — 非 MIT 模式发送帧（命令帧）

非 MIT 模式（如使用 `SetPosition` / `SetVelocity` / `SetEffort`）时，帧格式为：

| Byte | 字段 | 说明 |
|:---:|:---|:---|
| `[0]` | `cmd` | 命令码（见下表） |
| `[1–4]` | `float value` | IEEE 754 float（小端序） |
| `[5–7]` | 未使用 | — |

**常见命令码**：

| 值 | 枚举名 | 含义 |
|:---:|:---|:---|
| `0x01` | CMD_REQUEST_STATE | 请求使能/失能（byte[1]=状态值） |
| `0x02` | CMD_CLEAR_ERROR | 清除错误 |
| `0x03` | CMD_SET_HOMING_POSITON | 设置零位 |
| `0x0B` | CMD_SET_MODE | 设置运行模式（byte[1]=模式值） |
| `0x65` | CMD_SET_POS | 设置位置 |
| `0x66` | CMD_SET_VEL | 设置速度 |
| `0x67` | CMD_SET_CUR | 设置电流 |
| `0xCC` | CMD_SAVE_CONFIG | 保存配置（byte[1]=123 魔数） |

### 6.3 PowerFlow R86/R52 — 状态反馈帧（8 bytes）

源码：[power_flow.h → StateData](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/power_flow.h#L88-L97)

```c
#pragma pack(1)
struct StateData {
  uint16_t pos;            // 16 bit 位置
  uint32_t vel : 12;       // 12 bit 速度
  uint32_t cur : 12;       // 12 bit 电流（力矩）
  uint32_t heartbeat : 1;  //  1 bit 心跳
  uint32_t state : 3;      //  3 bit 状态
  uint32_t error : 4;      //  4 bit 错误码
  uint16_t temp;           // 16 bit 温度
};
```

**逐字节解析**：

| Byte | bit 范围 | 字段 | 描述 |
|:---:|:---|:---|:---|
| `[0]` | 全 8 bit | `pos[15:8]` | 位置高字节 |
| `[1]` | 全 8 bit | `pos[7:0]` | 位置低字节 |
| `[2]` | 全 8 bit | `vel[11:4]` | 速度高 8 位 |
| `[3]` | bit[7:4] | `vel[3:0]` | 速度低 4 位 |
| `[3]` | bit[3:0] | `cur[11:8]` | 电流高 4 位 |
| `[4]` | 全 8 bit | `cur[7:0]` | 电流低 8 位 |
| `[5]` | bit[7] | `heartbeat` | 心跳标志 |
| `[5]` | bit[6:4] | `state` | 执行器状态（0=Disable, 1=Enable, 2=Calibration） |
| `[5]` | bit[3:0] | `error` | 4 位错误码 |
| `[6–7]` | 16 bit | `temp` | 温度值 |

> [!NOTE]
> 位置和速度的解码使用与 MIT 发送帧相同的 `MitUintToFloat()` 量化逆映射公式：`float_value = uint_value × span / (2^bits - 1) + offset`

### 6.4 PowerFlow L28 — 数据帧（8 bytes）

L28 类型执行器使用更简单的帧格式（收发格式相同）：

```c
struct L28Data {
  float pos = 0;  // 4 bytes IEEE 754 float 位置
  float cur = 0;  // 4 bytes IEEE 754 float 电流
};
```

| Byte | 长度 | 字段 |
|:---:|:---:|:---|
| `[0–3]` | 4 | 位置（float, 小端序） |
| `[4–7]` | 4 | 电流（float, 小端序） |

---

## 7. 多从站 IO Map 布局

本系统有 **2 个 DCU 从站**（来自 `dcu_x1.yaml` 配置）：

| EtherCAT Slave ID | DCU 名称 | 功能 |
|:---:|:---|:---|
| 1 | `body` | 上肢 + 腰部（CH1: 左臂 8 个, CH2: 右臂 8 个, CH3: 腰部 2 个） |
| 2 | `hip` | 下肢（CH1: 左腿 6 个, CH2: 右腿 6 个, CH3: 腰偏航 1 个），含 IMU |

SOEM `ec_config_map(io_map_)` 将所有从站的 PDO 映射到 **一整块连续的 IO Map 缓冲区**（最大 4096 bytes）：

```
io_map_[4096] 
├── Slave 1 Output (DcuSendPacket, 240 bytes) ← ec_slave[1].outputs
├── Slave 2 Output (DcuSendPacket, 240 bytes) ← ec_slave[2].outputs
├── Slave 1 Input  (DcuRecvPacket, 240 bytes) ← ec_slave[1].inputs
└── Slave 2 Input  (DcuRecvPacket, 240 bytes) ← ec_slave[2].inputs
```

> [!NOTE]
> 输出和输入的具体排列顺序取决于 SOEM 的 `ec_config_map()` 实现——通常先所有输出再所有输入，但也可能交错。Wireshark 中在 LRW datagram 的数据区可以看到这些连续的 PDO 数据。

在 Wireshark 的 LRW datagram 中，**数据区长度** = 所有从站的 Output + Input 总和 = 2 × 240 + 2 × 240 = **960 bytes**。

---

## 8. 完整帧一览（OP 态周期 PDO）

```
一个完整的 EtherCAT 以太网帧（OP 态 PDO）:

[ Ethernet Header (14B) ][ EtherCAT Header (2B) ][ LRW Datagram ][ FCS (4B) ]

→ LRW Datagram 展开:
[ Cmd(1) | Idx(1) | LogAddr(4) | DLen+M(2) | IRQ(2) ]  ← 10B datagram 头
[ Slave1 Tx PDO (240B) | Slave2 Tx PDO (240B) | Slave1 Rx PDO (240B) | Slave2 Rx PDO (240B) ]  ← 960B 数据
[ WKC (2B) ]

→ 每个 Tx PDO (DcuSendPacket, 240B) 展开:
[ CH1_ctrl(1) | CH1_data(64) | CH2_ctrl(1) | CH2_data(64) | CH3_ctrl(1) | CH3_data(64) | IMU_cmd(1) | Reserved(44) ]

→ 通道 CAN-FD 数据区 (64B) 展开:
[ Actuator_1(8B) | Actuator_2(8B) | ... | Actuator_8(8B) ]

→ 每个执行器 MIT 模式帧 (8B) 展开:
[ pos(16bit) | vel(12bit) | kp(12bit) | kd(12bit) | tor(12bit) ]
```

**总帧长** ≈ 14 + 2 + 10 + 960 + 2 + 4 = **992 bytes**

> [!NOTE]
> 实际帧中可能还包含额外的 DC 同步 datagram（如 ARMW/FRMW 命令，用于分布式时钟同步），这会使帧总长略有增加。

---

## 9. 抓包分析速查表

### 快速定位清单

| 你想看的内容 | Wireshark 操作 |
|:---|:---|
| 所有 EtherCAT 帧 | 过滤器：`ecat` 或 `eth.type == 0x88a4` |
| PDO 数据交换帧 | 过滤器：`ecat.cmd == 0x0c`（LRW 命令） |
| 某个 DCU 的输出数据 | 在 LRW datagram 数据区中找到对应 slave 的偏移（每个 DCU 占 240B） |
| 通道 1 的控制字 | DcuSendPacket 偏移 +0（1 byte） |
| 通道 1 的第 1 个执行器 | DcuSendPacket 偏移 +1（8 bytes） |
| 通道 2 的第 3 个执行器 | DcuSendPacket 偏移 +65+1+16 = +82（8 bytes） |
| IMU 加速度 X | DcuRecvPacket 偏移 +192（4 bytes, big-endian float） |
| IMU 四元数 W | DcuRecvPacket 偏移 +216（4 bytes, big-endian float） |

### 字节偏移速查（相对于某个 DCU 的 DcuSendPacket 起始）

| 通道 | ctrl 偏移 | 执行器 1 偏移 | 执行器 2 偏移 | ... | 执行器 8 偏移 |
|:---:|:---:|:---:|:---:|:---:|:---:|
| CH1 | +0 | +1 | +9 | ... | +57 |
| CH2 | +65 | +66 | +74 | ... | +122 |
| CH3 | +130 | +131 | +139 | ... | +187 |

### 字节偏移速查（相对于某个 DCU 的 DcuRecvPacket 起始）

| 通道 | 执行器 1 偏移 | 执行器 2 偏移 | ... | 执行器 8 偏移 |
|:---:|:---:|:---:|:---:|:---:|
| CH1 | +0 | +8 | ... | +56 |
| CH2 | +64 | +72 | ... | +120 |
| CH3 | +128 | +136 | ... | +184 |

| IMU 字段 | 偏移 | 大小 | 字节序 |
|:---|:---:|:---:|:---:|
| acc[0] (X) | +192 | 4B | Big-endian |
| acc[1] (Y) | +196 | 4B | Big-endian |
| acc[2] (Z) | +200 | 4B | Big-endian |
| gyro[0] (X) | +204 | 4B | Big-endian |
| gyro[1] (Y) | +208 | 4B | Big-endian |
| gyro[2] (Z) | +212 | 4B | Big-endian |
| quat[0] (W) | +216 | 4B | Big-endian |
| quat[1] (X) | +220 | 4B | Big-endian |
| quat[2] (Y) | +224 | 4B | Big-endian |
| quat[3] (Z) | +228 | 4B | Big-endian |

---

## 10. 源码文件参考

| 文件 | 说明 |
|:---|:---|
| [ethercattype.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/third_party/soem/soem/ethercattype.h) | SOEM 类型定义（帧头、命令、数据类型） |
| [ethercat_manager.cpp](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/src/ethercat_manager.cpp) | EtherCAT 主站管理（初始化、WorkLoop、DC 同步） |
| [ethercat_node.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/ethercat_node.h) | 节点抽象类（Send/Recv 缓冲区） |
| [dcu.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/dcu.h) | DCU 节点实现（DcuSendPacket / DcuRecvPacket） |
| [dcu.cpp](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/src/dcu.cpp) | DCU 业务逻辑（通道控制、IMU 读取） |
| [actuator_base.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/actuator_base.h) | 执行器基类（8 字节帧分配） |
| [power_flow.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/power_flow.h) | PowerFlow 执行器定义（MitCmd / StateData 位域） |
| [power_flow.cpp](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/src/power_flow.cpp) | PowerFlow 帧编码/解码实现 |
| [common_type.h](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/xyber_controller/xyber_api/include/common_type.h) | 通用类型定义（MitParam 参数范围） |
| [dcu_x1.yaml](file:///home/jori/Project/zhiyuan-x1-infer/src/module/dcu_driver_module/cfg/dcu_x1.yaml) | 系统配置（DCU 拓扑、执行器映射） |
