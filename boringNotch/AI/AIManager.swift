import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
class AIManager: ObservableObject {
    static let shared = AIManager()

    // MARK: - Published State

    @Published var sessions: [String: AISessionState] = [:]
    @Published var activeSessionId: String?
    @Published var isActive: Bool = false
    @Published var isConnected: Bool = false
    @Published var lastError: String?

    // MARK: - Computed

    var currentPhase: AISessionPhase {
        guard let sessionId = activeSessionId,
              let session = sessions[sessionId] else {
            return .idle
        }
        return session.phase
    }

    var currentSession: AISessionState? {
        guard let sessionId = activeSessionId else { return nil }
        return sessions[sessionId]
    }

    var hasPendingApproval: Bool {
        currentSession?.permissionRequest != nil
    }

    // MARK: - Multi-Session Support

    /// Sessions sorted by priority (highest first).
    var sortedSessions: [AISessionState] {
        let sorted = SessionPriorityHelper.sortSessions(Array(sessions.values))
        // Debug: log session details with full IDs
        if sessions.count > 0 {
            let details = sessions.keys.map { k in "\(k):\(sessions[k]?.phase.rawValue ?? "?")" }.joined(separator: ",")
            appendAILog("sortedSessions: count=\(sessions.count), dict=[\(details)]\n")
        }
        return sorted
    }

    /// The session requiring most attention (for collapsed state display).
    var highestPrioritySession: AISessionState? {
        sortedSessions.first
    }

    /// Count of sessions waiting for approval.
    var approvalPendingCount: Int {
        sessions.values.filter { $0.phase == .waitingForApproval }.count
    }

    /// Has any session waiting for approval.
    var hasAnyPendingApproval: Bool {
        sessions.values.contains { $0.phase == .waitingForApproval }
    }

    // MARK: - Private

    private var hookServer: AIHookServer?

    // Expose for cleanup after SessionEnd
    static var sharedHookServer: AIHookServer? {
        AIManager.shared.hookServer
    }
    private var cancellables = Set<AnyCancellable>()
    private var persistentPeekTimeoutTask: Task<Void, Never>?
    private var staleProcessingCleanupTimer: Timer?

    private static let logPath: String = {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
        return cachesPath + "/ai-debug.log"
    }()

    private func appendAILog(_ msg: String) {
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

    private init() {
        hookServer = AIHookServer()
        hookServer?.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleHookEvent(event)
            }
        }
        hookServer?.onPermissionFailure = { [weak self] sessionId, toolUseId in
            Task { @MainActor in
                self?.handlePermissionFailure(sessionId: sessionId, toolUseId: toolUseId)
            }
        }

