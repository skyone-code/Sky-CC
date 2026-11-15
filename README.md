# Sky CC · 项目现状（3.0.5）

> 本文档按 3.0.5 实际代码编写（2026-11-15）。只覆盖当前版本，不含历史版本沿革。
> 范围规则：只覆盖本目录（`Mac控制台-3.0.4.4/`）；更早的内容已封存到 `../Mac控制台-已归档/`，不引用、不追溯。

## 1. 项目是什么

**Sky CC** —— 给同方 qc71（LAPQC71D）黑苹果笔记本做的原生 macOS 硬件控制台，复刻 OEM Control Center。

| 项 | 内容 |
|---|---|
| 目标机 | Intel i7-9750H / UHD 630 核显 / RTX 2070S Max-Q 独显 |
| 系统 | macOS 26（OpenCore + VirtualSMC） |
| 配套驱动 | LAPQC71 NVIDIA fork **v3.0-Patch.1**（github.com/skyone213/nvidia-macos-driver-LAPQC71，2026-11-15） |
| 规模 | ~19,200 行 Swift（29 个主程序页面/组件 + 12 个 Native 桥接 + helper/mcutil），另有 C 工具（nvmetemp/mckextload） |
| 当前版本 | **3.0.5 LAPQC71x** —— `Sky CC-安装器-3.0.5-LAPQC71x.dmg / .pkg` 在 `05-安装包/`（DMG 校验 VALID，2026-11-14 出包） |
| Git | 快照提交 `ae0dc61`（3.0.5 全部工作已入库，工作区干净） |

## 2. 架构

```
Sky CC.app (SwiftUI, bundle id com.macconsole.console —— 保留旧 id 以兼容升级)
├── MacOS/Sky CC            主程序（纯 UI 客户端，无内嵌后端）
├── MacOS/MacConsoleHelper  常驻 helper（LaunchAgent + XPC，Mach service com.macconsole.helper）
├── MacOS/mcutil            CLI（xpc get/post/ping；sensors/rgb/fan 排障）
├── Library/LaunchAgents/   helper plist
└── native/
    ├── TongfangFan.kext    散热内核扩展（com.macconsole.TongfangFan，app 内「立即安装」）
    ├── bin/                Sky CC散热扩展 / nvmetemp / nvmesmart
    └── scripts/            install-kext.sh / ensure-agents.sh
```

**kext 通信协议**（写代码必读）：

| selector | 用途 |
|---|---|
| 0 | INFO：arg1 ← hasGuid |
| 1 | SET_MODE：arg1 = 0 normal / 1 boost / 2 custom |
| 2 | SET_LEVEL：arg1 = 0..7 |
| 3 | RAW_METHOD：arg1 = WMI methodId, arg2 = data |
| 4 | EC_WRITE：arg1 = EC 16 位地址, arg2 = 16 位数据 |
| 5 | EC_READ：arg1 = EC 16 位地址 → result |

入参 12 字节 `{u32 selector, u32 arg1, u32 arg2}`，出参 8 字节 `{i32 status, u32 result}`。

**EC 按需读取（租约制）**：EC 不常驻轮询，页面可见才读，切走 10 秒租约过期。
- 性能页看转速 → `/api/fan/live`（续租 + 读转速）
- 控制页 → `/api/fan/refresh`（读一次模式组+开关组+充电阈值，不续转速租约）
- 温度全走 SMC/NVAccel，不读 EC
- 风扇曲线运行期间 0 次 EC 读（只在切档瞬间写）

**helper 本地 HTTP API**（`Native/*.swift` 桥接）：
`/api/all` `/api/overview` `/api/battery` `/api/disks` `/api/processes`
`/api/gpu`（+`/mode` `/exclude` `/idle/want`）`/api/fan`（+`/live` `/refresh`）
`/api/control` `/api/rgb`（+`/apply` `/save` `/forget`）`/api/hid` `/api/lightbar`
`/api/apbeat` `/api/capability` `/api/ec/read` `/api/helper/shutdown|quit-all`

## 3. 页面（`MacConsoleApp.Page`，7 页）

