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
| `AIHookServerCore.swift` | 状态文件路径改为 `{basePath}/boringnotch-ai-state-{sessionId}.json`；sessionId 做 URL-safe base64 编码确保文件名安全 |
| `AIHookServer.swift` | 轮询逻辑改为扫描多文件，hash dedup per file；扫描时检查文件修改时间，超过 5 分钟未更新的视为僵尸文件忽略 |
| `BoringNotchAIXPCHelperProtocol.swift` | 新增 `cleanupStateFile(sessionId:)` 方法 |
| `AIManager.swift` | **处理完** SessionEnd 事件后（而非收到时）调用 XPC 清理状态文件；增加延迟清理逻辑防止事件丢失 |
| `AIHookInstaller.swift` | Hook 脚本生成逻辑更新，新增事件映射 |

**SessionEnd 清理时序设计**：
```
Hook 发送 SessionEnd → XPC Helper 写入状态文件 → 主 App 轮询读取
→ AIManager.handleHookEvent() 处理 SessionEnd（移除 session）
→ 延迟 2 秒后调用 AIXPCClient.cleanupStateFile(sessionId)
```

**延迟清理原因**：防止清理过早导致轮询未读到事件。主 App 处理完 SessionEnd 后再清理，确保事件不丢失。

---

### Phase 2: Darwin Notification 推送

**核心改动**：
- XPC Helper 写入状态文件后**直接发送** Darwin Notification（无需额外 Thread）
- 主 App 收到通知后立即读取（无需定时轮询）
- 保留低频轮询兜底（每 5 秒一次），防止 Darwin Notification 丢失

**架构变化**：
```
之前：
  状态文件 → 主 App 定时轮询（200ms）

之后：
  XPC Helper 写入状态文件 → notify_post() → Darwin Notification → 主 App 立即读取
                              ↓
                        低频轮询兜底（5s）
```

**通知名称**：`com.boringnotch.ai.stateupdate`

**关键改动清单**：

| 文件 | 改动 |
|------|------|
| `AIHookServerCore.swift` | 在 `handleClient()` 写入状态文件后调用 `notify_post()` |
| `AIXPCClient.swift` | 新增 Darwin Notification 监听，收到后扫描状态文件 hash 对比 |
| `AIHookServer.swift` | 移除 200ms 定时轮询，改为事件驱动 + 5s 低频兜底 |

**Darwin Notification 无 payload 处理**：
主 App 收到通知后扫描所有 `boringnotch-ai-state-*.json` 文件，比对 hash 确定哪些文件发生变化（复用现有 hash dedup 逻辑）。

---

## 三、子 Agent 状态追踪

### 事件识别

| 事件 | 说明 | 处理策略 |
|------|------|----------|
| `SubagentStart` | 子 agent 开始 | subagentCount += 1，**不改变 phase** |
| `SubagentStop` | 子 agent 结束 | subagentCount -= 1，**不改变 phase** |
| 其他事件 | 无法区分主/子 | 按原有规则处理 |

**关键设计**：SubagentStart/SubagentStop 只更新计数，不触发 phase 变更。由 AIManager 根据 subagentCount 判断整体状态：
- `subagentCount > 0`：保持当前 phase（主 agent 可能在等待子 agent 结果）
- `subagentCount == 0`：按下一个事件决定 phase

### Hook 脚本改动

SubagentStart/SubagentStop 映射为 `processing`（而非 waiting_for_input），但不触发状态转换：
```python
status_map = {
    "SubagentStart": "subagent_active",  # 新增：仅计数标记
    "SubagentStop": "subagent_done",     # 新增：仅计数标记
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
    // 不改变 phase
}
if event.event == "SubagentStop" {
    sessions[sessionId]?.subagentCount -= 1
    // 不改变 phase，由后续事件或超时决定
}

// SessionEnd 时强制归零
if phase == .ended {
    sessions[sessionId]?.subagentCount = 0
}
```

### 边界条件处理

| 场景 | 处理规则 |
|------|----------|
| SubagentStart 到达但无对应 session | 创建新 session，phase=processing，subagentCount=1 |
| SubagentStop 到达但 subagentCount 已为 0 | 不减为负数，忽略该事件 |
| SessionEnd 时 subagentCount > 0 | 强制归零，正常清理 session |

