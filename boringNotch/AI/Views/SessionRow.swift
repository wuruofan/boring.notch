import SwiftUI
import AppKit
import Defaults

/// Single session row display.
struct SessionRow: View {
    let session: AISessionState
    @State private var isHovered = false
    @State private var isClicked = false
    @Default(.aiSleepAnimationEnabled) private var sleepAnimationEnabled

    private var isWaitingForApproval: Bool {
        session.phase == .waitingForApproval
    }

    var body: some View {
        Button(action: {
            isClicked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isClicked = false
            }
            Task {
                await jumpToSession()
            }
        }) {
            HStack(alignment: .center, spacing: 10) {
                statusIndicator
                    .frame(width: 16, height: 16)

                    let sessionId = session.id.prefix(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("\(sessionId) | \(secondLineText)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(secondLineColor)
                        .lineLimit(1)
                }
                .frame(height: 34, alignment: .leading)

                Spacer(minLength: 0)

                if isWaitingForApproval, let request = session.permissionRequest {
                    ApprovalButtons(sessionId: session.id, requestId: request.id)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isClicked ? Color.white.opacity(0.3) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(BorderlessButtonStyle())
        .onHover { isHovered = $0 }
    }

    // MARK: - Jump to Session

    private func jumpToSession() async {
        guard let cwd = session.cwd else { return }

        // Check if current terminal is inside tmux (switch-client only works then)
        let clientResult = await AIXPCClient.shared.runTmuxCommand(
            command: "tmux display-message -p '#{client_session}' 2>/dev/null || echo 'NO_TMUX'"
        )

        let hasActiveTmuxClient = clientResult.success && !clientResult.output.contains("NO_TMUX")

        if hasActiveTmuxClient {
            // Find target by CWD and switch
            let listResult = await AIXPCClient.shared.runTmuxCommand(
                command: "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}'"
            )

            for line in listResult.output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let target = String(parts[0])
                let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if path == cwd || cwd.hasPrefix(path + "/") {
                    _ = await AIXPCClient.shared.runTmuxCommand(
                        command: "tmux switch-client -t \(target)"
                    )
                    break
                }
            }
        }

        // Always activate terminal app
        await activateTerminalApp()
    }

    // MARK: - Terminal Activation

    private func activateTerminalApp() async {
        let runningApps = NSWorkspace.shared.runningApplications

        // Terminal priority (most popular first)
        let terminalPriority: [(bundleId: String, appName: String)] = [
            ("com.mitchellh.ghostty", "Ghostty"),
            ("com.googlecode.iterm2", "iTerm2"),
            ("net.kovidgoyal.kitty", "kitty"),
            ("org.alacritty", "Alacritty"),
            ("dev.warp.Warp-Stable", "Warp"),
            ("org.wezfurlong.wezterm", "WezTerm"),
            ("com.hyper.Hyper", "Hyper"),
            ("com.apple.Terminal", "Terminal"),
        ]

        for terminal in terminalPriority {
            if runningApps.contains(where: { $0.bundleIdentifier == terminal.bundleId }) {
                _ = await AIXPCClient.shared.runShellCommand(command: "open -a '\(terminal.appName)'")
                return
            }
        }

        // Fallback: open Terminal.app with cwd
        if let cwd = session.cwd {
            _ = await AIXPCClient.shared.runShellCommand(command: "open -a Terminal '\(cwd)'")
        }
    }

    // MARK: - Display Helpers

    private var secondLineDisplay: (text: String, color: Color) {
        ToolInputFormatter.format(
            tool: session.currentTool ?? "",
            input: session.toolInput,
            phase: session.phase
        )
    }

    private var secondLineText: String {
        secondLineDisplay.text
    }

    private var secondLineColor: Color {
        secondLineDisplay.color
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
        case .waitingForApproval:
            PermissionIndicatorIcon(size: 16, color: claudeOrange)
        case .waitingForInput:
            ReadyForInputIndicatorIcon(size: 16, color: .green)
        case .toolFailed:
            FailedIndicatorIcon(size: 16)
        case .error:
            ErrorIndicatorIcon(size: 16)
        case .idle, .ended, .stopPending:
            SleepIcon(size: 16, enableAnimation: sleepAnimationEnabled)
        }
    }

    private var projectName: String {
        guard let cwd = session.cwd else { return "Claude Code" }
        let baseName = cwd.split(separator: "/").last.map(String.init) ?? "Claude Code"
        return session.subagentCount > 0 ? "\(baseName) [\(session.subagentCount)]" : baseName
    }
}