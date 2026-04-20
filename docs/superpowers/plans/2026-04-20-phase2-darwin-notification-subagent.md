# Phase 2: Darwin Notification 推送 + 子 Agent 追踪 + 新事件处理实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** XPC Helper 写入状态文件后直接发送 Darwin Notification，主 App 立即响应消除 200ms 轮询延迟；实现子 Agent 计数追踪和新事件状态处理

**Architecture:** XPC Helper `notify_post()` 直接推送，主 App Darwin Notification 监听 + 5s 低频兜底轮询；AIManager 维护 subagentCount，SubagentStart/Stop 只计数不改 phase

**Tech Stack:** Swift, Darwin Notification (CFNotificationCenter), Thread-based file monitoring, state machine

---

## 前置条件

- Phase 1 已完成：Per-Session 状态文件机制已实现
- Hook 脚本已更新：支持 SubagentStart/Stop 等新事件

---

## 文件结构

**新建文件：**
- 无（所有改动在现有文件）

**修改文件：**
- `BoringNotchAIXPCHelper/AIHookServerCore.swift` - 写入后 notify_post()
- `boringNotch/XPCHelperClient/AIXPCClient.swift` - 新增 Darwin Notification 监听 (stateupdate)
- `boringNotch/AI/AIHookServer.swift` - 移除 200ms 轮询，改为事件驱动 + 5s 兜底
- `boringNotch/AI/AIManager.swift` - subagentCount 维护，新状态超时处理
- `boringNotch/AI/Models/AISessionState.swift` - 新增 subagentCount 字段

---

## Task 1: XPC Helper 写入后 notify_post()

**Files:**
- Modify: `BoringNotchAIXPCHelper/AIHookServerCore.swift`

- [ ] **Step 1: 添加 Darwin Notification 发送**

在写入状态文件后调用 notify_post()。找到 `handleClient()` 中写入状态文件的位置（约 282 行），在写入后添加：

```swift
// Write to state file
let encodedId = Self.encodeSessionId(sessionId)
let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"
try? str.write(toFile: path, atomically: true, encoding: .utf8)

// Send Darwin Notification to notify main app immediately
let notificationName = "com.boringnotch.ai.stateupdate" as CFString
CFNotificationCenterPostNotification(
    CFNotificationCenterGetDarwinNotifyCenter(),
    CFNotificationName(notificationName),
    nil, nil, true
)
NSLog("AIHookServerCore: Sent stateupdate notification for \(sessionId.prefix(8))")
```

- [ ] **Step 2: 添加 import Foundation（如缺失）**

确保文件顶部有：
```swift
import Foundation
```

CFNotificationCenter 需要 Foundation 模块。

- [ ] **Step 3: 验证编译**

运行：`xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add BoringNotchAIXPCHelper/AIHookServerCore.swift
git commit -m "feat(xpc): send Darwin Notification after state file write"
```

---

## Task 2: AIXPCClient 新增 stateupdate Darwin Notification 监听

**Files:**
- Modify: `boringNotch/XPCHelperClient/AIXPCClient.swift`

- [ ] **Step 1: 添加通知名称常量**

在文件顶部 `kInterruptNotificationName` 后添加：

```swift
/// Darwin notification name for state file updates
let kStateUpdateNotificationName = "com.boringnotch.ai.stateupdate"
```

- [ ] **Step 2: 添加状态更新回调**

在 `onInterruptDetected` 属性后添加：

```swift
    /// Callback when state file update is detected via Darwin Notification
    var onStateUpdateDetected: (() -> Void)?
```

- [ ] **Step 3: 添加 Darwin Notification 监听器**

在 `setupDarwinNotificationListener()` 方法后添加新方法：

```swift
    private func setupStateUpdateListener() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { center, observer, name, object, userInfo in
                // Notify callback to scan state files
                Task { @MainActor in
                    AIXPCClient.shared.onStateUpdateDetected?()
                }
            },
            kStateUpdateNotificationName as CFString,
            nil,
            CFNotificationSuspensionBehavior.deliverImmediately
        )
        
        NSLog("AIXPCClient: Darwin notification listener set up for state updates")
    }
```

- [ ] **Step 4: 在 ensureRemoteService 中调用监听器设置**

在 `setupDarwinNotificationListener()` 调用后添加：

