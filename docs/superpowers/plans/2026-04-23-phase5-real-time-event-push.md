# Phase 5: 实时事件推送改进实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除文件扫描延迟，实现指定文件读取 + ESC 中断实时检测

**Architecture:**
1. Darwin Notification 携带 sessionId（写入专用目录通知文件），主 App 只读取指定 session 状态文件，避免扫描所有文件
2. XPC Helper 用 Thread.polling 监听 JSONL 文件替代不稳定的 DispatchSource，实现 ESC 中断实时检测

**Tech Stack:** Swift, Darwin Notification, Thread.polling, XPC Service, NSLock for thread safety

---

## 前置条件

- Phase 1 + Phase 2 已完成：Per-Session 状态文件、Darwin Notification 触发机制

---

## 文件结构

**新建文件：**
- `BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift` - Thread.polling JSONL 监听（替代 DispatchSource）

**修改文件：**
- `BoringNotchAIXPCHelper/AIHookServerCore.swift` - 发送 Darwin Notification 时写入 sessionId 到专用目录
- `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift` - InterruptWatcherManagerCore 切换到 Thread.polling
- `boringNotch/XPCHelperClient/AIXPCClient.swift` - 收到通知后从专用目录读取 sessionId
- `boringNotch/AI/AIHookServer.swift` - 改为事件驱动（收到通知后读取指定文件）
- `boringNotch/AI/AIManager.swift` - 调整 processing 超时为僵尸检测（依赖实时中断）

---

## Task 1: AIHookServerCore 发送 Darwin Notification 时携带 sessionId

**Files:**
- Modify: `BoringNotchAIXPCHelper/AIHookServerCore.swift:309-344`

**现状问题：** Darwin Notification 无 payload，主 App 收到通知后需要扫描所有文件才知道哪个 session 有变化。

**改进方案：** 使用专用目录 `/tmp/boringnotch-notify/` 存放通知文件，避免扫描 `/tmp` 整个目录。通知文件名包含时间戳避免竞态。

- [ ] **Step 1: 修改 handleClient 方法中 Darwin Notification 相关代码**

找到 `AIHookServerCore.swift` 第 309-344 行（`handleClient` 方法中写入状态文件后发送通知的部分），将：

```swift
// Write raw event data to state file for main app to read
if let str = String(data: allData, encoding: .utf8) {
    // Per-session state file path
    let encodedId = Self.encodeSessionId(sessionId)
    let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"

    // Diagnostic: log before/after inode to verify atomic write behavior
    let beforeInode: Int? = {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let inode = attrs[.systemFileNumber] as? Int {
            return inode
        }
        return nil
    }()

    try? str.write(toFile: path, atomically: true, encoding: .utf8)

    let afterInode: Int? = {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let inode = attrs[.systemFileNumber] as? Int {
            return inode
        }
        return nil
    }()

    NSLog("AIHookServerCore: Wrote event \(event) inode: before=\(beforeInode ?? -1) after=\(afterInode ?? -1) changed=\(beforeInode != afterInode)")

    // Send Darwin Notification to notify main app immediately
    let notificationName = "com.boringnotch.ai.stateupdate" as CFString
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(notificationName),
        nil, nil, true
    )
    NSLog("AIHookServerCore: Sent stateupdate notification for \(sessionId.prefix(8))")
}
```

改为：

```swift
// Write raw event data to state file for main app to read
if let str = String(data: allData, encoding: .utf8) {
    // Per-session state file path
    let encodedId = Self.encodeSessionId(sessionId)
    let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"

    // Diagnostic: log before/after inode to verify atomic write behavior
    let beforeInode: Int? = {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let inode = attrs[.systemFileNumber] as? Int {
            return inode
        }
        return nil
    }()

    try? str.write(toFile: path, atomically: true, encoding: .utf8)

    let afterInode: Int? = {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let inode = attrs[.systemFileNumber] as? Int {
            return inode
        }
        return nil
    }()

    NSLog("AIHookServerCore: Wrote event \(event) inode: before=\(beforeInode ?? -1) after=\(afterInode ?? -1) changed=\(beforeInode != afterInode)")

    // Write sessionId to dedicated notification directory (avoid scanning /tmp)
    // Use timestamp in filename to avoid race conditions with multiple rapid notifications
    let notifyDir = "/tmp/boringnotch-notify"
    try? FileManager.default.createDirectory(atPath: notifyDir, withIntermediateDirectories: true)
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)  // milliseconds
    let notifyPath = notifyDir + "/stateupdate-" + Self.encodeSessionId(sessionId) + "-" + String(timestamp) + ".txt"
    try? sessionId.write(toFile: notifyPath, atomically: true, encoding: .utf8)

    // Send Darwin Notification to notify main app immediately
    let notificationName = "com.boringnotch.ai.stateupdate" as CFString
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(notificationName),
        nil, nil, true
    )
    NSLog("AIHookServerCore: Sent stateupdate notification for \(sessionId.prefix(8)), notifyPath=\(notifyPath)")
}
```

