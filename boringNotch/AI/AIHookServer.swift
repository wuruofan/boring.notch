import Foundation

/// File-based event receiver for Claude Code hook events.
/// The XPC Helper (unsandboxed) runs the actual Socket server and writes
/// received events to a state file. This class polls that file.
/// Note: File watching via DispatchSource is blocked by sandbox, so we use polling.
class AIHookServer {
    /// State file path in sandbox container Caches directory
    static let stateFilePath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath + "/boringnotch-ai-state.json"
    }()

    static let logPath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath + "/hookserver-debug.log"
    }()

    var onEvent: ((AIHookEvent) -> Void)?
    var onPermissionFailure: ((_ sessionId: String, _ toolUseId: String) -> Void)?

    private var pollingTask: Task<Void, Never>?
    private var lastContentHash: String?

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
        appendLog("AIHookServer.start() - path=\(Self.stateFilePath)\n")
        startPolling()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        appendLog("AIHookServer.stop() - polling stopped\n")
    }

    func hasPendingPermission(sessionId: String) async -> Bool {
        await AIXPCClient.shared.hasPendingPermission(sessionId: sessionId)
    }

    // MARK: - Polling

    private func startPolling() {
        appendLog("startPolling: Starting polling task\n")
        pollingTask = Task.detached { [weak self] in
            var count = 0
            while !Task.isCancelled {
                count += 1
                if count % 50 == 0 {  // Log every 10 seconds (50 * 200ms)
                    self?.appendLog("polling: tick \(count)\n")
                }
                self?.pollStateFile()
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.appendLog("polling: Task cancelled\n")
        }
    }

    private func pollStateFile() {
        let path = Self.stateFilePath
        // Check file exists
        let exists = FileManager.default.fileExists(atPath: path)

        // Try to read
        let url = URL(fileURLWithPath: path)
        let readResult: Data? = try? Data(contentsOf: url)

        if !exists {
            appendLog("pollStateFile: File not exists at \(path)\n")
            return
        }

        guard let data = readResult, !data.isEmpty else {
            if readResult == nil {
                appendLog("pollStateFile: Data read failed (file exists but read error)\n")
            } else {
                appendLog("pollStateFile: Data is empty\n")
            }
            return
        }

        // Hash-based deduplication
        let contentHash = data.base64EncodedString()
        if contentHash == lastContentHash { return }
        lastContentHash = contentHash

        appendLog("pollStateFile: Got new data (\(data.count) bytes), processing\n")
        processStateFile(data: data)
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