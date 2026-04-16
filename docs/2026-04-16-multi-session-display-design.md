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

## 实现方案

### 1. 新建文件

#### AISessionPriorityHelper.swift

Session 排序逻辑，参考 Claude-Island 的 `phasePriority()`:

```
优先级权重：
- waitingForApproval/processing/compacting: 0 (最高)
- waitingForInput: 1
- idle/ended: 2 (最低)

同优先级按 lastUpdated 倒序排列
```

#### AISessionCardView.swift

单个 session 卡片（参考 Claude-Island `InstanceRow`）：

- 状态图标（蟹=processing，睡=idle，问号=waitingForApproval）
- cwd 项目名（简化显示，取最后一个路径组件）
- 当前工具名（格式化显示）
- MiniApprovalButtons（等待审批时显示）

#### AISessionListView.swift

Session 列表容器（参考 Claude-Island `ClaudeInstancesView`）：

- `ScrollView` + `LazyVStack` 显示 session 列表
- 超出显示容量时显示 "+N more sessions"
- 带动画的插入/移除过渡

#### MiniApprovalButtons.swift

精简版审批按钮：

- Allow/Deny 按钮
- 支持指定 sessionId 和 requestId
- 点击后调用 XPC 响应权限请求

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

- 替换 `AIStatusCardExpanded` 为 `AISessionListView`
- 调整布局适配多卡片

#### BoringViewModel.swift

`effectiveOpenNotchSize` 动态计算高度：

```swift
// 单 session: baseHeight + 55
// 多 session: baseHeight + 55 + (N-1) * 63
// 最多显示 3 个 session
```

#### AILiveActivity.swift

- `AIOnlyLiveActivity` 使用 `highestPrioritySession` 显示状态
- 多个审批 pending 时显示 badge count

#### AgentIconView.swift

添加新组件：

- `ApprovalBadge` - 审批计数徽章
- `SessionStatusIcon` - 统一的 session 状态图标

---

## 数据流

```
AIManager.sessions (字典)
    ↓
AIManager.sortedSessions (排序后的数组)
    ↓
AISessionListView 监听并显示
    ↓
ForEach → AISessionCardView (每个 session)
```

---

## 实现顺序

### Phase 1: 基础设施

1. 创建 `AISessionPriorityHelper.swift`
2. 更新 `AIManager.swift` 添加计算属性

### Phase 2: 展开态 UI

1. 创建 `AISessionCardView.swift`
2. 创建 `AISessionListView.swift`
3. 创建 `MiniApprovalButtons.swift`
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
| `boringNotch/AI/Helpers/AISessionPriorityHelper.swift` | 新建 |
| `boringNotch/AI/Views/AISessionCardView.swift` | 新建 |
| `boringNotch/AI/Views/AISessionListView.swift` | 新建 |
| `boringNotch/AI/Views/MiniApprovalButtons.swift` | 新建 |

---

## 验证方法

1. 启动多个 Claude 会话（不同终端窗口）
2. 测试 ESC 打断单个 session：应该显示 sleep 动画
3. 测试多 session 展开态：应该看到 session 列表
4. 测试权限审批：应该在对应 session 卡片显示按钮
5. 测试高度动态调整：session 数量变化时 notch 高度应跟随变化