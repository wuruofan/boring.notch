import SwiftUI

struct AIStatusAnimationView: View {
    let phase: AISessionPhase

    var body: some View {
        switch phase {
        case .processing, .runningTool:
            ProcessingSpinner()
                .frame(width: 12, height: 12)

        case .waitingForApproval:
            PermissionIndicatorIcon(size: 14, color: claudeOrange)

        case .waitingForInput:
            ReadyForInputIndicatorIcon(size: 14, color: .green)

        case .compacting:
            ProcessingSpinner()
                .frame(width: 12, height: 12)

        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }
}
