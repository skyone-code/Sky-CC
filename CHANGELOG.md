# 更新记录

Sky CC 的版本变更、升级注意事项与产物校验值。发布渠道：<https://gitee.com/skyone021396/Sky-CC/releases>

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
