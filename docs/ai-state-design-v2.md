# AI 状态设计 V2

> 基于 Claude Code 官方 Hooks 文档（2026-04-20）重新设计状态语义
> 
> **版本**: v2.0 | **日期**: 2026-04-20

## 一、核心概念

### idle vs waitingForInput 的语义区分

| 状态 | 触发条件 | 图标 | 时间语义 |
|------|----------|------|----------|
| **waitingForInput** | Stop / idle_prompt 触发 | ✅ 对勾（绿色）或 🦀 静止蟹 | "刚完成任务，活跃等待你的输入" |
| **idle** | waitingForInput 5分钟后无新输入，或用户中断（ESC） | zZ 睡眠（浅紫色 #DDD6FE） | "等太久，睡着了" |

**核心逻辑：**
- 对勾/静止蟹 = 活跃等待（用户刚完成任务，可能马上继续）
- SleepIcon = 睡眠状态（长时间无交互，降低视觉干扰）

### 用户中断 vs 任务完成

根据官方文档，**Stop 事件**：
> "Runs when the main Claude Code agent has finished responding. Does not run if the stoppage occurred due to a user interrupt."

| 场景 | Hook 事件 | 处理方式 |
|------|----------|----------|
| **任务完成** | Stop | 显示 waitingForInput |
| **用户中断（ESC）** | 无 Hook 事件 | Darwin Notification 监听 JSONL → idle（SleepIcon） |

> ⚠️ **Trade-off 说明**：删除 stopPending 后，假设"Stop 永不触发于用户中断"。如果官方文档描述有误或未来行为变更，可能出现误判。回退方案：若发现 Stop 后立即收到 ESC 相关信号，可临时回退到 idle。

---

## 二、状态枚举定义

```swift
enum AISessionPhase: String, Codable {
    case idle                        // 睡眠状态（长时间无输入或用户中断）
    case processing                  // Claude 正在思考
    case runningTool                 // 正在执行工具
    case waitingForInput             // 任务完成，等待用户输入
    case waitingForApproval          // 权限请求待审批
    case compacting                  // 正在压缩上下文
    case ended                       // 会话已结束
    case toolFailed                  // 工具执行失败
    case error                       // API 错误
    // 删除 stopPending - 语义混淆，直接映射 Stop → waitingForInput
}
```

**关于 interrupted 状态**：不新增。理由：与 idle 视觉表现完全相同（都是 SleepIcon），只是来源不同。统一用 idle 表示"睡眠"即可。

---

## 三、isActive 语义定义

> **关键决策**：waitingForInput **不属于 isActive**

```swift
var isActive: Bool {
    self == .processing || self == .runningTool || self == .compacting
}
```

**原因**：
- isActive 用于判断"是否有正在运行的 session"
- waitingForInput 表示"任务已完成，等待输入"，不属于"正在运行"
- `activeSessionId` 只指向真正 active 的 session（processing/approval）
- waitingForInput 的 session 通过 `hasIdleSessions` 判断是否显示在 Live Activity

**显示逻辑**：
```swift
let hasIdleSessions = sessions.values.contains { 
    $0.phase == .idle || $0.phase == .waitingForInput 
}
let show = (isActive || hasIdleSessions) && Defaults[.aiShowInNotch]
```

---

## 四、SessionStart 的初始状态

SessionStart 映射到 `waitingForInput`，原因：
1. **语义一致**：会话开始后，Claude 正等待用户提交第一个 prompt
2. **视觉表现**：静止蟹或对勾表示"准备好接收输入"
3. **与 Stop 一致**：Stop 也映射到 waitingForInput，统一"等待输入"语义

> **可选调整**：如果用户希望新会话显示为 idle（SleepIcon）而非 waitingForInput，可后续修改 Hook Script 映射。

---

## 五、状态图标对照表（分视图）

### 紧凑态左侧（SessionStatusIcon）

