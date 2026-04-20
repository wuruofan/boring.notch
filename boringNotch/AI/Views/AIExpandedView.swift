import SwiftUI

struct AIExpandedView: View {
    @ObservedObject var aiManager = AIManager.shared
    @State private var replyText: String = ""
    @State private var rejectionReason: String = ""
    @State private var showRejectionSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                AgentIconView()
                    .frame(width: 24, height: 24)
                Text("Claude Code")
                    .font(.headline)
                Spacer()
                Text(phaseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Status
            if let session = aiManager.currentSession {
                statusView(session: session)
            }

            // Permission Request UI
            if let request = aiManager.currentSession?.permissionRequest {
                permissionRequestView(request: request)
            }

            // Reply Input
            replyInputView

            Spacer()
        }
        .padding()
        .frame(minHeight: 300, maxHeight: 500)
        .background(.black)
    }

    private var phaseText: String {
        switch aiManager.currentPhase {
        case .processing: return "Processing..."
        case .runningTool: return "Running tool..."
        case .waitingForInput: return "Waiting for input"
        case .waitingForApproval: return "Needs approval"
        case .compacting: return "Compacting..."
        case .idle, .ended, .stopPending: return "Idle"
        case .toolFailed: return "Tool failed"
        case .error: return "Error"
        }
    }

    @ViewBuilder
    private func statusView(session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tool = session.currentTool {
                HStack {
                    Image(systemName: "wrench")
                        .foregroundStyle(.orange)
                    Text("Tool: \(tool)")
                        .font(.subheadline)
                }
            }

            if let cwd = session.cwd {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                    Text(cwd)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRequestView(request: AIPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permission Request")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Tool: \(request.tool)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task { await aiManager.approveOnce() }
                } label: {
                    Text("Allow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    Task { await aiManager.approveAlways() }
                } label: {
                    Text("Always Allow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showRejectionSheet = true
                } label: {
                    Text("Deny")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
        .sheet(isPresented: $showRejectionSheet) {
            VStack(spacing: 16) {
                Text("Deny Permission")
                    .font(.headline)

                TextField("Reason (optional)", text: $rejectionReason)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Cancel") {
                        showRejectionSheet = false
                        rejectionReason = ""
                    }

                    Button("Deny", role: .destructive) {
                        Task {
                            await aiManager.reject(reason: rejectionReason.isEmpty ? nil : rejectionReason)
                        }
                        showRejectionSheet = false
                        rejectionReason = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    @ViewBuilder
    private var replyInputView: some View {
        HStack {
            TextField("Send a message...", text: $replyText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    sendReply()
                }

            Button {
                sendReply()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(replyText.isEmpty)
        }
    }

    private func sendReply() {
        guard !replyText.isEmpty else { return }
        Task {
            await aiManager.sendReply(replyText)
            replyText = ""
        }
    }
}
