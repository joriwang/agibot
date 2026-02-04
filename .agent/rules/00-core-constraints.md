---
trigger: always_on
---

# Workspace 核心约束规则（最高优先级）

**文件说明**  
本文件为当前工作区（workspace）的核心约束规则。
**优先级声明**：  
本工作区规则的优先级高于全局规则（~/.gemini/GEMINI.md）。  
当本文件内容与全局规则发生冲突时，**必须**以本文件为准，并在回复中明确报告：  
1. 冲突的具体条款（引用全局规则原文）  
2. 冲突原因（简要说明为什么工作区规则更适合当前项目）  
3. 实际采用的规则（即本文件中的版本）

## 1. 强制元规则（必须始终遵守）

- 任何时候都不得违反本文件中以 **粗体** 或 `**强制**` 标记的条款。
- 如果用户指令与本规则冲突，优先执行本规则，并在回复开头明确说明：“检测到用户指令与 workspace 规则冲突，已按规则优先处理，详情如下：……”
- **语言要求**：所有回复、任务清单、实施计划（Implementation Plan）、Task List，均须使用简体中文。
- **固定指令**：Implementation Plan, Task List and response in Chinese.

## 2. 行为与合规协议 (Behavioral Protocols)
1.  **原子性更新原则 (Atomic Updates)**
    - **定义**：代码变更（Code Change）与文档更新（Doc Update）必须视为同一事务。
    - **强制**：在修改任何代码逻辑后，必须同步检查并更新相关的 `README.md`、`spec.md` 或 `Implementation Plan`，确保“文档即代码（Docs as Code）”的一致性。
2.  **思维链自检 (Chain-of-Thought Self-Correction)**
    - **强制**：在输出最终回复（Artifacts/Response）前，必须执行隐式自检：
        1. 语言是否为简体中文？
        2. 是否遗漏了配套的文档更新？
    - **动作**：一旦发现不合规，必须在输出前自我修正。