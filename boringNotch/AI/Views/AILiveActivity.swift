import SwiftUI

struct AILiveActivity: View {
    @ObservedObject var aiManager = AIManager.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(spacing: 0) {
            AgentIconView()
                .frame(width: iconSize, height: iconSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            AIStatusAnimationView(phase: aiManager.currentPhase)
                .frame(width: iconSize, height: iconSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }

    private var iconSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }
}
