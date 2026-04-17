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
        session.phase == .idle || session.phase == .ended || session.phase == .waitingForInput || session.phase == .stopPending
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Status indicator
            statusIndicator
                .frame(width: 16, height: 16)

            // Project and tool info - fixed two lines
            VStack(alignment: .leading, spacing: 2) {
                // Line 1: Project name
                Text(projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // Line 2: Tool name or status text
                Text(secondLineText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(secondLineColor)
                    .lineLimit(1)
            }
            .frame(height: 34, alignment: .leading)  // Fixed height for two lines

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

    /// Second line text: tool name or status
    private var secondLineText: String {
        if let tool = session.currentTool {
            return formatToolName(tool)
        }
        // No tool: show status text
        switch session.phase {
        case .processing:
            return "Processing..."
        case .runningTool:
            return "Running tool..."
        case .compacting:
            return "Compacting..."
        case .waitingForApproval:
            return "Needs approval"
        case .waitingForInput:
            return "Ready for input"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        case .stopPending:
            return "Stopping..."
        }
    }

    /// Second line color based on status
    private var secondLineColor: Color {
        if session.currentTool != nil {
            return isWaitingForApproval ? claudeOrange.opacity(0.9) : .white.opacity(0.5)
        }
        // Status text colors
        switch session.phase {
        case .waitingForApproval:
            return claudeOrange.opacity(0.9)
        case .waitingForInput:
            return .green.opacity(0.7)
        case .idle, .ended:
            return .white.opacity(0.4)
        default:
            return .white.opacity(0.5)
        }
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
        case .idle, .ended, .stopPending:
            SleepIcon(size: 16)  // Uses purple by default
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