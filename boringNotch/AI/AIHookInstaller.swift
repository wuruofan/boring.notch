import Defaults
import Foundation

struct AIHookInstaller {
    static let hookScriptName = "boringnotch-ai-state.py"

    /// Real user home directory (not sandbox container)
    private static let realHomeDir: URL = {
        // In sandbox, NSHomeDirectory() returns container path.
        // Use getpwuid to get the real home directory.
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    private static let claudeDir = realHomeDir.appendingPathComponent(".claude")
    static let hooksDir = claudeDir.appendingPathComponent("hooks")
    private static let settingsFile = claudeDir.appendingPathComponent("settings.json")

    // MARK: - Install

    static func installIfNeeded() {
        guard Defaults[.aiAutoInstallHooks] else { return }

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        let scriptURL = hooksDir.appendingPathComponent(hookScriptName)
        let scriptContent = generateHookScript()
        try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        updateSettings()
        NSLog("AIHookInstaller: Hooks installed")
    }

    // MARK: - Uninstall

    static func uninstall() {
        let scriptURL = hooksDir.appendingPathComponent(hookScriptName)
        try? FileManager.default.removeItem(at: scriptURL)
        removeFromSettings()
        NSLog("AIHookInstaller: Hooks uninstalled")
    }

    // MARK: - Check

    static func isInstalled() -> Bool {
        let scriptURL = hooksDir.appendingPathComponent(hookScriptName)
        return FileManager.default.fileExists(atPath: scriptURL.path)
    }

    // MARK: - Settings Update

    /// Backup the original settings.json before any modification
    private static func backupSettings() -> Bool {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return true }

        let backupFile = claudeDir.appendingPathComponent("settings.json.boringnotch-backup")

        // Don't overwrite an existing backup (preserve the earliest state)
        if FileManager.default.fileExists(atPath: backupFile.path) {
            NSLog("AIHookInstaller: Backup already exists at \(backupFile.path)")
            return true
        }

        do {
            try FileManager.default.copyItem(at: settingsFile, to: backupFile)
            NSLog("AIHookInstaller: Backed up settings.json to \(backupFile.path)")
            return true
        } catch {
            NSLog("AIHookInstaller: Failed to backup settings.json: \(error)")
            return false
        }
    }

    /// Atomically write JSON data to settings.json
    /// Uses replaceItem which works in sandboxed environments
    @discardableResult
    private static func writeSettingsSafely(_ json: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            NSLog("AIHookInstaller: Failed to serialize settings JSON")
            return false
        }

        // Write to temp file first, then replace the original atomically
        let tempFile = settingsFile.appendingPathExtension("tmp")
        do {
            // Remove stale temp file if any
            try? FileManager.default.removeItem(at: tempFile)
            try data.write(to: tempFile, options: .atomic)
            // replaceItem works in sandbox (unlike moveItem which can't overwrite)
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                _ = try FileManager.default.replaceItemAt(settingsFile, withItemAt: tempFile)
            } else {
                try FileManager.default.moveItem(at: tempFile, to: settingsFile)
            }
            return true
        } catch {
            NSLog("AIHookInstaller: Failed to write settings.json: \(error)")
            try? FileManager.default.removeItem(at: tempFile)
            return false
        }
    }

    private static func updateSettings() {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) ~/.claude/hooks/\(hookScriptName)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains(hookScriptName)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        // Backup before writing, then write atomically
        backupSettings()
        writeSettingsSafely(json)
    }

    private static func removeFromSettings() {
        guard let data = try? Data(contentsOf: settingsFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains(hookScriptName)
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        // Backup before writing, then write atomically
        backupSettings()
        writeSettingsSafely(json)
    }

    // MARK: - Python Detection

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    // MARK: - Hook Script

    private static func generateHookScript() -> String {
        """
        #!/usr/bin/env python3
        import json
        import socket
        import sys
        import os

        SOCKET_PATH = "/tmp/boringnotch-ai.sock"
        TIMEOUT_SECONDS = 300

        def send_event(state):
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(TIMEOUT_SECONDS)
                sock.connect(SOCKET_PATH)
                sock.sendall(json.dumps(state).encode())

                if state.get("status") == "waiting_for_approval":
                    response = sock.recv(4096)
                    return json.loads(response.decode())
                return None
            except Exception as e:
                print(f"BoringNotch hook error: {e}", file=sys.stderr)
                return None
            finally:
                try:
                    sock.close()
                except:
                    pass

        def get_tty():
            ppid = os.getppid()
            try:
                import subprocess
                result = subprocess.run(
                    ["ps", "-p", str(ppid), "-o", "tty="],
                    capture_output=True, text=True
                )
                tty = result.stdout.strip()
                if tty and tty != "?":
                    return "/dev/" + tty if not tty.startswith("/") else tty
            except:
                pass
            try:
                return os.ttyname(sys.stdin.fileno())
            except:
                try:
                    return os.ttyname(sys.stdout.fileno())
                except:
                    return ""

        def main():
            try:
                input_data = json.loads(sys.stdin.read())
            except:
                input_data = {}

            event_type = os.environ.get("CLAUDE_HOOK_EVENT_NAME", "Unknown")

            # Map event to status
            status_map = {
                "UserPromptSubmit": "processing",
                "PreToolUse": "running_tool",
                "PostToolUse": "processing",
                "PermissionRequest": "waiting_for_approval",
                "Stop": "waiting_for_input",
                "SubagentStop": "waiting_for_input",
                "SessionStart": "waiting_for_input",
                "SessionEnd": "ended",
                "PreCompact": "compacting",
            }

            notification_type = input_data.get("notification_type", "")

            if event_type == "Notification":
                if notification_type == "permission_prompt":
                    return
                elif notification_type == "idle_prompt":
                    status = "waiting_for_input"
                else:
                    status = "notification"
            else:
                status = status_map.get(event_type, "unknown")

            state = {
                "session_id": os.environ.get("CLAUDE_SESSION_ID", ""),
                "cwd": os.environ.get("CLAUDE_WORKING_DIRECTORY", ""),
                "event": event_type,
                "status": status,
                "tool": input_data.get("tool_name"),
                "tool_input": input_data.get("tool_input"),
                "tool_use_id": input_data.get("tool_use_id"),
                "pid": os.getpid(),
                "tty": get_tty(),
            }

            response = send_event(state)

            if response and status == "waiting_for_approval":
                decision = response.get("decision", "ask")
                reason = response.get("reason")
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": decision,
                        }
                    }
                }
                if reason and decision == "deny":
                    output["hookSpecificOutput"]["decision"]["message"] = reason
                print(json.dumps(output))

        if __name__ == "__main__":
            main()
        """
    }
}
