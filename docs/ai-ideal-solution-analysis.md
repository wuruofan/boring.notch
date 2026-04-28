# 理想状态流转方案可行性分析

> 对 `ai-state-flow-optimization.md` 中提出的理想方案进行可行性评估。
> **更新 (2026-04-27)**: XPC 推送和 JSONL Interrupt 链路均已验证成功。

---

## 一、理想方案回顾

文档提出的理想状态流转：

```
Hook 事件 → XPC Helper 写入状态文件(原子写入)
                    │
                    │ XPC 回调推送（替代轮询）
                    ▼
              主 App AIManager
                    │
                    ├─ processing / running_tool / compacting → 正常更新
                    │
                    ├─ stop_pending → idle + 启动 15s 窗口
                    │       ├─ 窗口内收到 idle_prompt → waitingForInput (完成)
                    │       ├─ 窗口内收到 XPC interrupt → idle (中断，标记阻止后续覆盖)
                    │       └─ 窗口超时 → idle (超时)
                    │
                    ├─ waitingForInput → 直接设置（如果未被 interrupt 标记阻止)
                    │
                    └─ ended → 移除 session
```

关键改进点：
1. 原子写入
2. XPC 推送（替代轮询）
3. interrupt 标记
4. 时间窗口兜底

---

## 二、可行性分析

### 问题 1：XPC 推送模式的实现 ✅ 已解决

**方案描述**：
> XPC Helper 读取状态文件后通过 XPC 回调主动通知主 App

**解决方案 (已实现)**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          XPC 推送链路 (已验证)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  XPC Helper (AIHookServerCore)                                               │
│  ├─ Thread.polling 接收 Socket 数据 (替代 DispatchSource)                   │
│  ├─ 写入状态文件 (per-session)                                               │
│  └─ helper.notifyStateUpdate(sessionIds) ← XPC 回调推送                     │
│                                                                              │
│  主 App (AIXPCListener)                                                      │
│  └─ onStateUpdate(sessionIds) → pollSpecificStateFiles()                    │
│                                                                              │
│  验证证据 (2026-04-27)：                                                       │
│  ├─ 日志: "Sent stateupdate callback for b350c048 via XPC listener"         │
│  ├─ 日志: "AIXPCListener: onStateUpdate received with 1 sessions"           │
│  └─ 延迟: 毫秒级                                                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**关键技术决策**：
- 使用 `Thread.polling` 替代 `DispatchSource` → 解决 XPC Service 无 RunLoop 问题
- XPC 回调穿透 Sandbox → 主 App 可以接收推送
- 保留 15s fallback 轮询 → 防止回调丢失

**结论**：✅ **已解决** - XPC 推送链路稳定工作，毫秒级延迟。
```

**结论**：XPC 推送模式理论上可行，但需要额外架构改动，收益不大。

---

### 问题 2：时间窗口方案的逻辑漏洞 ⚠️ 中等

**方案描述**：
> stop_pending → idle + 启动 15s 窗口
> 窗口内收到 idle_prompt → waitingForInput (完成)

**逻辑漏洞**：

```
场景 1：正常任务完成（时间窗口方案工作）
┌─────────────────────────────────────────────────────────────────────────────┐
│  T0: Stop → idle + 启动 15s 窗口                                             │
│  T1 (1s后): idle_prompt → waitingForInput ✓                                 │
│                                                                              │
│  结果：正确判断为完成                                                         │
└─────────────────────────────────────────────────────────────────────────────┘

场景 2：长任务完成（时间窗口方案失败）
┌─────────────────────────────────────────────────────────────────────────────┐
│  T0: Stop → idle + 启动 15s 窗口                                             │
│  T1-T20: 长任务执行中（没有 Hook 事件）                                       │
│  T15 (窗口超时): → idle (误判为超时)                                         │
│  T20: idle_prompt 到达 → 但 session 已经是 idle                             │
│                                                                              │
│  问题：15s 窗口对长任务不够                                                   │
│  结果：长任务完成被误判为超时 ❌                                              │
└─────────────────────────────────────────────────────────────────────────────┘

