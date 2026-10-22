#!/bin/zsh
# ============================================================================
# autostart.sh —— Mac控制台 开机启动开关
#
# ⚠ 已废弃（2026-10-17）：开机自启改为主 app 内设置
#    （系统页 → 通用 →「开机自动启动」开关，SMAppService 实现）。
#    本脚本与「Mac控制台开机启动.app」toggle 不再打进 DMG，
#    保留仅为兼容已安装旧版；app 开启自启开关时会自动清理本脚本
#    写入的 com.macconsole.autostart 登录项（避免双重自启）。
# ============================================================================
# autostart.sh —— Mac控制台 开机启动开关（历史实现，勿在新环境使用）
#
#   autostart.sh status   输出 on / off
#   autostart.sh on       写入 ~/Library/LaunchAgents/com.macconsole.autostart.plist
#                         并装载（RunAtLoad：登录时 open -a Mac控制台.app）
#   autostart.sh off      卸载并删除 plist
#
# MACCONSOLE_APP_PATH 可覆盖 app 位置（默认 /Applications/Mac控制台.app），
# 供打包测试用。
# ============================================================================
set -u
APP_PATH="${MACCONSOLE_APP_PATH:-/Applications/Mac控制台.app}"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST="$LA_DIR/com.macconsole.autostart.plist"
LABEL="com.macconsole.autostart"
UID_NUM=$(id -u)

write_plist() {
  mkdir -p "$LA_DIR"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>$APP_PATH</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF
}

case "${1:-status}" in
  on)
    if [[ ! -d "$APP_PATH" ]]; then
      echo "错误：找不到 $APP_PATH"
      exit 1
    fi
    write_plist
    launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
    launchctl bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 \
      || launchctl load -w "$PLIST" >/dev/null 2>&1 \
      || true
    # 必须实测验证（load -w 失败时退出码也是 0，不能信）
    if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
      echo "已启用开机启动（登录时自动打开 Mac控制台）"
    else
      echo "开机启动已写入，本次没能立即装载；重启后生效，或去 系统设置→通用→登录项 手动添加"
    fi
    ;;
  off)
    launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
    rm -f "$PLIST"
    echo "已禁用开机启动"
    ;;
  status)
    if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
      echo "on"
    else
      echo "off"
    fi
    ;;
  *)
    echo "用法: $0 on|off|status"
    exit 2
    ;;
esac
