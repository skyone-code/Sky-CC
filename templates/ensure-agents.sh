#!/bin/zsh
# ============================================================================
# ensure-agents.sh —— 清理/让位 Mac控制台 的用户态 launchd 守护（幂等）
#
# 【2.8.12 变更】本脚本不再**安装**任何登录项，只做清理。
#   以前它给键盘灯效恢复装了一条 com.macconsole.rgbrestore（/bin/bash 跑
#   restore_rgb.sh）。其实 helper 启动序列里已经用原生 RGBProfile.apply()
#   恢复过键盘灯了 —— 这条 bash 登录项是纯重复，用户登录项列表里还多一项。
#   现在改由 helper 自己恢复（带 USB 未枚举时的重试），这里负责把历史上
#   装过的 rgbrestore 停掉并删除 plist。
#
# 同时让位已废弃的守护：
#   com.user.pwmwake   面板 PWM 模式保持器（3.0.1 起 app 已彻底移除，这里只清旧机器残留）
#   com.user.auxbright 更早的亮度守护（v4 watch）
#   com.user.auxsmooth 更早的亮度渐变守护（Python 时代）
# 这三个 plist 只改名 .disabled 备份（用户想回退 mv 回来即可），不删。
#
# 由 helper 启动序列调用；日志进 ~/Library/Logs/macconsole-helper.log
# ============================================================================
set -u
LA_DIR="$HOME/Library/LaunchAgents"
UID_NUM=$(id -u)

mkdir -p "$LA_DIR"

bootout_if_running() {
  if launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_NUM/$1" >/dev/null 2>&1
    sleep 0.3
    echo "[agents] 已停 $1"
  fi
}

# ---------- 1. 删除历史上的「键盘灯效恢复」bash 登录项 ----------
# 恢复已并入 helper 启动序列，这条登录项从此不再需要（也不该再出现）。
LABEL_RGB="com.macconsole.rgbrestore"
bootout_if_running "$LABEL_RGB"
for f in "$LA_DIR/$LABEL_RGB.plist" \
         "$LA_DIR/.$LABEL_RGB.plist.tmp" \
         "$LA_DIR/$LABEL_RGB.plist.disabled"; do
  [[ -e "$f" ]] && rm -f "$f" && echo "[agents] 已删除 $f"
done

# ---------- 2. 停用并让位所有与「屏幕亮度」有关的旧守护 ----------
#
# 不删除 plist，只改名 .disabled —— 用户想回退时 mv 回来即可。
for LABEL in com.user.pwmwake com.user.auxbright com.user.auxsmooth; do
  bootout_if_running "$LABEL"
  PL="$LA_DIR/$LABEL.plist"
  if [[ -f "$PL" ]]; then
    mv "$PL" "$PL.disabled"
    echo "[agents] 已停用亮度守护: $LABEL（plist 备份为 $LABEL.plist.disabled）"
  fi
done
# ---------- 3. 清掉已废弃的「静默启动」登录项（com.macconsole.autostart）----------
#
# 2.8.15 删掉静默启动功能，本轮 P2 清理起 app bundle 里也不再生成这份 plist。
# 老机器（≤2.8.15）可能在 ~/Library/LaunchAgents 留着一份（autostart.sh 写的）
# 或者在 SMAppService 注册库里有记录 —— 后者 app 侧 AutostartHeal 负责（需要
# bundle 里还有 plist 才能注销），这里负责磁盘与 launchd 运行态。
LABEL_AUTO="com.macconsole.autostart"
bootout_if_running "$LABEL_AUTO"
launchctl disable "gui/$UID_NUM/$LABEL_AUTO" >/dev/null 2>&1 || true
for f in "$LA_DIR/$LABEL_AUTO.plist" \
         "$LA_DIR/$LABEL_AUTO.plist.disabled" \
         "$LA_DIR/.$LABEL_AUTO.plist.tmp"; do
  [[ -e "$f" ]] && rm -f "$f" && echo "[agents] 已删除废弃登录项 ${f:t}"
done

# ---------- 4. 兜底：kill 残留进程 ----------
# 兜底：plist 已经不在了但进程还活着（旧版本 app 直接拉起的）
pkill -f "/pwmwake$" 2>/dev/null && echo "[agents] 已结束残留 pwmwake 进程"
pkill -f "auxbright watch" 2>/dev/null && echo "[agents] 已结束残留 auxbright watch 进程"
pkill -f "auxsmooth" 2>/dev/null && echo "[agents] 已结束残留 auxsmooth 进程"

echo "[agents] done（当前只应有 com.macconsole.helper 一条）"
