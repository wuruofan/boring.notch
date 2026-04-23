import Foundation

actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    /// Find tmux target by matching pane's current path
    func findTarget(forCWD cwd: String) async -> TmuxTarget? {
        let result = await TmuxController.shared.runCommand(
            "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}'"
        )

        guard result.success else { return nil }

        for line in result.output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let targetStr = String(parts[0])
            let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            if path == cwd || cwd.hasPrefix(path + "/") {
                return TmuxTarget(from: targetStr)
            }
        }

        return nil
    }

    /// Find tmux target by PID - traverse process tree to find tmux client
    func findTarget(forPID pid: Int) async -> TmuxTarget? {
        let result = await TmuxController.shared.runCommand(
            "tmux list-clients -F '#{client_session} #{client_pid}'"
        )

        guard result.success else { return nil }

        var clientPIDs: [(session: String, pid: Int)] = []
        for line in result.output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let clientPID = Int(parts[1]) else { continue }
            clientPIDs.append((String(parts[0]), clientPID))
        }

        var currentPID = pid
        for _ in 0..<15 {
            for client in clientPIDs {
                if isProcessRelated(appPID: client.pid, targetPID: currentPID) {
                    let panes = await TmuxController.shared.listPanes()
                    if let pane = panes.first(where: { $0.target.session == client.session }) {
                        return pane.target
                    }
                }
            }

            if let ppid = getNonisolatedParentPID(currentPID) {
                if ppid <= 1 { break }
                currentPID = ppid
            } else {
                break
            }
        }

        return nil
    }

    private func isProcessRelated(appPID: Int, targetPID: Int) -> Bool {
        if appPID == targetPID { return true }

        var current = targetPID
        for _ in 0..<10 {
            if current == appPID { return true }
            if let ppid = getNonisolatedParentPID(current), ppid > 1 {
                current = ppid
            } else {
                break
            }
        }
        return false
    }

    // Nonisolated helper for process tree traversal
    private nonisolated func getNonisolatedParentPID(_ pid: Int) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "ppid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return Int(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } catch {
            return nil
        }
    }
}
