#!/bin/zsh
# ============================================================================
# install-kext.sh —— Sky CC.app 内置的内核扩展安装脚本
#
# 调用方式：由 launcher 经
#   osascript -e "do shell script \"bash <本脚本>\" with administrator privileges"
# 以 root 身份运行（用户机器上会弹出系统密码框；沙箱/已提权环境直接通过）
#
# 特性：
#   - 幂等：kext 已加载 → 直接退出；重复运行安全
#   - 日志：/tmp/skycc-kext-install.log（同时保留 stdout，供 app 读取失败原因）
#   - 非 root 调用时内部自动套 sudo（例如有人手动 bash 它）
#
# 2.8.12：kext 不再单独放 DMG，只有 app 内嵌这一份；app 里点「立即安装」调用本脚本。
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"     # Resources/native
KEXT_SRC="$HERE/TongfangFan.kext"
KEXT_DST="/Library/Extensions/TongfangFan.kext"
DAEMON_PLIST="/Library/LaunchDaemons/com.skycc.TongfangFan.plist"
# 2.8.15：开机加载器用我们自己的二进制，不再让守护直接 exec /usr/bin/kmutil
# （那样「系统设置 → 登录项」里会显示成一条来路不明的 "kmutil"）。
# 放 app 自己的支持库：/Library/PrivilegedHelperTools 与 /usr/local/bin 在本机
# 被 SIP 挡住（root 都 EACCES），只有支持库可写。
# 注意：本脚本以 root 运行，$HOME 是 /var/root，必须从控制台用户反查真实家目录。
LOADER_SRC="$HERE/bin/Sky CC散热扩展"
CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null)"
USER_HOME=""
if [[ -n "$CONSOLE_USER" && -d "/Users/$CONSOLE_USER" ]]; then
  USER_HOME="/Users/$CONSOLE_USER"
else
  USER_HOME="${HOME:-/var/root}"
fi
LOADER_DST="$USER_HOME/Library/Application Support/SkyCC/bin/Sky CC散热扩展"
LOG="/tmp/skycc-kext-install.log"

# 既写日志又把输出留给调用方（osascript 只回传 stdout，全导进日志的话
# app 拿不到任何原因，只能报「未知」）
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') install-kext 开始 (euid=$(id -u)) ==="

if [[ ! -d "$KEXT_SRC" ]]; then
  echo "✗ app 内找不到 kext：$KEXT_SRC（安装包可能不完整，请重新拷贝 app）"
  exit 1
fi

kext_running() { ioreg -r -c TongfangFanDriver 2>/dev/null | grep -q TongfangFanDriver; }

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# 2026-11-17（MacConsole → SkyCC 更名）：更名把 kext 的 CFBundleIdentifier
# 从 com.macconsole.TongfangFan 换成了 com.skycc.TongfangFan。已经装过旧版的机器，
# 磁盘里那份还是旧 id —— 功能上没差别（类名 TongfangFanDriver 不变，
# 所以 IOServiceMatching 照样能匹配），但「彻底退役」要求系统里不留旧标识。
# 检测到 id 不匹配就卸掉重装一次；匹配则维持原来的「已加载即退出」幂等语义。
KEXT_ID_EXPECTED="com.skycc.TongfangFan"
CURRENT_ID=""
if [[ -d "$KEXT_DST" ]]; then
  CURRENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                  "$KEXT_DST/Contents/Info.plist" 2>/dev/null || true)"
fi
NEED_ID_MIGRATE=false
if [[ -d "$KEXT_DST" && "$CURRENT_ID" != "$KEXT_ID_EXPECTED" ]]; then
  NEED_ID_MIGRATE=true
fi

# 已加载且标识已是新名 → 什么都不做
if kext_running && [[ "$NEED_ID_MIGRATE" == "false" ]]; then
  echo "✓ TongfangFanDriver 已在内核运行，无需安装"
  exit 0
fi

# 已加载但标识是旧名 → 先卸下（否则同一个驱动类被两个 bundle 争用）
if kext_running && [[ "$NEED_ID_MIGRATE" == "true" ]]; then
  echo "→ 0/4 旧版 kext 标识为「${CURRENT_ID:-未知}」，先卸下以换成 $KEXT_ID_EXPECTED"
  $SUDO kmutil unload -p "$KEXT_DST" >/dev/null 2>&1 || true
  sleep 1
