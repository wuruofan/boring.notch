import SwiftUI
import Defaults

/// Combined Live Activity view when both AI and Music are active
/// Layout: [🤖]│[封面] 刘海 [波形]│[动画]
/// Design: AI icon and album art same size, proper spacing between elements
struct DualLiveActivity: View {
    @ObservedObject var aiManager = AIManager.shared
    @ObservedObject var musicManager = MusicManager.shared
    @EnvironmentObject var vm: BoringViewModel
    @Namespace var albumArtNamespace

    private var iconSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 16)  // Smaller than album art for visual balance
    }

    /// The session to display (highest priority)
    private var displaySession: AISessionState? {
        aiManager.highestPrioritySession
    }

    /// Badge count for multiple approvals pending
    private var approvalBadgeCount: Int {
        aiManager.approvalPendingCount
    }

    var body: some View {
        HStack(spacing: 6) {
            // Left: AI icon - use highest priority session's status
            ZStack(alignment: .topLeading) {
                if let session = displaySession {
                    SessionStatusIcon(phase: session.phase, size: iconSize)
                        .frame(width: iconSize, height: iconSize)
                } else {
                    SleepIcon(size: iconSize, color: .white.opacity(0.6))
                        .frame(width: iconSize, height: iconSize)
                }

                // Session count badge (only when multiple sessions)
                // Note: DualLiveActivity shares space with music, use smaller badge (0.35x vs 1x in AIOnly)
                if aiManager.sessions.count > 1 {
                    SessionCountBadge(count: aiManager.sessions.count, size: iconSize * 0.35)
                        .offset(x: iconSize * 0.12, y: -iconSize * 0.08)
                }
            }
            .frame(width: iconSize, height: iconSize)

            // Divider line (subtle separator)
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1, height: iconSize - 4)

            // Middle: Music content (album art + spacer + spectrum)
            // Album art (exact same frame as AI icon)
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(width: iconSize, height: iconSize)

            // Spacer (notch body)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            // Spectrum
            HStack {
                if Defaults[.useMusicVisualizer] {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: iconSize, height: iconSize, alignment: .center)

            // Divider line
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1, height: iconSize - 4)

            // Right: Status animation or approval badge
            if approvalBadgeCount > 1 {
                ApprovalBadge(count: approvalBadgeCount, size: iconSize)
                    .frame(width: iconSize, height: iconSize)
            } else if let session = displaySession {
                AIStatusAnimationView(phase: session.phase, size: iconSize)
                    .frame(width: iconSize, height: iconSize)
            } else {
                SleepIcon(size: iconSize)  // Uses purple by default
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

/// AI-only Live Activity (no music playing)
/// Layout: [🤖] Spacer [动画]
struct AIOnlyLiveActivity: View {
    @ObservedObject var aiManager = AIManager.shared
    @EnvironmentObject var vm: BoringViewModel

    private var iconSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 16)  // Smaller than album art for visual balance
    }

    /// The session to display (highest priority)
    private var displaySession: AISessionState? {
        aiManager.highestPrioritySession
    }

    /// Badge count for multiple approvals pending
    private var approvalBadgeCount: Int {
        aiManager.approvalPendingCount
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: AI icon - use highest priority session's status
            ZStack(alignment: .topLeading) {
                if let session = displaySession {
                    SessionStatusIcon(phase: session.phase, size: iconSize)
                        .frame(width: iconSize, height: iconSize)
                } else {
                    SleepIcon(size: iconSize, color: .white.opacity(0.6))
                        .frame(width: iconSize, height: iconSize)
                }

                // Session count badge (only when multiple sessions)
                if aiManager.sessions.count > 1 {
                    SessionCountBadge(count: aiManager.sessions.count, size: iconSize)
                        .offset(x: iconSize * 0.15, y: -iconSize * 0.15)
                }
            }
            .frame(width: iconSize, height: iconSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            // Right: Status animation or approval badge
            if approvalBadgeCount > 1 {
                ApprovalBadge(count: approvalBadgeCount, size: iconSize)
                    .frame(width: iconSize, height: iconSize)
            } else if let session = displaySession {
                AIStatusAnimationView(phase: session.phase, size: iconSize)
                    .frame(width: iconSize, height: iconSize)
            } else {
                SleepIcon(size: iconSize)  // Uses purple by default
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

// MARK: - Session Count Badge
struct SessionCountBadge: View {
    let count: Int
    let size: CGFloat

    init(count: Int, size: CGFloat = 14) {
        self.count = count
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.2))
                .frame(width: size * 0.6, height: size * 0.6)

            Text("\(count)")
                .font(.system(size: size * 0.35, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
