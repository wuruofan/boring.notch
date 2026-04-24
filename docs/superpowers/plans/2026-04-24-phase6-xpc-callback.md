# XPC 协议回调替代 DistributedNotification 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用 XPC 协议回调机制替代 DistributedNotification，实现主 App（沙盒）实时接收 XPC Helper（非沙盒）的状态更新和 ESC 中断通知。

**Architecture:**
1. 主 App 导出 AIXPCListener 对象作为 connection.exportedObject
2. XPC Helper 通过 connection.remoteObjectProxy 获取 listener 并直接调用方法
3. XPC 协议回调天然穿透沙盒边界，无需依赖文件/通知机制

**Tech Stack:** Swift, NSXPCConnection, XPC Protocol, Combine

---

## 前置条件

- ✅ 已完成最小验证：XPC 协议回调可以穿透沙盒边界（testPing 成功）
- ✅ AIXPCEventListener 协议已定义
- ✅ AIXPCListener 类已实现

---

## 文件结构

**修改文件：**
| 文件 | 改动内容 |
|-----|---------|
| `BoringNotchAIXPCHelper/main.swift` | 存储 NSXPCConnection 引用，传递给 Helper |
| `BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift` | 添加 connection 引用，实现回调方法 |
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | 状态更新时调用 listener.onStateUpdate() |
| `BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift` | 中断检测时调用 listener.onInterrupt() |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | 设置 listener，移除 DistributedNotification 监听 |
| `boringNotch/AI/AIHookServer.swift` | 使用 listener 回调替代通知触发 |
| `boringNotch/AI/AIManager.swift` | 处理 listener 回调触发状态更新 |

**清理文件：**
- 移除 `/tmp/boringnotch-notify/` 目录写入逻辑（不再需要）
- 移除 DistributedNotification 监听代码

---

## Task 1: XPC Helper 存储 connection 引用并实现回调发送

**Files:**
- Modify: `BoringNotchAIXPCHelper/main.swift`
- Modify: `BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift`

**现状：** XPC Helper 已保存 connection 引用，但缺少 `notifyStateUpdate()` 和 `notifyInterrupt()` 回调方法。

- [ ] **Step 0: 确认 AIXPCEventListener 协议方法签名**

确认 `BoringNotchAIXPCHelperProtocol.swift` 和 `boringNotch/XPCHelperClient/BoringNotchAIXPCHelperProtocol.swift` 中定义：

```swift
@objc protocol AIXPCEventListener {
    func onStateUpdate(sessionIds: [String])
    func onInterrupt(sessionId: String)
    func ping()
}
```

- [ ] **Step 1: 修改 BoringNotchAIXPCHelper.swift 添加回调发送方法**

在 `BoringNotchAIXPCHelper.swift` 文件中，找到 `getListener()` 方法（已实现），在其后添加：

```swift
// MARK: - Real-time Callbacks

/// Send state update callback to main app
func notifyStateUpdate(sessionIds: [String]) {
    guard let listener = getListener() else { return }
    NSLog("BoringNotchAIXPCHelper: Calling listener.onStateUpdate with \(sessionIds.count) sessions")
    listener.onStateUpdate(sessionIds: sessionIds)
}

/// Send interrupt callback to main app
func notifyInterrupt(sessionId: String) {
    guard let listener = getListener() else { return }
    NSLog("BoringNotchAIXPCHelper: Calling listener.onInterrupt for \(sessionId.prefix(8))")
    listener.onInterrupt(sessionId: sessionId)
}
```

- [ ] **Step 2: 验证 main.swift 已正确设置 remoteObjectInterface**

确认 `main.swift` 已包含（当前已实现，无需改动）：

