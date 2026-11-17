#!/bin/zsh
# ============================================================================
# install-kext.sh —— Sky CC.app 内置的内核扩展安装脚本
#
# 调用方式：由 launcher 经
#   osascript -e "do shell script \"bash <本脚本>\" with administrator privileges"
# 以 root 身份运行（用户机器上会弹出系统密码框；沙箱/已提权环境直接通过）
#
# 特性：
#   - 幂等：kext 已加载且标识正确 → 直接退出；重复运行安全
#   - 日志：/tmp/skycc-kext-install.log（同时保留 stdout，供 app 读取失败原因）
#   - 非 root 调用时内部自动套 sudo（例如有人手动 bash 它）
#
# 2026-11-17：kext 从 TongfangFan.kext（第三方二进制、无源码）换成 SkyCCEC.kext
#（Sources/ECDriver 自维护，同时提供 EC 通道与 APERF/MPERF 实时频率）：
#   - 服务类名不同：TongfangFanDriver → SkyCCECDriver
#   - 装完会把旧 kext 与旧 LaunchDaemon 一并摘掉，免得两个驱动同时挂在同一个
#     PNP0C14 设备上抢 EC 邮箱
#   - macOS 26 起第三方 kext 不能热加载：新二进制先写入内核集合，重启后生效。
#     `kmutil load -p` 此时只会回 "requires a reboot"，脚本按这个分支正常退出。
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"     # Resources/native
KEXT_SRC="$HERE/SkyCCEC.kext"
KEXT_DST="/Library/Extensions/SkyCCEC.kext"
KEXT_ID="com.skycc.EC"
SERVICE_CLASS="SkyCCECDriver"
DAEMON_LABEL="com.skycc.ec"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"

# 要彻底退役的旧东西（TongfangFan 时代 + MacConsole 时代 + 被合并掉的 MSR 驱动）
OLD_KEXTS=(
  "/Library/Extensions/TongfangFan.kext"
  "/Library/Extensions/SkyCCMSR.kext"
)
OLD_LABELS=(
  "com.skycc.TongfangFan"
  "com.macconsole.TongfangFan"
)

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

kext_running() { ioreg -r -c "$SERVICE_CLASS" 2>/dev/null | grep -q "$SERVICE_CLASS"; }

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# 已加载且磁盘上那份标识正确 → 什么都不做（幂等）
CURRENT_ID=""
if [[ -d "$KEXT_DST" ]]; then
  CURRENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                  "$KEXT_DST/Contents/Info.plist" 2>/dev/null || true)"
fi
if kext_running && [[ "$CURRENT_ID" == "$KEXT_ID" ]]; then
  echo "✓ $SERVICE_CLASS 已在内核运行（$KEXT_ID），无需安装"
  exit 0
fi

# 标识不对（旧版内容或残留）→ 先卸下，避免同名 bundle 被两个驱动争用
if kext_running; then
  echo "→ 0/5 内核里跑着的版本与预期不符（磁盘上是 ${CURRENT_ID:-空}），先卸下"
  $SUDO kmutil unload -p "$KEXT_DST" >/dev/null 2>&1 || true
  sleep 1
fi

# SIP 提示（只提示，不阻断；本机此前检查为 disabled）
csrutil status 2>/dev/null | grep -q "Kext Signing: disabled" || \
  echo "⚠ SIP「Kext Signing」未关闭，kmutil load 大概率失败"

echo "→ 1/5 拷贝 kext 到 $KEXT_DST"
$SUDO rm -rf "$KEXT_DST"
$SUDO cp -R "$KEXT_SRC" "$KEXT_DST"
$SUDO chown -R root:wheel "$KEXT_DST"
$SUDO chmod -R go-w "$KEXT_DST"

echo "→ 2/5 重建内核集合"
# --update-all 是把 /Library/Extensions 的变化并进集合，本身不加载。
# 少了这一步，下一步的 kmutil load 会报 "kext is not in the kernel collection"。
$SUDO kmutil install --volume-root / --update-all -z 2>&1 | tail -3 | sed 's/^/    /'

echo "→ 3/5 立即尝试加载"
LOAD_OUT="$($SUDO kmutil load -z -p "$KEXT_DST" 2>&1)"
echo "$LOAD_OUT" | sed 's/^/    /'
NEED_REBOOT=false
echo "$LOAD_OUT" | grep -qi "reboot" && NEED_REBOOT=true

echo "→ 4/5 摘掉旧驱动与旧守护（TongfangFan / MacConsole 时代）"
for old in "${OLD_KEXTS[@]}"; do
  if [[ -d "$old" ]]; then
    echo "    卸载并删除 $old"
    $SUDO kmutil unload -p "$old" >/dev/null 2>&1 || true
    $SUDO rm -rf "$old"
  fi
done
for label in "${OLD_LABELS[@]}"; do
  if [[ -e "/Library/LaunchDaemons/$label.plist" ]] || \
     launchctl print "system/$label" >/dev/null 2>&1; then
    echo "    清理守护 $label"
    $SUDO launchctl bootout "system/$label" 2>/dev/null || true
    $SUDO launchctl disable "system/$label" 2>/dev/null || true
    $SUDO rm -f "/Library/LaunchDaemons/$label.plist"
  fi
done

echo "→ 5/5 安装开机自动加载（LaunchDaemon + 自有加载器）"
# 2.8.15：先把自己这一份加载器放到控制台的支持库，再让守护指向它。
# 这样「登录项」里显示的是「Sky CC散热扩展」而不是来路不明的 kmutil。
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
$SUDO launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true

$SUDO tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$DAEMON_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DAEMON_PROG</string>
		$DAEMON_ARGS
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/skycc-ec-kext.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/skycc-ec-kext.log</string>
</dict>
</plist>
PLIST
$SUDO chown root:wheel "$DAEMON_PLIST"
$SUDO chmod 644 "$DAEMON_PLIST"
$SUDO launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null || true

echo "→ 验证"
sleep 1
if kext_running; then
  echo "✓ $SERVICE_CLASS 已在内核运行，安装完成"
  exit 0
fi

if [[ "$NEED_REBOOT" == "true" ]]; then
  # macOS 26 的正常路径：二进制已进集合，重启后由守护加载
  echo "✓ kext 已装入系统扩展并写入内核集合，**重启后生效**"
  echo "   重启后验证：ioreg -r -c $SERVICE_CLASS | grep $SERVICE_CLASS"
  exit 0
fi

echo "✗ 加载后仍未发现 $SERVICE_CLASS。排查："
echo "    - sudo kmutil load -p $KEXT_DST"
echo "    - log show --last 2m --predicate 'process == \"kernel\"' | grep -i skycc"
echo "    - codesign --verify --strict $KEXT_DST"
exit 1
