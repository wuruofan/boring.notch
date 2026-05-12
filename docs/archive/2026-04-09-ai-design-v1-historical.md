# BoringNotch AI 集成设计文档

- **版本**: 1.0 (历史版本)
- **日期**: 2026-04-09
- **状态**: ⚠️ 已过时 - 部分假设已被推翻

> **注意**: 这是早期设计文档，包含一些不准确的假设（如 stdin 注入方案）。
> 实际实现方案请参考 `2026-04-10-ai-research.md`。
> 本文档仅作为设计演进历史参考保留。

---

## 1. 背景与目标

### 1.1 当前痛点

| 产品 | 问题 |
|------|------|
| BoringNotch | 音乐功能完善，但缺乏 AI Agent 状态感知 |
| Claude Island | 支持 AI 双向交互，但无音乐功能，无 Peek 机制 |
| CodeIsland | 支持多 AI 工具，但无音乐，无 Live Activity |

### 1.2 设计目标

融合 BoringNotch 的音乐 Live Activity 与 Claude Island 的双向 AI 通信，实现：

- 收起态同时显示音乐和 AI 状态（双实况胶囊）
- AI 请求时无需跳转终端即可 approve/deny/reply
- 支持多 Agent（Claude, Codex, Cursor 等）

---

## 2. 架构概述

### 2.1 系统架构图

```
┌─────────────────────────────────────┐
│  BoringNotch (SwiftUI + AppKit)     │
│  ├─ Music Module (现有)             │
│  ├─ AI Module (新增)                │
│  │   ├─ SocketServer               │
│  │   ├─ AgentManager               │
│  │   └─ AIActivityView             │
│  └─ Peek Coordinator               │
└──────────────┬──────────────────────┘
               │ Unix Socket
┌──────────────▼──────────────────────┐
│  Event Bus                          │
│  /tmp/boringnotch-ai.sock          │
└──────────────┬──────────────────────┘
               │
    ┌──────────┼──────────┬──────────┐
    │          │          │          │
┌───▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───┐
│ Claude │ │ Codex │ │ Cursor│ │ Other │
│ Hook   │ │ Hook  │ │Plugin │ │Wrapper│
└────────┘ └───────┘ └───────┘ └───────┘
```

### 2.2 通信模式

| 属性 | 值 |
|------|-----|
| 方向 | 双向（Bidirectional） |
| 协议 | Unix Domain Socket (Stream) |
| 数据格式 | JSON Lines（每行一个 JSON 对象） |
| 端口 | /tmp/boringnotch-.sock |

---

## 3. UI/UX 设计

### 3.1 收起态（Compact Mode）

借鉴鸿蒙双实况胶囊设计，药丸分为左右两个热区：

**布局结构**

```
┌─────────────────────────────┐
│ [🎵] [🤖] 〰️ [⋮] │
│ 音乐 Agent 动画 菜单 │
└─────────────────────────────┘
```

**左侧图标区（40x40 each）**

- 音乐图标: 专辑封面圆角，暂停时 50% 透明度
- Agent 图标: Pixel-art 风格，根据工具类型变色

| Agent | 颜色 | 图标 |
|-------|------|------|
| Claude | 橙色 | ☀️ |
| Codex | 蓝色 | ☁️ |
| Cursor | 黑色 | ▶️ |
| 通用 | - | 🤖 |

**右侧动画区**

- 音乐播放: 频谱条动画（BoringNotch 现有）
- AI Thinking: 脉冲光点或打字机闪烁
- 两者同时: 左右分栏显示（空间不足时轮播）

**交互**

- Hover 左侧音乐图标 → 展开音乐面板
- Hover 左侧 Agent 图标 → 展开 AI 面板
- Hover 中间动画区 → 展开双卡片视图

### 3.2 展开态（Expanded Mode）

#### 模式 A: 双卡片并列（默认）

适用于同时查看音乐和 AI:

```
┌─────────────────────────────┐
│ 🎵 The Moment - 孙燕姿        │
│ 00:39 ━━●━━━━━━ 04:13       │
│ ⏮ ⏸ ⏭ ❤️                  │
├─────────────────────────────┤
│ 🤖 Claude                    │
│ > 正在分析代码结构…          │
│ [Abort] [View Log]          │
└─────────────────────────────┘
```

