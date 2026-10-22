#!/bin/zsh
# ============================================================================
# install-kext.sh —— Mac控制台.app 内置的内核扩展安装脚本
#
# 调用方式：由 launcher 经
#   osascript -e "do shell script \"bash <本脚本>\" with administrator privileges"
# 以 root 身份运行（用户机器上会弹出系统密码框；沙箱/已提权环境直接通过）
#
# 特性：
#   - 幂等：kext 已加载 → 直接退出；重复运行安全
#   - 日志：/tmp/macconsole-kext-install.log
#   - 非 root 调用时内部自动套 sudo（例如有人手动 bash 它）
#
# 与桌面版「安装散热控制.command」同一套命令，失败排查方式一致。
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"     # Resources/
KEXT_SRC="$HERE/TongfangFan.kext"
KEXT_DST="/Library/Extensions/TongfangFan.kext"
DAEMON_PLIST="/Library/LaunchDaemons/com.macconsole.TongfangFan.plist"
LOG="/tmp/macconsole-kext-install.log"

exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') install-kext 开始 (euid=$(id -u)) ==="

if [[ ! -d "$KEXT_SRC" ]]; then
  echo "✗ bundle 内找不到 kext：$KEXT_SRC"
  exit 1
fi

kext_running() { ioreg -r -c TongfangFanDriver 2>/dev/null | grep -q TongfangFanDriver; }

# 已加载 → 什么都不做
if kext_running; then
  echo "✓ TongfangFanDriver 已在内核运行，无需安装"
  exit 0
fi

# SIP 提示（只提示，不阻断；本机此前检查为 disabled）
csrutil status 2>/dev/null | grep -q "Kext Signing: disabled" || \
  echo "⚠ SIP「Kext Signing」未关闭，kmutil load 大概率失败"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

echo "→ 1/4 拷贝 kext 到 $KEXT_DST"
$SUDO rm -rf "$KEXT_DST"
$SUDO cp -R "$KEXT_SRC" "$KEXT_DST"
$SUDO chown -R root:wheel "$KEXT_DST"

echo "→ 2/4 立即加载"
$SUDO kmutil load -p "$KEXT_DST" 2>&1 | sed 's/^/    /'

echo "→ 3/4 安装开机自动加载 LaunchDaemon"
$SUDO tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.macconsole.TongfangFan</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/kmutil</string>
		<string>load</string>
		<string>-p</string>
		<string>$KEXT_DST</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/macconsole-fankext.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/macconsole-fankext.log</string>
</dict>
</plist>
PLIST
$SUDO chown root:wheel "$DAEMON_PLIST"
$SUDO chmod 644 "$DAEMON_PLIST"

echo "→ 4/4 验证"
sleep 1
if kext_running; then
  echo "✓ TongfangFanDriver 已在内核运行，安装完成"
  exit 0
else
  echo "✗ 加载后仍未发现 TongfangFanDriver。排查："
  echo "    - sudo kmutil load -p $KEXT_DST"
  echo "    - log show --last 2m --predicate 'process == \"kernel\"' | grep -i tongfang"
  exit 1
fi
