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

    // MARK: - Private

    private var hookServer: AIHookServer?
    private var cancellables = Set<AnyCancellable>()
    private var persistentPeekTimeoutTask: Task<Void, Never>?

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
        guard Defaults[.aiEnabled] else { return }
        hookServer?.start()
        isConnected = true
        NSLog("AIManager: Started")
    }

    func stop() {
        hookServer?.stop()
        sessions.removeAll()
        activeSessionId = nil
        isActive = false
        isConnected = false
        persistentPeekTimeoutTask?.cancel()
        NSLog("AIManager: Stopped")
    }

    // MARK: - Event Handling

    private func handleHookEvent(_ event: AIHookEvent) {
        let sessionId = event.sessionId
        let phase = event.toPhase()

        // Update or create session
        var session = sessions[sessionId] ?? AISessionState(
            id: sessionId,
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
                sessionId: sessionId,
                cwd: event.cwd,
                pid: event.pid,
                tty: event.tty
            )
        } else if phase != .waitingForApproval {
            session.permissionRequest = nil
        }

        // Remove ended sessions
        if phase == .ended {
            sessions.removeValue(forKey: sessionId)
            if activeSessionId == sessionId {
                activeSessionId = nil
                isActive = false
            }
            updateCoordinator()
            return
        }

        sessions[sessionId] = session

        // Update active session
        if phase.isActive || phase.needsAttention {
            activeSessionId = sessionId
            isActive = true
        } else if activeSessionId == sessionId && phase == .idle {
            activeSessionId = nil
            isActive = false
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

        if isActive && Defaults[.aiShowInNotch] {
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
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.persistentPeekTimeoutTask = nil
                    coordinator.sneakPeek.persistent = false
                    coordinator.toggleSneakPeek(status: false, type: .ai)
                }
            }
        } else {
            persistentPeekTimeoutTask?.cancel()
            coordinator.sneakPeek.persistent = false
            coordinator.toggleSneakPeek(status: false, type: .ai)
        }
    }

    // MARK: - Approval Actions

    func approveOnce() async {
        guard let request = currentSession?.permissionRequest else { return }

        // Respond via socket
        hookServer?.respondToPermission(toolUseId: request.id, decision: "allow")

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

        hookServer?.respondToPermission(toolUseId: request.id, decision: "allow")

        if let pid = request.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.approveAlways(target: target)
        } else if let tty = request.tty {
            await ToolApprovalHandler.shared.jumpToTerminal(tty: tty)
        }
    }

    func reject(reason: String? = nil) async {
        guard let request = currentSession?.permissionRequest else { return }

        hookServer?.respondToPermission(toolUseId: request.id, decision: "deny", reason: reason)

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
