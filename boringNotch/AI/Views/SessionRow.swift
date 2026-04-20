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
        session.phase == .idle || session.phase == .ended || session.phase == .waitingForInput || session.phase == .stopPending || session.phase == .toolFailed || session.phase == .error
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

    /// Second line display using ToolInputFormatter
    private var secondLineDisplay: (text: String, color: Color) {
        ToolInputFormatter.format(
            tool: session.currentTool ?? "",
            input: session.toolInput,  // Use session.toolInput
            phase: session.phase
        )
    }

    /// Second line text: tool name or status
    private var secondLineText: String {
        secondLineDisplay.text
    }

    /// Second line color based on status
    private var secondLineColor: Color {
        secondLineDisplay.color
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
        case .toolFailed:
            FailedIndicatorIcon(size: 16)
        case .error:
            ErrorIndicatorIcon(size: 16)
        case .idle, .ended, .stopPending:
            SleepIcon(size: 16)  // Default light purple, no opacity
        }
    }

    private var projectName: String {
        guard let cwd = session.cwd else { return "Claude Code" }
        let parts = cwd.split(separator: "/")
        let baseName = parts.last.map(String.init) ?? "Claude Code"

        if session.subagentCount > 0 {
            return "\(baseName) [\(session.subagentCount)]"
        }
        return baseName
    }
}