- 点击上卡片 → 音乐面板全屏展开
- 点击下卡片 → AI 面板全屏展开（带输入框）

#### 模式 B: AI 回复模式（Input Request）

当 AI 需要输入时，AI 卡片扩展出输入区:

```
┌─────────────────────────────┐
│ 🎵 The Moment (playing)     │ ← 压缩显示
├─────────────────────────────┤
│ 🤖 Claude asks:             │
│ "请解释这个函数的作用"       │
│ ┌───────────────────────┐   │
│ │ [输入框… ]             │   │
│ └───────────────────────┘   │
│ [Cancel] [Send]             │
└─────────────────────────────┘
```

**输入框特性**

- 自动聚焦
- Return 发送，Esc 取消
- 支持多行（Shift+Return）

#### 模式 C: 权限请求（Permission Request）

```
┌─────────────────────────────┐
│ 🎵 The Moment (playing)     │
├─────────────────────────────┤
│ 🤖 Claude requests:          │
│ Edit file main.swift?       │
│                             │
│ [Deny] [Approve Once]       │
│ [Approve Session]           │
└─────────────────────────────┘
```

**按钮说明**

| 按钮 | 行为 |
|------|------|
| Deny | 拒绝本次请求 |
| Approve Once | 仅批准本次 |
| Approve Session | 批准当前会话的所有同类请求 |

### 3.3 Peek（Live Activity）行为

Peek 是 BoringNotch 的核心体验，AI 事件应遵循相同逻辑:

**触发条件与持续时间**

| 事件类型 | Peek 内容 | 持续时间 |
|----------|-----------|----------|
| 切歌 | 歌曲名+封面+进度 | 3秒 |
| AI Tool Request | Agent图标+"需要授权" | 常驻 |
| AI Input Request | Agent图标+"等待输入" | 常驻 |
| AI Thinking 开始 | Agent图标+脉冲动画 | 思考期间 |
| AI Thinking 结束 | 成功/失败图标+摘要 | 2秒 |
| AI Error | 红色警告图标+错误信息 | 5秒 |

**多事件并发处理**

- 音乐 Peek + AI Peek → 上下双卡片 Peek
- AI 请求是阻塞性的，常驻直到操作
- 音乐是非阻塞性的，3 秒后自动收起
- Hover 任意位置 → 从 Peek 平滑过渡到展开态

---

## 4. 技术实现

### 4.1 IPC 协议设计

**事件流向**

1. AI Tool → Hook → Socket → BoringNotch（上行）
2. BoringNotch → Socket → Hook → AI Tool（下行）

**上行事件（AI → Notch）**

```json
{
  "source": "claude-code",
  "session_id": "uuid-v4-string",
  "event_type": "thinking|tool_call|permission_request|input_request|completed|error",
  "timestamp": 1699123456,
  "data": {
    // 根据 event_type 变化
  }
}
```

**event_type 详情**

| event_type | 说明 | UI 表现 |
|-------------|------|---------|
| thinking | AI 正在思考 | 显示脉冲动画 |
| tool_call | 正在调用工具 | 显示工具图标 |
| permission_request | 需要用户批准 | 展开 Peek 常驻 |
| input_request | 需要用户输入 | 展开输入框 |
| completed | 任务完成 | 显示摘要后消失 |
| error | 发生错误 | 红色提示 |

**下行事件（Notch → AI）**

```json
{
  "target": "claude-code",
  "session_id": "uuid-v4-string",
  "action_type": "approve|deny|reply|abort",
  "timestamp": 1699123460,
  "data": {
    "text": "用户输入的文本"
  }
}
```

### 4.2 核心模块

**SocketServer**

- 使用 CFSocket 或 Network.framework
- 监听 Unix Socket，接受多个 Agent 连接
- 上行事件转发给 AgentManager
- 下行事件通过对应连接写回

**AgentManager**

- 维护 `activeSessions: [AISession]`
- 维护 `currentRequest: AIPendingRequest?`
- 处理事件路由到 UI
- 管理回复的发送

**AISession 模型**

