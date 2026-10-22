#!/bin/zsh
# 安装亮度守护.command
# ---------------------------------------------------------------------------
# 安装 auxbright v4「PWM 模式保持」守护（2026-10-17 新方案）。
#
# 背景：本机面板默认处于 eDP AUX 背光模式，根本不看 iGPU 的 PWM 引脚；
# macOS 亮度链路只写 PWM 寄存器——这就是「系统亮度滑块失效」的根因。
# 把面板切到 PWM 模式（DPCD 0x721=0x08）后，macOS 原生链路全面接管：
# 滑条/F1F2 -> 系统亮度 -> 原生写 PWM 占空比 -> 屏幕跟随（自带原生渐变）。
#
# 本脚本做的事：
#   1. 安装 auxbright v4 二进制到 ~/bin/auxbright（旧版自动备份）
#   2. 写登录项 plist（com.user.auxbright，RunAtLoad + KeepAlive）
#   3. 让位已废弃的 com.user.auxsmooth 守护（plist 改名 .disabled）
#   4. 立即切换面板到 PWM 模式并验证
#
# 旧方案（auxsmooth.py 轮询+渐变+写 DPCD 0x723）已废弃：
# PWM 模式下 DPCD 写入被面板忽略，且 8 位 + 软件渐变不如原生顺滑。
# ---------------------------------------------------------------------------
set -u
UID_NUM=$(id -u)
SRC="$(cd "$(dirname "$0")" && pwd)/bin/auxbright"
PLIST="$HOME/Library/LaunchAgents/com.user.auxbright.plist"

echo "==> 检查 auxbright v4 二进制"
if [ ! -x "$SRC" ]; then
  echo "❌ 找不到 $SRC"
  read -r -p "按回车退出..." _; exit 1
fi
"$SRC" mode >/dev/null 2>&1 || echo "   (面板暂不可读，稍后重试)"

echo "==> 停掉可能残留的旧守护（auxsmooth / 旧 auxbright）"
pkill -f "auxsmooth.*watch" 2>/dev/null && sleep 0.3
launchctl bootout gui/$UID_NUM/com.user.auxsmooth 2>/dev/null
launchctl bootout gui/$UID_NUM/com.user.auxbright 2>/dev/null

echo "==> 让位已废弃的 auxsmooth 登录项（可随时改回）"
if [ -f "$HOME/Library/LaunchAgents/com.user.auxsmooth.plist" ]; then
  mv "$HOME/Library/LaunchAgents/com.user.auxsmooth.plist" \
     "$HOME/Library/LaunchAgents/com.user.auxsmooth.plist.disabled"
  echo "    已改名: com.user.auxsmooth.plist.disabled"
fi

echo "==> 安装二进制到 ~/bin/auxbright"
mkdir -p "$HOME/bin"
if [ -f "$HOME/bin/auxbright" ]; then
  cp "$HOME/bin/auxbright" "$HOME/bin/auxbright.bak-$(date +%m%d-%H%M)"
  echo "    旧版已备份"
fi
cp "$SRC" "$HOME/bin/auxbright"
chmod 755 "$HOME/bin/auxbright"

echo "==> 写登录项 plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.user.auxbright</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HOME/bin/auxbright</string>
		<string>watch</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>/tmp/auxbright.log</string>
	<key>StandardErrorPath</string>
	<string>/tmp/auxbright.log</string>
</dict>
</plist>
EOF

echo "==> 加载守护"
if launchctl bootstrap gui/$UID_NUM "$PLIST" 2>/dev/null; then
  echo "    bootstrap 成功"
else
  echo "    bootstrap 失败，尝试传统 load"
  launchctl load -w "$PLIST" 2>&1 | sed 's/^/    /'
fi

sleep 1
echo "==> 立即切换面板到 PWM 模式"
"$HOME/bin/auxbright" pwm 2>&1 | sed 's/^/    /'

echo
echo "=== 验证 ==="
if pgrep -f "auxbright watch" >/dev/null; then
  echo "✅ 守护运行中 (PID $(pgrep -f 'auxbright watch' | head -1))，开机自动启动"
else
  echo "⚠️  守护未运行，plist 已就绪，注销重登或重启后生效"
fi
"$HOME/bin/auxbright" mode | sed 's/^/    /'
echo
echo "完成。现在拖系统亮度滑条 / 按 F1F2，亮度由 macOS 原生链路实时驱动。"
echo "守护日志: /tmp/auxbright.log"
echo "卸载: 双击「卸载亮度守护.command」"
echo
read -r -p "按回车关闭此窗口..." _
