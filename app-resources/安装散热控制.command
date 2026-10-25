#!/bin/zsh
# 安装散热控制.command —— 加载 TongfangFan.kext 并设置开机自动加载
#
# 做三件事:
#   1. 把 TongfangFan.kext 拷到 /Library/Extensions（稳定路径）
#   2. 立即加载（kmutil load，SIP 内核扩展签名须为关闭状态）
#   3. 装 LaunchDaemon，开机自动加载
#
# 卸载: 双击「卸载散热控制.command」

DIR="$(cd "$(dirname "$0")" && pwd)"
KEXT_SRC="$DIR/TongfangFan.kext"
KEXT_DST="/Library/Extensions/TongfangFan.kext"
DAEMON_PLIST="/Library/LaunchDaemons/com.macconsole.TongfangFan.plist"

echo "=============================================="
echo "  Mac 控制台 · 散热控制内核扩展安装"
echo "=============================================="
echo

if [[ ! -d "$KEXT_SRC" ]]; then
  echo "✗ 找不到 $KEXT_SRC"
  exit 1
fi

# SIP 检查（内核扩展签名必须关闭，否则无法加载自编译 kext）
SIP_KEXT=$(csrutil status 2>/dev/null | grep -c "Kext Signing: disabled" || true)
if [[ "$SIP_KEXT" -lt 1 ]]; then
  echo "⚠ 检测到 SIP「Kext Signing」未关闭，加载大概率会失败。"
  echo "  （本机此前检查为关闭状态；若你改过 SIP 请先恢复）"
  echo
fi

echo "→ 需要 administrator 密码（拷贝 kext + 立即加载 + 安装开机项）"
echo

sudo -v || { echo "✗ 未获得权限，退出"; exit 1; }

echo "1/4 拷贝 kext 到 /Library/Extensions ..."
sudo rm -rf "$KEXT_DST"
sudo cp -R "$KEXT_SRC" "$KEXT_DST"
sudo chown -R root:wheel "$KEXT_DST"

echo "2/4 立即加载（输出同时存到 /tmp/macconsole-fankext.log） ..."
sudo kmutil load -p "$KEXT_DST" 2>&1 | tee /tmp/macconsole-fankext.log | sed 's/^/    /'

echo "3/4 安装开机自动加载 (LaunchDaemon) ..."
sudo tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.macconsole.TongfangFan</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/kmutil</string>
		<string>load</string>
		<string>-p</string>
		<string>$KEXT_DST</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/macconsole-fankext.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/macconsole-fankext.log</string>
</dict>
</plist>
PLIST
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"

echo "4/4 验证 ..."
sleep 1
if ioreg -r -c TongfangFanDriver | grep -q TongfangFanDriver; then
  echo "✓ TongfangFanDriver 已在内核中运行"
  echo
  echo "安装完成！打开控制台（http://127.0.0.1:8787）→「控制」页 → 散热模式。"
  echo "也可以先用命令行试一下:"
  echo "    /usr/bin/python3 \"$DIR/fanctl.py\" mode boost"
  echo "    /usr/bin/python3 \"$DIR/fanctl.py\" mode normal   # 恢复自动调度"
else
  echo "✗ 未能找到 TongfangFanDriver 服务。排查:"
  echo "    - 看 /Library/Extensions/TongfangFan.kext 是否存在"
  echo "    - 看加载日志: sudo kmutil load -p $KEXT_DST"
  echo "    - 看系统日志: log show --last 2m --predicate 'process == \"kernel\"' | grep -i tongfang"
  echo "    （未加载成功时不影响系统其他功能，控制台散热页会显示不可用）"
fi
echo
echo "按任意键关闭..."
read -k 1
