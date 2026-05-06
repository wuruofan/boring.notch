import Foundation

/// Listener protocol for receiving callbacks from XPC Helper.
/// This allows the main app (sandboxed) to receive real-time events from XPC Helper (unsandboxed)
/// via XPC protocol callbacks, which naturally penetrate the sandbox boundary.
@objc protocol AIXPCEventListener {
    /// Called when state file is updated for specific sessions
    func onStateUpdate(sessionIds: [String])
    /// Called when ESC interrupt is detected for a session
    func onInterrupt(sessionId: String)
    /// Called when session status changes (busy/idle) from ~/.claude/sessions/*.json
    func onSessionStatus(sessionId: String, status: String)
    /// Ping for connectivity test (minimal verification)
    func ping()
}

/// Protocol for the AI XPC Helper service.
/// The helper runs outside the sandbox and manages the Unix Domain Socket server,
/// JSONL interrupt watchers, and sessions status monitoring.
/// All events are pushed via XPC callbacks (penetrates sandbox boundary).
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
    /// When interrupt is detected, XPC callback notifyInterrupt(sessionId) is sent.
    func startInterruptWatcher(sessionId: String, cwd: String, with reply: @escaping (Bool) -> Void)
    /// Stop watching a session's JSONL file
    func stopInterruptWatcher(sessionId: String, with reply: @escaping (Bool) -> Void)

    // MARK: - Tmux Commands

    /// Run a tmux command (switch-client, etc.)
    /// Returns (success: Bool, output: String)
    func runTmuxCommand(command: String, with reply: @escaping (Bool, String) -> Void)

    /// Run a shell command (open, etc.)
    /// Returns (success: Bool, output: String)
    func runShellCommand(command: String, with reply: @escaping (Bool, String) -> Void)

    // MARK: - Sessions Query

    /// Get all active session IDs from ~/.claude/sessions/*.json
    /// Returns array of sessionIds
    func getAllActiveSessionIds(with reply: @escaping ([String]) -> Void)

    // MARK: - Test Callback (for verification)

    /// Test XPC callback by sending ping to main app's listener.
    /// XPC Helper gets listener via remoteObjectProxy and calls listener.ping()
    func testPing(with reply: @escaping (Bool) -> Void)
}
