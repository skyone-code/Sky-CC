# Mac 控制台 · LAPQC71D

在 macOS（黑苹果）上复刻 OEM Control Center 的硬件控制面板。  
基于你提供的 Windows 版 Control Center 安装文件逆向实现，**纯 Python 标准库 + ctypes 直调 IOKit，零第三方依赖**。

---

## 快速开始

双击 **`启动控制台.command`** —— 会自动启动本地服务并打开浏览器（地址 `http://127.0.0.1:8787`）。

停止：双击 `停止控制台.command`。

---

## 功能与实测结论

这台机器（i7-9750H / UHD630 + RTX 2070S Max-Q / macOS 15.8.1 / OpenCore）上，  
原版 Control Center 的功能在 macOS 端的可行性如下。**这是实测结论，不是推测。**

### ✅ 完全可用

| 功能               | 实现方式                                               |
| ---------------- | -------------------------------------------------- |
| CPU 六核独立温度       | SMC `TC1C` ~ `TC6C`，sp78 定点                        |
| CPU 封装温度         | SMC `TC0P` / `TC0D` / `TC0E` / `TC0F` / `TC0H`     |
| CPU 电流与功耗        | SMC `PC0C` / `PCPC` / `PCPT` / `PCTR`，sp96 定点（÷64） |
| 内存 / 负载 / 运行时间   | `sysctl` + `vm_stat`                               |
| 显卡信息             | `system_profiler`，核显与 RTX 2070S 均可见                |
| 电池               | `ioreg AppleSmartBattery` + `pmset`                |
| 磁盘占用             | `df`，含 Word / Windows 分区                           |
| **键盘灯控制**        | ITE 8291 (048d:ce00) 的 HID Feature 报告，**已实测可写入**   |
| 音量 / 阻止休眠        | `osascript` / `caffeinate`                                                               |
| **屏幕亮度**         | `bright.py`（IOKit `IODisplaySetFloatParameter` 写系统亮度）+ `~/bin/auxbright 写面板背光本体`。**本机只改前者到不了屏幕**，所以服务端两条一起走；找不到 auxbright 时自动降级。`auxsmooth` 守护负责把亮度变化**平滑过渡**到面板（见「无级亮度」一节） |
| **散热模式控制**       | TongfangFan.kext → EC 邮箱；自动 / 基准·拉满 / 手动 L0-7，**已实测** |
| **风扇转速与温度读数**   | 直读 EC `0x046C`(CPU 风扇) / `0x0464`(GPU 风扇)（大端）+ `0x043E`(CPU) / `0x044F`(独显)，**已实测** |
| ~~CPU 性能档（TURBO_LEVEL）~~ | `CTRL_2 (0x078C)` bit2-3，**写得进去但无下游**——OEM 侧实为切 Windows 电源计划（四档，第 4 档疑为隐藏的 Ultimate Performance），macOS 无对应物，**控制页按钮已于 2026-10-16 移除** |
| **电池充电阈值**       | EC `0x07B9`，bit0-6 = 百分比，**已实测可写**（设 80 → 回读 0xD0） |
| **海岸灯（灯条）**       | EC `0x0748` 控制字节 + `0x0749-74B` RGB；多彩轮换 / 应用颜色 / 关闭，**已实测**（2026-10-16 用户确认全部正常） |

### ⚠️ 部分可用

- **电池健康度**：VirtualSMC 对电池建模较粗——循环次数恒为 0、设计容量等于最大容量，  
  容量读数可信度有限。电压/温度/充电状态是可信的。
