#!/bin/zsh
# ============================================================================
# 卸载Sky CC.command —— 彻底卸载
#
# 目标：把 Sky CC 在这台机器上留下的**每一样东西**都清掉，
#       不只是把 .app 拖进废纸篓。清完「系统设置 → 通用 → 登录项」、
#       launchd、内核扩展、偏好设置里都不再有它的痕迹。
#
# 具体清这些东西：
#   ① 进程      主程序（含旧版拉起的实例）、SkyCCHelper、历史 pwmwake 残留进程
#   ② 系统注册  SMAppService 的注册（helper / mainApp 登录项；autostart 是 ≤2.8.15
#               的历史遗留，打包时已移除那份 plist，这里只清旧机器残留）
#               —— 这些记录在系统数据库里，删 plist 或 bootout 都清不掉，
#               必须让 app 自己调 --unregister-all 注销
#   ③ 内核扩展  /Library/Extensions/SkyCCEC.kext
#               + /Library/LaunchDaemons/com.skycc.ec.plist
#               （同时清理 TongfangFan / SkyCCMSR 时代的旧 kext 与旧守护）
#               + 开机加载器（支持库内「Sky CC散热扩展」）
#               + kmutil unload（都需要管理员密码）
#   ④ 登录项    ~/Library/LaunchAgents 下 com.skycc.*（含历史 rgbrestore）
#               以及旧版亮度守护 com.user.pwmwake / auxbright / auxsmooth
#               2026-11-17 起连 com.macconsole.* 旧命名一并清
#   ⑤ app       /Applications 与 ~/Applications 里的 Sky CC（含旧「开机启动」app）
#   ⑥ 数据      ~/Library/Application Support/SkyCC（灯效档 / 风扇曲线 / 记忆 / 锁）
#               以及旧名 MacConsole 目录
#   ⑦ 偏好      com.skycc.console 整个 UserDefaults 域（pref.* 全部设置项）
#   ⑧ 缓存      Caches / Containers / HTTPStorages / WebKit / Saved Application State
#   ⑨ 日志      ~/Library/Logs/skycc*.log、pwmwake.out.log、/tmp/skycc*
#   ⑩ 旧工具    /usr/local/bin 下 auxbright / pwmwake / fanctl 之类历史残留
#   ⑪ GPU 路由  /Library/GPUBundles/gpu-router.dylib、/usr/local/lib 软链，
#               以及指向它的 DYLD_INSERT_LIBRARIES 注入开关
#
# 结束时会把「所有应该消失的路径」再扫一遍，列出仍然存在的残留。
# ============================================================================
set -u

APP_DIRS=(
  "/Applications/Sky CC.app"
  "$HOME/Applications/Sky CC.app"
  # 旧版本（≤3.0.4.4）的 app 名，升级换名后残留也要清
  "/Applications/Mac控制台.app"
  "$HOME/Applications/Mac控制台.app"
  # 更早期的「开机启动」独立 app
  "/Applications/Mac控制台开机启动.app"
  "$HOME/Applications/Mac控制台开机启动.app"
)
LA_DIR="$HOME/Library/LaunchAgents"
SUPPORT="$HOME/Library/Application Support/SkyCC"
DAEMON_PLIST="/Library/LaunchDaemons/com.skycc.ec.plist"
KEXT_DST="/Library/Extensions/SkyCCEC.kext"
# 旧标识一并清：TongfangFan（第三方二进制时代）、SkyCCMSR（已并入 EC kext）
DAEMON_LEGACY_LABELS=("com.skycc.TongfangFan" "com.macconsole.TongfangFan")
KEXT_LEGACY=(
  "/Library/Extensions/TongfangFan.kext"
  "/Library/Extensions/SkyCCMSR.kext"
)
# 2.8.15：开机加载器放在控制台支持库里（/Library/PrivilegedHelperTools 被 SIP 挡住）
LOADER_DST="$SUPPORT/bin/Sky CC散热扩展"
# 旧版本（≤3.0.4.4）加载器的名字，一并清
LOADER_LEGACY="$SUPPORT/bin/Mac控制台散热扩展"
# 早期试验版曾想把它放到这里，一并清掉
LOADER_OLD="/Library/PrivilegedHelperTools/Mac控制台散热扩展"
# 3.0.4.1 起：GPU 路由注入库由 pkg 装到 /Library/GPUBundles（App Sandbox 可读），
# 并在 /usr/local/lib 留一条软链兼容旧路径。卸载时两处都要清，否则下次装别的版本
# 会读到孤儿副本。
GPU_DYLIB="/Library/GPUBundles/gpu-router.dylib"
GPU_LEGACY="/usr/local/lib/gpu-router.dylib"
UID_NUM=$(id -u)

