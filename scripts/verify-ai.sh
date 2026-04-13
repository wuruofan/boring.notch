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
