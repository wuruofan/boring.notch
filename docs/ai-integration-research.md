# BoringNotch AI 集成调研笔记

- **创建日期**: 2026-04-10
- **最后更新**: 2026-04-10
- **状态**: 调研中

---

## 1. 理解程度总览

### 评分标准

| 等级 | 含义 |
|------|------|
| ✅ 80%+ | 完全理解，可直接实现 |
| ⚠️ 50-70% | 基本理解，需要少量调试 |
| ❌ < 50% | 理解不足，需要深入研究 |
| ❓ 未验证 | 代码理解但未实际运行测试 |

### 模块理解矩阵

| 模块 | 理解度 | 可实现性 | 备注 |
|------|--------|----------|------|
| BoringNotch 状态管理 | ✅ 85% | 高 | ObservableObject + Combine |
| Peek 机制 | ✅ 80% | 高 | toggleSneakPeek、时序控制 |
| Compact 视图渲染 | ✅ 80% | 高 | 改造方案已确定（单胶囊+内部分区） |
| Expanded 视图 | ✅ 80% | 高 | AI展开态设计已确认（双卡片独立区域） |
| Claude-Island Hook 机制 | ✅ 90% | 高 | 代码完整可移植 |
| Claude-Island 回复机制 | ✅ 85% | 高 | tmux send-keys 方案 |
| SocketServer 实现 | ✅ 90% | 高 | GCD DispatchSource |
| 应用启动流程 | ✅ 80% | 高 | 已完整阅读 |
| Settings 系统 | ✅ 75% | 高 | Defaults 库使用方式已理解 |
| 动画系统 | ✅ 75% | 高 | matchedGeometryEffect、transition |
| 多显示器支持 | ⚠️ 60% | 中 | 每显示器独立 ViewModel |

---

## 2. BoringNotch 架构分析

### 2.1 核心文件

| 文件 | 职责 | 理解度 |
|------|------|--------|
| `boringNotchApp.swift` | 应用入口、窗口管理、生命周期 | ✅ 80% |
| `BoringViewCoordinator.swift` | 全局视图状态、Peek/Expand 管理 | ✅ 85% |
| `ContentView.swift` | 主视图、Compact/Expanded 渲染 | ✅ 75% |
| `BoringViewModel.swift` | 窗口级状态、手势、拖放 | ⚠️ 60% |
| `MusicManager.swift` | 音乐状态聚合、控制器切换 | ⚠️ 65% |
| `Constants.swift` | Defaults Keys 定义 | ✅ 80% |
| `SettingsView.swift` | 设置界面 | ✅ 70% |

### 2.2 应用启动流程

**核心代码位置**: `boringNotchApp.swift`

```
@main
DynamicNotchApp
    ↓
AppDelegate.applicationDidFinishLaunching
    ├── 监听屏幕变化通知
    ├── 监听锁屏/解锁事件
    ├── 注册键盘快捷键
    ├── 创建窗口 (createBoringNotchWindow)
    │   ├── BoringNotchSkyLightWindow (支持锁屏显示)
    │   ├── NSHostingView(rootView: ContentView())
    │   └── 添加到 NotchSpaceManager
    └── 设置 DragDetector
```

**关键发现**:

1. **窗口类型**: `BoringNotchSkyLightWindow` - 特殊窗口类，支持锁屏显示
2. **多显示器**: 支持两种模式
   - `showOnAllDisplays = true`: 每个显示器一个窗口，独立 `BoringViewModel`
   - `showOnAllDisplays = false`: 单窗口，可通过 `preferredScreenUUID` 选择显示器
3. **窗口存储**: `windows: [String: NSWindow]` (UUID → NSWindow)

**SocketServer 初始化时机**:
```swift
// 推荐：在 AppDelegate.applicationDidFinishLaunching 中启动
func applicationDidFinishLaunching(_ notification: Notification) {
    // 现有初始化代码...
    
    // 添加 AI Hook Server 启动
    AIHookServer.shared.start()
    AIHookInstaller.installIfNeeded()
}
```

**理解度**: ✅ 80%

### 2.3 状态管理层次

