# 更新记录

Sky CC 的版本变更、升级注意事项与产物校验值。发布渠道：<https://gitee.com/skyone021396/Sky-CC/releases>

---

## 3.2.0 — 2026-11-18

代号：实时频率。CPU 频率从「恒定的标称基频」变成真正随负载变化的实时读数；EC 通道换成自己维护、源码可审的内核扩展；安装器获得全新外观与旧版清理能力。

### 硬件通道

- **EC 通道重写为 SkyCCEC.kext**（`Sources/ECDriver/`）：取代只有二进制、无源码的 TongfangFan.kext。对外 ABI 完全一致（selector 0），app 无感切换；新增 selector 1 提供 MSR 采样。已在实机上与旧通道逐地址对拍（11 地址全一致）、写通路与 300 次压力测试通过。协议基于 kirainmoe/TongfangEnhancer（GPL-2.0）还原实现，**本组件因此按 GPL-2.0 发布**，安装器「软件许可」页载有声明
- **CPU 实时频率**：状态栏与监测页的 CPU 频率改为 APERF/MPERF 实时比值（基频 × ΔAPERF/ΔMPERF，中位数抹抖动），睿频与降频真实可见；拿不到读数时回落基频并标明来源（`freq_source` 字段）

### 安装器

- **自研安装器 app**（`Sources/InstallerApp/`，SwiftUI）：DMG 内不再放 pkg——改为「Sky CC 安装器.app」，全自定义界面（深浅色自适应、要点卡片、**本次更新说明**、实时进度 + 日志窗、结果页区分成功/需重启/失败），一键提权跑 6 步安装脚本（停旧进程 → 清旧残留 → 装主程序 → GPU 路由库 → 装 kext → 收尾），内嵌完整 Sky CC.app，底部带 GPL-2.0 署名
- **应用内检查更新升级为自研安装器**：更新下载 **DMG**（自研安装器）→ 自动挂载 → 拉起「Sky CC 安装器.app」→ 主程序退出，后续授权 / 安装 / 进度全在安装器可视界面完成；**「本次更新」说明卡**直接把 CHANGELOG 最新一节展示在安装器首页（构建时自动注入）。release 里没有 DMG 时回落 pkg（`installer` CLI 静默装）；静态 `latest.json` 支持 `dmg_url` 字段
- **双发布通道分工**：**DMG = 首次安装 / 手动重装 / 应用内更新**（自研安装器）；**pkg = 兜底**（应用内更新的降级通道，双击手动装则有 distribution 界面：品牌背景 + 深浅色 + 许可页）。两者共用同一套 preinstall 清理逻辑
- **安装前自动清理旧版本残留**（preinstall，root 执行、幂等，pkg 与自研安装器共用同一套清理逻辑）：旧版 Mac控制台 app、TongfangFan.kext / SkyCCMSR.kext 旧内核扩展、新旧两代 launchd 守护与登录项、旧开机加载器、历史遗留命令行工具。升级无需先卸载，用户数据（设置 / 风扇曲线 / 灯效档）原样保留，由 app 内迁移器接管

### 修复

- 安装脚本执行完但 kext 未加载时，能正确识别「macOS 26 不支持热加载、重启后生效」，不再误报安装失败

### 清理

- 仓库移除已退役的 TongfangFan.kext / SkyCCMSR.kext 二进制（git 历史与历史安装包归档中仍可追溯）

---

## 3.1.0 — 2026-11-17

代号：更名。从这一版起，`MacConsole` 这个名字在源码、二进制、系统标识、数据目录里全部退役。

### 更名（破坏性）

| 项 | 旧 | 新 |
|---|---|---|
| 源码目录 | `Sources/MacConsole/` | `Sources/SkyCC/` |
| 主程序可执行 | `MacConsole` | `Sky CC` |
| 后台进程 | `MacConsoleHelper` | `SkyCCHelper` |
| App 标识 | `com.macconsole.console` | `com.skycc.console` |
| 后台服务 | `com.macconsole.helper` | `com.skycc.helper` |
| 内核扩展 | `com.macconsole.TongfangFan` | `com.skycc.TongfangFan` |
| 数据目录 | `Application Support/MacConsole` | `Application Support/SkyCC` |

