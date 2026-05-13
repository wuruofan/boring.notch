# Progress

> Last updated: 2026-05-13

## 🎯 Current Focus

- **shelf→home 动画跳动**（多 session 时窗口顶部短暂脱离屏幕边缘）

## 📥 Todo Queue

- [可选] 优化 fallback 轮询频率（当前 15s，可改为 5s）
- [待调研] Codex/OpenCode/Cursor Hook 机制

## ✅ Recently Completed

- **2026-05-12**: 文档架构重组
  - CLAUDE.md 更新项目结构和动画代码
  - 提取动画调试经验到 docs/architecture/animation-debugging.md
  - docs 目录重组为 design/、research/、archive/
- **2026-05-11**: 视图切换动画全局平滑化
  - 修复：仅 expand→home 使用目标高度立即设置，其他方向全部插值
  - Chat view 宽度 600→640 与 home/shelf 保持一致

## 🧱 Blockers & Issues

### shelf→home 动画跳动（未解决）

**现象**：多 AI session（2+）时，从 shelf 切回 home，窗口顶部会短暂脱离屏幕边缘（约 6-10px），随后恢复。1 个 session 时无明显跳动。

**关键发现**：

1. **窗口 frame 始终正确**：`diff_top` = 0.0，`setFrame` 后 top edge 未移动
2. **NSHostingView.intrinsicContentSize 始终小于窗口 frame**：差 1-16px
3. **子类化 TopAlignedHostingView**（覆写 intrinsicContentSize = frame.size）不解决问题
4. **home→shelf**（大→小）不跳，**shelf→home**（小→大）跳

**已排除的原因**：
- 窗口 frame 计算错误
- macOS 自动调整窗口位置
- display:true / false
- maxHeight vs height
- VStack + Spacer 强制顶部对齐  
- SwiftUI 原生 withAnimation
- 内容 layoutSubtreeIfNeeded

**待验证的嫌疑**：
- home 页面呈现时 SwiftUI 内容渲染有 1-2 帧延迟，视觉上看起来像跳动
- SessionList 高度变化引起的视觉错觉（非窗口级，而是内容级）
- 音乐封面 matchedGeometryEffect hero 动画在 notchSize 变化时的视觉副作用

**当前代码改动**（尚未提交）：
- `BoringViewCoordinator`: 新增 `previousView` 属性
- `boringNotchApp.swift`: `isExpandToHome` → `isChatToHome`（仅 chat→home 使用 target-immediately）
- `boringNotchApp.swift`: `TopAlignedHostingView` 子类（覆写 intrinsicContentSize）
- 详细日志（diff_Y, diff_top, cv frame）

## 🧠 Context Notes

### Sessions 状态文件发现
- 路径: `~/.claude/sessions/<pid>.json`
- 字段: `{sessionId, status: "busy"/"idle", pid, cwd}`
- **关键**: status="idle" 是权威状态，覆盖所有阶段的 ESC 打断检测

### 状态合并逻辑
```
sessions idle → 最终 idle (权威，不可覆盖)
sessions busy + Hook → 详细 phase
  ├─ busy + waiting_for_approval → waitingForApproval
  ├─ busy + running_tool → runningTool
  └─ busy + 其他 → processing
```

### 多 Agent 支持设计思路
见 `docs/design/ai-multi-agent-support.md`

### 视图切换动画架构
见 `docs/architecture/animation-debugging.md` 和 CLAUDE.md 动画相关章节

## ⚡ Quick Recovery
- `git pull`
- open: BoringNotchAIXPCHelper/SessionsWatcher.swift, boringNotch/AI/AIManager.swift

## 📅 Task History (Last 7 days)
<!-- Automatically generated, sorted by date in descending order -->

| 日期 | 任务 | 状态 |
|------|------|------|
| 2026-05-13 | shelf→home 动画跳动排查（进行中） | 🔧 排查中 |
| 2026-05-12 | 文档架构重组 | ✅ 完成 |
| 2026-05-11 | 视图切换动画全局平滑化 | ✅ 完成 |
| 2026-04-28 | 僵尸 session 清理 | ✅ 完成 |
| 2026-04-27 | XPC 推送链路验证 | ✅ 完成 |
| 2026-04-27 | JSONL Interrupt 验证 | ✅ 完成 |

## 🏛️ Archive Links
<!-- Automatically generated, pointing to historical archive files -->

暂无