import Foundation

actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    func approveOnce(target: TmuxTarget) async -> Bool {
        await TmuxController.shared.sendKeys(to: target, keys: "1", pressEnter: true)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await TmuxController.shared.sendKeys(to: target, keys: "2", pressEnter: true)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        if let message = message, !message.isEmpty {
            _ = await TmuxController.shared.sendKeys(to: target, keys: message, pressEnter: false)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await TmuxController.shared.sendKeys(to: target, keys: "n", pressEnter: true)
    }

    func sendReply(target: TmuxTarget, message: String) async -> Bool {
        await TmuxController.shared.sendKeys(to: target, keys: message, pressEnter: true)
    }

    func jumpToTerminal(tty: String?) async {
        guard let tty = tty else { return }

        let appName: String
        if tty.contains("iTerm") || tty.contains("iterm") {
            appName = "iTerm2"
        } else {
            appName = "Terminal"
        }

        _ = await AIXPCClient.shared.runShellCommand(command: "open -a '\(appName)'")
    }
}
