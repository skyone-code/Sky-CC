#!/bin/bash
#
# 启动 Mac 控制台
# 双击运行即可：启动本地服务 + 自动打开浏览器
#
set -u
cd "$(dirname "$0")"

PORT="${MACCONSOLE_PORT:-8787}"
URL="http://127.0.0.1:$PORT"

echo "=============================================="
echo "  Mac 控制台 · LAPQC71D"
echo "=============================================="
echo

# ---------- 选择 Python ----------
PY=""
for c in /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3; do
    if [ -x "$c" ]; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    echo "✗ 未找到 python3。"
    echo "  请安装 Xcode 命令行工具：xcode-select --install"
    echo
    read -n 1 -s -r -p "按任意键关闭窗口..."
    exit 1
fi
echo "Python: $PY  ($("$PY" -V 2>&1))"

# ---------- 依赖自检 ----------
# 注意 fanctl.py 必须一起检：server.py 第 32 行是顶层 import fanctl，
# 缺了它服务会直接 ImportError 起不来（而不是 graceful 降级）。
if [ ! -f server.py ] || [ ! -f smc.py ] || [ ! -f rgbkb.py ] || [ ! -f hid.py ] || [ ! -f bright.py ] || [ ! -f fanctl.py ]; then
    echo "✗ 文件不完整，缺少 server.py / smc.py / rgbkb.py / hid.py / bright.py / fanctl.py"
    read -n 1 -s -r -p "按任意键关闭窗口..."
    exit 1
fi
if [ ! -f web/index.html ]; then
    echo "✗ 缺少 web/index.html"
    read -n 1 -s -r -p "按任意键关闭窗口..."
    exit 1
fi
echo "文件自检通过 ✓"

# ---------- 已在运行? ----------
# 注意：如果直接复用旧进程，改过的 server.py 不会生效（界面是每次现读的，
# 所以会出现「新界面 + 旧接口」这种对不上的情况）。所以这里一律先停再启。
if curl -s -o /dev/null --max-time 2 "$URL"; then
    echo "检测到旧服务仍在运行 —— 先停掉它，好让最新代码生效。"
    if [ -f .server.pid ]; then
        PID=$(cat .server.pid 2>/dev/null || echo "")
        if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; fi
        rm -f .server.pid
    fi
    PIDS=$(lsof -ti tcp:$PORT 2>/dev/null || true)
    if [ -n "$PIDS" ]; then echo "$PIDS" | xargs kill 2>/dev/null; fi
    sleep 1.5
fi

# ---------- 启动 ----------
echo "正在启动服务…"
nohup "$PY" server.py > /tmp/macconsole.log 2>&1 &
SRV_PID=$!
echo "$SRV_PID" > .server.pid

for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 1 "$URL"; then
        echo "已就绪 → $URL"
        open "$URL"
        echo
        echo "浏览器已打开。关闭本窗口不影响服务运行。"
        echo "如需停止，双击「停止控制台.command」。"
        sleep 2
        exit 0
    fi
    sleep 0.3
done

echo "✗ 启动超时，日志如下："
echo "----------------------------------------------"
tail -25 /tmp/macconsole.log
echo "----------------------------------------------"
read -n 1 -s -r -p "按任意键关闭窗口..."
exit 1
