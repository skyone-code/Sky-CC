#!/bin/zsh
# 卸载散热控制.command —— 卸载 TongfangFan.kext 与开机加载项
#
# 不删除 /Library/Extensions/TongfangFan.kext 之外的东西；
# 控制台目录里的 TongfangFan.kext 源文件保留（想重装再点安装脚本）。

KEXT_DST="/Library/Extensions/TongfangFan.kext"
DAEMON_PLIST="/Library/LaunchDaemons/com.macconsole.TongfangFan.plist"

echo "=============================================="
echo "  Mac 控制台 · 散热控制卸载"
echo "=============================================="
echo

sudo -v || { echo "✗ 未获得权限，退出"; exit 1; }

echo "1/3 卸载内核扩展（风扇回到 EC 自动调度）..."
sudo kmutil unload -b com.macconsole.TongfangFan 2>&1 | sed 's/^/    /'

echo "2/3 移除开机自动加载项 ..."
sudo launchctl bootout system/com.macconsole.TongfangFan 2>/dev/null
sudo rm -f "$DAEMON_PLIST"

echo "3/3 删除 /Library/Extensions 下的 kext ..."
sudo rm -rf "$KEXT_DST"

if ioreg -r -c TongfangFanDriver | grep -q TongfangFanDriver; then
  echo "⚠ TongfangFanDriver 仍在内核中（可能被占用，重启后即彻底移除）"
else
  echo "✓ 已卸载"
fi
echo
echo "按任意键关闭..."
read -k 1
