import Foundation

/// Darwin notification name for interrupt detection
let kInterruptNotificationName = "com.boringnotch.ai.interrupt"

/// JSONL interrupt watcher that runs inside XPC Helper (unsandboxed).
/// Uses DispatchSource for real-time file watching, which works outside sandbox.
/// Notifies main app via Darwin Notification when interrupt detected.
class JSONLInterruptWatcherCore {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionId: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.boringnotch.xpc.interruptwatcher", qos: .userInteractive)

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

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath) else {
            NSLog("JSONLInterruptWatcherCore: File not found: \(filePath)")
            return
        }

        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            NSLog("JSONLInterruptWatcherCore: Failed to open file: \(filePath)")
            return
        }

        fileHandle = handle

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            NSLog("JSONLInterruptWatcherCore: Failed to seek to end: \(error)")
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        NSLog("JSONLInterruptWatcherCore: Started watching \(sessionId.prefix(8))")
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return
        }

        lastOffset = currentSize

        let lines = newContent.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                NSLog("JSONLInterruptWatcherCore: Detected interrupt for \(sessionId.prefix(8))")
                sendInterruptNotification()
                return
            }
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

    /// Send Darwin notification with session ID as payload
    private func sendInterruptNotification() {
        // Write session ID to a temp file for main app to read
        let notifyPath = "/tmp/boringnotch-interrupt-\(sessionId).txt"
        try? sessionId.write(toFile: notifyPath, atomically: true, encoding: .utf8)

        // Send Darwin notification
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(kInterruptNotificationName as CFString),
            nil, nil, true
        )

        NSLog("JSONLInterruptWatcherCore: Sent interrupt notification for \(sessionId.prefix(8))")
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if source != nil {
            NSLog("JSONLInterruptWatcherCore: Stopped watching \(sessionId.prefix(8))")
        }
        source?.cancel()
        source = nil

        // Clean up notification file
        let notifyPath = "/tmp/boringnotch-interrupt-\(sessionId).txt"
        try? FileManager.default.removeItem(atPath: notifyPath)
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Interrupt Watcher Manager (XPC Helper)

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