        // Set up XPC interrupt detection callback
        AIXPCClient.shared.onInterruptDetected = { [weak self] sessionId in
            Task { @MainActor in
                self?.handleXPCInterrupt(sessionId: sessionId)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        appendAILog("AIManager.start() called, aiEnabled=\(Defaults[.aiEnabled])\n")
        guard Defaults[.aiEnabled] else {
            appendAILog("AIManager: Skipping start - AI disabled\n")
            return
        }
        hookServer?.start()
        appendAILog("AIManager: hookServer started\n")
        Task {
            let success = await AIXPCClient.shared.startServer()
            isConnected = success
            appendAILog("AIManager: XPC startServer result = \(success)\n")
        }

        // Start cleanup timer for stale processing sessions (every 10 seconds)
        staleProcessingCleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.convertStaleProcessingToIdle()
            }
        }
    }

    func stop() {
        hookServer?.stop()
        staleProcessingCleanupTimer?.invalidate()
        staleProcessingCleanupTimer = nil
        Task {
            _ = await AIXPCClient.shared.stopServer()
        }
        sessions.removeAll()
        activeSessionId = nil
        isActive = false
        isConnected = false
        persistentPeekTimeoutTask?.cancel()
    }

    // MARK: - Event Handling

    private func handleHookEvent(_ event: AIHookEvent) {
        let sessionId = event.sessionId
        let phase = event.toPhase()

        // Append log for event handling
        appendAILog("handleHookEvent: event=\(event.event) phase=\(phase.rawValue) sessionId=\(sessionId)\n")

        // Handle termination events: only remove session when truly ended
        // Stop can mean ESC interrupt (phase=idle) - keep session, update state
        // SessionEnd always means termination
        if phase == .ended || event.event == "SessionEnd" {
            if sessionId.isEmpty {
                // Global cleanup for empty sessionId
                appendAILog("handleHookEvent: Global cleanup - clearing all sessions\n")
                sessions.removeAll()
                activeSessionId = nil
                isActive = false
                updateCoordinator()
                return
            } else {
                // Remove specific session, even if not in dictionary
                appendAILog("handleHookEvent: Session ended, removing \(sessionId.prefix(8))\n")
                sessions.removeValue(forKey: sessionId)

                // Delayed cleanup: wait 2 seconds before deleting state file
                // This ensures the polling loop has time to read the SessionEnd event
                // Note: Task lifecycle is bound to AIManager; if app exits, zombie cleanup will handle it
                let sessionIdCopy = sessionId  // Capture for Task
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await AIXPCClient.shared.cleanupStateFile(sessionId: sessionIdCopy)
                    // Clear hash entry to prevent memory leak (now thread-safe)
                    AIManager.sharedHookServer?.clearHash(sessionId: sessionIdCopy)
                }

                if activeSessionId == sessionId {
                    activeSessionId = nil
                    isActive = false
                    // Check if other sessions are still active (only processing/approval phases)
                    for remaining in sessions.values {
                        if remaining.phase.isActive || remaining.phase == .waitingForApproval {
                            activeSessionId = remaining.id
                            isActive = true
                            appendAILog("handleHookEvent: Found other active session \(remaining.id.prefix(8))\n")
                            break
                        }
                    }
                }
                updateCoordinator()
                return
            }
        }

        // Use sessionId if available, otherwise use toolUseId or pid as fallback identifier
        let effectiveSessionId: String
        if !sessionId.isEmpty {
            effectiveSessionId = sessionId
        } else if let toolUseId = event.toolUseId, !toolUseId.isEmpty {
            effectiveSessionId = "tool-\(toolUseId)"
        } else if let pid = event.pid {
            effectiveSessionId = "pid-\(pid)"
        } else {
            // No valid identifier, skip this event
            appendAILog("handleHookEvent: Skipping event with no valid identifier\n")
            return
        }

        // Update or create session
        var session = sessions[effectiveSessionId] ?? AISessionState(
            id: effectiveSessionId,
            phase: .idle,
            lastUpdated: Date()
        )

        session.phase = phase
        session.cwd = event.cwd
        session.pid = event.pid
        session.tty = event.tty
        session.lastUpdated = Date()

        // Handle stopPending: keep as idle temporarily, let idle_prompt override
        // Note: Hook event order is unpredictable due to polling/async issues
        // idle_prompt may arrive AFTER Stop, so we don't make final decision here
        if phase == .stopPending {
            // Temporarily set to idle - will be overridden by idle_prompt if task completed
            session.phase = .idle
            appendAILog("handleHookEvent: Stop → idle (temporary, will be overridden by idle_prompt if task completed)\n")
        }

        // idle_prompt event: always means task completed, override any previous state
        // idle_prompt is only sent by Claude Code when task is actually done
        if phase == .waitingForInput {
            session.phase = .waitingForInput
            appendAILog("handleHookEvent: idle_prompt → waitingForInput (task completed)\n")
        }

        if let tool = event.tool {
            session.currentTool = tool
        }

        // Handle permission requests
        if phase == .waitingForApproval, let toolUseId = event.toolUseId {
            session.permissionRequest = AIPermissionRequest(
                id: toolUseId,
                tool: event.tool ?? "",
                toolInput: event.toolInput,
                sessionId: effectiveSessionId,
                cwd: event.cwd,
                pid: event.pid,
                tty: event.tty
            )
        } else if phase != .waitingForApproval {
            session.permissionRequest = nil
        }

        sessions[effectiveSessionId] = session

        // Start XPC interrupt watcher when session enters processing state
        if session.phase == .processing, let cwd = session.cwd {
            Task {
                await AIXPCClient.shared.startInterruptWatcher(sessionId: effectiveSessionId, cwd: cwd)
            }
            appendAILog("handleHookEvent: Started XPC interrupt watcher for \(effectiveSessionId.prefix(8))\n")
        }

        // Stop XPC interrupt watcher when session ends or becomes idle
        if session.phase == .ended || session.phase == .idle || session.phase == .waitingForInput {
            Task {
                await AIXPCClient.shared.stopInterruptWatcher(sessionId: effectiveSessionId)
            }
        }

        // Update active session - only truly active phases (processing, running tool, compacting)
        // or waiting for approval (needs user decision)
        if phase.isActive || phase == .waitingForApproval {
            activeSessionId = effectiveSessionId
            isActive = true
            appendAILog("handleHookEvent: Set isActive=true, phase=\(phase.rawValue)\n")
        } else if activeSessionId == effectiveSessionId && (phase == .idle || phase == .ended) {
            activeSessionId = nil
            isActive = false
            appendAILog("handleHookEvent: Set isActive=false for session \(effectiveSessionId.prefix(8))\n")
            // Check if other sessions are still active (only processing/approval phases)
            appendAILog("handleHookEvent: Checking other sessions, total=\(sessions.count)\n")
            for remaining in sessions.values {
                appendAILog("handleHookEvent: Session \(remaining.id.prefix(8)) phase=\(remaining.phase.rawValue)\n")
                if remaining.phase.isActive || remaining.phase == .waitingForApproval {
                    activeSessionId = remaining.id
                    isActive = true
                    appendAILog("handleHookEvent: Found other active session \(remaining.id.prefix(8))\n")
                    break
                }
            }
        }

        updateCoordinator()
    }

    private func handlePermissionFailure(sessionId: String, toolUseId: String) {
        if var session = sessions[sessionId] {
            if session.permissionRequest?.id == toolUseId {
                session.permissionRequest = nil
            }
            sessions[sessionId] = session
        }
    }

    private func updateCoordinator() {
        let coordinator = BoringViewCoordinator.shared
        // Show peek when: AI is active OR there are idle sessions (ESC interrupted but still watching)
        let hasIdleSessions = sessions.values.contains { $0.phase == .idle || $0.phase == .waitingForInput }
        let show = (isActive || hasIdleSessions) && Defaults[.aiShowInNotch]
        appendAILog("updateCoordinator: isActive=\(isActive), hasIdleSessions=\(hasIdleSessions), show=\(show)\n")
        appendAILog("updateCoordinator: sneakPeek.show=\(coordinator.sneakPeek.show), isAI=\(coordinator.sneakPeek.type == .ai)\n")
        appendAILog("updateCoordinator: expandingView.show=\(coordinator.expandingView.show), type=\(coordinator.expandingView.type)\n")

        if show {
            appendAILog("updateCoordinator: Calling toggleSneakPeek(status=true, type=.ai)\n")
            coordinator.toggleSneakPeek(
                status: true,
                type: .ai,
                duration: .infinity,
                persistent: true
            )

            // Timeout for persistent peek (10 minutes max)
            persistentPeekTimeoutTask?.cancel()
            persistentPeekTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.persistentPeekTimeoutTask = nil
                    coordinator.sneakPeek.persistent = false
                    coordinator.toggleSneakPeek(status: false, type: .ai)
                }
            }
        } else {
            appendAILog("updateCoordinator: toggleSneakPeek(status=false) - conditions not met\n")
            persistentPeekTimeoutTask?.cancel()
            coordinator.sneakPeek.persistent = false
            coordinator.toggleSneakPeek(status: false, type: .ai)
        }
    }

    // MARK: - Approval Actions

    func approveOnce() async {
        guard let request = currentSession?.permissionRequest else { return }

        // Respond via XPC (which sends through the socket)
        _ = await AIXPCClient.shared.respondToPermission(
            toolUseId: request.id, decision: "allow"
        )

        // Also try tmux
        if let pid = request.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.approveOnce(target: target)
        } else if let tty = request.tty {
            await ToolApprovalHandler.shared.jumpToTerminal(tty: tty)
        }
    }

    func approveAlways() async {
        guard let request = currentSession?.permissionRequest else { return }

        _ = await AIXPCClient.shared.respondToPermission(
            toolUseId: request.id, decision: "allow"
        )

        if let pid = request.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.approveAlways(target: target)
        } else if let tty = request.tty {
            await ToolApprovalHandler.shared.jumpToTerminal(tty: tty)
        }
    }

    func reject(reason: String? = nil) async {
        guard let request = currentSession?.permissionRequest else { return }

        _ = await AIXPCClient.shared.respondToPermission(
            toolUseId: request.id, decision: "deny", reason: reason
        )

        if let pid = request.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.reject(target: target, message: reason)
        } else if let tty = request.tty {
            await ToolApprovalHandler.shared.jumpToTerminal(tty: tty)
        }
    }

    func sendReply(_ message: String) async {
        guard let session = currentSession,
              let pid = session.pid else { return }

        if let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.sendReply(target: target, message: message)
        }
    }

    // MARK: - Cleanup

    func clearStaleSessions() {
        let threshold = Date().addingTimeInterval(-300)
        sessions = sessions.filter { $0.value.lastUpdated > threshold }
    }

    /// Convert stale processing sessions to idle.
    /// Different timeouts for different phases:
    /// - processing: 15 seconds (thinking shouldn't take too long)
    /// - running_tool: 120 seconds (tools like Bash can take minutes)
    /// - compacting: 60 seconds (context compression needs time)
    func convertStaleProcessingToIdle() {
        let now = Date()
        var changed = false

        for (sessionId, session) in sessions {
            let timeout: TimeInterval
            switch session.phase {
            case .processing:
                timeout = 15  // Thinking phase - short timeout
            case .runningTool:
                timeout = 120  // Tool execution - long timeout (2 minutes)
            case .compacting:
                timeout = 60  // Context compression - medium timeout
            default:
                continue  // Not an active phase, skip
            }

            if now.timeIntervalSince(session.lastUpdated) > timeout {
                sessions[sessionId]?.phase = .idle
                changed = true
                appendAILog("convertStaleProcessingToIdle: Session \(sessionId.prefix(8)) timed out from \(session.phase.rawValue) to idle (timeout=\(timeout)s)\n")

                // If this was the active session, need to re-evaluate activeSessionId
                if activeSessionId == sessionId {
                    activeSessionId = nil
                    isActive = false
                    for remaining in sessions.values where remaining.id != sessionId {
                        if remaining.phase.isActive || remaining.phase == .waitingForApproval {
                            activeSessionId = remaining.id
                            isActive = true
                            appendAILog("convertStaleProcessingToIdle: Found other active session \(remaining.id.prefix(8))\n")
                            break
                        }
                    }
                }
            }
        }

        // Update UI if any session changed
        if changed {
            updateCoordinator()
        }
    }
}

// MARK: - XPC Interrupt Handling

extension AIManager {
    /// Handle interrupt detected by XPC Helper via Darwin Notification
    func handleXPCInterrupt(sessionId: String) {
        // Convert processing session to idle on interrupt detection
        if var session = sessions[sessionId] {
            session.phase = .idle
            session.lastUpdated = Date()
            sessions[sessionId] = session
            appendAILog("handleXPCInterrupt: Session \(sessionId.prefix(8)) interrupted -> idle\n")

            // Stop XPC watcher for this session
            Task {
                await AIXPCClient.shared.stopInterruptWatcher(sessionId: sessionId)
            }

            // Update coordinator to reflect state change
            updateCoordinator()
        }
    }
}
