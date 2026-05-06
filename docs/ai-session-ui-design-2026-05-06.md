# AI Session UI 设计文档

> Last updated: 2026-05-06

## 概述

BoringNotch AI 功能的 Session 列表和 ChatView 界面设计规范。

参考 Claude-Island 实现，结合 BoringNotch 特有的音乐区域共存场景。

---

## SessionRow 设计（紧凑态）

SessionRow 是 Notch 展开态的 session 列表项，需要紧凑、信息清晰。

### 布局结构

```
┌─────────────────────────────────────────────┐
│ [状态指示]  项目名                    [按钮] │
│            工具信息 / 状态描述               │
└─────────────────────────────────────────────┘
```

### 第一行

| 元素 | 内容 | 样式 |
|-----|------|------|
| **状态指示器** | 左侧 16×16 区域 | 见状态指示器章节 |
| **项目名** | cwd 最后一级目录 | 13pt medium, 白色 |
| **右侧按钮** | 审批按钮或终端图标 | 见按钮章节 |

### 第二行

| Phase | 显示内容 | 颜色 |
|-------|---------|------|
| `processing` | "Processing..." | 白色 0.4 opacity |
| `runningTool` | 工具名 + 输入摘要 | 见 ToolInputFormatter |
| `waitingForApproval` | 工具名（橙色）+ 输入摘要 | 橙色 0.9 + 白色 0.5 |
| `waitingForInput` | "Ready for input" | 绿色 |
| `compacting` | "Compacting..." | 白色 0.4 opacity |
| `toolFailed` | 工具名 + " failed" | 红色 0.8 |
| `error` | "Error" | 红色 |
| `idle` | "Idle" | 白色 0.3 opacity |

### 不显示的信息

以下信息不在 SessionRow 显示，避免视觉杂乱：

- **sessionId**：项目名已足够区分，详细信息在 ChatView 查看
- **subagentCount**：subagent 工具列表在 ChatView 的 ToolCallView 中详细展示

---

## 状态指示器（左侧）

16×16 区域，根据 phase 显示不同状态：

| Phase | 指示器 | 说明 |
|-------|--------|------|
| `processing` | ProcessingSpinner | 旋转加载动画 |
| `runningTool` | ProcessingSpinner | 旋转加载动画 |
| `compacting` | ProcessingSpinner | 旋转加载动画 |
| `waitingForApproval` | PermissionIndicatorIcon | 橙色权限图标 |
| `waitingForInput` | ReadyForInputIndicatorIcon | 绿色就绪图标 |
| `toolFailed` | FailedIndicatorIcon | 失败图标 |
| `error` | ErrorIndicatorIcon | 错误图标 |
| `idle` | SleepIcon | 睡眠状态（可配置动画） |

---

## 右侧按钮区域

根据 session 状态显示不同按钮组合：

### waitingForApproval 状态

显示紧凑审批按钮：

| 按钮 | 样式 | 行为 |
|-----|------|------|
| **Allow** | 白底黑字 Capsule | `approveOnce` |
| **Deny** | 红色半透明 Capsule | `reject` |

按钮动画：staggered spring（Allow 先出现）

### 其他状态

显示终端图标按钮：

```
┌─────┐
│ 🖥  │  → 点击跳转到 tmux 窗口
└─────┘
```

- 图标：`terminal` system icon
- 样式：11pt medium, 白色 0.4 opacity
- Hover：背景白色 0.1 opacity
- 行为：`jumpToSession()`

---

## 点击行为

| 区域 | 行为 |
|-----|------|
| **Row 整体（点击）** | 打开 ChatView（消息列表） |
| **终端按钮（点击）** | `jumpToSession()` 聚焦 tmux 窗口 |
| **审批按钮（点击）** | approve / deny 权限请求 |

---

## ChatView 设计（展开态）

ChatView 是点击 SessionRow 后打开的详细消息列表界面。

### 窗口尺寸

动态调整：
- **宽度**：600px（SessionList 为 480px）
- **高度**：480px（SessionList 为 320px）

### 布局结构

```
┌─────────────────────────────────────────────┐
│ [← 返回]  项目名                            │  ← Header
├─────────────────────────────────────────────┤
│                                             │
│ 消息列表（ScrollView）                       │  ← Messages
│ - 用户消息（右对齐气泡）                      │
│ - Assistant 消息（左对齐）                   │
│ - Tool 调用（可展开）                        │
│ - Processing 指示器                         │
│                                             │
├─────────────────────────────────────────────┤
│ 输入框 / 审批栏                             │  ← Bottom Bar
└─────────────────────────────────────────────┘
```

### Header

```
[← chevron.left]  项目名
```

- 点击返回：关闭 ChatView，返回 Session 列表
- 项目名：cwd 最后一级目录

### Messages

参考 Claude-Island ChatView：

| 类型 | 样式 |
|-----|------|
| **User 消息** | 右对齐气泡，白色 0.15 背景 |
| **Assistant 消息** | 左对齐，白色圆点指示器 |
| **Tool Call** | 状态圆点 + 工具名 + 输入，可展开查看结果 |
| **Thinking** | 灰色圆点 + 斜体文字 |
| **Processing** | 橙色 spinner + "Processing..." |

### Bottom Bar

根据状态显示不同内容：

