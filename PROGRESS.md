# Progress

> Last updated: 2026-04-28

## 🎯 Current Focus
<!-- Core tasks in progress, recommended no more than 2 -->

- AI 状态监控多 Agent 支持调研 (Codex/OpenCode/Cursor)

## 📥 Todo Queue
<!-- Next planned tasks -->

- [可选] 优化 fallback 轮询频率（当前 15s，可改为 5s）
- [待调研] Codex/OpenCode/Cursor Hook 机制

## ✅ Recently Completed
<!-- Keep only the last 3-5 items to avoid infinite file growth -->

- **2026-04-28**: Sessions 状态监听实现并验证成功
  - SessionsWatcher 监听 ~/.claude/sessions/*.json
  - 权威 idle 判断，覆盖所有阶段的 ESC 打断
  - 状态合并逻辑：idle 不被 Hook 覆盖
- **2026-04-27**: XPC 推送链路验证成功（毫秒级延迟）
- **2026-04-27**: JSONL Interrupt 验证成功（thinking 阶段 ESC 打断）

## 🧱 Blockers & Issues
<!-- Record sticking points for easy review -->

暂无

## 🧠 Context Notes
<!-- Key decisions, API snippets, research conclusions, debug notes and error analysis -->

### Sessions 状态文件发现
- 路径: `~/.claude/sessions/<pid>.json`
- 字段: `{sessionId, status: "busy"/"idle", pid, cwd}`
- **关键**: status="idle" 是权威状态，覆盖所有阶段的 ESC 打断检测

### 状态合并逻辑
```
sessions idle → 最终 idle (权威，不可覆盖)
sessions busy + Hook → 详细 phase
  ├─ busy + waiting_for_approval → waitingForApproval
  ├─ busy + running_tool → runningTool
  └─ busy + 其他 → processing
```

### 多 Agent 支持设计思路
见 `docs/ai-multi-agent-support.md`

## ⚡ Quick Recovery
- `git pull`
- open: BoringNotchAIXPCHelper/SessionsWatcher.swift, boringNotch/AI/AIManager.swift

## 📅 Task History (Last 7 days)
<!-- Automatically generated, sorted by date in descending order -->

| 日期 | 任务 | 状态 |
|------|------|------|
| 2026-04-28 | 清理 Darwin Notification 死代码 | ✅ 完成 |
| 2026-04-28 | Sessions 状态监听实现 | ✅ 完成 |
| 2026-04-28 | Sessions 状态监听验证 | ✅ 完成 |
| 2026-04-28 | 僵尸 session 清理 | ✅ 完成 |
| 2026-04-27 | XPC 推送链路验证 | ✅ 完成 |
| 2026-04-27 | JSONL Interrupt 验证 | ✅ 完成 |

## 🏛️ Archive Links
<!-- Automatically generated, pointing to historical archive files -->

暂无