```
┌─────────────────────────────────────────┐
│ 全局层 (单例，跨窗口共享)                │
│ - BoringViewCoordinator.shared          │
│   - currentView, sneakPeek, expandingView│
│ - MusicManager.shared                   │
│   - songTitle, isPlaying, albumArt...   │
│ - [待添加] AIManager.shared             │
│   - sessions, currentPhase, isActive    │
└─────────────────────────────────────────┘
         ↓ Combine Publisher
┌─────────────────────────────────────────┐
│ 窗口层 (每窗口实例)                      │
│ - BoringViewModel                       │
│   - notchState, notchSize, hideOnClosed │
│   - screenUUID (多显示器时区分)         │
└─────────────────────────────────────────┘
```

**理解度**: ✅ 80%

**实现要点**:
- AI 需要新建 `AIManager.shared` 单例
- 遵循 ObservableObject + @Published 模式
- 窗口状态通过 `screenUUID` 关联到特定显示器

### 2.4 Peek 机制详解

**核心代码位置**: `BoringViewCoordinator.swift:208-260`

```swift
enum SneakContentType {
    case brightness, volume, backlight, music, mic, battery, download
    // 需要添加: case ai
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    // 需要添加: var persistent: Bool = false  // AI 请求需要常驻
}

func toggleSneakPeek(status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, ...)
```

**时序机制**:
- 默认持续时间: 1.5s
- 音乐切歌: 3s（通过 duration 参数传递）
- 自动隐藏: 在 `sneakPeek` 的 `didSet` 中触发 `scheduleSneakPeekHide`

**理解度**: ✅ 80%

**改造要点**:
1. 添加 `SneakContentType.ai`
2. 添加 `persistent` 标志，AI 请求时设为 true 跳过自动隐藏
3. AI 事件触发 `toggleSneakPeek(status: true, type: .ai, persistent: true)`

### 2.5 Compact 视图渲染逻辑

**核心代码位置**: `ContentView.swift:260-338`

**当前渲染优先级（互斥）**:
```swift
if coordinator.expandingView.type == .battery && coordinator.expandingView.show {
    // 1. 电池通知
} else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) {
    // 2. InlineHUD (volume/brightness/mic)
} else if musicManager.isPlaying && coordinator.musicLiveActivityEnabled {
    // 3. MusicLiveActivity ← 音乐
} else if !musicManager.isPlaying && Defaults[.showNotHumanFace] {
    // 4. BoringFaceAnimation
} else {
    // 5. 空白
}
```

**MusicLiveActivity 结构**:
```swift
HStack {
    // 左: 专辑封面 (20x20)
    Image(nsImage: musicManager.albumArt).frame(width: height-12, height: height-12)
    // 中: 黑色间隔
    Rectangle().fill(.black).frame(width: closedNotchSize.width - 20)
    // 右: 频谱动画 (20x20)
    AudioSpectrumView().frame(width: height-12, height: height-12)
}
```

**理解度**: ✅ 80%（已确定改造方案）

---

#### Compact 改造方案（已确认）

**设计原则**:
- 音乐单独激活：保持 BoringNotch 原有实现（不变）
- AI单独激活：新建类似样式，复用动画参数
- 双激活：胶囊宽度扩展，AI元素从两侧入场

**布局结构**:

```
音乐单独（原样式不变）：
┌────────────────────────────────────┐
│ [封面]     Spacer      [波形]     │
└────────────────────────────────────┘
宽度: ~120px

AI单独：
┌────────────────────────────────────┐
│ [🤖]      Spacer      [动画]      │
└────────────────────────────────────┘
宽度: ~120px（和音乐一样）

双激活：
┌───────────────────────────────────────────────┐
│ [🤖] │ [封面]   Spacer   [波形] │ [动画]     │
│      ↑线                          ↑线         │
└───────────────────────────────────────────────┘
宽度: ~160px（胶囊向外扩展）
高度: 32px（始终和刘海一致）
```

**实现方案**:

采用「单胶囊框架 + 内部分区」方式，无需真正两层 ZStack：

