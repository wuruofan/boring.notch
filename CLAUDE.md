# BoringNotch 项目上下文

## 项目概述

BoringNotch 是一个 macOS 应用，在 MacBook 刘海区域显示音乐播放状态、日历、电池等信息。正在开发 AI Agent 状态感知功能（集成 Claude Code/Codex 状态显示和双向交互）。

## 项目结构

```
boringNotch/
├── boringNotchApp.swift        # 应用入口、AppDelegate
├── BoringViewCoordinator.swift # 视图协调器（核心状态管理、Peek/Expand）
├── ContentView.swift           # 主视图容器（Compact/Expanded 渲染）
├── models/
│   ├── BoringViewModel.swift   # 窗口级状态（手势、拖放）
│   ├── PlaybackState.swift     # 音乐播放状态
│   └── Constants.swift         # Defaults Keys 定义
├── managers/
│   ├── MusicManager.swift      # 音乐状态聚合、控制器切换
│   └── VolumeManager.swift     # 音量控制
├── MediaControllers/           # 媒体控制器协议实现
├── components/
│   ├── Notch/                  # Notch 核心 UI
│   ├── Music/                  # 音乐相关 UI
│   ├── Live activities/        # Live Activity UI
│   └── Settings/               # 设置界面
└── observers/                  # MediaKeyInterceptor 等
```

## 关键架构

### Peek 机制（BoringViewCoordinator）

```swift
enum SneakContentType {
    case brightness, volume, backlight, music, mic, battery, download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

func toggleSneakPeek(status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, ...)
```

### 音乐状态管理（MusicManager）

- ObservableObject + Combine Publisher
- MediaControllerProtocol 多控制器抽象
- 支持 Apple Music、Spotify、YouTube Music

### 状态管理层次

1. **全局层**: BoringViewCoordinator.shared（跨窗口共享）
2. **窗口层**: BoringViewModel（每窗口实例）
3. **业务层**: MusicManager、VolumeManager

## AI 集成设计

详见 `docs/ai-integration-design.md`，目标是：

- 收起态同时显示音乐和 AI 状态（双实况胶囊）
- AI 请求时无需跳转终端即可 approve/deny/reply
- 支持多 Agent（Claude, Codex, Cursor 等）

## 参考实现：Claude-Island

**路径**: `/Users/wuruofan/mine/rfw/claude-island/`

Claude-Island 已实现 Claude Code 状态监控和权限审批，关键技术：

### Hook ↔ Session 通信机制（完整架构）

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Claude Code Hook 事件流                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Claude Code                        Hook 脚本                        App │
│  ┌──────────┐                       ┌──────────┐                    ┌───┐│
│  │ Hook 触发 │ ──stdin JSON──>       │ 解析事件 │ ──socket──>       │   ││
│  │ (事件)   │                        │ 构造状态 │                    │UI ││
│  └──────────┘                       └──────────┘                    └───┘│
│                                                                          │
│  Claude Code                        JSONL 文件                       App │
│  ┌──────────┐                       ┌──────────┐                    ┌───┐│
│  │ 写入状态 │ ──文件追加──>          │ 文件监听 │ ──中断事件──>      │   ││
│  │ (JSONL)  │                        │ (实时)   │                    │UI ││
│  └──────────┘                       └──────────┘                    └───┘│
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 两种 DispatchSource 监听机制

| 监听类型        | 目标                         | DispatchSource                   | 用途           |
| --------------- | ---------------------------- | -------------------------------- | -------------- |
| **Socket 监听** | `/tmp/*.sock`                | `DispatchSourceRead`             | 接收 hook 事件 |
| **JSONL 监听**  | `~/.claude/projects/*.jsonl` | `DispatchSourceFileSystemObject` | 检测 ESC 中断  |

**Socket 监听实现**（参考 `AIHookServerCore.swift`）：

```swift
// 监听 Unix Socket 新连接
acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
acceptSource?.setEventHandler { self?.acceptConnection() }
acceptSource?.resume()
```

**JSONL 监听实现**（参考 Claude-Island `JSONLInterruptWatcher.swift`）：

