# BoringNotch 多 Session 展示功能设计

- **创建日期**: 2026-04-16
- **状态**: 待审核
- **参考实现**: Claude-Island (`/Users/wuruofan/mine/rfw/claude-island/`)

---

## 背景

当前 BoringNotch 只显示单个 session（`activeSessionId`），无法区分多个 Claude 会话的状态。用户 ESC 打断一个 session 后，如果另一个 session 还在处理中，会显示错误的状态。

引入多 session 展示可以：
- 展开态：显示所有活跃 session 的列表，每个有独立状态图标
- 收起态：显示最高优先级 session 的状态（waitingForApproval > processing > idle）

---

## 现有模型字段说明

### AISessionState (已存在)

`AISessionState` 模型已包含排序所需的字段：

```swift
struct AISessionState: Identifiable {
    let id: String           // sessionId
    var phase: AISessionPhase
    var currentTool: String?
    var cwd: String?
    var pid: Int?
    var tty: String?
    var permissionRequest: AIPermissionRequest?
    var lastUpdated: Date    // 已存在，用于排序
}
```

**无需新增字段**。

---

## 参考设计：Claude-Island

Claude-Island 项目已实现多 session 管理，关键架构：

### Session 排序优先级

**文件**: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift` - `phasePriority()` 函数

```swift
// 0 (最高): waitingForApproval, processing, compacting
// 1: waitingForInput
// 2 (最低): idle, ended
// 同优先级按 lastUserMessageDate 倒序
```

### 收起态显示

**文件**: `ClaudeIsland/UI/Views/NotchView.swift`

- Crab 图标 + 状态指示器
- 有 pending permission 时显示 `PermissionIndicatorIcon`
- 等待输入时显示绿色 checkmark (`ReadyForInputIndicatorIcon`)

### 展开态显示

**文件**: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`

- `ScrollView` + `LazyVStack` 的 session 列表
- 每行 `InstanceRow` 显示：状态图标 + 项目名 + 工具名 + 审批按钮

---

## 命名约定

采用简化命名，避免冗余：

| 原建议命名 | 简化命名 | 说明 |
|------------|----------|------|
| AISessionCardView | SessionRow | 单行展示，类似 TableView Row |
| AISessionListView | SessionList | 列表容器 |
| AISessionPriorityHelper | SessionPriorityHelper | 前缀省略 |
| MiniApprovalButtons | ApprovalButtons | 精简版审批按钮 |

---

## 实现方案

### 1. 新建文件

#### SessionPriorityHelper.swift

```
优先级权重：
- waitingForApproval/processing/compacting: 0 (最高)
- waitingForInput: 1
- idle/ended: 2 (最低)

同优先级按 lastUpdated 倒序排列
```

#### SessionRow.swift

单个 session 卡片（参考 Claude-Island `InstanceRow`）：

- 状态图标（蟹=processing，睡=idle，问号=waitingForApproval）
- cwd 项目名（简化显示，取最后一个路径组件）
- 当前工具名（格式化显示）
- ApprovalButtons（等待审批时显示）

#### SessionList.swift

Session 列表容器（参考 Claude-Island `ClaudeInstancesView`）：

- `ScrollView` + `LazyVStack` 显示 session 列表，支持滚动
- 无数量限制，超出可见区域自动滚动
- 带动画的插入/移除过渡
- 固定可见区域高度（约 200px），内容动态增长

#### ApprovalButtons.swift

精简版审批按钮：

- Allow/Deny 按钮
- 支持指定 sessionId 和 requestId
- 点击后调用 XPC 响应权限请求

**XPC 交互**：复用现有 `AIXPCClient.respondToPermission(toolUseId, decision, reason)`，无需修改 XPC 协议。

```swift
// 现有 XPC 方法（AIXPCClient.swift 第 105-116 行）
AIXPCClient.shared.respondToPermission(
    toolUseId: requestId,
    decision: "allow"  // 或 "deny"
)
```

**可选**：使用 `respondToPermissionBySession(sessionId, decision, reason)` 按 session 响应。

### 2. 修改文件

#### AIManager.swift

添加计算属性：

```swift
/// Sessions 按优先级排序（最高优先）
var sortedSessions: [AISessionState]

/// 需要最高关注的 session（用于收起态显示）
var highestPrioritySession: AISessionState?

/// 等待审批的 session 数量
var approvalPendingCount: Int
```

#### NotchHomeView.swift