```swift
struct CompactCapsuleView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var aiManager = AIManager.shared

    let height: CGFloat = 32

    var body: some View {
        Capsule()
            .fill(.black)
            .frame(width: capsuleWidth, height: height)
            .overlay(
                HStack(spacing: 4) {
                    // AI左侧
                    if aiManager.isActive {
                        AgentIconView()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                        DividerLine()  // 1px分割线
                            .transition(.opacity)
                    }

                    // 音乐核心（封面 + 波形）
                    if musicManager.isPlaying {
                        AlbumArtView()
                        Spacer()
                        AudioSpectrumView()
                    } else if aiManager.isActive && !musicManager.isPlaying {
                        Spacer()  // AI单独时中间空白
                    }

                    // AI右侧
                    if aiManager.isActive {
                        DividerLine()
                            .transition(.opacity)
                        AIStatusAnimationView()
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 8)
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: capsuleWidth)
    }

    var capsuleWidth: CGFloat {
        let musicWidth: CGFloat = 120
        let aiExtra: CGFloat = 44  // AI图标20 + 动画20 + 分割线4

        if musicManager.isPlaying && aiManager.isActive {
            return musicWidth + aiExtra
        }
        return musicWidth
    }
}

struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 20)
    }
}
```

**过渡动画设计**:

| 状态变化 | 动画 |
|---------|------|
| 音乐单独 → 双激活 | 胶囊宽度扩展 + AI元素从两侧滑入淡入 + 分割线淡入 |
| 双激活 → 音乐单独 | AI元素淡出 + 胶囊宽度收缩 |
| 音乐单独 ↔ AI单独 | 不涉及（各自独立渲染） |

```swift
// 胶囊宽度变化
.animation(.spring(response: 0.35, dampingFraction: 0.75), value: capsuleWidth)

// AI元素入场/退场
.transition(.asymmetric(
    insertion: .opacity.combined(with: .move(edge: .leading)),
    removal: .opacity
))
```

入场顺序：
1. 胶囊宽度先扩展（约 0.15s）
2. AI图标/动画淡入滑入（约 0.25s）

退场顺序：
1. AI元素淡出（约 0.2s）
2. 胶囊宽度收缩

**交互行为**:

| 操作 | 展开内容 |
|------|----------|
| Hover 音乐图标/波形 | 音乐面板（单人展开） |
| Hover Agent图标/动画 | AI面板（单人展开） |
| Hover 刘海中间区域 | 双卡片竖直并列展开 |

### 2.6 Expanded 视图

**核心文件**: `components/Notch/NotchHomeView.swift`

**当前布局**:
```
┌─────────────────────────────────────────┐
│ BoringHeader (tabs, camera, settings)   │
├─────────────────────────────────────────┤
│ HStack:                                 │
│   MusicPlayerView | CalendarView | Camera│
└─────────────────────────────────────────┘
```

**理解度**: ✅ 80%（AI展开态设计已确认）

---

#### AI展开态设计方案（已确认）

**设计原则**：
- 音乐单独展开：保持 BoringNotch 原有样式（有顶部tabs）
- AI单独展开：全黑背景、无顶部tabs（类似Claude-Island风格）
- 双展开：两个独立卡片，中间透明间隙，各自圆角阴影

**布局结构**：

```
音乐单独展开（原样式）：
┌─────────────────────────────────────────┐
│ [🎵][📅][📷] 音乐播放器               │
│                                         │
│ 专辑封面    歌曲信息    控制按钮        │
└─────────────────────────────────────────┘
高度: ~180px

AI单独展开：
┌─────────────────────────────────────────┐
│ 🤖 Claude Code                         │ ← 全黑背景，无tabs
│ ─────────────────                      │
│ > Analyzing codebase...                │
│                                        │
│ [Abort]                                │
│                                        │
│ ┌──────────────────────────────────┐   │
│ │ 输入消息...                       │   │
│ └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
高度: 300-400px（内容自适应）

双展开（音乐+AI）：
┌─────────────────────────────────────────┐
│ [🎵][📅][📷] 音乐播放器               │ ← 音乐卡片（原样式）
│                                         │
│ 专辑封面    歌曲信息    控制按钮        │
└─────────────────────────────────────────┘
              ↑↑↑ 透明间隙 12px ↑↑↑
┌─────────────────────────────────────────┐
│ 🤖 Claude Code                         │ ← AI卡片（独立圆角矩形）
│ ─────────────────                      │
│ > Waiting for approval...              │
│                                        │
│ [Deny]              [Allow]            │
│                                        │
│ ┌──────────────────────────────────┐   │
│ │ 输入回复...                       │   │
│ └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
总高度: ~500-600px
```

**实现方案**：

