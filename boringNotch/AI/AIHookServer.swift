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
        if let data = msg.data(using: .utf8) {
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

        // Set up Darwin Notification callback for immediate response
        AIXPCClient.shared.onStateUpdateDetected = { [weak self] in
            self?.pollStateFiles()
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
        AIXPCClient.shared.onStateUpdateDetected = nil
        appendLog("AIHookServer.stop() - polling stopped, tasks cancelled, callback cleared\n")
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

        // Zombie file cleanup: delete files older than timeout
        cleanupZombieFiles(files: stateFiles, basePath: basePath)
    }

    private func processStateFileWithDedup(path: String, fileName: String) {
        // Check file modification time for zombie detection
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        // Parse file to check status - use longer timeout for waiting_for_approval
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            return
        }

        let isApprovalFile: Bool = {
            guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else { return false }
            return event.status == "waiting_for_approval"
        }()

        // Skip zombie files (older than timeout)
        let skipTimeout: TimeInterval = isApprovalFile ? 1800 : 300  // 30 min for approval, 5 min otherwise
        if Date().timeIntervalSince(modDate) > skipTimeout {
            appendLog("processStateFileWithDedup: Skipping zombie file \(fileName)\n")
            return
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

        appendLog("processStateFileWithDedup: New data for \(sessionId), processing\n")
        processStateFile(data: data)
    }

    private func cleanupZombieFiles(files: [String], basePath: String) {
        for fileName in files {
            let filePath = basePath + "/" + fileName
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }

            // Parse file to check status - don't delete if waiting_for_approval
            let isApprovalFile: Bool = {
                guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else { return false }
                return event.status == "waiting_for_approval"
            }()

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
}