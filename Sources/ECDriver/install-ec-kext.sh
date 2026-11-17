#!/bin/sh
# 安装 SkyCCEC.kext 到 /Library/Extensions 并重建 kernel collection（需 root）
#
# 用法：sudo sh Sources/ECDriver/install-ec-kext.sh [kext 路径]
#
# 装完必须重启一次：macOS 26 不接受新 kext 热加载，二进制一变（cdhash 变）
# 同样要再重启。SkyCCMSR.kext 的功能已经并进这个 kext，顺手清掉。

set -e

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-$PROJ/app-resources/SkyCCEC.kext}"
DST=/Library/Extensions/SkyCCEC.kext
OLD_MSR=/Library/Extensions/SkyCCMSR.kext

if [ "$(id -u)" != "0" ]; then
  echo "需要 root：sudo sh $0" >&2
  exit 1
fi

[ -d "$SRC" ] || { echo "!! 源 kext 不存在：$SRC" >&2; exit 1; }

echo "==> 卸掉旧的（若已加载）"
kmutil unload -b com.skycc.EC >/dev/null 2>&1 || true

echo "==> 复制到 $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"
chmod 755 "$DST/Contents/MacOS/SkyCCEC"

echo "==> 校验签名"
codesign --verify --strict "$DST"

if [ -d "$OLD_MSR" ]; then
  echo "==> 清理 SkyCCMSR.kext（功能已并进 SkyCCEC）"
  kmutil unload -b com.skycc.MSRReader >/dev/null 2>&1 || true
  rm -rf "$OLD_MSR"
fi

echo "==> 重建 kernel collection"
kmutil install --volume-root / --update-all -z 2>&1 | grep -v "extension manager" || true

echo "==> 部署完成，重启后生效"
echo "    重启后：kmutil showloaded | grep -i skycc"
echo "            ./Tools/ecprobe"