```swift
// NotchHomeView.swift
enum ExpandedContentType {
    case none
    case music           // 单独音乐
    case calendar
    case camera
    case ai              // 单独AI
    case musicAndAI      // 双展开
}

var body: some View {
    switch contentType {
    case .music:
        MusicPlayerView()  // 原有实现
    case .ai:
        AIExpandedView()   // 全黑背景
    case .musicAndAI:
        VStack(spacing: 12) {
            // 音乐卡片
            MusicPlayerView()
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            // AI卡片（独立圆角矩形+阴影）
            AIExpandedView()
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .padding(.horizontal, 12)
    // ...
    }
}
```

**关键样式**：
| 元素 | 样式 |
|------|------|
| 间隙 | `spacing: 12`，透明 |
| 圆角 | `cornerRadius: 16`（卡片各自圆角）|
| 阴影 | AI卡片底部阴影，悬浮感 |
| 背景 | 各自 `.black`，视觉上分离 |

**动态高度计算**：
```swift
var expandedHeight: CGFloat {
    switch contentType {
    case .music: return 180
    case .ai: return 350  // 自适应，此为最小值
    case .musicAndAI: return 180 + 12 + 350  // 音乐 + 间隙 + AI
    default: return 32
    }
}
```

### 2.7 动画系统

**Compact ↔ Expanded 过渡**:

```swift
// 专辑封面 - matchedGeometryEffect 实现 Hero 动画
.matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)

// 频谱动画
.matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
```

**过渡动画参数**:
```swift
// 打开动画
let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)

// 关闭动画
let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

// 视图切换
.transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
.transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
```

**AI 组件需要的动画处理**:
1. 新建独立的 `@Namespace` 用于 AI 相关 Hero 动画
2. 使用 `.transition(.opacity)` 或 `.transition(.scale.combined(with: .opacity))`
3. 遵循现有的 spring 参数

**理解度**: ✅ 75%

---

## 3. Settings 系统详解

### 3.1 Defaults 库使用

**配置项定义**: `Constants.swift` → `Defaults.Keys` extension

```swift
extension Defaults.Keys {
    // 添加 AI 相关配置示例
    static let aiEnabled = Key<Bool>("aiEnabled", default: true)
    static let aiShowInNotch = Key<Bool>("aiShowInNotch", default: true)
    static let aiAutoInstallHooks = Key<Bool>("aiAutoInstallHooks", default: true)
    static let aiSelectedAgents = Key<[String]>("aiSelectedAgents", default: ["claude-code"])
}
```

**在视图中使用**:
```swift
// Toggle
Defaults.Toggle(key: .aiEnabled) {
    Text("Enable AI integration")
}

// 读取值
@Default(.aiEnabled) var aiEnabled

// 直接访问
if Defaults[.aiEnabled] { ... }
```

**理解度**: ✅ 75%

### 3.2 添加新的设置面板

**步骤**:
1. 在 `SettingsView.swift` 的 `List` 中添加 `NavigationLink`
2. 创建对应的设置视图
3. 在 `switch selectedTab` 中添加 case

**示例代码**:
```swift
// 在 List 中添加
NavigationLink(value: "AI") {
    Label("AI Agents", systemImage: "brain")
}

// 在 detail switch 中添加
case "AI":
    AISettings()
```

**新建 AISettings 视图**:
```swift
struct AISettings: View {
    @Default(.aiEnabled) var aiEnabled
    @Default(.aiAutoInstallHooks) var aiAutoInstallHooks
    
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .aiEnabled) {
                    Text("Enable AI integration")
                }
                Defaults.Toggle(key: .aiAutoInstallHooks) {
                    Text("Auto-install hooks on launch")
                }
            } header: {
                Text("General")
            }
            
            Section {
                // Agent 列表
            } header: {
                Text("Agents")
            }
        }
        .navigationTitle("AI Agents")
    }
}
```

**理解度**: ✅ 70%

---

## 4. Claude-Island 参考实现

### 4.1 项目结构

```
ClaudeIsland/
├── Services/
│   ├── Hooks/
│   │   ├── HookSocketServer.swift    ← 核心：Unix Socket 服务端
│   │   └── HookInstaller.swift       ← Hook 自动安装
│   ├── Tmux/
│   │   ├── TmuxController.swift      ← tmux 操作控制器
│   │   ├── TmuxTargetFinder.swift    ← 根据 PID 找 tmux target
│   │   └── ToolApprovalHandler.swift ← approve/deny 实现
│   └── State/
│       └── SessionStore.swift        ← Session 状态管理
├── Models/
│   ├── SessionState.swift            ← Session 数据模型
│   └── SessionPhase.swift            ← idle/processing/waitingForApproval
└── Resources/
    └── claude-island-state.py        ← Python Hook 脚本
```

