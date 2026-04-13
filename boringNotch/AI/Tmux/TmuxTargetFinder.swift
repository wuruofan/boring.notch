import Foundation

actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    func findTarget(forPID pid: Int) async -> TmuxTarget? {
        let panes = await TmuxController.shared.listPanes()

        // Direct match
        if let direct = panes.first(where: { $0.pid == pid }) {
            return direct.target
        }

        // Check parent processes
        if let parentPID = getParentPID(pid) {
            return await findTarget(forPID: parentPID)
        }

        return nil
    }

    func findTarget(forCWD cwd: String) async -> TmuxTarget? {
        let escapedCWD = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let result = await TmuxController.shared.runCommand(
            "tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}'"
        )

        guard result.exitCode == 0 else { return nil }

        for line in result.output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if path == cwd {
                return TmuxTarget(from: String(parts[0]))
            }
        }

        return nil
    }

    private func getParentPID(_ pid: Int) -> Int? {
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
            let output = String(data: data, encoding: .utf8) ?? ""
            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }
}
