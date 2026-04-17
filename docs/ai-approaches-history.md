# AI 状态监控方案历史总结

## 一、方案演进时间线

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            方案演进历史                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Phase 1: 直接 Socket (失败)                                                 │
│  ├─ 主 App 直接运行 Socket Server                                            │
│  ├─ 问题: Sandbox 阻止创建 /tmp/*.sock                                       │
│  └─ 结果: ❌ 完全失败                                                         │
│                                                                              │
│  Phase 2: XPC Helper Socket Server (部分成功)                                │
│  ├─ 将 Socket Server 移到 XPC Helper (unsandboxed)                           │
│  ├─ Socket 创建成功                                                          │
│  ├─ 问题: XPC Service 中 DispatchSource/Task/Thread 都不工作                 │
│  ├─ 尝试: DispatchSource, FileHandle, Thread.polling                         │
│  └─ 结果: ⚠️ Socket 能创建但无法稳定接收数据                                   │
│                                                                              │
│  Phase 3: Hook 直接写文件 (当前方案)                                          │
│  ├─ Hook Python 脚本直接写入状态文件                                          │
│  ├─ 主 App 轮询读取状态文件                                                   │
│  ├─ 问题: Hook 脚本经常回滚到 socket 方式                                     │
│  ├─ 问题: 事件顺序不稳定 (Stop vs idle_prompt)                                │
│  └─ 结果: ✅ 基本可用，但需要维护                                              │
│                                                                              │
│  Phase 4: Interrupt JSONL 监听 (未验证)                                      │
│  ├─ XPC Helper 监听 JSONL 文件写入                                            │
│  ├─ Darwin Notification 跨进程通知                                            │
│  ├─ 状态: 代码已实现，未实际验证                                               │
│  └─ 结果: ⏳ 待验证                                                           │
│                                                                              │
│  Phase 5: 推送版本 (未实现，改进建议)                                         │
│  ├─ XPC Helper 读取状态文件后主动推送                                          │
│  ├─ 避免 200ms 轮询延迟                                                       │
│  ├─ 状态: 未实现                                                              │
│  └─ 结果: ⏳ 待实现                                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、各方案详细分析

### 方案 1: 直接 Socket Server (主 App)

**时间**: 开发初期

**架构**:
```
Claude Code → Hook Python → Socket → 主 App (Socket Server)
```

**实现**:
- 主 App 直接在 sandboxed 环境创建 Unix Domain Socket
- 监听 `/tmp/boringnotch-ai.sock`

**问题**:
```swift
// 主 App 无法创建 /tmp 下的 socket
// Sandbox 错误: "Operation not permitted"
socket(AF_UNIX, SOCK_STREAM, 0)  // ❌ 被 sandbox 阻止
bind(socket, sockaddr_un, ...)   // ❌ 权限拒绝
```

**结论**: ❌ **完全失败** - Sandbox 不允许在 /tmp 创建 socket

---

### 方案 2: XPC Helper Socket Server

**时间**: Phase 2

**架构**:
```
Claude Code → Hook Python → Socket → XPC Helper → 状态文件 → 主 App
```

**实现**:
- XPC Helper 运行在 unsandboxed 环境
- 可以创建 `/tmp/boringnotch-ai.sock`
- 尝试多种异步机制接收数据

**尝试的异步机制**:

| 机制 | 结果 | 问题 |
|------|------|------|
| DispatchSource.read | ❌ | XPC Service 无 RunLoop，DispatchSource 不触发 |
| FileHandle.readabilityHandler | ❌ | 同上，依赖 RunLoop |
| Thread + poll() | ❌ | Thread.start() 不工作，polling 线程不启动 |
| DispatchQueue.async + while | ⚠️ | 偶尔工作，不稳定 |

**日志证据**:
```
// AIHookServerCore.swift 尝试了多种方式
acceptSource = DispatchSource.makeReadSource(...)  // 不触发
acceptSource?.resume()  // 无效果

// Thread-based polling
pollingThread = Thread { while isRunning { poll() } }  // 线程不启动
pollingThread?.start()  // 无效果
```

**根本原因**: XPC Service 没有 RunLoop，大部分异步机制失效

**结论**: ⚠️ **部分成功** - Socket 能创建，但数据接收不稳定

---

### 方案 3: Hook 直接写文件 + 主 App 轮询

**时间**: Phase 3 (当前)

**架构**:
```
Claude Code → Hook Python → 直接写文件 → 主 App 轮询读取
                   ↓
              (可选) Socket → XPC Helper (用于权限响应)
```

**实现**:
```python
# Hook Python 直接写入状态文件
STATE_FILE_PATH = "~/Library/Containers/.../boringnotch-ai-state.json"

def send_event(state):
    # 主方式：直接写文件
    with open(STATE_FILE_PATH, 'w') as f:
        json.dump(state, f)
    
    # 权限请求：也尝试 socket (等待响应)
    if state.get("status") == "waiting_for_approval":
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state))
        response = sock.recv(4096)
        return json.loads(response)
```

```swift
// 主 App 轮询读取
Task.detached {
    while !Task.isCancelled {
        pollStateFile()  // 每 200ms 读取
        sleep(200ms)
    }
}
```

**问题**:

| 问题 | 描述 | 影响 |
|------|------|------|
| Hook 脚本回滚 | 脚本经常被恢复到 socket 方式 | 状态文件不更新 |
| 事件顺序不稳定 | Stop 和 idle_prompt 处理顺序颠倒 | 中断判断错误 |
| 轮询延迟 | 200ms 延迟 | 状态更新不够实时 |

**解决方案**:
- Hook 脚本回滚 → 手动修复，需要持续维护
- 事件顺序 → idle_prompt 到达时覆盖之前的 Stop 判断
- 轮询延迟 → 推送版本改进

**结论**: ✅ **基本可用** - 主要工作方式，但需要维护

---

### 方案 4: Interrupt JSONL 监听 (模仿 Claude-Island)

**时间**: Phase 4

**架构**:
```
Claude Code → JSONL 文件追加 → XPC Helper 监听 → Darwin Notification → 主 App
```

**实现**:
```swift
// XPC Helper (JSONLInterruptWatcherCore.swift)
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend],  // 文件追加触发
    queue: queue
)
source.setEventHandler { self?.checkForInterrupt() }

// 检测中断模式
private static let interruptContentPatterns = [
    "Interrupted by user",
    "[Request interrupted by user]",
    "\"interrupted\":true"
]

// Darwin Notification 跨进程通知
CFNotificationCenterPostNotification(
    CFNotificationCenterGetDarwinNotifyCenter(),
    CFNotificationName("com.boringnotch.ai.interrupt"),
    nil, nil, true
)
```

```swift
// 主 App (AIXPCClient.swift)
CFNotificationCenterAddObserver(
    CFNotificationCenterGetDarwinNotifyCenter(),
    nil,
    { ... onInterruptDetected?(sessionId) },
    "com.boringnotch.ai.interrupt",
    nil, .deliverImmediately
)
```

**状态**: 
- 代码已实现
- 未实际测试验证整个链路

**潜在问题**:
- DispatchSource 在 XPC Service 中的稳定性未验证
- Darwin Notification 可能延迟
- 文件路径计算可能有问题

**结论**: ⏳ **待验证** - 代码存在，功能未确认

---

### 方案 5: 推送版本 (改进建议，未实现)

**背景**: 当前轮询方式有 200ms 延迟

**改进思路**:
```
方案 A: XPC Helper 推送
┌─────────────────────────────────────────────────────────────┐
│  XPC Helper 读取状态文件 → 通过 XPC 回调主动通知主 App        │
│                                                              │
│  // XPC Helper                                               │
│  readStateFile() → call remoteApp.onStateChanged(event)     │
│                                                              │
│  // 主 App                                                   │
│  func onStateChanged(event: AIHookEvent) {                  │
│      handleHookEvent(event)  // 直接处理，无延迟             │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘

方案 B: NSFileCoordinator
┌─────────────────────────────────────────────────────────────┐
│  使用 NSFileCoordinator 监听文件变化                          │
│  (可能被 sandbox 阻止，需验证)                                │
│                                                              │
│  NSFileCoordinator.addFilePresenter(...)                    │
│  presentedItemDidChange() → handleHookEvent()               │
└─────────────────────────────────────────────────────────────┘

方案 C: FSEvents (File System Events API)
┌─────────────────────────────────────────────────────────────┐
│  低级文件系统监听 API                                         │
│  FSEventStreamCreate(...)                                   │
│  可能绕过 sandbox 限制                                        │
│  需要研究                                                    │
└─────────────────────────────────────────────────────────────┘
```

**结论**: ⏳ **未实现** - 改进建议，需要进一步研究

---

## 三、方案对比表

| 方案 | 状态 | 优点 | 缺点 | 实时性 |
|------|------|------|------|--------|
| 直接 Socket | ❌ 失败 | 简单 | Sandbox 阻止 | - |
| XPC Socket | ⚠️ 部分 | Unsandboxed | XPC 无 RunLoop | 不稳定 |
| Hook 写文件 + 轮询 | ✅ 可用 | 稳定可靠 | 200ms 延迟，脚本回滚 | 低 |
| Interrupt JSONL | ⏳ 待验证 | 实时检测中断 | 链路复杂，未验证 | 高(理论) |
| 推送版本 | ⏳ 待实现 | 实时更新 | 需要研究实现 | 高 |

---

## 四、Claude-Island 方案对比

**Claude-Island 成功的关键**:
1. **主 App 不在 Sandbox** - 可以直接创建 Socket 和监听文件
2. **DispatchSource 正常工作** - 有 RunLoop
3. **Hook + JSONL 双通道** - Hook 发事件，JSONL 检中断

**BoringNotch 的限制**:
1. **主 App 在 Sandbox** - 无法直接监听 /tmp 下的文件
2. **必须依赖 XPC Helper** - 所有 unsandboxed 操作需要通过 XPC
3. **XPC Service 环境** - 缺少 RunLoop，很多异步机制失效

---

## 五、当前推荐方案

**短期** (稳定可用):
- Hook 直接写文件 + 主 App 轮询
- 确保 Hook 脚本不被回滚
- 使用 idle_prompt 覆盖处理事件顺序问题

**中期** (改进实时性):
- 验证 Interrupt JSONL 方案是否工作
- 如果工作，作为补充机制

**长期** (最佳体验):
- 实现推送版本
- 研究 NSFileCoordinator 或 FSEvents
- 或考虑移除 Sandbox（如果可行）

---

## 六、关键技术限制总结

| 技术 | Sandbox 主 App | XPC Service | Unsandboxed App |
|------|---------------|-------------|-----------------|
| 创建 /tmp/*.sock | ❌ 阻止 | ✅ 允许 | ✅ 允许 |
| DispatchSource | ❌ 阻止 | ⚠️ 不稳定 | ✅ 正常 |
| Task.detached | ✅ 工作 | ⚠️ 不稳定 | ✅ 正常 |
| Thread.start | ✅ 工作 | ❌ 不启动 | ✅ 正常 |
| FileHandle.readabilityHandler | ❌ 阻止 | ⚠️ 不稳定 | ✅ 正常 |
| 轮询读取文件 | ✅ 工作 | ✅ 工作 | ✅ 工作 |
| Darwin Notification | ✅ 工作 | ✅ 工作 | ✅ 工作 |

**核心问题**: XPC Service 是一个特殊环境，缺少完整的 RunLoop，导致大多数基于 RunLoop 的异步机制不工作。

---

## 七、文件路径记录

| 文件 | 作用 | 状态 |
|------|------|------|
| `~/.claude/hooks/boringnotch-ai-state.py` | Hook 脚本 | ⚠️ 需维护 |
| `~/Library/Containers/.../boringnotch-ai-state.json` | 状态文件 | ✅ |
| `boringNotch/AI/AIManager.swift` | 状态管理 | ✅ |
| `boringNotch/AI/AIHookServer.swift` | 文件轮询 | ✅ |
| `BoringNotchAIXPCHelper/AIHookServerCore.swift` | XPC Socket | ⚠️ 部分 |
| `BoringNotchAIXPCHelper/JSONLInterruptWatcherCore.swift` | JSONL 监听 | ⏳ 待验证 |
| `boringNotch/XPCHelperClient/AIXPCClient.swift` | XPC 通信 | ✅ |