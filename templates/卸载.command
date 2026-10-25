#!/bin/zsh
# ============================================================================
# 卸载Mac控制台.command —— 彻底卸载
#
# 目标：把 Mac控制台 在这台机器上留下的**每一样东西**都清掉，
#       不只是把 .app 拖进废纸篓。清完「系统设置 → 通用 → 登录项」、
#       launchd、内核扩展、偏好设置里都不再有它的痕迹。
#
# 具体清这些东西：
#   ① 进程      主程序（含旧版拉起的实例）、MacConsoleHelper、历史 pwmwake 残留进程
#   ② 系统注册  SMAppService 的注册（helper / mainApp 登录项；autostart 是 ≤2.8.15
#               的历史遗留，打包时已移除那份 plist，这里只清旧机器残留）
#               —— 这些记录在系统数据库里，删 plist 或 bootout 都清不掉，
#               必须让 app 自己调 --unregister-all 注销
#   ③ 内核扩展  /Library/Extensions/TongfangFan.kext
#               + /Library/LaunchDaemons/com.macconsole.TongfangFan.plist
#               + 开机加载器（支持库内「Mac控制台散热扩展」）
#               + kmutil unload（都需要管理员密码）
#   ④ 登录项    ~/Library/LaunchAgents 下 com.macconsole.*（含历史 rgbrestore）
#               以及旧版亮度守护 com.user.pwmwake / auxbright / auxsmooth
#   ⑤ app       /Applications 与 ~/Applications 里的 Mac控制台（含旧「开机启动」app）
#   ⑥ 数据      ~/Library/Application Support/MacConsole（灯效档 / 风扇曲线 / 记忆 / 锁）
#   ⑦ 偏好      com.macconsole.app 整个 UserDefaults 域（pref.* 全部设置项）
#   ⑧ 缓存      Caches / Containers / HTTPStorages / WebKit / Saved Application State
#   ⑨ 日志      ~/Library/Logs/macconsole*.log、pwmwake.out.log、/tmp/macconsole*
#   ⑩ 旧工具    /usr/local/bin 下 auxbright / pwmwake / fanctl 之类历史残留
#
# 结束时会把「所有应该消失的路径」再扫一遍，列出仍然存在的残留。
# ============================================================================
set -u

APP_DIRS=(
  "/Applications/Mac控制台.app"
  "$HOME/Applications/Mac控制台.app"
  "/Applications/Mac控制台开机启动.app"
  "$HOME/Applications/Mac控制台开机启动.app"
)
LA_DIR="$HOME/Library/LaunchAgents"
SUPPORT="$HOME/Library/Application Support/MacConsole"
DAEMON_PLIST="/Library/LaunchDaemons/com.macconsole.TongfangFan.plist"
KEXT_DST="/Library/Extensions/TongfangFan.kext"
# 2.8.15：开机加载器放在控制台支持库里（/Library/PrivilegedHelperTools 被 SIP 挡住）
LOADER_DST="$SUPPORT/bin/Mac控制台散热扩展"
# 早期试验版曾想把它放到这里，一并清掉
LOADER_OLD="/Library/PrivilegedHelperTools/Mac控制台散热扩展"
UID_NUM=$(id -u)

echo "=============================================="
echo "  Mac 控制台 · 彻底卸载"
echo "=============================================="
echo
echo "将要清除："
echo "  · 主程序 / 后台守护 / 历史 pwmwake 残留进程"
echo "  · 登录项与后台任务注册（helper、静默启动、开机自启）"
echo "  · TongfangFan.kext 与它的开机加载项"
echo "  · $SUPPORT（灯效 / 风扇曲线 / 软件记忆）"
echo "  · com.macconsole.app 的全部偏好设置、缓存、日志"
echo
echo "⚠️  软件记忆（散热档、灯效、充电阈值等）会一并删除，重装后需要重新设置。"
echo
read -k 1 -s -r -p "按任意键继续，Control-C 取消..."
echo
echo

# ---------------------------------------------------------------- ① 停进程
echo "→ 1/9 停止正在运行的进程"
for D in "${APP_DIRS[@]}"; do
  BIN="$D/Contents/MacOS/Mac控制台"
  [[ -x "$BIN" ]] || continue
  # --unregister-all 注销 helper / mainApp 两条现役注册，外加 autostart 历史残留
  # （3.0.1 起 bundle 不含 autostart plist，SMAppService 那条只能清旧机器）。
  # 必须在删 app 之前跑：注册记录在系统数据库里，只删文件清不掉。
  "$BIN" --unregister-all 2>/dev/null && echo "    已注销后台注册（$D）"
