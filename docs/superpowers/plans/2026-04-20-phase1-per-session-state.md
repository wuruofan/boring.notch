# Phase 1: Per-Session 状态文件实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将单一状态文件改为 per-session 文件，解决多 session 并发事件覆盖问题

**Architecture:** XPC Helper 写入 per-session 状态文件 `boringnotch-ai-state-{sessionId}.json`，主 App 轮询扫描所有文件，每个文件独立 hash dedup，僵尸文件 5 分钟超时清理，SessionEnd 延迟 2 秒后清理对应文件

**Tech Stack:** Swift, XPC Service, Unix Domain Socket, FileManager polling

---

## 文件结构

**新建文件：**
- 无（所有改动在现有文件）

**修改文件：**
- `BoringNotchAIXPCHelper/AIHookServerCore.swift` - 状态文件路径计算改为 per-session，sessionId URL-safe base64 编码
- `BoringNotchAIXPCHelper/BoringNotchAIXPCHelperProtocol.swift` - 新增 `cleanupStateFile(sessionId:)` 协议方法
- `BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift` - 实现 `cleanupStateFile` 转发到 AIHookServerCore
- `boringNotch/XPCHelperClient/AIXPCClient.swift` - 新增 `cleanupStateFile` 调用
- `boringNotch/AI/AIHookServer.swift` - 轮询改为扫描多文件，per-file hash dedup，僵尸文件清理
- `boringNotch/AI/AIManager.swift` - SessionEnd 处理完后延迟 2 秒调用清理
- `boringNotch/AI/AIHookInstaller.swift` - Hook 脚本更新（新增事件映射）
- `boringNotch/AI/Models/AIHookEvent.swift` - 新增 status 解码

---

## Task 1: XPC 协议新增 cleanupStateFile 方法

**Files:**
- Modify: `BoringNotchAIXPCHelper/BoringNotchAIXPCHelperProtocol.swift`

- [ ] **Step 1: 添加协议方法定义**

在 `BoringNotchAIXPCHelperProtocol.swift` 的 `// MARK: - JSONL Interrupt Watching` 部分前添加：

```swift
    // MARK: - State File Cleanup

    /// Clean up the state file for a specific session.
    /// Called by main app after processing SessionEnd event.
    func cleanupStateFile(sessionId: String, with reply: @escaping (Bool) -> Void)
```

- [ ] **Step 2: 验证文件语法正确**

运行：`xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | head -50`
预期：无编译错误（协议方法签名正确）

- [ ] **Step 3: 提交**

```bash
git add BoringNotchAIXPCHelper/BoringNotchAIXPCHelperProtocol.swift
git commit -m "feat(xpc): add cleanupStateFile protocol method"
```

---

## Task 2: XPC Helper 实现 cleanupStateFile

**Files:**
- Modify: `BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift`
- Modify: `BoringNotchAIXPCHelper/AIHookServerCore.swift`

- [ ] **Step 1: AIHookServerCore 添加删除方法**

在 `AIHookServerCore.swift` 的 `stop()` 方法后添加：

```swift
    /// Delete the state file for a specific session
    func cleanupStateFile(sessionId: String) -> Bool {
        let encodedId = Self.encodeSessionId(sessionId)
        let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"
        
        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                NSLog("AIHookServerCore: Cleaned up state file for \(sessionId.prefix(8))")
                return true
            } catch {
                NSLog("AIHookServerCore: Failed to cleanup state file: \(error)")
                return false
            }
        }
        return true  // File doesn't exist, consider it cleaned
    }
```

- [ ] **Step 2: 添加 sessionId 编码方法**

在 `AIHookServerCore.swift` 的 `static let stateFilePath` 定义后添加：

```swift
    /// URL-safe base64 encoding for sessionId to ensure safe file names
    static func encodeSessionId(_ sessionId: String) -> String {
        // Use base64url encoding (no +, /, = characters)
        let data = sessionId.data(using: .utf8) ?? Data()
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    /// Base path for all state files
    static let stateFileBasePath: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return "\(homePath)/Library/Containers/theboringteam.boringnotch/Data/Library/Caches"
        }
        return "/tmp"
    }()
```

- [ ] **Step 3: 修改状态文件路径计算**