**理解度**: ✅ 90%

### 4.2 Hook 通信机制

**Python Hook 脚本** (`claude-island-state.py`):

```python
SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300  # 权限决策最长等待 5 分钟

def send_event(state):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps(state).encode())

    # 权限请求时等待响应
    if state.get("status") == "waiting_for_approval":
        response = sock.recv(4096)
        return json.loads(response.decode())
```

**Hook 事件类型**:

| 事件 | 触发时机 | status |
|------|----------|--------|
| UserPromptSubmit | 用户发送消息 | processing |
| PreToolUse | 工具调用前 | running_tool |
| PostToolUse | 工具调用后 | processing |
| PermissionRequest | 需要权限批准 | waiting_for_approval |
| Notification | 通知事件 | notification/waiting_for_input |
| Stop | 停止 | waiting_for_input |
| SessionStart | 会话开始 | waiting_for_input |
| SessionEnd | 会话结束 | ended |

**理解度**: ✅ 90%

### 4.3 SocketServer 实现

**核心代码**: `HookSocketServer.swift`

```swift
class HookSocketServer {
    static let socketPath = "/tmp/claude-island.sock"

    // 启动服务端
    func start(onEvent: @escaping HookEventHandler, ...)

    // 响应权限请求
    func respondToPermission(toolUseId: String, decision: String, reason: String?)

    // 等待中的权限请求
    private var pendingPermissions: [String: PendingPermission]
}

struct HookEvent: Codable {
    let sessionId: String
    let cwd: String
    let event: String      // PreToolUse, PermissionRequest, etc.
    let status: String     // waiting_for_approval, running_tool, processing
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let pid: Int?
    let tty: String?
}
```

**关键技术点**:
1. GCD DispatchSource 实现非阻塞 I/O
2. PermissionRequest 时保持连接，等待用户决策后写入响应
3. 使用 `AnyCodable` 处理动态 JSON

**理解度**: ✅ 90%

**移植方案**: 直接复制 HookSocketServer.swift，修改 socket 路径为 `/tmp/boringnotch-ai.sock`

### 4.4 回复机制（tmux send-keys）

**核心代码**: `ToolApprovalHandler.swift`

```swift
actor ToolApprovalHandler {
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "1", pressEnter: true)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "2", pressEnter: true)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await sendKeys(to: target, keys: "n", pressEnter: true)
    }

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        // tmux send-keys -t session:window.pane -l "text"
        // tmux send-keys -t session:window.pane Enter
    }
}
```

**TmuxTarget 查找** (`TmuxTargetFinder.swift`):
1. 通过 Claude PID 找到对应的 tmux pane
2. 使用 `tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"`
3. 匹配进程树找到目标 pane

**理解度**: ✅ 85%

**限制**: 仅支持 tmux 环境，非 tmux 终端无法发送回复。

**替代方案**:
| 终端 | 方案 | 可行性 |
|------|------|--------|
| iTerm2 | AppleScript `write text` | ✅ 可实现 |
| Terminal.app | AppleScript `do script` | ✅ 可实现 |
| Warp | 无公开 API | ❌ 不可行 |
| Ghostty | 无公开 API | ❌ 不可行 |
| VS Code/Cursor | Extension API | ⚠️ 需额外开发 |

### 4.5 Hook 安装机制

**核心代码**: `HookInstaller.swift`

```swift
struct HookInstaller {
    static func installIfNeeded() {
        // 1. 复制 Python 脚本到 ~/.claude/hooks/
        // 2. 更新 ~/.claude/settings.json 注册 hook 事件
    }
}
```

**settings.json 格式**:
```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/boringnotch-ai-state.py"}]}],
    "PreToolUse": [{"matcher": "*", "hooks": [...]}],
    "PermissionRequest": [{"matcher": "*", "hooks": [...]}],
    ...
  }
}
```

**理解度**: ✅ 90%

---

## 5. 多显示器支持

### 5.1 当前实现

**配置选项**:
- `showOnAllDisplays`: 每个显示器一个 Notch 窗口
- `preferredScreenUUID`: 单窗口模式下的首选显示器
- `automaticallySwitchDisplay`: 自动切换到鼠标所在显示器

