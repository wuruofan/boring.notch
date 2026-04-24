import AsyncXPCConnection
import Foundation

/// Client for the AI XPC Helper service.
/// Connects to the unsandboxed helper to manage the socket server,
/// JSONL interrupt watchers, and reads state files for event data.
final class AIXPCClient {
    nonisolated static let shared = AIXPCClient()

    private let serviceName = "theboringteam.boringnotch.BoringNotchAIXPCHelper"

    /// Caches directory path for debug files (sandbox container)
    private static let cachesPath: String = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? ""
    }()

    private var remoteService: RemoteXPCService<BoringNotchAIXPCHelperProtocol>?
    private var connection: NSXPCConnection?

    /// Listener object for receiving XPC callbacks
    private var listener: AIXPCListener?

    deinit {
        connection?.invalidate()
    }

    // MARK: - Connection Management

    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchAIXPCHelperProtocol> {
        // Write entry marker for debugging (sandbox container path)
        let entryMarker = Self.cachesPath + "/boringnotch-ensureRemoteService-entry.txt"
        try? "ensureRemoteService called at \(Date())".write(toFile: entryMarker, atomically: true, encoding: .utf8)

        if let existing = remoteService {
            // Write early return marker
            let earlyReturnMarker = Self.cachesPath + "/boringnotch-ensureRemoteService-early-return.txt"
            try? "Returning early, remoteService already exists at \(Date())".write(toFile: earlyReturnMarker, atomically: true, encoding: .utf8)
            return existing
        }

        let conn = NSXPCConnection(serviceName: serviceName)

        // Set up exported interface for receiving callbacks from XPC Helper
        conn.exportedInterface = NSXPCInterface(with: AIXPCEventListener.self)
        conn.exportedObject = listener

        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }

        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.remoteService = nil
            }
        }

        conn.resume()

        let service = RemoteXPCService<BoringNotchAIXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchAIXPCHelperProtocol.self
        )

        connection = conn
        remoteService = service

        // Listener is set externally via setListener(), callbacks handled by AIXPCListener

        return service
    }

    // MARK: - Server Management

    nonisolated func startServer() async -> Bool {
        NSLog("AIXPCClient.startServer() called - about to call ensureRemoteService")
        do {
            let service = await MainActor.run {
                NSLog("AIXPCClient: Inside MainActor.run, calling ensureRemoteService")
                return ensureRemoteService()
            }
            NSLog("AIXPCClient: Connection created, calling remote startServer()")
            return try await service.withContinuation { service, continuation in
                service.startServer { success in
                    NSLog("AIXPCClient: Remote startServer returned \(success)")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: startServer failed with error: \(error)")
            return false
        }
    }

    nonisolated func stopServer() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.stopServer { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func isServerRunning() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.isServerRunning { running in
                    continuation.resume(returning: running)
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - Permission Responses

    nonisolated func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.respondToPermission(toolUseId: toolUseId, decision: decision, reason: reason) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.respondToPermissionBySession(sessionId: sessionId, decision: decision, reason: reason) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func hasPendingPermission(sessionId: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.hasPendingPermission(sessionId: sessionId) { has in
                    continuation.resume(returning: has)
                }
            }
        } catch {
            return false
        }
    }

    nonisolated func getSocketPath() async -> String {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.getSocketPath { path in
                    continuation.resume(returning: path)
                }
            }
        } catch {
            return "/tmp/boringnotch-ai.sock"
        }
    }

    // MARK: - JSONL Interrupt Watching

    nonisolated func startInterruptWatcher(sessionId: String, cwd: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.startInterruptWatcher(sessionId: sessionId, cwd: cwd) { success in
                    NSLog("AIXPCClient: startInterruptWatcher returned \(success) for \(sessionId.prefix(8))")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: startInterruptWatcher failed: \(error)")
            return false
        }
    }

    nonisolated func stopInterruptWatcher(sessionId: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.stopInterruptWatcher(sessionId: sessionId) { success in
                    NSLog("AIXPCClient: stopInterruptWatcher returned \(success) for \(sessionId.prefix(8))")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: stopInterruptWatcher failed: \(error)")
            return false
        }
    }

    nonisolated func cleanupStateFile(sessionId: String) async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.cleanupStateFile(sessionId: sessionId) { success in
                    NSLog("AIXPCClient: cleanupStateFile returned \(success) for \(sessionId.prefix(8))")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: cleanupStateFile failed: \(error)")
            return false
        }
    }

    // MARK: - Tmux Commands

    nonisolated func runTmuxCommand(command: String) async -> (success: Bool, output: String) {
        return await runShellCommandInternal(command: command)
    }

    nonisolated func runShellCommand(command: String) async -> (success: Bool, output: String) {
        return await runShellCommandInternal(command: command)
    }

    private nonisolated func runShellCommandInternal(command: String) async -> (success: Bool, output: String) {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.runShellCommand(command: command) { success, output in
                    continuation.resume(returning: (success, output))
                }
            }
        } catch {
            NSLog("AIXPCClient: runShellCommand failed: \(error)")
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Listener Registration (for real-time callbacks)

    /// Set the listener for receiving XPC callbacks.
    /// The listener is set as exportedObject, XPC Helper gets it via remoteObjectProxy.
    @MainActor
    func setListener(_ listener: AIXPCListener) {
        self.listener = listener
        NSLog("AIXPCClient: Listener set as exportedObject")
    }

    /// Test listener connectivity by asking XPC Helper to ping the listener.
    nonisolated func testPing() async -> Bool {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.testPing { success in
                    NSLog("AIXPCClient: testPing returned \(success)")
                    continuation.resume(returning: success)
                }
            }
        } catch {
            NSLog("AIXPCClient: testPing failed: \(error)")
            return false
        }
    }
}

/// Listener implementation for receiving XPC callbacks.
/// This class receives real-time events from XPC Helper via XPC protocol callbacks.
class AIXPCListener: NSObject, AIXPCEventListener {

    /// Callback when ping is received (for verification)
    var onPingReceived: (() -> Void)?

    /// Callback when state update is received
    var onStateUpdateReceived: (([String]) -> Void)?

    /// Callback when interrupt is received
    var onInterruptReceived: ((String) -> Void)?

    func ping() {
        NSLog("AIXPCListener: ping() received!")
        onPingReceived?()
    }

    func onStateUpdate(sessionIds: [String]) {
        NSLog("AIXPCListener: onStateUpdate received with \(sessionIds.count) sessions")
        onStateUpdateReceived?(sessionIds)
    }

    func onInterrupt(sessionId: String) {
        NSLog("AIXPCListener: onInterrupt received for \(sessionId.prefix(8))")
        onInterruptReceived?(sessionId)
    }
}
