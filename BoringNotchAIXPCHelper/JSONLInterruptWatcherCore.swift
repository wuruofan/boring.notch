import Foundation

/// Darwin notification name for interrupt detection
let kInterruptNotificationName = "com.boringnotch.ai.interrupt"

// MARK: - Interrupt Watcher Manager (XPC Helper)

/// Manages interrupt watchers for all active sessions in XPC Helper
/// Uses Thread.polling instead of DispatchSource for XPC Service compatibility
class InterruptWatcherManagerCore {
    static let shared = InterruptWatcherManagerCore()

    private var watchers: [String: JSONLInterruptPollingThread] = [:]
    private let lock = NSLock()

    private init() {}

    func startWatching(sessionId: String, cwd: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard watchers[sessionId] == nil else {
            NSLog("InterruptWatcherManagerCore: Already watching \(sessionId.prefix(8))")
            return true
        }

        let watcher = JSONLInterruptPollingThread(sessionId: sessionId, cwd: cwd)
        watcher.start()
        watchers[sessionId] = watcher

        NSLog("InterruptWatcherManagerCore: Started Thread.polling watcher for \(sessionId.prefix(8))")
        return true
    }

    func stopWatching(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let watcher = watchers.removeValue(forKey: sessionId) else {
            return false
        }

        watcher.stop()
        NSLog("InterruptWatcherManagerCore: Stopped watcher for \(sessionId.prefix(8))")
        return true
    }

    func stopAll() {
        lock.lock()
        defer { lock.unlock() }

        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        NSLog("InterruptWatcherManagerCore: Stopped all watchers")
    }
}