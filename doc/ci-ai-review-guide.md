# CI AI Code Review 使用指南

> **适用版本**: v0.2.0+
> **最后更新**: 2026-03-20

---

## 概述

本项目的 CI/CD pipeline 集成了两层自动化审查机制：

1. **规则检查（Stage 1）**：确保 spec 与代码同步，代码格式合规——硬性阻断
2. **AI 深度审查（Stage 2）**：使用 OpenCode + Claude Sonnet 对照 spec 做语义级代码审查——CRITICAL 级别阻断

---

## 对开发者的影响

### 每次提交 MR 时会发生什么

```
MR 创建/更新
    ↓
Stage 1: 规则检查（~10 秒）
  ├── 代码文件变更 → 对应 spec 是否也更新了？
  ├── spec 变更 → 版本号字段是否更新了？
  └── 代码格式 → 是否通过 clang-format？
    ↓ 通过后
Stage 2: AI 审查（~30-120 秒）
  ├── AI 读取 diff + spec + bugs.md
  ├── 从四个维度审查代码
  └── 发布 MR comment + 设置 CI 状态
```

### 你需要做的

1. **修改代码时同步更新 spec**——这是最重要的一条。修改了模块代码，就要更新对应的 `spec/module_*.md`
2. **更新 spec 中的版本字段**——修改 spec 时，更新 `对应代码 commit` 为当前 commit hash
3. **使用 MR 模板**——MR 描述中填写 checklist
4. **关注 AI review 评论**——AI 会在 MR 中留下评论，分 CRITICAL / WARNING / INFO 三级

### 结果解读

| AI 输出 | 含义 | 你需要做什么 |
|---------|------|------------|
| ✅ 无 CRITICAL | 审查通过 | 可以请 reviewer 合并 |
| ⚠️ WARNING | 有改进建议 | 建议修复，但不阻断合并 |
| 🔴 CRITICAL | 接口契约违规或已知 bug 模式 | **必须修复**才能合并 |

---

## 特殊操作

### Spec 豁免

如果你的 MR 确实不需要更新 spec（如纯格式化、纯注释修改），在 MR 描述中添加：

```
[spec-exempt]
原因：纯代码格式化，不影响任何运行时行为
```

Stage 1 的 spec 同步检查会跳过。

### Tech Lead 覆盖 CRITICAL

如果 AI 的 CRITICAL 判定有误（误报），tech lead 可以在 MR 评论中回复：

```
/ai-review-override reason: AI 误判，该 Topic 名变更已在 spec 中通过口头确认，下个 commit 补充 spec 更新
```

下次 pipeline 运行时，CRITICAL 会被标记为"已覆盖"，不再阻断合并。

### 切换 AI 模型

在 GitLab CI/CD Variables 中设置 `OPENCODE_MODEL` 变量：

| 值 | 模型 | 说明 |
|----|------|------|
| `anthropic/claude-sonnet-4-6` | Claude Sonnet 4.6（默认） | 结构化输出最稳定 |
| `google/gemini-3.1-pro` | Gemini 3.1 Pro | 编码能力略强，成本略低 |
| `qwen/qwen3.5-397b-a17b` | Qwen3.5 397B | 成本最低 |

---

## AI 审查的四个维度

### 1. 接口契约合规

AI 对照 spec 中的 Channel 接口表，检查：
- 新增的 Topic 订阅/发布是否在 spec 中声明
- 消息类型是否与 spec 一致
- 频率约束是否满足

**示例违规**：在 `sim_module.cc` 中新增了 `/reset_sim` 的订阅处理，但 `spec/module_sim_module.md` §2.2 中没有更新该接口 → **CRITICAL**

### 2. 命名风格合规

对照 L0 spec 中的命名约定检查变量名、函数名、类名等。

**示例违规**：新增变量 `tmpVal` 但项目约定使用 `snake_case_` → **WARNING**

### 3. Spec 同步

检测代码行为变更是否需要更新 spec 但遗漏了。

**示例违规**：新增了一个状态机状态但 spec §4.1 状态表未更新 → **CRITICAL**

### 4. 代码质量

对照 `bugs.md` 中的已知 bug 模式，检查是否有类似问题新引入。

**示例违规**：新代码中用 `map[key]` 访问可能不存在的键，与 BUG-07 模式相同 → **WARNING**

---

## 常见问题

### Q: AI 审查需要多长时间？
A: 通常 30-120 秒，取决于 diff 大小和 AI 需要读取的文件数量。

### Q: AI 审查会读取我的全部代码吗？
A: AI 可以访问仓库中的所有文件，但它只会主动读取与变更相关的文件（diff 涉及的模块、对应的 spec、被 include 的头文件等）。

### Q: AI 的 CRITICAL 判定可靠吗？
A: CRITICAL 仅限两种高置信度场景（接口契约违规 + 已知 bug 模式），误报率较低。如确有误报，tech lead 可以覆盖。

### Q: 每次 AI 审查的成本是多少？
A: 使用 Claude Sonnet 4.6，单次审查约 $0.09-0.30（取决于 diff 大小和 AI 读取的文件量）。

### Q: 如果 AI 审查 Stage 超时或报错怎么办？
A: AI 审查失败不应阻断开发流程。如果 Stage 2 因 API 错误或超时失败，通知 tech lead 检查 CI 配置。

---

## 文件结构

```
.gitlab-ci.yml                              # Pipeline 定义
.gitlab/merge_request_templates/default.md   # MR 模板
.opencode/
├── agents/review.md                        # AI review agent 定义
└── config.yaml                             # OpenCode 项目配置
scripts/ci/
├── spec_sync_check.sh                      # Stage 1: 规则检查
├── ai_review.sh                            # Stage 2: AI 审查入口
├── post_review.py                          # MR comment 发布
└── config.yaml                             # 审查配置（映射关系等）
docs/
└── ci-ai-review-guide.md                   # 本文档
```

---

## 环境要求

### GitLab CI/CD Variables（需配置）

| 变量名 | 用途 | 必填 |
|--------|------|------|
| `ANTHROPIC_API_KEY` | Claude API 密钥 | ✅ |
| `GITLAB_REVIEW_BOT_TOKEN` | GitLab API Token（需要 `api` scope） | ✅ |
| `GOOGLE_API_KEY` | Gemini API 密钥（使用 Gemini 时） | ❌ |
| `ALIBABA_API_KEY` | 阿里云 API 密钥（使用 Qwen 时） | ❌ |
| `OPENCODE_MODEL` | 覆盖默认模型 | ❌ |

### Runner 要求

- 可访问外网（api.anthropic.com）
- Node.js 20+（用于 OpenCode CLI）
- Python 3（用于 post_review.py）
- Git
