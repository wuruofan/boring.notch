import Foundation

/// Protocol for the AI XPC Helper service.
/// The helper runs outside the sandbox and manages the Unix Domain Socket server.
@objc protocol BoringNotchAIXPCHelperProtocol {
    /// Start the socket server
    func startServer(with reply: @escaping (Bool) -> Void)
    /// Stop the socket server
    func stopServer(with reply: @escaping (Bool) -> Void)
    /// Check if the server is running
    func isServerRunning(with reply: @escaping (Bool) -> Void)
    /// Send a permission response to a waiting hook client
    func respondToPermission(toolUseId: String, decision: String, reason: String?, with reply: @escaping (Bool) -> Void)
    /// Send a permission response by session ID
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String?, with reply: @escaping (Bool) -> Void)
    /// Check if there's a pending permission for a session
    func hasPendingPermission(sessionId: String, with reply: @escaping (Bool) -> Void)
    /// Get the socket path
    func getSocketPath(with reply: @escaping (String) -> Void)
}
