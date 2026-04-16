import SwiftUI

/// Session list container with scroll support.
/// Reference: Claude-Island ClaudeInstancesView
struct SessionList: View {
    @ObservedObject var aiManager = AIManager.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(aiManager.sortedSessions, id: \.id) { session in
                    SessionRow(session: session)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 200)  // Fixed visible area height
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: aiManager.sortedSessions.count)
    }
}