| 状态 | 图标 | 颜色 | 动画 |
|------|------|------|------|
| **processing** | 🦀 跑动的蟹 | Claude Orange (#D9785C) | 腿部动画 |
| **runningTool** | 🦀 跑动的蟹 | Claude Orange | 腿部动画 |
| **compacting** | 🦀 跑动的蟹 | Claude Orange | 腿部动画 |
| **waitingForApproval** | ❓ 问号 | Claude Orange | 无 |
| **waitingForInput** | 🦀 静止的蟹 | Claude Orange | 无 |
| **toolFailed** | ❌ 红色感叹号 | Red | 无 |
| **error** | ✖️ 红色 X | Red | 无 |
| **idle** | 🦀 Sleeping Crab | Claude Orange + zZ 浅紫色 | zZ 透明度呼吸 |

### 紧凑态右侧 / 展开态列表（AIStatusAnimationView）

| 状态 | 图标 | 颜色 | 动画 |
|------|------|------|------|
| **processing** | ✢ 符号旋转 | Claude Orange | 旋转 |
| **runningTool** | ✢ 符号旋转 | Claude Orange | 旋转 |
| **compacting** | ✢ 符号旋转 | Claude Orange | 旋转 |
| **waitingForApproval** | ❓ 问号 | Claude Orange | 无 |
| **waitingForInput** | ✅ 对勾 | Green | 无 |
| **toolFailed** | ❌ 红色感叹号 | Red | 无 |
| **error** | ✖️ 红色 X | Red | 无 |
| **idle** | zZ 睡眠符号 | Light Purple (#DDD6FE) | 0.6~1.0 透明度呼吸 + 浮动 |

**图标不一致说明**：
- 紧凑态左侧用蟹图标系列（统一视觉风格）
- 紧凑态右侧/展开态列表用符号图标（更简洁）
- 这是**有意为之**的设计决策，不是 bug

### processing vs runningTool

两者图标相同（都是跑动的蟹/旋转符号），原因：
1. **语义接近**：都在"执行任务"中，用户无需区分
2. **简化 UI**：避免过多状态图标造成视觉混乱
3. **待改进**：未来可考虑用不同速度动画区分

---

## 六、生命周期状态流转

```
SessionStart → waitingForInput（🦀 静止蟹 / ✅ 对勾）
    ↓
UserPromptSubmit → processing（🦀 跑动 / ✢ 旋转）
    ↓
PreToolUse → runningTool（同上）
    ↓ [权限请求]
PermissionRequest → waitingForApproval（❓ 橙色）
    ↓ [用户批准]
PostToolUse → processing（🦀 跑动）
    ↓
Stop → waitingForInput（✅ 对勾 / 🦀 静止蟹）
    ↓ [5分钟无输入]
waitingForInput → idle（zZ 睡眠）

[ESC中断] → Darwin Notification → idle（zZ 睡眠）
[API错误] → StopFailure → error（✖️ 红色）
[工具失败] → PostToolUseFailure → toolFailed（❌ 红色）
```

---

## 七、Hook 事件映射表

| Hook 事件 | 文档含义 | 映射状态 | 备注 |
|----------|----------|----------|------|
| **SessionStart** | 会话开始/恢复 | waitingForInput | 准备接收用户输入 |
| **UserPromptSubmit** | 用户提交 prompt | processing | 开始处理 |
| **PreToolUse** | 工具执行前 | runningTool | 正在调用工具 |
| **PostToolUse** | 工具执行后 | processing | 继续处理 |
| **PostToolUseFailure** | 工具失败 | toolFailed | 有 `is_interrupt` 字段（暂未使用） |
| **PermissionRequest** | 权限请求 | waitingForApproval | 需用户审批 |
| **PermissionDenied** | 权限被拒 | processing | 继续处理（可能重试） |
| **Stop** | Claude 完成响应 | waitingForInput | ⚠️ 改：原为 stop_pending（AIManager 再转 idle），现直接映射 |
| **StopFailure** | API 错误 | error | rate_limit, auth_failed 等 |
| **Notification** + `idle_prompt` | Claude idle | waitingForInput | 等待用户输入 |
| **Notification** + `permission_prompt` | 权限弹窗 | 已忽略 | 正确（无需处理） |
| **Notification** + `auth_success` | 认证成功 | 不改变状态 | 可忽略 |
| **Notification** + `elicitation_dialog` | MCP 输入请求 | waitingForApproval | ⚠️ 新增处理 |
| **SubagentStart** | 子 Agent 启动 | 不改变 phase，只计数 | 显示 `[n]` badge |
| **SubagentStop** | 子 Agent 结束 | 不改变 phase，只计数 | 更新 badge |
| **TeammateIdle** | Teammate idle | 不处理 | Agent teams 场景，可忽略 |
| **TaskCreated** | 任务创建 | 不处理 | 可忽略 |
| **TaskCompleted** | 任务完成 | 不处理 | 可忽略 |
| **PreCompact** | 压缩前 | compacting | 显示压缩状态 |
| **PostCompact** | 压缩后 | processing | 继续处理 |
| **CwdChanged** | 工作目录变化 | 不改变 phase | 更新 session.cwd |
| **Elicitation** | MCP 输入请求 | waitingForApproval | 已支持 |
| **SessionEnd** | 会话结束 | ended | 清理 session |
| **用户中断（ESC）** | 无 Hook 事件 | idle | Darwin Notification 监听 |

---

## 八、Timeout 与 Cleanup 执行顺序

> **关键问题**：waitingForInput timeout 与 clearStaleSessions 的冲突

**现有逻辑**：
- `clearStaleSessions()`：`sessions.filter { $0.value.lastUpdated > threshold }`（5分钟阈值，无差别删除）
- `convertStaleProcessingToIdle()`：processing/runningTool/compacting 5分钟 → idle；toolFailed/error 10秒 → idle

**新增逻辑**：
- waitingForInput → 5分钟 → idle

**执行顺序**（在 staleProcessingCleanupTimer 10秒轮询中）：
```
1. convertStaleProcessingToIdle()  // processing/toolFailed/error → idle
2. convertWaitingForInputToIdle()  // waitingForInput → idle (新增)
3. clearStaleSessions()            // 删除过期 session
```

**问题**：如果 waitingForInput 超过 5分钟，步骤 2 转为 idle，然后步骤 3 可能删除它。

**解决方案**（待实现）：修改 clearStaleSessions 的阈值，区分不同状态：
```swift
func clearStaleSessions() {
    let now = Date()
    for (sessionId, session) in sessions {
        let threshold: TimeInterval
        switch session.phase {
        case .ended:
            threshold = 60  // 1分钟后清理 ended session
        case .idle:
            threshold = 300  // 5分钟后清理 idle session（已睡眠足够久）
        default:
            continue  // 其他状态不清理
        }
        
        if now.timeIntervalSince(session.lastUpdated) > threshold {
            sessions.removeValue(forKey: sessionId)
        }
    }
}
```

这样 waitingForInput → idle 后，需要再等 5分钟才会被清理。

---

## 九、Darwin Notification 实现（已完成）

### 用户中断检测流程

```
用户按 ESC
    ↓
Claude Code 写入 JSONL 文件（包含 "Interrupted by user"）
    ↓
XPC Helper 的 JSONLInterruptWatcher 检测到中断内容
    ↓
写入通知文件：/tmp/boringnotch:{sessionId}.txt
    ↓
发送 Darwin Notification：com.boringnotch.ai.interrupt
    ↓
主 App 的 AIXPCClient 收到通知
    ↓
读取通知文件，提取 sessionId
    ↓
调用 AIManager.handleXPCInterrupt(sessionId)
    ↓
session.phase = .idle
```

### 代码位置

| 文件 | 功能 |
|------|------|
| `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift` | 监听 JSONL 文件，检测中断 |
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | 写入通知文件，发送 Darwin Notification |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | 监听 Darwin Notification |
| `boringNotch/AI/AIManager.swift` | handleXPCInterrupt 处理中断 |

---

## 十、实现改动清单

### 受影响文件（完整列表）

| 文件 | 改动类型 | 具体改动 |
|------|----------|----------|
| **AISessionState.swift** | 删除 | 删除 `case stopPending` |
| **AIHookEvent.swift** | 删除+修改 | 删除 `"stop_pending" → .stopPending` case，`"stop_pending"` 改为 `"waiting_for_input" → .waitingForInput` |
| **AIHookInstaller.swift** | 修改 | status_map: `"Stop"` 从 `"stop_pending"` 改为 `"waiting_for_input"` |
| **AIManager.swift** | 删除+新增 | 删除 stopPending 处理逻辑；新增 waitingForInput→idle timeout；修改 clearStaleSessions |
| **AgentIconView.swift** | 删除 | SessionStatusIcon 删除 `case .stopPending` |
| **AIStatusAnimationView.swift** | 删除 | 删除 `case .stopPending` |
| **SessionRow.swift** | 删除 | 删除 stopPending 相关判断 |
| **AIExpandedView.swift** | 删除 | 删除 `case .stopPending: return "Idle"` |
| **SessionPriorityHelper.swift** | 删除 | 删除 `case .stopPending` |
| **NotchHomeView.swift** | 删除 | 删除 `case .stopPending` |

### Hook Script 改动

```python
status_map = {
    "UserPromptSubmit": "processing",
    "PreToolUse": "running_tool",
    "PostToolUse": "processing",
    "PostToolUseFailure": "tool_failed",
    "PermissionRequest": "waiting_for_approval",
    "PermissionDenied": "processing",
    "Stop": "waiting_for_input",        # 改：任务完成，等待输入
    "StopFailure": "error",
    "SubagentStart": "subagent_active",  # 不改变 phase，只计数
    "SubagentStop": "subagent_done",     # 不改变 phase，只计数
    "SessionStart": "waiting_for_input",
    "SessionEnd": "ended",
    "PreCompact": "compacting",
    "PostCompact": "processing",
    "CwdChanged": "cwd_changed",         # 不改变 phase，只更新 cwd
    "Elicitation": "waiting_for_approval",
}

# Notification 特殊处理
if event_type == "Notification":
    if notification_type == "permission_prompt":
        return  # 已忽略
    elif notification_type == "idle_prompt":
        status = "waiting_for_input"
    elif notification_type == "elicitation_dialog":
        status = "waiting_for_approval"  # 新增
    elif notification_type == "auth_success":
        return  # 不改变状态
    else:
        status = "notification"
```

---

## 十一、参考资料

- Claude Code Hooks 官方文档: `docs/claude-code-hooks-reference.md`
- 旧版设计文档: `docs/ai-state-flow-logic.md`
- Push 方案设计: `docs/superpowers/specs/2026-04-20-ai-push-and-ui-design.md`