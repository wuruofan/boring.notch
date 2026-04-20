# AI 状态推送与 UI 展示改进设计

> 解决多 session 并发事件覆盖问题，优化紧凑态和展开态的 UI 展示

---

## 一、背景与问题

### 当前问题

1. **事件覆盖问题**
   - 单一状态文件 + 多 session 并发运行 → Hook 事件互相覆盖
   - ESC 中断事件可能被其他 session 的 PreToolUse 覆盖
   - 主 App 200ms 轮询 → 响应延迟

2. **子 agent 状态混乱**
   - 子 agent（Explore/Plan）和主 agent 共享 session_id
   - 无法区分事件来源 → 状态来回切换（idle → processing → idle）

3. **UI 展示不够丰富**
   - 紧凑态：只有单一状态图标，无 session 数量指示
   - 展开态第二行：只显示工具名（Bash），缺少输入信息

---

## 二、XPC 推送模式架构

### 分两步实施

| Phase | 目标 | 方案 |
|-------|------|------|
| Phase 1 | 解决覆盖问题 | Per-Session 状态文件 |
| Phase 2 | 消除延迟 | Darwin Notification 推送 |

---

### Phase 1: Per-Session 状态文件

**核心改动**：
- 状态文件从单一改为 per-session：`boringnotch-ai-state-{session_id}.json`
- 主 App 轮询时扫描所有 session 文件
- SessionEnd 时清理对应状态文件

**架构变化**：
```
之前：
  Hook → 状态文件（单一） → 主 App 轮询（可能覆盖）

之后：
  Hook → 状态文件-A → 主 App 轮询（扫描多文件）
       → 状态文件-B →
       → 状态文件-C →
```

**关键改动清单**：

| 文件 | 改动 |
|------|------|
| `AIHookServerCore.swift` | 状态文件路径改为 `{basePath}/boringnotch-ai-state-{sessionId}.json` |
| `AIHookServer.swift` | 轮询逻辑改为扫描多文件，hash dedup per file |
| `BoringNotchAIXPCHelperProtocol.swift` | 新增 `cleanupStateFile(sessionId:)` 方法 |
| `AIManager.swift` | SessionEnd 时调用 XPC 清理状态文件 |

---

### Phase 2: Darwin Notification 推送

**核心改动**：
- XPC Helper 新增 Thread 轮询检测状态文件变化
- 通过 Darwin Notification 通知主 App
- 主 App 收到通知后立即读取（无需定时轮询）

**架构变化**：
```
之前：
  状态文件 → 主 App 定时轮询（200ms）

之后：
  状态文件 → XPC Helper Thread 检测 → Darwin Notification → 主 App 立即读取
```

**通知名称**：`com.boringnotch.ai.stateupdate`

**关键改动清单**：

| 文件 | 改动 |
|------|------|
| `AIHookServerCore.swift` | 新增状态文件轮询 Thread + Darwin Notification 发送 |
| `AIXPCClient.swift` | 新增 Darwin Notification 监听 |
| `AIHookServer.swift` | 移除定时轮询，改为事件驱动 |

---

## 三、子 Agent 状态追踪

### 事件识别

| 事件 | 说明 | 标记 |
|------|------|------|
| `SubagentStart` | 子 agent 开始 | 子 agent 数量 +1 |
| `SubagentStop` | 子 agent 结束 | 子 agent 数量 -1 |
| 其他事件 | 无法区分主/子 | 保持当前状态 |

### Hook 脚本改动

新增 `SubagentStart` 事件处理：
```python
status_map = {
    "SubagentStart": "subagent_running",  # 新增
    "SubagentStop": "waiting_for_input",
    ...
}
```

### AIManager 状态追踪

```swift
// 每个 session 维护子 agent 数量
struct AISessionState {
    var subagentCount: Int = 0
}

// handleHookEvent 中
if event.event == "SubagentStart" {
    sessions[sessionId]?.subagentCount += 1
}
if event.event == "SubagentStop" {
    sessions[sessionId]?.subagentCount -= 1
}
```