```swift
// 监听文件写入事件（实时检测 ESC 中断）
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend],  // 文件追加时触发
    queue: queue
)
source.setEventHandler { self?.checkForInterrupt() }
source.resume()
```

### 中断检测（JSONLInterruptWatcher）

**文件**: `ClaudeIsland/Services/Session/JSONLInterruptWatcher.swift`

当 session 进入 `processing` 状态时启动监听 JSONL 文件，检测中断模式：

```swift
// 中断内容模式
private static let interruptContentPatterns = [
    "Interrupted by user",
    "[Request interrupted by user]",
    "\"interrupted\":true"
]
```

**优势**：

- **毫秒级响应**（文件系统事件实时触发）
- **不影响长任务**（只监听文件，不超时判断）
- **精确检测**（匹配具体中断内容）

### Hook 机制

- Python 脚本 `claude-island-state.py` 安装到 `~/.claude/hooks/`
- 通过 Unix Socket `/tmp/claude-island.sock` 发送 JSON 事件
- 权限请求时保持连接等待响应（双向通信）

### SocketServer 实现

**文件**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`

```swift
struct HookEvent: Codable {
    let sessionId: String
    let cwd: String
    let event: String      // PreToolUse, PostToolUse, PermissionRequest, etc.
    let status: String     // waiting_for_approval, running_tool, processing
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
}

struct HookResponse: Codable {
    let decision: String   // "allow", "deny", "ask"
    let reason: String?
}
```

### 回复机制（重要发现）

**Claude-Island 使用 tmux send-keys，不是 FIFO！**

**文件**: `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`

```swift
func approveOnce(target: TmuxTarget) async -> Bool {
    await sendKeys(to: target, keys: "1", pressEnter: true)
}

func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
    await sendKeys(to: target, keys: "n", pressEnter: true)
}
```

**限制**: 仅支持 tmux 环境，非 tmux 终端无法发送回复。

### HookInstaller 自动安装

**文件**: `ClaudeIsland/Services/Hooks/HookInstaller.swift`

- 首次启动自动将 Python 脚本复制到 `~/.claude/hooks/`
- 更新 `~/.claude/settings.json` 注册 hook 事件

### Python Hook 脚本核心逻辑

```python
# PermissionRequest 双向通信
if state.get("status") == "waiting_for_approval":
    response = sock.recv(4096)  # 等待决策
    if response:
        decision = json.loads(response.decode()).get("decision")
        if decision == "allow":
            print(json.dumps({"hookSpecificOutput": {...}}))
            sys.exit(0)
```

### Session 状态模型

**文件**: `ClaudeIsland/Models/SessionState.swift`

```swift
struct SessionState {
    let sessionId: String
    let cwd: String
    var phase: SessionPhase  // idle, processing, waitingForApproval, waitingForInput
    var chatItems: [ChatHistoryItem]
    var toolTracker: ToolTracker
}
```

## 技术栈

- SwiftUI + AppKit
- Combine（响应式状态管理）
- Swift Concurrency（async/await, Task）
- Defaults（第三方库，配置存储）
- XPC Helper（权限处理）

## 开发命令

```bash
# 构建
xcodebuild -scheme boringNotch -configuration Debug build

# 运行测试（如有）
xcodebuild test -scheme boringNotch
```

## 应用重启（重要）

由于 macOS 进程管理特殊性，`killall` 经常失败。**可靠的重启方法：**

```bash
# 方法 1：用户手动退出后启动
# 让用户手动退出应用（Dock 或菜单栏），然后：
open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app

# 方法 2：强制 kill 进程组
pkill -9 -f "boringNotch.app/Contents/MacOS"
sleep 2
open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app

# 方法 3：AppleScript 优雅退出
osascript -e 'quit app "boringNotch"'
sleep 2
open <app路径>
```

**失败原因：**

- `killall` 需精确匹配进程名（大小写敏感）
- BoringNotch 有子进程守护（XPC Helper）
- DerivedData 路径可能变化

## Progress Tracking (Critical)

- Before commit: Call `/progress-save` to update PROGRESS.md
- When resuming work: Call `/progress-restore` to restore session context
- When major task completed: Call `/progress-archive` to archive history
- Before new session: Call `/progress-summary` to get session context
