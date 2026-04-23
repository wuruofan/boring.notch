import SwiftUI

/// Session list container with scroll support.
/// Height adapts to session count (capped at 5).
struct SessionList: View {
    @ObservedObject var aiManager = AIManager.shared

    /// Calculate visible height based on session count (capped at 5)
    /// SessionRow: 50px, spacing: 6px, padding: 16px (8px each side)
    private var visibleHeight: CGFloat {
        let sessionCount = aiManager.sortedSessions.count
        let effectiveCount = min(sessionCount, 5)
        let rowHeight: CGFloat = 50
        let spacing: CGFloat = 6
        let padding: CGFloat = 16

        return CGFloat(effectiveCount) * rowHeight
            + CGFloat(max(0, effectiveCount - 1)) * spacing
            + padding
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(aiManager.sortedSessions, id: \.id) { session in
                    SessionRow(session: session)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                }
            }
            .padding(8)
        }
        .frame(height: visibleHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: aiManager.sortedSessions.count)
        .contentMargins(0, for: .scrollContent)
    }
}