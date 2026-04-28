# 多 Agent 支持调研

> 记录支持 Codex、OpenCode、Cursor 等 Agent 的设计思路和待调研内容。
> 创建日期：2026-04-28

---

## 一、当前架构（Claude Code 专用）

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Claude Code 专用路径                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Hook 事件通道：                                                          │
│  ├─ Hook 脚本：~/.claude/hooks/*.py                                      │
│  ├─ Socket：/tmp/boringnotch-ai.sock                                     │
│  └─ 状态文件：~/Library/Containers/.../boringnotch-ai-state-*.json      │
│                                                                          │
│  Sessions 状态通道（新发现）：                                             │
│  ├─ Sessions 文件：~/.claude/sessions/*.json                             │
│  ├─ 字段：{sessionId, status: "busy"/"idle"}                             │
│  └─ 作用：权威 idle 判断                                                  │
│                                                                          │
│  JSONL 监听通道：                                                         │
│  ├─ JSONL 文件：~/.claude/projects/<cwd>/<sessionId>.jsonl               │
│  ├─ 作用：ESC 中断检测                                                    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、待调研内容

### Codex（OpenAI）

| 项目 | 待调研 | 备注 |
|------|--------|------|
| Hook 机制 | ❓ 是否有类似 Claude Code 的 hook？ | 需查看文档 |
| Sessions 状态文件 | ❓ 是否有状态文件？路径？ | - |
| 状态字段 | ❓ status 有哪些值？ | - |
| 中断检测 | ❓ JSONL 或类似机制？ | - |

### OpenCode

| 项目 | 待调研 | 备注 |
|------|--------|------|
| Hook 机制 | ❓ | - |
| Sessions 状态文件 | ❓ | - |
| 状态字段 | ❓ | - |
| 中断检测 | ❓ | - |

### Cursor

| 项目 | 待调研 | 备注 |
|------|--------|------|
| Hook 机制 | ❓ | Cursor 有自己的 agent 系统 |
| Sessions 状态文件 | ❓ | - |
| 状态字段 | ❓ | - |
| 中断检测 | ❓ | - |

---

## 三、设计思路

### 方案 A：AgentStatusProvider 协议

```swift
protocol AgentStatusProvider {
    /// Agent 类型标识
    var agentType: AgentType { get }  // claude, codex, opencode, cursor
    
    /// Sessions 状态文件路径
    var sessionsPath: String { get }
    
    /// 解析状态文件，返回统一格式
    func parseStatus(data: Data) -> (sessionId: String, status: AgentStatus)?
}

enum AgentType: String, CaseIterable {
    case claude = "claude"
    case codex = "codex"
    case opencode = "opencode"
    case cursor = "cursor"
}

enum AgentStatus: String {
    case busy = "busy"
    case idle = "idle"
    // 其他 Agent 可能有更多状态
    case waiting = "waiting"
    case paused = "paused"
}
```

### 方案 B：配置化多路径监听

```swift
struct AgentSessionConfig {
    let agentType: AgentType
    let sessionsPath: String
    let pathPattern: String   // "*.json", "status-*.txt"
    let statusMapping: [String: AgentStatus]  // raw -> unified
}

class MultiAgentSessionsWatcher {
    let configs: [AgentSessionConfig]
    
    func start() {
        for config in configs {
            watchPath(config.sessionsPath, pattern: config.pathPattern)
        }
    }
    
    func onStatusChange(agentType: AgentType, sessionId: String, status: AgentStatus) {
        // 发送统一通知
        NotificationCenter.default.post(
            name: .AISessionStatusChanged,
            object: nil,
            userInfo: ["agentType": agentType, "sessionId": sessionId, "status": status]
        )
    }
}
```

### 方案 C：sessionId 前缀区分

```
通过 sessionId 前缀区分 Agent：
├─ claude-b350c048-...  → Claude session
├─ codex-abc123-...     → Codex session
├─ opencode-xyz789-...  → OpenCode session
└─ cursor-def456-...    → Cursor session

优点：
├─ 现有架构改动最小
├─ AIManager 无需区分 Agent 类型
└─ UI 统一显示

缺点：
├─ 需要各 Agent 的 hook 脚本配合（添加前缀）
└─ Sessions 状态文件路径不同，需要多路径监听
```

---

## 四、建议实施步骤

1. **调研阶段**
   - 查看 Codex/OpenCode/Cursor 的 hook 机制文档
   - 确认是否有状态文件、路径、字段格式
   - 记录调研结果到本文档

2. **设计阶段**
   - 根据调研结果选择方案（A/B/C）
   - 设计统一的状态模型
   - 设计多 Agent UI 显示方案

3. **实现阶段**
   - 抽象 SessionsWatcher
   - 添加多路径监听
   - 更新 AIManager 支持多 Agent

---

## 五、相关文件

| 文件 | 作用 |
|------|------|
| `docs/ai-sessions-state-watch.md` | Sessions 状态文件发现记录 |
| `docs/ai-approaches-history.md` | 方案演进历史 |
| `BoringNotchAIXPCHelper/SessionsWatcher.swift` | 当前 Claude 专用实现 |

---

## 六、待调研链接

- Codex 文档：https://github.com/openai/codex（待确认）
- OpenCode 文档：https://github.com/opencode-ai/opencode（待确认）
- Cursor Agent：https://cursor.sh/docs（待确认）