```swift
newConnection.remoteObjectInterface = NSXPCInterface(with: AIXPCEventListener.self)
exportedObject.setConnection(newConnection)
```

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift
git commit -m "feat(xpc-helper): add notifyStateUpdate and notifyInterrupt callback methods"
```

---

## Task 2: AIHookServerCore 使用 listener 回调替代 DistributedNotification

**Files:**
- Modify: `BoringNotchAIXPCHelper/AIHookServerCore.swift`

**现状：** 状态更新时发送 DistributedNotification 并写入通知文件，无法穿透沙盒。

- [ ] **Step 1: 添加 helper 引用参数**

在 `AIHookServerCore.swift` 文件开头，找到类定义：

```swift
class AIHookServerCore {
```

改为：

```swift
class AIHookServerCore {
    /// Reference to XPC Helper for sending callbacks
    weak var helper: BoringNotchAIXPCHelper?
```

- [ ] **Step 2: 修改 handleClient 方法，用 listener 回调替代 DistributedNotification**

找到 `handleClient` 方法中发送 DistributedNotification 的代码（约第 336-349 行）：

```swift
// Write sessionId to dedicated notification directory (avoid scanning /tmp)
// Use timestamp in filename to avoid race conditions with multiple rapid notifications
let notifyDir = "/tmp/boringnotch-notify"
try? FileManager.default.createDirectory(atPath: notifyDir, withIntermediateDirectories: true)
let timestamp = Int(Date().timeIntervalSince1970 * 1000)  // milliseconds
let notifyPath = notifyDir + "/stateupdate-" + Self.encodeSessionId(sessionId) + "-" + String(timestamp) + ".txt"
try? sessionId.write(toFile: notifyPath, atomically: true, encoding: .utf8)

// Send Distributed Notification to notify main app immediately
DistributedNotificationCenter.default().post(
    name: Notification.Name("com.boringnotch.ai.stateupdate"),
    object: nil
)
NSLog("AIHookServerCore: Sent stateupdate notification for \(sessionId.prefix(8)), notifyPath=\(notifyPath)")
```

改为：

```swift
// Send real-time callback via XPC protocol (penetrates sandbox boundary)
// No need for file/notification mechanism anymore
helper?.notifyStateUpdate(sessionIds: [sessionId])
NSLog("AIHookServerCore: Sent stateupdate callback for \(sessionId.prefix(8)) via XPC listener")
```

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add BoringNotchAIXPCHelper/AIHookServerCore.swift
git commit -m "feat(xpc): replace DistributedNotification with XPC listener callback for state updates"
```

---

## Task 3: JSONLInterruptPollingThread 使用 listener 回调替代 DistributedNotification

**Files:**
- Modify: `BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift`

**现状：** ESC 中断检测时发送 DistributedNotification，无法穿透沙盒。

- [ ] **Step 1: 添加 helper 引用参数**

找到 `JSONLInterruptPollingThread` 类定义：

```swift
class JSONLInterruptPollingThread {
    private var pollingThread: Thread?
    private let isRunningLock = NSLock()
    private var _isRunning: Bool = false
    private let sessionId: String
    private let filePath: String
```

改为：

```swift
class JSONLInterruptPollingThread {
    private var pollingThread: Thread?
    private let isRunningLock = NSLock()
    private var _isRunning: Bool = false
    private let sessionId: String
    private let filePath: String
    private weak var helper: BoringNotchAIXPCHelper?  // Reference for callbacks
```

- [ ] **Step 2: 修改 init 方法接收 helper 参数**

找到 `init` 方法：

```swift
init(sessionId: String, cwd: String) {
    self.sessionId = sessionId
    // Convert cwd to project directory format: ~/.claude/projects/<cwd>/
    let projectDir = cwd
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
}
```

改为：

```swift
init(sessionId: String, cwd: String, helper: BoringNotchAIXPCHelper? = nil) {
    self.sessionId = sessionId
    self.helper = helper
    // Convert cwd to project directory format: ~/.claude/projects/<cwd>/
    let projectDir = cwd
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ".", with: "-")
    self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
}
```

- [ ] **Step 3: 修改 sendInterruptNotification 方法，用 listener 回调替代 DistributedNotification**

找到 `sendInterruptNotification` 方法：

```swift
private func sendInterruptNotification() {
    // Write session ID to a temp file for main app to read
    // NOTE: Uses raw sessionId (not encoded) unlike stateupdate files which use encodedId.
    // Reason: Main app reads file content directly, no need to parse filename for sessionId.
    // This is intentional design difference - interrupt files are simpler (just sessionId content).
    let notifyPath = "/tmp/boringnotch-interrupt-\(sessionId).txt"
    try? sessionId.write(toFile: notifyPath, atomically: true, encoding: .utf8)

    // Send Darwin notification
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName("com.boringnotch.ai.interrupt" as CFString),
        nil, nil, true
    )

    NSLog("JSONLInterruptPollingThread: Sent interrupt notification for \(sessionId.prefix(8))")

    // Stop polling after interrupt detected (session will be cleaned up)
    isRunning = false
}
```

改为：

```swift
private func sendInterruptNotification() {
    // Send real-time callback via XPC protocol (penetrates sandbox boundary)
    helper?.notifyInterrupt(sessionId: sessionId)
    NSLog("JSONLInterruptPollingThread: Sent interrupt callback for \(sessionId.prefix(8)) via XPC listener")

    // Stop polling after interrupt detected (session will be cleaned up)
    isRunning = false
}
```

- [ ] **Step 4: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift
git commit -m "feat(xpc): replace DistributedNotification with XPC listener callback for interrupt detection"
```

---

## Task 4: InterruptWatcherManagerCore 传递 helper 引用

**Files:**
- Modify: `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift`

- [ ] **Step 1: 添加 helper 引用到 InterruptWatcherManagerCore**

找到 `InterruptWatcherManagerCore` 类定义：

```swift
class InterruptWatcherManagerCore {
    static let shared = InterruptWatcherManagerCore()