将 `handleClient()` 中写入状态文件的部分从：

```swift
try? str.write(toFile: Self.stateFilePath, atomically: true, encoding: .utf8)
```

改为：

```swift
let encodedId = Self.encodeSessionId(sessionId)
let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"
try? str.write(toFile: path, atomically: true, encoding: .utf8)
```

- [ ] **Step 4: BoringNotchAIXPCHelper 添加转发方法**

在 `BoringNotchAIXPCHelper.swift` 的 `stopInterruptWatcher` 方法后添加：

```swift
    func cleanupStateFile(sessionId: String, with reply: @escaping (Bool) -> Void) {
        let success = core.cleanupStateFile(sessionId: sessionId)
        reply(success)
    }
```

- [ ] **Step 5: 验证编译**

运行：`xcodebuild -scheme BoringNotchAIXPCHelper -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add BoringNotchAIXPCHelper/AIHookServerCore.swift BoringNotchAIXPCHelper/BoringNotchAIXPCHelper.swift
git commit -m "feat(xpc): implement per-session state file writing and cleanup"
```

---

## Task 3: AIXPCClient 新增 cleanupStateFile 调用

**Files:**
- Modify: `boringNotch/XPCHelperClient/AIXPCClient.swift`

- [ ] **Step 1: 添加 cleanupStateFile 方法**

在 `AIXPCClient.swift` 的 `stopInterruptWatcher` 方法后添加：

```swift
    nonisolated func cleanupStateFile(sessionId: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.cleanupStateFile(sessionId: sessionId) { success in
                    NSLog("AIXPCClient: cleanupStateFile returned \(success) for \(sessionId.prefix(8))")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: cleanupStateFile failed: \(error)")
            return false
        }
    }
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/XPCHelperClient/AIXPCClient.swift
git commit -m "feat(xpc-client): add cleanupStateFile method"
```

---

## Task 4: AIHookServer 多文件扫描轮询

**Files:**
- Modify: `boringNotch/AI/AIHookServer.swift`

- [ ] **Step 1: 添加多文件 hash 存储**

将 `lastContentHash` 从单个改为字典：

```swift
    private var lastHashes: [String: String] = [:]  // sessionId -> hash
```

- [ ] **Step 2: 修改轮询方法**

将 `pollStateFile()` 方法改为 `pollStateFiles()`：

```swift
    private func pollStateFiles() {
        let basePath = Self.stateFileBasePath
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
            appendLog("pollStateFiles: Cannot read directory \(basePath)\n")
            return
        }
        
        let stateFiles = files.filter { 
            $0.hasPrefix("boringnotch-ai-state-") && $0.hasSuffix(".json")
        }
        
        for fileName in stateFiles {
            let filePath = basePath + "/" + fileName
            processStateFileWithDedup(path: filePath, fileName: fileName)
        }
        
        // Zombie file cleanup: delete files older than 5 minutes
        cleanupZombieFiles(files: stateFiles, basePath: basePath)
    }
    
    private func processStateFileWithDedup(path: String, fileName: String) {
        // Check file modification time for zombie detection
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }
        
        // Skip zombie files (older than 5 minutes)
        if Date().timeIntervalSince(modDate) > 300 {
            appendLog("processStateFileWithDedup: Skipping zombie file \(fileName)\n")
            return
        }
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return
        }
        
        // Extract sessionId from filename
        let sessionId = fileName
            .replacingOccurrences(of: "boringnotch-ai-state-", with: "")
            .replacingOccurrences(of: ".json", with: "")
        
        // Per-file hash deduplication
        let contentHash = data.base64EncodedString()
        if lastHashes[sessionId] == contentHash { return }
        lastHashes[sessionId] = contentHash
        
        appendLog("processStateFileWithDedup: New data for \(sessionId), processing\n")
        processStateFile(data: data)
    }
    
    private func cleanupZombieFiles(files: [String], basePath: String) {
        for fileName in files {
            let filePath = basePath + "/" + fileName
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date else {
                continue
            }
            
            if Date().timeIntervalSince(modDate) > 300 {  // 5 minutes
                try? FileManager.default.removeItem(atPath: filePath)
                appendLog("cleanupZombieFiles: Removed zombie file \(fileName)\n")
                
                // Remove from hash cache
                let sessionId = fileName
                    .replacingOccurrences(of: "boringnotch-ai-state-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                lastHashes.removeValue(forKey: sessionId)
            }
        }
    }
```

