#!/bin/zsh
# ============================================================================
# installer-install.sh —— 「Sky CC 安装器」app 的 root 执行脚本
#
# 由安装器 app 经
#   osascript -e "do shell script \"bash <本脚本>\" with administrator privileges"
# 一次性提权执行。全程写 /tmp/skycc-install.log，并输出「STEP n/6 标题」
# 进度标记——安装器 app 轮询日志把这些标记翻译成界面进度。
#
# 步骤：
#   1/6 停止旧进程          （app / helper，新旧两代进程名）
#   2/6 清理旧版本残留      （旧 app / 旧 kext / 旧守护 / 旧登录项 / 旧工具）
#   3/6 安装主程序          （内嵌的 Sky CC.app → /Applications）
#   4/6 配置 GPU 路由库     （/Library/GPUBundles + /usr/local/lib 软链）
#   5/6 安装内核扩展        （复用 app 内置的 install-kext.sh，含旧 kext 摘除）
#   6/6 收尾                （属主权限、安装摘要）
#
# 用户数据（设置 / 风扇曲线 / 灯效档）不动 —— 首启由 app 内 SkyCCMigrator 迁移。
# 退出码：0 成功；3 用户取消授权；其它 = 失败（日志里有原因）。
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"              # 安装器 app 的 Resources/
EMBEDDED_APP="$HERE/Sky CC.app"
DST_APP="/Applications/Sky CC.app"
LOG=/tmp/skycc-install.log

CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null)"
CONSOLE_UID="$(stat -f %u /dev/console 2>/dev/null || echo 501)"
USER_HOME=""
if [[ -n "$CONSOLE_USER" && -d "/Users/$CONSOLE_USER" ]]; then
  USER_HOME="/Users/$CONSOLE_USER"
else
  USER_HOME="${HOME:-/var/root}"
fi

exec > >(tee -a "$LOG") 2>&1
echo "===== Sky CC 安装 $(date '+%Y-%m-%d %H:%M:%S') ====="

step() { echo "STEP $1/6 $2"; }

# ---------------------------------------------------------------- 1 停旧进程
step 1 "停止旧版进程"
/usr/bin/pkill -f "Sky CC.app/Contents/MacOS/Sky CC" 2>/dev/null || true
/usr/bin/pkill -f "Sky CC.app/Contents/MacOS/SkyCCHelper" 2>/dev/null || true
/usr/bin/pkill -f "Sky CC.app/Contents/MacOS/MacConsoleHelper" 2>/dev/null || true
/usr/bin/pkill -f "Mac控制台.app/Contents/MacOS/Mac控制台" 2>/dev/null || true
/usr/bin/pkill -f "MacConsoleHelper" 2>/dev/null || true
launchctl bootout "gui/$CONSOLE_UID/com.skycc.helper" >/dev/null 2>&1 || true
launchctl bootout "gui/$CONSOLE_UID/com.macconsole.helper" >/dev/null 2>&1 || true
echo "    完成"

# ------------------------------------------------------------ 2 清旧残留
step 2 "清理旧版本残留"
# 旧 app（更名前两个代次）
for OLDAPP in \
  "/Applications/Mac控制台.app" "$USER_HOME/Applications/Mac控制台.app" \
  "/Applications/Mac控制台开机启动.app" "$USER_HOME/Applications/Mac控制台开机启动.app"; do
  [[ -d "$OLDAPP" ]] && /bin/rm -rf "$OLDAPP" && echo "    已删除旧 app：$OLDAPP"
done
# 旧内核扩展（TongfangFan / SkyCCMSR；现役 SkyCCEC.kext 由第 5 步的
# install-kext.sh 覆盖更新，这里不动）
for K in /Library/Extensions/TongfangFan.kext /Library/Extensions/SkyCCMSR.kext; do
  if [[ -d "$K" ]]; then
    /usr/bin/kmutil unload -p "$K" >/dev/null 2>&1 || true
    /bin/rm -rf "$K" && echo "    已删除旧内核扩展：$K"
  fi
done
# 旧守护与旧登录项（launchd 域 + plist，新旧两代命名）
launchctl bootout "system/com.skycc.ec" >/dev/null 2>&1 || true
for L in com.skycc.TongfangFan com.macconsole.TongfangFan; do
  launchctl bootout "system/$L" >/dev/null 2>&1 || true
  launchctl disable "system/$L" >/dev/null 2>&1 || true
  [[ -f "/Library/LaunchDaemons/$L.plist" ]] \
    && /bin/rm -f "/Library/LaunchDaemons/$L.plist" && echo "    已删除旧守护：$L.plist"
