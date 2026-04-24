import AsyncXPCConnection
import Foundation

/// Darwin notification name for interrupt detection
let kInterruptNotificationName = "com.boringnotch.ai.interrupt"

/// Darwin notification name for state file updates
let kStateUpdateNotificationName = "com.boringnotch.ai.stateupdate"

/// Client for the AI XPC Helper service.
/// Connects to the unsandboxed helper to manage the socket server,
/// JSONL interrupt watchers, and reads state files for event data.
final class AIXPCClient {
    nonisolated static let shared = AIXPCClient()

    private let serviceName = "theboringteam.boringnotch.BoringNotchAIXPCHelper"

    private var remoteService: RemoteXPCService<BoringNotchAIXPCHelperProtocol>?
    private var connection: NSXPCConnection?

    /// Callback when interrupt is detected via Darwin Notification
    var onInterruptDetected: ((String) -> Void)?

    /// Callback when state file update is detected via Darwin Notification
    /// Parameters: changedSessionIds - list of sessionIds that have state changes
    var onStateUpdateDetected: (([String]) -> Void)?

    deinit {
        connection?.invalidate()
    }

    // MARK: - Connection Management

    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchAIXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }

        let conn = NSXPCConnection(serviceName: serviceName)

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

        // Set up Darwin Notification listener for interrupts
        setupDarwinNotificationListener()

        // Set up Darwin Notification listener for state updates
        setupStateUpdateListener()

        return service
    }

    // MARK: - Distributed Notification Listener

    private func setupDarwinNotificationListener() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kInterruptNotificationName),
            object: nil,
            queue: nil,
            using: { notification in
                // Read interrupt files from /tmp
                let tmpPath = "/tmp"
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
                    return
                }

                let interruptFiles = files.filter { $0.hasPrefix("boringnotch-interrupt-") && $0.hasSuffix(".txt") }
                for fileName in interruptFiles {
                    let filePath = tmpPath + "/" + fileName
                    // Extract session ID from filename
                    let sessionId = fileName
                        .replacingOccurrences(of: "boringnotch-interrupt-", with: "")
                        .replacingOccurrences(of: ".txt", with: "")

                    // Read and clean up
                    if let content = try? String(contentsOfFile: filePath),
                       content == sessionId {
                        // Clean up the file
                        try? FileManager.default.removeItem(atPath: filePath)

                        // Notify callback
                        Task { @MainActor in
                            AIXPCClient.shared.onInterruptDetected?(sessionId)
                        }
                    }
                }
            }
        )

        NSLog("AIXPCClient: Distributed notification listener set up for interrupts")
    }

    private func setupStateUpdateListener() {
        // Clean up stale notification files from previous session (startup hygiene)
        let notifyDir = "/tmp/boringnotch-notify"
        if FileManager.default.fileExists(atPath: notifyDir) {
            try? FileManager.default.removeItem(atPath: notifyDir)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kStateUpdateNotificationName),
            object: nil,
            queue: nil,
            using: { notification in
                NSLog("AIXPCClient: Distributed notification received for stateupdate")
                // Read from dedicated notification directory (avoid scanning /tmp)
                let notifyDir = "/tmp/boringnotch-notify"
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: notifyDir) else {
                    NSLog("AIXPCClient: Cannot read notify directory")
                    return
                }

                // Filter stateupdate notification files
                let notifyFiles = files.filter { $0.hasPrefix("stateupdate-") && $0.hasSuffix(".txt") }
                var changedSessionIds: [String] = []

                for fileName in notifyFiles {
                    let filePath = notifyDir + "/" + fileName
                    if let sessionId = try? String(contentsOfFile: filePath, encoding: .utf8), !sessionId.isEmpty {
                        changedSessionIds.append(sessionId)
                    }
                    // Clean up notification file after reading
                    try? FileManager.default.removeItem(atPath: filePath)
                }

                // Notify callback with changed sessionIds (if any)
                NSLog("AIXPCClient: Found \(changedSessionIds.count) sessionIds, calling callback")
                if !changedSessionIds.isEmpty {
                    Task { @MainActor in
                        NSLog("AIXPCClient: Dispatching onStateUpdateDetected callback")
                        AIXPCClient.shared.onStateUpdateDetected?(changedSessionIds)
                    }
                }
            }
        )

        NSLog("AIXPCClient: Distributed notification listener set up for state updates (dedicated directory, startup cleanup)")
    }

    // MARK: - Server Management

    nonisolated func startServer() async -> Bool {
        do {
            let service = await MainActor.run {
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
}
