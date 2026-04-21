import SwiftUI

/// Session list container with scroll support.
/// Height adapts to session count (capped at 4):
/// - 1 session: ~55px
/// - 2 sessions: ~118px
/// - 3 sessions: ~181px
/// - 4 sessions: ~244px (max, scroll for more)
struct SessionList: View {
    @ObservedObject var aiManager = AIManager.shared

    /// Calculate visible height based on session count (capped at 4)
    /// Includes: SessionRow height (50px) + VStack spacing (6px per additional) + ScrollView padding (8px)
    private var visibleHeight: CGFloat {
        let sessionCount = aiManager.sortedSessions.count
        let effectiveCount = min(sessionCount, 4)
        // First session: 50px, each additional: 56px, plus ScrollView padding: 8px
        return 50 + CGFloat(max(0, effectiveCount - 1)) * 56 + 8
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
            .padding(.vertical, 4)
        }
        .frame(maxHeight: visibleHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: aiManager.sortedSessions.count)
        // Remove default content margins to prevent extra scroll space
        .contentMargins(0, for: .scrollContent)
    }
}