- 替换 `AIStatusCardExpanded` 为 `SessionList`
- 调整布局适配多卡片

#### BoringViewModel.swift

`effectiveOpenNotchSize` 动态计算**展开态高度**：

```swift
// 展开态高度计算（Notch 打开时的高度）
// 使用 ScrollView 支持无限 session 滚动
// 固定最大高度：baseHeight + 200（约 3 个 session 可见区域）
// 内容超出时自动滚动

// 边界约束：
// - 最小高度：baseHeight + 55（至少显示一个 session）
// - 最大高度：baseHeight + 200（可见区域）
// - 内容超出可见区域时通过 ScrollView 滚动
```

#### AILiveActivity.swift

- `AIOnlyLiveActivity` 使用 `highestPrioritySession` 显示状态
- 多个审批 pending 时显示 badge count

#### AgentIconView.swift

添加新组件：

- `ApprovalBadge` - 审批计数徽章
- `SessionStatusIcon` - 统一的 session 状态图标

---

## 交互设计

### ESC 键行为

ESC 打断 Claude 会话时：

1. **单 session 场景**：
   - ESC 打断 → session 状态变为 `idle`
   - 收起态显示 Sleep 动画（zZZ）
   - 展开态显示单个 idle session 卡片

2. **多 session 场景**：
   - ESC 打断当前活跃 session → 该 session 状态变为 `idle`
   - 其他活跃 session 不受影响
   - 收起态显示剩余最高优先级 session 的状态
   - 展开态显示所有 session，idle 的排在列表底部

**设计原则**：ESC 只打断**当前终端窗口对应的 session**，不影响其他终端的 session。

### 错误场景处理

| 场景 | UI 表现 |
|------|---------|
| Session 意外断开（进程崩溃） | 从列表移除，显示剩余 session |
| Socket 连接失败 | 收起态隐藏 AI 指示器，展开态显示"连接中断"提示 |
| XPC Helper 不可用 | 自动重试连接，3 次失败后显示错误提示 |

**Session 清理策略**（AIManager 已实现）：
- `lastUpdated` 超过 300 秒的 session 自动清理
- `ended` 状态的 session 立即移除

---

## 国际化考虑

如需要本地化，定义以下状态字符串 key：

```
"session.status.processing" = "Processing...";
"session.status.waiting_approval" = "Waiting for Approval";
"session.status.idle" = "Paused";
"session.status.waiting_input" = "Ready for Input";
"session.action.allow" = "Allow";
"session.action.deny" = "Deny";
```

---

## 数据流

```
AIManager.sessions (字典)
    ↓
AIManager.sortedSessions (排序后的数组)
    ↓
SessionList 监听并显示
    ↓
ForEach → SessionRow (每个 session)
```

---

## 实现顺序

### Phase 1: 基础设施

1. 创建 `SessionPriorityHelper.swift`
2. 更新 `AIManager.swift` 添加计算属性

### Phase 2: 展开态 UI

1. 创建 `SessionRow.swift`
2. 创建 `SessionList.swift`
3. 创建 `ApprovalButtons.swift`
4. 修改 `NotchHomeView.swift`
5. 修改 `BoringViewModel.swift` 高度计算

### Phase 3: 收起态 UI

1. `AgentIconView.swift` 添加 `ApprovalBadge`
2. 修改 `AILiveActivity.swift`

---

## 关键文件路径

| 文件 | 修改类型 |
|------|----------|
| `boringNotch/AI/AIManager.swift` | 修改 |
| `boringNotch/components/Notch/NotchHomeView.swift` | 修改 |
| `boringNotch/AI/Views/AILiveActivity.swift` | 修改 |
| `boringNotch/models/BoringViewModel.swift` | 修改 |
| `boringNotch/AI/Views/AgentIconView.swift` | 修改 |
| `boringNotch/AI/Helpers/SessionPriorityHelper.swift` | 新建 |
| `boringNotch/AI/Views/SessionRow.swift` | 新建 |
| `boringNotch/AI/Views/SessionList.swift` | 新建 |
| `boringNotch/AI/Views/ApprovalButtons.swift` | 新建 |

---

## 验证方法

1. 启动多个 Claude 会话（不同终端窗口）
2. 测试 ESC 打断单个 session：应该显示 sleep 动画
3. 测试多 session 展开态：应该看到 session 列表
4. 测试权限审批：应该在对应 session 卡片显示按钮
5. 测试高度动态调整：session 数量变化时 notch 高度应跟随变化