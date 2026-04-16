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

    /// Whether AI is currently processing/running (should animate legs)
    private var isAIProcessing: Bool {
        aiManager.currentPhase == .processing || aiManager.currentPhase == .runningTool || aiManager.currentPhase == .compacting
    }

    /// Whether AI just completed (waiting for input = done)
    private var isAICompleted: Bool {
        aiManager.currentPhase == .waitingForInput
    }

    var body: some View {
        HStack(spacing: 6) {
            // Left: AI icon (same size as album art)
            AgentIconView(size: iconSize, animateLegs: isAIProcessing)
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

            // Right: AI status - checkmark for completed, spinner for processing
            if isAICompleted {
                // Green checkmark for completed state
                ReadyForInputIndicatorIcon(size: iconSize, color: .green)
                    .frame(width: iconSize, height: iconSize)
            } else {
                AIStatusAnimationView(phase: aiManager.currentPhase)
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

/// AI-only Live Activity (no music playing)
/// Layout: [🤖] Spacer [动画/对勾]
struct AIOnlyLiveActivity: View {
    @ObservedObject var aiManager = AIManager.shared
    @EnvironmentObject var vm: BoringViewModel

    private var iconSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 16)  // Smaller than album art for visual balance
    }

    private var isAIProcessing: Bool {
        aiManager.currentPhase == .processing || aiManager.currentPhase == .runningTool || aiManager.currentPhase == .compacting
    }

    private var isAICompleted: Bool {
        aiManager.currentPhase == .waitingForInput
    }

    var body: some View {
        HStack(spacing: 0) {
            AgentIconView(size: iconSize, animateLegs: isAIProcessing)
                .frame(width: iconSize, height: iconSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width)

            if isAICompleted {
                ReadyForInputIndicatorIcon(size: iconSize, color: .green)
                    .frame(width: iconSize, height: iconSize)
            } else {
                AIStatusAnimationView(phase: aiManager.currentPhase)
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}
