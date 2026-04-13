import Defaults
import SwiftUI

struct AISettingsView: View {
    @Default(.aiEnabled) var aiEnabled
    @Default(.aiShowInNotch) var aiShowInNotch
    @Default(.aiAutoInstallHooks) var aiAutoInstallHooks
    @Default(.aiScreenMode) var aiScreenMode
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var aiManager = AIManager.shared

    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }

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
                    Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
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
                    Text(hookStatusText)
                        .foregroundStyle(hookStatusColor)
                }

                Button("Reinstall hooks") {
                    AIHookInstaller.installIfNeeded()
                }

                Button("Uninstall hooks") {
                    AIHookInstaller.uninstall()
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

    private var hookStatusText: String {
        AIHookInstaller.isInstalled() ? "Installed" : "Not installed"
    }

    private var hookStatusColor: Color {
        AIHookInstaller.isInstalled() ? .green : .orange
    }
}