---

## 三.5、完整事件处理矩阵

### Claude Code Hook 事件全量映射

| 事件 | status | phase | UI 展示 | 备注 |
|------|--------|-------|---------|------|
| UserPromptSubmit | processing | .processing | 蟹动画 + Spinner | 用户提交新 prompt |
| PreToolUse | running_tool | .runningTool | 蟹动画 + 工具名 | 开始执行工具 |
| PostToolUse | processing | .processing | 蟹动画 + Spinner | 工具执行完毕 |
| **PostToolUseFailure** | tool_failed | .toolFailed | 蟹动画 + 红色指示器 | 工具失败，第二行用红色 |
| PermissionRequest | waiting_for_approval | .waitingForApproval | 琥珀色审批指示器 | 需要权限审批 |
| **PermissionDenied** | processing | .processing | 蟹动画 + Spinner | 自动拒绝，继续执行 |
| Stop | stop_pending | → .idle | 睡眠动画 | ESC 中断或任务完成 |
| **StopFailure** | error | .error | 红色错误指示器 | API 错误中断 |
| Notification (idle_prompt) | waiting_for_input | .waitingForInput | 绿色 Checkmark | 任务完成，等待新输入 |
| SubagentStart | subagent_active | 不改变 | 角标 +1 | 仅计数，不改变 phase |
| SubagentStop | subagent_done | 不改变 | 角标 -1 | 仅计数，不改变 phase |
| SessionStart | waiting_for_input | .waitingForInput | 绿色 Checkmark | 新 session 启动 |
| SessionEnd | ended | → 移除 | 不显示 | Session 结束，移除 |
| PreCompact | compacting | .compacting | 压缩动画 | 压缩上下文 |
| **PostCompact** | processing | .processing | 蟹动画 + Spinner | 压缩完成，继续处理 |
| **CwdChanged** | 不改变 | 不改变 | 更新项目名 | 仅更新 cwd 字段 |
| **Elicitation** | waiting_for_approval | .waitingForApproval | 琥珀色指示器 | MCP 请求用户输入 |

**新增状态**：
- `.toolFailed`：工具执行失败，Session Row 第二行用红色标识
- `.error`：API 错误中断，紧凑态用红色错误指示器

### UI 展示差异

| 状态 | 紧凑态右侧 | 展开态第二行 |
|------|-----------|--------------|
| tool_failed | 红色感叹号 | 工具名（红色）+ "Failed" |
| error | 红色错误图标 | "Error" + 错误类型 |

### 特殊事件处理详解

**CwdChanged 数据流**：
```
Hook stdin JSON 包含新 cwd → Hook 脚本传递 cwd 字段 → AIHookEvent 解码 cwd → AIManager 更新 session.cwd
```
改动点：
1. Hook 脚本：从 stdin JSON 读取 `cwd` 字段并传递（当前已支持）
2. AIHookEvent：确保 `cwd` 字段解码正确（当前已支持）
3. AIManager：收到 CwdChanged 时更新 `sessions[sessionId]?.cwd`

**SubagentStart/SubagentStop Swift 处理**：
```swift
// AIManager.handleHookEvent() 中
if event.status == "subagent_active" || event.event == "SubagentStart" {
    sessions[sessionId]?.subagentCount += 1
    // 不调用 updateCoordinator()，不改变 phase
    return
}
if event.status == "subagent_done" || event.event == "SubagentStop" {
    sessions[sessionId]?.subagentCount = max(0, (sessions[sessionId]?.subagentCount ?? 0) - 1)
    // 不调用 updateCoordinator()，不改变 phase
    return
}
```
关键点：识别 `subagent_active` 和 `subagent_done` status 值，做计数处理而非 phase 变更。

---

## 四、UI 展示设计

### 紧凑态（收起态）

**布局**：左侧蟹图标 + 右侧状态指示

