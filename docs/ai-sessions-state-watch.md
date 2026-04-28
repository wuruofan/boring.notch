# Sessions 状态文件监听方案

> **重大发现 (2026-04-27)**：Claude Code 官方 session 状态文件直接包含 `busy/idle` 状态，可作为权威状态源。
> **验证成功 (2026-04-28)**：SessionsWatcher 实现完成，ESC 打断检测正常工作。

---

## 一、Sessions 状态文件发现

### 文件路径

```
~/.claude/sessions/<pid>.json
```

### 文件结构

```json
{
    "pid": 38103,
    "sessionId": "b350c048-0712-44ec-b856-6bfdfdf382b3",
    "cwd": "/Users/wuruofan/mine/rfw/boring.notch",
    "startedAt": 1777273318581,
    "procStart": "Mon Apr 27 07:01:57 2026",
    "version": "2.1.119",
    "peerProtocol": 1,
    "kind": "interactive",
    "entrypoint": "cli",
    "status": "busy",
    "updatedAt": 1777281497981
}
```

### 已观察的字段

| 字段 | 类型 | 说明 | 观察到的值 |
|------|------|------|-----------|
| pid | int | 进程 ID | - |
| sessionId | string | 会话 UUID | - |
| cwd | string | 工作目录 | - |
| startedAt | timestamp | 启动时间 | - |
| procStart | string | 启动时间字符串 | - |
| version | string | Claude Code 版本 | "2.1.119" |
| peerProtocol | int | 协议版本 | 1 |
| kind | string | 会话类型 | **只有 "interactive"** |
| entrypoint | string | 入口点 | **只有 "cli"** |
| status | string | 状态 | **只有 "busy" / "idle"** |
| updatedAt | timestamp | 更新时间 | - |

### 状态变化观察

```
17:19:04 pid=38103 busy (当前会话)
17:19:04 pid=63375 idle
17:19:12 pid=63375 idle -> busy (开始工作)
17:19:46 pid=63375 busy -> idle (工作完成)
```

**关键发现**：ESC 打断后，sessions 文件立即变成 `idle` 状态。

---

## 二、解决的问题

### 问题 A：UserPromptSubmit ~ PreToolUse 之间的 ESC 打断

**之前的问题**：
- Hook 只有 PreToolUse 之后的事件
- JSONL Interrupt 只能检测 thinking 阶段的 ESC
- UserPromptSubmit 到 thinking 之间（最长 64 秒）无法检测 ESC
- 需要超时机制（30s？可能不够）

**Sessions 方案解决**：
- ESC 打断后 sessions 立即变 `idle`
- 无需超时推断
- 覆盖所有阶段（包括空白期）

### 问题 B：interrupt 和 Hook 事件的竞态

**之前的问题**：
- `interrupt → idle` 被 `PostToolUse → processing` 覆盖
- 需要 interrupt 标记阻止后续覆盖

**Sessions 方案解决**：
- sessions 的 `idle` 是权威状态
- Hook 事件不能覆盖 sessions 的 idle
- 无需额外的标记机制

---

## 三、新架构设计

### 状态来源优先级

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        状态来源优先级                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  优先级 1：Sessions status (权威源)                                       │
│  ├─ status="idle" → 最终状态就是 idle                                     │
│  └─ status="busy" → 结合 Hook 事件判断细节                                │
│                                                                          │
│  优先级 2：Hook 事件 (补充细节)                                           │
│  ├─ busy + waiting_for_approval → waitingForApproval                    │
│  ├─ busy + running_tool → runningTool                                   │
│  ├─ busy + compacting → compacting                                      │
│  └─ busy + 其他 → processing                                             │
│                                                                          │
│  优先级 3：JSONL Interrupt (可选补充)                                     │
│  ├─ 检测 ESC 打断的详细信息                                               │
│  └─ 与 sessions idle 状态协同                                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 状态映射表

| Sessions | Hook | 最终状态 | 说明 |
|----------|------|---------|------|
| idle | * | **idle** | Hook 事件被忽略 |
| busy | waiting_for_approval | waitingForApproval | 权限审批 |
| busy | running_tool | runningTool | 执行工具 |
| busy | compacting | compacting | Compact 操作 |
| busy | stop_pending | processing | 忽略，等 sessions 变 idle |
| busy | 其他 | processing | 正常处理 |