```swift
// Set up Darwin Notification listener for interrupts
setupDarwinNotificationListener()

// Set up Darwin Notification listener for state updates
setupStateUpdateListener()
```

- [ ] **Step 5: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add boringNotch/XPCHelperClient/AIXPCClient.swift
git commit -m "feat(xpc-client): add stateupdate Darwin Notification listener"
```

---

## Task 3: AIHookServer 事件驱动 + 动态兜底轮询（waitingForApproval 加速）

**Files:**
- Modify: `boringNotch/AI/AIHookServer.swift`

**说明：** waitingForApproval 状态对用户体验影响大，需要更短的兜底轮询间隔（1s 而非 5s）。

- [ ] **Step 1: 添加动态轮询间隔属性**

在 `AIHookServer` 中添加状态检测属性和 Task 存储：

```swift
    // Thread-safe storage for notification observer
    private var notificationObserverTask: Task<Void, Never>?
    
    // @MainActor isolated state for polling speed
    @MainActor private var hasWaitingForApproval: Bool = false
    
    func start() {
        appendLog("AIHookServer.start() - path=\(Self.stateFileBasePath)\n")
        
        // Set up Darwin Notification callback for immediate response
        AIXPCClient.shared.onStateUpdateDetected = { [weak self] in
            self?.pollStateFiles()
        }
        
        // Observe AIManager for waitingForApproval state changes
        // Store Task for cleanup in stop()
        notificationObserverTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AIWaitingForApprovalChanged) {
                self?.updatePollingSpeed()
            }
        }
        
        startPolling()
    }
    
    @MainActor
    private func updatePollingSpeed() {
        // Check if any session is waitingForApproval
        hasWaitingForApproval = AIManager.shared.hasAnyPendingApproval
        appendLog("updatePollingSpeed: waitingForApproval=\(hasWaitingForApproval)\n")
    }
```

- [ ] **Step 2: 修改轮询间隔（线程安全读取）**

将 `startPolling()` 改为动态间隔，使用 `await MainActor.run` 读取：

```swift
    private func startPolling() {
        appendLog("startPolling: Starting event-driven polling with dynamic fallback\n")
        pollingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                // Thread-safe read: use await MainActor.run to read @MainActor isolated property
                let interval = await MainActor.run {
                    self?.hasWaitingForApproval ?? false ? 1.0 : 5.0
                }
                self?.pollStateFiles()
                try? await Task.sleep(for: .seconds(interval))
            }
            self?.appendLog("polling: Task cancelled\n")
        }
    }
```

**重要说明：** `hasWaitingForApproval` 标记为 `@MainActor`，防止数据竞争。`Task.detached` 中的轮询需要用 `await MainActor.run` 读取，确保线程安全。

- [ ] **Step 3: 添加 Notification.Name 定义**

在 `boringNotch/AI/AIManager.swift` 中发送通知：

```swift
extension Notification.Name {
    static let AIWaitingForApprovalChanged = Notification.Name("AIWaitingForApprovalChanged")
}
```

在 `updateCoordinator()` 中发送：

```swift
    private func updateCoordinator() {
        // ... existing code ...
        
        // Notify polling speed change if waitingForApproval state changed
        let hasApproval = hasAnyPendingApproval
        NotificationCenter.default.post(name: .AIWaitingForApprovalChanged, object: nil)
    }
```

- [ ] **Step 4: 在 stop() 中清除回调并取消 Task**

```swift
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        notificationObserverTask?.cancel()  // Cancel notification observer to prevent leak
        notificationObserverTask = nil
        AIXPCClient.shared.onStateUpdateDetected = nil
        appendLog("AIHookServer.stop() - polling stopped, tasks cancelled, callback cleared\n")
    }
```

- [ ] **Step 5: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add boringNotch/AI/AIHookServer.swift boringNotch/AI/AIManager.swift
git commit -m "feat(ai-server): dynamic polling speed 1s for waitingForApproval"
```

---

## Task 4: AISessionState 新增 subagentCount 字段

**Files:**
- Modify: `boringNotch/AI/Models/AISessionState.swift`

- [ ] **Step 1: 添加 subagentCount 字段**

在 `AISessionState` 结构体中添加：