| 状态 | 左侧 | 右侧 |
|------|------|------|
| Processing | 蟹图标（腿动画） + Session 数量角标 | Spinner |
| Running Tool | 蟹图标（腿动画） + Session 数量角标 | 工具图标 |
| Tool Failed | 蟹图标（腿动画） + Session 数量角标 | 红色感叹号 |
| Error | 蟹图标（腿动画） + Session 数量角标 | 红色错误图标 |
| Waiting for Approval | 蟹图标（腿动画） + Session 数量角标 | 琥珀色审批指示器 |
| Waiting for Input | 蟹图标（腿动画） + Session 数量角标 | 绿色 Checkmark |
| Idle | 蟹图标（静止） + Session 数量角标 | Sleep 动画 |

**角标规则**（简化设计）：

| 角标位置 | 含义 | 显示条件 |
|----------|------|----------|
| 蟹图标右上角 | Session 数量 | 多个活跃 session 时显示 |

**子 agent 信息**：仅在展开态 Session Row 显示，紧凑态不显示（避免信息密度过高）。

**颜色调整**：
- Sleep 动画颜色调整为 `white.opacity(0.4)`（待视觉验证）

---

### 展开态 Session Row

**布局**：两行显示

| 行 | 内容 |
|----|------|
| 第一行 | 项目名（cwd 简化） + 子 agent 数量角标 `[n]` |
| 第二行 | 工具名 + 输入信息（根据工具类型格式化） |

**子 agent 数量角标 `[n]`**：
- 显示当前运行的子 agent 数量
- 无子 agent 时不显示
- 格式：`boring.notch [2]`

**第二行展示规则**：

| 工具类型 | 展示格式 | 截断策略 |
|----------|----------|----------|
| Bash | `Bash` + `cat ~/...` | 命令部分尾部截断，保留前 30 字符 |
| Edit | `Edit` + `file:line` | 文件名头部截断，显示最后两级路径 |
| Write | `Write` + `filename` | 文件名尾部截断 |
| Read | `Read` + `filename` | 文件名尾部截断 |
| Grep | `Grep` + `pattern` | pattern 尾部截断 |
| Glob | `Glob` + `pattern` | pattern 不截断（通常较短） |
| WebFetch | `WebFetch` + `url` | URL 省略中间，显示域名 + 路径末尾 |
| Agent | `Agent` + `description` | description 尾部截断 |
| 其他 | 工具名 | 无额外信息 |

**特殊状态展示**：

| 状态 | 第二行内容 | 颜色 |
|------|-----------|------|
| processing（无工具） | "Thinking..." | 默认灰色 |
| tool_failed | 工具名 + "Failed" | 红色 |
| error | "Error" + 错误类型 | 红色 |
| compacting | "Compacting..." | 默认灰色 |

---

### 状态优先级（紧凑态右侧）

| 优先级 | 状态 | 右侧图标 | 说明 |
|--------|------|----------|------|
| 1（最高） | Waiting for Approval | 琥珀色审批指示器 | 需用户决策 |
| 2 | Error | 红色错误图标 | API 错误需用户注意 |
| 3 | Tool Failed | 红色感叹号 | 工具失败需用户注意 |
| 4 | Processing / Running Tool / Compacting | Spinner / 工具图标 | 正常执行中 |
| 5 | Waiting for Input | 绿色 Checkmark | 任务完成等待输入 |
| 6（最低） | Idle | Sleep 动画 | 无任务 |

**设计决策**：紧凑态仅展示最高优先级 session 的状态（通过 `highestPrioritySession` 计算），详细信息需查看展开态。Notch 空间有限，无法同时展示多个 session 的详细状态。

---

## 五、关键文件路径

| 文件 | 作用 |
|------|------|
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | XPC Helper socket + 状态文件写入 + notify_post() |
| `boringNotch/AI/AIHookServer.swift` | 主 App 状态文件轮询 + hash dedup + 僵尸文件清理 |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | XPC 客户端 + Darwin Notification 监听 |
| `BoringNotchAIXPCHelper/BoringNotchAIXPCHelperProtocol.swift` | XPC 协议定义 + cleanupStateFile |
| `boringNotch/AI/AIManager.swift` | Session 状态管理 + 子 agent 追踪 + 延迟清理 |
| `boringNotch/AI/AISessionState.swift` | Session 状态结构体 + subagentCount |
| `boringNotch/AI/AIHookInstaller.swift` | Hook 脚本生成 + 版本检查 + 自动升级 |
| `boringNotch/AI/Views/AILiveActivity.swift` | 紧凑态 UI |
| `boringNotch/AI/Views/AgentIconView.swift` | 蟹图标 + 角标 |
| `boringNotch/AI/Views/SessionRow.swift` | 展开态 session 行 + 第二行格式化 |
| `~/.claude/hooks/boringnotch-ai-state.py` | Hook 脚本（运行时生成） |

