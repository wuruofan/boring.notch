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
        return result.success
    }

    func listPanes() async -> [(target: TmuxTarget, pid: Int)] {
        let result = await runCommand("tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}'")

        guard result.success else { return [] }

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
        return result.success
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        let result = await runCommand("tmux switch-client -t \(target.targetString)")
        return result.success
    }

    func runCommand(_ command: String) async -> (success: Bool, output: String) {
        await AIXPCClient.shared.runShellCommand(command: command)
    }
}
