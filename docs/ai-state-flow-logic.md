# AI 状态流转逻辑梳理

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Claude Code                                     │
│  ┌────────────────┐                                                      │
│  │ Hook 事件触发   │ ──stdin JSON──→ Hook 脚本                            │
│  │ (各种事件)     │                                                      │
│  └────────────────┘                                                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Hook 脚本 (Python)                                │
│  ~/.claude/hooks/boringnotch-ai-state.py                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 1. 解析 stdin JSON 获取事件类型                                    │  │
│  │ 2. 映射事件到 status (processing/running_tool/stop_pending 等)    │  │
│  │ 3. 直接写入状态文件 (主要方式)                                     │  │
│  │ 4. 权限请求时也尝试 socket (需要等待响应)                          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 写入状态文件
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    状态文件 (JSON)                                       │
│  ~/Library/Containers/.../Caches/boringnotch-ai-state.json              │
│  {                                                                       │
│    "session_id": "...",                                                  │
│    "event": "Stop",                                                      │
│    "status": "stop_pending",                                             │
│    ...                                                                   │
│  }                                                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 轮询读取 (200ms 间隔)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    主 App (AIHookServer)                                 │
│  sandboxed，无法使用 DispatchSource 监听文件                             │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ Task.detached {                                                   │  │
│  │   while !Task.isCancelled {                                      │  │
│  │     pollStateFile()  // 读取状态文件                              │  │
│  │     processStateFile() // 解析 JSON                              │  │
│  │     onEvent?(event)  // 传递给 AIManager                         │  │
│  │     sleep(200ms)                                                 │  │
│  │   }                                                              │  │
│  │ }                                                                │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ onEvent 回调
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    AIManager (状态管理)                                  │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ handleHookEvent(event):                                          │  │
│  │   1. 根据 event.status 确定 phase                                │  │
│  │   2. 特殊处理 stopPending → idle (暂时)                          │  │
│  │   3. idle_prompt 覆盖之前的 Stop 判断                            │  │
│  │   4. 更新 sessions[sessionId]                                    │  │
│  │   5. updateCoordinator() 更新 UI                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、Hook 事件类型与状态映射

| Hook 事件 | status | AISessionPhase | 说明 |
|-----------|--------|----------------|------|
| UserPromptSubmit | processing | .processing | 用户提交新 prompt |
| PreToolUse | running_tool | .runningTool | 开始执行工具 |
| PostToolUse | processing | .processing | 工具执行完毕 |
| PermissionRequest | waiting_for_approval | .waitingForApproval | 需要权限审批 |
| Stop | stop_pending | .stopPending → .idle | **特殊：需要判断是中断还是完成** |
| Notification (idle_prompt) | waiting_for_input | .waitingForInput | 任务完成，等待新输入 |
| SubagentStop | waiting_for_input | .waitingForInput | 子 Agent 完成 |
| SessionStart | waiting_for_input | .waitingForInput | 新 session 启动 |
| SessionEnd | ended | .ended | Session 结束，移除 |
| PreCompact | compacting | .compacting | 压缩上下文 |

---

## 三、Stop 事件的歧义性处理

### 问题
`Stop` 事件有两种含义：
1. **ESC 中断**：用户按下 ESC 打断正在进行的任务
2. **任务完成**：Claude 完成任务后自然停止

Hook 脚本无法区分这两种情况，只能发送相同的 `Stop` 事件。

### 当前解决方案

```
Stop 事件到达 → 暂时设为 idle
                    │
                    ├── 如果后续有 idle_prompt → 覆盖为 waitingForInput (任务完成)
                    │
                    └── 如果没有 idle_prompt → 保持 idle (ESC 中断)
```

**代码逻辑** (AIManager.swift):
```swift
// Stop → idle (暂时)
if phase == .stopPending {
    session.phase = .idle
}

// idle_prompt 覆盖之前的 Stop 判断
if phase == .waitingForInput {
    if sessions[effectiveSessionId]?.phase == .idle {
        session.phase = .waitingForInput  // 任务完成
    }
}
```