- [ ] **Step 3: 添加 stateFileBasePath**

添加静态属性：

```swift
    static let stateFileBasePath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath
    }()
```

- [ ] **Step 4: 更新 startPolling 调用**

将 `pollStateFile()` 改为 `pollStateFiles()`：

```swift
    private func startPolling() {
        appendLog("startPolling: Starting multi-file polling task\n")
        pollingTask = Task.detached { [weak self] in
            var count = 0
            while !Task.isCancelled {
                count += 1
                if count % 50 == 0 {
                    self?.appendLog("polling: tick \(count)\n")
                }
                self?.pollStateFiles()
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.appendLog("polling: Task cancelled\n")
        }
    }
```

- [ ] **Step 5: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 6: 提交**

```bash
git add boringNotch/AI/AIHookServer.swift
git commit -m "feat(ai-server): multi-file polling with per-file hash dedup and zombie cleanup"
```

---

## Task 5: AIManager SessionEnd 延迟清理

**Files:**
- Modify: `boringNotch/AI/AIManager.swift`

- [ ] **Step 1: 在 handleHookEvent 中添加延迟清理**

找到 `handleHookEvent` 中处理 SessionEnd 的部分（约 162-190 行），在 `sessions.removeValue(forKey: sessionId)` 后添加：

```swift
                // Delayed cleanup: wait 2 seconds before deleting state file
                // This ensures the polling loop has time to read the SessionEnd event
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await AIXPCClient.shared.cleanupStateFile(sessionId: sessionId)
                }
```

具体改动位置：在 `updateCoordinator()` 调用前添加上述代码。

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/AIManager.swift
git commit -m "feat(ai-manager): delay state file cleanup after SessionEnd processing"
```

---

## Task 6: Hook 脚本更新（新增事件映射）

**Files:**
- Modify: `boringNotch/AI/AIHookInstaller.swift`

- [ ] **Step 1: 更新 generateHookScript 中的 status_map**

将 `generateHookScript()` 方法中的 `status_map` 字典从：

```python
            status_map = {
                "UserPromptSubmit": "processing",
                "PreToolUse": "running_tool",
                "PostToolUse": "processing",
                "PermissionRequest": "waiting_for_approval",
                "Stop": "stop_pending",
                "SubagentStop": "waiting_for_input",
                "SessionStart": "waiting_for_input",
                "SessionEnd": "ended",
                "PreCompact": "compacting",
            }
```

改为：

```python
            status_map = {
                "UserPromptSubmit": "processing",
                "PreToolUse": "running_tool",
                "PostToolUse": "processing",
                "PostToolUseFailure": "tool_failed",
                "PermissionRequest": "waiting_for_approval",
                "PermissionDenied": "processing",
                "Stop": "stop_pending",
                "StopFailure": "error",
                "SubagentStart": "subagent_active",
                "SubagentStop": "subagent_done",
                "SessionStart": "waiting_for_input",
                "SessionEnd": "ended",
                "PreCompact": "compacting",
                "PostCompact": "processing",
                "CwdChanged": "cwd_changed",
                "Elicitation": "waiting_for_approval",
            }
```

- [ ] **Step 2: 更新 hookEvents 列表**

将 `updateSettings()` 中的 `hookEvents` 列表从：

```swift
        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]
```

改为：

```swift
        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PostToolUseFailure", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("PermissionDenied", withoutMatcher),
            ("Stop", withoutMatcher),
            ("StopFailure", withoutMatcher),
            ("SubagentStart", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
            ("PostCompact", withoutMatcher),
            ("CwdChanged", withoutMatcher),
            ("Elicitation", withMatcherAndTimeout),
            ("Notification", withMatcher),
        ]
