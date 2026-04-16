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
        case .processing, .runningTool:
            ProcessingSpinner()
                .frame(width: size, height: size)

        case .waitingForApproval:
            PermissionIndicatorIcon(size: size, color: claudeOrange)

        case .waitingForInput:
            // waitingForInput means session ready for new prompt (not needing user action)
            // Show sleep animation like idle state
            SleepIcon(size: size, color: .white.opacity(0.5))

        case .compacting:
            ProcessingSpinner()
                .frame(width: size, height: size)

        case .idle, .ended:
            SleepIcon(size: size, color: .white.opacity(0.5))
        }
    }
}
