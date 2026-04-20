import Foundation

/// Protocol for the AI XPC Helper service.
/// The helper runs outside the sandbox and manages the Unix Domain Socket server
/// and JSONL interrupt watchers.
/// Interrupt detection uses Darwin Notification (CFNotificationCenter) for real-time
/// cross-process communication.
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

    // MARK: - State File Cleanup

    /// Clean up the state file for a specific session.
    /// Called by main app after processing SessionEnd event.
    func cleanupStateFile(sessionId: String, with reply: @escaping (Bool) -> Void)

    // MARK: - JSONL Interrupt Watching

    /// Start watching a session's JSONL file for interrupts.
    /// When interrupt is detected, a Darwin Notification is sent with name:
    /// "com.boringnotch.ai.interrupt" and session ID written to /tmp/boringnotch-interrupt-<sessionId>.txt
    func startInterruptWatcher(sessionId: String, cwd: String, with reply: @escaping (Bool) -> Void)
    /// Stop watching a session's JSONL file
    func stopInterruptWatcher(sessionId: String, with reply: @escaping (Bool) -> Void)
}
