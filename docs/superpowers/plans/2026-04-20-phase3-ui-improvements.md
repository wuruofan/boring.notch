# Phase 3: UI 展示改进实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 紧凑态添加 Session 数量角标，展开态 Session Row 添加子 agent 角标和工具输入信息展示，新增 toolFailed/error 状态 UI

**Architecture:** 紧凑态左侧蟹图标 + 右侧状态图标（仅显示最高优先级 session），右侧角标显示活跃 Session 数量；展开态第一行项目名 + `[n]` 子 agent 角标，第二行工具名 + 输入信息（根据工具类型格式化）

**Tech Stack:** SwiftUI, Canvas API for pixel-art icons, animation timers

---

## 前置条件

- Phase 1 + Phase 2 已完成：状态系统支持多 session、subagentCount、toolFailed/error 状态

---

## 文件结构

**新建文件：**
- `boringNotch/AI/Views/ToolInputFormatter.swift` - 工具输入格式化器

**修改文件：**
- `boringNotch/AI/Views/AILiveActivity.swift` - 紧凑态 Session 数量角标
- `boringNotch/AI/Views/AgentIconView.swift` - SleepIcon 颜色调整，新增 toolFailed/error 图标
- `boringNotch/AI/Views/AIStatusAnimationView.swift` - 新增 toolFailed/error 状态动画
- `boringNotch/AI/Views/SessionRow.swift` - 子 agent 角标 + 第二行工具输入展示
- `boringNotch/AI/Views/SessionPriorityHelper.swift` - 新状态优先级排序

---

## Task 1: SessionPriorityHelper 新状态优先级

**Files:**
- Modify: `boringNotch/AI/Views/SessionPriorityHelper.swift`

- [ ] **Step 1: 更新优先级排序**

将 `priority(for:)` 方法改为：

```swift
    static func priority(for phase: AISessionPhase) -> Int {
        switch phase {
        case .waitingForApproval:
            return 0  // Highest - needs immediate user action
        case .error:
            return 1  // Error - user needs to notice
        case .toolFailed:
            return 2  // Tool failed - user needs to notice
        case .processing, .runningTool, .compacting:
            return 3  // Active work
        case .waitingForInput:
            return 4  // Ready for new input
        case .idle, .ended, .stopPending:
            return 5  // Lowest
        }
    }
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/Views/SessionPriorityHelper.swift
git commit -m "feat(ui): add error and toolFailed priority levels"
```

---

## Task 2: AgentIconView 新增 toolFailed/error 图标

**Files:**
- Modify: `boringNotch/AI/Views/AgentIconView.swift`

- [ ] **Step 1: 新增 FailedIndicatorIcon（红色感叹号）**

在 `SleepIcon` 后添加：

```swift
// MARK: - Tool Failed Indicator Icon (Red Exclamation Mark)
struct FailedIndicatorIcon: View {
    let size: CGFloat
    
    init(size: CGFloat = 14) {
        self.size = size
    }
    
    private let pixels: [(CGFloat, CGFloat)] = [
        (13, 3),   // Top dot
        (13, 7), (13, 11), (13, 15),  // Vertical bar
        (9, 19), (13, 19), (17, 19),   // Bottom dot row
        (13, 23)   // Bottom dot
    ]
    
    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale
            
            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(.red))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Error Indicator Icon (Red Error Symbol)
struct ErrorIndicatorIcon: View {
    let size: CGFloat
    
    init(size: CGFloat = 14) {
        self.size = size
    }
    
    private let pixels: [(CGFloat, CGFloat)] = [
        // X shape
        (7, 7), (11, 11),  // Top-left diagonal
        (15, 15), (19, 19), (23, 23),  // Center diagonal
        (23, 7), (19, 11),  // Top-right diagonal
        (7, 23), (11, 19)   // Bottom-left diagonal
    ]
    
    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale
            
            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(.red))
            }
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 2: 更新 SleepIcon 颜色**

将 `SleepIcon` 的默认颜色改为 `white.opacity(0.4)`：

```swift
    // Default to white.opacity(0.4) for better visibility on dark background
    init(size: CGFloat = 14, color: Color = .white.opacity(0.4)) {
        self.size = size
        self.color = color
    }