- [ ] **Step 2: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add BoringNotchAIXPCHelper/AIHookServerCore.swift
git commit -m "feat(xpc): write sessionId to dedicated notify directory with timestamp"
```

---

## Task 2: AIXPCClient 收到通知后从专用目录获取 sessionId

**Files:**
- Modify: `boringNotch/XPCHelperClient/AIXPCClient.swift:24-25, 122-138`

- [ ] **Step 1: 修改 onStateUpdateDetected 回调类型**

找到 `AIXPCClient.swift` 第 24-25 行，将：

```swift
/// Callback when state file update is detected via Darwin Notification
var onStateUpdateDetected: (() -> Void)?
```

改为：

```swift
/// Callback when state file update is detected via Darwin Notification
/// Parameters: changedSessionIds - list of sessionIds that have state changes
var onStateUpdateDetected: (([String]) -> Void)?
```

- [ ] **Step 2: 修改 setupStateUpdateListener 从专用目录读取**

找到 `AIXPCClient.swift` 第 122-138 行，将：

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

改为：

```swift
private func setupStateUpdateListener() {
    // Clean up stale notification files from previous session (startup hygiene)
    let notifyDir = "/tmp/boringnotch-notify"
    if FileManager.default.fileExists(atPath: notifyDir) {
        try? FileManager.default.removeItem(atPath: notifyDir)
    }
    
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        nil,
        { center, observer, name, object, userInfo in
            // Read from dedicated notification directory (avoid scanning /tmp)
            let notifyDir = "/tmp/boringnotch-notify"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: notifyDir) else {
                return
            }
            
            // Filter stateupdate notification files
            let notifyFiles = files.filter { $0.hasPrefix("stateupdate-") && $0.hasSuffix(".txt") }
            var changedSessionIds: [String] = []
            
            for fileName in notifyFiles {
                let filePath = notifyDir + "/" + fileName
                if let sessionId = try? String(contentsOfFile: filePath, encoding: .utf8), !sessionId.isEmpty {
                    changedSessionIds.append(sessionId)
                }
                // Clean up notification file after reading
                try? FileManager.default.removeItem(atPath: filePath)
            }
            
            // Notify callback with changed sessionIds (if any)
            if !changedSessionIds.isEmpty {
                Task { @MainActor in
                    AIXPCClient.shared.onStateUpdateDetected?(changedSessionIds)
                }
            }
        },
        kStateUpdateNotificationName as CFString,
        nil,
        CFNotificationSuspensionBehavior.deliverImmediately
    )
    
    NSLog("AIXPCClient: Darwin notification listener set up for state updates (dedicated directory, startup cleanup)")
}
```

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add boringNotch/XPCHelperClient/AIXPCClient.swift
git commit -m "feat(xpc-client): read sessionId from dedicated notify directory"
```

---

## Task 3: AIHookServer 改为指定文件读取

**Files:**
- Modify: `boringNotch/AI/AIHookServer.swift`

**注意：** 主 App 无法直接调用 XPC Helper 的 `encodeSessionId` 方法，因此需要在主 App 中复制相同的编码逻辑。这违反了 DRY 但无法避免（XPC 隔离）。

- [ ] **Step 1: 修改 onStateUpdateDetected 回调处理**

找到 `AIHookServer.swift` 第 59-64 行，将：

```swift
// Set up Darwin Notification callback for immediate response
AIXPCClient.shared.onStateUpdateDetected = { [weak self] in
    Task {
        await self?.pollStateFiles()
    }
}
```

改为：

```swift
// Set up Darwin Notification callback for immediate response
AIXPCClient.shared.onStateUpdateDetected = { [weak self] changedSessionIds in
    Task {
        await self?.pollSpecificStateFiles(sessionIds: changedSessionIds)
    }
}
```

- [ ] **Step 2: 新增 pollSpecificStateFiles 和 encodeSessionId 方法**

在 `AIHookServer.swift` 的 `pollStateFiles()` 方法后添加新方法：

