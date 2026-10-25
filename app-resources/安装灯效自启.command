#!/bin/bash
# --------------------------------------------------------------------------
# 安装灯效自启 —— 开机/登录后自动恢复上次设置的键盘灯效
# 双击运行即可。会往 ~/Library/LaunchAgents/ 写一个 launchd 任务。
# --------------------------------------------------------------------------
cd "$(dirname "$0")" || exit 1
PROJ="$(pwd)"
LABEL="com.macconsole.rgbrestore"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PY="/usr/bin/python3"

echo "=================================================="
echo "   Mac 控制台 · 键盘灯效开机自启 安装"
echo "=================================================="
echo
echo "项目目录 : $PROJ"
echo "任务标识 : $LABEL"
echo "配置文件 : $PLIST"
echo

if [ ! -f "$PROJ/rgbkb.py" ]; then
    echo "✗ 找不到 rgbkb.py，请在项目目录内运行本脚本。"
    read -n 1 -s -r -p "按任意键关闭..."
    exit 1
fi
if [ ! -f "$PROJ/restore_rgb.sh" ]; then
    echo "✗ 找不到 restore_rgb.sh。"
    read -n 1 -s -r -p "按任意键关闭..."
    exit 1
fi

chmod +x "$PROJ/restore_rgb.sh"

# --- 当前是否已有保存的灯效配置 ---
echo "当前保存的灯效:"
"$PY" "$PROJ/rgbkb.py" profile 2>/dev/null | sed 's/^/    /'
echo

# --- 写 launchd plist ---
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJ/restore_rgb.sh</string>
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

if [ ! -f "$PLIST" ]; then
    echo "✗ plist 写入失败。"
    read -n 1 -s -r -p "按任意键关闭..."
    exit 1
fi
echo "✓ 已写入 $PLIST"
echo

# --- 卸载旧的（如果存在），再装载 ---
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null

if launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
    echo "✓ launchd 任务已装载"
elif launchctl load -w "$PLIST" 2>/dev/null; then
    echo "✓ launchd 任务已装载 (load 方式)"
else
    echo "! 自动装载失败（不影响开机自启，重启后仍会生效）"
    echo "  如需手动装载: launchctl bootstrap gui/$UID \"$PLIST\""
fi
echo

# --- 立即执行一次，验证链路 ---
echo "正在立即执行一次以验证..."
: > /tmp/macconsole-rgb.log
launchctl kickstart -k "gui/$UID/$LABEL" 2>/dev/null
sleep 3
echo
echo "--- 日志 ---"
cat /tmp/macconsole-rgb.log 2>/dev/null | tail -6
echo "------------"
echo
echo "完成。以后每次开机/登录，键盘灯会自动恢复成上面那份配置。"
echo "想换灯效：打开控制台调好，它会自动记住。"
echo
read -n 1 -s -r -p "按任意键关闭..."
