import Foundation
import os.log

private let serverLog = Logger(subsystem: "com.boringnotch.xpchelper", category: "AIHookServer")

/// Core socket server logic that runs inside the XPC Helper (unsandboxed).
/// Receives events from Claude Code hooks via Unix Domain Socket,
/// writes them to a state file for the main app to read.
/// Uses Thread-based polling because DispatchSource/Task don't work reliably in XPC Services.
class AIHookServerCore {
    static let socketPath = "/tmp/boringnotch-ai.sock"

    private var serverSocket: Int32 = -1
    private var pollingThread: Thread?
    private var isRunning: Bool = false
    private let queue = DispatchQueue(label: "com.boringnotch.ai.socket", qos: .userInitiated)

    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    /// State file path in sandbox container (main app can read this)
    /// XPC Helper is unsandboxed and can write anywhere
    static let stateFilePath: String = {
        // Get real user home directory (not sandbox container)
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return "\(homePath)/Library/Containers/theboringteam.boringnotch/Data/Library/Caches/boringnotch-ai-state.json"
        }
        // Fallback to /tmp if we can't determine container path
        return "/tmp/boringnotch-ai-state.json"
    }()

    /// URL-safe base64 encoding for sessionId to ensure safe file names
    static func encodeSessionId(_ sessionId: String) -> String {
        // Use base64url encoding (no +, /, = characters)
        let data = sessionId.data(using: .utf8) ?? Data()
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base path for all state files
    static let stateFileBasePath: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let homePath = String(cString: home)
            return "\(homePath)/Library/Containers/theboringteam.boringnotch/Data/Library/Caches"
        }
        return "/tmp"
    }()

    struct PendingPermission {
        let sessionId: String
        let toolUseId: String
        let clientSocket: Int32
        let receivedAt: Date
    }

    // MARK: - Public

    func start() {
        queue.async { [weak self] in
            self?.startServer()
        }
    }

    func stop() {
        isRunning = false
        pollingThread = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        try? FileManager.default.removeItem(atPath: Self.stateFilePath)
    }

    /// Delete the state file for a specific session
    func cleanupStateFile(sessionId: String) -> Bool {
        let encodedId = Self.encodeSessionId(sessionId)
        let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"

        if FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                NSLog("AIHookServerCore: Cleaned up state file for \(sessionId.prefix(8))")
                return true
            } catch {
                NSLog("AIHookServerCore: Failed to cleanup state file: \(error)")
                return false
            }
        }
        return true  // File doesn't exist, consider it cleaned
    }

    @discardableResult
    func respondToPermission(toolUseId: String, decision: String, reason: String?) -> Bool {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return false
        }
        permissionsLock.unlock()

        let response: [String: Any?] = ["decision": decision, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            close(pending.clientSocket)
            return false
        }

        var success = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let result = write(pending.clientSocket, baseAddress, data.count)
            success = result >= 0
        }

        close(pending.clientSocket)
        return success
    }

    @discardableResult
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String?) -> Bool {
        permissionsLock.lock()
        let matching = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matching else {
            permissionsLock.unlock()
            return false
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response: [String: Any?] = ["decision": decision, "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            close(pending.clientSocket)
            return false
        }

        var success = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let result = write(pending.clientSocket, baseAddress, data.count)
            success = result >= 0
        }

        close(pending.clientSocket)
        return success
    }

    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    // MARK: - Server

    private func startServer() {
        guard serverSocket < 0 else { return }

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            serverLog.error("Failed to create socket: \(errno)")
            return
        }

        // Set non-blocking
        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            serverLog.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            serverLog.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        serverLog.info("Listening on \(Self.socketPath), starting polling")

        // Use polling instead of DispatchSource (XPC Service compatibility)
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        isRunning = true
        pollingThread = Thread { [weak self] in
            while self?.isRunning == true {
                self?.pollForConnections()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        pollingThread?.start()
        serverLog.info("Polling thread started")
    }

    private func pollForConnections() {
        var pollFd = pollfd(fd: serverSocket, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFd, 1, 0)

        if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
            acceptConnection()
        }
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty { break }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        // Parse event for internal logic (needed for logging before write)
        guard let json = try? JSONSerialization.jsonObject(with: allData) as? [String: Any] else {
            NSLog("AIHookServerCore: Failed to parse event JSON")
            close(clientSocket)
            return
        }

        let event = json["event"] as? String ?? ""
        let sessionId = json["session_id"] as? String ?? ""
        let status = json["status"] as? String ?? ""

        // Write raw event data to state file for main app to read
        if let str = String(data: allData, encoding: .utf8) {
            // Per-session state file path
            let encodedId = Self.encodeSessionId(sessionId)
            let path = Self.stateFileBasePath + "/boringnotch-ai-state-" + encodedId + ".json"

            // Diagnostic: log before/after inode to verify atomic write behavior
            let beforeInode: Int? = {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let inode = attrs[.systemFileNumber] as? Int {
                    return inode
                }
                return nil
            }()

            try? str.write(toFile: path, atomically: true, encoding: .utf8)

            let afterInode: Int? = {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let inode = attrs[.systemFileNumber] as? Int {
                    return inode
                }
                return nil
            }()

            NSLog("AIHookServerCore: Wrote event \(event) inode: before=\(beforeInode ?? -1) after=\(afterInode ?? -1) changed=\(beforeInode != afterInode)")

            // Write sessionId to dedicated notification directory (avoid scanning /tmp)
            // Use timestamp in filename to avoid race conditions with multiple rapid notifications
            let notifyDir = "/tmp/boringnotch-notify"
            try? FileManager.default.createDirectory(atPath: notifyDir, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)  // milliseconds
            let notifyPath = notifyDir + "/stateupdate-" + Self.encodeSessionId(sessionId) + "-" + String(timestamp) + ".txt"
            try? sessionId.write(toFile: notifyPath, atomically: true, encoding: .utf8)

            // Send Darwin Notification to notify main app immediately
            let notificationName = "com.boringnotch.ai.stateupdate" as CFString
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(notificationName),
                nil, nil, true
            )
            NSLog("AIHookServerCore: Sent stateupdate notification for \(sessionId.prefix(8)), notifyPath=\(notifyPath)")
        }

        // Cache tool_use_id from PreToolUse
        if event == "PreToolUse" {
            if let toolUseId = json["tool_use_id"] as? String {
                let toolName = json["tool"] as? String ?? "unknown"
                let key = "\(sessionId):\(toolName)"
                cacheLock.lock()
                if toolUseIdCache[key] == nil { toolUseIdCache[key] = [] }
                toolUseIdCache[key]?.append(toolUseId)
                cacheLock.unlock()
            }
        }

        // Clean up cache on session end
        if event == "SessionEnd" {
            cacheLock.lock()
            let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
            for key in keysToRemove { toolUseIdCache.removeValue(forKey: key) }
            cacheLock.unlock()
        }

        // Handle permission requests (keep socket open for response)
        if event == "PermissionRequest" && status == "waiting_for_approval" {
            let toolUseId: String
            if let eventToolUseId = json["tool_use_id"] as? String {
                toolUseId = eventToolUseId
            } else {
                // Try cached tool_use_id
                let toolName = json["tool"] as? String ?? "unknown"
                let key = "\(sessionId):\(toolName)"
                cacheLock.lock()
                if let cached = toolUseIdCache[key]?.first {
                    toolUseId = cached
                    toolUseIdCache[key]?.removeFirst()
                    if toolUseIdCache[key]?.isEmpty ?? true { toolUseIdCache.removeValue(forKey: key) }
                } else {
                    cacheLock.unlock()
                    NSLog("AIHookServerCore: Permission request missing tool_use_id for \(sessionId.prefix(8))")
                    close(clientSocket)
                    return
                }
                cacheLock.unlock()
            }

            let pending = PendingPermission(
                sessionId: sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()
            return
        } else {
            close(clientSocket)
        }
    }
}
