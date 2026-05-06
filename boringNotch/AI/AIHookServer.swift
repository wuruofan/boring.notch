import Foundation

/// File-based event receiver for Claude Code hook events.
/// The XPC Helper (unsandboxed) runs the actual Socket server and writes
/// received events to a state file. This class polls that file.
/// Note: File watching via DispatchSource is blocked by sandbox, so we use polling.
class AIHookServer {
    /// State file path in sandbox container Caches directory (deprecated, now per-session)
    static let stateFilePath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath + "/boringnotch-ai-state.json"
    }()

    /// Base path for all per-session state files
    static let stateFileBasePath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath
    }()

    static let logPath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath + "/hookserver-debug.log"
    }()

    var onEvent: ((AIHookEvent) -> Void)?
    var onPermissionFailure: ((_ sessionId: String, _ toolUseId: String) -> Void)?

    private var pollingTask: Task<Void, Never>?
    private var lastHashes: [String: String] = [:]  // sessionId -> hash
    private let hashQueue = DispatchQueue(label: "com.boringnotch.hashQueue")

    // Thread-safe storage for notification observer
    private var notificationObserverTask: Task<Void, Never>?

    // @MainActor isolated state for polling speed
    @MainActor private var hasWaitingForApproval: Bool = false

    // MARK: - Helper

    private func appendLog(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let msgWithTime = "[\(timestamp)] \(msg)"
        if let data = msgWithTime.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logPath) {
                if let fh = FileHandle(forWritingAtPath: Self.logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? msg.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Public

    func start() {
        appendLog("AIHookServer.start() - path=\(Self.stateFileBasePath)\n")

        // Set up listener for XPC callbacks (real-time, penetrates sandbox)
        Task { @MainActor [weak self] in
            let listener = AIXPCListener()
            listener.onStateUpdateReceived = { sessionIds in
                Task {
                    await self?.pollSpecificStateFiles(sessionIds: sessionIds)
                }
            }
            listener.onInterruptReceived = { sessionId in
                Task {
                    await self?.handleInterrupt(sessionId: sessionId)
                }
            }
            listener.onSessionStatusReceived = { sessionId, status in
                Task {
                    await self?.handleSessionStatus(sessionId: sessionId, status: status)
                }
            }
            AIXPCClient.shared.setListener(listener)
        }

        // Observe AIManager for waitingForApproval state changes
        notificationObserverTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AIWaitingForApprovalChanged) {
                self?.updatePollingSpeed()
            }
        }

        startPolling()
    }

    @MainActor
    private func updatePollingSpeed() {
        hasWaitingForApproval = AIManager.shared.hasAnyPendingApproval
        appendLog("updatePollingSpeed: waitingForApproval=\(hasWaitingForApproval)\n")
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        notificationObserverTask?.cancel()
        notificationObserverTask = nil
        appendLog("AIHookServer.stop() - polling stopped, tasks cancelled\n")
    }

    func hasPendingPermission(sessionId: String) async -> Bool {
        await AIXPCClient.shared.hasPendingPermission(sessionId: sessionId)
    }

    /// Clear hash entry for a session (called after cleanup)
    func clearHash(sessionId: String) {
        hashQueue.async { self.lastHashes.removeValue(forKey: sessionId) }
        appendLog("clearHash: Removed hash for \(sessionId)\n")
    }

    // MARK: - Polling

    private var isFirstPoll = true  // Track first poll after start

    private func startPolling() {
        appendLog("startPolling: Starting event-driven polling with 15s fallback\n")
        isFirstPoll = true  // Reset on start
        pollingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                // Thread-safe read: use await MainActor.run to read @MainActor isolated property
                let interval = await MainActor.run {
                    self?.hasWaitingForApproval ?? false ? 1.0 : 5.0  // 5s fallback, 1s for approval
                }
                await self?.pollStateFiles()  // Full scan as fallback
                try? await Task.sleep(for: .seconds(interval))
            }
            self?.appendLog("polling: Task cancelled\n")
        }
    }

    private func pollStateFiles() async {
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

        // Mark first poll as complete after processing all files
        if isFirstPoll {
            isFirstPoll = false
            appendLog("pollStateFiles: First poll complete, zombie cleanup enabled\n")
        }

        // Zombie file cleanup: delete files older than timeout (only after first poll)
        if !isFirstPoll {
            // Get active session IDs on main thread before cleanup
            let activeSessionIds = await MainActor.run {
                Set(AIManager.shared.sessions.keys)
            }
            cleanupZombieFiles(files: stateFiles, basePath: basePath, activeSessionIds: activeSessionIds)
        }
    }

    /// Poll specific state files identified by XPC callback
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

    private func processStateFileWithDedup(path: String, fileName: String) {
        // Parse file first to get status
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return
        }

        let isApprovalFile: Bool = {
            guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else { return false }
            return event.status == "waiting_for_approval"
        }()

        // Get file modification date
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        // Skip zombie files only after first poll (not on startup)
        if !isFirstPoll {
            let skipTimeout: TimeInterval = isApprovalFile ? 1800 : 300  // 30 min for approval, 5 min otherwise
            if Date().timeIntervalSince(modDate) > skipTimeout {
                appendLog("processStateFileWithDedup: Skipping zombie file \(fileName)\n")
                return
            }
        }

        // Extract sessionId from filename
        let sessionId = fileName
            .replacingOccurrences(of: "boringnotch-ai-state-", with: "")
            .replacingOccurrences(of: ".json", with: "")

        // Per-file hash deduplication
        let contentHash = data.base64EncodedString()
        let existingHash = hashQueue.sync { lastHashes[sessionId] }
        if existingHash == contentHash { return }
        hashQueue.async { self.lastHashes[sessionId] = contentHash }

        // On first poll (startup), check if file is stale (>5 min) and processing
        // If so, send a synthetic idle event instead
        let isStaleProcessing = isFirstPoll && !isApprovalFile && Date().timeIntervalSince(modDate) > 300
        if isStaleProcessing {
            appendLog("processStateFileWithDedup: Stale processing file \(fileName), converting to idle\n")
            processStaleFileAsIdle(data: data, modDate: modDate)
            return
        }

        appendLog("processStateFileWithDedup: New data for \(sessionId), processing\n")
        processStateFile(data: data)
    }

    private func processStaleFileAsIdle(data: Data, modDate: Date) {
        guard var event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else {
            return
        }
        // Create synthetic event with idle status
        event = AIHookEvent(
            sessionId: event.sessionId,
            cwd: event.cwd,
            event: "SessionTimeout",
            status: "idle",
            tool: event.tool,
            toolInput: event.toolInput,
            toolUseId: event.toolUseId,
            pid: event.pid,
            tty: event.tty
        )
        appendLog("processStaleFileAsIdle: Converting stale session \(event.sessionId.prefix(8)) to idle\n")
        onEvent?(event)
    }

    private func cleanupZombieFiles(files: [String], basePath: String, activeSessionIds: Set<String>) {
        for fileName in files {
            let filePath = basePath + "/" + fileName
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }

            // Parse file to check status and sessionId
            let (isApprovalFile, fileSessionId): (Bool, String) = {
                guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else { return (false, "") }
                return (event.status == "waiting_for_approval", event.sessionId)
            }()

            // Don't delete if this session is still active in AIManager
            if activeSessionIds.contains(fileSessionId) {
                appendLog("cleanupZombieFiles: Preserving active session file \(fileName)\n")
                continue
            }

            let timeout: TimeInterval = isApprovalFile ? 1800 : 300  // 30 min for approval, 5 min otherwise

            if Date().timeIntervalSince(modDate) > timeout {
                try? FileManager.default.removeItem(atPath: filePath)
                appendLog("cleanupZombieFiles: Removed zombie file \(fileName) (timeout=\(timeout)s)\n")

                // Remove from hash cache
                let sessionId = fileName
                    .replacingOccurrences(of: "boringnotch-ai-state-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                hashQueue.async { self.lastHashes.removeValue(forKey: sessionId) }
            }
        }
    }

    private func processStateFile(data: Data) {
        guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else {
            let raw = String(data: data, encoding: .utf8) ?? "?"
            appendLog("processStateFile: Failed to decode: \(raw.prefix(100))\n")
            return
        }

        appendLog("processStateFile: event=\(event.event) status=\(event.status), calling onEvent\n")
        onEvent?(event)
    }

    /// Handle interrupt callback from XPC Helper
    private func handleInterrupt(sessionId: String) async {
        appendLog("handleInterrupt: Received interrupt for \(sessionId.prefix(8))\n")

        // Post notification for AIManager to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: .AIInterruptDetected,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }

    /// Handle session status callback (busy/idle) from sessions/*.json
    private func handleSessionStatus(sessionId: String, status: String) async {
        appendLog("handleSessionStatus: Received status \(status) for \(sessionId.prefix(8))\n")

        // Post notification for AIManager to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: .AISessionStatusChanged,
                object: nil,
                userInfo: ["sessionId": sessionId, "status": status]
            )
        }
    }
}