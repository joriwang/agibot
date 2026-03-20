# Spec 版本绑定实施指南

> 本文档描述如何为 agibot_x1_infer 的 spec 体系建立与代码的版本绑定机制。

---

## 一、Tag 规范

### 1.1 命名格式

```
v<major>.<minor>.<patch>
```

| 级别 | 触发条件 | 示例场景 |
|------|---------|---------|
| major | 架构级变更 | 新增/移除模块、AimRT 大版本升级、通信协议不兼容变更 |
| minor | 功能变更 | 新增控制器/状态、配置格式变化、新增 RL 策略 |
| patch | Bug 修复/参数调整 | bugs.md 中的修复、PD 参数调优、文档修正 |

### 1.2 首个 Tag

当前仓库从未打过 tag。建议以当前状态（spec 体系初版完成）打第一个 tag：

```bash
git tag -a v0.1.0 -m "Initial spec-driven baseline: L0/L1/L2 specs complete, 7 known bugs documented"
git push origin v0.1.0
```

使用 `v0.x.x` 表示开发阶段，给团队留出接口变更的空间。

### 1.3 Tag 纪律

- **Tag 只在 spec 和代码同步时打**——如果代码改了但 spec 没更新，不打 tag
- **Tag 信息必须包含变更摘要**——`git tag -a` 的 message 中列出本次变更涉及的模块和 spec
- **不删除已发布的 tag**——如果发现 tag 有误，打新 tag（如 `v0.1.1`）而非修改已有 tag

---

## 二、Spec 头部格式变更

### 2.1 新增字段

在每份 spec 的元数据区（`>` 引用块）中增加两行：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

- `对应代码版本`：**必填**，标明 spec 描述的代码版本（git tag）
- `对应代码 commit`：**推荐**，tag 之间有多次 commit 时便于精确追溯；打 tag 时与 tag 指向的 commit 一致

### 2.2 各文件需要修改的位置

#### spec/l0_system_architecture.md

在第 7 行（`> **许可协议**: MulanPSL-2.0`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### spec/module_control_module.md

在第 9 行（`> **配置路径**: ...`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### spec/module_dcu_driver_module.md

在第 9 行（`> **配置路径**: ...`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### spec/module_joy_stick_module.md

在第 8 行（`> **源码路径**: ...`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### spec/module_sim_module.md

在第 6 行（`> **信息来源**: ...`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### spec/protocol_joint_command.md

在第 6 行（`> **文档版本**: v1.0 | 2026-03-20`）之后插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

#### 其他协议 spec（protocol_joystick_data.md、protocol_joystick_state.md、protocol_example_proto.md、protocol_my_proto.md、protocol_my_ros_rpc.md）

同样在元数据区末尾插入相同的两行。

#### spec/bugs.md

在元数据区末尾插入：

```markdown
> **对应代码版本**: v0.1.0
> **对应代码 commit**: f749ecb
```

---

## 三、PR 流程配套

### 3.1 PR 模板 Checklist

在仓库根目录创建 `.github/PULL_REQUEST_TEMPLATE.md`：

```markdown
## Checklist

- [ ] 代码变更已通过编译和测试
- [ ] 涉及的 spec 已同步更新（`对应代码版本` 和 `对应代码 commit` 已更新）
- [ ] 如果此 PR 不涉及任何 spec 变更，请说明原因：_______________
- [ ] bugs.md 中的已知缺陷是否受本次变更影响？如是，已更新状态
```

### 3.2 版本更新工作流

```
1. 开发者修改代码
2. 开发者更新对应的 spec（修改 spec 正文 + 更新「对应代码 commit」为当前 HEAD）
3. 提交 PR，通过 review
4. 合并后，如果达到 minor/major 变更级别，由技术负责人打 tag
5. 打 tag 后，更新所有受影响 spec 的「对应代码版本」字段为新 tag 号
```

---

## 四、执行命令参考

### 首次执行（一次性）

```bash
# 1. 修改所有 spec 文件（添加版本绑定字段）
#    按上述 §2.2 的指引逐文件修改

# 2. 创建 PR 模板
mkdir -p .github
cat > .github/PULL_REQUEST_TEMPLATE.md << 'EOF'
## Checklist

- [ ] 代码变更已通过编译和测试
- [ ] 涉及的 spec 已同步更新（`对应代码版本` 和 `对应代码 commit` 已更新）
- [ ] 如果此 PR 不涉及任何 spec 变更，请说明原因：_______________
- [ ] bugs.md 中的已知缺陷是否受本次变更影响？如是，已更新状态
EOF

# 3. 提交
git add spec/ .github/
git commit -m "chore: add version binding to all specs, add PR template"

# 4. 打首个 tag
git tag -a v0.1.0 -m "v0.1.0: Initial spec-driven baseline

Spec coverage:
- L0: system architecture (l0_system_architecture.md)
- L1: 4 modules (control, dcu_driver, joy_stick, sim)
- L2: 6 protocols (joint_command, joystick_data/state, example_proto, my_proto, my_ros_rpc)
- Bug tracker: 7 known issues (3 high, 2 medium, 2 low)
- Test criteria: all L1 modules + joint_command protocol

Known issues at this version:
- BUG-01 through BUG-07 (see spec/bugs.md)"

# 5. 推送
git push origin main
git push origin v0.1.0
```