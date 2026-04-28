import Foundation

/// Thread-based polling sessions watcher for XPC Helper.
/// Monitors ~/.claude/sessions/*.json files for status changes (busy/idle).
/// Uses Thread.polling because DispatchSource doesn't work in XPC Service (no RunLoop).
class SessionsWatcher {
    private var pollingThread: Thread?
    private let isRunningLock = NSLock()
    private var _isRunning: Bool = false

    // Callback for sending status updates
    var onStatusChange: ((String, String) -> Void)?  // (sessionId, status)

    // Track previous states to detect changes
    private var prevStates: [Int: String] = [:]  // pid -> status
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
        guard FileManager.default.fileExists(atPath: sessionsDir) else { return }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
            for filename in files where filename.hasSuffix(".json") {
                let filepath = sessionsDir + filename
                checkSessionFile(filepath: filepath)
            }
        } catch {
            NSLog("SessionsWatcher: Error reading sessions directory: \(error)")
        }
    }

    private func checkSessionFile(filepath: String) {
        guard let data = FileManager.default.contents(atPath: filepath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard let pid = json["pid"] as? Int,
              let sessionId = json["sessionId"] as? String,
              let status = json["status"] as? String else {
            return
        }

        // Detect status change
        let prevStatus = prevStates[pid]
        if prevStatus != status {
            prevStates[pid] = status
            NSLog("SessionsWatcher: Status change - sessionId=\(sessionId.prefix(8)), pid=\(pid), status=\(status)")
            sendStatusCallback(sessionId: sessionId, status: status)
        }
    }

    private func sendStatusCallback(sessionId: String, status: String) {
        onStatusChange?(sessionId, status)
        NSLog("SessionsWatcher: Sent status callback for \(sessionId.prefix(8)) -> \(status)")
    }
}