```

- [ ] **Step 3: 更新 SessionStatusIcon**

在 `SessionStatusIcon` 的 switch 中添加新状态：

```swift
    var body: some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            AgentIconView(size: size, animateLegs: true)
        case .waitingForApproval:
            PermissionIndicatorIcon(size: size, color: claudeOrange)
        case .waitingForInput:
            AgentIconView(size: size, animateLegs: false)
        case .toolFailed:
            FailedIndicatorIcon(size: size)
        case .error:
            ErrorIndicatorIcon(size: size)
        case .idle, .ended, .stopPending:
            SleepingCrabIcon(size: size, crabColor: claudeOrange.opacity(0.7))
        }
    }
```

- [ ] **Step 4: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/Views/AgentIconView.swift
git commit -m "feat(ui): add FailedIndicatorIcon and ErrorIndicatorIcon, adjust SleepIcon color"
```

---

## Task 3: AIStatusAnimationView 新状态动画

**Files:**
- Modify: `boringNotch/AI/Views/AIStatusAnimationView.swift`

- [ ] **Step 1: 添加新状态展示**

更新 switch body：

```swift
    var body: some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
                .frame(width: size, height: size)
        
        case .waitingForApproval:
            PermissionIndicatorIcon(size: size, color: claudeOrange)
        
        case .waitingForInput:
            ReadyForInputIndicatorIcon(size: size, color: .green)
        
        case .toolFailed:
            FailedIndicatorIcon(size: size)
        
        case .error:
            ErrorIndicatorIcon(size: size)
        
        case .idle, .ended, .stopPending:
            SleepIcon(size: size, color: .white.opacity(0.4))
        }
    }
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/Views/AIStatusAnimationView.swift
git commit -m "feat(ui): add toolFailed and error status animations"
```

---

## Task 4: 新建 ToolInputFormatter 工具输入格式化器

**Files:**
- Create: `boringNotch/AI/Views/ToolInputFormatter.swift`

- [ ] **Step 1: 创建格式化器文件**

```swift
import Foundation
import SwiftUI

/// Format tool input for display in Session Row second line.
/// Different tools have different display strategies.
enum ToolInputFormatter {
    /// Format tool name + input for second line display.
    /// Returns (displayText, truncateStrategy)
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
```

- [ ] **Step 2: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 3: 提交**

```bash
git add boringNotch/AI/Views/ToolInputFormatter.swift
git commit -m "feat(ui): add ToolInputFormatter for second line display"
```

---

## Task 5: SessionRow 子 agent 角标 + 工具输入展示

**Files:**
- Modify: `boringNotch/AI/Views/SessionRow.swift`

- [ ] **Step 1: 更新第一行项目名展示**

将 `projectName` 计算属性改为包含子 agent 角标：

```swift
    private var projectName: String {
        guard let cwd = session.cwd else { return "Claude Code" }
        let parts = cwd.split(separator: "/")
        let baseName = parts.last.map(String.init) ?? "Claude Code"
        
        // Add subagent count badge if > 0
        if session.subagentCount > 0 {
            return "\(baseName) [\(session.subagentCount)]"
        }
        return baseName
    }
```

- [ ] **Step 2: 更新第二行展示使用 ToolInputFormatter**

将 `secondLineText` 和 `secondLineColor` 计算属性改为：

```swift
    private var secondLineDisplay: (text: String, color: Color) {
        ToolInputFormatter.format(
            tool: session.currentTool ?? "",
            input: session.permissionRequest?.toolInput,
            phase: session.phase
        )
    }
    
    private var secondLineText: String {
        secondLineDisplay.text
    }
    
    private var secondLineColor: Color {
        secondLineDisplay.color
    }
```

