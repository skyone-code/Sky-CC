#!/bin/zsh
# 热重载散热控制.command —— 不重启，把 v1.0.6 kext 换进内核
# 全部输出同时记录到 /tmp/macconsole-fanreload.log
# 注意：log 必须用 /usr/bin/log 绝对路径，zsh 内建的 log 会劫持命令

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/macconsole-fanreload.log
KEXT_DST=/Library/Extensions/TongfangFan.kext

{
echo "=============================================="
echo "  Mac 控制台 · 散热 kext 热重载 $(date)"
echo "=============================================="

sudo -v || { echo "✗ 未获得权限，退出"; exit 1; }

echo
echo "1/5 更新 /Library/Extensions 里的 kext (v1.0.6) ..."
sudo rm -rf "$KEXT_DST"
sudo cp -R "$DIR/TongfangFan.kext" "$KEXT_DST"
sudo chown -R root:wheel "$KEXT_DST"
sudo chmod -R 755 "$KEXT_DST"

echo
echo "2/5 卸载内核里的旧版 ..."
sudo kmutil unload -b com.macconsole.TongfangFan 2>&1
echo "unload 退出码: $?"

echo
echo "3/5 加载新版 ..."
sudo kmutil load -p "$KEXT_DST" 2>&1
echo "load 退出码: $?"

sleep 1

echo
echo "4/5 内核里的状态 ..."
kextstat | grep -i tongfang || echo "(kext 不在内核)"
ioreg -r -c TongfangFanDriver | grep -E "TongfangFanDriver|WMIMethod|WMIGuid" | head -5 || true

echo
echo "5/5 用户态探测（v1.0.6: EC 直读风扇状态） ..."
/usr/bin/python3 "$DIR/fanctl.py" status 2>&1
/usr/bin/python3 "$DIR/fanctl.py" 2>&1 | head -2

echo
echo "=== 内核日志（TongfangFan 相关，含 v1.0.6 全路径 IOLog） ==="
sudo /usr/bin/log show --last 1h --predicate 'eventMessage CONTAINS "TongfangFan"' --info 2>&1 | grep -i tongfang | tail -40 || true

echo
if ioreg -r -c TongfangFanDriver | grep -q TongfangFanDriver; then
  echo "✓ 驱动已在线！可以打开控制台试「基准（拉满）」模式了。"
else
  echo "✗ 驱动尚未挂上，看上面的日志。"
  echo "  若出现 Code=27（未批准，换新二进制后必现一次）: 系统设置→隐私与安全性→允许，然后重启一次。"
fi
} 2>&1 | tee "$LOG"

echo
echo "按任意键关闭..."
read -k 1
