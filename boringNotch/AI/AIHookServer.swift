import Foundation

/// File-based event receiver for Claude Code hook events.
/// The XPC Helper (unsandboxed) runs the actual Socket server and writes
/// received events to a state file. This class monitors that file.
class AIHookServer {
    static let stateFilePath = "/tmp/boringnotch-ai-state.json"

    var onEvent: ((AIHookEvent) -> Void)?
    var onPermissionFailure: ((_ sessionId: String, _ toolUseId: String) -> Void)?

    private var fileSource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.boringnotch.ai.filewatch", qos: .userInitiated)
    private var lastModificationDate: Date?

    // MARK: - Public

    func start() {
        startFileWatcher()
        NSLog("AIHookServer: Watching \(Self.stateFilePath)")
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
    }

    func hasPendingPermission(sessionId: String) async -> Bool {
        await AIXPCClient.shared.hasPendingPermission(sessionId: sessionId)
    }

    // MARK: - File Watcher

    private func startFileWatcher() {
        // Ensure state file exists for watching
        if !FileManager.default.fileExists(atPath: Self.stateFilePath) {
            FileManager.default.createFile(atPath: Self.stateFilePath, contents: nil)
        }

        let fd = open(Self.stateFilePath, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("AIHookServer: Failed to open state file for watching")
            return
        }

        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        fileSource?.setEventHandler { [weak self] in
            self?.processStateFile()
        }

        fileSource?.setCancelHandler {
            close(fd)
        }

        fileSource?.resume()
    }

    private func processStateFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.stateFilePath)),
              !data.isEmpty else {
            return
        }

        guard let event = try? JSONDecoder().decode(AIHookEvent.self, from: data) else {
            return
        }

        // Deduplicate: skip if same modification
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.stateFilePath)
        let modDate = attrs?[.modificationDate] as? Date
        if let modDate = modDate, modDate == lastModificationDate { return }
        lastModificationDate = modDate

        onEvent?(event)
    }
}