```swift
/// Poll specific state files identified by Darwin Notification
/// This avoids scanning all files when we know which sessions changed
private func pollSpecificStateFiles(sessionIds: [String]) async {
    let basePath = Self.stateFileBasePath
    
    for sessionId in sessionIds {
        let encodedId = Self.encodeSessionId(sessionId)
        let fileName = "boringnotch-ai-state-" + encodedId + ".json"
        let filePath = basePath + "/" + fileName
        
        appendLog("pollSpecificStateFiles: Processing sessionId=\(sessionId.prefix(8)) encoded=\(encodedId.prefix(8))\n")
        processStateFileWithDedup(path: filePath, fileName: fileName)
    }
}

/// URL-safe base64 encoding for sessionId
/// NOTE: This duplicates AIHookServerCore.encodeSessionId because main app cannot access XPC Helper methods
static func encodeSessionId(_ sessionId: String) -> String {
    let data = sessionId.data(using: .utf8) ?? Data()
    let base64 = data.base64EncodedString()
    return base64
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
```

- [ ] **Step 3: 修改兜底轮询间隔为合理值**

找到 `startPolling()` 方法（第 105-119 行），将轮询间隔改为 15 秒（Darwin Notification 可能丢失，需要合理兜底）：

```swift
private func startPolling() {
    appendLog("startPolling: Starting event-driven polling with 15s fallback\n")
    isFirstPoll = true
    pollingTask = Task.detached { [weak self] in
        while !Task.isCancelled {
            let interval = await MainActor.run {
                self?.hasWaitingForApproval ?? false ? 1.0 : 15.0  // 15s fallback, 1s for approval
            }
            await self?.pollStateFiles()  // Full scan as fallback
            try? await Task.sleep(for: .seconds(interval))
        }
        self?.appendLog("polling: Task cancelled\n")
    }
}
```

- [ ] **Step 4: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/AIHookServer.swift
git commit -m "feat(ai-server): targeted state file reading with 15s fallback"
```

---

## Task 4: 新建 JSONLInterruptPollingThread（Thread.polling 替代 DispatchSource）

**Files:**
- Create: `BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift`

**背景：** Phase 4 的 `JSONLInterruptWatcherCore.swift` 使用 DispatchSource 监听 JSONL 文件，但在 XPC Service 环境中不稳定。需要用 Thread.polling 替代（类似 Socket 接收的已验证方式）。

**关键改进：**
- 使用 `NSLock` 保护 `isRunning` 确保线程安全
- 使用 `defer` 确保 `FileHandle` 正确关闭
- 删除未使用的 `queue` 属性

- [ ] **Step 1: 创建 Thread.polling JSONL 监听类**

```swift
import Foundation

/// Thread-based polling JSONL watcher for XPC Helper.
/// Uses Thread.polling instead of DispatchSource because DispatchSource
/// doesn't work reliably in XPC Service environment (no RunLoop).
class JSONLInterruptPollingThread {
    private var pollingThread: Thread?
    private let isRunningLock = NSLock()
    private var _isRunning: Bool = false
    private let sessionId: String
    private let filePath: String
    private var lastOffset: UInt64 = 0  // NOTE: Only accessed within polling thread, no cross-thread access
    
    /// Thread-safe isRunning access
    private var isRunning: Bool {
        get {
            isRunningLock.lock()
            let value = _isRunning
            isRunningLock.unlock()
            return value
        }
        set {
            isRunningLock.lock()
            _isRunning = newValue
            isRunningLock.unlock()
        }
    }
    
