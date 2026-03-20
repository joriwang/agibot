# 实时性保障措施分析（除 RT 内核与线程优先级外）

> 分析范围：`zhiyuan-x1-infer` 项目自有代码（排除 third_party）

## 已实现的措施

### 1. CPU 核心绑定（CPU Affinity）✅

通过 `pthread_setaffinity_np` 将关键线程绑定到指定 CPU 核心，避免线程在核心间迁移引起的缓存失效和调度延迟。

**实现位置**：[comm_utils.cpp](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/xyber_controller/xyber_api/src/comm_utils.cpp#L61-L72)

```cpp
// bind cpu core
if (bind_cpu >= 0) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(bind_cpu, &cpuset);
    if (pthread_setaffinity_np(pid, sizeof(cpuset), &cpuset) != 0) {
        LOG_ERROR("setaffinity error %s", strerror(errno));
    }
}
```

**配置**：[dcu_x1.yaml](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/cfg/dcu_x1.yaml#L82-L83) 中指定 `bind_cpu: 9`。

**调用链**：`EthercatManager::WorkLoop()` → `SetRealTimeThread("ecat_io_loop", rt_priority=90, bind_cpu=9)`

---

### 2. EtherCAT DC 时钟同步（Distributed Clock PI 控制器）✅

使用 PI 控制器将本地循环定时器与从站 DC 时钟对齐，补偿时钟漂移，确保主站与从站的周期同步。

**实现位置**：[ethercat_manager.cpp](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/xyber_controller/xyber_api/src/ethercat_manager.cpp#L292-L312)

```cpp
int64_t EthercatManager::CalcDcPiSync(int64_t refTime, int64_t cycle_time, int64_t shift_time) {
    static double kP = 0.05, kI = 0.01;
    // ... PI 控制器计算 timer_offset 用于修正 sleep_until 时间
}
```

---

### 3. 原子变量（`std::atomic`）用于线程间无锁标志 ✅

使用 `std::atomic_bool` 作为线程运行标志，避免在控制循环内使用 mutex 导致优先级反转。

| 文件 | 变量 |
|------|------|
| [dcu_driver_module.h](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/include/dcu_driver_module/dcu_driver_module.h#L49) | `std::atomic_bool is_running_` |
| [xyber_controller.h](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/xyber_controller/xyber_api/include/xyber_controller.h#L209) | `std::atomic_bool is_running_` |
| [ethercat_manager.h](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/xyber_controller/xyber_api/include/internal/ethercat_manager.h#L62) | `std::atomic_bool is_running_` |

---

### 4. `steady_clock` + `sleep_until` 绝对时间定时 ✅

EtherCAT 主循环使用 `std::chrono::steady_clock` + `sleep_until` 做绝对时间定时，避免 `sleep_for` 的累积漂移。

**位置**：[ethercat_manager.cpp:354](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/dcu_driver_module/xyber_controller/xyber_api/src/ethercat_manager.cpp#L353-L354)

---

## 未实现的措施

| 措施 | 说明 | 风险等级 |
|------|------|---------|
| **`mlockall(MCL_CURRENT \| MCL_FUTURE)`** | 内存锁定，防止页面换出导致的延迟毛刺 | 🔴 **高** |
| **线程栈预故障（Stack Prefault）** | 提前触碰栈页面，避免运行时缺页中断 | 🟡 中 |
| **无锁队列 / Ring Buffer** | 关键路径的线程间数据传递仍可能使用锁 | 🟡 中 |
| **内存池 / 预分配** | 运行时动态分配可能触发 `brk`/`mmap` 系统调用 | 🟡 中 |
| **`malloc_trim` / 自定义 allocator** | 缺少防止 glibc 内存碎片化的措施 | 🟠 低-中 |
| **信号屏蔽（`pthread_sigmask`）** | RT 线程未屏蔽异步信号 | 🟠 低-中 |
| **`/dev/cpu_dma_latency`** | 未设置 CPU idle state 约束，可能因 C-state 深睡引起唤醒延迟 | 🟡 中 |

> [!CAUTION]
> **`mlockall` 缺失是最关键的遗漏**。在实时系统中，这是仅次于 RT 调度策略的基础措施。缺少它意味着 EtherCAT 循环线程可能在任意时刻因缺页中断而产生毫秒级抖动。
