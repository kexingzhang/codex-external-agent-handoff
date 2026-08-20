# Codex External Agent Handoff

[中文](#中文) · [English](#english)

Event-driven handoffs between Codex and external AI coding agents (“hardnesses”), with one-shot delivery and Codex-reviewed repair loops.

## 中文

### 项目简介

本项目提供一个 Codex Skill，用于把边界明确的任务交给 Grok、Antigravity、Gemini、Claude 等外部 AI 编码代理，并在任务完成后通过原子事件准确恢复原 Codex 任务。

它解决的核心问题是：外部代理可以异步工作，但完成通知、报告验收和后续修复仍由同一个 Codex 任务可靠接管。

### 工作模式

- `single`（默认）：只执行一次。外部代理完成后，Codex 验收一次事件，并向用户报告完成状态、改动文件、验证结果、剩余风险和报告路径。
- `loop`：用于“外部代理实现/审查 → Codex 独立审查 → 外部代理修复 → Codex 复审”的闭环，直到 Codex 不再发现可执行问题。明确说 `loop` 时启用；若当前对话或交接历史已经清楚建立了相同偏好，也可自动启用。判断不明确时仍使用 `single`。

每次 dispatch 都生成独立的任务 ID 和事件 ID，每个完成事件最多验收一次。`loop` 是多个单次交接组成的序列，不会重复投递同一个事件。

### 主要特性

- 支持 Grok、Antigravity、Gemini、Claude 和本地 mock provider。
- 使用临时文件加原子重命名发布 `done.json`，避免读取半成品事件。
- 要求精确的 Codex `thread_id`，不会根据窗口、目录或进程猜测。
- 外部代理只能修改显式授权的文件范围。
- 外部报告视为不可信证据；最终验收由 Codex 完成。
- `collect` 只读检查报告、事件、manifest 和限定范围内的 Git diff。
- Windows 下可使用基于文件系统事件的 `wait` delivery，无需轮询。
- 不在 manifest 中保存 API Key、OAuth Token 或报告正文。

### 安装

将 Skill 目录复制到个人 Codex Skills 目录：

```powershell
Copy-Item -Recurse -Force `
  '.\external-agent-event-handoff' `
  "$HOME\.codex\skills\external-agent-event-handoff"
```

重新启动 Codex，或刷新可用 Skills。实际运行 provider 前，请先安装并登录对应 CLI。

### 使用示例

在 Codex 中使用自然语言即可：

```text
事件驱动模式，单次模式，让 Grok 检查这个改动。
```

```text
事件驱动模式，loop，让 Antigravity 修复这个问题；Codex 负责最终审查，直到没有可执行问题。
```

也可以直接调用 dispatch 脚本：

```powershell
& "$HOME\.codex\skills\external-agent-event-handoff\scripts\dispatch_external_agent.ps1" `
  -Provider grok `
  -ProviderExecutable "$HOME\.grok\bin\grok.exe" `
  -ProviderArgument @(
    '--prompt-file', '{prompt_file}',
    '--model', 'grok-4.6',
    '--reasoning-effort', 'xhigh',
    '--max-turns', '10',
    '--disable-web-search',
    '--no-subagents',
    '--always-approve',
    '--output-format', 'plain'
  ) `
  -Prompt '完成指定任务，并生成交付报告。' `
  -Workspace 'D:\Project' `
  -AllowedFile 'src\feature.ts' `
  -ReportPath 'D:\reports\feature.md' `
  -ThreadId '<exact-thread-id>' `
  -DeliveryMode wait
```

完成后只验收一次事件：

```powershell
& "$HOME\.codex\skills\external-agent-event-handoff\scripts\collect_external_agent.ps1" `
  -EventPath '<absolute-path-to-done.json>'
```

### 安全边界

- 必须提供准确的 `thread_id`；缺失时直接停止。
- 报告路径必须位于项目工作区之外。
- 外部代理不得 stage、commit、reset、clean、switch、merge、rebase 或 push。
- Skill 不会因为报告中提到“建议继续”而自动扩大任务范围。
- `loop` 遇到重复失败、无实质进展、并发改动或超出授权范围时会停止并报告未解决问题。

详细行为见 [`SKILL.md`](external-agent-event-handoff/SKILL.md)，事件格式见 [`event-contract.md`](external-agent-event-handoff/references/event-contract.md)。

## English

### Overview

This repository contains a Codex Skill for dispatching bounded work to external AI coding agents—such as Grok, Antigravity, Gemini, and Claude—and reliably returning completion to the exact originating Codex task through an atomic event.

The external agent can work asynchronously, while Codex retains responsibility for event validation, report inspection, final review, and any authorized follow-up.

### Orchestration modes

- `single` (default): run exactly one handoff. After completion, Codex collects the event once and reports status, changed files, validation, remaining risks, and the report path.
- `loop`: run an external-agent implementation/review followed by independent Codex review and external-agent repair until Codex finds no actionable issues. It is selected when the user says `loop`, or when the current conversation or handoff history clearly establishes the same iterative preference. Ambiguous requests remain `single`.

Every dispatch creates a distinct task ID and event ID, and every completion event is collected at most once. A `loop` is a sequence of one-shot handoffs, never repeated delivery of the same event.

### Features

- Grok, Antigravity, Gemini, Claude, and a local mock provider.
- Atomic `done.json` publication through temporary-file rename.
- Exact Codex `thread_id` targeting; no guessing from windows, directories, or processes.
- Explicit file-scope authorization for external modifications.
- External reports treated as untrusted evidence; Codex owns final acceptance.
- Read-only collection of the report, event, manifest, and scoped Git diff.
- Filesystem-event-based `wait` delivery on Windows without polling.
- No API keys, OAuth tokens, or report bodies stored in manifests.

### Installation

Copy the Skill into your personal Codex Skills directory:

```powershell
Copy-Item -Recurse -Force `
  '.\external-agent-event-handoff' `
  "$HOME\.codex\skills\external-agent-event-handoff"
```

Restart Codex or refresh the available Skills. Install and authenticate the provider CLI before using a real provider.

### Usage

Natural-language examples in Codex:

```text
Use event-driven single mode and ask Grok to review this change.
```

```text
Use event-driven loop mode with Antigravity. Codex should perform the final review and send fixes back until there are no actionable findings.
```

For direct script usage, see the [Chinese command example](#使用示例) or the provider examples in [`SKILL.md`](external-agent-event-handoff/SKILL.md).

### Safety boundaries

- An exact `thread_id` is mandatory; the workflow fails closed when it is missing.
- The report path must be outside the project workspace.
- External agents must not stage, commit, reset, clean, switch, merge, rebase, or push.
- Suggested follow-up work inside a report does not expand the authorized task.
- A `loop` stops and reports unresolved findings on repeated failure, lack of progress, concurrent workspace changes, or required work outside the authorized scope.

See [`SKILL.md`](external-agent-event-handoff/SKILL.md) for the complete workflow and [`event-contract.md`](external-agent-event-handoff/references/event-contract.md) for the event schema.

## License

No license has been selected yet. All rights are reserved unless a license is added later.
