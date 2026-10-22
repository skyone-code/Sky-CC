#!/bin/zsh
# ============================================================================
# ensure-agents.sh —— 安装/刷新 Mac控制台 的用户态 launchd 守护（幂等）
#
#   1. com.user.auxbright       亮度守护（auxbright v4 watch：保持面板 PWM 模式，
#                                RunAtLoad+KeepAlive）。亮度本身由 macOS 原生链路驱动
#   2. com.macconsole.rgbrestore 键盘灯效开机恢复（restore_rgb.sh，RunAtLoad）
#   3. 让位已废弃的 com.user.auxsmooth（bootout + plist 改名 .disabled，可随时改回）
#
# 架构背景（2026-10-17 换新方案，详见 00-先读我.md 1.3）：
#   旧：auxsmooth.py 轮询系统亮度 -> 渐变 -> 写 DPCD 0x723（AUX 背光）
#   新：面板切 PWM 模式（DPCD 0x721=0x08）后 macOS 原生链路全面接管，
#       守护只负责保持模式（睡眠唤醒后面板会复位回 AUX，每秒校验改回）
#
# 由 app 启动器每次启动时调用；内容没变就不重启守护。
# 日志写入 ~/Library/Logs/MacConsole.log（由调用方重定向）
# ============================================================================
set -u
RES="$(cd "$(dirname "$0")/.." && pwd)"     # Resources/
LA_DIR="$HOME/Library/LaunchAgents"
UID_NUM=$(id -u)
LABEL_BL="com.user.auxbright"
LABEL_RGB="com.macconsole.rgbrestore"
AUXBRIGHT="$RES/bin/auxbright"

mkdir -p "$LA_DIR"

bootout_if_running() {
  if launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_NUM/$1" >/dev/null 2>&1
    sleep 0.3
    return 0
  fi
  return 1
}

bootstrap_plist() {
  # 注意：launchctl load -w 失败时退出码也是 0，所以装载后必须用 print 实测验证
  launchctl bootstrap "gui/$UID_NUM" "$1" >/dev/null 2>&1 \
    || launchctl load -w "$1" >/dev/null 2>&1 \
    || true
  launchctl print "gui/$UID_NUM/$2" >/dev/null 2>&1
}

# ---------- 0. 让位已废弃的 auxsmooth 守护（一次性，幂等） ----------
OLD="$LA_DIR/com.user.auxsmooth.plist"
if [[ -f "$OLD" ]]; then
  bootout_if_running "com.user.auxsmooth"
  pkill -f "auxsmooth.*watch" 2>/dev/null && sleep 0.3
  mv "$OLD" "$OLD.disabled"
  echo "[agents] 已废弃的 auxsmooth 守护已让位: $OLD.disabled"
fi

# ---------- 1. 亮度守护（v5: pwmwake 事件驱动，替代 auxbright watch 轮询） ----------
#
#   旧方案 auxbright watch：常驻 tick 循环 + 每秒读 DPCD 0x721 校验模式 + AUX 渐变兜底空转
#   新方案 pwmwake      ：CFRunLoop 挂 IOKit 通知，平时零活动；
#                         事件命中（登录 modeset / 唤醒 / 熄屏重亮）才写一针 0x721=0x08
#   三个翻转触发点已由 2026-10-19 实验 D/E 实锤穷举。
LABEL_BL="com.user.pwmwake"
PWMBIN=""
for cand in "$RES/bin/pwmwake" "$HOME/bin/pwmwake" "/usr/local/bin/pwmwake"; do
  [[ -x "$cand" ]] && PWMBIN="$cand" && break
done
if [[ -z "$PWMBIN" ]]; then
  echo "[agents] 警告: 找不到 pwmwake，跳过亮度守护安装"
else
# 让位旧守护：绝不用 launchctl bootout（服务会永久注销救不回来），用 SIGTERM + plist 改名
if launchctl print "gui/$UID_NUM/com.user.auxbright" >/dev/null 2>&1; then
  launchctl kill SIGTERM "gui/$UID_NUM/com.user.auxbright" >/dev/null 2>&1
fi
if [[ -f "$LA_DIR/com.user.auxbright.plist" ]]; then
  mv "$LA_DIR/com.user.auxbright.plist" "$LA_DIR/com.user.auxbright.plist.v5disabled"
  echo "[agents] 旧 auxbright watch 登录项已让位: com.user.auxbright.plist.v5disabled"
fi
BL_PLIST="$LA_DIR/$LABEL_BL.plist"
BL_TMP="$LA_DIR/.$LABEL_BL.plist.tmp"
cat >"$BL_TMP" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL_BL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$PWMBIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PWMWAKE_LOG</key>
		<string>$HOME/Library/Logs/pwmwake.log</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/pwmwake.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/pwmwake.out.log</string>
</dict>
</plist>
EOF2
if [[ -f "$BL_PLIST" ]] && cmp -s "$BL_TMP" "$BL_PLIST"; then
  if ! launchctl print "gui/$UID_NUM/$LABEL_BL" >/dev/null 2>&1; then
    bootstrap_plist "$BL_PLIST" "$LABEL_BL" && echo "[agents] pwmwake 守护已重新装载" || true
  fi
else
  if launchctl print "gui/$UID_NUM/$LABEL_BL" >/dev/null 2>&1; then
    launchctl kill SIGTERM "gui/$UID_NUM/$LABEL_BL" >/dev/null 2>&1
    sleep 0.3
  fi
  mv "$BL_TMP" "$BL_PLIST"
  bootstrap_plist "$BL_PLIST" "$LABEL_BL"     && echo "[agents] pwmwake 守护已安装（事件驱动，无轮询）"     || echo "[agents] pwmwake 本次没装载成功（plist 就绪，重启后生效）"
fi
rm -f "$BL_TMP"
fi

# ---------- 2. 键盘灯效开机恢复 ----------
RGB_PLIST="$LA_DIR/$LABEL_RGB.plist"
RGB_TMP="$LA_DIR/.$LABEL_RGB.plist.tmp"
cat >"$RGB_TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL_RGB</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$RES/restore_rgb.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/macconsole-rgb.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/macconsole-rgb.log</string>
</dict>
</plist>
EOF
if [[ -f "$RGB_PLIST" ]] && cmp -s "$RGB_TMP" "$RGB_PLIST"; then
  if ! launchctl print "gui/$UID_NUM/$LABEL_RGB" >/dev/null 2>&1; then
    bootstrap_plist "$RGB_PLIST" "$LABEL_RGB" && echo "[agents] rgbrestore 已重新装载" || true
  fi
else
  bootout_if_running "$LABEL_RGB"
  mv "$RGB_TMP" "$RGB_PLIST"
  if bootstrap_plist "$RGB_PLIST" "$LABEL_RGB"; then
    echo "[agents] rgbrestore 已安装（登录时恢复键盘灯效）"
  else
    echo "[agents] rgbrestore 本次没装载成功（plist 就绪，重启后生效）"
  fi
fi
rm -f "$RGB_TMP"

echo "[agents] done"
