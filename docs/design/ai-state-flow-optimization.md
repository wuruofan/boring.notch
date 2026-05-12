# AI 状态流转优化设计

> 基于 `ai-state-flow-logic.md` 和 `ai-approaches-history.md` 的综合分析，梳理当前逻辑漏洞并提出优化方案。

---

## 一、当前架构问题总览

系统存在三条数据通道，但缺乏协调机制：

| 通道 | 方向 | 机制 | 延迟 |
|------|------|------|------|
| Hook → 状态文件 → 主 App 轮询 | 推→拉 | 200ms 轮询 | 0~200ms |
| Hook → Socket → XPC Helper → 状态文件 → 主 App 轮询 | 推→拉 | 100ms+200ms | 0~300ms |
| JSONL → XPC Helper DispatchSource → Darwin Notification → 主 App | 推→推 | 实时 | 理论极低 |

**核心矛盾**：三条通道可能对同一个 session 产生冲突的状态更新，没有优先级或去重机制。

---

## 二、关键漏洞

### 漏洞 1：Stop 与 idle_prompt 的竞态 [严重]

**现状**：Hook 脚本先发 `Stop`（status=`stop_pending`），后发 `Notification`（status=`waiting_for_input`）。主 App 200ms 轮询可能：

- **正常顺序**：Stop → idle → idle_prompt 覆盖为 waitingForInput ✅
- **乱序**：idle_prompt 先到，此时 session 还是 `processing`，`sessions[id]?.phase == .idle` 检查失败，idle_prompt **被丢弃**。随后 Stop 到达，session 变为 `idle`。**结果：任务完成被误判为中断** ❌

**根因**：`handleHookEvent` 中 idle_prompt 的覆盖条件是 `sessions[id]?.phase == .idle`，但 idle_prompt 可能先于 Stop 到达。

**修复方案**：

```swift
// 方案 A：idle_prompt 无条件覆盖（推荐，最简单）
if phase == .waitingForInput {
    // 无论当前 phase 是什么，idle_prompt 都意味着任务完成
    session.phase = .waitingForInput
    lastIdlePromptTime[effectiveSessionId] = Date()
}

// 方案 B：放宽覆盖条件
if phase == .waitingForInput {
    lastIdlePromptTime[effectiveSessionId] = Date()
    let currentPhase = sessions[effectiveSessionId]?.phase
    if currentPhase == .idle || currentPhase == .processing || currentPhase == .runningTool {
        session.phase = .waitingForInput
    }
}
```

方案 A 的合理性：`idle_prompt`（Notification 事件中的 `idle_prompt` 子类型）在 Claude Code 的语义中**只会在任务完成后发出**，不可能在任务进行中发出。所以无条件覆盖是安全的。

---

### 漏洞 2：`stopCompletionWindow` 和 `lastIdlePromptTime` 是死代码 [严重]

**位置**：`AIManager.swift:77`、`AIManager.swift:74`

`stopCompletionWindow = 15.0` 和 `lastIdlePromptTime` 字典被定义和写入，但**从未被读取**。原本设计是用时间窗口区分中断和完成，但逻辑从未实现。

**影响**：如果修复了漏洞 1（idle_prompt 无条件覆盖），这两个死代码可以清理掉。但如果想保留时间窗口方案作为额外保护，需要补全逻辑。

**建议**：修复漏洞 1 后，删除 `stopCompletionWindow` 和 `lastIdlePromptTime`，它们不再需要。

---

### 漏洞 3：XPC Interrupt 与 Hook Stop 的竞态 [严重]

**场景**：
1. 用户按 ESC
2. JSONL 文件写入中断标记 → XPC Helper DispatchSource 触发 → Darwin Notification → 主 App `handleXPCInterrupt` → 设为 `.idle`
3. 几乎同时，Hook 发 Stop → 主 App 收到 `stop_pending` → 设为 `.idle`
4. 稍后，Hook 发 idle_prompt（如果 Claude Code 在中断前已完成）→ 主 App 收到 `waiting_for_input` → 覆盖为 `.waitingForInput`

**结果**：用户 ESC 中断被误判为任务完成 ❌

**修复方案**：XPC Interrupt 应设置一个标记，阻止后续 idle_prompt 覆盖：

```swift
// AIManager 新增
private var interruptedSessions: Set<String> = []

func handleXPCInterrupt(sessionId: String) {
    interruptedSessions.insert(sessionId)
    if var session = sessions[sessionId] {
        session.phase = .idle
        session.lastUpdated = Date()
        sessions[sessionId] = session
    }
    Task {
        await AIXPCClient.shared.stopInterruptWatcher(sessionId: sessionId)
    }
    updateCoordinator()
}

// handleHookEvent 中
if phase == .waitingForInput {
    if interruptedSessions.contains(effectiveSessionId) {
        // 中断后的 idle_prompt，忽略
        interruptedSessions.remove(effectiveSessionId)
        appendAILog("handleHookEvent: idle_prompt after interrupt, ignoring")
        return  // 或 continue，取决于上下文
    }
    session.phase = .waitingForInput
    lastIdlePromptTime[effectiveSessionId] = Date()
}
```

---

### 漏洞 4：状态文件非原子写入 [中等]

**位置**：`AIHookServerCore.swift:282`

```swift
try? str.write(toFile: Self.stateFilePath, atomically: false, encoding: .utf8)
```

主 App 可能读到半截 JSON。虽然 `try? JSONDecoder` 会静默失败，但**事件被丢弃**可能导致状态卡死。

**修复**：改为 `atomically: true`：

```swift
try? str.write(toFile: Self.stateFilePath, atomically: true, encoding: .utf8)
```

