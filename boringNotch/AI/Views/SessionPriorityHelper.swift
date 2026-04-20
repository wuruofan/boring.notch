import Foundation

/// Helper for sorting sessions by priority.
/// Reference: Claude-Island ClaudeInstancesView.phasePriority()
enum SessionPriorityHelper {
    /// Priority weight for session phase.
    /// Lower number = higher priority.
    static func priority(for phase: AISessionPhase) -> Int {
        switch phase {
        case .waitingForApproval:
            return 0  // Highest - needs immediate user action
        case .toolFailed, .error:
            return 1  // High - needs user attention (same as active work)
        case .processing, .runningTool, .compacting:
            return 2  // Active work
        case .waitingForInput:
            return 3  // Ready for new input
        case .idle, .ended, .stopPending:
            return 4  // Lowest
        }
    }

    /// Sort sessions by priority (highest first).
    /// Secondary sort: most recently updated first.
    static func sortSessions(_ sessions: [AISessionState]) -> [AISessionState] {
        sessions.sorted { lhs, rhs in
            let lhsPriority = priority(for: lhs.phase)
            let rhsPriority = priority(for: rhs.phase)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            // Secondary: most recently updated first
            return lhs.lastUpdated > rhs.lastUpdated
        }
    }
}