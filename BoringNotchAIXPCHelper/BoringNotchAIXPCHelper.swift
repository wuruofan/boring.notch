import Foundation

/// AI XPC Helper implementation.
/// Runs outside the sandbox to create and manage Unix Domain Socket server
/// and JSONL interrupt watchers.
class BoringNotchAIXPCHelper: NSObject, BoringNotchAIXPCHelperProtocol {

    private var hookServer: AIHookServerCore?

    func startServer(with reply: @escaping (Bool) -> Void) {
        NSLog("BoringNotchAIXPCHelper: startServer called")
        guard hookServer == nil else {
            NSLog("BoringNotchAIXPCHelper: server already exists")
            reply(true)
            return
        }

        let server = AIHookServerCore()
        NSLog("BoringNotchAIXPCHelper: created AIHookServerCore, calling start()")
        server.start()
        hookServer = server
        NSLog("BoringNotchAIXPCHelper: Server started, replying true")
        reply(true)
    }

    func stopServer(with reply: @escaping (Bool) -> Void) {
        hookServer?.stop()
        hookServer = nil
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
}
