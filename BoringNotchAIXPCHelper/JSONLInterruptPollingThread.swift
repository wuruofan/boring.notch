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

        // Send Distributed notification
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.boringnotch.ai.interrupt"),
            object: nil
        )

        NSLog("JSONLInterruptPollingThread: Sent interrupt notification for \(sessionId.prefix(8))")

        // Stop polling after interrupt detected (session will be cleaned up)
        isRunning = false
    }
}