    /// Patterns that indicate an interrupt occurred
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
        "\"interrupted\":true"
    ]
    
    init(sessionId: String, cwd: String) {
        self.sessionId = sessionId
        // Convert cwd to project directory format: ~/.claude/projects/<cwd>/
        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.filePath = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }
    
    // MARK: - Public
    
    func start() {
        isRunning = true
        pollingThread = Thread { [weak self] in
            self?.runPollingLoop()
        }
        pollingThread?.start()
        NSLog("JSONLInterruptPollingThread: Started polling for \(sessionId.prefix(8))")
    }
    
    func stop() {
        isRunning = false
        pollingThread = nil
        // Clean up notification file
        // NOTE: Uses raw sessionId (not encoded) because main app reads file content, not filename
        let notifyPath = "/tmp/boringnotch-interrupt-\(sessionId).txt"
        try? FileManager.default.removeItem(atPath: notifyPath)
        NSLog("JSONLInterruptPollingThread: Stopped polling for \(sessionId.prefix(8))")
    }
    
    // MARK: - Polling Loop
    
    private func runPollingLoop() {
        // Initial check for file existence
        guard FileManager.default.fileExists(atPath: filePath) else {
            NSLog("JSONLInterruptPollingThread: File not found: \(filePath)")
            return
        }
        
        // Get initial file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
           let size = attrs[.size] as? UInt64 {
            lastOffset = size
        }
        
        while isRunning {
            checkForNewContent()
            Thread.sleep(forTimeInterval: 0.5)  // Poll every 500ms
        }
    }
    
    private func checkForNewContent() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let currentSize = attrs[.size] as? UInt64 else {
            return
        }
        
        guard currentSize > lastOffset else { return }
        
        // Read new content from lastOffset to currentSize
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else { return }
        
        defer {
            try? fileHandle.close()
        }
        
        do {
            try fileHandle.seek(toOffset: lastOffset)
            if let newData = try? fileHandle.readToEnd(),
               let newContent = String(data: newData, encoding: .utf8) {
                lastOffset = currentSize
                
                // Check for interrupt patterns
                let lines = newContent.components(separatedBy: "\n")
                for line in lines where !line.isEmpty {
                    if isInterruptLine(line) {
                        NSLog("JSONLInterruptPollingThread: Detected interrupt for \(sessionId.prefix(8))")
                        sendInterruptNotification()
                        return
                    }
                }
            }
        } catch {
            NSLog("JSONLInterruptPollingThread: Error reading file: \(error)")
        }
    }
    
    private func isInterruptLine(_ line: String) -> Bool {
        // Check for user interrupt message
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
               line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }
        
        // Check for tool_result with error
        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            for pattern in Self.interruptContentPatterns {
                if line.contains(pattern) {
                    return true
                }
            }
        }
        
        // Check for interrupted flag
        if line.contains("\"interrupted\":true") {
            return true
        }
        
        return false
    }
    
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
}
```

- [ ] **Step 2: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add BoringNotchAIXPCHelper/JSONLInterruptPollingThread.swift
git commit -m "feat(xpc): Thread.polling JSONL watcher with thread safety and proper cleanup"
```

---

## Task 5: InterruptWatcherManagerCore 切换到 Thread.polling 并清理旧代码

**Files:**
- Modify: `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift`

- [ ] **Step 1: 修改 InterruptWatcherManagerCore 使用新的 Thread.polling 类**

找到 `JSONLInterruptWatcherCore.swift` 文件末尾的 `InterruptWatcherManagerCore` 类（第 188-239 行），将：

```swift
/// Manages interrupt watchers for all active sessions in XPC Helper
class InterruptWatcherManagerCore {
    static let shared = InterruptWatcherManagerCore()
    
    private var watchers: [String: JSONLInterruptWatcherCore] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    func startWatching(sessionId: String, cwd: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard watchers[sessionId] == nil else {
            NSLog("InterruptWatcherManagerCore: Already watching \(sessionId.prefix(8))")
            return true
        }
        
        let watcher = JSONLInterruptWatcherCore(sessionId: sessionId, cwd: cwd)
        watcher.start()
        watchers[sessionId] = watcher
        
        NSLog("InterruptWatcherManagerCore: Started watcher for \(sessionId.prefix(8))")
        return true
    }
    
    func stopWatching(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let watcher = watchers.removeValue(forKey: sessionId) else {
            return false
        }
        
        watcher.stop()
        NSLog("InterruptWatcherManagerCore: Stopped watcher for \(sessionId.prefix(8))")
        return true
    }
    
    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        NSLog("InterruptWatcherManagerCore: Stopped all watchers")
    }
}
```

改为：

```swift
/// Manages interrupt watchers for all active sessions in XPC Helper
/// Uses Thread.polling instead of DispatchSource for XPC Service compatibility
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
    
    func stopWatching(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let watcher = watchers.removeValue(forKey: sessionId) else {
            return false
        }
        
        watcher.stop()
        NSLog("InterruptWatcherManagerCore: Stopped watcher for \(sessionId.prefix(8))")
        return true
    }
    
    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        NSLog("InterruptWatcherManagerCore: Stopped all watchers")
    }
}
```

- [ ] **Step 2: 删除旧的 JSONLInterruptWatcherCore 类（成为死代码）**

删除文件中第 9-186 行的 `JSONLInterruptWatcherCore` 类定义（基于 DispatchSource 的旧实现），保留第 1-8 行的常量定义和第 188 行之后的 `InterruptWatcherManagerCore`。

保留文件开头：
```swift
import Foundation

/// Darwin notification name for interrupt detection
let kInterruptNotificationName = "com.boringnotch.ai.interrupt"
```

然后直接是修改后的 `InterruptWatcherManagerCore` 类。

- [ ] **Step 3: 验证编译**

Run: `xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift
git commit -m "feat(xpc): switch to Thread.polling, remove old DispatchSource watcher"
```

---

## Task 6: AIManager 调整 processing 超时为僵尸检测

