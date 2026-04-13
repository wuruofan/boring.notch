import Foundation

struct TmuxTarget: Equatable {
    let session: String
    let window: Int
    let pane: Int

    var targetString: String {
        "\(session):\(window).\(pane)"
    }

    init?(from string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2 else { return nil }
        session = String(parts[0])
        let windowPane = parts[1].split(separator: ".")
        guard windowPane.count == 2,
              let w = Int(windowPane[0]),
              let p = Int(windowPane[1]) else { return nil }
        window = w
        pane = p
    }

    init(session: String, window: Int, pane: Int) {
        self.session = session
        self.window = window
        self.pane = pane
    }
}

actor TmuxController {
    static let shared = TmuxController()

    func isTmuxAvailable() async -> Bool {
        let result = await runCommand("tmux -V")
        return result.exitCode == 0
    }

    func listPanes() async -> [(target: TmuxTarget, pid: Int)] {
        let format = "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
        let result = await runCommand("tmux list-panes -a -F '\(format)'")

        guard result.exitCode == 0 else { return [] }

        var panes: [(TmuxTarget, Int)] = []
        for line in result.output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = Int(parts[1]),
                  let target = TmuxTarget(from: String(parts[0])) else { continue }
            panes.append((target, pid))
        }
        return panes
    }

    func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool = false) async -> Bool {
        let escapedKeys = keys.replacingOccurrences(of: "'", with: "'\\''")
        var command = "tmux send-keys -t \(target.targetString) -l '\(escapedKeys)'"
        if pressEnter {
            command += " && tmux send-keys -t \(target.targetString) Enter"
        }
        let result = await runCommand(command)
        return result.exitCode == 0
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        let result1 = await runCommand("tmux select-window -t \(target.session):\(target.window)")
        let result2 = await runCommand("tmux select-pane -t \(target.targetString)")
        return result1.exitCode == 0 && result2.exitCode == 0
    }

    func runCommand(_ command: String) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", command]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                continuation.resume(returning: (output, task.terminationStatus))
            } catch {
                continuation.resume(returning: ("", -1))
            }
        }
    }
}
