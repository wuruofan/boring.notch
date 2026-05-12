# BoringNotch AI 集成验证方案

- **创建日期**: 2026-04-13
- **对应实现**: `docs/2026-04-10-ai-research.md`
- **架构**: XPC Helper（sandbox OFF）运行 Socket + 主 app（sandbox ON）文件监听

---

## 1. 编译验证

```bash
xcodebuild -scheme boringNotch -configuration Debug build
```

**预期**: `BUILD SUCCEEDED`

---

## 2. 基础设施验证（无需 Claude Code）

### 2.1 XPC Helper + Socket 服务

启动 BoringNotch 后：

```bash
# Socket 文件
ls -la /tmp/boringnotch-ai.sock
# 预期：文件存在，权限 777

# XPC bundle 嵌入
ls boringNotch.app/Contents/XPCServices/BoringNotchAIXPCHelper.xpc
# 预期：目录存在

# 状态文件（事件触发后才会出现）
ls -la /tmp/boringnotch-ai-state.json
# 预期：发送事件后文件存在
```

### 2.2 Hook 脚本安装

```bash
ls -la ~/.claude/hooks/boringnotch-ai-state.py
```

**预期**: 文件存在，权限 755

```bash
cat ~/.claude/settings.json | python3 -m json.tool | grep -A5 boringnotch
```

**预期**: 包含 10 个 hook 事件注册（UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, Stop, SubagentStop, SessionStart, SessionEnd, PreCompact）

### 2.3 settings.json 备份

```bash
ls -la ~/.claude/settings.json.boringnotch-backup
```

**预期**: 文件存在，内容为修改前的原始配置

**恢复命令**（如需回滚）：

```bash
cp ~/.claude/settings.json.boringnotch-backup ~/.claude/settings.json
```

### 2.4 Settings 面板

| 操作 | 预期 |
|------|------|
| 打开 Settings | 侧栏出现 "AI Agents"（brain 图标） |
| Hook status | 显示 "Installed"（绿色） |
| 点击 "Uninstall hooks" | status 变为 "Not installed"（橙色） |
| 点击 "Reinstall hooks" | status 恢复 "Installed" |
| 关闭 "Enable AI integration" | AI 状态消失，Socket 停止 |
| 重新开启 | AI 恢复，Socket 重启 |
| 关闭 "Show AI status in notch" | AI 状态不在 Notch 显示，Socket 仍运行 |

---

## 3. Socket 事件模拟验证

无需 Claude Code，手动发送 JSON 事件测试 UI 渲染。

### 3.1 Processing 事件

```bash
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'test-001',
    'cwd': '/tmp/test',
    'event': 'UserPromptSubmit',
    'status': 'processing',
    'pid': 12345,
    'tty': '/dev/ttys001'
}).encode())
sock.close()
"
```

**预期**: Notch 出现橙色 brain 图标 + 脉冲点动画

### 3.2 Running Tool 事件

```bash
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'test-001',
    'cwd': '/tmp/test',
    'event': 'PreToolUse',
    'status': 'running_tool',
    'tool': 'Read',
    'tool_input': {'file_path': '/tmp/test.txt'},
    'tool_use_id': 'tool-001',
    'pid': 12345,
    'tty': '/dev/ttys001'
}).encode())
sock.close()
"
```

**预期**: 动画继续（processing 状态）

### 3.3 Waiting For Approval 事件

```bash
python3 -c "
import socket, json, time
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'test-001',
    'cwd': '/tmp/test',
    'event': 'PermissionRequest',
    'status': 'waiting_for_approval',
    'tool': 'Write',
    'tool_input': {'file_path': '/tmp/test.txt'},
    'tool_use_id': 'tool-002',
    'pid': 12345,
    'tty': '/dev/ttys001'
}).encode())
# 保持连接 5 秒（模拟等待权限决策）
time.sleep(5)
sock.close()
"
```

**预期**:
- Notch 出现橙色警告图标闪烁
- 点击展开显示权限请求 UI（Tool: Write, Allow/Always Allow/Deny 按钮）

