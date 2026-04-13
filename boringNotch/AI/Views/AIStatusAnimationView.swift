import SwiftUI

struct AIStatusAnimationView: View {
    let phase: AISessionPhase
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            switch phase {
            case .processing, .runningTool:
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .scaleEffect(isAnimating ? 1.0 : 0.5)
                            .animation(
                                .easeInOut(duration: 0.4)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                value: isAnimating
                            )
                    }
                }
                .onAppear { isAnimating = true }

            case .waitingForApproval:
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.orange)
                    .padding(4)
                    .opacity(isAnimating ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(), value: isAnimating)
                    .onAppear { isAnimating = true }

            case .waitingForInput:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.green)
                    .padding(4)

            case .compacting:
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)

            case .idle, .ended:
                Rectangle()
                    .fill(.clear)
            }
        }
    }
}