```swift
struct AISession {
    let id: UUID
    let source: String           // claude-code, codex, etc.
    var status: Status           // thinking | waiting | idle
    var currentTool: String?
    let startTime: Date
    
    enum Status {
        case thinking
        case waiting
        case idle
    }
}
```

### 4.3 回复机制实现

#### stdin 注入方案（适用于 Claude/Codex）

Hook 脚本作为中间层:

1. Hook 启动时创建 FIFO 文件 `/tmp/boringnotch-input-.fifo`
2. Hook 主循环读取 FIFO，写入 Claude stdin
3. BoringNotch 发送 reply 时，写入对应 FIFO
4. Claude 收到输入，继续执行

#### 伪终端方案（更 robust）

Hook 创建伪终端(PTY)，Claude 运行在 PTY 中:

- BoringNotch 通过 Socket 发送命令给 Hook
- Hook 通过 PTY master 写入命令
- Claude 在 PTY slave 中读取

#### Cursor 适配（无官方 Hook）

**方案 1: VS Code Extension**

- 开发 Cursor 插件，监听编辑器事件
- 通过 HTTP localhost 或 Socket 与 BoringNotch 通信
- 回复通过 VS Code API 执行命令

**方案 2: 进程监控（Fallback）**

- 监控 Cursor 进程，解析日志（脆弱）

**方案 3: 只读模式**

- 仅显示 Cursor 状态，回复仍需跳转到 IDE

---

## 5. 多 Agent 支持策略

### 5.1 Agent 适配器模式

**统一接口 AgentAdapter**

```swift
protocol AgentAdapter {
    func connect() throws
    func sendReply(sessionId: String, text: String) throws
    func approveTool(sessionId: String, toolCallId: String) throws
    func denyTool(sessionId: String, toolCallId: String) throws
    func abort(sessionId: String) throws
}
```

**具体实现**

| Adapter | 实现方式 |
|---------|----------|
| ClaudeAdapter | 通过 FIFO 写入 stdin |
| CodexAdapter | 类似 Claude，路径不同 |
| CursorAdapter | 通过 Extension API 或 HTTP |

### 5.2 Hook 安装策略

自动检测与安装: BoringNotch 设置面板提供 "Install AI Hooks" 按钮

**检测逻辑**

| 检测命令 | 发现工具 |
|----------|----------|
| `which claude` | Claude Code |
| `which codex` | Codex CLI |
| `ls ~/.cursor` | Cursor |
| `ls ~/.config/opencode` | OpenCode |

**安装逻辑**

对于每个检测到的工具:

1. 检查是否已安装 Hook
2. 备份原有配置
3. 复制 Hook 脚本到对应目录
4. 设置可执行权限
5. 测试 Socket 连接

**Hook 模板**

```
templates/
├── claude-hook.sh       → ~/.claude/hooks/boringnotch-hook
├── codex-hook.sh        → ~/.codex/hooks/boringnotch-hook
├── cursor-bridge.json   → VS Code Extension 配置指引
└── generic-wrapper.sh   → 包装脚本（Fallback）
```

### 5.3 配置文件

`~/.boringnotch/agents.conf`

```json
{
  "agents": [
    {
      "id": "claude-code",
      "name": "Claude",
      "enabled": true,
      "supports_reply": true,
      "hook_type": "official",
      "icon": "claude",
      "hook_path": "~/.claude/hooks/boringnotch-hook"
    },
    {
      "id": "codex",
      "name": "Codex",
      "enabled": true,
      "supports_reply": true,
      "hook_type": "official",
      "icon": "codex",
      "hook_path": "~/.codex/hooks/boringnotch-hook"
    },
    {
      "id": "cursor",
      "name": "Cursor",
      "enabled": false,
      "supports_reply": false,
      "hook_type": "extension",
      "icon": "cursor",
      "note": "Requires manual extension installation"
    }
  ]
}
```

---

## 6. 实现路线图

### Phase 1: 基础通信（Week 1-2）

- [ ] 实现 SocketServer（Unix Domain Socket）
- [ ] 移植 Claude Island 的 Hook 脚本
- [ ] 实现单向接收（Claude → Notch）
- [ ] UI: 基础 AI 状态显示（thinking 动画）

### Phase 2: 双向交互（Week 3-4）