done

# 主程序（精确匹配可执行文件路径，避免误杀）
PIDS="$(pgrep -f '/Mac控制台\.app/Contents/MacOS/Mac控制台$' 2>/dev/null || true)"
if [[ -n "$PIDS" ]]; then
  echo "$PIDS" | tr ' ' '\n' | while read -r p; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  sleep 1
  PIDS="$(pgrep -f '/Mac控制台\.app/Contents/MacOS/Mac控制台$' 2>/dev/null || true)"
  if [[ -n "$PIDS" ]]; then
    echo "$PIDS" | tr ' ' '\n' | while read -r p; do
      [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
    done
  fi
  echo "    主程序已停止"
else
  echo "    没有在跑的主程序"
fi

# 后台 helper（launchd KeepAlive，先 bootout 再补刀）
launchctl bootout "gui/$UID_NUM/com.macconsole.helper" >/dev/null 2>&1 || true
HPIDS="$(pgrep -f 'MacConsoleHelper' 2>/dev/null || true)"
if [[ -n "$HPIDS" ]]; then
  echo "$HPIDS" | tr ' ' '\n' | while read -r p; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  echo "    MacConsoleHelper 已停止"
fi

# 旧版残留脚本/工具进程
pkill -f 'restore_rgb\.sh' 2>/dev/null && echo "    已停止 restore_rgb.sh"
pkill -f '/pwmwake$' 2>/dev/null && echo "    已停止 pwmwake"
pkill -f 'auxbright watch' 2>/dev/null && echo "    已停止 auxbright watch"
pkill -f 'auxsmooth' 2>/dev/null && echo "    已停止 auxsmooth"

# ---------------------------------------------------------- ② 登录项 / 守护
echo "→ 2/9 移除 launchd 登录项与后台任务"
for LABEL in com.macconsole.helper com.macconsole.autostart com.macconsole.rgbrestore \
             com.user.pwmwake com.user.auxbright com.user.auxsmooth; do
  launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 && echo "    已 bootout $LABEL"
  launchctl disable "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
done
sudo launchctl bootout "system/com.macconsole.TongfangFan" >/dev/null 2>&1 || true

for LABEL in com.macconsole.helper com.macconsole.autostart com.macconsole.rgbrestore \
             com.user.pwmwake com.user.auxbright com.user.auxsmooth; do
  for f in "$LA_DIR/$LABEL.plist" "$LA_DIR/$LABEL.plist.disabled" "$LA_DIR/.$LABEL.plist.tmp"; do
    if [[ -e "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
  done
done

# ------------------------------------------------------------ ③ kext 与 daemon
echo "→ 3/9 卸载内核扩展（需要管理员密码）"
if [[ -d "$KEXT_DST" || -f "$DAEMON_PLIST" || -e "$LOADER_DST" || -e "$LOADER_OLD" ]]; then
  sudo -v || echo "    ⚠️ 没拿到管理员权限，kext 部分跳过（其余继续）"
  sudo launchctl bootout "system/com.macconsole.TongfangFan" >/dev/null 2>&1 || true
  sudo launchctl disable "system/com.macconsole.TongfangFan" >/dev/null 2>&1 || true
  if [[ -d "$KEXT_DST" ]]; then
    if sudo kmutil unload -p "$KEXT_DST" >/dev/null 2>&1; then
      echo "    kext 已从内核卸载"
    else
      echo "    kext 未在内核中（或已卸载）"
    fi
  fi
  sudo rm -f "$DAEMON_PLIST"
  sudo rm -rf "$KEXT_DST"
  # 2.8.15：开机加载器（我们自己的二进制）——先卸守护再删文件，
  # 否则 launchd 会在 KeepAlive/RunAtLoad 下拿不到程序反复失败。
  if [[ -e "$LOADER_DST" ]]; then
    sudo rm -f "$LOADER_DST" && echo "    已删除开机加载器（支持库）"
  fi
  if [[ -e "$LOADER_OLD" ]]; then
    sudo rm -f "$LOADER_OLD" && echo "    已删除开机加载器（旧路径残留）"
  fi
  echo "    已删除 kext 与开机加载项"
  if kmutil showloaded 2>/dev/null | grep -q TongfangFan; then
    echo "    ⚠️ 内核里仍能看到 TongfangFan（重启后彻底消失）"
  fi
else
  echo "    未安装，跳过"
fi

# ------------------------------------------------------------------ ④ 删 app
echo "→ 4/9 删除 app"
for D in "${APP_DIRS[@]}"; do
  if [[ -d "$D" ]]; then
    rm -rf "$D" && echo "    已删除 $D"
  fi
done

# -------------------------------------------------------------- ⑤ 状态目录
echo "→ 5/9 删除状态目录"
if [[ -e "$SUPPORT" ]]; then
  rm -rf "$SUPPORT" && echo "    已删除 Application Support/MacConsole"
else
  echo "    不存在，跳过"
fi

# ------------------------------------------------------------------ ⑥ 偏好
echo "→ 6/9 删除偏好设置（com.macconsole.app 整个域）"
defaults delete com.macconsole.app >/dev/null 2>&1 && echo "    已清空 UserDefaults"
rm -f "$HOME/Library/Preferences/com.macconsole.app.plist" 2>/dev/null
for f in "$HOME/Library/Preferences/ByHost/com.macconsole.app."*.plist; do
  [[ -e "$f" ]] && rm -f "$f"
done

# ------------------------------------------------------------------ ⑦ 缓存
echo "→ 7/9 删除缓存 / 容器 / 保存状态"
for P in \
  "$HOME/Library/Caches/com.macconsole.app" \
  "$HOME/Library/Containers/com.macconsole.app" \
  "$HOME/Library/HTTPStorages/com.macconsole.app" \
  "$HOME/Library/HTTPStorages/com.macconsole.app.binarycookies" \
  "$HOME/Library/WebKit/com.macconsole.app" \
  "$HOME/Library/Saved Application State/com.macconsole.app.savedState" \
  "$HOME/.macconsole" ; do
  if [[ -e "$P" ]]; then rm -rf "$P" && echo "    已删除 ${P:t}"; fi
done

# ------------------------------------------------------------------ ⑧ 日志
echo "→ 8/9 删除日志"
for f in "$HOME/Library/Logs/macconsole-helper.log" \
         "$HOME/Library/Logs/macconsole-rgb.log" \
         "$HOME/Library/Logs/MacConsole.log" \
         "$HOME/Library/Logs/pwmwake.out.log" \
         "$HOME/Library/Logs/auxbright.out.log"; do
  if [[ -f "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
done
for f in /tmp/macconsole-*.log; do
  if [[ -f "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
done

# -------------------------------------------------------- ⑨ 旧工具 + 自检
echo "→ 9/9 清理历史工具并自检残留"
for f in /usr/local/bin/auxbright /usr/local/bin/pwmwake /usr/local/bin/fanctl \
         /usr/local/bin/macconsole /usr/local/bin/rgbkb.py; do
  if [[ -e "$f" ]]; then
    sudo rm -f "$f" && echo "    已删除 $f"
  fi
done

echo
echo "—— 残留自检 ——"
LEFT=0
check() {
  if [[ -e "$1" ]]; then echo "  ✗ 仍存在：$1"; LEFT=$((LEFT+1)); fi
}
for D in "${APP_DIRS[@]}"; do check "$D"; done
check "$SUPPORT"
check "$KEXT_DST"
check "$DAEMON_PLIST"
check "$LOADER_DST"
check "$LOADER_OLD"
check "$HOME/Library/Preferences/com.macconsole.app.plist"
check "$HOME/Library/Caches/com.macconsole.app"
check "$HOME/Library/Saved Application State/com.macconsole.app.savedState"
for LABEL in com.macconsole.helper com.macconsole.autostart com.macconsole.rgbrestore; do
  check "$LA_DIR/$LABEL.plist"
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "  ✗ launchd 里仍有 $LABEL"; LEFT=$((LEFT+1))
  fi
done
if pgrep -f '/Mac控制台\.app/Contents/MacOS/Mac控制台$' >/dev/null 2>&1; then
  echo "  ✗ 主程序进程仍在运行"; LEFT=$((LEFT+1))
fi
if pgrep -f 'MacConsoleHelper' >/dev/null 2>&1; then
  echo "  ✗ MacConsoleHelper 进程仍在运行"; LEFT=$((LEFT+1))
fi

echo
if [[ $LEFT -eq 0 ]]; then
  echo "✅ 卸载完成，没有发现残留。"
else
  echo "⚠️ 还有 $LEFT 处残留（见上面 ✗）。多数情况重启一次就会彻底消失。"
fi
echo
echo "提示：若「系统设置 → 通用 → 登录项」里仍看到 Mac控制台，"
echo "      那是旧版本注册的条目，手动点「−」删掉即可。"
echo
echo "按任意键关闭..."
read -k 1
