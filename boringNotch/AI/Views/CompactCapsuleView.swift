import SwiftUI

struct CompactCapsuleView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var aiManager = AIManager.shared
    @EnvironmentObject var vm: BoringViewModel

    private let musicWidth: CGFloat = 120
    private let aiWidth: CGFloat = 120
    private let aiExtra: CGFloat = 44

    var body: some View {
        Capsule()
            .fill(.black)
            .frame(width: capsuleWidth, height: vm.effectiveClosedNotchHeight)
            .overlay(
                HStack(spacing: 4) {
                    // AI Left Side
                    if aiManager.isActive {
                        AgentIconView()
                            .frame(width: iconSize, height: iconSize)
                            .transition(.opacity.combined(with: .move(edge: .leading)))

                        DividerLine()
                            .transition(.opacity)
                    }

                    // Music Core
                    if musicManager.isPlaying {
                        Image(nsImage: musicManager.albumArt)
                            .resizable()
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .frame(width: iconSize, height: iconSize)

                        Spacer()

                        // Spectrum placeholder - uses the same pattern as MusicLiveActivity
                        Rectangle()
                            .fill(.clear)
                            .frame(width: iconSize, height: iconSize)
                    } else if aiManager.isActive {
                        Spacer()
                    }

                    // AI Right Side
                    if aiManager.isActive {
                        DividerLine()
                            .transition(.opacity)

                        AIStatusAnimationView(phase: aiManager.currentPhase)
                            .frame(width: iconSize, height: iconSize)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 8)
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: capsuleWidth)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: aiManager.isActive)
    }

    private var iconSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    private var capsuleWidth: CGFloat {
        let hasMusic = musicManager.isPlaying
        let hasAI = aiManager.isActive

        if hasMusic && hasAI {
            return musicWidth + aiExtra
        } else if hasAI && !hasMusic {
            return aiWidth
        } else if hasMusic {
            return musicWidth
        }
        return vm.closedNotchSize.width
    }
}

struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 20)
    }
}