### 已知问题
**事件顺序不稳定**：由于轮询机制，Stop 和 idle_prompt 的处理顺序可能颠倒。
- Hook 脚本：先发 Stop，后发 idle_prompt
- App 端：可能先处理 idle_prompt，后处理 Stop（因为轮询间隔）

**解决方案**：idle_prompt 到达时检查 session 是否为 idle，如果是则覆盖。

---

## 四、Interrupt 方案（JSONL 文件监听）

### 目标
实时检测 ESC 中断，不依赖 Hook 事件顺序。

### 架构
```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Claude Code JSONL 文件                                │
│  ~/.claude/projects/<cwd>/<session_id>.jsonl                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ 每次用户交互追加一行：                                             │  │
│  │ {"type":"user", "message":"[Request interrupted by user]"}        │  │
│  │ {"tool_result", "is_error":true, "content":"Interrupted..."}      │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ DispatchSource 文件监听
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    XPC Helper (JSONLInterruptWatcherCore)                │
│  unsandboxed，可以使用 DispatchSource                                    │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ DispatchSource.makeFileSystemObjectSource(                       │  │
│  │   fd, eventMask: [.write, .extend]                               │  │
│  │ )                                                                │  │
│  │                                                                   │  │
│  │ 检测中断模式：                                                    │  │
│  │ - "Interrupted by user"                                          │  │
│  │ - "[Request interrupted by user]"                                │  │
│  │ - "\"interrupted\":true"                                         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Darwin Notification
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    主 App (AIXPCClient)                                  │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ CFNotificationCenterAddObserver(                                 │  │
│  │   kInterruptNotificationName                                     │  │
│  │ )                                                                │  │
│  │                                                                   │  │
│  │ onInterruptDetected?(sessionId) → AIManager.handleXPCInterrupt() │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 当前状态
**实现完成但未验证**：
- XPC Helper: JSONLInterruptWatcherCore 已实现
- 主 App: AIXPCClient Darwin Notification 已实现
- AIManager: handleXPCInterrupt 已实现

**潜在问题**：
1. XPC Service 中 DispatchSource 可能不稳定
2. Darwin Notification 跨进程通信可能延迟
3. 需要实际测试验证整个链路

---

## 五、状态流转完整流程

### 状态流转图 (简化版)

```
                              ┌─────────────┐
                              │   START     │
                              │ (新建session)│
                              └──────┬──────┘
                                     │
                                     │ SessionStart / SubagentStop
                                     ▼
                            ┌─────────────────────┐
                            │ waiting_for_input   │◄──────────────────────┐
                            │ (等待用户输入)       │                        │
                            └─────────┬───────────┘                        │
                                      │                                     │
                                      │ UserPromptSubmit                    │
                                      ▼                                     │
                            ┌─────────────────────┐                        │
                      ┌────►│    processing       │                        │
                      │     │   (思考中)          │                        │
                      │     └─────────┬───────────┘                        │
                      │               │                                     │
                      │               │ PreToolUse                          │
                      │               ▼                                     │
                      │     ┌─────────────────────┐                        │
                      │     │   running_tool      │──── PermissionRequest ─┐
                      │     │   (执行工具)        │                        │
                      │     └─────────┬───────────┘                        │
                      │               │                                     │
                      │               │ PostToolUse                         │
                      │               ▼                                     │
                      │     ┌─────────────────────┐   ┌────────────────────┴┘
                      └─────┤    processing       │   │ waiting_for_approval
                            └─────────┬───────────┘   │ (等待审批)
                                      │               └────────┬──────────┘
                                      │                        │
          ┌───────────────────────────┤            用户 Allow/Deny
          │                           │                        │
          │ Stop                      │                        ▼
          ▼                           │              恢复执行 (下一个 Hook
   ┌─────────────────────┐            │              事件决定状态)
   │       idle          │            │
   │    (暂时状态)       │            │
   └─────────┬───────────┘            │
             │                        │
     ┌───────┴────────┐               │
     │                │               │
     │ idle_prompt    │ 无 idle_prompt│
     │ (无条件覆盖)   │ = ESC中断     │
     ▼                ▼               │