```

- [ ] **Step 3: 更新 Hook 脚本的状态文件写入逻辑**

在 `generateHookScript()` 的 `send_event` 函数中，将 socket 方式改为直接文件写入：

```python
def send_event(state):
    """Write state directly to file (primary method for reliability)."""
    # Get session_id for per-session file
    session_id = state.get("session_id", "")
    
    # URL-safe base64 encode session_id
    import base64
    encoded_id = base64.b64encode(session_id.encode()).decode()
    encoded_id = encoded_id.replace("+", "-").replace("/", "_").rstrip("=")
    
    # Write to per-session state file
    state_file_path = os.path.expanduser("~/Library/Containers/theboringteam.boringnotch/Data/Library/Caches/boringnotch-ai-state-" + encoded_id + ".json")
    
    try:
        with open(state_file_path, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        print(f"BoringNotch hook file write error: {e}", file=sys.stderr)
    
    # Also try socket for permission requests (needs response)
    if state.get("status") == "waiting_for_approval":
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(TIMEOUT_SECONDS)
            sock.connect(SOCKET_PATH)
            sock.sendall(json.dumps(state).encode())
            response = sock.recv(4096)
            sock.close()
            return json.loads(response.decode())
        except Exception as e:
            print(f"BoringNotch hook socket error: {e}", file=sys.stderr)
    
    return None
```

- [ ] **Step 4: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/AIHookInstaller.swift
git commit -m "feat(hook-installer): add new event mappings for tool_failed, error, subagent, etc"
```

---

## Task 7: AIHookEvent 新增 status 解码

**Files:**
- Modify: `boringNotch/AI/Models/AIHookEvent.swift`

- [ ] **Step 1: 更新 toPhase 方法**

在 `AIHookEvent.swift` 的 `toPhase()` 方法中添加新 status 的处理：

```swift
    func toPhase() -> AISessionPhase {
        switch status {
        case "processing":
            return .processing
        case "running_tool":
            return .runningTool
        case "waiting_for_input":
            return .waitingForInput
        case "waiting_for_approval":
            return .waitingForApproval
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        case "idle":
            return .idle
        case "stop_pending":
            return .stopPending
        case "tool_failed":
            return .toolFailed  // New
        case "error":
            return .error       // New
        case "subagent_active", "subagent_done":
            return .processing  // Keep current phase, will handle in AIManager
        case "cwd_changed":
            return .processing  // No phase change, just update cwd
        default:
            if event == "SessionEnd" {
                return .ended
            }
            return .idle
        }
    }
```

- [ ] **Step 2: AISessionPhase 新增枚举值**

在 `AISessionState.swift` 的 `AISessionPhase` enum 中添加：

```swift
enum AISessionPhase: String, Codable {
    case idle
    case processing
    case runningTool = "running_tool"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case compacting
    case ended
    case stopPending = "stop_pending"
    case toolFailed = "tool_failed"  // New
    case error                       // New
    
    // ... rest unchanged
}
```

- [ ] **Step 3: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 4: 提交**

```bash
git add boringNotch/AI/Models/AIHookEvent.swift boringNotch/AI/Models/AISessionState.swift
git commit -m "feat(ai-models): add toolFailed and error phases"
```

---

## Task 8: 验证 Phase 1 功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用并触发 Hook 安装**

运行：`open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app`

检查 Hook 脚本是否更新：
```bash
cat ~/.claude/hooks/boringnotch-ai-state.py | grep -A 20 "status_map"
```

预期：包含 `tool_failed`, `error`, `subagent_active` 等新映射

- [ ] **Step 2: 启动 2 个 Claude session**

在不同目录启动两个 Claude Code session，执行简单任务。

- [ ] **Step 3: 检查状态文件是否独立**

```bash
ls ~/Library/Containers/theboringteam.boringnotch/Data/Library/Caches/boringnotch-ai-state-*.json
```

预期：看到多个状态文件，每个 session 一个

- [ ] **Step 4: ESC 中断测试**

在一个 session 中按 ESC，观察 Notch 显示是否立即更新（无等待超时）

- [ ] **Step 5: SessionEnd 清理验证**

关闭一个 session，等待 3 秒后检查状态文件是否被删除：

```bash
ls ~/Library/Containers/theboringteam.boringnotch/Data/Library/Caches/boringnotch-ai-state-*.json
```

预期：对应文件已删除

- [ ] **Step 6: 提交验证结果**

```bash
git add -A
git commit -m "test: phase 1 per-session state files verification passed"
```

---

## 完成标记

- [ ] Phase 1 实施完成，所有测试通过
- [ ] 代码已提交到 ai-integration 分支