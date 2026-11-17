#!/bin/sh
# 卸载 SkyCCMSR.kext（需 root）
#
# 用法：sudo sh Tools/uninstall-msr.sh
#
# 这个 kext 只读 MSR、不接管任何硬件，卸载是安全的：unload 掉再删目录即可。
# 删完触摸 /Library/Extensions 让系统下次重启重建 kernel collection。

set -e

DST=/Library/Extensions/SkyCCMSR.kext

if [ "$(id -u)" != "0" ]; then
  echo "需要 root：sudo sh $0" >&2
  exit 1
fi

echo "==> unload com.skycc.MSRReader"
kmutil unload -b com.skycc.MSRReader 2>&1 || echo "    （未加载或需重启后才释放）"

if [ -d "$DST" ]; then
  echo "==> 删除 $DST"
  rm -rf "$DST"
else
  echo "==> $DST 不存在，跳过"
fi

touch /Library/Extensions
echo "完成。重启后不会再加载。"
