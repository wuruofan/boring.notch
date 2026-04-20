import Foundation

struct AIHookEvent: Codable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let pid: Int?
    let tty: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case event
        case status
        case tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case pid
        case tty
    }

    func toPhase() -> AISessionPhase {
        // Respect the status field from hook script first
        // Hook script determines the semantic meaning of each event
        switch status {
        case "processing":
            return .processing
        case "running_tool":
            return .runningTool
        case "waiting_for_input":
            return .waitingForInput
        case "waiting_for_approval":
            return .waitingForApproval
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        case "idle":
            return .idle
        case "stop_pending":
            return .stopPending
        case "tool_failed":
            return .toolFailed
        case "error":
            return .error
        case "subagent_active", "subagent_done":
            return .processing  // Keep current phase, will handle in AIManager
        case "cwd_changed":
            return .processing  // No phase change, will handle in AIManager before toPhase()
        default:
            // Fallback: only SessionEnd always means ended
            if event == "SessionEnd" {
                return .ended
            }
            return .idle
        }
    }

    var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}