原子写入先写临时文件再 rename，保证主 App 要么读到旧数据要么读到新数据，不会读到半截。

---

### 漏洞 5：`convertStaleProcessingToIdle` 不更新 coordinator [中等]

**位置**：`AIManager.swift:424-445`

超时后设置 `sessions[id]?.phase = .idle`，但没有调用 `updateCoordinator()`，也没有重新评估 `activeSessionId`。UI 不会更新。

**修复**：在循环结束后调用 `updateCoordinator()`：

```swift
func convertStaleProcessingToIdle() {
    let now = Date()
    var changed = false
    for (sessionId, session) in sessions {
        // ... 原有超时判断逻辑 ...
        if now.timeIntervalSince(session.lastUpdated) > timeout {
            sessions[sessionId]?.phase = .idle
            changed = true
        }
    }
    if changed {
        updateCoordinator()
    }
}
```

---

### 漏洞 6：Hook 脚本回滚问题 [中等]

Hook 脚本经常被恢复到 socket 方式。从 `AIHookInstaller.swift` 看，脚本在 App 启动时写入，但 Claude Code 更新时可能覆盖 `settings.json`，导致 hook 注册丢失。

**修复方向**：
- 在 App 进入前台时检查 hook 注册是否完整，丢失则重新安装
- 或在 `settings.json` 中使用 `include` 机制（如果 Claude Code 支持）

---

### 漏洞 7：Darwin Notification 扫描 /tmp 性能问题 [低]

**位置**：`AIXPCClient.swift:80-103`

收到 Darwin Notification 后扫描整个 `/tmp` 目录查找 `boringnotch-interrupt-*.txt`。如果 `/tmp` 文件很多，会有性能问题。

**修复**：已知 sessionId 时直接构造路径读取，而非扫描目录。或在 XPC 调用中传递 sessionId（绕过 Darwin Notification 的无 payload 限制）。

---

## 三、优化后的理想状态流转

```
Hook 事件 → XPC Helper 写入状态文件(原子写入)
                    │
                    │ XPC 回调推送（替代轮询）
                    ▼
              主 App AIManager
                    │
                    ├─ processing / running_tool / compacting → 正常更新
                    │
                    ├─ stop_pending → idle + 启动 15s 窗口
                    │       ├─ 窗口内收到 idle_prompt → waitingForInput (完成)
                    │       ├─ 窗口内收到 XPC interrupt → idle (中断，标记阻止后续覆盖)
                    │       └─ 窗口超时 → idle (超时)
                    │
                    ├─ waitingForInput → 直接设置（如果未被 interrupt 标记阻止）
                    │
                    └─ ended → 移除 session
```

关键改进点：
- **原子写入**保证不丢事件
- **XPC 推送**消除轮询延迟和乱序
- **interrupt 标记**防止竞态
- **时间窗口**作为兜底保护（如果推送延迟）

---

## 四、分阶段实施计划

### 短期（立即可做，低风险）

| # | 改动 | 文件 | 说明 |
|---|------|------|------|
| 1 | 修复 idle_prompt 覆盖逻辑 | `AIManager.swift` | 无条件覆盖或放宽覆盖条件（漏洞 1） |
| 2 | 状态文件原子写入 | `AIHookServerCore.swift` | `atomically: false` → `atomically: true`（漏洞 4） |
| 3 | 超时后更新 UI | `AIManager.swift` | `convertStaleProcessingToIdle` 末尾加 `updateCoordinator()`（漏洞 5） |
| 4 | 清理死代码 | `AIManager.swift` | 删除未使用的 `stopCompletionWindow` 和 `lastIdlePromptTime`（漏洞 2） |

### 中期（需要验证，中风险）

| # | 改动 | 文件 | 说明 |
|---|------|------|------|
| 5 | 验证 JSONL Interrupt 链路 | 多文件 | DispatchSource → Darwin Notification → 主 App 全链路测试 |
| 6 | 添加 XPC Interrupt 标记 | `AIManager.swift` | 防止中断后的 idle_prompt 误覆盖（漏洞 3） |
| 7 | Hook 脚本保活 | `AIHookInstaller.swift` | 定期检查 hook 注册是否完整，自动修复（漏洞 6） |

### 长期（架构改进）

| # | 改动 | 说明 |
|---|------|------|
| 8 | XPC Helper 推送模式 | XPC Helper 读取状态文件后通过 XPC 回调主动通知主 App，消除 200ms 轮询延迟 |
| 9 | 统一数据通道 | 当前 Hook 写文件 + Socket 双通道增加复杂度，考虑统一为单一通道 |
| 10 | 评估移除 Sandbox | 如果可行，主 App 直接用 DispatchSource 监听文件，彻底解决 XPC 环境限制 |

---

## 五、漏洞与代码位置索引

| 漏洞 | 严重程度 | 代码位置 | 关联文档 |
|------|---------|---------|---------|
| Stop 与 idle_prompt 竞态 | 严重 | `AIManager.swift:237-244` | ai-state-flow-logic.md 第三节 |
| stopCompletionWindow 死代码 | 严重 | `AIManager.swift:77` | ai-state-flow-logic.md 第三节 |
| XPC Interrupt 与 Hook Stop 竞态 | 严重 | `AIManager.swift:452-468` | ai-state-flow-logic.md 第四节 |
| 非原子写入 | 中等 | `AIHookServerCore.swift:282` | ai-approaches-history.md 方案 3 |
| 超时不更新 UI | 中等 | `AIManager.swift:424-445` | 新发现 |
| Hook 脚本回滚 | 中等 | `AIHookInstaller.swift` | ai-approaches-history.md 方案 3 |
| /tmp 扫描性能 | 低 | `AIXPCClient.swift:80-103` | 新发现 |