**窗口管理**:
```swift
// AppDelegate 中
var windows: [String: NSWindow] = [:]      // UUID → NSWindow
var viewModels: [String: BoringViewModel] = [:] // UUID → BoringViewModel
```

**AI 状态显示策略**:
- AI 状态应该只在**一个**显示器显示（避免混乱）
- 建议跟随 `preferredScreenUUID` 或 `selectedScreenUUID`
- 或者跟随当前活跃窗口所在的显示器

**理解度**: ⚠️ 60%

---

## 6. 待研究问题

### 6.1 已解决

| 问题 | 状态 | 结论 |
|------|------|------|
| SocketServer 初始化时机 | ✅ 已解决 | 在 `applicationDidFinishLaunching` 中启动 |
| Settings 配置项添加 | ✅ 已解决 | 在 `Defaults.Keys` extension 中添加 |
| Compact/Expanded 动画 | ✅ 已理解 | matchedGeometryEffect + spring 动画 |
| 非 tmux 终端回复方案 | ✅ 已明确 | 只支持 tmux，其他终端降级为跳转 |
| **Compact 视图布局** | ✅ 已确认 | 单胶囊框架 + 内部分区，音乐保持原样式 |
| **Expanded 视图布局** | ✅ 已确认 | 双展开为两个独立卡片，中间透明间隙 |

### 6.2 待验证

| 问题 | 影响 | 状态 |
|------|------|------|
| ~~BoringNotch 编译运行~~ | ~~开发环境验证~~ | ✅ **已验证** |
| Hook 安装后实际行为 | 集成测试 | ❌ 未验证 |
| 添加 AI 组件后的性能 | 用户体验 | ❌ 未验证 |
| ~~AI 状态多显示器策略~~ | ~~UI 设计决策~~ | ✅ **已确认** |

### 6.3 低优先级

| 问题 | 影响 | 状态 |
|------|------|------|
| Shelf 功能冲突 | 功能交互 | ❌ 未研究 |
| XPC Helper 详细用途 | 权限管理 | ⚠️ 部分理解 |

---

## 7. 技术决策记录

### 7.1 已确认方案

| 决策 | 方案 | 原因 |
|------|------|------|
| 通信协议 | Unix Domain Socket | Claude-Island 已验证可行 |
| 回复机制 | tmux send-keys（主） + 跳转终端（降级） | 跨终端统一方案 |
| 状态管理 | 新建 AIManager.shared 单例 | 遵循现有架构模式 |
| Socket 路径 | `/tmp/boringnotch-ai.sock` | 避免与 Claude-Island 冲突 |
| 配置存储 | Defaults 库 | 与现有代码一致 |
| 动画方式 | SwiftUI matchedGeometryEffect + spring | 与音乐模块一致 |
| **Compact 布局** | 单胶囊 + 内部分区 | 音乐保持原样式，AI元素从两侧入场 |
| **双展开布局** | 两个独立圆角卡片 | 中间透明间隙，各自阴影 |
| **AI单独展开** | 全黑背景，无顶部tabs | 类似Claude-Island风格 |
| **多显示器策略** | AI独立显示器设置 | 支持音乐和AI在不同显示器显示 |

### 7.2 待定方案

| 问题 | 备选方案 | 决策依据 |
|------|----------|----------|
| ~~iTerm2 AppleScript 支持~~ | ~~Phase 1 vs Phase 2~~ | ✅ **已确认：Phase 2** |

---

## 7.4 终端支持策略（已确认）


### 回复能力矩阵

| 终端类型 | 回复能力 | 当前行为 | 未来计划 |
|----------|----------|----------|----------|
| **tmux** | ✅ 完整支持 | `send-keys` 发送 approve/deny/reply | - |
| **iTerm2** | ⚠️ Phase 2 | 跳转终端（手动输入） | AppleScript `write text` |
| **Ghostty** | ❌ 不支持 | 跳转终端（手动输入） | 无公开 API |
| **Terminal.app** | ⚠️ Phase 2 | 跳转终端（手动输入） | AppleScript `do script` |
| **Warp** | ❌ 不支持 | 跳转终端（手动输入） | 无公开 API |
| **Cursor/VS Code** | ❌ 不支持 | 跳转终端（手动输入） | 需 Extension API |

### 跳转终端行为