### 3.4 Waiting For Input 事件

```bash
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'test-001',
    'cwd': '/tmp/test',
    'event': 'Stop',
    'status': 'waiting_for_input',
    'pid': 12345,
    'tty': '/dev/ttys001'
}).encode())
sock.close()
"
```

**预期**: Notch 显示绿色对勾图标

### 3.5 Session End 事件

```bash
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'test-001',
    'cwd': '/tmp/test',
    'event': 'SessionEnd',
    'status': 'ended',
    'pid': 12345,
    'tty': '/dev/ttys001'
}).encode())
sock.close()
"
```

**预期**: AI 状态消失，Notch 恢复正常

---

## 4. Claude Code 集成验证（需要 tmux）

### 4.1 环境准备

```bash
which tmux    # 确认 tmux 可用
which claude  # 确认 Claude Code 可用
pgrep -f boringNotch  # 确认 BoringNotch 运行中
```

### 4.2 Phase 1：单向状态接收

```bash
tmux new -s claude-test
claude
```

在 Claude 中发送消息：

```
> hello, what is 2+2?
```

**检查项**:

- [ ] Notch 中出现 AI 状态动画（脉冲点）
- [ ] 处理完成后动画变为绿色对勾
- [ ] 等待输入时 Notch 恢复

### 4.3 Phase 2：权限请求交互

在 Claude 中触发需要权限的操作：

```
> write a file called /tmp/boringnotch-test.txt with content "hello"
```

**检查项**:

- [ ] Notch 出现橙色警告闪烁
- [ ] 点击 Notch 展开，显示权限请求 UI
- [ ] 显示工具名和参数
- [ ] 点击 "Allow" → 终端中 Claude 自动批准
- [ ] 或点击 "Deny" → Claude 收到拒绝

### 4.4 Phase 2：Reply 功能

在 Claude 等待输入时，展开 Notch → 在输入框中输入文字 → 点击发送。

**检查项**:

- [ ] 文本通过 tmux send-keys 发送到终端
- [ ] Claude 收到消息并继续处理

### 4.5 非 tmux 环境降级

直接在 Terminal.app 中运行 `claude`（不在 tmux 中），触发权限请求。

**检查项**:

- [ ] Notch 仍显示 AI 状态
- [ ] 点击 Allow/Deny 时，终端窗口被激活（AppleScript）
- [ ] 用户需手动在终端中输入 y/n

---

## 5. 双实况 UI 验证（Phase 3）

### 5.1 音乐 + AI 同时显示

1. 播放音乐（Apple Music / Spotify）
2. 同时在 tmux 中运行 Claude Code 并发送消息

**检查项**:

- [ ] 胶囊宽度扩展
- [ ] AI 图标从左侧滑入
- [ ] AI 状态动画从右侧滑入
- [ ] 分割线淡入
- [ ] 音乐封面和波形保持不变

### 5.2 状态转换动画

| 操作 | 预期动画 |
|------|----------|
| AI 开始处理 | 胶囊扩展 + AI 元素从两侧滑入 |
| AI 处理完成 | AI 元素淡出 + 胶囊收缩 |
| 音乐停止 | 仅 AI 显示 |
| AI 停止 | 仅音乐显示 |

---

## 6. 健壮性验证

### 6.1 多实例场景

在两个 tmux 窗口中分别启动 Claude Code，同时发送消息。

**检查项**:

- [ ] Notch 显示最新活跃会话的状态
- [ ] 不会崩溃或状态混乱

### 6.2 Socket 异常

```bash
# 删除 socket 文件
rm /tmp/boringnotch-ai.sock
```

**检查项**:

- [ ] BoringNotch 不崩溃
- [ ] AI 状态显示断连

### 6.3 Hook 脚本被删除

```bash
rm ~/.claude/hooks/boringnotch-ai-state.py
```

重启 BoringNotch。

**检查项**:

- [ ] Hook 脚本自动重新安装
- [ ] settings.json 中 hooks 仍存在

### 6.4 Persistent Peek 超时

发送 processing 事件后等待 10 分钟。

