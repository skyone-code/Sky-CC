#!/bin/bash
# --------------------------------------------------------------------------
# 卸载灯效自启 —— 移除开机自动恢复键盘灯效的 launchd 任务
# 只删除任务本身，不会动你保存的灯效配置，也不改键盘当前颜色。
# --------------------------------------------------------------------------
LABEL="com.macconsole.rgbrestore"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "=================================================="
echo "   Mac 控制台 · 键盘灯效开机自启 卸载"
echo "=================================================="
echo

launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null && echo "✓ 已停止并卸载任务" \
    || echo "· 任务未在运行"

launchctl unload -w "$PLIST" 2>/dev/null

if [ -f "$PLIST" ]; then
    rm -f "$PLIST" && echo "✓ 已删除 $PLIST"
else
    echo "· 没有找到 plist 文件"
fi

echo
echo "完成。开机不再自动恢复灯效。"
echo "（你保存的灯效配置仍在，重新安装即可恢复自动应用。）"
echo
read -n 1 -s -r -p "按任意键关闭..."