    private var watchers: [String: JSONLInterruptPollingThread] = [:]
    private let lock = NSLock()

    private init() {}

    func startWatching(sessionId: String, cwd: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard watchers[sessionId] == nil else {
            NSLog("InterruptWatcherManagerCore: Already watching \(sessionId.prefix(8))")
            return true
        }

        let watcher = JSONLInterruptPollingThread(sessionId: sessionId, cwd: cwd)
        watcher.start()
        watchers[sessionId] = watcher

        NSLog("InterruptWatcherManagerCore: Started Thread.polling watcher for \(sessionId.prefix(8))")
        return true
    }
```

改为：

```swift
class InterruptWatcherManagerCore {
    static let shared = InterruptWatcherManagerCore()

    private var watchers: [String: JSONLInterruptPollingThread] = [:]
    private let lock = NSLock()
    private weak var helper: BoringNotchAIXPCHelper?  // Reference for callbacks

    private init() {}

    /// Set helper reference for callbacks
    func setHelper(_ helper: BoringNotchAIXPCHelper) {
        self.helper = helper
    }

    func startWatching(sessionId: String, cwd: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard watchers[sessionId] == nil else {
            NSLog("InterruptWatcherManagerCore: Already watching \(sessionId.prefix(8))")
            return true
        }

        let watcher = JSONLInterruptPollingThread(sessionId: sessionId, cwd: cwd, helper: helper)
        watcher.start()
        watchers[sessionId] = watcher

        NSLog("InterruptWatcherManagerCore: Started Thread.polling watcher for \(sessionId.prefix(8))")
        return true
    }
```

- [ ] **Step 2: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift
git commit -m "feat(xpc): pass helper reference to InterruptWatcherManager for callbacks"
```

---

## Task 5: BoringNotchAIXPCHelper 设置 helper 引用链

**Files:**
- Modify: `BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift`

- [ ] **Step 1: 在 setConnection 中设置 helper 引用链**

找到 `setConnection` 方法：

```swift
func setConnection(_ conn: NSXPCConnection) {
    connection = conn
    NSLog("BoringNotchAIXPCHelper: Connection stored, remoteObjectInterface set")
}
```

改为：

```swift
func setConnection(_ conn: NSXPCConnection) {
    connection = conn
    NSLog("BoringNotchAIXPCHelper: Connection stored, remoteObjectInterface set")

    // Set helper reference chain for callbacks
    InterruptWatcherManagerCore.shared.setHelper(self)
    NSLog("BoringNotchAIXPCHelper: Helper reference chain set for InterruptWatcherManager")

    // Set helper reference for HookServer (will be set when server starts)
}
```

- [ ] **Step 2: 在 startServer 中设置 hookServer 的 helper 引用**

找到 `startServer` 方法：

```swift
func startServer(with reply: @escaping (Bool) -> Void) {
    NSLog("BoringNotchAIXPCHelper: startServer called")
    guard hookServer == nil else {
        NSLog("BoringNotchAIXPCHelper: server already exists")
        reply(true)
        return
    }

    let server = AIHookServerCore()
    NSLog("BoringNotchAIXPCHelper: created AIHookServerCore, calling start()")
    server.start()
    hookServer = server
    NSLog("BoringNotchAIXPCHelper: Server started, replying true")
    reply(true)
}
```

改为：

```swift
func startServer(with reply: @escaping (Bool) -> Void) {
    NSLog("BoringNotchAIXPCHelper: startServer called")
    guard hookServer == nil else {
        NSLog("BoringNotchAIXPCHelper: server already exists")
        reply(true)
        return
    }

    let server = AIHookServerCore()
    server.helper = self  // Set helper reference for callbacks
    NSLog("BoringNotchAIXPCHelper: created AIHookServerCore, calling start()")
    server.start()
    hookServer = server
    NSLog("BoringNotchAIXPCHelper: Server started, replying true")
    reply(true)
}
```

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift
git commit -m "feat(xpc): set helper reference chain for HookServer and InterruptWatcher"
```

---

## Task 6: AIXPCClient 移除 DistributedNotification 监听，使用 listener 回调

**Files:**
- Modify: `boringNotch/XPCHelperClient/AIXPCClient.swift`

**现状：** 主 App 监听 DistributedNotification 并读取文件，无法实时响应。

- [ ] **Step 1: 移除 DistributedNotification 监听代码**

删除以下两个方法：
- `setupDarwinNotificationListener()` - 监听 interrupt
- `setupStateUpdateListener()` - 监听 stateupdate

在 `ensureRemoteService()` 方法中，删除调用这两个方法的代码：

```swift
// Set up Darwin Notification listener for interrupts
setupDarwinNotificationListener()

// Set up Darwin Notification listener for state updates
setupStateUpdateListener()
```

改为：

```swift
// Listener is set externally via setListener(), no setup needed here
```

- [ ] **Step 2: 确保 exportedObject 设置正确**

确认 `ensureRemoteService()` 中已正确设置 exportedObject（之前验证已实现）：

```swift
// Set up exported interface for receiving callbacks from XPC Helper
conn.exportedInterface = NSXPCInterface(with: AIXPCEventListener.self)
conn.exportedObject = listener
```

- [ ] **Step 3: 删除无用的常量和属性定义**

删除文件开头的常量（不再需要）：

```swift
/// Darwin notification name for interrupt detection
let kInterruptNotificationName = "com.boringnotch.ai.interrupt"

/// Darwin notification name for state file updates
let kStateUpdateNotificationName = "com.boringnotch.ai.stateupdate"
```

删除类中的回调属性（不再使用）：

```swift
/// Callback when interrupt is detected via Darwin Notification
var onInterruptDetected: ((String) -> Void)?

/// Callback when state file update is detected via Darwin Notification
/// Parameters: changedSessionIds - list of sessionIds that have state changes
var onStateUpdateDetected: (([String]) -> Void)?
```

- [ ] **Step 4: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/XPCHelperClient/AIXPCClient.swift
git commit -m "feat(xpc-client): remove DistributedNotification listeners, use XPC callbacks"
```

---

## Task 7: AIHookServer 使用 listener 回调触发状态更新

**Files:**
- Modify: `boringNotch/AI/AIHookServer.swift`

**现状：** 设置 `onStateUpdateDetected` 回调等待通知触发，改为直接处理 listener 回调。

- [ ] **Step 1: 修改 start() 方法，设置 listener 回调**

找到 `start()` 方法中设置 `onStateUpdateDetected` 的代码：

```swift
// Set up Darwin Notification callback for immediate response
AIXPCClient.shared.onStateUpdateDetected = { [weak self] changedSessionIds in
    Task {
        await self?.pollSpecificStateFiles(sessionIds: changedSessionIds)
    }
}
```

改为：

```swift
// Set up listener for XPC callbacks (real-time, penetrates sandbox)
let listener = AIXPCListener()
listener.onStateUpdateReceived = { [weak self] sessionIds in
    Task {
        await self?.pollSpecificStateFiles(sessionIds: sessionIds)
    }
}
listener.onInterruptReceived = { [weak self] sessionId in
    Task {
        await self?.handleInterrupt(sessionId: sessionId)
    }
}
AIXPCClient.shared.setListener(listener)
```

- [ ] **Step 2: 添加 handleInterrupt 方法处理中断回调**

在 `AIHookServer.swift` 文件末尾添加：

```swift
/// Handle interrupt callback from XPC Helper
private func handleInterrupt(sessionId: String) async {
    appendLog("handleInterrupt: Received interrupt for \(sessionId.prefix(8))\n")

    // Mark session as interrupted (will transition to idle)
    await MainActor.run {
        // Notify AIManager to update state
        NotificationCenter.default.post(
            name: .AIInterruptDetected,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }
}
```

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add boringNotch/AI/AIHookServer.swift
git commit -m "feat(ai-hookserver): use XPC listener callbacks instead of DistributedNotification"
```

---

## Task 8: AIManager 处理中断通知

**Files:**
- Modify: `boringNotch/AI/AIManager.swift`

- [ ] **Step 1: 添加中断通知监听**

在 `AIManager` 的 `init` 或 `start()` 方法中添加：

```swift
// Listen for interrupt notifications from HookServer
NotificationCenter.default.addObserver(
    forName: .AIInterruptDetected,
    object: nil,
    queue: .main
) { [weak self] notification in
    guard let sessionId = notification.userInfo?["sessionId"] as? String else { return }
    self?.handleSessionInterrupt(sessionId: sessionId)
}
```

- [ ] **Step 2: 添加 handleSessionInterrupt 方法**

```swift
/// Handle session interrupt detected by XPC Helper
private func handleSessionInterrupt(sessionId: String) {
    NSLog("AIManager: Interrupt detected for \(sessionId.prefix(8))")

    // Update session state to idle
    if let session = sessions[sessionId] {
        session.phase = .idle
        updateCoordinator()

        // Clean up session
        sessions.removeValue(forKey: sessionId)
        NotificationCenter.default.post(name: .AISessionListChanged, object: nil)
    }
}
```

- [ ] **Step 3: 定义通知名称**

在 `AIManager.swift` 文件顶部或 `Notification+AI.swift` 中添加：

```swift
extension Notification.Name {
    static let AIInterruptDetected = Notification.Name("com.boringnotch.ai.interrupt.detected")
}
```

- [ ] **Step 4: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/AIManager.swift
git commit -m "feat(ai-manager): handle interrupt callbacks from XPC Helper"
```

---

## Task 9: 清理调试代码和测试按钮

**Files:**
- Modify: `boringNotch/AI/Views/AISettingsView.swift`

- [ ] **Step 1: 移除 Test Notification 按钮（DistributedNotification 已废弃）**

删除 "Test Notification" 按钮相关代码。

- [ ] **Step 2: 保留 Test XPC Callback 按钮（用于验证回调机制）**

保留现有测试按钮，用于验证 XPC 回调工作正常。

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add boringNotch/AI/Views/AISettingsView.swift
git commit -m "cleanup: remove DistributedNotification test button, keep XPC callback test"
```

---

## Task 10: 验证完整功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用**

Run: `open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app`

- [ ] **Step 2: 验证状态更新回调**

在 Claude Code 中执行任务，观察：
1. Notch 是否实时显示状态变化（无需等待 15 秒轮询）
2. Console.app 中查看日志：
   - `BoringNotchAIXPCHelper: Calling listener.onStateUpdate`
   - `AIXPCListener: onStateUpdate received`

- [ ] **Step 3: 验证 ESC 中断回调**

在 Claude Code processing 状态时按 ESC，观察：
1. Notch 是否立即显示 Sleep 状态
2. Console.app 中查看日志：
   - `JSONLInterruptPollingThread: Sent interrupt callback via XPC listener`
   - `AIXPCListener: onInterrupt received`

- [ ] **Step 4: 检查通知文件目录是否不再生成**

```bash
ls /tmp/boringnotch-notify/  # 应该不存在或为空
ls /tmp/boringnotch-interrupt-*.txt  # 应该不存在
```

- [ ] **Step 5: 提交验证结果**

```bash
git add -A
git commit -m "test: XPC callback verification passed - real-time updates work"
```

---

## 完成标记

- [ ] Phase 6 实施完成，所有测试通过
- [ ] 代码已提交到 ai-integration 分支

---

## 架构改进总结

| 改进点 | 之前（Phase 5） | 之后（Phase 6） |
|--------|----------------|----------------|
| 状态更新通信 | DistributedNotification + 文件 | XPC 协议回调 |
| ESC 中断通信 | DistributedNotification + 文件 | XPC 协议回调 |
| 沙盒穿透 | ❌ 无法穿透 | ✅ 天然穿透 |
| 响应延迟 | 依赖 15 秒兜底轮询 | 实时响应（毫秒级） |
| 文件依赖 | `/tmp/boringnotch-notify/` 等目录 | 无文件依赖 |
| 代码复杂度 | 文件监听 + 通知监听 + 文件读取 | 直接回调 |

---

## 已知限制

1. **connection 生命周期**：XPC connection 断开后需要重新设置 listener
2. **回调错误处理**：remoteObjectProxyWithErrorHandler 需要处理连接错误
3. **测试按钮保留**：Test XPC Callback 按钮用于验证机制，可在生产版本移除