场景 3：事件乱序（时间窗口方案无法解决）
┌─────────────────────────────────────────────────────────────────────────────┐
│  T0: idle_prompt → waitingForInput (session 还是 processing)                │
│  T1 (200ms后): Stop → idle + 启动窗口                                        │
│                                                                              │
│  问题：idle_prompt 先到，session 还是 processing                            │
│        时间窗口逻辑依赖 Stop 先到，无法处理乱序                              │
│  结果：完成被误判为中断 ❌                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

**根本问题**：时间窗口方案假设事件顺序是可控的，但实际上：
- Hook 事件顺序由 Claude Code 决定（先 Stop 后 idle_prompt）
- App 处理顺序由轮询间隔决定（可能乱序）
- 时间窗口方案无法解决乱序问题

**结论**：时间窗口方案对长任务和乱序场景都无效。

---

### 问题 3：interrupt 标记链路 ✅ 已验证成功

**方案描述**：
> 窗口内收到 XPC interrupt → idle (中断，标记阻止后续覆盖)

**验证结果 (2026-04-27)**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          JSONL Interrupt 链路 (已验证)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  JSONL 文件写入格式 (实测):                                                   │
│  {"type":"user","message":{"content":[{"type":"tool_result",                │
│   "content":"Interrupted by user","is_error":true}]}}                       │
│                                                                              │
│  XPC Helper (JSONLInterruptPollingThread)                                    │
│  ├─ Thread.polling 监听 JSONL 文件 (500ms)                                   │
│  ├─ 检测模式: "Interrupted by user", "[Request interrupted by user]"        │
│  └─ helper.notifyInterrupt(sessionId) ← XPC 回调推送                        │
│                                                                              │
│  主 App (AIXPCListener)                                                      │
│  └─ onInterrupt → handleXPCInterrupt() → session.phase = .idle              │
│                                                                              │
│  验证证据:                                                                    │
│  ├─ 日志: "handleInterrupt: Received interrupt for 39bff100"                │
│  ├─ 日志: "handleXPCInterrupt: Session 39bff100 interrupted -> idle"        │
│  ├─ 日志: "sortedSessions: 39bff100:idle"                                   │
│  └─ UI: 状态正确更新为 idle                                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**关键技术决策**：
- 使用 `Thread.polling` 替代 `DispatchSource` → 解决 XPC Service 无 RunLoop
- 使用 XPC 回调替代 Darwin Notification → 更可靠，穿透 Sandbox
- 检测 `"Interrupted by user"` 文本 → 覆盖 JSONL 实际格式

**结论**：✅ **已验证成功** - thinking 阶段 ESC 打断检测完全工作。

---

### 问题 4：原子写入的可行性 ✅ 可行

**方案描述**：
> atomically: false → atomically: true

**实现**：
```swift
// AIHookServerCore.swift:282
try? str.write(toFile: Self.stateFilePath, atomically: true, encoding: .utf8)
```

**可行性分析**：
- 原子写入是 Swift 标准 API
- 不依赖 RunLoop 或特殊环境
- 在 XPC Service 中正常工作
- 实际上 XPC Helper 已经有写入权限

**结论**：完全可行，应该立即实施。

---

## 三、方案总体评估 (2026-04-27 更新)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          理想方案可行性总结                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  改进点 1：原子写入                                                          │
│  ├─ 可行性：✅ 完全可行                                                      │
│  ├─ 风险：低                                                                │
│  └─────────────────────────────────────────────────────────────────────────┤│
│                                                                              │
│  改进点 2：XPC 推送                                                          │
│  ├─ 可行性：✅ 已实现并验证                                                  │
│  ├─ 解决方案：Thread.polling + XPC 回调                                     │
│  ├─ 延迟：毫秒级                                                             │
│  └─────────────────────────────────────────────────────────────────────────┤│
│                                                                              │
│  改进点 3：interrupt 标记                                                    │
│  ├─ 可行性：✅ 已验证成功                                                    │
│  ├─ 解决方案：JSONLInterruptPollingThread + XPC 回调                        │
│  ├─ 检测模式：覆盖 JSONL 实际格式                                            │
│  └─────────────────────────────────────────────────────────────────────────┤│
│                                                                              │
│  改进点 4：时间窗口兜底                                                       │
│  ├─ 可行性：⚠️ 有逻辑漏洞                                                    │
│  ├─ 问题：无法处理长任务和事件乱序                                            │
│  ├─ 替代方案：interrupt 链路已验证，时间窗口不再必需                          │
│  └─────────────────────────────────────────────────────────────────────────┤│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 四、更简洁的替代方案

