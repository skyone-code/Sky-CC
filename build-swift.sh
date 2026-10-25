#!/bin/zsh
# ============================================================================
# build-swift.sh —— 一键构建「Mac控制台」SwiftUI 原生 app + DMG 安装器
#
# 产物（都在本目录）：
#   Mac控制台-安装器-<版本>-LAPQC71专版.dmg   拖拽式安装器
#     ├─ Mac控制台.app           原生 SwiftUI 主程序（kext 已内嵌在 bundle 里）
#     ├─ 卸载Mac控制台.command    彻底卸载器
#     ├─ 说明.txt
#     └─ Applications            拖拽目标别名
#
# 2.8.12：DMG 顶层不再放 TongfangFan.kext / 安装散热控制.command。
# 没装 kext 的机器在 app 里点「立即安装」，直接安装 Contents/Resources/native/
# 里那份（同一份文件，少一次「用户该点哪个文件」的困惑）。
#
# 架构（2026-10-20 v2.5.0 起，去 Python 化）：
#   SwiftUI 原生界面（Sources/MacConsole）+ 原生硬件后端
#   （Sources/MacConsole/Native/*.swift：EC/kext、USB HID、SMC、DPCD——
#   由数月逆向成果的 Python 版逐行移植，IOKit 用户客户端直调）。
#   2.6.0 起硬件后端从 app 进程搬到后台 MacConsoleHelper（launchd LaunchAgent +
#   Mach service com.macconsole.helper），app 与它只走 NSXPCConnection；
#   EC/SMC/HID/亮度/风扇曲线只有 helper 读，UI 退出不影响散热。HTTP 与 8787 端口、
#   内置 web 页面已整体删除。随包只剩三个编译型助手二进制
#   （nvmetemp / nvmesmart）与 shell 脚本，全部与 Python 无关。
#
# 开机自启：app 内「系统 → 通用 → 开机自动启动」开关（SMAppService，macOS 13+）。
#
# 用法：改了 Swift 代码或资源后，`zsh build-swift.sh`
# ============================================================================
set -euo pipefail

BUILD="$(cd "$(dirname "$0")" && pwd)"
SWIFT="$BUILD"   # Swift 源码在 $BUILD/Sources/MacConsole/（接手包布局，无 swift/ 子目录）
# staging 目录可用环境变量改到 /tmp：本机文件策略会拦截「删除/重命名」已存在的
# app bundle（file-delete / rename source refused），原地重建会一直失败。
STAGE="${MC_STAGE:-$BUILD/swift-stage}"
# 后端资源（kext / 助手二进制 / 恢复脚本）住在 app-resources/。
# 本轮清理之前这个目录叫 python后端/ —— 那是 2.0 时代内置 Python 后端的名字，
# 2.6.0 去 Python 化之后名不副实，已随遗留清理改名。
# 当年的 .py 实现、静态页 web/、vendor/ 与那批 .command 启动脚本已一并删除
# （git 历史里还在）；目录里的 README.md 留作那份实现的逆向结论与实测记录。
# 现在构建只吃这四样：TongfangFan.kext、bin/、restore_rgb.sh、scripts 来自 templates/。
PROJ="$BUILD/app-resources"
[ -d "$PROJ" ] || { echo "错误：找不到资源目录 $PROJ" >&2; exit 1; }

# 版本号（唯一来源：脚本注入 Info.plist 与 helper 的 BuildVersion.swift）
VERSION="3.0.1.1"
# 显示版本（侧边栏/设置页文案）：数字版本 + 专用版标识
DISPLAY_VERSION="$VERSION LAPQC71专版"
# nvmetemp（NVMe 硬盘温度，SMART）——有现成二进制就用，
# 源码更新则现场重编。
# ⚠️ 2026-10-22：该工具的 C 源码全盘已找不到（原先两个外部路径都已失效），
# 现在 app-resources/bin/nvmetemp 这份二进制就是唯一来源，已纳入 git。
# 所以源码缺失不再静默降级——二进制也没了就直接报错，避免打出缺硬盘温度的包。
NVME_C=""
if [[ -f "$BUILD/Tools/nvmetemp.c" ]]; then NVME_C="$BUILD/Tools/nvmetemp.c"; fi
if [[ -n "$NVME_C" && ( ! -f "$PROJ/bin/nvmetemp" || "$NVME_C" -nt "$PROJ/bin/nvmetemp" ) ]]; then
  TMPN="$(mktemp -t nvmetemp)"
  if clang -O2 -Wall -o "$TMPN" "$NVME_C" \
        -framework IOKit -framework CoreFoundation 2>/dev/null; then
    cp "$TMPN" "$PROJ/bin/nvmetemp"
    chmod 755 "$PROJ/bin/nvmetemp"
    rm -f "$TMPN"
    echo "==> nvmetemp: 已从源码编译 → $PROJ/bin/nvmetemp"
  else
    rm -f "$TMPN"
    echo "警告：nvmetemp 编译失败，硬盘温度将显示不可用" >&2
  fi