| 页面 | 副标题 | 要点 |
|---|---|---|
| 概览 | 设备 · 风扇 · 电池 · 存储 | hero 卡置顶；风扇+电池双列 |
| 性能 | CPU · GPU · 内存 · 网络 | GPU 型号动态化（读驱动遥测） |
| 控制 | 散热 / 功耗 / 风扇手动 / 充电 | 温控曲线在本页；基准+禁用被动下移带隔线；EC 回读允许可见校正 |
| 灯效 | 键盘 RGB / 逐键投影 / 海岸灯 | 键盘灯总开关；15 灯效展开收起；海岸灯免确认防抖直发；「应用/恢复」同行 |
| NVIDIA 驱动 | 检查更新 | repo=`nvidia-macos-driver-LAPQC71`，资产名 `LAPQC71-NVIDIA-<tag>-fork.zip`；仅手动检查 |
| 全部信息 | — | AllDataView 汇总 |
| 设置 | — | 开机自启 / 外观三段（随系统/浅色/深色）/ 状态栏图标命名 / 系统与启动参数置底 |

菜单栏监控：硬盘只留温度；主图标三态命名 随系统/浅色/彩色。

## 4. 关键机制（3.0.5 包含）

- **首帧记忆**：控制/灯效/设置页 `init()` 同步读 `UIControlPrefs`，不再「默认值起步→异步跳位」。
  镜像键：`rgbEffect/Speed/Bright/Direction/Palette(42hex)/Keymap(756hex)/rgbKbOn/apbeat/gpuRoute`；
  EC 回读对不上时允许可见校正。
- **首开闪退修复**：accessory 策略下 `isActive` 不可靠 → 改判据
  `XPC_SERVICE_NAME == bundle id`（launchd 拉起）+ `SMAppService mainApp` 已启用 → 静默；双击一律亮窗。
- **NVIDIA 检查更新**：直接请求 `nvidia-macos-driver-LAPQC71` 的 release 资产名匹配，无重定向依赖。
- **Wi-Fi SSID 定位授权自申请**：`LocationPermission.swift` + Info.plist `NSLocationUsageDescription`。
- **图标资产**：`AppIcon.icns`（`Tools/gen_icons.swift` SwiftUI 渲染 → iconset → iconutil）、
  菜单栏飘带模板图、`NvidiaLogo.svg`（NSImage 原生 SVG）。
- **名称**：应用名 Sky CC，专版标识 `LAPQC71x`；卸载脚本兼容清理旧版路径。

## 5. 构建与打包

- 唯一入口：`bash build-swift.sh`。版本号唯一来源：脚本内 `VERSION="3.0.5"`，注入 Info.plist 与 `BuildVersion.swift`。
- stage 落 APFS `/tmp/mc-build/stage`（TEMP 卷直接跑会起不来）；产物 DMG/PKG 输出到源码根目录，正式包同步 `05-安装包/`。
- 构建只吃 `app-resources/` 四样：TongfangFan.kext、bin/、restore_rgb.sh、templates/ 脚本。
- `nvmetemp` C 源码已丢失，`app-resources/bin/nvmetemp` 二进制是唯一来源（已入库；缺失时构建直接报错，不静默降级）。
- `.gitignore`：`*.pkg` `*.dmg` `swift-pkgroot/` `build/` `*.app/` 不入库。

## 6. 已知问题与待办

1. **Win 键锁（未解决，方案未拍板）**：EC `0x767` bit0 写入会引发黑屏/假睡眠（EC 电源级假事件族）。
   建议方向：macOS 侧实现（CGEventTap 吞左 Command / hidutil 改映射），完全不碰 0x767；
   代价是安全输入框内可能拦不住。
2. **`0x767` 整字节写隐患**：该寄存器 4 功能共用（WinLock 0x01 / FanBoost 0x04 / SilentMode 0x08 /
   USBCharger 0x10），代码整字节写而非读改写 `(cur & 0xFE) | 0x01`，且 `ecWriteVerified` 带 4 次重试
   （toggle 语义下自清零会被重写翻转）。动 Win 键锁时必须一并改为读改写。
3. **文档生态未跟上**：`00-先读我.md`、`功能总纲-3.0.4.4.md`、`03-权威文档/` 仍是旧口径，待按本文件重写。
4. **GitHub 开源**：源码待推送到 GitHub（仓库另建，本文件随仓库作为 README 基底）。

## 7. 目录索引

| 路径 | 内容 |
|---|---|
| `00-先读我.md` | 入口（待更新为 Sky CC 口径） |
| `01-项目现状.md` | 本文件 |
| `02-版本补档/` | 版本补档 |
| `03-权威文档/` | 技术文档 + 全量手册（待更名同步） |
| `04-源代码/mc2534-src/` | 全部源码（git 仓库，HEAD `ae0dc61`） |
| `05-安装包/` | Sky CC-安装器-3.0.5-LAPQC71x.dmg / .pkg |
| `06-运行日志/` | 运行日志 |