- [ ] 实现 stdin 注入（FIFO 方案）
- [ ] 添加 approve/deny 按钮
- [ ] 添加输入框和 reply 功能
- [ ] UI: 权限请求和输入框界面

### Phase 3: 双实况 UI（Week 5-6）

- [ ] 重构 Compact 视图，支持双图标
- [ ] 实现 Peek 双卡片并列显示
- [ ] 音乐与 AI 状态同时显示
- [ ] 动画过渡优化

### Phase 4: 多 Agent 支持（Week 7-8）

- [ ] 抽象 AgentAdapter 接口
- [ ] 添加 Codex 支持
- [ ] Cursor 基础支持（只读）
- [ ] Hook 自动安装器

### Phase 5: Polish（Week 9+）

- [ ] 声音效果（Claude Island 的 8-bit 音效）
- [ ] 设置面板重构
- [ ] 错误处理和重连机制
- [ ] 文档和测试

---

## 7. 风险与备选方案

### 风险 1: BoringNotch 架构耦合

| 项目 | 说明 |
|------|------|
| 风险 | BoringNotch 是单体应用，添加异步 Socket 可能破坏响应式数据流 |
| 缓解 | 使用 Combine 框架，将 AI 状态封装为 ObservableObject |

### 风险 2: stdin 注入不稳定

| 项目 | 说明 |
|------|------|
| 风险 | 不同终端模拟器（iTerm, Terminal, Warp）对 stdin 注入支持不同 |
| 缓解 | 优先支持 iTerm2（AppleScript 控制成熟），其他终端降级为"跳转打开" |

### 风险 3: Cursor 无官方 Hook

| 项目 | 说明 |
|------|------|
| 风险 | Cursor 不支持 CLI Hook，Extension API 可能受限 |
| 缓解 | Phase 1 只支持 Claude，Cursor 作为后续增强 |

### 备选方案

如果 BoringNotch 改造困难:

- 转向 Atoll（BoringNotch 的 GPL 分支，代码结构相似但可能更模块化）
- 或基于 CodeIsland 重构 UI，添加 Peek 和音乐功能（工作量大但架构干净）

---

## 8. 附录

### A. 事件类型详细定义

**thinking 事件**

```json
{
  "source": "claude-code",
  "session_id": "abc-123",
  "event_type": "thinking",
  "data": {
    "message": "Analyzing codebase…"
  }
}
```

**permission_request 事件**

```json
{
  "source": "claude-code",
  "session_id": "abc-123",
  "event_type": "permission_request",
  "data": {
    "request_id": "req-456",
    "tool": "Bash",
    "command": "rm -rf /tmp/*",
    "description": "Remove temporary files"
  }
}
```

**input_request 事件**

```json
{
  "source": "claude-code",
  "session_id": "abc-123",
  "event_type": "input_request",
  "data": {
    "prompt": "Please describe the function:",
    "multiline": true
  }
}
```

### B. 文件结构

```
BoringNotch/
├── boringNotch/
│   ├── Music/ (现有)
│   ├── AI/ (新增)
│   │   ├── SocketServer.swift
│   │   ├── AgentManager.swift
│   │   ├── AgentAdapter.swift
│   │   ├── ClaudeAdapter.swift
│   │   ├── Models/
│   │   │   ├── AIEvent.swift
│   │   │   ├── AISession.swift
│   │   │   └── AIPendingRequest.swift
│   │   └── Views/
│   │       ├── AICompactView.swift (收起态图标)
│   │       ├── AIExpandedView.swift (展开态卡片)
│   │       ├── AIInputView.swift (输入框)
│   │       ├── AIPermissionView.swift (权限按钮)
│   │       └── AIThinkingView.swift (动画)
│   ├── Peek/ (修改)
│   │   └── PeekCoordinator.swift (支持 AI 事件)
│   └── Settings/
│       └── AISettingsView.swift
└── Hooks/ (新增)
    ├── install.sh
    ├── claude-hook.sh
    └── codex-hook.sh
```

---

## 结语

本设计文档确立了"以 BoringNotch 为基础，集成 AI 双向通信"的技术路线。核心创新点是双实况胶囊 UI（借鉴鸿蒙）和统一的多 Agent 适配架构。实施应分阶段进行，先确保 Claude Code 的完整体验，再扩展到其他工具。