- [ ] **Step 3: 更新状态指示器**

将 `statusIndicator` 计算属性改为：

```swift
    @ViewBuilder
    private var statusIndicator: some View {
        switch session.phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
        case .waitingForApproval:
            PermissionIndicatorIcon(size: 16, color: claudeOrange)
        case .waitingForInput:
            ReadyForInputIndicatorIcon(size: 16, color: .green)
        case .toolFailed:
            FailedIndicatorIcon(size: 16)
        case .error:
            ErrorIndicatorIcon(size: 16)
        case .idle, .ended, .stopPending:
            SleepIcon(size: 16, color: .white.opacity(0.4))
        }
    }
```

- [ ] **Step 4: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/Views/SessionRow.swift
git commit -m "feat(ui): add subagent badge and tool input display in SessionRow"
```

---

## Task 6: AILiveActivity 紧凑态 Session 数量角标

**Files:**
- Modify: `boringNotch/AI/Views/AILiveActivity.swift`

- [ ] **Step 1: 添加 Session 数量角标组件**

在文件末尾添加：

```swift
// MARK: - Session Count Badge
struct SessionCountBadge: View {
    let count: Int
    let size: CGFloat
    
    init(count: Int, size: CGFloat = 14) {
        self.count = count
        self.size = size
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.2))
                .frame(width: size * 0.6, height: size * 0.6)
            
            Text("\(count)")
                .font(.system(size: size * 0.35, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 2: 在 AIOnlyLiveActivity 中添加角标**

更新 `AIOnlyLiveActivity` 的左侧蟹图标部分：

```swift
            // Left: AI icon - use highest priority session's status
            ZStack(alignment: .topLeading) {
                if let session = displaySession {
                    SessionStatusIcon(phase: session.phase, size: iconSize)
                        .frame(width: iconSize, height: iconSize)
                } else {
                    SleepIcon(size: iconSize, color: .white.opacity(0.4))
                        .frame(width: iconSize, height: iconSize)
                }
                
                // Session count badge (only when multiple sessions)
                if aiManager.sessions.count > 1 {
                    SessionCountBadge(count: aiManager.sessions.count, size: iconSize)
                        .offset(x: iconSize * 0.15, y: -iconSize * 0.15)
                }
            }
            .frame(width: iconSize, height: iconSize)
```

- [ ] **Step 3: 同样更新 DualLiveActivity**

在 `DualLiveActivity` 中同样更新左侧 AI 图标部分。

- [ ] **Step 4: 验证编译**

运行：`xcodebuild -scheme boringNotch -configuration Debug build 2>&1 | tail -20`
预期：BUILD SUCCEEDED

- [ ] **Step 5: 提交**

```bash
git add boringNotch/AI/Views/AILiveActivity.swift
git commit -m "feat(ui): add session count badge to compact mode"
```

---

## Task 7: 验证 UI 改进

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用**

运行：`open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app`

- [ ] **Step 2: Session 数量角标验证**

启动 2 个 Claude session，观察紧凑态左侧蟹图标右上角是否显示 `[2]` 角标

- [ ] **Step 3: 子 agent 角标验证**

启动子 agent（如 Plan 模式），观察展开态 Session Row 第一行是否显示 `[n]` 角标

- [ ] **Step 4: 工具输入展示验证**

执行不同工具命令，观察第二行显示：
- Bash: 显示命令前 30 字符
- Read/Write: 显示文件名
- Agent: 显示 description

- [ ] **Step 5: 错误状态验证**

执行失败命令，观察 Session Row 第二行是否红色显示

- [ ] **Step 6: Sleep 动画颜色验证**

观察 Sleep 动画（white.opacity(0.4)) 是否清晰可见

- [ ] **Step 7: 提交验证结果**

```bash
git add -A
git commit -m "test: phase 3 UI improvements verification passed"
```

---

## 完成标记

- [ ] Phase 3 实施完成，所有测试通过
- [ ] 代码已提交到 ai-integration 分支