既然理想方案有多个可行性问题，建议采用更简洁的方案：

### 方案 A：idle_prompt 无条件覆盖（最简单）

```
核心逻辑：
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│  Stop → idle (暂时，不做最终判断)                                            │
│                                                                              │
│  idle_prompt → waitingForInput (无条件覆盖，因为语义上是任务完成)             │
│                                                                              │
│  无 idle_prompt → 保持 idle (最终判断为中断)                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

优点：
├─ 不依赖事件顺序
├─ 不依赖时间窗口
├─ 不依赖 interrupt 链路
├─ 实现简单，风险低
```

### 方案 B：保留 interrupt 标记（如果链路验证成功）

```
如果 JSONL 监听链路验证成功：
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│  XPC interrupt → idle + 标记 interruptedSessions                            │
│                                                                              │
│  idle_prompt → 检查标记                                                      │
│       ├─ 有标记 → 忽略（是真正的中断）                                        │
│       ├─ 无标记 → waitingForInput（是完成）                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

优点：
├─ 可以精确区分中断和完成
├─ 作为方案 A 的补充保护
```

### 方案 C：完全不区分（最保守）

```
核心逻辑：
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│  所有 Stop/idle_prompt → 都显示 idle 或 waitingForInput                      │
│  不尝试区分中断和完成                                                         │
│                                                                              │
│  只关注真正需要用户注意的状态：                                               │
│  ├─ waitingForApproval → 显示审批按钮                                        │
│  ├─ processing/runningTool → 显示蟹动画                                      │
│  └─ 其他 → 显示默认状态                                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

优点：
├─ 最简单，无竞态问题
├─ 减少状态复杂度
└─ 不影响核心功能（审批）
```

---

## 五、建议实施顺序 (2026-04-27 更新)

| 优先级 | 改动 | 状态 | 说明 |
|--------|------|------|------|
| **已完成** | 原子写入 | ✅ 已实施 | 防止事件丢失 |
| **已完成** | XPC 推送 | ✅ 已验证 | 毫秒级延迟，穿透 Sandbox |
| **已完成** | JSONL Interrupt | ✅ 已验证 | thinking 阶段 ESC 打断检测 |
| **已完成** | idle_prompt 无条件覆盖 | ✅ 已实施 | 解决竞态，逻辑简单 |
| **已完成** | Sessions 状态监听 | ✅ 已验证 | 2026-04-28，权威 idle 判断 |
| **可选** | 清理死代码 | ⏳ 待清理 | 删除 Darwin Notification 相关代码 |
| **可选** | 优化 fallback 轮询频率 | ⏳ 待优化 | 当前 15s，可改为 5s |

---

## 六、结论 (2026-04-28 更新)

**理想方案验证结果**：
1. ✅ XPC 推送通过 Thread.polling + XPC 回调实现，毫秒级延迟
2. ✅ JSONL Interrupt 链路完全工作，thinking 阶段 ESC 打断可检测
3. ✅ Sessions 状态监听已实现，权威 idle 判断，解决 UserPromptSubmit ~ PreToolUse 之间的空白期
4. ⚠️ 时间窗口方案仍有逻辑漏洞，但 Sessions 状态监听已解决核心问题

**当前架构状态**：
- 推送链路稳定工作，无需轮询延迟
- Sessions 状态权威，覆盖所有阶段的 ESC 打断检测
- 15s fallback 轮询作为兜底机制
- 竞态问题已解决（sessions idle 不被 Hook 覆盖）

**未来可选改进**：
- 清理 Darwin Notification 相关死代码（已改用 XPC 回调）
- 优化 fallback 轮询频率以进一步降低丢失风险
- 调研多 Agent 支持（Codex/OpenCode/Cursor）