done
for L in com.skycc.autostart com.skycc.rgbrestore \
         com.macconsole.helper com.macconsole.autostart com.macconsole.rgbrestore; do
  launchctl bootout "gui/$CONSOLE_UID/$L" >/dev/null 2>&1 || true
  for F in "$USER_HOME/Library/LaunchAgents/$L.plist" \
           "$USER_HOME/Library/LaunchAgents/$L.plist.disabled"; do
    [[ -e "$F" ]] && /bin/rm -f "$F" && echo "    已删除旧登录项：${F:t}"
  done
done
# 旧开机加载器与历史工具
for LOADER in \
  "$USER_HOME/Library/Application Support/SkyCC/bin/Mac控制台散热扩展" \
  "$USER_HOME/Library/Application Support/MacConsole/bin/Mac控制台散热扩展" \
  "/Library/PrivilegedHelperTools/Mac控制台散热扩展"; do
  [[ -e "$LOADER" ]] && /bin/rm -f "$LOADER" && echo "    已删除旧开机加载器"
done
for T in /usr/local/bin/auxbright /usr/local/bin/pwmwake /usr/local/bin/fanctl \
         /usr/local/bin/rgbkb.py; do
  [[ -e "$T" ]] && /bin/rm -f "$T" && echo "    已删除旧工具：$T"
done
echo "    完成"

# ------------------------------------------------------------ 3 装主程序
step 3 "安装主程序到 /Applications"
[[ -d "$EMBEDDED_APP" ]] || { echo "错误：安装器里找不到内嵌的 Sky CC.app" >&2; exit 2; }
# 旧 app 整个摘掉再 ditto（保留签名与元数据），避免新旧文件混装
/bin/rm -rf "$DST_APP"
/usr/bin/ditto "$EMBEDDED_APP" "$DST_APP" || { echo "错误：复制主程序失败" >&2; exit 2; }
# 控制台用户要能读能跑：属主给用户，权限 a+rX（umask 077 的锅在这里兜底）
/usr/sbin/chown -R "${CONSOLE_USER}:staff" "$DST_APP" 2>/dev/null \
  || /usr/sbin/chown -R "$CONSOLE_USER" "$DST_APP" 2>/dev/null || true
/bin/chmod -R a+rX,go-w "$DST_APP"
echo "    已安装：$DST_APP"

# -------------------------------------------------------- 4 GPU 路由库
step 4 "配置 GPU 路由库"
DYLD="$DST_APP/Contents/Resources/gpu-router.dylib"
LIBDIR=/Library/GPUBundles
[[ -f "$DYLD" ]] || { echo "错误：主程序里没有 gpu-router.dylib" >&2; exit 2; }
/bin/mkdir -p "$LIBDIR"
/bin/cp -f "$DYLD" "$LIBDIR/gpu-router.dylib"
/usr/sbin/chown root:wheel "$LIBDIR" "$LIBDIR/gpu-router.dylib"
/bin/chmod 755 "$LIBDIR" && /bin/chmod 644 "$LIBDIR/gpu-router.dylib"
/bin/mkdir -p /usr/local/lib
/bin/ln -sfn "$LIBDIR/gpu-router.dylib" /usr/local/lib/gpu-router.dylib
/usr/sbin/chown -h root:wheel /usr/local/lib/gpu-router.dylib 2>/dev/null || true
echo "    已安装 $LIBDIR/gpu-router.dylib（沙箱 app 可读）"

# -------------------------------------------------------- 5 内核扩展
step 5 "安装内核扩展（SkyCCEC.kext）"
KEXT_SCRIPT="$HERE/Sky CC.app/Contents/Resources/native/scripts/install-kext.sh"
[[ -f "$KEXT_SCRIPT" ]] || { echo "错误：找不到 install-kext.sh" >&2; exit 2; }
/bin/zsh "$KEXT_SCRIPT"
KEXT_RC=$?
# install-kext.sh 约定：0 = 成功或「重启后生效」（日志里有「重启后生效」字样）
if [[ $KEXT_RC -ne 0 ]]; then
  echo "错误：内核扩展安装失败（退出码 $KEXT_RC），详见 /tmp/skycc-kext-install.log" >&2
  exit 2
fi
echo "    内核扩展就绪（macOS 26 需重启一次加载）"

# ---------------------------------------------------------------- 6 收尾
step 6 "收尾"
{
  echo "== 安装摘要 $(/bin/date '+%Y-%m-%d %H:%M:%S') =="
  /bin/ls -d "$DST_APP" "$LIBDIR/gpu-router.dylib" /Library/Extensions/SkyCCEC.kext 2>&1
} >> "$LOG"
echo "ALL DONE"
exit 0
