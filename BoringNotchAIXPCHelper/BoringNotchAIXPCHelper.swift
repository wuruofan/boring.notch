import Foundation

/// AI XPC Helper implementation.
/// Runs outside the sandbox to create and manage Unix Domain Socket server.
class BoringNotchAIXPCHelper: NSObject, BoringNotchAIXPCHelperProtocol {

    private var hookServer: AIHookServerCore?

    func startServer(with reply: @escaping (Bool) -> Void) {
        guard hookServer == nil else {
            reply(true)
            return
        }

        let server = AIHookServerCore()
        server.start()
        hookServer = server
        NSLog("BoringNotchAIXPCHelper: Server started")
        reply(true)
    }

    func stopServer(with reply: @escaping (Bool) -> Void) {
        hookServer?.stop()
        hookServer = nil
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
}
