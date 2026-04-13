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
                    Text("Server status")
                    Spacer()
                    Circle()
                        .fill(aiManager.isConnected ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(aiManager.isConnected ? "Running" : "Stopped")
                        .font(.caption)
                }
            } header: {
                Text("Diagnostics")
            }
        }
        .navigationTitle("AI Agents")
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
