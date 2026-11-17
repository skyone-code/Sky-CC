#!/bin/sh
# 安装 SkyCCMSR.kext 到 /Library/Extensions 并重建 kernel collection（需 root）
#
# 用法：sudo sh Sources/MSRReader/install-msr-kext.sh [kext 路径]
#      默认取仓库里的 app-resources/SkyCCMSR.kext
#
# macOS 26 不接受热加载的新 kext：装完必须重启一次，重启后 kext 才会进
# kernel collection 并可被 IOServiceGetMatchingService 找到。重新构建后
# 因为二进制变了（cdhash 变），同样要再重启一次——升级驱动时记得提醒用户。

set -e

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-$PROJ/app-resources/SkyCCMSR.kext}"
DST=/Library/Extensions/SkyCCMSR.kext

if [ "$(id -u)" != "0" ]; then
  echo "需要 root：sudo sh $0" >&2
  exit 1
fi

[ -d "$SRC" ] || { echo "!! 源 kext 不存在：$SRC" >&2; exit 1; }

echo "==> 卸掉旧的（若已加载）"
kmutil unload -b com.skycc.MSRReader >/dev/null 2>&1 || true

echo "==> 复制到 $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"
chmod 755 "$DST/Contents/MacOS/SkyCCMSR"

echo "==> 校验签名"
codesign --verify --strict "$DST"

echo "==> 重建 kernel collection"
kmutil install --volume-root / --update-all -z 2>&1 | grep -v "extension manager" || true

echo "==> 部署完成"
echo "    重启后生效：kmutil showloaded | grep -i MSR"
