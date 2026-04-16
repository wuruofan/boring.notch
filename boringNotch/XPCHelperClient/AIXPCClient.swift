import AsyncXPCConnection
import Foundation

/// Client for the AI XPC Helper service.
/// Connects to the unsandboxed helper to manage the socket server,
/// and reads state files for event data.
final class AIXPCClient {
    nonisolated static let shared = AIXPCClient()

    private let serviceName = "theboringteam.boringnotch.BoringNotchAIXPCHelper"

    private var remoteService: RemoteXPCService<BoringNotchAIXPCHelperProtocol>?
    private var connection: NSXPCConnection?

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
        return service
    }

    // MARK: - Server Management

    nonisolated func startServer() async -> Bool {
        NSLog("AIXPCClient.startServer() called")
        do {
            let service = await MainActor.run {
                NSLog("AIXPCClient: Creating NSXPCConnection for \(serviceName)")
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
}