echo "=============================================="
echo "  Mac 控制台 · 彻底卸载"
echo "=============================================="
echo
echo "将要清除："
echo "  · 主程序 / 后台守护 / 历史 pwmwake 残留进程"
echo "  · 登录项与后台任务注册（helper、静默启动、开机自启）"
echo "  · SkyCCEC.kext（含 TongfangFan / SkyCCMSR 旧驱动）与它的开机加载项"
echo "  · $SUPPORT（灯效 / 风扇曲线 / 软件记忆）"
echo "  · com.skycc.app 的全部偏好设置、缓存、日志"
echo
echo "⚠️  软件记忆（散热档、灯效、充电阈值等）会一并删除，重装后需要重新设置。"
echo
read -k 1 -s -r -p "按任意键继续，Control-C 取消..."
echo
echo

# ---------------------------------------------------------------- ① 停进程
echo "→ 1/9 停止正在运行的进程"
for D in "${APP_DIRS[@]}"; do
  for EXE in "Sky CC" "Mac控制台"; do
  BIN="$D/Contents/MacOS/$EXE"
  [[ -x "$BIN" ]] || continue
  # --unregister-all 注销 helper / mainApp 两条现役注册，外加 autostart 历史残留
  # （3.0.1 起 bundle 不含 autostart plist，SMAppService 那条只能清旧机器）。
  # 必须在删 app 之前跑：注册记录在系统数据库里，只删文件清不掉。
  "$BIN" --unregister-all 2>/dev/null && echo "    已注销后台注册（$D）"
  done
done

# 主程序（精确匹配可执行文件路径，避免误杀；新旧两代 app 名都要匹配）
PID_PAT='/(Sky CC|Mac控制台)\.app/Contents/MacOS/(Sky CC|Mac控制台)$'
PIDS="$(pgrep -f "$PID_PAT" 2>/dev/null || true)"
if [[ -n "$PIDS" ]]; then
  echo "$PIDS" | tr ' ' '\n' | while read -r p; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  sleep 1
  PIDS="$(pgrep -f "$PID_PAT" 2>/dev/null || true)"
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
launchctl bootout "gui/$UID_NUM/com.skycc.helper" >/dev/null 2>&1 || true
HPIDS="$(pgrep -f 'SkyCCHelper' 2>/dev/null || true)"
if [[ -n "$HPIDS" ]]; then
  echo "$HPIDS" | tr ' ' '\n' | while read -r p; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  echo "    SkyCCHelper 已停止"
fi
# 旧名 helper（MacConsoleHelper）—— 更名前的进程，名字不同所以单独补一刀
launchctl bootout "gui/$UID_NUM/com.macconsole.helper" >/dev/null 2>&1 || true
OLD_HPIDS="$(pgrep -f 'MacConsoleHelper' 2>/dev/null || true)"
if [[ -n "$OLD_HPIDS" ]]; then
  echo "$OLD_HPIDS" | tr ' ' '\n' | while read -r p; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done
  echo "    MacConsoleHelper（旧名）已停止"
fi

# 旧版残留脚本/工具进程
pkill -f 'restore_rgb\.sh' 2>/dev/null && echo "    已停止 restore_rgb.sh"
pkill -f '/pwmwake$' 2>/dev/null && echo "    已停止 pwmwake"
pkill -f 'auxbright watch' 2>/dev/null && echo "    已停止 auxbright watch"
pkill -f 'auxsmooth' 2>/dev/null && echo "    已停止 auxsmooth"

# ---------------------------------------------------------- ② 登录项 / 守护
echo "→ 2/9 移除 launchd 登录项与后台任务"
for LABEL in com.skycc.helper com.skycc.autostart com.skycc.rgbrestore \
             com.user.pwmwake com.user.auxbright com.user.auxsmooth; do
  launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 && echo "    已 bootout $LABEL"
  launchctl disable "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
done
for LABEL in system/com.skycc.ec system/com.skycc.TongfangFan system/com.macconsole.TongfangFan; do
  sudo launchctl bootout "$LABEL" >/dev/null 2>&1 || true
done

