# AI 状态监控方案历史总结

## 一、方案演进时间线

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            方案演进历史                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Phase 1: 直接 Socket (失败)                                                 │
│  ├─ 主 App 直接运行 Socket Server                                            │
│  ├─ 问题: Sandbox 阻止创建 /tmp/*.sock                                       │
│  └─ 结果: ❌ 完全失败                                                         │
│                                                                              │
│  Phase 2: XPC Helper Socket Server (部分成功)                                │
│  ├─ 将 Socket Server 移到 XPC Helper (unsandboxed)                           │
│  ├─ Socket 创建成功                                                          │
│  ├─ 问题: XPC Service 中 DispatchSource/Task/Thread 都不工作                 │
│  ├─ 尝试: DispatchSource, FileHandle, Thread.polling                         │
│  └─ 结果: ⚠️ Socket 能创建但无法稳定接收数据                                   │
│                                                                              │
│  Phase 3: Hook 直接写文件 (当前方案)                                          │
│  ├─ Hook Python 脚本直接写入状态文件                                          │
│  ├─ 主 App 轮询读取状态文件                                                   │
│  ├─ 问题: Hook 脚本经常回滚到 socket 方式                                     │
│  ├─ 问题: 事件顺序不稳定 (Stop vs idle_prompt)                                │
│  └─ 结果: ✅ 基本可用，但需要维护                                              │
│                                                                              │
│  Phase 4: Interrupt JSONL 监听 (已验证成功) ✅                              │
│  ├─ XPC Helper 监听 JSONL 文件写入 (Thread.polling)                          │
│  ├─ XPC 回调推送 interrupt 事件                                               │
│  ├─ 验证日期: 2026-04-27                                                      │
│  ├─ 验证证据: handleXPCInterrupt 日志, JSONL "Interrupted by user" 检测       │
│  └─ 结果: ✅ 完全工作 - thinking 阶段 ESC 打断可检测                           │
│                                                                              │
│  Phase 5: XPC 推送版本 (已实现) ✅                                            │
│  ├─ XPC Helper 收到 Hook 事件后主动推送                                        │
│  ├─ 通过 XPC 回调穿透 Sandbox 边界                                            │
│  ├─ 推送延迟: 毫秒级 (远优于 200ms 轮询)                                       │
│  ├─ 验证日期: 2026-04-27                                                      │
│  └─ 结果: ✅ 完全工作 - notifyStateUpdate/onStateUpdate 链路稳定              │
│                                                                              │
│  Phase 6: Sessions 状态监听 (已验证) ✅                                       │
│  ├─ XPC Helper 监听 ~/.claude/sessions/*.json (Thread.polling)               │
│  ├─ 检测 busy → idle 状态变化                                                 │
│  ├─ 解决 UserPromptSubmit ~ PreToolUse 之间的 ESC 打断空白期                  │
│  ├─ idle 状态权威，不被 Hook 事件覆盖                                         │
│  ├─ 验证日期: 2026-04-28                                                      │
│  └─ 结果: ✅ 完全工作 - 权威 idle 判断                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、各方案详细分析

### 方案 1: 直接 Socket Server (主 App)

**时间**: 开发初期

**架构**:
```
Claude Code → Hook Python → Socket → 主 App (Socket Server)
```

**实现**:
- 主 App 直接在 sandboxed 环境创建 Unix Domain Socket
- 监听 `/tmp/boringnotch-ai.sock`

**问题**:
```swift
// 主 App 无法创建 /tmp 下的 socket
// Sandbox 错误: "Operation not permitted"
socket(AF_UNIX, SOCK_STREAM, 0)  // ❌ 被 sandbox 阻止
bind(socket, sockaddr_un, ...)   // ❌ 权限拒绝
```

**结论**: ❌ **完全失败** - Sandbox 不允许在 /tmp 创建 socket

---

### 方案 2: XPC Helper Socket Server

**时间**: Phase 2

**架构**:
```
Claude Code → Hook Python → Socket → XPC Helper → 状态文件 → 主 App
```

**实现**:
- XPC Helper 运行在 unsandboxed 环境
- 可以创建 `/tmp/boringnotch-ai.sock`
- 尝试多种异步机制接收数据

**尝试的异步机制**:

| 机制 | 结果 | 问题 |
|------|------|------|
| DispatchSource.read | ❌ | XPC Service 无 RunLoop，DispatchSource 不触发 |
| FileHandle.readabilityHandler | ❌ | 同上，依赖 RunLoop |
| Thread + poll() | ❌ | Thread.start() 不工作，polling 线程不启动 |
| DispatchQueue.async + while | ⚠️ | 偶尔工作，不稳定 |

**日志证据**:
```
// AIHookServerCore.swift 尝试了多种方式
acceptSource = DispatchSource.makeReadSource(...)  // 不触发
acceptSource?.resume()  // 无效果

// Thread-based polling
pollingThread = Thread { while isRunning { poll() } }  // 线程不启动
pollingThread?.start()  // 无效果
```

**根本原因**: XPC Service 没有 RunLoop，大部分异步机制失效

**结论**: ⚠️ **部分成功** - Socket 能创建，但数据接收不稳定

---

### 方案 3: Hook 直接写文件 + 主 App 轮询

**时间**: Phase 3 (当前)

**架构**:
```
Claude Code → Hook Python → 直接写文件 → 主 App 轮询读取
                   ↓
              (可选) Socket → XPC Helper (用于权限响应)
```

**实现**:
```python
# Hook Python 直接写入状态文件
STATE_FILE_PATH = "~/Library/Containers/.../boringnotch-ai-state.json"

def send_event(state):
    # 主方式：直接写文件
    with open(STATE_FILE_PATH, 'w') as f:
        json.dump(state, f)
    
    # 权限请求：也尝试 socket (等待响应)
    if state.get("status") == "waiting_for_approval":
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state))
        response = sock.recv(4096)
        return json.loads(response)
```

```swift
// 主 App 轮询读取
Task.detached {
    while !Task.isCancelled {
        pollStateFile()  // 每 200ms 读取
        sleep(200ms)
    }
}
```

**问题**:

| 问题 | 描述 | 影响 |
|------|------|------|
| Hook 脚本回滚 | 脚本经常被恢复到 socket 方式 | 状态文件不更新 |
| 事件顺序不稳定 | Stop 和 idle_prompt 处理顺序颠倒 | 中断判断错误 |
| 轮询延迟 | 200ms 延迟 | 状态更新不够实时 |

**解决方案**:
- Hook 脚本回滚 → 手动修复，需要持续维护
- 事件顺序 → idle_prompt 到达时覆盖之前的 Stop 判断
- 轮询延迟 → 推送版本改进

**结论**: ✅ **基本可用** - 主要工作方式，但需要维护

---

### 方案 4: Interrupt JSONL 监听 (已验证成功)

**时间**: Phase 4 (2026-04-27 验证)

**架构**:
```
Claude Code → JSONL 文件追加 → XPC Helper (Thread.polling) → XPC 回调 → 主 App
```

**实现**:
```swift
// XPC Helper (JSONLInterruptPollingThread.swift)
// 使用 Thread.polling 替代 DispatchSource (XPC Service 兼容)
pollingThread = Thread {
    while isRunning {
        checkForNewContent()
        Thread.sleep(forTimeInterval: 0.5)
    }
}
pollingThread?.start()

// 检测中断模式 (已验证覆盖 JSONL 实际格式)
private static let interruptContentPatterns = [
    "Interrupted by user",          // ✅ JSONL 实际格式: tool_result.is_error + "Interrupted by user"
    "[Request interrupted by user]", // ✅ JSONL 实际格式: user 消息中的文本
    "\"interrupted\":true"
]

// XPC 回调推送 (穿透 Sandbox)
helper?.notifyInterrupt(sessionId: sessionId)
```

```swift
// 主 App (AIXPCListener.swift)
func onInterrupt(sessionId: String) {
    // 收到 XPC 回调，直接处理
    NotificationCenter.default.post(name: .AIInterruptDetected, ...)
}
```

**验证证据 (2026-04-27)**:
```
// JSONL 文件实际写入格式:
{"type":"user","message":{"content":[{"type":"tool_result","content":"Interrupted by user","is_error":true}]}

// XPC Helper 日志:
handleInterrupt: Received interrupt for 39bff100

// 主 App 日志:
handleXPCInterrupt: Session 39bff100 interrupted -> idle
sortedSessions: 39bff100:idle
```

**关键技术决策**:
- 使用 `Thread.polling` 替代 `DispatchSource` → 解决 XPC Service 无 RunLoop 问题
- 检测 `"Interrupted by user"` 文本 → 覆盖 JSONL 实际写入格式
- XPC 回调替代 Darwin Notification → 更可靠，延迟更低

**结论**: ✅ **完全工作** - thinking 阶段 ESC 打断检测链路稳定

---

### 方案 5: XPC 推送版本 (已实现，已验证)

**时间**: Phase 5 (2026-04-27 验证)

**架构**:
```
Claude Code → Hook Python → Socket → XPC Helper → XPC 回调 → 主 App
                                         ↓
                                    状态文件 (备份)
```

**实现**:
```swift
// XPC Helper (AIHookServerCore.swift)
// 收到 Hook 事件后主动推送
helper?.notifyStateUpdate(sessionIds: [sessionId])

// 主 App (AIHookServer.swift)
// 设置 XPC 回调监听
let listener = AIXPCListener()
listener.onStateUpdateReceived = { sessionIds in
    self?.pollSpecificStateFiles(sessionIds: sessionIds)
}
AIXPCClient.shared.setListener(listener)
```

**验证证据 (2026-04-27)**:
```
// XPC Helper 日志:
AIHookServerCore: Sent stateupdate callback for b350c048 via XPC listener

// 主 App 日志:
AIXPCListener: onStateUpdate received with 1 sessions
pollSpecificStateFiles: Processing sessionId=b350c048
```

**关键改进**:
- 毫秒级延迟 (vs 之前 200ms 轮询)
- 穿透 Sandbox 边界 (XPC 回调不受 Sandbox 限制)
- 保留状态文件作为备份 (主 App 仍有 15s fallback 轮询)

**结论**: ✅ **完全工作** - 实时推送链路稳定

---

## 三、方案对比表

| 方案 | 状态 | 优点 | 缺点 | 实时性 |
|------|------|------|------|--------|
| 直接 Socket | ❌ 失败 | 简单 | Sandbox 阻止 | - |
| XPC Socket (DispatchSource) | ❌ 失败 | Unsandboxed | XPC 无 RunLoop，DispatchSource 不触发 | - |
| XPC Socket (Thread.polling) | ✅ 可用 | Unsandboxed，稳定 | 需要 Thread 管理 | 高 |
| Hook 写文件 + 轮询 | ✅ 可用 | 稳定可靠 | 200ms 延迟 | 低 |
| XPC 推送 | ✅ 已验证 | 毫秒级延迟 | 需要 XPC 回调设置 | **高** |
| Interrupt JSONL (Thread.polling) | ✅ 已验证 | 实时检测 ESC 中断 | 需要 Thread 管理 | **高** |
| **Sessions 状态监听** | ✅ 已验证 | **权威 idle 判断**，覆盖所有阶段 | 需要 Thread 管理 | **高** |

---

## 四、Claude-Island 方案对比

**Claude-Island 成功的关键**:
1. **主 App 不在 Sandbox** - 可以直接创建 Socket 和监听文件
2. **DispatchSource 正常工作** - 有 RunLoop
3. **Hook + JSONL 双通道** - Hook 发事件，JSONL 检中断

**BoringNotch 的限制**:
1. **主 App 在 Sandbox** - 无法直接监听 /tmp 下的文件
2. **必须依赖 XPC Helper** - 所有 unsandboxed 操作需要通过 XPC
3. **XPC Service 环境** - 缺少 RunLoop，很多异步机制失效

---

## 五、当前推荐方案 (2026-04-28 更新)

**当前已实现 (全部验证通过)**:
- ✅ XPC 推送: 毫秒级延迟，穿透 Sandbox
- ✅ JSONL Interrupt: thinking 阶段 ESC 中断检测
- ✅ Sessions 状态监听: 权威 idle 判断，覆盖所有阶段
- ✅ 15s fallback 轮询: 防止 XPC 回调丢失
- ✅ Per-session 状态文件: 多 session 支持

**架构图**:
```
┌─────────────────────────────────────────────────────────────────────────┐
│                        完整推送链路 (已验证)                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Hook Python 脚本                                                        │
│       ↓ Socket                                                           │
│  XPC Helper (AIHookServerCore)                                           │
│       ├─ Thread.polling 接收数据                                         │
│       ├─ 写入状态文件 (per-session, atomically)                          │
│       └─ helper.notifyStateUpdate(sessionIds) ← 推送!                    │
│              ↓ XPC 回调 (毫秒级)                                          │
│  主 App (AIXPCListener)                                                  │
│       └─ onStateUpdate → pollSpecificStateFiles()                        │
│                                                                          │
│  Sessions 状态监听 (新增，权威 idle 判断)                                  │
│  XPC Helper (SessionsWatcher)                                            │
│       ├─ Thread.polling 监听 ~/.claude/sessions/*.json (300ms)           │
│       ├─ 检测 busy → idle 状态变化                                        │
│       └─ helper.notifySessionStatus(sessionId, status) ← 推送!           │
│              ↓ XPC 回调                                                   │
│  主 App (AIXPCListener)                                                  │
│       └─ onSessionStatus → handleSessionsStatus()                        │
│       └─ idle 状态权威，不被 Hook 事件覆盖                                 │
│                                                                          │
│  JSONL Interrupt (可选补充)                                               │
│  XPC Helper (JSONLInterruptPollingThread)                                │
│       ├─ Thread.polling 监听 JSONL 文件 (500ms)                          │
│       ├─ 检测 "Interrupted by user"                                      │
│       └─ helper.notifyInterrupt(sessionId) ← 推送!                       │
│              ↓ XPC 回调                                                   │
│  主 App (AIXPCListener)                                                  │
│       └─ onInterrupt → handleXPCInterrupt()                              │
│                                                                          │
│  Fallback (兜底机制)                                                      │
│  主 App (AIHookServer)                                                   │
│       └─ 15s 轮询 pollStateFiles() ← 防止 XPC 回调丢失                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**状态合并逻辑**:
```
Sessions status="idle" → 最终状态就是 idle (权威，不可覆盖)
Sessions status="busy" + Hook event → 详细 phase
  ├─ busy + waiting_for_approval → waitingForApproval
  ├─ busy + running_tool → runningTool
  ├─ busy + compacting → compacting
  └─ busy + 其他 → processing
```

**未来可选改进**:
- 研究更频繁的 fallback 轮询（如 5s）以进一步降低丢失风险
- 调研多 Agent 支持（Codex/OpenCode/Cursor）
- 考虑 NSFileCoordinator 监听状态文件变化（可能更可靠）

---

## 六、关键技术限制总结 (2026-04-27 更新)

| 技术 | Sandbox 主 App | XPC Service | Unsandboxed App |
|------|---------------|-------------|-----------------|
| 创建 /tmp/*.sock | ❌ 阻止 | ✅ 允许 | ✅ 允许 |
| DispatchSource | ❌ 阻止 | ❌ **不触发** (无 RunLoop) | ✅ 正常 |
| Thread.polling | ✅ 工作 | ✅ **工作** | ✅ 正常 |
| Task.detached | ✅ 工作 | ⚠️ 不稳定 | ✅ 正常 |
| FileHandle.readabilityHandler | ❌ 阻止 | ❌ 不稳定 | ✅ 正常 |
| 轮询读取文件 | ✅ 工作 | ✅ 工作 | ✅ 工作 |
| XPC 回调 (推送) | ✅ **工作** | ✅ **工作** | ✅ 正常 |

**核心问题已解决**: 使用 `Thread.polling` 替代 `DispatchSource`，解决了 XPC Service 无 RunLoop 问题。

**推送链路已验证**: XPC 回调 `notifyStateUpdate` / `notifyInterrupt` 穿透 Sandbox，毫秒级延迟。

---

## 七、文件路径记录

| 文件 | 作用 | 状态 |
|------|------|------|
| `~/.claude/hooks/boringnotch-ai-state.py` | Hook 脚本 | ✅ 工作 |
| `~/Library/Containers/.../boringnotch-ai-state-*.json` | 状态文件 (per-session) | ✅ 工作 |
| `boringNotch/AI/AIManager.swift` | 状态管理 | ✅ 工作 |
| `boringNotch/AI/AIHookServer.swift` | XPC 回调接收 + 15s fallback 轮询 | ✅ 工作 |
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | XPC Socket Server + 推送 | ✅ 工作 |
| `BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift` | JSONL 中断检测 (Thread.polling) | ✅ **已验证** |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | XPC 通信 | ✅ 工作 |
| `boringNotch/XPCHelperClient/AIXPCListener.swift` | XPC 回调监听 | ✅ 工作 |

---

## 八、验证历史

| 日期 | 验证内容 | 结果 |
|------|---------|------|
| 2026-04-27 | XPC 推送链路 (notifyStateUpdate) | ✅ 毫秒级延迟 |
| 2026-04-27 | JSONL Interrupt 检测 (Thread.polling) | ✅ thinking 阶段 ESC 可检测 |
| 2026-04-27 | JSONL 文件格式 ("Interrupted by user") | ✅ 与检测模式匹配 |
| 2026-04-28 | Sessions 状态监听 (SessionsWatcher) | ✅ busy → idle 立即检测 |
| 2026-04-28 | ESC 打断检测 (UserPromptSubmit 后) | ✅ Sessions 状态覆盖所有阶段 |
| 2026-04-28 | 状态合并逻辑 | ✅ idle 不被 Hook 覆盖 |