```swift
struct AISessionState: Identifiable {
    let id: String
    var phase: AISessionPhase
    var currentTool: String?
    var cwd: String?
    var pid: Int?
    var tty: String?
    var permissionRequest: AIPermissionRequest?
    var lastUpdated: Date
    var subagentCount: Int = 0  // Track running subagents
}
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/Models/AISessionState.swift
git commit -m "feat(ai-state): add subagentCount field"
```

---

## Task 5: AIManager SubagentStart/Stop + CwdChanged 处理（移到 toPhase() 之前）

**Files:**
- Modify: `boringNotch/AI/AIManager.swift`

**重要：** SubagentStart/Stop 和 CwdChanged 处理必须在 `let phase = event.toPhase()` 之前，因为这些事件不触发 phase 变换，只更新字段。

- [ ] **Step 1: 重构 handleHookEvent 开头**

将 `handleHookEvent` 方法的开头改为：

```swift
    private func handleHookEvent(_ event: AIHookEvent) {
        let sessionId = event.sessionId
        
        // ===== Early-return events (no phase change) =====
        // Must process BEFORE toPhase() call
        
        // Handle CwdChanged: only update cwd, no phase change
        if event.status == "cwd_changed" || event.event == "CwdChanged" {
            let effectiveSessionId = !sessionId.isEmpty ? sessionId : "unknown"
            if let newCwd = event.cwd, !newCwd.isEmpty {
                sessions[effectiveSessionId]?.cwd = newCwd
                objectWillChange.send()  // Trigger SwiftUI update for cwd display
                appendAILog("handleHookEvent: CwdChanged for \(effectiveSessionId.prefix(8)), new cwd=\(newCwd)\n")
            }
            return  // No phase change, no updateCoordinator
        }
        
        // Handle SubagentStart: only increment count, no phase change
        if event.status == "subagent_active" || event.event == "SubagentStart" {
            let effectiveSessionId = !sessionId.isEmpty ? sessionId : "unknown"
            if sessions[effectiveSessionId] == nil {
                // Defensive: create session if not exists (should have SessionStart first)
                sessions[effectiveSessionId] = AISessionState(
                    id: effectiveSessionId,
                    phase: .processing,
                    cwd: event.cwd,  // Fill cwd from event
                    lastUpdated: Date(),
                    subagentCount: 1
                )
                appendAILog("handleHookEvent: Created session for SubagentStart \(effectiveSessionId.prefix(8)) cwd=\(event.cwd ?? "nil")\n")
            } else {
                sessions[effectiveSessionId]?.subagentCount += 1
                objectWillChange.send()  // Trigger SwiftUI update for [n] badge
                appendAILog("handleHookEvent: SubagentStart for \(effectiveSessionId.prefix(8)), count=\(sessions[effectiveSessionId]?.subagentCount ?? 0)\n")
            }
            return  // No phase change
        }
        
        // Handle SubagentStop: only decrement count, no phase change
        if event.status == "subagent_done" || event.event == "SubagentStop" {
            let effectiveSessionId = !sessionId.isEmpty ? sessionId : "unknown"
            let currentCount = sessions[effectiveSessionId]?.subagentCount ?? 0
            sessions[effectiveSessionId]?.subagentCount = max(0, currentCount - 1)
            objectWillChange.send()  // Trigger SwiftUI update for [n] badge
            appendAILog("handleHookEvent: SubagentStop for \(effectiveSessionId.prefix(8)), count=\(sessions[effectiveSessionId]?.subagentCount ?? 0)\n")
            return  // No phase change
        }
        
        // ===== Phase-transforming events =====
        // Now call toPhase() for other events
        
        let phase = event.toPhase()
        
        // ... rest of handleHookEvent unchanged (SessionEnd handling, etc.)
    }
```

**重要说明：** `sessions[id]?.subagentCount += 1` 这种字典 value 修改不会触发 @Published 的 objectWillChange（因为字典引用未变）。必须手动调用 `objectWillChange.send()` 才能通知 SwiftUI 更新 UI，否则 `[n]` 角标不会显示。对于创建新 session（字典赋值），@Published 会自动触发，无需额外调用。

- [ ] **Step 2: 在 SessionEnd 处理中强制归零 subagentCount**

找到 SessionEnd 处理部分（约 163-190 行），在 `sessions.removeValue(forKey: sessionId)` 前添加：

