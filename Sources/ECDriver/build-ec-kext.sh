#!/bin/zsh
# ============================================================================
# build-ec-kext.sh —— 编译 SkyCCEC.kext
#
# 这个 kext 是自己维护的 EC 通道（外加 CPU 实时频率的 MSR 读数），取代
# app-resources/TongfangFan.kext 那个只有二进制的产物，并吸收掉原来单独的
# SkyCCMSR.kext。对外 ABI 与 TongfangFan 一致（selector 0 + 12/8 字节结构），
# 所以验证通过后用户态只需改一个服务类名即可切换。
#
# 用法：zsh Sources/ECDriver/build-ec-kext.sh [输出目录]
# ============================================================================
set -euo pipefail

HERE="${0:A:h}"
PROJ="${HERE:h:h}"
PLIST="$HERE/Info.plist"
OUT_DIR="${1:-$PROJ/app-resources}"
OUT="$OUT_DIR/SkyCCEC.kext"
TMP="$(mktemp -d)"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
KINC="$SDK/System/Library/Frameworks/Kernel.framework/Headers"

SRCS=("$HERE/SkyCCEC.cpp")
OBJS=()

for src in $SRCS; do
  obj="$TMP/$(basename "${src%.cpp}").o"
  echo "==> 编译 $(basename "$src")"
  clang++ -target x86_64-apple-macos14.0 -fapple-kext \
    -fno-builtin -fno-exceptions -fno-rtti -nostdinc++ -std=c++14 -O2 \
    -I"$KINC" -I"$SDK/usr/include" -I"$HERE" \
    -c "$src" -o "$obj"
  OBJS+=("$obj")
done

echo "==> 链接（kext bundle，静态）"
# 三个必须项，缺一个 kmutil 就拒：
#   · -Wl,-kext -Wl,-static   生成 kext 形态
#   · __TEXT,__info_plist     现代 kext 要求 Info.plist 同时嵌进二进制
#   · _kmod_info              源码里必须显式定义（链接器不再自动生成）
# 库只能是 libkmodc++：C++ kext 的 operator new/delete 在那儿，没有 libkern。
clang++ -target x86_64-apple-macos14.0 -fapple-kext -nostdlib \
  -Wl,-kext -Wl,-static \
  -Wl,-sectcreate,__TEXT,__info_plist,"$PLIST" \
  -o "$TMP/SkyCCEC.bin" "${OBJS[@]}" -L"$SDK/usr/lib" -lkmodc++

if ! nm -g "$TMP/SkyCCEC.bin" | grep -q "_kmod_info"; then
  echo "错误：产物缺少 _kmod_info 符号" >&2
  exit 1
fi

# 非 KPI 符号检查：出现说明用了内核不导出的 API，加载时会被拒
echo "==> 检查未定义符号"
BAD=$(nm -u "$TMP/SkyCCEC.bin" | awk '{print $2}' | grep -vE "kpi|^_ZN.*OS|^_Z.*OSMetaClass|IOService|IOLog|IOSleep|IOLock|OSData|OSNumber|OSString|OSDictionary|OSBoolean|OSArray|OSObject|OSDynamicCast|OSDefineMetaClass|memcpy|memmove|memset|strcmp|strlen|strncpy|snprintf|IOMalloc|IOFree|PE_parse_boot_argn|__Znwm|__ZdlPv" || true)
if [[ -n "$BAD" ]]; then
  echo "以下符号不在 KPI 里，加载会失败：" >&2
  echo "$BAD" >&2
fi

echo "==> 组装 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$PLIST" "$OUT/Contents/Info.plist"
cp "$TMP/SkyCCEC.bin" "$OUT/Contents/MacOS/SkyCCEC"
chmod 755 "$OUT/Contents/MacOS/SkyCCEC"

# ad-hoc 签名：本机没有开发者证书。**改过 Info.plist 就必须重签**，
# 否则 _CodeSignature 里的摘要对不上，kmutil 报 invalid Info.plist。
codesign --force --sign - "$OUT" 2>&1 | tail -1
codesign --verify --strict "$OUT" && echo "    签名校验通过"

echo "完成：$OUT （$(du -sh "$OUT" | cut -f1)）"
rm -rf "$TMP"
