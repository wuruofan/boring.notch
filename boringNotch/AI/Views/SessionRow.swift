import SwiftUI

/// Single session row display.
/// Reference: Claude-Island InstanceRow
struct SessionRow: View {
    let session: AISessionState
    @State private var isHovered = false

    private var isProcessing: Bool {
        session.phase.isActive
    }

    private var isWaitingForApproval: Bool {
        session.phase == .waitingForApproval
    }

    private var isIdle: Bool {
        session.phase == .idle || session.phase == .ended || session.phase == .waitingForInput
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Status indicator
            statusIndicator
                .frame(width: 16, height: 16)

            // Project and tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let tool = session.currentTool {
                    Text(formatToolName(tool))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isWaitingForApproval ? claudeOrange.opacity(0.9) : .white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Approval buttons
            if isWaitingForApproval, let request = session.permissionRequest {
                ApprovalButtons(
                    sessionId: session.id,
                    requestId: request.id
                )
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
        case .waitingForApproval:
            PermissionIndicatorIcon(size: 16, color: claudeOrange)
        case .waitingForInput:
            ReadyForInputIndicatorIcon(size: 16, color: .green)
        case .idle, .ended:
            SleepIcon(size: 16, color: .white.opacity(0.5))
        }
    }

    private var projectName: String {
        guard let cwd = session.cwd else { return "Claude Code" }
        let parts = cwd.split(separator: "/")
        return parts.last.map(String.init) ?? "Claude Code"
    }

    private func formatToolName(_ tool: String) -> String {
        // MCP tool: "mcp__server__tool" -> "server: tool"
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).split(separator: "__")
            if parts.count >= 2 {
                return "\(parts[0]): \(parts[1])"
            }
        }
        return tool
    }
}