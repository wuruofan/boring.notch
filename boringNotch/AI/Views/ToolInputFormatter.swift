import Foundation
import SwiftUI

/// Format tool input for display in Session Row second line.
/// Different tools have different display strategies.
enum ToolInputFormatter {
    /// Format tool name + input for second line display.
    /// Returns (displayText, color)
    static func format(tool: String, input: [String: AnyCodable]?, phase: AISessionPhase) -> (text: String, color: Color) {
        // Handle error states first
        if phase == .toolFailed {
            return ("\(formatToolName(tool)) Failed", .red)
        }
        if phase == .error {
            return ("Error", .red)
        }

        // Handle special status text
        if input == nil {
            switch phase {
            case .processing:
                return ("Thinking...", .white.opacity(0.5))
            case .compacting:
                return ("Compacting...", .white.opacity(0.5))
            default:
                return (formatToolName(tool), .white.opacity(0.5))
            }
        }

        // Format based on tool type
        switch tool {
        case "Bash":
            return formatBash(input)
        case "Edit":
            return formatEdit(input)
        case "Write":
            return formatWrite(input)
        case "Read":
            return formatRead(input)
        case "Grep":
            return formatGrep(input)
        case "Glob":
            return formatGlob(input)
        case "WebFetch", "WebSearch":
            return formatWeb(input)
        case "Agent":
            return formatAgent(input)
        default:
            // MCP tool: "mcp__server__tool" -> "server: tool"
            if tool.hasPrefix("mcp__") {
                return formatMCP(tool)
            }
            return (formatToolName(tool), .white.opacity(0.5))
        }
    }

    // MARK: - Tool-specific formatting

    private static func formatBash(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let command = input?["command"]?.value as? String else {
            return ("Bash", .white.opacity(0.5))
        }
        // Tail truncate, keep first 30 chars
        let truncated = command.count > 30 ? String(command.prefix(30)) + "..." : command
        return ("Bash \(truncated)", .white.opacity(0.5))
    }

    private static func formatEdit(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let filePath = input?["file_path"]?.value as? String else {
            return ("Edit", .white.opacity(0.5))
        }
        // Show last two path components
        let parts = filePath.split(separator: "/")
        let displayPath = parts.count > 2 ? "\(parts[parts.count-2])/\(parts.last!)" : filePath
        return ("Edit \(displayPath)", .white.opacity(0.5))
    }

    private static func formatWrite(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let filePath = input?["file_path"]?.value as? String else {
            return ("Write", .white.opacity(0.5))
        }
        // Tail truncate filename
        let filename = filePath.split(separator: "/").last.map(String.init) ?? filePath
        let truncated = filename.count > 20 ? String(filename.prefix(20)) + "..." : filename
        return ("Write \(truncated)", .white.opacity(0.5))
    }

    private static func formatRead(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let filePath = input?["file_path"]?.value as? String else {
            return ("Read", .white.opacity(0.5))
        }
        let filename = filePath.split(separator: "/").last.map(String.init) ?? filePath
        let truncated = filename.count > 20 ? String(filename.prefix(20)) + "..." : filename
        return ("Read \(truncated)", .white.opacity(0.5))
    }

    private static func formatGrep(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let pattern = input?["pattern"]?.value as? String else {
            return ("Grep", .white.opacity(0.5))
        }
        let truncated = pattern.count > 20 ? String(pattern.prefix(20)) + "..." : pattern
        return ("Grep \(truncated)", .white.opacity(0.5))
    }

    private static func formatGlob(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let pattern = input?["pattern"]?.value as? String else {
            return ("Glob", .white.opacity(0.5))
        }
        // Glob patterns usually short, don't truncate
        return ("Glob \(pattern)", .white.opacity(0.5))
    }

    private static func formatWeb(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let url = input?["url"]?.value as? String else {
            return ("WebFetch", .white.opacity(0.5))
        }
        // Show domain + last path component
        if let urlObj = URL(string: url) {
            let domain = urlObj.host ?? ""
            let pathParts = urlObj.path.split(separator: "/")
            let lastPath = pathParts.last.map(String.init) ?? ""
            return ("WebFetch \(domain)/\(lastPath)", .white.opacity(0.5))
        }
        return ("WebFetch", .white.opacity(0.5))
    }

    private static func formatAgent(_ input: [String: AnyCodable]?) -> (String, Color) {
        guard let description = input?["description"]?.value as? String else {
            return ("Agent", .white.opacity(0.5))
        }
        let truncated = description.count > 20 ? String(description.prefix(20)) + "..." : description
        return ("Agent \(truncated)", .white.opacity(0.5))
    }

    private static func formatMCP(_ tool: String) -> (String, Color) {
        let parts = tool.dropFirst(5).split(separator: "__")
        if parts.count >= 2 {
            return ("\(parts[0]): \(parts[1])", .white.opacity(0.5))
        }
        return (tool, .white.opacity(0.5))
    }

    private static func formatToolName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).split(separator: "__")
            if parts.count >= 2 {
                return "\(parts[0]): \(parts[1])"
            }
        }
        return tool
    }
}