#### 等待审批状态（waitingForApproval）

三个按钮（空间充足）：

| 按钮 | 样式 | 行为 |
|-----|------|------|
| **Allow** | 白底黑字 Capsule | 本次允许 |
| **Always Allow** | 边框按钮 | 添加到白名单 |
| **Deny** | 红色边框按钮 | 拒绝（可选填理由） |

#### 其他状态

输入框：

```
┌───────────────────────────────────┐  ┌─────┐
│ Message Claude...                  │  │  ↑  │
└───────────────────────────────────┘  └─────┘
```

- Placeholder：tmux 连接时 "Message Claude..."，否则提示需 tmux
- 发送按钮：箭头图标，输入为空时 disabled
- 行为：`sendReply()` 通过 tmux send-keys 发送消息

---

## 切换流程

### 从 Session 列表到 ChatView

```
用户点击 SessionRow
    ↓
contentType = .chat(session)
    ↓
窗口尺寸动态调整 (480×320 → 600×480)
    ↓
隐藏音乐区域
    ↓
显示 ChatView（消息列表 + Header + Bottom Bar）
```

### 从 ChatView 返回

```
用户点击返回按钮
    ↓
contentType = .instances
    ↓
窗口尺寸恢复 (600×480 → 480×320)
    ↓
恢复音乐区域
    ↓
显示 Session 列表
```

---

## 音乐区域处理

### Session 列表态（contentType = .instances）

```
┌─────────────────────────────────────────────┐
│ [音乐卡片]                                  │  ← 显示
├─────────────────────────────────────────────┤
│ Session 列表                                │
└─────────────────────────────────────────────┘
```

### ChatView 态（contentType = .chat）

```
┌─────────────────────────────────────────────┐
│ [← 返回]  项目名                            │  ← 音乐隐藏
├─────────────────────────────────────────────┤
│ 消息列表                                    │  ← ChatView 全屏
└─────────────────────────────────────────────┘
```

**设计理由**：
- 聊天时用户专注消息交互
- 音乐状态在收起态（DualLiveActivity）仍可见
- ChatView 需要完整空间展示消息列表

---

## 多显示器模式（Separate Display）

### 设置项

| 设置项 | 选项 | 说明 |
|-------|------|------|
| **主Notch显示器** | `fixed(UUID)` | 固定某显示器 |
| | `autoFollow` | 跟随鼠标（只有一个，随鼠标移动） |
| | `allDisplays` | 所有显示器都有主Notch |
| **AI显示器** | `followNotch` | AI跟主Notch（合并态） |
| | `separate(UUID)` | AI在指定显示器 |

### 合并显示逻辑

某显示器同时显示音乐+AI的条件：

```
showBoth = 主Notch在该显示器 && AI也在该显示器
```

**主Notch在某显示器**：
| 主Notch设置 | 条件 |
|------------|------|
| `fixed(X)` | 当前显示器 == X |
| `autoFollow` | 鼠标在当前显示器 |
| `allDisplays` | 始终满足 |

**AI在某显示器**：
| AI设置 | 条件 |
|-------|------|
| `followNotch` | 主Notch在该显示器（跟随） |
| `separate(Y)` | 当前显示器 == Y |

### 场景组合表

| 主Notch设置 | AI设置 | AI显示器展开态 | 其他显示器展开态 |
|------------|--------|---------------|----------------|
| `fixed(笔记本)` | `separate(显示器2)` | AI alone | 音乐 alone |
| `autoFollow` + 鼠标在显示器2 | `separate(显示器2)` | 音乐+AI 合并 | 无主Notch |
| `autoFollow` + 鼠标在其他 | `separate(显示器2)` | AI alone | 音乐 alone（鼠标在该显示器） |
| `allDisplays` | `separate(显示器2)` | 音乐+AI 合并 | 音乐 alone |

### 典型使用场景

**笔记本+大显示器编程场景**：

```
设置：主Notch = allDisplays, AI = separate(显示器2)

笔记本显示器：主Notch(音乐) → 展开态显示音乐 alone
显示器2：主Notch(音乐) + AI Notch → 展开态合并显示音乐+AI
显示器3：主Notch(音乐) → 展开态显示音乐 alone
```

用户在显示器2编程时，一眼看到AI状态，展开时音乐+AI合并显示。

---

## 实现计划

### Phase 1：SessionRow 调整（当前）

1. 去掉 sessionId 显示
2. 去掉 subagentCount 显示
3. 第一行改为：项目名 + 右侧按钮
4. 第二行保持工具/状态描述
5. 点击行为改为打开 ChatView（暂用 placeholder）

### Phase 2：ChatView 实现（后续）

1. 添加 `contentType` 状态（BoringViewModel）
2. 动态窗口尺寸计算
3. ChatView 基础组件（Header + Messages + Bottom Bar）
4. 音乐区域隐藏/显示逻辑
5. 消息加载（从 JSONL 解析）
6. 输入框 + 发送功能

---

## 参考文件

- Claude-Island: `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`
- Claude-Island: `ClaudeIsland/UI/Views/ChatView.swift`
- Claude-Island: `ClaudeIsland/Core/NotchViewModel.swift`
- BoringNotch: `boringNotch/AI/Views/SessionRow.swift`
- BoringNotch: `boringNotch/models/BoringViewModel.swift`