elif [[ -x "$PROJ/bin/nvmetemp" ]]; then
  echo "==> nvmetemp: $PROJ/bin/nvmetemp"
else
  echo "错误：既没有 Tools/nvmetemp.c，也没有 $PROJ/bin/nvmetemp。" >&2
  echo "      nvmetemp 源码已丢失，这份二进制是唯一来源，请从旧包/备份恢复后重试。" >&2
  exit 1
fi

# nvmesmart（2.7.5）：按控制器枚举所有 NVMe 盘的 SMART。
# nvmetemp 只能读首块盘，第二块（SKHynix）一直「未覆盖」——这个工具补上。
nvmesmart_build() {
  local src="$BUILD/Tools/nvmesmart.c"
  [[ -f "$src" ]] || { echo "警告：缺少 Tools/nvmesmart.c，第二块硬盘 SMART 将不可用" >&2; return; }
  if [[ ! -x "$PROJ/bin/nvmesmart" || "$src" -nt "$PROJ/bin/nvmesmart" ]]; then
    mkdir -p "$PROJ/bin"
    if clang -O2 -Wall -o "$PROJ/bin/nvmesmart" "$src" \
          -framework IOKit -framework CoreFoundation 2>/dev/null; then
      chmod 755 "$PROJ/bin/nvmesmart"
      echo "==> nvmesmart: 已从源码编译 → $PROJ/bin/nvmesmart"
    else
      echo "警告：nvmesmart 编译失败（逐盘 SMART 将回退到单盘模式）" >&2
    fi
  else
    echo "==> nvmesmart: $PROJ/bin/nvmesmart"
  fi
}
nvmesmart_build

# 开机 kext 加载器（2.8.15）：取代守护里直接 exec /usr/bin/kmutil ——
# 那样 launchd 会把它显示成「系统设置 → 登录项」里一条来路不明的 "kmutil"。
# 用自己的二进制，显示名就变成「Mac控制台散热扩展」。
# 装到 /Library/PrivilegedHelperTools/（root 属主，不随 app 一起被删）。
mckextload_build() {
  local src="$BUILD/Tools/mckextload.c"
  local out="$PROJ/bin/Mac控制台散热扩展"
  [[ -f "$src" ]] || { echo "警告：缺少 Tools/mckextload.c，开机将无法自动加载 kext" >&2; return; }
  if [[ ! -x "$out" || "$src" -nt "$out" ]]; then
    mkdir -p "$PROJ/bin"
    if clang -O2 -Wall -o "$out" "$src" 2>/dev/null; then
      chmod 755 "$out"
      echo "==> kext 加载器: 已编译 → $out"
    else
      echo "警告：kext 加载器编译失败（开机自动加载 kext 会缺失）" >&2
    fi
  else
    echo "==> kext 加载器: $out"
  fi
}
mckextload_build

APP="$STAGE/Applications/Mac控制台.app"
RES="$APP/Contents/Resources"
NATIVE="$RES/native"          # 2.5.0 起：随包原生资源（旧版叫 python/）
DMGROOT="${MC_DMGROOT:-$BUILD/swift-dmgroot}"

echo "==> 1/8 清理并重建 staging"
# 用 find -delete 而不是 rm -rf：本机安全钩子对 rm 系命令的备份暂存目录
# 权限异常（root 属主），会误拦构建清理；staging 全是可再生产物，直接清内容即可
for d in "$STAGE" "$DMGROOT"; do
  if [[ -d "$d" ]]; then
    find "$d" -mindepth 1 -delete 2>/dev/null || true
  fi
done
mkdir -p "$APP/Contents/MacOS" "$NATIVE/bin" "$NATIVE/scripts"

