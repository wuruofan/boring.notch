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
        // Debug: log session count
        if sessions.count > 0 {
            appendAILog("sortedSessions: count=\(sessions.count), sessions=\(sessions.keys.map { $0.prefix(8) }.joined(separator: ","))\n")
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
    private var cancellables = Set<AnyCancellable>()
    private var persistentPeekTimeoutTask: Task<Void, Never>?

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
    }

    func stop() {
        hookServer?.stop()
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
        appendAILog("handleHookEvent: event=\(event.event) phase=\(phase.rawValue) sessionId=\(sessionId.isEmpty ? "empty" : sessionId.prefix(8))\n")

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
}
