import Defaults
import SwiftUI

struct AISettingsView: View {
    @Default(.aiEnabled) var aiEnabled
    @Default(.aiShowInNotch) var aiShowInNotch
    @Default(.aiAutoInstallHooks) var aiAutoInstallHooks
    @Default(.aiScreenMode) var aiScreenMode
    @Default(.aiPreferredScreenUUID) var aiPreferredScreenUUID
    @ObservedObject var aiManager = AIManager.shared

    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }

    @State private var hookInstalled = AIHookInstaller.isInstalled()
    @State private var showUninstallWarning = false

    // Diagnostic states
    @State private var socketExists = false
    @State private var activeSessionsCount = 0
    @State private var lastHealthCheck: Date? = nil
    @State private var showingDiagnostics = false
    @State private var xpcCallbackTestResult: String? = nil

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .aiEnabled) {
                    Text("Enable AI integration")
                }
                Defaults.Toggle(key: .aiShowInNotch) {
                    Text("Show AI status in notch")
                }
                .disabled(!aiEnabled)
                Defaults.Toggle(key: .aiAutoInstallHooks) {
                    Text("Auto-install hooks on launch")
                }
                .disabled(!aiEnabled)
                Defaults.Toggle(key: .aiSleepAnimationEnabled) {
                    Text("Sleep icon animation")
                }
                .disabled(!aiEnabled)
            } header: {
                Text("General")
            }

            Section {
                Picker("AI display location", selection: $aiScreenMode) {
                    Text("Follow Notch").tag(AIScreenMode.followNotch)
                    Text("Separate display").tag(AIScreenMode.separate)
                }
                .disabled(!aiEnabled)

                if aiScreenMode == .separate {
                    Picker("Preferred display", selection: $aiPreferredScreenUUID) {
                        Text("Auto").tag(nil as String?)
                        ForEach(screens, id: \.uuid) { screen in
                            Text(screen.name).tag(screen.uuid as String?)
                        }
                    }
                }
            } header: {
                Text("Display")
            }

            Section {
                HStack {
                    Text("Hook status")
                    Spacer()
                    Text(hookInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(hookInstalled ? .green : .orange)
                }

                HStack {
                    Button("Reinstall") {
                        AIHookInstaller.installIfNeeded()
                        hookInstalled = AIHookInstaller.isInstalled()
                        showFeedback(success: hookInstalled, message: "Hooks reinstall")
                    }

                    Button("Uninstall") {
                        if aiManager.isActive {
                            showUninstallWarning = true
                        } else {
                            performUninstall()
                        }
                    }
                }
                .alert("Claude Code is active", isPresented: $showUninstallWarning) {
                    Button("Cancel", role: .cancel) {}
                    Button("Uninstall anyway", role: .destructive) {
                        performUninstall()
                    }
                } message: {
                    Text("Uninstalling hooks while Claude Code is running will cause hook errors. Restart Claude Code after uninstalling.")
                }
            } header: {
                Text("Hooks")
            }

            Section {
                HStack {
                    Text("Socket path")
                    Spacer()
                    Text("/tmp/boringnotch-ai.sock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Socket file")
                    Spacer()
                    Image(systemName: socketExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(socketExists ? .green : .red)
                        .font(.caption)
                    Text(socketExists ? "Exists" : "Missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("XPC Service")
                    Spacer()
                    Circle()
                        .fill(aiManager.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(aiManager.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                }

                if !aiManager.sessions.isEmpty {
                    HStack {
                        Text("Active sessions")
                        Spacer()
                        Text("\(aiManager.sessions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(aiManager.sessions.values), id: \.id) { session in
                        HStack {
                            Text(session.id.prefix(8))
                                .font(.caption)
                                .monospaced()
                            Spacer()
                            Text(session.phase.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let lastCheck = lastHealthCheck {
                    HStack {
                        Text("Last health check")
                        Spacer()
                        Text(lastCheck, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Refresh Status") {
                        refreshDiagnostics()
                    }
                    .buttonStyle(.bordered)

                    Button("Test XPC Callback") {
                        xpcCallbackTestResult = "⏳ Testing..."
                        Task {
                            // Create listener if not exists
                            let listener = AIXPCListener()
                            listener.onPingReceived = {
                                print("✅ XPC CALLBACK SUCCESS! ping() received!")
                                Task { @MainActor in
                                    xpcCallbackTestResult = "✅ SUCCESS - XPC callback works!"
                                }
                            }
                            AIXPCClient.shared.setListener(listener)

                            // Start server (listener is exported automatically)
                            _ = await AIXPCClient.shared.startServer()

                            // Test ping - XPC Helper will call listener.ping()
                            _ = await AIXPCClient.shared.testPing()

                            // Wait 3 seconds for callback, if not received, mark as failed
                            try? await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                if xpcCallbackTestResult == "⏳ Testing..." {
                                    xpcCallbackTestResult = "❌ FAILED - No response after 3s"
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let result = xpcCallbackTestResult {
                    HStack {
                        Spacer()
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("SUCCESS") ? .green : result.contains("Testing") ? .secondary : .red)
                        Spacer()
                    }
                }

                if !aiManager.isConnected {
                    Button("Restart XPC Service") {
                        Task {
                            _ = await AIXPCClient.shared.stopServer()
                            try? await Task.sleep(for: .milliseconds(500))
                            _ = await AIXPCClient.shared.startServer()
                            refreshDiagnostics()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Socket file and XPC service status are checked automatically every 30 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI Agents")
        .onAppear {
            refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AIWaitingForApprovalChanged)) { _ in
            // Refresh when AI state changes
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        socketExists = FileManager.default.fileExists(atPath: "/tmp/boringnotch-ai.sock")
        activeSessionsCount = aiManager.sessions.count
        lastHealthCheck = Date()
    }

    private func performUninstall() {
        AIHookInstaller.uninstall()
        hookInstalled = AIHookInstaller.isInstalled()
        showFeedback(success: !hookInstalled, message: "Hooks uninstall")
    }

    /// Show peek feedback using .settings type.
    /// Always renders via InlineHUD/SystemEventIndicator, never conflicts with AI status.
    private func showFeedback(success: Bool, message: String = "Hooks") {
        let coordinator = BoringViewCoordinator.shared
        coordinator.toggleSneakPeek(
            status: true,
            type: .settings,
            duration: 2.0,
            icon: success ? "checkmark.circle" : "xmark.circle",
            message: message,
            persistent: false
        )
    }
}