┌──────────────┐ ┌─────────┐          │
│waiting_for_  │ │  idle   │          │
│input(任务完成)│ │(中断/超时)│          │
└──────┬───────┘ └─────────┘          │
       │                               │
       └───────────────────────────────┘

   PreCompact ────────────────► compacting ───────────────► processing

   SessionEnd ────────────────► 移除 session

   超时兜底 ──────────────────► idle

   注: idle_prompt 可能先于 Stop 到达 (事件乱序)，
       无条件覆盖保证无论到达顺序如何都能正确判断。
```

### 核心路径说明

**正常任务完成**：
```
waiting_for_input → processing → running_tool → processing → Stop → idle
                                                              ↓
                                                        idle_prompt (无条件覆盖)
                                                              ↓
                                                      waiting_for_input ✓
```

**ESC 中断**：
```
processing → Stop → idle → (无 idle_prompt) → idle ✓
```

**权限审批**：
```
running_tool → waiting_for_approval → 用户 Allow/Deny → 恢复执行 (下一个 Hook 事件决定状态)
```

**超时兜底**：
```
processing/running_tool/compacting 超时 → idle
```

### 关键改动说明

| 场景 | 改动前 | 改动后 |
|------|--------|--------|
| **任务完成** | Stop → 判断时间窗口 → idle/waitingForInput | Stop → idle → idle_prompt **无条件**覆盖为 waitingForInput |
| **ESC 中断** | Stop → 检查是否有 recent idle_prompt → idle | Stop → idle → 无 idle_prompt → 保持 idle |
| **事件乱序** | idle_prompt 先到 → 检查失败 → 被丢弃 | idle_prompt 先到 → **无条件生效** |

---

## 六、超时机制

### 处理状态超时
由于某些情况下 Hook 事件可能丢失，AIManager 有超时机制：

```swift
// 每 10 秒检查
func convertStaleProcessingToIdle() {
    // processing: 15 秒超时
    // running_tool: 120 秒超时 (工具执行可能很长)
    // compacting: 60 秒超时
}
```

---

## 七、当前状态

### 已完成改进 (2025-04-17)

1. ✅ **idle_prompt 无条件覆盖**
   - 解决了 Stop 和 idle_prompt 的竞态问题
   - idle_prompt 无论何时到达都直接设为 waitingForInput

2. ✅ **状态文件原子写入**
   - `atomically: false` → `atomically: true`
   - 防止读到半截 JSON 导致事件丢失

3. ✅ **超时后更新 UI**
   - `convertStaleProcessingToIdle` 循环后调用 `updateCoordinator()`
   - 超时状态不再卡死

4. ✅ **超时后更新 activeSessionId**
   - 被超时的 session 如果是当前活跃 session，会重新评估其他 session
   - 防止 UI 显示不一致状态

5. ✅ **清理死代码**
   - 删除未使用的 `stopCompletionWindow` 和 `lastIdlePromptTime`

### 未修复问题

#### 问题 1：XPC Interrupt 与 idle_prompt 的竞态 [严重 - 依赖链路验证]

**位置**: `AIManager.swift:449-465`

**场景**：
1. 用户 ESC → JSONL 检测到中断 → handleXPCInterrupt → .idle
2. Hook idle_prompt 到达 → 无条件覆盖为 .waitingForInput ❌

**修复方案**（待 Interrupt 链路验证后实施）：
```swift
// AIManager 新增
private var interruptedSessions: Set<String> = []

// handleXPCInterrupt 中添加标记
func handleXPCInterrupt(sessionId: String) {
    interruptedSessions.insert(sessionId)
    // ... 原有逻辑
}