**检查项**:

- [ ] 10 分钟后 AI peek 自动消失

### 6.5 settings.json 写入安全

1. 记录当前 `settings.json` 的 MD5
2. 触发 hook 安装
3. 验证备份文件已创建
4. 验证原文件未被损坏

```bash
md5 ~/.claude/settings.json
# 触发安装后
ls ~/.claude/settings.json.boringnotch-backup
python3 -m json.tool ~/.claude/settings.json > /dev/null
```

**检查项**:

- [ ] 备份文件存在
- [ ] settings.json 是合法 JSON
- [ ] 原有配置未被删除

---

## 7. 快速验证脚本

保存为 `scripts/verify-ai.sh` 运行：

```bash
#!/bin/bash
set -e

echo "=== BoringNotch AI 集成验证 ==="

# 1. 编译
echo "[1/6] 编译验证..."
xcodebuild -scheme boringNotch -configuration Debug build -quiet 2>/dev/null
echo "  ✅ 编译成功"

# 2. Socket
echo "[2/6] Socket 验证..."
if [ -S /tmp/boringnotch-ai.sock ]; then
    echo "  ✅ Socket 文件存在"
else
    echo "  ⚠️  Socket 未创建（需要先启动应用）"
fi

# 3. Hook 脚本
echo "[3/6] Hook 脚本验证..."
if [ -f ~/.claude/hooks/boringnotch-ai-state.py ]; then
    echo "  ✅ Hook 脚本已安装"
else
    echo "  ⚠️  Hook 脚本未安装（需要先启动应用）"
fi

# 4. Settings.json
echo "[4/6] Settings.json 验证..."
if grep -q "boringnotch-ai-state.py" ~/.claude/settings.json 2>/dev/null; then
    echo "  ✅ Hooks 已注册到 settings.json"
else
    echo "  ⚠️  Hooks 未注册（需要先启动应用）"
fi

# 5. 备份
echo "[5/6] 备份验证..."
if [ -f ~/.claude/settings.json.boringnotch-backup ]; then
    echo "  ✅ settings.json 备份已存在"
else
    echo "  ⚠️  备份未创建（需要先触发 hook 安装）"
fi

# 6. 发送测试事件
echo "[6/6] 发送测试事件..."
if [ -S /tmp/boringnotch-ai.sock ]; then
    python3 -c "
import socket, json, time

# 发送 processing
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'verify-test',
    'cwd': '/tmp',
    'event': 'UserPromptSubmit',
    'status': 'processing',
    'pid': 99999,
    'tty': ''
}).encode())
sock.close()
print('  ✅ processing 事件已发送（检查 Notch 动画）')
time.sleep(3)

# 清理
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('/tmp/boringnotch-ai.sock')
sock.sendall(json.dumps({
    'session_id': 'verify-test',
    'cwd': '/tmp',
    'event': 'SessionEnd',
    'status': 'ended',
    'pid': 99999,
    'tty': ''
}).encode())
sock.close()
print('  ✅ 清理事件已发送')
"
else
    echo "  ⚠️  跳过（Socket 未创建）"
fi

echo ""
echo "=== 验证完成 ==="
echo ""
echo "下一步："
echo "  1. 启动 BoringNotch 应用"
echo "  2. 在 tmux 中运行 claude 进行端到端测试"
echo "  3. 播放音乐测试双实况 UI"
```

运行方式：

```bash
chmod +x scripts/verify-ai.sh
./scripts/verify-ai.sh
```

---

## 8. 验证优先级

| 优先级 | 验证项 | 原因 |
|--------|--------|------|
| P0 | 编译通过 | 所有后续验证的前提 |
| P0 | Socket + Hook 安装 | 核心通信链路 |
| P0 | settings.json 备份和原子写入 | 用户数据安全 |
| P1 | Socket 事件模拟 | UI 渲染正确性 |
| P1 | Claude Code + tmux 端到端 | 完整功能验证 |
| P2 | 双实况 UI | 体验优化 |
| P2 | 健壮性（断连、多实例） | 边界情况 |