```
用户点击 [Approve] 按钮
       ↓
执行 AppleScript：activate 终端窗口
       ↓
终端窗口获得焦点
       ↓
用户手动输入 y + Enter
```

**提示文案**：
> "请切换到终端按 y 确认" 或自动聚焦终端窗口

### 优先级理由

- 主用 Ghostty 无 AppleScript API，iTerm2 优化收益有限
- tmux 是主要使用场景（Claude Code 推荐环境）
- Phase 1 聚焦核心通信和 UI，Phase 2 再优化终端适配

---

## 7.3 多显示器策略（已确认）

### 设置项设计

在现有设置基础上，新增 AI 专属选项：

```
┌─────────────────────────────────────────┐
│ 在所有显示器上显示                    [ ] │
├─────────────────────────────────────────┤
│ Notch 首选显示器       [内建视网膜 ▼]     │
│ 自动切换显示器                        [ ] │
├─────────────────────────────────────────┤
│ AI 状态显示位置        [跟随 Notch ▼]     │  ← 新增
│                        [外接显示器 1 ▼]   │
│                        [外接显示器 2 ▼]   │
└─────────────────────────────────────────┘
```

**选项说明**：
- **跟随 Notch**：AI 状态和音乐在同一显示器（默认）
- **指定显示器**：AI 状态单独显示在选择的显示器

### 配置定义

```swift
extension Defaults.Keys {
    // 新增 AI 专用
    static let aiScreenMode = Key<AIScreenMode>("aiScreenMode", default: .followNotch)
    static let aiPreferredScreenUUID = Key<String?>("aiPreferredScreenUUID", default: nil)
}

enum AIScreenMode: String, Defaults.Serializable {
    case followNotch    // 跟随 Notch 窗口
    case separate       // 单独指定显示器
}
```

### UI 状态矩阵（完整版）

#### Compact 视图

| 场景 | 内屏 | 外屏 |
|------|------|------|
| 仅音乐 | `[封面] 刘海 [波形]` | - |
| 仅 AI | - | `[🤖] 刘海 [动画]` |
| 音乐+AI 同屏 | `[🤖]│[封面] 刘海 [波形]│[动画]` | - |
| 音乐+AI 分屏 | `[封面] 刘海 [波形]` | `[🤖] 刘海 [动画]` |

#### 展开态视图

| 场景 | 内屏 | 外屏 |
|------|------|------|
| 仅音乐 | 音乐面板（有 tabs） | - |
| 仅 AI | - | AI面板（全黑背景） |
| 音乐+AI 同屏 | 音乐卡片+间隙+AI卡片（垂直堆叠） | - |
| 音乐+AI 分屏 | 音乐面板（有 tabs） | AI面板（全黑背景） |

### AI 单独 Compact 样式

和外屏音乐保持一致，完整展示：

```swift
// 外屏 AI Compact
HStack(spacing: 0) {
    AgentIconView()           // 左侧：Agent 图标（如 Claude 橙色螃蟹）
    Spacer()                   // 中间：刘海主体
    AIStatusAnimationView()   // 右侧：AI 状态动画
}
.padding(.horizontal, 8)
.background(.black)
.clipShape(Capsule())
```

**动画效果**：
- `thinking`：脉冲光点或旋转动画
- `waitingForApproval`：橙色警告图标闪烁  
- `waitingForInput`：绿色对勾图标
- `processing`：进度条或波纹动画

---

## 8. 文件路径索引

### BoringNotch 关键文件

```
boringNotch/
├── boringNotchApp.swift              # 应用入口 ← SocketServer 初始化
├── BoringViewCoordinator.swift       # 视图协调器 ← 添加 AI Peek 支持
├── ContentView.swift                 # 主视图 ← 添加 AI Live Activity
├── models/
│   ├── BoringViewModel.swift         # 窗口状态
│   └── Constants.swift               # Defaults Keys ← 添加 AI 配置项
├── managers/
│   ├── MusicManager.swift            # 音乐管理
│   └── [新增] AIManager.swift        # AI 状态管理
├── components/
│   ├── Notch/NotchHomeView.swift     # Expanded 视图 ← 添加双展开支持
│   ├── Settings/SettingsView.swift   # 设置界面 ← 添加 AI 设置
│   └── Live activities/
│       └── InlineHUD.swift           # Peek HUD
└── [新增] AI/
    ├── AIHookServer.swift            # Socket 服务端
    ├── AIHookInstaller.swift         # Hook 安装
    ├── TmuxController.swift          # tmux 控制
    └── Views/
        ├── AILiveActivity.swift      # Compact 视图（图标+动画）
        ├── AIExpandedView.swift      # AI单独展开视图（全黑）
        ├── AICompactCapsule.swift    # 双激活时Compact胶囊
        ├── CompactCapsuleView.swift  # 统一Compact视图（音乐+AI组合）
        ├── AgentIconView.swift       # Agent图标组件
        ├── AIStatusAnimation.swift   # AI状态动画（thinking/waiting）
        ├── DividerLine.swift         # 分割线组件
        └── AISettingsView.swift      # AI设置面板
```

