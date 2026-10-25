#!/bin/bash
#
# 停止 Mac 控制台本地服务
#
set -u
cd "$(dirname "$0")"

PORT="${MACCONSOLE_PORT:-8787}"

echo "正在停止 Mac 控制台…"

STOPPED=0
if [ -f .server.pid ]; then
    PID=$(cat .server.pid 2>/dev/null || echo "")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null && { echo "已停止服务 (PID $PID)"; STOPPED=1; }
    fi
    rm -f .server.pid
fi

if [ "$STOPPED" = "0" ]; then
    # 按端口兜底查找
    PIDS=$(lsof -ti tcp:$PORT 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill 2>/dev/null && { echo "已停止服务 (端口 $PORT)"; STOPPED=1; }
    fi
fi

if [ "$STOPPED" = "0" ]; then
    echo "未发现正在运行的控制台服务。"
fi

sleep 1
