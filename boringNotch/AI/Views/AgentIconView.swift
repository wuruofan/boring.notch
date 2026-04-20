import SwiftUI

// Claude orange color
let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

// MARK: - Claude Crab Icon (Pixel Art)
struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0
    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16, color: Color = claudeOrange, animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            // Use canvas size directly for proper scaling
            let scale = min(canvasSize.width, canvasSize.height) / 52.0
            let actualWidth = 66 * scale
            let xOffset = (canvasSize.width - actualWidth) / 2

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            // Animated legs - alternating up/down pattern for walking effect
            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13

            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],   // Phase 0: alternating
                [0, 0, 0, 0],     // Phase 1: neutral
                [-3, 3, -3, 3],   // Phase 2: alternating (opposite)
                [0, 0, 0, 0],     // Phase 3: neutral
            ]

            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            // Main body
            let body = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            // Left eye
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            // Right eye
            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size, height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
}

// MARK: - Processing Spinner
struct ProcessingSpinner: View {
    @State private var phase: Int = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color = claudeOrange

    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .frame(width: 12, alignment: .center)
            .onReceive(timer) { _ in
                phase = (phase + 1) % symbols.count
            }
    }
}

// MARK: - Permission Indicator Icon (Pixel Art)
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = claudeOrange) {
        self.size = size
        self.color = color
    }

    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Ready for Input Indicator Icon (Checkmark)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .green) {
        self.size = size
        self.color = color
    }

    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sleep/Idle Icon (zZZ animation)
struct SleepIcon: View {
    let size: CGFloat
    let color: Color

    @State private var zOffset: CGFloat = 0
    @State private var opacity: Double = 0.4

    // Default to white.opacity(0.6) for better visibility on dark background
    init(size: CGFloat = 14, color: Color = .white.opacity(0.6)) {
        self.size = size
        self.color = color
    }

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0

            // Draw "z" letters floating up
            let zPositions: [(CGFloat, CGFloat, CGFloat)] = [
                (8, 20, 0.8),   // Bottom z - larger
                (14, 12, 0.6),  // Middle z - medium
                (20, 6, 0.4),   // Top z - smallest
            ]

            for (x, y, alpha) in zPositions {
                // Simple pixel-art "z" shape
                let dots: [(CGFloat, CGFloat)] = [
                    (x - 3, y), (x, y), (x + 3, y),       // Top bar
                    (x, y - 3),                            // Diagonal
                    (x - 3, y - 6), (x, y - 6), (x + 3, y - 6), // Bottom bar
                ]

                for (dx, dy) in dots {
                    let rect = CGRect(
                        x: dx * scale - 1.5 * scale,
                        y: dy * scale - 1.5 * scale,
                        width: 3 * scale,
                        height: 3 * scale
                    )
                    context.fill(Path(rect), with: .color(color.opacity(alpha * opacity)))
                }
            }
        }
        .frame(width: size, height: size)
        .offset(y: zOffset)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                zOffset = -2
                opacity = 0.7
            }
        }
    }
}

// MARK: - Tool Failed Indicator Icon (Red Exclamation Mark)
struct FailedIndicatorIcon: View {
    let size: CGFloat

    init(size: CGFloat = 14) {
        self.size = size
    }

    private let pixels: [(CGFloat, CGFloat)] = [
        (13, 3),   // Top dot
        (13, 7), (13, 11), (13, 15),  // Vertical bar
        (9, 19), (13, 19), (17, 19),   // Bottom dot row
        (13, 23)   // Bottom dot
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(.red))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Error Indicator Icon (Red X Symbol)
struct ErrorIndicatorIcon: View {
    let size: CGFloat

    init(size: CGFloat = 14) {
        self.size = size
    }

    private let pixels: [(CGFloat, CGFloat)] = [
        // X shape - diagonal lines
        (7, 7), (11, 11),  // Top-left diagonal
        (15, 15), (19, 19), (23, 23),  // Center diagonal
        (23, 7), (19, 11),  // Top-right diagonal
        (7, 23), (11, 19)   // Bottom-left diagonal
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(.red))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Agent Icon View
struct AgentIconView: View {
    let size: CGFloat
    var animateLegs: Bool = false

    init(size: CGFloat = 16, animateLegs: Bool = false) {
        self.size = size
        self.animateLegs = animateLegs
    }

    var body: some View {
        ClaudeCrabIcon(size: size, animateLegs: animateLegs)
    }
}

// MARK: - Approval Badge (for multiple pending approvals)
struct ApprovalBadge: View {
    let count: Int
    let size: CGFloat

    init(count: Int, size: CGFloat = 14) {
        self.count = count
        self.size = size
    }

    var body: some View {
        ZStack {
            PermissionIndicatorIcon(size: size, color: claudeOrange)

            // Count overlay
            Text("\(count)")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(.white)
                .offset(x: size * 0.2, y: -size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sleeping Crab Icon (crab with zZ on head)
struct SleepingCrabIcon: View {
    let size: CGFloat
    let crabColor: Color
    let sleepColor: Color
    var animateLegs: Bool = false

    @State private var zOffset: CGFloat = 0

    // Brighter purple zZ color for better visibility on dark background
    private let purpleColor = Color(red: 0.75, green: 0.55, blue: 0.95).opacity(0.9)

    init(size: CGFloat = 16, crabColor: Color = claudeOrange, sleepColor: Color? = nil, animateLegs: Bool = false) {
        self.size = size
        self.crabColor = crabColor
        self.sleepColor = sleepColor ?? purpleColor
        self.animateLegs = animateLegs
    }

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main crab icon
            ClaudeCrabIcon(size: size, color: crabColor, animateLegs: animateLegs)

            // zZ floating above crab's head (top-right corner)
            SleepIcon(size: size * 0.5, color: sleepColor)
                .offset(x: size * 0.3, y: -size * 0.15)
                .opacity(0.9)
        }
        .frame(width: size, height: size)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                zOffset = -2
            }
        }
    }
}

// MARK: - Session Status Icon (unified icon for session phase)
struct SessionStatusIcon: View {
    let phase: AISessionPhase
    let size: CGFloat

    init(phase: AISessionPhase, size: CGFloat = 16) {
        self.phase = phase
        self.size = size
    }

    var body: some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            AgentIconView(size: size, animateLegs: true)  // Running crab
        case .waitingForApproval:
            PermissionIndicatorIcon(size: size, color: claudeOrange)
        case .waitingForInput:
            AgentIconView(size: size, animateLegs: false)  // Static crab (ready for input)
        case .toolFailed:
            FailedIndicatorIcon(size: size)
        case .error:
            ErrorIndicatorIcon(size: size)
        case .idle, .ended, .stopPending:
            SleepingCrabIcon(size: size, crabColor: claudeOrange.opacity(0.7), sleepColor: .white.opacity(0.6))  // Crab + white zZ
        }
    }
}
