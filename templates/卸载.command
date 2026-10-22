#!/bin/zsh
# ============================================================================
# 卸载Mac控制台.command
#
# 做这些事（只有 kext 部分需要 administrator 密码）：
#   1. 停掉正在运行的控制台服务
#   2. 删除三个用户态 LaunchAgent（平滑亮度守护 / 键盘灯恢复 / 开机启动）
#   3. 停掉并删除开机 kext LaunchDaemon，卸载并删除 TongfangFan.kext
#   4. 删除 /Applications 里的两个 app
#   5. 删除状态目录与运行日志
#   6. 清理 /usr/local/bin/auxbright（pkg 时代装过才会有）
#
# 说明：~/Library/Application Support/MacConsole 里的灯效配置/白平衡
#       一并删除；旧版 auxbright watch 的 .disabled 备份保留不动。
# ============================================================================
set -u

APP_DIR="/Applications/Mac控制台.app"
TOGGLE_DIR="/Applications/Mac控制台开机启动.app"
LA_DIR="$HOME/Library/LaunchAgents"
STATE_DIR="$HOME/Library/Application Support/MacConsole"
DAEMON_PLIST="/Library/LaunchDaemons/com.macconsole.TongfangFan.plist"
KEXT_DST="/Library/Extensions/TongfangFan.kext"

echo "=============================================="
echo "  Mac 控制台 · 卸载"
echo "=============================================="
echo
echo "将移除：两个 app、TongfangFan.kext（含开机项）、"
echo "平滑亮度/键盘灯恢复/开机启动 三个 launchd 任务、状态目录与日志。"
echo
read -k 1 -s -r -p "按任意键继续，Control-C 取消..."
echo
echo

echo "→ 1/6 停止正在运行的控制台服务"
# 2.6.0 起没有 HTTP 了：按可执行文件路径找进程（旧的 lsof -i tcp:8787 已失效）
PIDS="$(pgrep -f "/Mac控制台\.app/Contents/MacOS/Mac控制台$" 2>/dev/null || true)"
if [[ -n "$PIDS" ]]; then
  echo "$PIDS" | tr ' ' '\n' | while read -r p; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  sleep 1
  echo "    已停止"
else
  echo "    没有在跑的服务"
fi

echo "→ 1.5/6 注销后台 helper（EC/SMC 守护进程）"
if [[ -x "$APP_DIR/Contents/MacOS/Mac控制台" ]]; then
  "$APP_DIR/Contents/MacOS/Mac控制台" --unregister-helper 2>/dev/null || true
fi
launchctl bootout "gui/$(id -u)/com.macconsole.helper" >/dev/null 2>&1 || true
echo "    已完成（若仍出现在 系统设置→通用→登录项，请手动删除「Mac控制台」条目）"

echo "→ 2/6 删除用户态 LaunchAgent"
for LABEL in com.user.auxsmooth com.macconsole.rgbrestore com.macconsole.autostart; do
  PL="$LA_DIR/$LABEL.plist"
  if [[ -f "$PL" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    rm -f "$PL"
    echo "    已删除 $LABEL"
  fi
done

echo "→ 3/6 卸载 kext（需要管理员密码）"
if [[ -f "$DAEMON_PLIST" || -d "$KEXT_DST" ]]; then
  sudo -v || { echo "✗ 未获得权限，kext 部分保留，其余继续"; }
  sudo launchctl bootout "system/com.macconsole.TongfangFan" >/dev/null 2>&1
  sudo launchctl disable "system/com.macconsole.TongfangFan" >/dev/null 2>&1
  if [[ -d "$KEXT_DST" ]]; then
    sudo kmutil unload -p "$KEXT_DST" >/dev/null 2>&1 \
      && echo "    kext 已卸载" || echo "    kext 卸载失败（可能本就没加载），继续删文件"
  fi
  sudo rm -f "$DAEMON_PLIST"
  sudo rm -rf "$KEXT_DST"
  echo "    已删除开机项与 kext 文件"
else
  echo "    未安装，跳过"
fi

echo "→ 4/6 删除 app"
for D in "$APP_DIR" "$TOGGLE_DIR"; do
  if [[ -d "$D" ]]; then
    rm -rf "$D"
    echo "    已删除 $D"
  fi
done

echo "→ 5/6 删除状态目录与日志"
rm -rf "$STATE_DIR"
rm -f "$HOME/Library/Logs/MacConsole.log"
echo "    完成"

echo "→ 6/6 收尾（保留本机背光修复，清理旧工具）"
# com.user.pwmwake 是本机 eDP 背光修复（登录/睡眠唤醒后把 TCON 抢回 PWM 模式），
# 属于机器级修复而非 app 功能，卸载 app 时【刻意保留】，避免亮度调节再次失效。
if [[ -f "$LA_DIR/com.user.pwmwake.plist" ]]; then
  echo "    保留 com.user.pwmwake（背光修复守护，非本 app 专属）"
  echo "    确需移除：launchctl bootout gui/\$(id -u)/com.user.pwmwake 并删除该 plist"
fi
if [[ -f /usr/local/bin/auxbright ]]; then
  sudo rm -f /usr/local/bin/auxbright && echo "    已删除 /usr/local/bin/auxbright"
else
  echo "    /usr/local/bin/auxbright 不存在，跳过"
fi

echo
echo "卸载完成。"
echo
echo "按任意键关闭..."
read -k 1
