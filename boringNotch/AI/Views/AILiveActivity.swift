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
            // Left: AI icon (always crab, representing AI agent)
            // Badge positioned inside crab icon (bottom-left area)
            ZStack(alignment: .bottomLeading) {
                // Crab icon: running if active, static if waiting/sleeping
                if let session = displaySession {
                    if session.phase.isActive {
                        AgentIconView(size: iconSize, animateLegs: true)
                    } else if session.phase == .waitingForApproval {
                        AgentIconView(size: iconSize, animateLegs: false)  // Static crab while waiting for approval
                    } else {
                        SleepingCrabIcon(size: iconSize)
                    }
                } else {
                    SleepingCrabIcon(size: iconSize)
                }

                // Session count badge (pixel-style, mostly inside crab icon)
                // Left edge slightly outside (2 pixels), bottom edge slightly outside
                if aiManager.sessions.count > 1 {
                    SessionCountBadge(count: aiManager.sessions.count, badgeSize: iconSize * 0.4)
                        .offset(x: -iconSize * 0.08, y: iconSize * 0.1)  // Left and bottom slightly outside
                }
            }

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
                SleepingCrabIcon(size: iconSize, crabColor: claudeOrange)
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
            // Left: AI icon (always crab, representing AI agent)
            // Badge positioned inside crab icon (bottom-left area)
            ZStack(alignment: .bottomLeading) {
                // Crab icon: running if active, static if waiting/sleeping
                if let session = displaySession {
                    if session.phase.isActive {
                        AgentIconView(size: iconSize, animateLegs: true)
                    } else if session.phase == .waitingForApproval {
                        AgentIconView(size: iconSize, animateLegs: false)  // Static crab while waiting for approval
                    } else {
                        SleepingCrabIcon(size: iconSize)
                    }
                } else {
                    SleepingCrabIcon(size: iconSize)
                }

                // Session count badge (pixel-style, mostly inside crab icon)
                // Left edge slightly outside (2 pixels), bottom edge slightly outside
                if aiManager.sessions.count > 1 {
                    SessionCountBadge(count: aiManager.sessions.count, badgeSize: iconSize * 0.4)
                        .offset(x: -iconSize * 0.08, y: iconSize * 0.1)  // Left and bottom slightly outside
                }
            }

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
                SleepingCrabIcon(size: iconSize, crabColor: claudeOrange)
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

// MARK: - Session Count Badge (Pixel-style number, no background)
struct SessionCountBadge: View {
    let count: Int
    let badgeSize: CGFloat  // Size of the digit display

    var body: some View {
        // Pixel-style number, no background circle
        PixelDigitView(digit: count, size: badgeSize, color: .white)
    }
}

// MARK: - Pixel Digit View
struct PixelDigitView: View {
    let digit: Int
    let size: CGFloat
    let color: Color

    // Pixel patterns for digits 0-9 (5x7 grid)
    private let digitPatterns: [Int: [[Bool]]] = [
        0: [
            [true, true, true, true, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
        ],
        1: [
            [false, false, true, false, false],
            [false, true, true, false, false],
            [false, false, true, false, false],
            [false, false, true, false, false],
            [false, false, true, false, false],
            [false, false, true, false, false],
            [false, true, true, true, false],
        ],
        2: [
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [true, true, true, true, true],
            [true, false, false, false, false],
            [true, false, false, false, false],
            [true, true, true, true, true],
        ],
        3: [
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [true, true, true, true, true],
        ],
        4: [
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
        ],
        5: [
            [true, true, true, true, true],
            [true, false, false, false, false],
            [true, false, false, false, false],
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [true, true, true, true, true],
        ],
        6: [
            [true, true, true, true, true],
            [true, false, false, false, false],
            [true, false, false, false, false],
            [true, true, true, true, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
        ],
        7: [
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [false, false, false, true, false],
            [false, false, false, true, false],
            [false, false, true, false, false],
            [false, false, true, false, false],
        ],
        8: [
            [true, true, true, true, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
        ],
        9: [
            [true, true, true, true, true],
            [true, false, false, false, true],
            [true, false, false, false, true],
            [true, true, true, true, true],
            [false, false, false, false, true],
            [false, false, false, false, true],
            [true, true, true, true, true],
        ]
    ]

    var body: some View {
        Canvas { context, canvasSize in
            guard let pattern = digitPatterns[digit % 10] else { return }

            let pixelWidth: CGFloat = 5
            let pixelHeight: CGFloat = 7
            let overlap: CGFloat = 0.15  // Small overlap for tight connection
            let pixelSize = min(canvasSize.width / pixelWidth, canvasSize.height / pixelHeight) + overlap

            for (y, row) in pattern.enumerated() {
                for (x, isOn) in row.enumerated() {
                    if isOn {
                        let rect = CGRect(
                            x: CGFloat(x) * (pixelSize - overlap),
                            y: CGFloat(y) * (pixelSize - overlap),
                            width: pixelSize,
                            height: pixelSize
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}
