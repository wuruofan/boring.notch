import SwiftUI

/// Compact approval buttons for session row.
struct ApprovalButtons: View {
    let sessionId: String
    let requestId: String
    @ObservedObject var aiManager = AIManager.shared
    @State private var showButtons = false

    var body: some View {
        HStack(spacing: 6) {
            // Allow button
            Button {
                Task {
                    await approve()
                }
            } label: {
                Text("Allow")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButtons ? 1 : 0)
            .scaleEffect(showButtons ? 1 : 0.8)

            // Deny button
            Button {
                Task {
                    await deny()
                }
            } label: {
                Text("Deny")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.6))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButtons ? 1 : 0)
            .scaleEffect(showButtons ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7).delay(0.05)) {
                showButtons = true
            }
        }
    }

    private func approve() async {
        _ = await AIXPCClient.shared.respondToPermission(
            toolUseId: requestId,
            decision: "allow"
        )

        // Also try tmux if available
        if let session = aiManager.sessions[sessionId],
           let pid = session.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.approveOnce(target: target)
        }
    }

    private func deny() async {
        _ = await AIXPCClient.shared.respondToPermission(
            toolUseId: requestId,
            decision: "deny"
        )

        if let session = aiManager.sessions[sessionId],
           let pid = session.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forPID: pid) {
            _ = await ToolApprovalHandler.shared.reject(target: target)
        }
    }
}