### 架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        新推送架构                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Claude Code                                                            │
│       ├─ Hook 事件 (Python 脚本)                                         │
│       │      ↓ Socket                                                   │
│       │   XPC Helper (AIHookServerCore)                                 │
│       │      ├─ 写入状态文件                                             │
│       │      └─ notifyStateUpdate(sessionIds)                           │
│       │             ↓ XPC 回调                                           │
│       │   主 App (AIManager) → 补充细节                                   │
│       │                                                                  │
│       ├─ Sessions 状态文件                                               │
│       │      ↓ Thread.polling                                           │
│       │   XPC Helper (SessionsWatcher - 新增)                           │
│       │      ├─ 监听 ~/.claude/sessions/*.json                          │
│       │      └─ notifySessionStatus(sessionId, status)                  │
│       │             ↓ XPC 回调                                           │
│       │   主 App (AIManager) → 权威 idle 判断                            │
│       │                                                                  │
│       └─ JSONL 文件                                                       │
│       │      ↓ Thread.polling                                           │
│       │   XPC Helper (JSONLInterruptPollingThread)                      │
│       │      └─ notifyInterrupt(sessionId)                              │
│       │             ↓ XPC 回调                                           │
│       │   主 App (AIManager) → 可选补充                                  │
│                                                                          │
│  主 App 状态合并逻辑：                                                    │
│  func updateSessionState(sessionId, sessionsStatus, hookStatus) {       │
│      if sessionsStatus == "idle" {                                       │
│          session.phase = .idle  // 权威，不可覆盖                        │
│      } else {                                                            │
│          session.phase = mapHookToPhase(hookStatus)  // 补充细节         │
│      }                                                                   │
│  }                                                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 四、实现计划

### 新增组件

| 文件 | 作用 | 状态 |
|------|------|------|
| `SessionsWatcher.swift` | XPC Helper 监听 sessions/*.json | ✅ 已实现 |
| `AIXPCService.swift` | 新增 notifySessionStatus 方法 | ✅ 已实现 |
| `AIXPCListener.swift` | 新增 onSessionStatus 回调 | ✅ 已实现 |
| `AIManager.swift` | 状态合并逻辑 | ✅ 已实现 |

### 实现步骤

1. **XPC Helper：SessionsWatcher**
   - Thread.polling 监听 sessions 目录
   - 检测 status 变化
   - XPC 回调推送

2. **XPC 协议扩展**
   - 新增 `notifySessionStatus(sessionId: String, status: String)` 方法
   - 主 App 接收回调

3. **主 App：状态合并**
   - sessions idle → 最终 idle
   - sessions busy + Hook → 详细状态

4. **清理旧逻辑**
   - 移除 interrupt 标记机制（不再需要）
   - 移除 stop_pending 时间窗口（不再需要）
   - 保留 JSONL Interrupt 作为可选补充

---

## 五、优势总结

| 方案 | 问题解决 | 实现复杂度 | 可靠性 |
|------|---------|-----------|--------|
| Hook + 超时 | 部分 | 高 | 低 |
| Hook + JSONL Interrupt | 部分 | 高 | 中 |
| **Sessions 状态** | **全部** | **低** | **高** |

**核心优势**：
1. 官方状态源，精确可靠
2. 无需超时机制
3. 无需竞态处理
4. 覆盖所有阶段
5. 实现简单（只需监听一个文件）

---

## 六、验证结果

**验证日期**：2026-04-28

**验证内容**：
- ESC 打断检测：输入 test 后 2 秒按 ESC
- Sessions 状态变化：busy → idle 立即检测

**验证日志**：
```
13:25:58 handleSessionStatus: Received status idle for 985592a8
13:26:16 handleSessionStatus: Received status busy for 985592a8
13:26:29 handleSessionStatus: Received status idle for 985592a8  ← ESC 打断
```

**结论**：✅ SessionsWatcher 正常工作，ESC 打断后立即检测到 idle。

**待继续观察**：
- 其他 `kind` 类型（如 agent）
- 其他 `entrypoint` 类型（如 api）
- 其他 `status` 值（目前只观察到 busy/idle）