**Files:**
- Modify: `boringNotch/AI/AIManager.swift:578-581`

**背景：** 实现实时中断检测后，processing 状态应该依赖 Thread.polling 检测 ESC 中断。超时机制仅作为僵尸检测（XPC Helper 崩溃等异常情况）。

**注意：** 原代码第 595-614 行已有 activeSessionId 重评估和 updateCoordinator() 逻辑，本次仅修改 timeout 值。

- [ ] **Step 1: 仅修改 processing timeout 值**

找到 `AIManager.swift` 第 578-581 行，将：

```swift
            case .processing, .runningTool, .compacting:
                // Darwin Notification handles cleanup via SessionEnd
                // Only timeout if truly stale (5 minutes = zombie detection)
                timeout = 300
```

改为：

```swift
            case .processing, .runningTool, .compacting:
                // Real-time interrupt detection via Thread.polling JSONL watcher
                // SessionEnd handles normal cleanup, ESC interrupt detected by Thread.polling
                // Keep 10 min timeout for zombie detection (XPC Health Check: 30s × 3 failures = 90s)
                timeout = 600  // 10 minutes zombie detection
```

- [ ] **Step 2: 验证编译**

Run: `xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/AIManager.swift
git commit -m "feat(ai-manager): 10min zombie detection timeout, rely on real-time interrupt"
```

---

## Task 7: 验证 Phase 5 功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用**

Run: `open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app`

- [ ] **Step 2: 指定文件读取验证**

在 Claude Code 中执行任务，观察：
1. `/tmp/boringnotch-notify/` 目录是否被创建
2. 目录中是否有 `stateupdate-{encodedId}-{timestamp}.txt` 文件
3. 主 App 日志是否显示 `pollSpecificStateFiles: Processing sessionId=xxx`

检查命令：
```bash
ls -la /tmp/boringnotch-notify/
cat ~/Library/Caches/hookserver-debug.log | grep "pollSpecificStateFiles"
```

- [ ] **Step 3: ESC 中断实时检测验证**

在 Claude Code processing 状态时按 ESC，观察：
1. Notch 是否立即显示 Sleep 状态（而非等待超时）
2. `/tmp/boringnotch-interrupt-*.txt` 是否被创建
3. XPC Helper 日志是否显示 `JSONLInterruptPollingThread: Detected interrupt`

检查命令：
```bash
ls /tmp/boringnotch-interrupt-*.txt
# XPC Helper 日志在 Console.app 中查看进程：BoringNotchAIXPCHelper
```

- [ ] **Step 4: 兜底轮询验证**

模拟 Darwin Notification 丢失（暂停主 App 15 秒），恢复后检查是否通过兜底轮询正确更新状态。

- [ ] **Step 5: 提交验证结果**

```bash
git add -A
git commit -m "test: phase 5 real-time event push verification passed"
```

---

## 完成标记

- [ ] Phase 5 实施完成，所有测试通过
- [ ] 代码已提交到 ai-integration 分支

---

## 架构改进总结

| 改进点 | 之前 | 之后 |
|--------|------|------|
| 状态更新延迟 | Darwin Notification → 扫描 `/tmp` 所有文件 | Darwin Notification → 专用目录 → 指定文件读取 |
| `/tmp` 扫描开销 | 扫描整个 `/tmp`（可能大量文件） | 扫描专用目录 `/tmp/boringnotch-notify/` |
| 通知文件竞态 | 单一文件名可能冲突 | 时间戳文件名避免竞态 |
| ESC 中断检测 | DispatchSource（不稳定）+ 5 分钟超时 | Thread.polling（稳定，线程安全）+ 实时检测 |
| Processing 超时 | 5 分钟 → idle | 10 分钟僵尸检测（依赖实时中断） |
| 兜底轮询间隔 | 5 秒 | 15 秒（事件驱动覆盖大部分情况） |
| 线程安全 | `isRunning` 无保护 | `NSLock` 保护 |

---

## 已知限制

1. **encodeSessionId 重复定义**：主 App 和 XPC Helper 各定义一次（DRY 违反），无法避免（XPC 隔离）
2. **Darwin Notification 可能丢失**：系统可能合并/丢弃通知，15 秒兜底轮询覆盖
3. **Thread.polling CPU 开销**：500ms 轮询间隔有轻微 CPU 使用，但比 DispatchSource 稳定性更重要
4. **interrupt vs stateupdate 文件命名风格不同**：interrupt 使用原始 sessionId，stateupdate 使用 encodedId。这是有意设计：interrupt 文件内容直接是 sessionId，无需从文件名解析；stateupdate 需要从文件名匹配状态文件，因此用 encodedId 保持一致性