for LABEL in com.skycc.helper com.skycc.autostart com.skycc.rgbrestore \
             com.user.pwmwake com.user.auxbright com.user.auxsmooth; do
  for f in "$LA_DIR/$LABEL.plist" "$LA_DIR/$LABEL.plist.disabled" "$LA_DIR/.$LABEL.plist.tmp"; do
    if [[ -e "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
  done
done

# 2026-11-17（MacConsole → SkyCC 更名）：把旧命名的守护一并清掉，
# 否则卸载完 launchd 里还留着 com.macconsole.helper，下次登录又把旧 helper 拉起来。
echo "    （兼容清理 MacConsole 时代的旧守护）"
for LABEL in com.macconsole.helper com.macconsole.autostart com.macconsole.rgbrestore; do
  launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
  launchctl disable "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
  for f in "$LA_DIR/$LABEL.plist" "$LA_DIR/$LABEL.plist.disabled" "$LA_DIR/.$LABEL.plist.tmp"; do
    if [[ -e "$f" ]]; then rm -f "$f" && echo "    已删除旧登录项 ${f:t}"; fi
  done
done
sudo rm -f "/Library/LaunchDaemons/com.macconsole.TongfangFan.plist" 2>/dev/null || true

# ------------------------------------------------------------ ③ kext 与 daemon
echo "→ 3/9 卸载内核扩展（需要管理员密码）"
LEGACY_PRESENT=false
for K in "${KEXT_LEGACY[@]}"; do [[ -d "$K" ]] && LEGACY_PRESENT=true; done
if [[ -d "$KEXT_DST" || -f "$DAEMON_PLIST" || -e "$LOADER_DST" || -e "$LOADER_OLD" \
      || "$LEGACY_PRESENT" == "true" ]]; then
  sudo -v || echo "    ⚠️ 没拿到管理员权限，kext 部分跳过（其余继续）"
  for LABEL in "$DAEMON_PLIST" system/com.skycc.ec; do
    sudo launchctl bootout "$LABEL" >/dev/null 2>&1 || true
  done
  for LABEL in "${DAEMON_LEGACY_LABELS[@]}"; do
    sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    sudo launchctl disable "system/$LABEL" >/dev/null 2>&1 || true
    sudo rm -f "/Library/LaunchDaemons/$LABEL.plist"
  done
  for K in "$KEXT_DST" "${KEXT_LEGACY[@]}"; do
    [[ -d "$K" ]] || continue
    if sudo kmutil unload -p "$K" >/dev/null 2>&1; then
      echo "    已卸载 ${K:t}"
    else
      echo "    ${K:t} 未在内核中（或已卸载）"
    fi
    sudo rm -rf "$K"
  done
  sudo rm -f "$DAEMON_PLIST"
  # 2.8.15：开机加载器（我们自己的二进制）——先卸守护再删文件，
  # 否则 launchd 会在 KeepAlive/RunAtLoad 下拿不到程序反复失败。
  if [[ -e "$LOADER_DST" ]]; then
    sudo rm -f "$LOADER_DST" && echo "    已删除开机加载器（支持库）"
  fi
  if [[ -e "$LOADER_LEGACY" ]]; then
    sudo rm -f "$LOADER_LEGACY" && echo "    已删除开机加载器（旧版名残留）"
  fi
  if [[ -e "$LOADER_OLD" ]]; then
    sudo rm -f "$LOADER_OLD" && echo "    已删除开机加载器（旧路径残留）"
  fi
  echo "    已删除 kext 与开机加载项"
  if kmutil showloaded 2>/dev/null | grep -qE "SkyCCEC|TongfangFan|MSRReader"; then
    echo "    ⚠️ 内核里仍能看到旧驱动（重启后彻底消失）"
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
  rm -rf "$SUPPORT" && echo "    已删除 Application Support/SkyCC"
else
  echo "    不存在，跳过"
fi
# 2026-11-17：MacConsole 时代的同名目录（改名前的存档位置）
SUPPORT_OLD="$HOME/Library/Application Support/MacConsole"
if [[ -e "$SUPPORT_OLD" ]]; then
  rm -rf "$SUPPORT_OLD" && echo "    已删除 Application Support/MacConsole（旧名）"
fi

# ------------------------------------------------------------------ ⑥ 偏好
# 2026-11-17：域名从 com.macconsole.console 换成 com.skycc.console。
# 老版本卸载器里写的 com.macconsole.app 是个历史错名（从来没有被真正写过），
# 这里一并 delete —— 反正不存在也不会报错。
echo "→ 6/9 删除偏好设置（com.skycc.console 整个域）"
for DOMAIN in com.skycc.console com.macconsole.console com.macconsole.app com.skycc.app; do
  defaults delete "$DOMAIN" >/dev/null 2>&1 && echo "    已清空 UserDefaults（$DOMAIN）"
  rm -f "$HOME/Library/Preferences/$DOMAIN.plist" 2>/dev/null
  for f in "$HOME/Library/Preferences/ByHost/$DOMAIN."*.plist; do
    [[ -e "$f" ]] && rm -f "$f"
  done
done

# ------------------------------------------------------------------ ⑦ 缓存
echo "→ 7/9 删除缓存 / 容器 / 保存状态"
for P in \
  "$HOME/Library/Caches/com.skycc.console" \
  "$HOME/Library/Containers/com.skycc.console" \
  "$HOME/Library/HTTPStorages/com.skycc.console" \
  "$HOME/Library/HTTPStorages/com.skycc.console.binarycookies" \
  "$HOME/Library/WebKit/com.skycc.console" \
  "$HOME/Library/Saved Application State/com.skycc.console.savedState" \
  "$HOME/Library/Caches/com.macconsole.console" \
  "$HOME/Library/HTTPStorages/com.macconsole.console" \
  "$HOME/Library/WebKit/com.macconsole.console" \
  "$HOME/Library/Saved Application State/com.macconsole.console.savedState" \
  "$HOME/.skycc" ; do
  if [[ -e "$P" ]]; then rm -rf "$P" && echo "    已删除 ${P:t}"; fi
done

# ------------------------------------------------------------------ ⑧ 日志
echo "→ 8/9 删除日志"
for f in "$HOME/Library/Logs/skycc-helper.log" \
         "$HOME/Library/Logs/skycc-rgb.log" \
         "$HOME/Library/Logs/SkyCC.log" \
         "$HOME/Library/Logs/pwmwake.out.log" \
         "$HOME/Library/Logs/auxbright.out.log"; do
  if [[ -f "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
done
for f in /tmp/skycc-*.log; do
  if [[ -f "$f" ]]; then rm -f "$f" && echo "    已删除 ${f:t}"; fi
done

# -------------------------------------------------------- ⑨ 旧工具 + 自检
echo "→ 9/9 清理历史工具并自检残留"
for f in /usr/local/bin/auxbright /usr/local/bin/pwmwake /usr/local/bin/fanctl \
         /usr/local/bin/skycc /usr/local/bin/rgbkb.py; do
  if [[ -e "$f" ]]; then
    sudo rm -f "$f" && echo "    已删除 $f"
  fi
done

# GPU 路由注入库（3.0.4.1 起由 pkg 装入 /Library/GPUBundles）
if [[ -e "$GPU_DYLIB" || -L "$GPU_LEGACY" || -e "$GPU_LEGACY" ]]; then
  sudo -v || echo "    ⚠️ 没拿到管理员权限，路由库可能删不掉"
  for f in "$GPU_DYLIB" "$GPU_LEGACY"; do
    if [[ -e "$f" || -L "$f" ]]; then
      sudo rm -f "$f" && echo "    已删除 $f"
    fi
  done
  # 注入开关还指着这个库的话一并关掉，否则环境变量会指向不存在的文件，
  # 之后所有新启动的 app 都会在 dyld 阶段报错
  CUR_INJ="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)"
  if [[ "$CUR_INJ" == *gpu-router.dylib* ]]; then
    launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null \
      && echo "    已关闭 GPU 路由注入开关（DYLD_INSERT_LIBRARIES）"
  fi
fi

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
check "$LOADER_LEGACY"
check "$LOADER_OLD"
check "$GPU_DYLIB"
check "$GPU_LEGACY"
check "$HOME/Library/Preferences/com.skycc.app.plist"
check "$HOME/Library/Caches/com.skycc.app"
check "$HOME/Library/Saved Application State/com.skycc.app.savedState"
for LABEL in com.skycc.helper com.skycc.autostart com.skycc.rgbrestore; do
  check "$LA_DIR/$LABEL.plist"
  if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "  ✗ launchd 里仍有 $LABEL"; LEFT=$((LEFT+1))
  fi
done
if pgrep -f '/(Sky CC|Mac控制台)\.app/Contents/MacOS/(Sky CC|Mac控制台)$' >/dev/null 2>&1; then
  echo "  ✗ 主程序进程仍在运行"; LEFT=$((LEFT+1))
fi
if pgrep -f 'SkyCCHelper' >/dev/null 2>&1; then
  echo "  ✗ SkyCCHelper 进程仍在运行"; LEFT=$((LEFT+1))
fi

echo
if [[ $LEFT -eq 0 ]]; then
  echo "✅ 卸载完成，没有发现残留。"
else
  echo "⚠️ 还有 $LEFT 处残留（见上面 ✗）。多数情况重启一次就会彻底消失。"
fi
echo
echo "提示：若「系统设置 → 通用 → 登录项」里仍看到 Sky CC，"
echo "      那是旧版本注册的条目，手动点「−」删掉即可。"
echo
echo "按任意键关闭..."
read -k 1
