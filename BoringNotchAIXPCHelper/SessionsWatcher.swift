import Foundation

/// Thread-based polling sessions watcher for XPC Helper.
/// Monitors ~/.claude/sessions/*.json files for status changes (busy/idle) and file deletion (ended).
/// Uses Thread.polling because DispatchSource doesn't work in XPC Service (no RunLoop).
class SessionsWatcher {
    private var pollingThread: Thread?
    private let isRunningLock = NSLock()
    private var _isRunning: Bool = false

    // Callback for sending status updates
    var onStatusChange: ((String, String) -> Void)?  // (sessionId, status)

    // Track previous states to detect changes
    private var prevStates: [Int: String] = [:]  // pid -> status
    private var pidToSessionId: [Int: String] = [:]  // pid -> sessionId (for deletion detection)
    private var knownSessionIds: Set<String> = []  // All known sessionIds
    private let sessionsDir: String

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

    init() {
        self.sessionsDir = NSHomeDirectory() + "/.claude/sessions/"
    }

    // MARK: - Public

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollingThread = Thread {
            self.runPollingLoop()
        }
        pollingThread?.start()
        NSLog("SessionsWatcher: Started polling sessions directory")
    }

    func stop() {
        isRunning = false
        pollingThread = nil
        prevStates.removeAll()
        pidToSessionId.removeAll()
        knownSessionIds.removeAll()
        NSLog("SessionsWatcher: Stopped polling")
    }

    // MARK: - Polling Loop

    private func runPollingLoop() {
        while isRunning {
            checkSessionsDirectory()
            Thread.sleep(forTimeInterval: 0.3)  // Poll every 300ms
        }
    }

    private func checkSessionsDirectory() {
        guard FileManager.default.fileExists(atPath: sessionsDir) else {
            // Directory doesn't exist, all sessions ended
            for sessionId in knownSessionIds {
                NSLog("SessionsWatcher: Directory missing, session ended - sessionId=\(sessionId.prefix(8))")
                sendStatusCallback(sessionId: sessionId, status: "ended")
            }
            knownSessionIds.removeAll()
            pidToSessionId.removeAll()
            prevStates.removeAll()
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
            let jsonFiles = files.filter { $0.hasSuffix(".json") }

            // Collect current sessionIds
            var currentSessionIds: Set<String> = []
            var currentPidToSessionId: [Int: String] = [:]

            for filename in jsonFiles {
                let filepath = sessionsDir + filename
                if let (sessionId, pid, status) = parseSessionFile(filepath: filepath) {
                    currentSessionIds.insert(sessionId)
                    currentPidToSessionId[pid] = sessionId

                    // Detect status change
                    let prevStatus = prevStates[pid]
                    if prevStatus != status {
                        prevStates[pid] = status
                        NSLog("SessionsWatcher: Status change - sessionId=\(sessionId.prefix(8)), pid=\(pid), status=\(status)")
                        sendStatusCallback(sessionId: sessionId, status: status)
                    }
                }
            }

            // Detect deleted sessions (files removed)
            let deletedSessionIds = knownSessionIds.subtracting(currentSessionIds)
            for sessionId in deletedSessionIds {
                NSLog("SessionsWatcher: Session ended (file deleted) - sessionId=\(sessionId.prefix(8))")
                sendStatusCallback(sessionId: sessionId, status: "ended")

                // Remove from tracking
                if let pid = pidToSessionId.first(where: { $0.value == sessionId })?.key {
                    prevStates.removeValue(forKey: pid)
                    pidToSessionId.removeValue(forKey: pid)
                }
            }

            // Update tracking state
            knownSessionIds = currentSessionIds
            pidToSessionId = currentPidToSessionId

        } catch {
            NSLog("SessionsWatcher: Error reading sessions directory: \(error)")
        }
    }

    private func parseSessionFile(filepath: String) -> (sessionId: String, pid: Int, status: String)? {
        guard let data = FileManager.default.contents(atPath: filepath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let pid = json["pid"] as? Int,
              let sessionId = json["sessionId"] as? String,
              let status = json["status"] as? String else {
            return nil
        }

        return (sessionId, pid, status)
    }

    private func sendStatusCallback(sessionId: String, status: String) {
        onStatusChange?(sessionId, status)
        NSLog("SessionsWatcher: Sent status callback for \(sessionId.prefix(8)) -> \(status)")
    }
}