#!/bin/zsh
# ============================================================================
# build-msr-kext.sh —— 编译 SkyCCMSR.kext（CPU 实时频率读数，APERF/MPERF）
#
# 产物默认写到 app-resources/SkyCCMSR.kext（与 TongfangFan.kext 同级，
# 后续由 app 的安装流程一起拷进 bundle 的 Contents/Resources/native/）。
#
# 为什么要单独一个 kext 而不是塞进 TongfangFan：
#   app-resources/TongfangFan.kext 只有二进制产物、仓库里从来没有源码
#   （初始导入 a83eda7 起就只有 .kext），没法给它加 selector。读 MSR 必须
#   在内核态，所以另立一个只读的小驱动，与风扇/EC 完全解耦。
#
# 用法：zsh Sources/MSRReader/build-msr-kext.sh [输出目录]
# ============================================================================
set -euo pipefail

HERE="${0:A:h}"
PROJ="${HERE:h:h}"
SRC="$HERE/SkyCCMSR.cpp"
PLIST="$HERE/Info.plist"
OUT_DIR="${1:-$PROJ/app-resources}"
OUT="$OUT_DIR/SkyCCMSR.kext"
OBJ="$(mktemp -d)/SkyCCMSR.o"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
KINC="$SDK/System/Library/Frameworks/Kernel.framework/Headers"

echo "==> 编译 $SRC"
clang++ -target x86_64-apple-macos14.0 -fapple-kext \
  -fno-builtin -fno-exceptions -fno-rtti -nostdinc++ -std=c++14 -O2 \
  -I"$KINC" -I"$SDK/usr/include" \
  -c "$SRC" -o "$OBJ"

echo "==> 链接（kext bundle，静态）"
# 三个必须项，缺一个 kmutil 就拒：
#   · -kext -static        生成 kext 形态
#   · __info_plist 段      现代 kext 要求 Info.plist 同时嵌进二进制
#   · _kmod_info 符号      由源码里的 KMOD 声明提供（链接器不再自动生成）
# -lkmodc++ 而非 -lkmod：C++ kext 需要它提供的 operator new/delete
clang++ -target x86_64-apple-macos14.0 -fapple-kext -nostdlib \
  -Wl,-kext -Wl,-static \
  -Wl,-sectcreate,__TEXT,__info_plist,"$PLIST" \
  -o "$OBJ.bin" "$OBJ" -L"$SDK/usr/lib" -lkmodc++

if ! nm -g "$OBJ.bin" | grep -q "_kmod_info"; then
  echo "错误：产物缺少 _kmod_info 符号" >&2
  exit 1
fi

echo "==> 组装 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$PLIST" "$OUT/Contents/Info.plist"
cp "$OBJ.bin" "$OUT/Contents/MacOS/SkyCCMSR"
chmod 755 "$OUT/Contents/MacOS/SkyCCMSR"

# ad-hoc 签名：本机没有开发者证书。注意 **改过 Info.plist 就必须重签**，
# 否则 _CodeSignature 里的摘要对不上，kmutil 报 invalid Info.plist
# （3.1.0 改名时在 TongfangFan.kext 上踩过这个坑）。
codesign --force --sign - "$OUT" 2>&1 | tail -1
codesign --verify --strict "$OUT" && echo "    签名校验通过"

echo "完成：$OUT （$(du -sh "$OUT" | cut -f1)）"
