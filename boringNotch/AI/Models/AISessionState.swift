import Foundation

enum AISessionPhase: String, Codable {
    case idle
    case processing
    case runningTool = "running_tool"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case compacting
    case ended
    case stopPending = "stop_pending"  // Special: awaiting Swift-side decision
    case toolFailed = "tool_failed"    // Tool execution failed
    case error                         // API error or catastrophic failure

    /// Only waiting_for_approval truly needs user attention.
    /// waiting_for_input means session is ready for new prompt (normal idle state).
    /// toolFailed and error also need attention.
    var needsAttention: Bool {
        self == .waitingForApproval || self == .toolFailed || self == .error
    }

    var isActive: Bool {
        self == .processing || self == .runningTool || self == .compacting || self == .toolFailed || self == .error
    }
}

struct AIPermissionRequest: Identifiable {
    let id: String
    let tool: String
    let toolInput: [String: AnyCodable]?
    let sessionId: String
    let cwd: String
    let pid: Int?
    let tty: String?
}

struct AISessionState: Identifiable {
    let id: String
    var phase: AISessionPhase
    var currentTool: String?
    var cwd: String?
    var pid: Int?
    var tty: String?
    var permissionRequest: AIPermissionRequest?
    var lastUpdated: Date
}

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let double = value as? Double {
            try container.encode(double)
        } else {
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
