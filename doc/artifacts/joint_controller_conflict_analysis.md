# 关节-控制器冲突分析报告

## 结论

**是的，代码中存在多个控制器控制同一关节的情况，且这是有意的设计。** 后注册的控制器会覆盖前者的关节命令。

---

## 1. 覆盖机制分析

### 代码位置

[control_module.cc](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/control_module/src/control_module.cc#L169-L183) 中的 `MainLoop()`：

```cpp
auto controller_names = state_machine_.GetCurrentControllerNames();
for (const auto& name : controller_names) {
    controller_map_[name]->Update();
    my_ros2_proto::msg::JointCommand tmp_cmd = controller_map_[name]->GetJointCmdData();
    for (size_t ii = 0; ii < tmp_cmd.name.size(); ii++) {
        int index = joint_cmd_index_map_[tmp_cmd.name[ii].c_str()];
        cmd_msg.name[index] = tmp_cmd.name[ii];
        cmd_msg.position[index] = tmp_cmd.position[ii] + ...;
        cmd_msg.velocity[index] = tmp_cmd.velocity[ii];
        cmd_msg.effort[index]   = tmp_cmd.effort[ii];
        cmd_msg.damping[index]  = tmp_cmd.damping[ii];
        cmd_msg.stiffness[index]= tmp_cmd.stiffness[ii];
    }
}
```

> [!IMPORTANT]
> **覆盖规则**：控制器列表中**靠后的控制器**会覆盖前面控制器对相同关节的命令。没有累加、混合或冲突检测逻辑。

---

## 2. 各状态的控制器-关节重叠分析

基于 [rl_x1.yaml](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/control_module/cfg/rl_x1.yaml) 的配置：

### 各控制器管辖关节一览

| 控制器 | 关节数 | 关节范围 |
|---|---|---|
| `pd_idle` | 29 | 全部关节 |
| `pd_keep` | 29 | 全部关节 |
| `pd_zero` | 29 | 全部关节 |
| `pd_stand` | 16 | 部分肩/肘 + 全部髋/膝/踝（不含 ankle_roll） |
| `pd_plan` | 3 | 右肩 pitch/yaw + 右肘 pitch |
| `rl_walk_leg` | 12 | 全部髋/膝/踝（含 ankle_roll） |
| `rl_walk_leg_shoulder` | 14 | 全部髋/膝/踝（含 ankle_roll）+ 左右 shoulder_pitch |

### 各状态重叠情况

#### ❌ 无冲突的状态（单控制器）

| 状态 | 控制器 | 冲突 |
|---|---|---|
| `idle` | `pd_idle` | 无 |
| `keep` | `pd_keep` | 无 |
| `zero` | `pd_zero` | 无 |

#### ⚠️ 存在有意覆盖的状态

**`stand` = [`pd_zero`, `pd_stand`]**

| 重叠关节 | 被覆盖方 | 最终生效 |
|---|---|---|
| `left_shoulder_pitch/roll_joint` | `pd_zero` | **`pd_stand`** |
| `left_elbow_pitch_joint` | `pd_zero` | **`pd_stand`** |
| `right_shoulder_pitch/roll_joint` | `pd_zero` | **`pd_stand`** |
| `right_elbow_pitch_joint` | `pd_zero` | **`pd_stand`** |
| 全部 `hip/knee/ankle_pitch` (10 个) | `pd_zero` | **`pd_stand`** |
| **共 16 个关节被覆盖** | | |

> 设计意图：`pd_zero` 提供全关节的基础姿态，`pd_stand` 覆盖特定关节以实现站立姿态。

---

**`walk_leg` = [`pd_zero`, `pd_stand`, `rl_walk_leg`]**

| 覆盖链 | 关节 | 最终生效 |
|---|---|---|
| `pd_zero` → `pd_stand` → `rl_walk_leg` | 全部 `hip/knee/ankle_pitch` (10 个) | **`rl_walk_leg`** |
| `pd_zero` → `pd_stand` | 部分肩/肘 (6 个) | **`pd_stand`** |
| `pd_zero` → `rl_walk_leg` 独有 | `left/right_ankle_roll_joint` (2 个) | **`rl_walk_leg`** |
| 仅 `pd_zero` | 腰部 + 其余手臂 (11 个) | **`pd_zero`** |

---

**`walk_leg_arm` = [`pd_zero`, `pd_stand`, `rl_walk_leg_shoulder`]**

| 覆盖链 | 关节 | 最终生效 |
|---|---|---|
| `pd_zero` → `pd_stand` → `rl_walk_leg_shoulder` | 全部 `hip/knee/ankle_pitch` + `left/right_shoulder_pitch` (12 个) | **`rl_walk_leg_shoulder`** |
| `pd_zero` → `pd_stand` | `left/right_shoulder_roll` + `left/right_elbow_pitch` (4 个) | **`pd_stand`** |
| `pd_zero` → `rl_walk_leg_shoulder` 独有 | `left/right_ankle_roll` (2 个) | **`rl_walk_leg_shoulder`** |
| 仅 `pd_zero` | 腰部 + 其余手臂 (11 个) | **`pd_zero`** |

---

**`stand_&_plan` = [`pd_zero`, `pd_stand`, `pd_plan`]**

| 覆盖链 | 关节 | 最终生效 |
|---|---|---|
| `pd_zero` → `pd_stand` → `pd_plan` | `right_shoulder_pitch` + `right_elbow_pitch` (2 个) | **`pd_plan`** |
| `pd_zero` → `pd_plan` 独有 | `right_shoulder_yaw` (1 个) | **`pd_plan`** |
| `pd_zero` → `pd_stand` | 其余 stand 关节 (14 个) | **`pd_stand`** |
| 仅 `pd_zero` | 腰部 + 其余手臂 (12 个) | **`pd_zero`** |

---

**`keep_&_plan` = [`pd_keep`, `pd_plan`]**

| 重叠关节 | 被覆盖方 | 最终生效 |
|---|---|---|
| `right_shoulder_pitch/yaw_joint` | `pd_keep` | **`pd_plan`** |
| `right_elbow_pitch_joint` | `pd_keep` | **`pd_plan`** |
| **共 3 个关节被覆盖** | | |

---

**`walk_leg_&_plan` = [`pd_zero`, `pd_stand`, `rl_walk_leg`, `pd_plan`]**

这是覆盖链最长的状态（4 个控制器），存在 4 层覆盖：

| 关节 | 覆盖链 | 最终生效 |
|---|---|---|
| `right_shoulder_pitch_joint` | `pd_zero` → `pd_stand` → `pd_plan` | **`pd_plan`** |
| `right_shoulder_yaw_joint` | `pd_zero` → `pd_plan` | **`pd_plan`** |
| `right_elbow_pitch_joint` | `pd_zero` → `pd_stand` → `pd_plan` | **`pd_plan`** |
| 全部下肢 (10-12 个) | `pd_zero` → `pd_stand` → `rl_walk_leg` | **`rl_walk_leg`** |

---

## 3. 关键结论

### 这是有意的分层覆盖设计

```mermaid
graph LR
    A["pd_zero (全身基础)"] --> B["pd_stand (站立覆盖)"]
    B --> C["rl_walk_leg (行走覆盖)"]
    B --> D["pd_plan (规划覆盖)"]
    C --> E["pd_plan (行走+规划)"]
```

设计模式：**全身 PD 基础 → 局部 PD 覆盖 → RL 策略覆盖 → 规划覆盖**

### 潜在风险

> [!WARNING]
> 1. **无冲突检测**：代码没有检查或日志记录重叠关节被覆盖的事实，完全依赖 YAML 配置的正确性
> 2. **覆盖顺序依赖**：控制器列表的顺序至关重要，调换顺序会导致不同的关节被最终控制
> 3. **浪费计算**：被覆盖的控制器仍会完整执行 `Update()` 计算，其结果被直接丢弃
> 4. **`pd_idle` 的 stiffness 数组少 1 个元素**（28 vs 29 个关节），可能是配置错误

### 仿真配置

[rl_x1_sim.yaml](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/module/control_module/cfg/rl_x1_sim.yaml) 的状态机配置与真机完全一致，覆盖关系相同，仅 PD 参数（stiffness/damping）数值不同。
