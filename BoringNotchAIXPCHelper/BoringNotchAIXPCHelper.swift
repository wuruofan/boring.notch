import Foundation

/// AI XPC Helper implementation.
/// Runs outside the sandbox to create and manage Unix Domain Socket server
/// and JSONL interrupt watchers.
class BoringNotchAIXPCHelper: NSObject, BoringNotchAIXPCHelperProtocol {

    private var hookServer: AIHookServerCore?
    private var connection: NSXPCConnection?
    private var sessionsWatcher: SessionsWatcher?

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

        // Start sessions watcher for busy/idle status
        startSessionsWatcher()

        reply(true)
    }

    private func startSessionsWatcher() {
        guard sessionsWatcher == nil else { return }
        let watcher = SessionsWatcher()
        watcher.onStatusChange = { [weak self] sessionId, status in
            self?.notifySessionStatus(sessionId: sessionId, status: status)
        }
        watcher.start()
        sessionsWatcher = watcher
        NSLog("BoringNotchAIXPCHelper: SessionsWatcher started")
    }

    func stopServer(with reply: @escaping (Bool) -> Void) {
        hookServer?.stop()
        hookServer = nil
        sessionsWatcher?.stop()
        sessionsWatcher = nil
        InterruptWatcherManagerCore.shared.stopAll()
        NSLog("BoringNotchAIXPCHelper: Server stopped")
        reply(true)
    }

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        reply(hookServer != nil)
    }

    func respondToPermission(toolUseId: String, decision: String, reason: String?, with reply: @escaping (Bool) -> Void) {
        let result = hookServer?.respondToPermission(toolUseId: toolUseId, decision: decision, reason: reason) ?? false
        reply(result)
    }

    func respondToPermissionBySession(sessionId: String, decision: String, reason: String?, with reply: @escaping (Bool) -> Void) {
        let result = hookServer?.respondToPermissionBySession(sessionId: sessionId, decision: decision, reason: reason) ?? false
        reply(result)
    }

    func hasPendingPermission(sessionId: String, with reply: @escaping (Bool) -> Void) {
        let result = hookServer?.hasPendingPermission(sessionId: sessionId) ?? false
        reply(result)
    }

    func getSocketPath(with reply: @escaping (String) -> Void) {
        reply(AIHookServerCore.socketPath)
    }

    // MARK: - JSONL Interrupt Watching

    func startInterruptWatcher(sessionId: String, cwd: String, with reply: @escaping (Bool) -> Void) {
        let result = InterruptWatcherManagerCore.shared.startWatching(sessionId: sessionId, cwd: cwd)
        reply(result)
    }

    func stopInterruptWatcher(sessionId: String, with reply: @escaping (Bool) -> Void) {
        let result = InterruptWatcherManagerCore.shared.stopWatching(sessionId: sessionId)
        reply(result)
    }

    func cleanupStateFile(sessionId: String, with reply: @escaping (Bool) -> Void) {
        let success = hookServer?.cleanupStateFile(sessionId: sessionId) ?? false
        reply(success)
    }

    // MARK: - Tmux Commands

    func runTmuxCommand(command: String, with reply: @escaping (Bool, String) -> Void) {
        runShellCommandInternal(command: command, reply: reply)
    }

    func runShellCommand(command: String, with reply: @escaping (Bool, String) -> Void) {
        runShellCommandInternal(command: command, reply: reply)
    }

    private func runShellCommandInternal(command: String, reply: @escaping (Bool, String) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            let success = task.terminationStatus == 0
            reply(success, output)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Sessions Query

    func getAllActiveSessionIds(with reply: @escaping ([String]) -> Void) {
        let sessionsDir = NSHomeDirectory() + "/.claude/sessions/"
        var sessionIds: [String] = []

        guard FileManager.default.fileExists(atPath: sessionsDir) else {
            reply(sessionIds)
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
            for filename in files where filename.hasSuffix(".json") {
                let filepath = sessionsDir + filename
                if let data = FileManager.default.contents(atPath: filepath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sessionId = json["sessionId"] as? String {
                    sessionIds.append(sessionId)
                }
            }
        } catch {
            NSLog("BoringNotchAIXPCHelper: Error reading sessions: \(error)")
        }

        NSLog("BoringNotchAIXPCHelper: getAllActiveSessionIds returned \(sessionIds.count) sessions")
        reply(sessionIds)
    }

    // MARK: - Connection Management

    /// Store connection reference to access remoteObjectProxy (main app's listener)
    func setConnection(_ conn: NSXPCConnection) {
        connection = conn
        NSLog("BoringNotchAIXPCHelper: Connection stored, remoteObjectInterface set")

        // Set helper reference chain for callbacks
        InterruptWatcherManagerCore.shared.setHelper(self)
        NSLog("BoringNotchAIXPCHelper: Helper reference chain set for InterruptWatcherManager")

        // Set helper reference for HookServer (will be set when server starts)
    }

    /// Get listener proxy from main app
    private func getListener() -> AIXPCEventListener? {
        guard let connection else {
            NSLog("BoringNotchAIXPCHelper: No connection available")
            return nil
        }

        let listener = connection.remoteObjectProxyWithErrorHandler { error in
            NSLog("BoringNotchAIXPCHelper: Listener error: \(error)")
        } as? AIXPCEventListener

        return listener
    }

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

    /// Send session status callback to main app (busy/idle from sessions/*.json)
    func notifySessionStatus(sessionId: String, status: String) {
        guard let listener = getListener() else { return }
        NSLog("BoringNotchAIXPCHelper: Calling listener.onSessionStatus for \(sessionId.prefix(8)) -> \(status)")
        listener.onSessionStatus(sessionId: sessionId, status: status)
    }

    // MARK: - Test Methods (for verification)

    /// Test callback by sending ping to main app's listener (XPC Protocol method)
    func testPing(with reply: @escaping (Bool) -> Void) {
        NSLog("BoringNotchAIXPCHelper: testPing called")
        guard let listener = getListener() else {
            NSLog("BoringNotchAIXPCHelper: No listener available")
            reply(false)
            return
        }

        NSLog("BoringNotchAIXPCHelper: Sending ping to listener...")
        listener.ping()
        reply(true)
        NSLog("BoringNotchAIXPCHelper: Ping sent")
    }
}
