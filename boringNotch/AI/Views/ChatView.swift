import SwiftUI
import Defaults

struct ChatView: View {
    let sessionId: String
    @ObservedObject var aiManager = AIManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @State private var inputText: String = ""
    @Default(.aiSleepAnimationEnabled) private var sleepAnimationEnabled

    private var session: AISessionState? {
        aiManager.sessions[sessionId]
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            messageArea
            bottomBar
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            coordinator.closeChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHeaderHovered ? .white : .white.opacity(0.6))
                    .frame(width: 24, height: 24)

                Text(projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHeaderHovered ? .white : .white.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                // Status indicator
                if let session = session {
                    statusIndicator(for: session.phase)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.vertical, 8)
    }

    // MARK: - Message Area (Placeholder)

    private var messageArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let session = session {
                    // Current status card
                    statusCard(session)

                    // Placeholder message
                    placeholderMessageView
                } else {
                    Text("Session not found")
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func statusCard(_ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Phase
            HStack(spacing: 6) {
                Circle()
                    .fill(phaseColor(session.phase))
                    .frame(width: 8, height: 8)
                Text(session.phase.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(phaseColor(session.phase))
            }

            // Current tool
            if let tool = session.currentTool {
                HStack(spacing: 6) {
                    Image(systemName: "wrench")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(tool)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            // CWD
            if let cwd = session.cwd {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text(cwd)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var placeholderMessageView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message History")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Loading messages from JSONL will be implemented in Phase 2. For now, this shows current session status.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            TextField(canSendMessage ? "Message Claude..." : "Open in tmux to send messages", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessage ? .white : .white.opacity(0.4))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessage ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .disabled(!canSendMessage)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessage || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessage || inputText.isEmpty)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Helpers

    private var projectName: String {
        guard let cwd = session?.cwd else { return "Claude Code" }
        return cwd.split(separator: "/").last.map(String.init) ?? "Claude Code"
    }

    private var canSendMessage: Bool {
        session?.tty != nil
    }

    @ViewBuilder
    private func statusIndicator(for phase: AISessionPhase) -> some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
        case .waitingForApproval:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .waitingForInput:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .toolFailed, .error:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        default:
            SleepIcon(size: 16, enableAnimation: sleepAnimationEnabled)
        }
    }

    private func phaseColor(_ phase: AISessionPhase) -> Color {
        switch phase {
        case .processing, .runningTool: return .orange
        case .waitingForApproval: return .orange
        case .waitingForInput: return .green
        case .toolFailed, .error: return .red
        default: return .gray
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSendMessage else { return }

        inputText = ""
        Task {
            await aiManager.sendReply(text)
        }
    }
}