---

## 六、验证方法

### Phase 1 验证

1. 启动 2 个 Claude session（不同目录）
2. 同时执行任务，观察状态文件是否独立
3. ESC 中断一个 session，观察是否立即更新（无等待超时）

### Phase 2 验证

1. 执行任务，观察紧凑态是否立即响应（无 200ms 延迟）
2. 检查 Darwin Notification 是否正确触发
3. 模拟 Darwin Notification 丢失，检查 5s 兜底轮询是否工作

### UI 验证

1. 紧凑态角标显示正确（Session 数量）
2. 展开态第二行显示工具名 + 输入
3. Sleep 动画颜色清晰可见
4. 工具失败时第二行红色标识

### 边界场景验证

| 场景 | 验证方法 |
|------|----------|
| 异常退出 | 强制 kill XPC Helper，检查状态文件残留，主 App 是否正常恢复并清理僵尸文件 |
| 子 agent 边界 | 启动子 agent → kill 子 agent → 检查 subagentCount 是否正确归零 |
| Hook 版本不匹配 | 旧版 Hook 脚本 + 新版主 App，检查 AIHookInstaller 是否自动升级 |
| 高频事件 | 快速连续触发多个事件，检查 hash dedup 是否只处理变化 |
| CwdChanged | Session 运行中切换目录，检查 Session Row 项目名是否更新 |
| 工具失败 | 模拟 PostToolUseFailure，检查第二行是否红色标识 |

---

## 七、已知限制

- Darwin Notification 无 payload，需通过文件扫描 + hash 对比确定变化文件
- Phase 1 的 200ms 轮询延迟仍存在（Phase 2 解决）
- 无法完全区分主/子 agent 的所有事件（只有 SubagentStart/Stop 可识别）
- **异常退出时状态文件残留**：无 SessionEnd 事件，需 5 分钟超时清理僵尸文件
- **Hook 脚本版本不匹配**：旧版脚本不支持新事件，AIHookInstaller 启动时检查版本并自动升级
- **sessionId 特殊字符**：做 URL-safe base64 编码，防止文件名不安全
- **Darwin Notification 丢通知**：保留 5 秒低频轮询兜底
- **多事件快速覆盖**：同一 session 短时间内多个事件，中间状态可能被跳过（设计允许，最终状态正确）
- **Elicitation 与 PermissionRequest 性质不同**：Elicitation 是 MCP 请求用户文本输入，PermissionRequest 是工具权限审批。短期映射为 waitingForApproval 可接受（MVP），长期需新增 .waitingForElicitation phase 并 UI 区分（输入框而非审批按钮）

### 异常场景处理策略

| 异常场景 | 处理策略 |
|----------|----------|
| XPC Helper 崩溃 | 主 App 检测到 XPC 连接断开，重新启动 XPC Helper |
| 主 App 崩溃 | 状态文件残留，下次启动时扫描清理 5 分钟以上的僵尸文件 |
| Hook 脚本版本过旧 | AIHookInstaller 启动时比对版本，自动覆盖升级 |
| Darwin Notification 丢失 | 5 秒低频轮询兜底扫描所有状态文件 |
| 同一 session 事件风暴 | Hash dedup 保证只处理变化，中间状态跳过不影响最终正确性 |

### 状态超时规则

AIManager 的 `convertStaleProcessingToIdle` 定时检查各状态的持续时间，超过阈值后自动回退到 idle：

| 状态 | 超时阈值 | 原因 |
|------|----------|------|
| processing | 15 秒 | 思考阶段不应过长 |
| running_tool | 120 秒 | 工具执行可能很长（如 Bash 命令） |
| compacting | 60 秒 | 压缩上下文需要一定时间 |
| tool_failed | 10 秒 | 失败状态短暂展示后自动回退，避免长时间显示错误 |
| waiting_for_approval | 不超时 | 等待用户决策，不应自动回退 |