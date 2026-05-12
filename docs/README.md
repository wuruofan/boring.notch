# BoringNotch 文档索引

## 目录结构

```
docs/
├── README.md                    # 本文档
├── superpowers/                 # Claude Code superpowers skill
├── architecture/                # 架构文档
│   ├── animation-debugging.md   # 动画调试经验
│   └── claude-island-reference.md  # Claude-Island 参考（待创建）
├── design/                      # AI 功能设计文档
│   ├── ai-state-flow-logic.md   # 状态流转逻辑
│   ├── ai-state-design-v2.md    # 状态设计 V2
│   ├── ai-session-ui-design.md   # Session UI 设计
│   └── ai-multi-agent-support.md # 多 Agent 支持
├── research/                    # AI 调研文档
│   ├── ai-approaches-history.md # 方案历史
│   ├── ai-ideal-solution-analysis.md  # 理想方案分析
│   ├── ai-sessions-state-watch.md    # Sessions 监听方案
│   └── claude-code-hooks-reference.md # Hooks 参考
└── archive/                     # 历史文档（仅供参考）
    ├── 2026-04-09-ai-design-v1-historical.md
    ├── 2026-04-10-ai-research.md
    ├── 2026-04-13-ai-verification.md
    └── 2026-04-16-multi-session-display-design.md
```

## 快速导航

### AI 状态感知功能
- [状态流转逻辑](design/ai-state-flow-logic.md) - 核心状态机设计
- [Sessions 监听方案](research/ai-sessions-state-watch.md) - 权威 idle 状态检测
- [Session UI 设计](design/ai-session-ui-design.md) - Chat 界面设计

### 动画与调试
- [动画调试经验](architecture/animation-debugging.md) - SwiftUI + AppKit 混合动画问题排查

### 参考资料
- [Claude Code Hooks 参考](research/claude-code-hooks-reference.md)
- [多 Agent 支持设计](design/ai-multi-agent-support.md)