```swift
        // Force reset subagentCount on SessionEnd
        sessions[sessionId]?.subagentCount = 0
```

- [ ] **Step 3: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add boringNotch/AI/AIManager.swift
git commit -m "feat(ai-manager): process CwdChanged/Subagent before toPhase with cwd fill"
```

---

## Task 6: AIManager 新状态超时处理

**Files:**
- Modify: `boringNotch/AI/AIManager.swift`

- [ ] **Step 1: 在 convertStaleProcessingToIdle 中添加新状态超时**

找到 `convertStaleProcessingToIdle` 方法（约 414-456 行），在 timeout switch 中添加新状态：

```swift
            switch session.phase {
            case .processing:
                timeout = 15  // Thinking phase - short timeout
            case .runningTool:
                timeout = 120  // Tool execution - long timeout (2 minutes)
            case .compacting:
                timeout = 60  // Context compression - medium timeout
            case .toolFailed:
                timeout = 10  // Tool failed - short display then back to idle
            case .error:
                timeout = 10  // Error state - short display then back to idle
            default:
                continue  // Not an active phase, skip
            }
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/AIManager.swift
git commit -m "feat(ai-manager): add timeout rules for toolFailed and error states"
```

---

## Task 7: AIHookEvent toPhase 验证（Phase 1 Task 6 已实现）

**Files:**
- Verify: `boringNotch/AI/Models/AIHookEvent.swift`

**说明：** 此 Task 仅验证 Phase 1 Task 6 的改动是否正确，无需重新实现。

- [ ] **Step 1: 验证 toPhase 已包含新状态**

读取 `AIHookEvent.swift` 确认以下 case 存在：

```swift
case "tool_failed":
    return .toolFailed
case "error":
    return .error
case "subagent_active", "subagent_done":
    return .processing  // Keep current phase, will handle in AIManager
case "cwd_changed":
    return .processing  // No phase change, will handle in AIManager before toPhase()
```

如果缺失，说明 Phase 1 Task 6 未完成，需先完成 Phase 1。

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

---

## Task 8: AISessionPhase needsAttention 和 isActive 验证（Phase 1 Task 6 已实现）

**Files:**
- Verify: `boringNotch/AI/Models/AISessionState.swift`

**说明：** 此 Task 仅验证 Phase 1 Task 6 的改动是否正确，无需重新实现。Phase 1 Task 6 已在添加枚举值时同步更新了 needsAttention 和 isActive 属性。

**重要：** isActive 必须包含 .toolFailed 和 .error，否则 Notch 会隐藏 AI 指示器。

- [ ] **Step 1: 验证 needsAttention 和 isActive 属性**

读取 `AISessionState.swift` 确认以下代码存在：

```swift
    var needsAttention: Bool {
        self == .waitingForApproval || self == .toolFailed || self == .error
    }

    var isActive: Bool {
        self == .processing || self == .runningTool || self == .compacting || self == .toolFailed || self == .error
    }
```

如果缺失，说明 Phase 1 Task 6 未完成，需先完成 Phase 1。

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

---

## Task 9: 验证 Phase 2 功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用**

运行：`open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app`

- [ ] **Step 2: 执行任务测试即时响应**

在 Claude Code 中执行一个任务，观察 Notch 紧凑态是否立即显示 Spinner（无 200ms 延迟）

- [ ] **Step 3: Darwin Notification 丢失兜底测试**

模拟 Darwin Notification 丢失场景（可通过暂停主 App 5 秒），恢复后检查是否通过兜底轮询正确显示状态

- [ ] **Step 4: 子 Agent 测试**

启动子 agent（如进入 Plan 模式），观察展开态 Session Row 是否显示 `[n]` 角标

检查紧凑态是否不因子 agent 事件而频繁切换状态

- [ ] **Step 5: 工具失败测试**

执行一个会失败的命令（如 `cat /nonexistent`），观察 Session Row 第二行是否用红色显示

- [ ] **Step 6: 提交验证结果**

```bash
git add -A
git commit -m "test: phase 2 darwin notification and subagent tracking verification passed"
```

---

## 完成标记

- [ ] Phase 2 实施完成，所有测试通过
- [ ] 代码已提交到 ai-integration 分支