fi

# SIP 提示（只提示，不阻断；本机此前检查为 disabled）
csrutil status 2>/dev/null | grep -q "Kext Signing: disabled" || \
  echo "⚠ SIP「Kext Signing」未关闭，kmutil load 大概率失败"

echo "→ 1/4 拷贝 kext 到 $KEXT_DST"
$SUDO rm -rf "$KEXT_DST"
$SUDO cp -R "$KEXT_SRC" "$KEXT_DST"
$SUDO chown -R root:wheel "$KEXT_DST"

echo "→ 2/4 立即加载"
$SUDO kmutil load -p "$KEXT_DST" 2>&1 | sed 's/^/    /'

echo "→ 3/4 安装开机自动加载（LaunchDaemon + 自有加载器）"
# 2.8.15：先把自己这一份加载器放到控制台的支持库，再让守护指向它。
# 这样「登录项」里显示的是「Sky CC散热扩展」而不是来路不明的 kmutil。
#
# 2.8.15 修正：原来这里 mkdir 的是 /Library/PrivilegedHelperTools，而拷贝目标是
# 用户支持库 —— 新机器上那个目录还不存在，cp 静默失败后 DAEMON_PROG 指向不存在的
# 路径，表现是「装完 kext 能跑，但重启后不再自动加载」。现在按目标父目录建。
if [[ -x "$LOADER_SRC" ]]; then
  $SUDO mkdir -p "$(dirname "$LOADER_DST")"
  $SUDO cp "$LOADER_SRC" "$LOADER_DST" 2>/dev/null
  $SUDO chown root:wheel "$LOADER_DST" 2>/dev/null
  $SUDO chmod 755 "$LOADER_DST" 2>/dev/null
fi

if [[ -x "$LOADER_DST" ]]; then
  echo "    加载器 → $LOADER_DST"
  DAEMON_PROG="$LOADER_DST"
  DAEMON_ARGS=""
  # 加载器放在用户 home 里：FileVault 开启时开机阶段 home 未解锁，守护读不到它。
  if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
    echo "    ⚠️ 检测到 FileVault 已开启：开机时 home 未解锁，kext 可能不会自动加载。"
    echo "       如遇重启后散热失效，请关闭 FileVault 或在控制台里重新点「立即安装」。"
  fi
else
  # 兜底：加载器缺失/拷贝失败时退回 kmutil（功能正常，只是登录项里显示 kmutil）
  echo "    ⚠️ 加载器不可用（缺失或拷贝失败），退回 kmutil 方式"
  DAEMON_PROG="/usr/bin/kmutil"
  DAEMON_ARGS="<string>load</string><string>-p</string><string>$KEXT_DST</string>"
fi

# 先卸掉旧守护，避免 label 冲突导致新 ProgramArguments 不生效
$SUDO launchctl bootout "system/com.skycc.TongfangFan" 2>/dev/null || true

# 2026-11-17（MacConsole → SkyCC 更名）：老版本装的是 com.macconsole.TongfangFan，
# 它的 plist 还留在 /Library/LaunchDaemons 里。两个 label 同时存在会各跑一份加载器，
# 风扇控制互相打架（一方交还 0x751、另一方又接管）。所以在这里一并摘掉：
#   · bootout 让 launchd 立刻忘掉这个 job
#   · launchctl disable 防止它被 RunAtLoad 重新拉起
#   · 删 plist，避免重启后又被 bootstrap
OLD_LABEL="com.macconsole.TongfangFan"
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"
if [ -e "$OLD_PLIST" ] || launchctl print "system/$OLD_LABEL" >/dev/null 2>&1; then
  echo "   清理旧守护 $OLD_LABEL（MacConsole 时代遗留）"
  $SUDO launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
  $SUDO launchctl disable "system/$OLD_LABEL" 2>/dev/null || true
  $SUDO rm -f "$OLD_PLIST"
fi

$SUDO tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.skycc.TongfangFan</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DAEMON_PROG</string>
		$DAEMON_ARGS
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/skycc-fankext.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/skycc-fankext.log</string>
</dict>
</plist>
PLIST
$SUDO chown root:wheel "$DAEMON_PLIST"
$SUDO chmod 644 "$DAEMON_PLIST"
$SUDO launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null || true

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