---

## 四、UI 展示设计

### 紧凑态（收起态）

**布局**：左侧蟹图标 + 右侧状态指示

| 状态 | 左侧 | 右侧 |
|------|------|------|
| Processing | 蟹图标（腿动画） + Session 数量角标 | Spinner + 子 agent 数量角标 |
| Waiting for Approval | 蟹图标（腿动画） + Session 数量角标 | 琥珀色审批指示器 + 子 agent 数量角标 |
| Waiting for Input | 蟹图标（腿动画） + Session 数量角标 | 绿色 Checkmark |
| Idle | 蟹图标（静止） + Session 数量角标 | Sleep 动画（浅色） |

**角标规则**：

| 角标位置 | 含义 | 显示条件 |
|----------|------|----------|
| 蟹图标右上角 | Session 数量 | 多个活跃 session 时显示 |
| Spinner/指示器右上角 | 子 agent 数量 | 有子 agent 运行时显示 |

**颜色调整**：
- Sleep 动画颜色调整为 `white.opacity(0.3)`（当前太深看不清）

---

### 展开态 Session Row

**布局**：两行显示

| 行 | 内容 |
|----|------|
| 第一行 | 项目名（cwd 简化） + 子 agent 数量角标 `[n]` |
| 第二行 | 工具名 + 输入信息（如 `Bash` + `cat ~/...`） |

**子 agent 数量角标 `[n]`**：
- 显示当前运行的子 agent 数量
- 无子 agent 时不显示
- 格式：`boring.notch [2]`

**第二行展示**：
- 工具名用琥珀色或灰色标识
- 输入信息截断显示（lineLimit: 1）
- 不区分主/子 agent，统一展示当前执行内容

---

### 状态优先级（紧凑态右侧）

| 优先级 | 状态 | 右侧图标 |
|--------|------|----------|
| 1（最高） | Waiting for Approval | 琥珀色审批指示器 |
| 2 | Processing | Spinner |
| 3 | Waiting for Input | 绿色 Checkmark |
| 4（最低） | Idle | Sleep 动画 |

---

## 五、关键文件路径

| 文件 | 作用 |
|------|------|
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | XPC Helper socket + 状态文件写入 |
| `boringNotch/AI/AIHookServer.swift` | 主 App 状态文件轮询 |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | XPC 客户端 + Darwin Notification |
| `BoringNotchAIXPCHelper/BoringNotchAIXPCHelperProtocol.swift` | XPC 协议定义 |
| `boringNotch/AI/AIManager.swift` | Session 状态管理 + 子 agent 追踪 |
| `boringNotch/AI/Views/AILiveActivity.swift` | 紧凑态 UI |
| `boringNotch/AI/Views/AgentIconView.swift` | 蟹图标 + 角标 |
| `boringNotch/AI/Views/SessionRow.swift` | 展开态 session 行 |
| `~/.claude/hooks/boringnotch-ai-state.py` | Hook 脚本 |

---

## 六、验证方法

### Phase 1 验证

1. 启动 2 个 Claude session（不同目录）
2. 同时执行任务，观察状态文件是否独立
3. ESC 中断一个 session，观察是否立即更新（无等待超时）

### Phase 2 验证

1. 执行任务，观察紧凑态是否立即响应（无 200ms 延迟）
2. 检查 Darwin Notification 是否正确触发

### UI 验证

1. 紧凑态角标显示正确（Session 数量 + 子 agent 数量）
2. 展开态第二行显示工具名 + 输入
3. Sleep 动画颜色清晰可见

---

## 七、已知限制

- Darwin Notification 无 payload，需通过文件传递 sessionId
- Phase 1 的 200ms 轮询延迟仍存在（Phase 2 解决）
- 无法完全区分主/子 agent 的所有事件（只有 SubagentStart/Stop 可识别）