配套新增 `SkyCCMigrator`：首次启动时把旧 UserDefaults 逐键搬过来（不覆盖已有值）、把数据目录整目录迁移、bootout 并摘掉三个旧 launchd 域（helper / autostart / rgbrestore），完成后弹一条提示。

### 界面

- **显卡路由**从设置页拆出，独立成卡放在「设备控制」页散热模式上方（原来在设置页里，和散热设置分处两页，改完要来回翻）
- 侧边栏「设备检测」改名「性能监测」
- 电池卡补健康度百分比与容量对照（`4500 / 8200 mAh`）

### 修复

- **触控板开关显示与实际不符**：后台进程拿不到 HID 输入监控授权时会回落到假值，界面就永远显示「已开」。改为在 app 进程内直读（`/api/touchpad`），并给每次读取加 epoch，过期读数直接丢弃，不再覆盖新状态
- **Fn+Esc 与「Fn 锁」开关状态不同步**：原来界面读的是 `misc` 缓存（TTL 24 小时），按完快捷键一天不更新。改为新增 `/api/fnlock` 现读 `0x074E bit4` 与 `0x07A4 bit3`，1.5 秒轮询，且 `0x07A4 bit3` 作为总闸保持常开（gate 关掉时 EC 会完全忽略状态位）
- **kext 签名失效**：改名改了 `Info.plist` 的 `CFBundleIdentifier`，但没重签，`codesign` 报 `invalid Info.plist`，装到 `/Library/Extensions` 后加载失败而界面只显示「未安装」。构建脚本第 4 段已加校验，不通过就地 ad-hoc 重签

### 检查更新

- NVIDIA 驱动页、网卡驱动页的「检查更新」改为「302 读 tag → tag 没变就不查详情」，同 tag 只更新检查时间，60 秒软节流。原来每次点击都打 API，未认证按出口 IP 限流，点几下就 403

### 性能

- 应用图标与菜单栏图标改为一次解码后缓存（原先每帧重建 `NSImage` 解 ICNS）
- 根视图不再整对象订阅监控数据（每秒一次 `objectWillChange` 会重算整个侧边栏 + 详情页布局）
- 传感器读数按 1 秒 / 4 秒 TTL 合并，避免同一轮布局触发多次 EC 读取

### 升级注意

- **内核扩展可以不重装**：驱动按 IOClass 匹配，不认 bundle id，旧标识的 kext 仍在正常工作。想让标识统一、以后卸载更干净，在「设备控制」页点一次「立即安装」即可（脚本会自动卸旧装新）
- **开机自动启动需要重新打开一次**：系统按应用标识记录登录项，换标识后旧记录失效
- 偏好设置与数据目录首次启动自动迁移，会弹提示说明
- 旧 `Sky CC.app` 被同名覆盖，无需单独卸载

### 产物

| | |
|---|---|
| pkg | `Sky CC-3.1.0-LAPQC71x.pkg` · 2,820,422 B |
| SHA-256 | `23882912e828e1f950fe8fb7276aa6fb8786770bef0953282695eba65a416978` |
| DMG | `Sky CC-3.1.0-LAPQC71x.dmg` · 3,490,599 B |

---

## 3.0.7 — 2026-11-17

- 菜单栏监控重构：监控项逐项开关，可切换图标样式（自动 / 白色 / 彩色）并实时预览
- 「状态栏显示」独立成页，从设置页迁出
- 支持挂载 EFI 分区
- 检查更新改走静态 `latest.json`（raw 直链，不受 API 限流），启动静默检查 24 小时节流

## 3.0.6 — 2026-11-16

- 皮肤系统：六套预设配色 + 自定义背景图，卡片随皮肤半透明
- 透明度统一到一套基准（深色 panel 0.72 / 浅色 0.62）
- 网卡安装脚本按 1401 方案重写（EFI 定位 + 机型校验 + 备份）

## 3.0.5 — 2026-11-15

- 新增网卡驱动页：Wi-Fi / 蓝牙组件版本对照与一键更新
- 检查更新加 Gitee 兜底源
- 归档目录规范：历史版本归档名带时间戳与内部版本号