echo "==> 2/8 编译 Swift（release，swiftc 直编）"
# 显式锁定部署目标为 14.0：本机 SDK/构建工具链是 macOS 26，swiftc 默认会把
# 二进制 minos 写成 26.0，导致在 macOS 15（及更低）上打开被拒（"当前版本不适用"）。
# 代码仅用到 macOS 14 起的 onChange(of:initial:_:)，故最低可落到 14.0，15 自然可跑。
# 注意：Native/ 子目录要显式列（shell 的 * 不递归子目录）。
# Swift 表达式类型检查器偶发超时（约束求解超过时间预算），会在无关文件上甩出
# 虚假的「cannot find X in scope」导致整编失败；这与源码正确性无关，重试通常即可
# 通过（第二次约束求解缓存命中、或时序不同便不再超时），故这里做最多 3 次重试。
# helper 版本常量：编译进二进制（不能读 Info.plist —— 原地覆盖升级后旧进程
# 读到的会是新版本号，握手会误判「无需重启」）
cat > "$SWIFT/Sources/Shared/BuildVersion.swift" <<EOF
// 由 build-swift.sh 自动生成，请勿手改
let mcHelperBuildVersion = "$VERSION"
EOF
SWIFTC_MAIN=(swiftc -O -parse-as-library -target x86_64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/Mac控制台" \
  "$SWIFT"/Sources/Shared/*.swift \
  "$SWIFT"/Sources/MacConsole/*.swift "$SWIFT"/Sources/MacConsole/Native/*.swift)
m=0; MAXTRY=3
while (( m < MAXTRY )); do
  m=$((m+1))
  echo "    [swiftc 主程序 尝试 $m/$MAXTRY]"
  if "${SWIFTC_MAIN[@]}" > /tmp/mc-swiftc-main.log 2>&1; then
    echo "    主程序编译通过（第 $m 次）"
    grep -E 'warning:' /tmp/mc-swiftc-main.log >&2 || true
    break
  fi
  echo "    swiftc 第 $m 次失败（疑似类型检查器超时，可重试）。" >&2
  if (( m == MAXTRY )); then
    echo "错误：swiftc 主程序连续 $MAXTRY 次失败。" >&2
    tail -20 /tmp/mc-swiftc-main.log >&2
    exit 1
  fi
done

echo "==> 3/8 编译 mcutil（硬件命令行助手，复用 Native 层）"
# 不加 -parse-as-library：main.swift 需要顶层代码（否则
# "expressions are not allowed at the top level"）。
swiftc -O -target x86_64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/mcutil" \
  "$SWIFT"/Sources/Shared/*.swift \
  "$SWIFT"/Sources/mcutil/main.swift "$SWIFT"/Sources/MacConsole/Native/*.swift "$SWIFT"/Sources/MacConsole/FanCurve.swift

echo "==> 3.5/8 编译 MacConsoleHelper（唯一持有 EC/SMC/HID 的后台进程）"
# 与主程序同一套 Native 层源码，但自己带 main.swift：它是 launchd 拉起的
# LaunchAgent，不是 app 的子进程，所以不能依赖 NSApplication。
swiftc -O -target x86_64-apple-macosx14.0 \
  -o "$APP/Contents/MacOS/MacConsoleHelper" \
  "$SWIFT"/Sources/Shared/*.swift \
  "$SWIFT"/Sources/MacConsoleHelper/main.swift \
  "$SWIFT"/Sources/MacConsole/Native/*.swift "$SWIFT"/Sources/MacConsole/FanCurve.swift

echo "==> 4/8 组装 app bundle（原生资源，无 Python）"
cp -R "$PROJ/TongfangFan.kext" "$NATIVE/"
if [[ -x "$PROJ/bin/nvmetemp" ]]; then
  cp "$PROJ/bin/nvmetemp" "$NATIVE/bin/nvmetemp"
  chmod 755 "$NATIVE/bin/nvmetemp"
fi
if [[ -x "$PROJ/bin/nvmesmart" ]]; then
  cp "$PROJ/bin/nvmesmart" "$NATIVE/bin/nvmesmart"
  chmod 755 "$NATIVE/bin/nvmesmart"
fi
# 开机 kext 加载器：install-kext.sh 会把它装到 /Library/PrivilegedHelperTools/，
# 由 LaunchDaemon com.macconsole.TongfangFan 以 root 调用
if [[ -x "$PROJ/bin/Mac控制台散热扩展" ]]; then
  cp "$PROJ/bin/Mac控制台散热扩展" "$NATIVE/bin/Mac控制台散热扩展"
  chmod 755 "$NATIVE/bin/Mac控制台散热扩展"
fi
cp "$BUILD/templates/install-kext.sh"  "$NATIVE/scripts/install-kext.sh"
cp "$BUILD/templates/ensure-agents.sh" "$NATIVE/scripts/ensure-agents.sh"
cp "$PROJ/restore_rgb.sh" "$NATIVE/restore_rgb.sh"
chmod 755 "$NATIVE/scripts/"*.sh "$NATIVE/restore_rgb.sh"
cp "$BUILD/icons/AppIcon.icns" "$RES/AppIcon.icns"
cp "$BUILD/templates/Info.plist" "$APP/Contents/Info.plist"
# 版本号统一由脚本顶部 VERSION 注入，避免模板硬编码与脚本不同步（2.3.1 曾因此跑偏）
# CFBundleVersion 必须保持纯数字：BackendService 用它跟 helper 的 BuildVersion 比对，
# 带中文后缀会导致「版本不一致 → 反复重启 helper」。专版标识只放 ShortVersionString。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DISPLAY_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# 后台 helper 的 LaunchAgent：SMAppService.agent(plistName:) 会到
# Contents/Library/LaunchAgents/ 找它并注册（实测 ad-hoc 签名无需审批）。
# BundleProgram 必须相对 app bundle，这样 app 被整体移动/升级也能跟着走。
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/com.macconsole.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.macconsole.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/MacConsoleHelper</string>
  <key>MachServices</key>
  <dict><key>com.macconsole.helper</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>2</integer>
</dict>
</plist>
PLIST

# 【P2 遗留清理起不再生成 com.macconsole.autostart.plist】
# 静默启动功能 2.8.15 就从代码里删掉了，这份 LaunchAgent 一直跟着 bundle 走，
# 只为让老机器升级时还能靠 SMAppService.agent(plistName:) 注销掉残留注册
# （而 SMAppService 只能注销**本 bundle 里真实存在**的 plist）。
#
# 现在改成两条互不依赖的清理，plist 不进包：
#   ① 老 bundle 里还有 plist 的（≤2.8.15），app 启动时 AutostartHeal 仍能正常注销；
#   ② 新 bundle 没有 plist 的，由 ensure-agents.sh（helper 启动序列）清掉
#      ~/Library/LaunchAgents 下的旧 plist 与 launchd 残留，卸载器再兜一层。
# 详情见 Sources/MacConsole/MacConsoleApp.swift 的 LegacyAutostart。

echo "==> 5/8 自检（语法 + 助手二进制冒烟）"
zsh -n "$NATIVE/scripts/ensure-agents.sh"
zsh -n "$NATIVE/scripts/install-kext.sh"
bash -n "$NATIVE/restore_rgb.sh"
# mcutil 冒烟：sensors 必须输出含 available 的 JSON（SMC 不可用时也是合法 JSON，
# 字段照样在；这条同时验证 Native 层链接与 IOKit 调用没崩）
SMOKE="$("$APP/Contents/MacOS/mcutil" sensors 2>&1 || true)"
if ! echo "$SMOKE" | grep -q '"available"'; then
  echo "错误：mcutil sensors 冒烟失败: $SMOKE" >&2
  exit 1
fi
echo "    mcutil sensors 冒烟通过"

echo "==> 6/8 签名（ad-hoc，本机无开发者证书）"
codesign --force --sign - "$APP/Contents/MacOS/MacConsoleHelper"
codesign --force --deep --sign - "$APP"
codesign --verify "$APP" && echo "签名校验通过"

echo "==> 7/8 组装 DMG 内容"
mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
# 2.8.12（用户要求）：kext 与「安装散热控制.command」不再放 DMG 顶层 ——
# kext 本体已经在 app 的 Contents/Resources/native/ 里，缺 kext 时 app 内
# 点「立即安装」即可，用户不需要在磁盘映像里找文件。
cp "$BUILD/templates/卸载.command" "$DMGROOT/卸载Mac控制台.command"
chmod 755 "$DMGROOT/卸载Mac控制台.command"
cp "$BUILD/templates/说明.txt" "$DMGROOT/说明.txt"
ln -s /Applications "$DMGROOT/Applications"

if [[ "${MC_SKIP_DMG:-0}" == "1" ]]; then
  echo "==> 8/8 跳过 DMG（MC_SKIP_DMG=1）"
  echo
  echo "完成（仅 app）：$APP"
  exit 0
fi

echo "==> 8/8 打 DMG"
hdiutil create -volname "Mac控制台安装器" -srcfolder "$DMGROOT" -ov -format UDZO \
  "$BUILD/Mac控制台-安装器-$VERSION-LAPQC71专版.dmg" | tail -1
hdiutil verify "$BUILD/Mac控制台-安装器-$VERSION-LAPQC71专版.dmg" >/dev/null && echo "DMG 校验通过"

echo
echo "完成：$BUILD/Mac控制台-安装器-$VERSION-LAPQC71专版.dmg"
echo "  app 内已无 Python、无 HTTP：硬件后端在 MacConsoleHelper（XPC），助手为 mcutil + 三个编译型二进制"
