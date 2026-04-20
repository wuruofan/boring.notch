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

        case .toolFailed:
            FailedIndicatorIcon(size: size)

        case .error:
            ErrorIndicatorIcon(size: size)

        case .idle, .ended, .stopPending:
            // ESC interrupt or sleep - show white zZ
            SleepIcon(size: size, color: .white.opacity(0.4))
        }
    }
}