// handleHookEvent 中检查标记
if phase == .waitingForInput {
    if interruptedSessions.contains(effectiveSessionId) {
        interruptedSessions.remove(effectiveSessionId)
        return  // 不覆盖，保持 idle
    }
    session.phase = .waitingForInput
}
```

**状态**: 暂不修复，因为 Interrupt 链路未验证。如果链路不工作，此问题不存在。

#### 问题 2：Darwin Notification 扫描 /tmp [低]

**位置**: `AIXPCClient.swift:79-103`

每次收到 Darwin Notification 都扫描整个 `/tmp` 目录查找 interrupt 文件。

**影响**: Interrupt 事件频率低，实际性能影响有限。

**状态**: 暂不处理。

#### 问题 3：stopPending 是瞬态枚举值 [低]

**位置**: `AISessionState.swift:11`

`stopPending` 在枚举中定义，但永远不会被存入 sessions 字典（收到后立即转为 idle）。

**建议**: 添加注释说明它是瞬态值，仅供 `toPhase()` 转换使用。

**状态**: 暂不处理。

### 待验证

1. **Interrupt 链路验证** (优先级高)
   - JSONL 监听 + Darwin Notification 全链路测试
   - 验证后决定是否实施问题 1 的修复

2. **Hook 脚本稳定性**
   - 脚本偶尔被回滚到 socket 方式
   - 需要持续维护

#### 问题 4：多 Session 并发事件覆盖 [中等 - 架构限制]

**位置**: 整体架构设计

**场景**：单一状态文件 + 多 session 并发运行时，Hook 事件轮流写入同一文件：

```
时间线：
T0: dotfiles session Stop → 写入状态文件
T1 (100ms): boring.notch session PreToolUse → 覆盖状态文件
T2 (200ms): 主 App 轮询 → 只读到 boring.notch 的 PreToolUse
           dotfiles 的 Stop 已被覆盖，丢失！
```

**影响**：
- ESC 中断事件可能被其他 session 的事件覆盖
- 最终依赖超时兜底机制，状态正确但响应延迟（最多 15 秒）

**验证日志** (2025-04-17 测试)：
- dotfiles session ESC 中断 → Stop 事件被覆盖 → 未触发 idle
- 最终通过 `convertStaleProcessingToIdle` 超时兜底 → idle（状态正确）

**修复方案**：

方案 A：每 session 独立状态文件
```
状态文件路径改为：
~/Library/Caches/boringnotch-ai-state-{session_id}.json
主 App 轮询时需扫描多个文件
```

方案 B：XPC 推送模式（避免轮询覆盖）
```
XPC Helper 读取后立即推送，而非依赖轮询
需解决 XPC Service 无 RunLoop 的问题
```

方案 C：事件队列（保留历史）
```
状态文件改为 JSONL 格式，追加而非覆盖
主 App 读取时按时间戳排序处理
```

**状态**: 暂不修复，超时兜底机制可保证最终状态正确。

---

## 八、后续改进方向

### 方案 A：维持当前简化方案 (推荐)
- 当前方案已能正确处理任务完成和 ESC 中断
- idle_prompt 无条件覆盖解决了核心竞态问题
- 超时兜底防止状态卡死

### 方案 B：启用 Interrupt 机制 (可选补充)
- 验证 JSONL 监听链路是否工作
- 如果成功，可添加 interrupt 标记防止误覆盖
- 作为方案 A 的补充保护

### 方案 C：推送版本 (长期优化)
- XPC Helper 轮询 + 主动推送
- 消除 200ms 轮询延迟
- 实现复杂度较高，收益有限

---

## 九、关键文件路径

| 文件 | 路径 | 作用 |
|------|------|------|
| Hook 脚本 | `~/.claude/hooks/boringnotch-ai-state.py` | 接收 Claude Code 事件 |
| 状态文件 | `~/Library/Containers/.../Caches/boringnotch-ai-state.json` | Hook 写入，App 读取 |
| AIManager | `boringNotch/AI/AIManager.swift` | 状态管理核心 |
| AIHookServer | `boringNotch/AI/AIHookServer.swift` | 文件轮询读取 |
| XPC Helper Core | `BoringNotchAIXPCHelper/AIHookServerCore.swift` | Socket 服务器 |
| Interrupt Watcher | `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift` | JSONL 监听 |
| AIXPCClient | `boringNotch/XPCHelperClient/AIXPCClient.swift` | XPC 通信 + Darwin Notification |