- **CPU 性能档（TURBO_LEVEL）已从控制台移除**（2026-10-16）：它写 `CTRL_2 (0x078C)` bit2-3，
  写得进去但**没有任何下游**——全页差分显示只有 `CTRL_2` 自己变；满载下 0/1/2/3 档
  运算量差 <2%，而真在切 35W/45W/65W 应该差几十个百分点。
  OEM 侧它是 `TURBO_MODE` 四档设置（1-4，默认 2），**真实功能是在 Windows 上切电源计划**：
  本机 hive 里出现过标准 Ultimate Performance 方案（`powrprof.dll,-19`），第 4 档疑为该极限档。
  macOS 没有电源计划机制、EC 侧又没有功耗墙可调，所以无论第几档都无效果。
  详见[「CPU 性能档 0-3 到底是什么」](#cpu-性能档-0-3-到底是什么oem-控制中默逆向证据)。
- **性能模式（专业 / 平衡 / 省电）实测有效（2026-10-16 05:00 修正，此前误判）**：
  写 `MyFanCCI_Mode_Index (0x07AB)` = `0x11/0x22/0x33` 会同时改 `CTRL_3 (0x07A5)`、
  `FAN_CTRL (0x0751)` 和 EC 内部风扇调度区，**风扇行为和 CPU 算力都有可复现的差异**
  （专业档算力最快、风扇随温爬升；平衡档风扇最猛；省电档风扇压在 31% 不动、算力慢 5~9%）。
  详见[「性能模式：从误判到实测有效」](#性能模式从误判到实测有效2026-10-16-0500-修正)。
  **控制页已接入这三个按钮**（2026-10-16 05:10，名字用 BIOS 的叫法：专业/平衡/省电），
  绿色打勾一律以 EC 回读的 `0x07AB` 为准。
- **OEM 三套功耗预设（GAMING 65/100/130、OFFICE 45/65/160、BATTERYSAVER 35/60/160）无效**：
  本机**没有功耗墙，只有温度墙**（用户确认）。生效寄存器 `0x0783/84/85` 恒为 0，
  且**直接写进去 0.3 秒内就被 EC 清零**——固件未启用 PL 调节，与「没有功耗墙」完全吻合。
- 以上带「已实测」的 EC 能力都依赖自编译的 `TongfangFan.kext`，  
  需双击 `安装散热控制.command` 加载一次（需管理员密码，不改 EFI）。

### ❌ 不可用（以及为什么）

| 功能                      | 原因                                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| **SMC 风扇建模**            | VirtualSMC 的 `FNum = 0`，`F0Ac` / `F0Mn` / `F0Mx` 均不存在。但风扇并未失联——转速已改从 EC 直读，见上一节 |
| **PL1 / PL2 数值调节**       | 寄存器确实在 EC（`0x0783` / `0x0784`），但本机读回恒为 0，固件未启用                                          |
| **屏幕色彩 / 显示性能档位**        | EC 与 DSDT 里都没有对应寄存器，属显卡 / PCH 层面，macOS 下不可达                                          |

> 说明：`FNum = 0` 是关键证据。如果 SMC 建模了风扇，通常会出现 `F0Ac`（实际转速）、  
> `F0Mn`/`F0Mx`（最小/最大）、`F0Tg`（目标转速）这一整套键。本机一个都没有，  
> 所以转速改走 EC 寄存器直读。

---

## 键盘灯协议（逆向结果）

**设备**：`ITE Device(8291)`，VID:PID = `048d:ce00`，USB bcdDevice = `0.03`  
**接口**：HID Usage Page `0xFF03`，Usage 1，未被系统事件驱动独占 → 用户态可直接读写  
**报告**：Feature 8 字节 / Output 64 字节 / Input 64 字节，**Report ID 均为 0**

### 命令表

| 命令     | 用途          | 8 字节载荷                                |
| ------ | ----------- | ------------------------------------- |
| `0x08` | 设置灯效        | `08 02 <效果> <速度> <亮度> <颜色> <附加> <保存>` |
| `0x08` | 关闭背光        | `08 01 00 00 00 00 00 00`             |
| `0x08` | 进用户模式 / 调亮度 | `08 02 33 00 <亮度> 00 00 <保存>`         |
| `0x16` | 选择行 (0-5)   | `16 00 <行号> 00 00 00 00 00`           |
| `0x14` | 设置命名色 1-7   | `14 00 <序号> <R> <G> <B> 00 00`        |
| `0x80` | 读固件版本       | `80 00 00 00 00 00 00 00`，随后 GET 回读   |

- **亮度**：`0x08` / `0x16` / `0x24` / `0x32`（最暗 → 最亮），即 8/22/36/50
- **速度**：`0x01` ~ `0x0A`（最快 → 最慢）
- **命名色**（预设灯效用）：`01` 红 `02` 橙 `03` 黄 `04` 绿 `05` 蓝 `06` 青 `07` 紫 `08` 彩虹

### 颜色数据的关键：分平面，不是交错 RGB

键盘物理上是 **6 行 × 21 列**。每更新一行：先发 `16 00 <行号>`，再向 OUT 端点写  
**64 字节「分平面」行缓冲**：

```
[ 0..20] 蓝平面 21B   [21..41] 绿平面 21B   [42..62] 红平面 21B   [63] 填充
```

> ⚠️ 早期我按 `[pad, R, G, B] × 16` 的交错格式下发，固件把交错的 `00 FF FF FF`  
> 当平面解析，三个平面各自「大部分亮、少量灭」，合成出偏冷的白 ——  
> 表现就是「设白色结果出来是淡蓝」。改成平面布局后，**纯红等纯色立刻变均匀正确**；  
> 但**纯白仍会偏蓝**，那是另一层原因（灯条硬件白平衡），需要走下面的「白色光谱校准」。

### 预设灯效码

| 名称                        | 码      | 名称                  | 码      |
| ------------------------- | ------ | ------------------- | ------ |
| 呼吸 breathing              | `0x02` | 跑马灯 marquee         | `0x09` |
| 波浪 wave                   | `0x03` | 雨滴 raindrop         | `0x0A` |
| 随机 random / 按键响应 reactive | `0x04` | 极光 aurora / 响应极光    | `0x0E` |
| 彩虹 rainbow                | `0x05` | 烟花 fireworks        | `0x11` |
| 涟漪 ripple                 | `0x06` | 响应涟漪 reactiveripple | `0x07` |

### 证据来源

1. 本机 OEM Control Center 的 `keyboard.dll` 导出符号：  
   `HID_Get_FirmwareVersion_80H` / `HID_Set_Effect_Type_08H` /  
   `HID_Set_Picture_12H` / `HID_Set_Color_14H` / `HID_Set_RowIndex_16H` /  
   `ColorBufferConvertTo12H` / `Set_ITE_Effect_Type_FourZoneUserMode` /  
   `ColorCalibrationResultCode`
2. **`pobrn/ite8291r3-ctl`** —— 专治 rev 0.03 的用户态驱动，`PRODUCT_IDS` 里  
   明确包含 `0xCE00`。颜色布局（6 行 × 21 列、分平面、65 字节行缓冲）与  
   `0x16` 选行命令均以它为准
3. **`ZavierChen/BetterRGB-ITE8291-Adaptive`** —— 同模具 ITE8291 键盘的独立控制器，  
   提供「白色光谱校准」；本项目的白平衡算法照搬它的 `calculate_white_calibration`
4. 本机 OEM 的 `RGBKeyboardView.reg`：`ColorBuffer` 为 **3 字节一组**的 RGB 三元组  
   （红/橙/黄/绿/蓝/青/紫），印证「R 在前、4 分区」的原厂表示
5. `rodgomesc/avell-unofficial-control-center` 与 `kirainmoe/tongfang-macos` issue #28  
   —— 注意 avell 的 `[0x00, R, G, B] × 16` 交错布局**不适用于本机**，照抄会导致白色变淡蓝

### 本机实测记录

```
GET  Feature(8B, id=0)  -> kr=0  data=0801000301000800
SET  Feature 8000000000000000   -> kr=0
GET  Feature            -> kr=0  data=8013070000000000   (固件 0x13.0x07)
SET  user_mode + 6 行平面缓冲    -> kr=0  (纯红整块均匀 ✓、纯白 ✓)
```

---

## 散热模式控制（TongfangFan.kext）

风扇调速当初判定「不可用」的前提是「走 SMC 路径」。实际还有一条 Windows 版  
Control Center 自己在用的通路，不经过 SMC：

```
用户态 fanctl.py ──IOUserClient──▶ TongfangFan.kext（内核）
    │                                  │
    │                     自己解析 _WDG + evaluateObject 调 AML
    ▼                                  ▼
  EC 寄存器 0x751 ◀── DSDT 的 WMBC 方法（WMI 块 ABBC0F6F，method 4 = GetSetULong）
```

- 本机 DSDT 的 WMI 设备带完整同方方法块（`ABBC0F6A`~`ABBC0F72`），  
  其中 `ABBC0F6F` 就是 EC 读写的 GetSetULong，由固件 AML 代为写 EC——  
  所以不需要用户态 EC 直写，也不需要碰 SuperIO。
- `TongfangFan.kext` 是参考 kirainmoe 的 TongfangEnhancer 重写的精简版  
  （只保留风扇通路，砍掉热键——本机的 VoodooWMIHotkey 已经在管 Fn 键），  
  用命令行 clang 编译（无需完整 Xcode），ad-hoc 签名。  
  源码与构建脚本在 `kext-src/`（双击 `构建kext.command` 即可重编）。
- 前置条件：SIP 的「Kext Signing」为 disabled（本机即是）。
- **v1.0.1 起 kext 不再依赖 VoodooWMI**：直接挂 ACPI WMI 设备（`PNP0C14`），  
  自己解析 `_WDG` 找到 `ABBC0F6F` 块、自己求值 `WMxx` ACPI 方法。  
  原因：本机 VoodooWMI 是 OpenCore 注入的，不在磁盘内核扩展搜索路径里，  
  依赖它会导致 `kmutil load` 报  
  `Failed to bind ... could not find a kext with 'io.github.goshin.VoodooWMI' bundle-id`  
  （在 macOS 15 上实测踩坑）。现在依赖只剩系统自带的 `IOACPIFamily`，  
  运行时加载即可成功，开机注入与否都无所谓。
- **v1.0.4 关键修复（IOMatchCategory）**：IOKit 规定同一 provider 上  
  每个匹配类别只挂载一个驱动，未声明 `IOMatchCategory` 的驱动全部归入  
  默认类别——VoodooWMI 已占据所有 WMI 设备的默认类别，导致本 kext  
  「加载成功但驱动永远不出现」（v1.0.1~1.0.3 的病根，排查了三轮才定位）。  
  现在personality声明了独立类别 `IOMatchCategory=TongfangFan`，  
  可与 VoodooWMI 并排挂载同一设备。
- 另两个排障结论（写在这避免再踩）：  
  ① 内核加载 kext 时会自动遍历 `__mod_init_func` 执行静态构造器（xnu  
  OSRuntimeInitializeCPP），kext 的 kmod 入口**绝不能**再手动调构造器，  
  否则 OSMetaClass 双重注册直接内核恐慌；  
  ② kext 签名覆盖 Info.plist，改 plist 就必须重签+重新批准；  
  ③ zsh 内建 `log` 会劫持 `log show`，脚本里必须用 `/usr/bin/log` 绝对路径。

**模式字节**（EC 0x751，与 Windows Control Center 一致）：

写入前的**关键前置**：必须先置 `CTRL_1 (0x0741)` 的 bit0 开「手动门」，否则 EC
**静默拒收**——返回命令回显但寄存器值纹丝不动（这个坑排查了很久）。

另一个坑：**不要直写 PWM**（`0x1804` / `0x1809`）。写 `0xFF` 会让 EC 直接停转风扇，
实测温度从 64°C 冲到 72°C。正确做法是只写 `FAN_CTRL` 档位，让 EC 自己算占空比。

| 写入值       | 含义                   | 实测占空比 / 转速      |
| --------- | -------------------- | ---------------- |
| `CTRL_1=0` | 自动——交回 EC 调度          | 约 30% / 2900 RPM |
| `0x40`    | 基准·拉满（BOOST）         | **78% / 5500 RPM** |
| `0x80+n`  | 手动档 n（0~7）           | 24%~53% / 2300→4300 RPM |

**安装**：双击 **`安装散热控制.command`**（会把 kext 拷到  
`/Library/Extensions` 并立即加载，再装一个 LaunchDaemon 开机自动加载）。  
之后控制台「控制」页就有卡片，改完立即生效：

- 散热：自动 / 基准·拉满 / 手动档 0-7 滑条
- **性能模式**：专业 / 平衡 / 省电（写 EC `0x07AB`，键盘灯实时跟随）
- **电池充电阈值**：不限制 / 80% / 60%

重启后自动恢复（状态存  
`~/Library/Application Support/MacConsole/fan_state.json`）。  
卸载：双击 `卸载散热控制.command`，风扇回 EC 自动调度。

命令行：

```bash
/usr/bin/python3 fanctl.py status         # 转速 / 温度 / 占空比 / 当前模式
/usr/bin/python3 fanctl.py mode boost     # 基准·拉满
/usr/bin/python3 fanctl.py mode normal    # 回自动调度
/usr/bin/python3 fanctl.py level 5        # 手动档 5
/usr/bin/python3 fanctl.py profile perf   # 性能模式 quiet|balance|perf
/usr/bin/python3 fanctl.py monitor        # 2 秒刷新监控
/usr/bin/python3 fanctl.py ec r 0x0751    # 读任意 EC 寄存器
```

> 三个注意事项：
>
> 1. kext 是为本机自编译的，没有经过大规模社区验证。加载失败不影响系统其他功能，
>    控制台相关卡片会显示「不可用」。
> 2. EC 邮箱是**全局单例**，并发访问会被拒（`0xFEFEFEFE`）。
>    `fanctl.py` 用全局锁串行化 + 忙时自动重试，网页端已压测通过。
> 3. 界面显示的模式一律以 **EC 实际读数**为准，而不是「上次保存了什么」——
>    下发失败时能立刻看出来。

### CPU 性能档 0-3 到底是什么（OEM 控制中默逆向证据）

> ⚠️ **2026-10-16 更新**：控制页的「CPU 性能档」按钮与 `/api/fan` 的 `turbo` 参数**已移除**。
> 本节保留作为查证记录——它解释了为什么这一项没有意义。

界面上的「CPU 性能档」写的是 `CTRL_2 (0x078C)` 的 **bit2-3（TURBO_LEVEL）**，
OEM 侧名字是 `AP_OEM_BYTE2`（和 `CTRL_1`=`AP_OEM_BYTE` 同系列的通用 OEM 字节）。

从 Windows 侧 OEM `Control Center` 的 `keyboard.dll`（.NET，未加壳）里直接读出的枚举常量：

```
FAN_GAMING_MODE = 0     FAN_OFFICE_MODE = 1     FAN_TURBO_MODE = 2
FAN_MODE_NORMAL = 0     FAN_MODE_BOOST  = 1     FAN_MODE_CUSTOMIZE = 2
TURBO_MODE_MIN = 1      TURBO_MODE_1..4 = 1..4  TURBO_MODE_DEFAULT = 2   TURBO_MODE_MAX = 4
QKEY_MODESWITCH = 0     QKEY_FANBOOST   = 1
```

以及它定义的 EC 寄存器表（与 Linux `qc71_laptop` 完全一致，可交叉验证）：

| OEM 常量名                     | 地址     | Linux 里的名字 / 含义                    |
| -------------------------- | ------ | --------------------------------- |
| `ADDR_AP_OEM_BYTE`         | 0x0741 | `CTRL_1`（bit0 手动模式门）               |
| `ADDR_AP_OEM_BYTE2`        | 0x078C | `CTRL_2`（bit2-3 TURBO_LEVEL）        |
| `ADDR_AP_OEM_BYTE3/4/6`    | 0x07A5 / 0x07A6 / 0x078E | `CTRL_3` / `CTRL_4` / `CTRL_6` |
| `ADDR_MAFAN_CONTROL_BYTE`  | 0x0751 | `FAN_CTRL`（**基准模式走这里**，bit6 BOOST）  |
| `ADDR_STAUTS_BYTE`         | 0x0768 | `STATUS_1`（bit2 FAN_BOOST 状态位）       |
| `ADDR_SUPPORT_BYTE1/2/5`   | 0x0765 / 0x0766 / 0x0742 | `SUPPORT_1/2/5`           |
| `ADDR_TRIGGER_BYTE`        | 0x0767 | `TRIGGER_1`（bit2 FAN_BOOST）          |

**结论一：第 4 个档位不是「基准模式」。**
「基准模式」在 OEM 里对应 `FAN_MODE_BOOST` / `QKEY_FANBOOST`，是写 **`FAN_CTRL (0x0751)` 的 bit6**
（再把 PWM 顶到最大），和我们已经实现的「基准 · 拉满」是同一件事。**它和 CTRL_2 是两个不同的寄存器。**

**结论二（2026-10-16 修正）：档位是四档，第 4 档承载在 bit4。**
早年这里写「第 4 个编码 OEM 不用」，是因为只看到 `FAN_GAMING/OFFICE/TURBO` 三个风扇枚举。
后来从 `keyboard.dll` 提出完整的常量表，发现 **`TURBO_MODE_1~4`（MIN=1 / MAX=4 / DEFAULT=2）
是一个独立的四档设置**——bit2-3 只能表示 0-3，第 4 档唯一合理的承载位就是 **bit4**
（`keyboard.dll` 模式位表里 `Turbo_Mode = 16 (0x10)` 也指向 bit4；该位语义未实测，按红线不写）。

这四档在 Windows 侧的真实用途是**切电源计划**：本机 SYSTEM hive 里出现过标准
**Ultimate Performance** 方案（`e9a42b02-d5df-448d-aa00-03f14749eb61`，资源串
`powrprof.dll,-19,Ultimate Performance`），且 MySettingDLL 里有整套
`PowerDuplicateScheme` / `PowerSetActiveScheme` + `powerWriteHiPerformanceName` 等
「复制方案 + 改名」的代码。按 1=省电 / 2=平衡（默认）/ 3=高性能 / 4=极限 排，
与 Windows 的四级方案对齐（**档位↔方案的具体映射是推断**，OEM 不硬编码 GUID）。
但 macOS 没有电源计划机制，EC 侧又没有功耗墙——所以这一项在 Mac 控制台上**无论第几档都没有下游**。

（历史记录：本机 EC 里存着三套 PL 预设，早年曾猜测它们对应 OEM 的三个按钮：）

| 预设（EC 地址）                  | PL1    | PL2     | PL4  | 读到的位置（本机实测）     |
| -------------------------- | ------ | ------- | ---- | ---------------- |
| `ADDR_GAMING_*` 0x0730-32  | 65 W   | 100 W   | 130  | `0x0730=0x41` 等 |
| `ADDR_OFFICE_*` 0x0734-36  | 45 W   | 65 W    | 160  | `0x0734=0x2D` 等 |
| `ADDR_BATTERYSAVER_*` 0x07A7-A9 | 35 W | 60 W | 160  | `0x07A7=0x23` 等 |

（这三套 PL 预设与 TURBO_MODE 的对应关系并未证实，且它们本身已确认无效——见功耗墙一节。）

**结论三：它改不动功耗。**
逐个下发 0/1/2/3 后，把 EC 的 `0x07` / `0x04` **两整页（512 个寄存器）**做差分，
只有 `CTRL_2` 自己变了，`PL1/PL2/PL4 (0x0783/84/85)`、`FAN_MODE_INDEX (0x07AB)`、
`CTRL_3`、`MyFanCCI_Mode_Profile1/2/3 (0x07B0/B1/B2)` 全部无变化。

### 直接跑负载实测（2026-10-15）

不看寄存器看结果：**12 线程跑满**，每个档位之间室温稳定、顺序连续，取最后 14 秒稳态。

| 档位 | `CTRL_2` 回读 | CPU 封装功耗 `PCPC` | 占空比 | CPU 温度 | 转速 | 完成迭代数 |
| ---- | ----------- | ---------------- | --- | ------ | ---- | ----- |
| L0   | 0x0 | 3162 | 129 | 89.7 ℃ | 4159 | 2339 |
| L1   | 0x4 | 3740 | 129 | 89.6 ℃ | 4152 | 2363 |
| L2   | 0x8 | 4213 | 133 | 89.7 ℃ | 4253 | 2379 |
| L3   | 0xC | 3661 | 133 | 89.6 ℃ | 4232 | 2368 |
| L0（复测） | 0x0 | 3880 | 132 | 88.9 ℃ | 4205 | 2390 |

**完成迭代数是最硬的判据**：四档之间只差 **±2%**，而这份 Benchmark 的重复性本身就在 ±1%。
真要是 PL1 在 35W / 45W / 65W 之间切，全核满载的持续频率会差出**几十个百分点**。
（`PCPC` 那 22% 的漂移是 SMC 侧读数自己的问题，同一-round 的重复基线也对不上。）

所以这四个按钮**无法按功耗大小排序** —— 我们测不出它改变了什么，也就没有依据去标
「哪个更省电、哪个更猛」。界面上已改写成中性的 `L0` ~ `L3` 并注明。

---

### 性能模式：从误判到实测有效（2026-10-16 05:00 修正）

> ⚠️ **本节是 2026-10-16 05:00 的修正版。** 在此之前的三轮测试都结论为「无效」，
> 原因是**负载方式错了**（详见下文「教训」）。现在结论是：**档位真实有效**。

#### 一、`CTRL_3 (0x07A5)` 这条路：确实走不通（2026-10-15，结论仍成立）

「性能模式」三个按钮最初写的是 `CTRL_3 (0x07A5)`。逐位测试写入保持性：

```
写 0x99 -> 回读 0x99    接受        写 0x9D -> 回读 0x99    ✗ bit2 被掩码
写 0x89 -> 回读 0x89    接受        写 0x9F -> 回读 0x99    ✗ bit2 被掩码
写 0x19 -> 回读 0x19    接受        写 0x91 -> 回读 0x91    接受
```

`bit2 = FAN_QUIET` 手工**写不进去**（和 `SUPPORT_2 (0x0766) bit0 = 0` 一致）；
`bit4 = OVERBOOST` 写得住，但 4 线程中负载稳态下清/置它：占空比 120→120、
温度 75.0→75.0、转速 4010→4016，**没有后果**。

#### 二、正确的入口是 `MyFanCCI_Mode_Index (0x07AB)`，档位码是魔数

| OEM 语义 | 实际写入 `0x07AB` 的值 | 同时镜像到 |
| ------ | ----------------- | ----- |
| 专业 / 性能（Gaming） | `0x11` | `Mode_Profile1 (0x07B0)` |
| 平衡 / 均衡（Office） | `0x22` | `Mode_Profile2 (0x07B1)` |
| 省电（BatterySaver） | `0x33` | `Mode_Profile3 (0x07B2)` |

（命名依据：OEM 程序集里的枚举 `Performance=1 / Balanced=2 / BatterySaver=3`，
乘 `0x11` 正好等于这三个魔数；与 BIOS 里「专业=2 灯、平衡=1 灯、省电=不亮」的灯位一致。）

> **BIOS 里的对应选项（2026-10-16 从 QC0158.CAP 的 AMI IFR 逆向确认）**：
> Setup 主表单里的 **Power Mode** = `Performance(1) / Balanced(2) / Battery Saver(3)`，
> 值乘 `0x11` 即 EC 魔数。**注意它不是风扇选项**——同一表单里另有一个独立的
> **Fan Control Mode**（`Fixed(0) / Custom(1) / Cool(2) / Balanced(3) / Quiet(4) / Fanless(5)`），
> 帮助文字写明"Quiet/Balanced/Cool 是预设自动风扇曲线，Custom 是用户可调曲线，Fixed 是固定占空比"，
> 那才是真正的风扇设置。BIOS 的「Q-Key function」选项也佐证了这点：
> MODE SWITCH 的描述是 "between office mode and gaming mode"，切的正是 Power Mode。
>
> **追查结论（2026-10-16）**：Fan Control Mode **没有运行时入口**——OEM 地址表里没有
> 对应寄存器，`MYFAN2` 曲线单元格 `0x0743-47` 是 EC 独占的死单元格（写得进、回读一致、
> 风扇毫无反应），`CTRL_3` 低三位在模式索引有效时被 EC 秒级覆盖。它是 POST 时按 NVRAM
> 一次性选好的内部曲线，之后 EC 自己调度。可试路径：BIOS 里设为 Custom 再重启，
> EC 可能就会启用曲线单元格（待验证）。详见「能力边界」页同名条目。

**寄存器层面的效应**（页内全差分，页 0 + 页 7 共 512 字节 × 3 档）：
只有这些字节随档位变化 —— 页 7 `0x0A / 0x0F / 0x11 / 0x13 / 0x51(FAN_CTRL) / 0x5B / 0x5C /
0xA5(CTRL_3) / 0xAB(索引)`，页 0 `0xD0-0xD9 / 0xDE / 0xDF`。
其中页 0 `0xD0-0xDF` 与页 7 `0x10-0x1F` 是**同一段 16 字节环形缓冲的两个视图**（随时间轮转），
语义未明，疑似 EC 内部风扇调度工作区。

| 档位 | `CTRL_3` | `FAN_CTRL` |
| --- | --- | --- |
| 专业 `0x11` | `0x89` | `0x00` |
| 平衡 `0x22` | `0x88` | `0xA0` |
| 省电 `0x33` | `0x8E` | `0xA0` |

#### 三、真满载下的行为差异（本轮的核心发现）

**测试方法**：12 个子进程真满载（不是线程，见教训），每轮 10-12 秒、2 秒采样、
轮间冷却到 CPU < 60℃、A/B/C/A 交叉排序、90℃ 自动熔断。

| 档位 | 同温（78-81℃）占空比 | CPU 温度 | 算力（10 秒迭代数） |
| --- | --- | --- | --- |
| 专业 `0x11` | 风扇随温爬升 29→44% | 80-87℃（最热） | **最快**（基准） |
| 平衡 `0x22` | 最猛，78℃ 就 41-47% | 77-81℃ | 慢 4~5% |
| 省电 `0x33` | 压在 31% 不动 | 74-82℃ | 慢 5~9% |

复现性：专业档两轮 207.9M / 209.5M（差 0.8%）；换序复测仍是最快
（175.2M vs 167.8M vs 159.2M）。**档位差 4~9%，远超 1% 的测量噪声。**

注意专业档温度最高却算力最高——说明它确实在让 CPU 放开跑，
而省电档是用「风扇不转 + CPU 降速」来省电。

#### 四、OEM 三套功耗预设：确认无效（本机没有功耗墙）

> 用户 2026-10-16 明确更正：**没有功耗墙，之前说的功耗墙其实是温度墙**（CPU 90℃ / 独显 75℃）。

| 预设 | 寄存器 | 出厂值 |
| --- | --- | --- |
| GAMING | `0x0730/0x0731/0x0732` | `65 / 100 / 130` |
| OFFICE | `0x0734/0x0735/0x0736` | `45 / 65 / 160` |
| BATTERYSAVER | `0x07A7/0x07A8/0x07A9` | `35 / 60 / 160` |

三组出厂值都在，但**真正生效的 `0x0783/0x0784/0x0785` 恒为 0**。
更硬的证据：**直接往生效寄存器写值，立即回读成功，0.3 秒后就被 EC 清零**
（写 65/100/130/45 都一样；而同一套写路径对 `CTRL_2`、风扇曲线点都能写能保持）。
即 EC 独占这些单元格、固件未启用 PL 调节。

第 0 页（ACPI EC 空间，DSDT `ECXP` 区）的 `PL1L/PL2L/PL3L/PL4L (0x6A-0x6F)`、
`TCOS (0x63)`、`TURB (0x66)` 三档下也**全程为 0**（这条链路经 `_Q70/71/72` +
SMI `0xAA/0x99/0x9A` 推给 BIOS 写 MSR，本机从来没被填过值）。
页 0 其他字节可读（41 个非零），证明不是读不到。

**结论：三套功耗预设在本机没有任何作用**——与「没有功耗墙」的更正完全吻合。
风扇曲线 `0x0743-0x0747`（60,70,80,100,120）和 `MyFanI 0x079E-0x07A0` 三档下也不变，
所以档位不是靠改曲线生效，而是靠 `CTRL_3`/`FAN_CTRL` + EC 内部调度区。

#### 五、OEM 控制台是怎么实现的（逆向结论）

模式按钮的完整链路：EC 置 `OSDF (0x7C) = 0xB0`（OEM 常量 `OSD_FanModeSwitch = 0xB000`）
→ SCI 查询 `_Q53` → `AMW0.WMBC(0, 3, OSDT)` → `Notify(AMW0, 0xD2)` →
**Windows 侧 `UWACPIDriver.sys` 捕获该 WMI 事件后，写模式索引 + PL 设置 + 触发字节**。

所以在 Windows 里不开控制台也有效（驱动常驻），而在 macOS 里**没有人监听这个 WMI 事件，
按钮自然无效**——但**直接写 `0x07AB` 就能完整复现三个档位的全部效果**。

**键盘灯已实测确认**：写 `0x07AB` 后模式灯实时跟随（专业=2 灯、平衡=1 灯、省电=不亮，
2026-10-16 用户肉眼确认），说明灯也是 EC 用这个寄存器实时驱动的——
所以 Mac 控制台切档位时视觉反馈和 Windows 完全一致。

**控制台已接入**：控制页「散热模式」卡片里新增「性能模式」一排按钮（专业 / 平衡 / 省电），
高亮一律以 EC 回读的 `0x07AB` 为准（`/api/fan` 新增 `modeindex` 字段，
POST 传 `modeindex: 0x11/0x22/0x33`）。

#### 六、教训：为什么之前三轮都误判为「无效」

1. **负载方式错了**：旧测试用 Python `threading` 起 12 个线程——**GIL 串行化，
   实际只压满一个核**，温度上不到 60℃，三档都停在最小占空比 24%，又叠了外部散热，
   当然测不出差别。
2. **只盯寄存器、没看行为**：旧测试反复对比 PL / 曲线 / MyFanI（这些确实不变），
   却没有直接对比风扇行为和算力。
3. `multiprocessing` 在本机 Python 3.13 走 **spawn**，会把 heredoc 的 `<stdin>`
   当主模块重载，12 个子进程全部 `FileNotFoundError` 秒退（CPU 纹丝不动，靠「温度 54℃ 不动」露馅）。
   **正确做法：写成 `/tmp/burner2.py`，用 `subprocess.Popen` 起 12 个真进程。**

> ⚠️ **另一个教训（2026-10-15）**：我曾往 `TRIGGER_BYTE (0x0767)` 试写 `0x01 / 0x80 / 0xFF`
> （语义未知），用户当时反馈**屏幕黑了一下、又亮、又黑只剩背光，然后自行恢复**。
> 现已从 OEM 程序集查到它是功能位掩码（`WinLock=1 / LightBar=2 / FanBoost=4 / SilentMode=8 /
> USBCharger=16 / RGBKeyboard=32 / RGBLogo=64 / RGBKBWelcome=128`），
> 但**依然不写**——语义未知的寄存器，不要在真人正在用的机器上试写。

---

## 白色光谱校准（为什么白色需要单独校准）

实测：下发纯白 `(255,255,255)` 时键盘明显**偏蓝**。这不是软件 bug，而是  
**灯条硬件的白平衡偏差** —— 蓝光 LED 的效率远高于红/绿，三通道同时打满时蓝压过其余两个。  
OEM 原厂工具里也有 `ColorCalibrationResultCode`，说明厂商自己也要走校准流程。

做法与 `BetterRGB-ITE8291-Adaptive` 一致：让用户指出「纯白指令下肉眼看到的实际颜色」，  
把该颜色转到**线性光空间**，以最弱通道为基准反算三个衰减增益（只衰减、不放大，避免溢出）：

```
gain_channel = 最弱通道 / 本通道
```

增益单位是千分比，`1000` = 不衰减，本机持久化在  
`~/Library/Application Support/MacConsole/rgb_white_gain.json`，  
对所有颜色统一生效（所以色彩仍然准确，只是整体亮度随之下降）。

**本机已标定的结果**（2026-10-14，用户肉眼确认白色正常）：

```
R×1.000  G×0.545  B×0.480        # 千分比: R=1000 G=545 B=480
满白 (255,255,255) 实际下发 -> (255, 139, 122)
```

即蓝通道被压到原来的 48%、绿通道 54.5%，红通道不动。这个校准值会跟着  
`restore_rgb.sh` 一起在开机登录时自动恢复。

**界面操作**：键盘灯页面 →「白色校准」→ 先点「显示原始白」看清偏色，  
再点选最接近的偏色色块得到初值，然后拖「去蓝强度」滑条实时微调到白看起来是白。

### 滑条端点：为什么滑条能无跳变往返

早期实现把滑条位置 `t` 硬编码映射成 `gain = 1000 - k×t`（G 取 0.70、B 取 0.80）。  
问题在于「点选偏色色块」走的是 `calc_white_gains`，反算出的三通道比例**一般不在那条直线上**——  
用户标定完再碰一下滑条，G 就会从标定值瞬间跳到直线上，肉眼可见跳变。

现在滑条只在**中性白 `(1000,1000,1000)`** 和一个可变的**端点**之间线性插值：

```
gain(t) = 1000 - (1000 - end) × t / 100
```

- 默认端点 `(1000, 300, 200)`，保留原来「拉满」时的衰减量；
- 一旦做了一次色块标定，端点**就被替换成那次标定的结果**，于是标定值正好落在 `t = 100`，  
  从 100 往回拖就是「逐步减弱这次校正」，语义自然且完全可逆。

端点持久化在 `~/Library/Application Support/MacConsole/rgb_white_end.json`。  
在默认端点 `(1000,300,200)` 下，本机现有标定 `(1000,545,480)` 正好对应 `t = 65%`；  
前端读取时不需要自己换算，后端已经算好放在 `white_gain.slider` 里直接回填。

命令行/接口：

```bash
# 按观测色自动校准（同时把滑条端点设为这次结果，t=100）
curl -X POST http://127.0.0.1:8787/api/rgb/whitecal \
     -H 'Content-Type: application/json' -d '{"observed":"#96e6ff"}'
# 直接给增益（千分比）
curl -X POST http://127.0.0.1:8787/api/rgb/whitegain \
     -H 'Content-Type: application/json' -d '{"R":1000,"G":545,"B":480}'
# 或者只给滑条位置 t，由后端按端点插值（界面走的就是这条）
curl -X POST http://127.0.0.1:8787/api/rgb/whitegain \
     -H 'Content-Type: application/json' -d '{"t":65}'
# 取消校准（增益与端点一并复位）
curl -X POST http://127.0.0.1:8787/api/rgb/whitegain/reset
```

> 校准值换机器/换键盘无效，每台机器都要各自标定一次（同一型号的灯条一致性也可能有差异）。

---

## 文件说明

```
Mac控制台/
├── 启动控制台.command      双击启动
├── 停止控制台.command      双击停止
├── 安装灯效自启.command    双击安装开机自动恢复灯效
├── 卸载灯效自启.command    双击卸载开机自启
├── 安装散热控制.command    双击加载 TongfangFan.kext + 开机自动加载
├── 卸载散热控制.command    双击卸载散热控制
├── restore_rgb.sh         开机恢复脚本（由 launchd 调用，带重试）
├── server.py              本地 HTTP 服务 + 全部数据采集 + 控制动作
├── smc.py                 SMC 读取模块（ctypes → IOKit AppleSMC）
├── hid.py                 IOKit HID 封装（ctypes）
├── rgbkb.py               键盘灯协议实现 + 配置持久化
├── bright.py              屏幕亮度（ctypes → IOKit IODisplay 参数接口）
├── auxsmooth.py           亮度 CLI 兼容层（get/set=系统亮度；watch/mode 委托 auxbright v4）
├── 安装亮度守护.command    安装 auxbright v4 守护（PWM 模式保持，开机自启）
├── 卸载亮度守护.command    停掉守护并取消开机自启
├── fanctl.py              散热模式用户态客户端（ctypes → IOUserClient）
├── TongfangFan.kext       散热控制内核扩展（自编译，见上节）
├── tools/
│   ├── rgb_test.py        键盘灯协议分阶段验证（先只读）
│   └── smc_probe.py       SMC 键枚举工具
└── web/
    ├── index.html         控制台界面
    └── assets/            OEM 原版素材（89 个：按钮三态/键盘按键图/圆环/开关）
```

后端接口：`/api/all` `/api/sensors` `/api/battery` `/api/disks` `/api/processes`  
`/api/hid` `/api/rgb` `/api/capability` `/api/fan`。  
（`/api/overview` 是 `/api/all` 的轻量子集，只为兼容早期调用保留。）

写入接口：`POST /api/rgb`（成功后自动记住灯效）、`POST /api/control`、  
`POST /api/fan`（`{"mode":"boost"}` 或 `{"level":3}`，成功后记住、重启自动恢复）。  
灯效管理：`POST /api/rgb/apply`（恢复）、`POST /api/rgb/forget`（清除）、  
`POST /api/rgb/save`（直接覆盖保存）。  
白平衡：`POST /api/rgb/whitecal`、`POST /api/rgb/whitegain`、`POST /api/rgb/whitegain/reset`。

界面覆盖情况：

| 页面   | 内容                                                                         |
| ---- | -------------------------------------------------------------------------- |
| 监控   | CPU 封装温度 · **占用率** · 功耗 · 电流 + 六核温度；**独显温度（EC 0x044F 实测）** 与 **核显温度（无独立传感器，取封装温度参考）**；风扇双路转速 / 占空比；电池详情；磁盘占用 |
| 控制   | **散热模式**（自动 / 基准 / 手动 L0-7）· **性能模式**（专业 / 平衡 / 省电，写 EC `0x07AB`）· **电池充电阈值** · 音量 · 屏幕亮度 · **电源与休眠** |
| 键盘灯和海岸灯 | **海岸灯（多彩 / 应用颜色 / 关闭，EC 0x0748-0x074B）** · 单色 · **预设灯效（可自定义颜色）** · **分区配色（6 行逐行）** · 白色校准 · 协议与命令表                        |
| 能力边界 | 可用-部分-不可用矩阵 · **SMC 枚举** · **HID 设备列表**                                    |
| 其他   | 电源休眠 · 传感器封装/接近温度 · 电流功耗电压全表 · 原始读数 JSON · **实现说明**（各模块数据来源与原理，头部标注所属模块） |

> `/api/processes` 与 `/api/hid` 原先只有后端实现、界面从未调用；  
> `/api/rgb` 的 `zones` 模式同理。现已全部接到界面上。

### CPU 占用率是怎么来的

界面「监控」页的占用率走 `host_processor_info`（mach，纯 ctypes）读 CPU 时间片
累计计数，两次采样求差。不 fork `top` / `ps`——本机沙箱把这两个都禁了，
而且 `top -l 1` 自己要跑一秒多，采出来的也不是你要的那一段。
因为是求差，第一次调用会在服务端补采一次（约 120 ms）；
之后每次刷新（2 秒）返回的就是**最近 2 秒的平均占用率**，不是瞬时值。

### GPU 温度：核显和独显分别是什么数

界面上两格分别是：

| 格 | 来源 | 说明 |
| - | ---- | ---- |
| 独显 RTX 2070S | **EC `0x044F` 实测** | 12 进程满载 35 秒的实测里，CPU 从 64℃ 冲到 89℃，而 `0x044F` 只从 60℃ 动到 62℃——它不在 CPU 那一路 |
| 核显 UHD 630 | **CPU 封装温度（参考值）** | 核显与 CPU 在同一块硅片上，本机**没有它的独立热敏**：SMC 只枚举出 TC* 一串 CPU 键，没有 TG*。所以这一格是参考值，不是核显自己报的数 |

**占用率与功耗不显示**：macOS 没有开放 GPU 利用率的用户态接口。独显在 macOS 下
只有一个 PCIe 设备条目（官方驱动早已停更、始终空载），核显也不上报利用率。
宁缺毋滥，不编造数字。

### 两路风扇：为什么「GPU 更凉却转得更快」

不是接反了。12 进程满载 35 秒实测，两路 PWM（`0x1804` / `0x1809`）
**每一步数值都相同**（80 → 96/96 → 117/117 → … → 177/177），
即 EC 给两颗风扇的是**同一个占空比**。转速差约 12%
（空载 2929 vs 3348 RPM，满载 5109 vs 5557 RPM）来自风扇本身的个体差异 / 型号差异。

**两个寄存器分别对应哪颗物理风扇，2026-10-16 已由用户实物确认**：
他亲手换过 CPU 风扇，满载时新风扇的转速确实比 GPU 那侧低，
所以转速较高的 **`0x046C` = CPU 风扇**，**`0x0464` = GPU 风扇**
（代码和界面之前的标注是反的，已修正；占空比（PWM）组也一并跟着对调，
`0x1809` = CPU 侧、`0x1804` = GPU 侧，保持同组一致）。

不过既然两颗风扇拿到的占空比完全相同，这个对应关系**只影响显示是否正确，
不影响任何实际行为**。

### 硬盘温度：读不到

两块 NVMe（OV P300 1TB、SK Hynix 512G）的温度本机取不到，已排查全部来源：

- SMC 只枚举出 TC* 一串 CPU 温度键，没有 TH* / Tm* 这类硬盘键
- `ioreg` 里 `IONVMeController` / `IOBlockStorageDevice` 都不上报温度
  （全系统唯一的 `Temperature` 键是电池的 29.3℃）
- EC 页 `0x04` 整页扫描也没有像硬盘热敏的寄存器
- 常规做法靠 `smartctl`（smartmontools）：本机未安装、也没有 brew；
  且 macOS 读 NVMe SMART 通常需要管理员权限，控制台是普通用户权限

若装了 smartmontools 并愿意授权，可以再把它接进来。

### 预设灯效的自定义颜色

灯效包只有 8 字节，其中 colour 只占 1 个字节，装不下 RGB —— 这就是以前灯效
只能是白 / 彩虹的原因。现在的做法是走协议里的**命名色命令 `0x14`**：

```
14 00 <槽位 1-7> <R> <G> <B> 00 00     ← 先把颜色写进槽位
08 02 <灯效> <速度> <亮度> <槽位> ...    ← 再让 colour 字节指向该槽位
```

**这条是按协议推导的**：下发返回 `kr=0`，但设备没有可靠的回读通道
（`read_feature` 拿到的是陈旧缓冲），**颜色是否真的变了需要肉眼确认**。
想要确定生效的自定义颜色，用「分区配色」——那条是实测过的。

---

## 灯效记忆与开机自动恢复

每次在界面里应用颜色 / 灯效，配置会写入  
`~/Library/Application Support/MacConsole/rgb_profile.json`。界面「键盘灯」页右侧  
会显示当前记住的灯效，并提供 **立即恢复** / **忘记**。

想让**每次开机自动恢复**：双击 **`安装灯效自启.command`**。


它会在 `~/Library/LaunchAgents/` 写一个 launchd 任务，登录时调用 `restore_rgb.sh`，
脚本带重试（USB 设备开机初期可能尚未枚举完，最多重试 30 次 × 2 秒），
日志在 `/tmp/macconsole-rgb.log`。取消就用 `卸载灯效自启.command`。

命令行也能单独用：

```bash
/usr/bin/python3 rgbkb.py                 # 不带参数：打印键盘设备与固件信息
/usr/bin/python3 rgbkb.py profile         # 看当前保存的配置
/usr/bin/python3 rgbkb.py apply           # 恢复
/usr/bin/python3 rgbkb.py set '#ff9500' 4 # 设橙色+最亮并记住
/usr/bin/python3 rgbkb.py clear           # 清除配置
```


---

## 排错

**开机 / 睡眠唤醒后键盘灯不亮**
灯效状态存在键盘控制器里，EC 复位会清掉，所以重启后回到 BIOS 默认。
**解决办法：装 `安装灯效自启.command`**，之后每次开机自动恢复你上次设置的灯效。
临时恢复也可以在控制台点「立即恢复」，或命令行 `python3 rgbkb.py apply`。

**键盘灯在 Windows 下失效**
若在 macOS 下写入后切回 Windows 发现 Fn 键调不了灯：在 Windows 里打开一次原版
Control Center 重新应用配置即可恢复。

**端口被占用**
`MACCONSOLE_PORT=9999 启动控制台.command`，或改 `server.py` 里的 `PORT` 默认值。

**SMC 读不到**
确认 OpenCore 用的是 VirtualSMC。本机实测 122 个键、六核温度齐全。

### 海岸灯（Lightbar / 灯条）

OEM 控制中心的"海岸灯"对应 EC 寄存器组：控制字节 `0x0748` + RGB 三通道
`0x0749` / `0x074A` / `0x074B`（OEM 常量表 `ADDR_LIGHTBAR/REDBAR/GREENBAR/BLUEBAR_CONTROL_BYTE`，
字节序低字节在前，与已知的 `ADDR_MAFAN_CONTROL_BYTE=0x0751` 交叉验证）。
本机 `SUPPORT_1 (0x0765)` bit6 = 1，声称支持；OEM 侧由 `DefaultRGBLightbar.exe`
经注册表 `\OEM\GamingCenter\MyLightBar`（LightBarOnOff / RedLevel / GreenLevel / BlueLevel /
WelcomeMode / BreathingLightEffect）驱动。HID 侧的 MyLightBar 设备本机不存在，EC 是唯一通路。

实测（2026-10-16）：RGB 三通道 0x00-0xFF 可写、回读一致；控制字节 bit0/1/2/3/6/7 可写，
**bit4/5 被 EC 掩码**（写 0x10/0x20 回读 0x00）。
界面三个操作（多彩 / 应用颜色 / 关闭）**2026-10-16 经用户确认全部正常**。

**控制字节的两个取值已肉眼验证**：

| ctrl | 灯的实际行为 |
| ---- | ------ |
| `0x80` | **多彩轮换动画**（机器出厂就是这个状态） |
| `0x00` | **停在固定色**，显示 RGB 寄存器里存的颜色 |
| `0x84` | **关灯** |

也就是说：**bit7 是「轮换/动画」位，不是开关位**（清掉它灯不会灭，只是停止轮换、定在一个颜色上），
**bit2 才是真正的关灯位**。模式判定按 `bit2 → off`、`bit7 → cycle`、其余 `static` 的优先级。

界面按 OEM 控制台的形态只留三个操作：**多彩**（轮换动画）、**应用颜色**（定在选中的色上）、
**关闭**（红色危险按钮，与同页单色模块的「关闭背光」同款）。按钮高亮一律来自 EC 回读。
控制字节还有 bit0 / bit1 / bit3 / bit6 语义未知（OEM 侧另有 WelcomeMode、
BreathingLightEffect 两个灯效开关没对应上），**三个操作不依赖这些位**；后端 `/api/lightbar`
仍接受 0-255 裸值，需要时可继续摸。
每次操作都是锁内一次性写 4 字节 + 回读一次，不做轮询、不做动画，状态展示一律以 EC 回读为准。

实现位置：`fanctl.py`（`lightbar_status()` / `lightbar_set()`）、`server.py`
（`/api/lightbar` GET/POST）、`web/index.html`（键盘灯页顶部卡片）。

---

## 屏幕亮度（PWM 模式 + 原生链路，v3 2026-10-17 起）

**根因**：本机面板（BOE NV156FHM-N4J）默认处于 **eDP AUX 背光模式**
（DPCD 0x721=0x0A），**根本不看 iGPU 的 PWM 引脚**；而 macOS 亮度链路
**只会写 iGPU 的 PWM 占空比寄存器**（BXT_BLC_PWM_DUTY1）——写了等于白写。
这就是历史上「系统亮度改了屏幕不动」的真正原因（不是链路坏，是面板不在听的那条路上）。

**方案**：把面板切到 **PWM 模式**（DPCD 0x721 写 0x08，bits[1:0]=00b）之后：

| 机制 | 旧方案（v2.x，已废弃） | 现行（v3） |
|---|---|---|
| 亮度写入 | 轮询系统亮度 → 渐变 → 写 DPCD 0x723 | 写系统亮度，macOS 原生写 PWM 占空比 |
| 平滑 | 软件渐变（200ms ease） | macOS 原生渐变（硬件 PWM） |
| 位深 | 8 位（256 级，面板上限） | 16 位占空比寄存器（面板 PWM 发生器量化到 8 位） |
| 延迟 | 轮询 25ms + 渐变 | 无（原生链路实时） |
| 守护职责 | 全程同步亮度 | **只保持 PWM 模式**（睡眠唤醒后每秒校验改回） |

- 安装：双击 **`安装亮度守护.command`**（装 auxbright v4 到 ~/bin + 登录项保活；
  同时让位已废弃的 auxsmooth 守护）。
- 卸载：双击 **`卸载亮度守护.command`**（注意：下次睡眠唤醒后面板会回 AUX 模式，
  亮度调节将失效；重启控制台或重装守护可恢复）。
- 守护日志：`/tmp/auxbright.log`；`auxbright mode` 查当前模式，`auxbright pwm/aux` 手动切。
- `auxsmooth.py` 现在是**兼容层 CLI**：`get/set` 走系统亮度（IOKit），
  `watch/mode/pwm/aux` 委托 auxbright v4，`raw <0-255>` 已废弃
  （PWM 模式下 DPCD 写入被面板忽略，仅 AUX 模式兜底有意义）。
- `server.py` 的亮度端点：`brightness_get` 读系统亮度（附 `panel_mode`），
  `brightness` 写系统亮度；守护不在时补一次 `auxbright pwm` 保证写入到达屏幕。
  （**重启控制台后生效**；F1/F2 和系统滑条立即生效，不依赖控制台）。
