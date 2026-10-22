#!/bin/zsh
# 卸载亮度守护.command
# ---------------------------------------------------------------------------
# 停掉 auxbright v4「PWM 模式保持」守护并取消开机自启。
#
# ⚠️ 卸载后的行为变化（务必知情）：
#   面板当前处于 PWM 模式时会继续正常工作（模式是面板寄存器状态，掉电才丢），
#   **直到下一次睡眠唤醒**——唤醒后面板会复位回 AUX 模式，此时 macOS 的
#   原生亮度写入（PWM 寄存器）面板不再理会，亮度调节将失效（旧方案时代的
#   老问题）。重新安装守护（或启动一次 Mac控制台.app，它会自动装回）即可恢复。
#
#   本脚本不动面板模式：留在 PWM 模式至少现在还是好的。
# ---------------------------------------------------------------------------
set -u
UID_NUM=$(id -u)
PLIST="$HOME/Library/LaunchAgents/com.user.auxbright.plist"

echo "==> 停掉亮度守护"
launchctl bootout gui/$UID_NUM/com.user.auxbright 2>/dev/null
pkill -f "auxbright watch" 2>/dev/null && sleep 0.3

echo "==> 删除登录项 plist"
rm -f "$PLIST"

echo "==> 检查是否有已废弃的 auxsmooth 登录项"
if [ -f "$HOME/Library/LaunchAgents/com.user.auxsmooth.plist.disabled" ]; then
  echo "    发现 com.user.auxsmooth.plist.disabled（旧方案，已废弃）"
  echo "    如需恢复旧行为，手动改名回 .plist 后 launchctl bootstrap 即可；"
  echo "    不建议——旧方案是 8 位 AUX + 软件渐变，不如现在的原生链路。"
fi

sleep 1
if pgrep -f "auxbright watch" >/dev/null; then
  echo "⚠️  守护进程仍在运行（PID $(pgrep -f 'auxbright watch' | head -1)）"
  echo "    若是 Mac控制台.app 的登录项装的，启动一次 app 会自动装回；"
  echo "    想彻底停掉: launchctl bootout gui/$UID_NUM/com.user.auxbright"
else
  echo "✅ 守护已停止，开机自启已取消"
fi

echo
echo "注意：下次睡眠唤醒后面板会回到 AUX 模式，亮度调节将失效。"
echo "      恢复方法：双击「安装亮度守护.command」，或启动 Mac控制台.app。"
echo
read -r -p "按回车关闭此窗口..." _
