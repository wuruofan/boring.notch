import SwiftUI

struct AIStatusAnimationView: View {
    let phase: AISessionPhase
    let size: CGFloat

    init(phase: AISessionPhase, size: CGFloat = 14) {
        self.phase = phase
        self.size = size
    }

    var body: some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
                .frame(width: size, height: size)

        case .waitingForApproval:
            PermissionIndicatorIcon(size: size, color: claudeOrange)

        case .waitingForInput:
            // Task completed, ready for new input - show green checkmark
            ReadyForInputIndicatorIcon(size: size, color: .green)

        case .idle, .ended, .stopPending:
            // ESC interrupt or sleep - show purple zZ
            SleepIcon(size: size)  // Uses purple by default now

        case .toolFailed, .error:
            // Tool execution failed or API error - show red warning icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.8))
                .foregroundColor(.red)
        }
    }
}