### Claude-Island 参考文件

```
/Users/wuruofan/mine/rfw/claude-island/ClaudeIsland/
├── Services/Hooks/
│   ├── HookSocketServer.swift        # Socket 服务端 ← 直接移植
│   └── HookInstaller.swift           # Hook 安装 ← 直接移植
├── Services/Tmux/
│   ├── TmuxController.swift          # tmux 操作
│   ├── TmuxTargetFinder.swift        # Target 查找
│   └── ToolApprovalHandler.swift     # 回复实现 ← 直接移植
├── Models/
│   └── SessionState.swift            # Session 模型
└── Resources/
    └── claude-island-state.py        # Hook 脚本 ← 直接移植
```

---

## 9. 实现路线图（更新）

### Phase 1: 基础通信（预计 3-5 天）

**目标**: 单向接收 Claude 状态，显示 thinking 动画

**任务清单**:
- [ ] 创建 `AI/` 目录结构
- [ ] 移植 `HookSocketServer.swift` → `AIHookServer.swift`
- [ ] 移植 `claude-island-state.py` → `boringnotch-ai-state.py`
- [ ] 创建 `AIManager.swift` 状态管理
- [ ] 添加 Defaults Keys（aiEnabled 等）
- [ ] 在 `AppDelegate` 中初始化 SocketServer
- [ ] 创建 `AILiveActivity.swift` 简单状态显示
- [ ] 添加 `SneakContentType.ai`
- [ ] 测试 Hook 安装和事件接收

### Phase 2: 双向交互（预计 3-5 天）

**目标**: 支持 approve/deny/reply

**任务清单**:
- [ ] 移植 `TmuxController` 相关代码
- [ ] 移植 `ToolApprovalHandler.swift`
- [ ] 实现 `AITmuxController.swift`
- [ ] 创建权限请求 UI（Approve/Deny 按钮）
- [ ] 创建输入框 UI（Reply 功能）
- [ ] 测试 tmux 环境下的回复功能

### Phase 3: 双实况 UI（预计 5-7 天）

**目标**: 音乐 + AI 同时显示

**任务清单**:
- [ ] 设计 DualLiveActivity 组件
- [ ] 重构 Compact 视图渲染逻辑
- [ ] 实现音乐和 AI 并列显示
- [ ] 处理优先级逻辑（AI 请求优先）
- [ ] 动画过渡优化

### Phase 4: 完善功能（预计 3-5 天）

**目标**: Settings、多 Agent 支持

**任务清单**:
- [ ] 创建 AI Settings 面板
- [ ] Hook 自动安装逻辑
- [ ] 多 Agent 支持（Codex 等）
- [ ] 非 tmux 终端降级方案
- [ ] 错误处理和重连机制

---

## 10. 更新日志

| 日期 | 更新内容 |
|------|----------|
| 2026-04-10 | 初始创建，完成架构分析、Claude-Island 研究、Peek 机制分析 |
| 2026-04-10 | 补充：启动流程、Settings 系统、动画系统、多显示器支持，更新理解度矩阵 |
| 2026-04-10 | 确认 Compact 改造方案（单胶囊+内部分区），确认 Expanded 双展开布局（独立卡片+透明间隙） |
| 2026-04-10 | 确认多显示器策略：AI独立显示器设置，支持音乐和AI分屏显示，完成UI状态矩阵 |
| 2026-04-10 | 确认终端支持策略：iTerm2放Phase 2，非tmux终端降级为跳转终端 |
| 2026-04-10 | **验证 BoringNotch 编译：BUILD SUCCEEDED**，开发环境就绪 |