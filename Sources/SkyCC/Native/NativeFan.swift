//
//  NativeFan.swift
//  Sky CC —— EC 通道的用户态客户端（原生移植）
//
//  对应 Python 版 app-resources/fanctl.py。
//
//  原理：
//    EC 通道由内核扩展提供，挂在 ACPI PNP0C14（WMI）设备上，暴露
//    SkyCCECDriver（自维护，Sources/ECDriver）或 TongfangFanDriver（旧二进制）
//    IOService + UserClient。经 IOServiceGetMatchingService →
//    IOServiceOpen → IOConnectCallStructMethod(selector=0) 调用：
//        入参 12 字节: {u32 selector, u32 arg1, u32 arg2}
//        出参  8 字节: {i32 status, u32 result}
//
//  两个必须记住的坑（原样保留）：
//    1. 写风扇相关寄存器前必须让 CTRL_1(0x0741) bit0 在位（AP exist：控制中心接管），
//       否则 EC 静默拒收。这一位不是「手动门」，是控制软件在线标志（文档 §4.2）；
//    2. 不要直写 PWM(0x1804/0x1809) —— 会让 EC 停转风扇，只写 FAN_CTRL 档位。
//

import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - kext 侧 selector（与 TongfangFan.hpp 一致）

private let SEL_INFO: UInt32 = 0        // arg1 <- hasGuid
private let SEL_SET_MODE: UInt32 = 1    // arg1: 0 normal / 1 boost / 2 custom
private let SEL_SET_LEVEL: UInt32 = 2   // arg1: 0..7
private let SEL_RAW_METHOD: UInt32 = 3  // arg1: WMI methodId, arg2: data
private let SEL_EC_WRITE: UInt32 = 4    // arg1: EC 16位地址, arg2: 16位数据
private let SEL_EC_READ: UInt32 = 5     // arg1: EC 16位地址 -> result

// MARK: - EC 寄存器图（来自 Linux qc71_laptop，LAPQC71/QCCFL 家族）

/// 诊断追踪：只有显式 `-D EC_TRACE` 编译时才输出到 stderr，正式构建是空函数。
#if EC_TRACE
func trace(_ s: String) {
    FileHandle.standardError.write(("[EC] " + s + "\n").data(using: .utf8)!)
}
#else
@inline(__always) func trace(_ s: String) {}
#endif


enum EC {
    static let fanCtrl: UInt32      = 0x0751   // bit4=TURBO bit5=AUTO bit6=BOOST, 0x80+n=级别
    static let fanRPM1: UInt32      = 0x0464   // **CPU 风扇**转速（16位，大端）
    static let fanRPM2: UInt32      = 0x046C   // GPU 风扇转速
    // 【2026-11-11 用户定案，之前标反了】
    //   · 原厂口径：ADDR_EC_MAIN_FAN_RPM_BYTE1/2 = 0x464/0x465 是**主风扇（CPU）**，
    //     原厂监测页只读这一路；0x46C/0x46D 是 qc71 驱动的 FAN_RPM_2 = 第二颗（GPU），
    //     前程序才加上的扩展项。
    //   · 2026-10-16 那次"转速更高的 0x046C 才是 CPU"是拿转速高低反推的，
    //     判据本身不牢：两颗风扇型号/叶片不同，同样的占空比下转速本来就会有差异
    //     （实测两路 PWM 恒等，0x1804 = 0x1809 = 60）。
    //   · 2026-11-11 05:54 实测旁证：0x464 = 0x08D8 = 2264 RPM，0x46C = 0x0A16 = 2582 RPM，
    //     而 CPU 板温 0x043E = 53℃、GPU 板温 0x044F = 41℃ —— 转得快的是 GPU 那颗，
    //     与"同一占空比下 GPU 风扇转速偏高"一致，不构成 0x46C 是 CPU 的证据。
    //   用户实物确认（换过 CPU 风扇）：**0x464 = CPU**。
    static let fanTemp1: UInt32     = 0x043E   // CPU 附近板级温度（°C）—— 仅登记地址，2.8.15 起无读取点
    static let fanTemp2: UInt32     = 0x044F   // GPU 附近板级温度（°C）—— 仅登记地址，2.7.6 起无读取点
    static let fanPWM1: UInt32      = 0x1809   // CPU 风扇占空比（量程 0-200）—— 仅登记地址，界面不显示
    static let fanPWM2: UInt32      = 0x1804   // GPU 风扇占空比 —— 仅登记地址，界面不显示
    static let ctrl1: UInt32        = 0x0741   // bit0 = AP exist（控制中心接管标志，文档 §4.2）bit5 = 风扇异常
    static let ctrl2: UInt32        = 0x078C   // bit2-3 = TURBO_LEVEL(0-3)
    static let ctrl3: UInt32        = 0x07A5   // ApOem3：功耗档+散热档共同决定（0x88|…），基准期间 EC 自己维护
    static let fanModeIndex: UInt32 = 0x07AB   // 模式总开关 = (功耗档<<4)|散热档
    static let modeProfile1: UInt32 = 0x07B0   // 三档功耗各自的曲线索引槽（0x7B0/1/2）
    static let biosCtrl3: UInt32    = 0x07A3   // bit6 = 禁用被动散热模式（2026-10-24 三次实测双向确认）
    static let biosCtrl1: UInt32    = 0x074E   // bit4=Fn 锁状态（qc71 BIOS_CTRL_1 / fn_lock）
    // bit3 = Fn 锁**总闸**（AP 侧使能，原厂 LaunchServGM 写）：为 1 时 EC 才处理 Fn+Esc，
    // 实测 gate=0 → 按 Fn+Esc 寄存器不动；gate=1 → 按一次状态位立刻翻转（2026-11-17）。
    static let apBiosByte: UInt32   = 0x07A4
    static let ctrl4: UInt32        = 0x07A6   // bit1=超频动态温控关闭 bit6=触控板关闭（qc71 CTRL_4）
    static let battCharge: UInt32   = 0x07B9   // 0=不限制；否则 0x80|百分比（实测 0xD0=80、0xBC=60）
    static let pl1: UInt32          = 0x0783   // PL1，单位 W（实测 0x41=65W）
    static let pl2: UInt32          = 0x0784   // PL2，单位 W（实测 0x64=100W）
    static let lightbarCtrl: UInt32 = 0x0748   // bit0/1/2/3/6/7 可写，bit4/5 被 EC 掩码
    static let lightbarRed: UInt32  = 0x0749
    static let lightbarGreen: UInt32 = 0x074A
    static let lightbarBlue: UInt32 = 0x074B
    static let pl4: UInt32          = 0x0785

    // ── 原厂「系统功耗设置 / 散热设置」联动表用到的地址（包内 EcMap 为准）──
    static let fanGpuSetting: UInt32 = 0x078B  // 随功耗档：高性能 1 / 平衡 1 / 节能 2
    static let fanCurveL1: UInt32    = 0x0743 // MYFAN2 五段 PWM 起始
    static let fanMinSpeed: UInt32   = 0x079E
    static let fanMinTemp: UInt32    = 0x079F
    static let fanExtraSpeed: UInt32 = 0x07A0

    // 三套功耗预设的出厂默认值区（先读再套，换机型也能用）
    static let gamingPl1Default: UInt32 = 0x0730
    static let gamingPl2Default: UInt32 = 0x0731
    static let gamingPl4Default: UInt32 = 0x0732
    static let officePl1Default: UInt32 = 0x0734
    static let officePl2Default: UInt32 = 0x0735
    static let officePl4Default: UInt32 = 0x0736
    static let saverPl1Default: UInt32  = 0x07A7
    static let saverPl2Default: UInt32  = 0x07A8
    static let saverPl4Default: UInt32  = 0x07A9

    /// `0x7B0/1/2` = 三档功耗各自的曲线索引槽，槽位 N = 功耗档 N。
    /// 写错槽位会让「切回该档」时风扇曲线用的还是旧档位。
    static func fanCurveProfile(_ power: Int) -> UInt32 {
        modeProfile1 + UInt32(max(1, min(3, power)) - 1)
    }

    /// 一次性触发位 `0x767`：写哪一位 EC 就执行对应动作（**toggle 语义**，先读状态再写）。
    static let triggerByte: UInt32   = 0x0767
    static let statusByte: UInt32    = 0x0768
    static let silentModeStatus: UInt32 = 0x045B   // 0=关 1=开（安静模式实际状态）
    static let keyboardBacklightState: UInt32 = 0x07C4  // bit6：键盘背光开（原厂服务写）
    static let support1: UInt32     = 0x0765   // bit7 = 支持 FAN_BOOST
    static let support2: UInt32     = 0x0766   // bit0 = 支持静音模式（本机不支持）
    static let support5: UInt32     = 0x0742   // bit4 = FAN_TURBO, bit5 = FAN
    static let projID: UInt32       = 0x0740   // 项目 ID，本机 = 8

    // 海岸灯控制字节（位定义见 qc71_laptop ec.h：
    //   LIGHTBAR_CTRL_ADDR 0x0748，BIT(1)=POWER_SAVE，BIT(2)=S0_OFF，
    //   BIT(3)=S3_OFF，BIT(7)=RAINBOW）
    //
    // 原厂位定义（移植文档 §4.6 / qc71_laptop ec.h 一致）：
    //   bit0 = AP exist（MyLightBar.SetApExist，启动置 1、退出清 0）
    //   bit1 = POWER_SAVE（qc71 定义，原厂文档未列，本机恒 0，不碰）
    //   bit2 = S0_OFF  灯带关（1 = 关）
    //   bit3 = S3_OFF  呼吸展示关（1 = 睡眠不展示）
    //   bit7 = RAINBOW 多彩动画（1 = 开）
    // 四个位各自是独立语义，**必须读改写**，不能用常量整字节覆盖
    // （用 0x84 关灯会把 bit3 一起清成 0，等于顺手把「睡眠展示」打开）。
    static let lightbarAPPresent: UInt8 = 0x01
    static let lightbarS0Off: UInt8     = 0x04
    static let lightbarS3Off: UInt8     = 0x08
    static let lightbarRainbow: UInt8   = 0x80
    static let lightbarWritableMask: UInt8 = 0xCF

    // 2.7.6：RGB 三个通道**只接受 10 档**（0/4/8/…/36），不是 0-255。
    // 依据 qc71_laptop led_lightbar.c 的 lightbar_color_values 表与反向表
    // lightbar_pwm_to_level[256]（只有 0,4,…,36 这 10 个下标有映射）。
    // 之前 UI 直接把 0-255 写进去，固件把越界值当无效 → 灯直接灭，
    // 这正是「选完固定色灯就没了」的根因。
    static let lightbarLevels: [UInt8] = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36]
    static let lightbarLevelMax: UInt8 = 36

    // 位定义
    static let fanCtrlLevelMask: UInt8 = 0x07
    static let fanCtrlTurbo: UInt8 = 0x10
    static let fanCtrlAuto: UInt8 = 0x20
    static let fanCtrlBoost: UInt8 = 0x40
    static let fanCtrlAutoMode: UInt8 = 0xA0  // 0x80 | AUTO —— 交回 EC 自动调度

    /// `0x741` bit0 的正身（文档 §4.2）：**AP exist 心跳 —— 控制软件在线标志**。
    /// 控制台打开即置 1、运行期续期、退出清 0。EC 只在这位置起时才接受整片
    /// 风扇/灯带寄存器写入，所以它看起来像「手动门」，实际是「有控制中心接管」。
    static let ctrl1APPresent: UInt8 = 0x01
    /// 历史命名，语义同上（旧调用点仍在用，避免大面积改名引入风险）。
    static let ctrl1ManualMode: UInt8 = ctrl1APPresent
    static let ctrl3FanQuiet: UInt8 = 0x04
    static let ctrl3Overboost: UInt8 = 0x10
    static let ctrl3HighPwr: UInt8 = 0x80

    static let ctrl2TurboLevelMask: UInt8 = 0x0C  // bit2-3
    static let battChargeMask: UInt8 = 0x7F
    static let battChargeReached: UInt8 = 0x80

    /// `0x0726` bit3 = **接电自动开机**（内核 `EC_ADDR_OEM_9` / `AC_AUTO_BOOT_ENABLE`）。
    /// `1` = 断电恢复供电或插上适配器即自动上电；`0` = 必须按电源键。
    /// 【2026-11-17 实测】本机 `0x0726 = 0x00`（关闭），其余 7 位两份开源源码里都没有定义、
    /// 含义未知 —— 因此**只能读-改-写这一个 bit，绝不能整字节写**，否则会抹掉未知位。
    static let acPowerCtrl: UInt32 = 0x0726
    static let acAutoBootBit: UInt8 = 0x08

    // 键盘 / 触控板 / 风扇行为位（qc71_laptop 交叉验证 2026-10-21，均读-改-写）
    static let biosCtrl1FnLock: UInt8 = 0x10          // 0x074E bit4 = BIOS 层 Fn 锁状态（Fn+Esc 翻它）
    /// 0x07A4 bit3。上游叫 `AP_BIOS_BYTE_FN_LOCK_SWITCH`，是 **AP 侧 Fn 锁使能位**：
    /// 2026-11-17 实测，它必须与 0x074E bit4 一起为 1，F 区映射才会真的变成媒体模式。
    /// 只写 0x074E → 几秒内被 EC 退回 0x00，无效果；
    /// 只写本一位 → 按键映射不动。两个一起写 → 生效且稳定。
    static let fnLockSwitch: UInt8 = 0x08
    static let ctrl4OverboostDynTempOff: UInt8 = 0x02 // 0x07A6 bit1（1=关闭动态温控）
    static let ctrl4TouchpadToggleOff: UInt8 = 0x40   // 0x07A6 bit6（1=禁用触控板）
    static let biosCtrl3ReducedDuty: UInt8 = 0x20     // 0x07A3 bit5（含义未经包内确认，实验位）
    /// 0x07A3 bit6：1 = 「禁用被动散热模式」已勾选。
    /// 【2026-10-24 00:33 / 00:38 / 00:49 三次实测双向确认】
    ///   早先的注释写成「风扇常转」是错的 —— 包内 `EcMap.BiosOem3PassiveBit` 定案为禁用被动散热。
    static let biosOem3PassiveBit: UInt8 = 0x40
    /// `0x7A5` bit4 = OverBoost（文档 §4.4）。基准模式置 1、切档强制清 0、退出清零。
    /// 【2026-11-11 更正】旧注释写「EC 自己算的镜像，我们不写」是错的：文档 §3.3
    /// 的开启链明确要求写这一位；此前失败是因为整字节写成了 0x99（多带 bit3），
    /// 正确值是 (cur & 0x60) | 0x91。
    static let apOem3BenchmarkBit: UInt8 = 0x10
    static let statusByteBoostBit: UInt8 = 0x04       // 0x0768 bit2 = 增压（基准模式期间为 1）
    static let statusByteWinLock: UInt8 = 0x01        // 0x0768 bit0 = Win 键锁定
    static let keyboardBacklightBit: UInt8 = 0x40     // 0x07C4 bit6

    // 0x0767 触发位（一次性动作，toggle 语义）
    static let triggerWinLock: UInt8      = 0x01
    static let triggerLightBar: UInt8     = 0x02
    static let triggerFanBoost: UInt8     = 0x04
    static let triggerSilentMode: UInt8   = 0x08
    static let triggerUsbCharger: UInt8   = 0x10
    static let triggerRgbKeyboard: UInt8  = 0x20

    // ── 原厂联动表的编码函数（包内 EcMap.ApOem3For / FanControlFor）──

    /// `0x7A5` 由功耗档与散热档共同决定。四组实测反推：
    ///   高性能+性能 0x89 / 平衡+标准 0x88 / 节能+安静 0x8E / 节能+性能 0x8A
    /// 即 `0x88 | (高性能?0x01) | (节能?0x02) | (安静?0x04)`，平衡与标准不贡献位。
    static func apOem3For(power: Int, thermal: Int, benchmark: Bool = false) -> UInt8 {
        var v: UInt8 = 0x88
        if power == 1 { v |= 0x01 } else if power == 3 { v |= 0x02 }
        if thermal == 3 { v |= 0x04 }
        if benchmark { v |= apOem3BenchmarkBit }
        return v
    }

    /// `0x751` 只跟散热档走：性能 0x00，标准 / 安静 0xA0。
    static func fanControlFor(_ thermal: Int) -> UInt8 { thermal == 1 ? 0x00 : 0xA0 }
}

// 服务类名，按顺序找第一个能用的：
//   SkyCCECDriver    —— 自己维护的 kext（Sources/ECDriver，源码可改）
//   TongfangFanDriver—— 旧二进制 kext（只有产物、无源码，升级过渡期兜底）
// 两者对外 ABI 完全一致（IOConnectCallStructMethod selector 0，12 进 8 出），
// 所以切换不需要改任何调用点。
private let serviceClasses = ["SkyCCECDriver", "TongfangFanDriver"]
private let kextID = "com.skycc.TongfangFan"

// MARK: - 客户端

struct FanReply {
    var status: Int32 = 0
    var result: UInt32 = 0
    /// 多步写入的逐步结果（排障用，例如 "pl1=1 pl2=1 ... 7AB=1"）
    var steps: String = ""

    var ok: Bool { status == 0 }
    var dict: [String: Any] {
        var d: [String: Any] = ["status": Int(status), "result": result]
        if !steps.isEmpty { d["steps"] = steps }
        return d
    }
}

/// EC 邮箱是全局单例资源：重叠访问会返回 kIOReturnIOError，所有事务必须串行化。
final class FanControl {
    static let shared = FanControl()

    // === 连接管理（2026-10-21 v2.5.3.1 重写，修 EC 并发挂死）===
    //
    // 旧实现每次 EC 事务都 IOServiceOpen/Close 开一条新连接。app 内多个线程
    //（MonitorStore 每秒轮询 / FanCurveController 2s 轮询 / HTTP handler）并发
    // 开连接打 WMI 方法，kext 侧多连接并发会搅乱 EC 邮箱：
    //   轻则 kIOReturnIOError 撞车（旧代码持锁 usleep 退避，最坏累计 2.9s，
    //        把 1s 的轮询拖成 5-7s —— 2.5.2 装机版实测）；
    //   重则某线程 IOConnectCallStructMethod 永不返回（kext 对异常忙的 EC
    //        无超时），持锁线程挂死 → 全局 EC 功能停摆（2.5.3 装机版实测：
    //        /api/fan 30s 无响应，而 /api/overview 正常、mcutil 独立进程正常）。
    //
    // 新实现三条：
    //   1) 进程内共用一个长连接（io_connect_t）——IOKit 对同一 connect 的并发
    //      调用由内核串行化，kext 只见一个客户端的串行请求流，从根上消除
    //      多连接竞态；
    //   2) 看门狗——每次 WMI 调用包 1.5s 超时（IOConnectCallStructMethod
    //      本身无超时参数，用 semaphore + DispatchWorkItem 实现）。超时即
    //      作废连接下次重开，绝不持锁水竖；
    //   3) 退避不持锁——IOError 重试的 sleep 从事务锁外做。
    //
    // bizLock：串行化「写事务」（读-改-写组必须原子，如 modifyBit / lightbarSet）；
    // 读组（fanStatus / miscStatus / ecProbe）不持锁——长连接下每个物理调用
    // 已串行，读组整体一致性无意义（1 秒后就过期），持锁只会放大看门狗超时
    // 的影响面（旧实现读组持锁 9 次调用，最坏要 13.5s）。
    private let stateLock = NSLock()          // 保护 conn/svc（临界区只赋值，无 IO）
    private var conn: io_connect_t = 0
    private var svc: io_service_t = 0
    private let bizLock = NSRecursiveLock()
    private let retries = 6
    private let retryDelay: UInt32 = 60_000   // 0.06s（微秒）

    // MARK: - 底层

    private struct Msg {
        var selector: UInt32 = 0
        var arg1: UInt32 = 0
        var arg2: UInt32 = 0
    }

    /// 找服务：按 `serviceClasses` 顺序，优先取「真 WMBC 通道」实例。
    ///
    /// 实例挑选（2026-11-18 修转速读全 0xFF 后明确）：一个类下通常有两个实例，
    /// 对应两个 ACPI EC 设备：
    ///   * 父设备 **AMW0**（或 WMIGuid 前缀 ABBC0F6F，其他机型）= WMBC 真通道；
    ///   * 父设备 **OTA0** = OTA 口，**读回来全 0xFF、写入无效**（ecprobe 实测
    ///     0x0751 都回 0xFF），绝对不能用。
    /// 本机（LAPQC71）驱动条目上没有 WMIGuid 属性（在父 ACPI 设备上也没有 guid，
    /// 只能靠父设备名区分），所以「挑对实例」的判据是：父设备名 AMW0 优先、
    /// OTA0 永远垫底，其余情况按出现顺序兜底。
    private func findService() -> io_service_t? {
        for cls in serviceClasses {
            if let s = findService(classNamed: cls) { return s }
        }
        trace("findService: 所有服务类名都没找到（\(serviceClasses.joined(separator: " / "))）")
        return nil
    }

    private func findService(classNamed cls: String) -> io_service_t? {
        guard let matching = IOServiceMatching(cls) else {
            trace("findService: IOServiceMatching(\(cls)) nil")
            return nil
        }
        var iter: io_iterator_t = 0
        // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会找不到服务
        let mkr = IOServiceGetMatchingServices(0, matching, &iter)
        guard mkr == KERN_SUCCESS, iter != 0 else {
            trace("findService: matchingServices kr=0x\(String(mkr, radix: 16)) iter=\(iter)")
            return nil
        }
        defer { IOObjectRelease(iter) }

        // 三档候选：amw（真通道）> 普通 > ota（废口，读全 0xFF 写无效）
        var amw: io_service_t = 0
        var normal: io_service_t = 0
        var ota: io_service_t = 0
        while true {
            let svc = IOIteratorNext(iter)
            if svc == 0 { break }
            // 真 WMBC 通道两种形态：TongFang 机型 WMIGuid 前缀 ABBC0F6F；
            // 本机（LAPQC71）无 WMIGuid 属性，靠父设备名 AMW0 判定。
            if serviceIsABBC(svc) || parentKind(svc) == .amw {
                if amw != 0 { IOObjectRelease(amw) }
                amw = svc
            } else if parentKind(svc) == .ota {
                if ota == 0 { ota = svc } else { IOObjectRelease(svc) }
            } else {
                if normal == 0 { normal = svc } else { IOObjectRelease(svc) }
            }
        }
        for (keep, drop) in [(amw, normal), (amw, ota), (normal, ota)] {
            if keep != 0 && drop != 0 { IOObjectRelease(drop) }
        }
        if amw != 0 { return amw }
        if normal != 0 { return normal }
        return ota != 0 ? ota : nil
    }

    /// 实例的父 ACPI 设备种类（见 findService 注释）
    private enum PortKind { case amw, ota, other }

    private func parentKind(_ svc: io_service_t) -> PortKind {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return .other
        }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return .other }
        switch String(cString: name).uppercased() {
        case "AMW0": return .amw      // WMBC 真通道
        case "OTA0": return .ota      // OTA 口：读全 0xFF、写无效
        default: return .other
        }
    }

    private func serviceIsABBC(_ svc: io_service_t) -> Bool {
        guard let key = "WMIGuid" as CFString? else { return false }
        guard let unmanaged = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0) else {
            return false
        }
        // takeRetainedValue 后由 ARC 接管，不需要手动 CFRelease
        guard let str = unmanaged.takeRetainedValue() as? String else { return false }
        return str.hasPrefix("ABBC0F6F")
    }

    /// kext 是否已加载（不打开连接）
    ///
    /// 任一服务类名能匹配到实例就算已加载——旧 kext 与新的并存时也算，
    /// 因为 EC 通道本身可用就是「已加载」的实质含义。
    static func kextLoaded() -> Bool {
        for cls in serviceClasses {
            guard let matching = IOServiceMatching(cls) else { continue }
            // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会找不到服务
            let svc = IOServiceGetMatchingService(0, matching)
            if svc != 0 {
                IOObjectRelease(svc)
                return true
            }
        }
        return false
    }

    /// 懒打开/重开长连接（调用方持 stateLock；IOServiceOpen 历史从未挂过，放临界区内）
    private func ensureConn() -> io_connect_t? {
        if conn != 0 { return conn }
        guard let s = findService() else {
            trace("ensureConn: findService nil")
            return nil
        }
        var c: io_connect_t = 0
        let okr = IOServiceOpen(s, mach_task_self_, 0, &c)
        guard okr == KERN_SUCCESS else {
            trace("ensureConn: IOServiceOpen kr=0x\(String(okr, radix: 16))")
            IOObjectRelease(s)
            return nil
        }
        svc = s          // 保续 service 引用（长连接存活期间不 release）
        conn = c
        trace("ensureConn: opened conn=\(c)")
        return c
    }

    /// 作废连接：置 0 让下次 ensureConn 重开。
    /// 故意不调 IOObjectClose——对可能还挂着 outstanding 调用的连接 close
    /// 有同样阻塞风险；宁可泄漏一个 user-client（看门狗事件极罕见，重启回收）。
    private func invalidateConn() {
        conn = 0
    }

    /// 作废当前 user client 连接，下一次调用自动重开（2.8.12）。
    ///
    /// 用途：kext 被重新加载（kmutil load / 重装 TongfangFan.kext）或睡眠唤醒后，
    /// 旧连接上的 IOConnectCallStructMethod 不会报错，而是**读到全 0**——
    /// 实测表现就是「写 0x7AB 不落地、回读 back=0x00」，界面报「调不了散热模式」。
    /// 重开一次连接即恢复，不需要重启 app/helper。
    func resetConnection() {
        stateLock.lock()
        invalidateConn()
        svc = 0
        ecQueue = DispatchQueue(label: "skycc.ec.mailbox", qos: .userInitiated)
        stateLock.unlock()
    }

    /// 串行 EC 通道：所有物理调用排进同一条串行 queue。
    /// 长连接≠串行——IOKit 不保证同一 connect 的并发调用顺序，kext 侧同时
    /// 进来的多个请求照样搅乱 EC 邮箱（实测），必须用户态自己串行化。
    /// 看门狗断路时整体替换（旧 queue 里挂死的 block 随之遗弃）。
    private var ecQueue: DispatchQueue =
        DispatchQueue(label: "skycc.ec.mailbox", qos: .userInitiated)

    /// 带看门狗的调用：排入串行 queue + 1.5s 超时。超时即「断路」——
    /// 作废连接并更换 queue（旧 queue 中可能仍挂着挂死的 block，
    /// 随旧 queue 遗弃；新 queue + 新连接继续服务，不拖死任何等待方）。
    private func guardedCall(_ selector: UInt32, _ arg1: UInt32, _ arg2: UInt32) -> FanReply? {
        stateLock.lock()
        let q = ecQueue
        let c = ensureConn()
        stateLock.unlock()
        guard let c else { return nil }

        let sem = DispatchSemaphore(value: 0)
        var boxed: FanReply?
        q.async {
            boxed = self.ioCall(c, selector, arg1, arg2)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 1.5) == .success else {
            trace("guardedCall: queue 阻塞超 1.5s，作废连接")
            stateLock.lock()
            invalidateConn()
            ecQueue = DispatchQueue(label: "skycc.ec.mailbox", qos: .userInitiated)
            stateLock.unlock()
            return FanReply(status: Int32(kIOReturnTimeout), result: 0)
        }
        if let b = boxed, b.status != 0 {
            trace("guardedCall: sel=\(selector) arg1=0x\(String(arg1, radix: 16)) status=\(b.status)")
        }
        return boxed
    }

    /// 裸 WMI 调用（只在串行 queue 内执行，天然无并发）
    ///
    /// 【2.8.13 致命 bug 修复】以前这里是：
    ///   `var reply = FanReply(); IOConnectCallStructMethod(..., &reply, &size)`
    /// 而 `FanReply` 里带一个 **Swift String `steps`**（16 字节，内含对象指针）。
    /// kext 侧的返回结构是纯 C 布局（只有 status/result），它写回的 24 字节里
    /// 后 16 字节是无意义内容，正好覆盖掉 String 的内部表示 → 结构体被踩坏。
    /// 实测症状极具迷惑性：ioCall 内部打印 status=0、result 正常，函数却 `return nil`，
    /// 于是每个 EC 调用都被判成"失败"，散热/功耗/基准/海岸灯集体失效，
    /// 而 kext 和 EC 硬件完全正常。
    /// 现在改成原始字节缓冲接收、手工解析 status/result/steps，不再让 kext 碰 Swift 对象。
    private func ioCall(_ c: io_connect_t, _ selector: UInt32, _ arg1: UInt32, _ arg2: UInt32) -> FanReply? {
        var msg = Msg(selector: selector, arg1: arg1, arg2: arg2)
        var buf = [UInt8](repeating: 0, count: 512)
        var outSize = buf.count
        let kr = withUnsafeMutablePointer(to: &msg) { mp in
            buf.withUnsafeMutableBytes { bp in
                IOConnectCallStructMethod(
                    c, 0,
                    UnsafeRawPointer(mp), MemoryLayout<Msg>.size,
                    bp.baseAddress!, &outSize)
            }
        }
        if kr != KERN_SUCCESS {
            trace("ioCall: sel=\(selector) kr=0x\(String(kr, radix: 16))")
            // 连接级错误（kext 卸载/睡眠唤醒/权限变化）：作废，下次自动重开
            if kr == kIOReturnNoDevice || kr == kIOReturnNotPermitted || kr == kIOReturnOffline {
                stateLock.lock()
                if conn == c { invalidateConn() }
                stateLock.unlock()
            }
            return FanReply(status: Int32(kr), result: 0)
        }
        // kext 不一定会回写 outSize；只要至少回满 8 字节（status+result）就算有内容
        let avail = min(max(outSize, 0), buf.count)
        guard avail >= 8 else {
            return FanReply(status: Int32(kIOReturnUnderrun), result: 0)
        }
        let status = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let result = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        var reply = FanReply(status: status, result: result)
        // steps 在 kext 侧是 C 字符数组；没有就以 NUL 起头，解析出来是空串
        if avail > 8 {
            let payload = buf[8..<avail]
            if let z = payload.firstIndex(of: 0) {
                reply.steps = String(decoding: payload[payload.startIndex..<z], as: UTF8.self)
            } else {
                reply.steps = String(decoding: payload, as: UTF8.self)
            }
        }
        return reply
    }

    /// EC 忙自动重试（不持任何锁：IOError 退避 sleep 在锁外，超时/其他错误不重试）
    private func call(_ selector: UInt32, _ arg1: UInt32 = 0, _ arg2: UInt32 = 0) -> FanReply? {
        var reply: FanReply?
        for attempt in 0..<retries {
            reply = guardedCall(selector, arg1, arg2)
            guard let r = reply else { return nil }      // kext 未加载
            if r.ok { return r }
            // 只有 EC 忙(IOError)才重试；看门狗超时/其他错误直接返回
            if r.status != Int32(kIOReturnIOError) { return r }
            usleep(retryDelay * UInt32(attempt + 1))
        }
        return reply
    }

    // MARK: - 高层接口

    func info() -> FanReply? { call(SEL_INFO) }

    /// 交还风扇调度权：**先放档位、再确认接管标志在位**（不清 bit0）。
    ///
    /// 【2.8.14 用户要求】手动档位退出、温控曲线退出都必须调它。
    /// 以前 `setLevel()` 只管置位不管收尾，用完手动档或曲线之后 0x751 停在 0x8n，
    /// 界面就一直显示「自定义档」，散热档 / 功耗档点了没反应。
    ///
    /// 【2026-11-11 更正】这不是「关手动门」。`0x741` bit0 是 AP exist
    /// （控制中心接管标志，文档 §4.2），常驻为 1，**不清零** —— 清了键盘灯 10 分钟
    /// 就会灭。这里只把 `0x751` 放回 0x00 交还 EC 自动调度。
    ///
    /// 【顺序不能反】先放档位 `0x751←0x00`（此时接管标志在位，才写得进），
    /// 再写回 `0x741`。反过来在 `0x751` 还挂着 `0x40` / `0x8n` 时清标志，
    /// EC 会置 FAN_ABNORMAL（bit5），之后**整片风扇寄存器拒写，只能重启**。
    /// 放档位这一步失败就保留原样、不动标志（风扇响着总比写不进去好）。
    ///
    /// - Returns: `status == 0` 表示已交还（含本来就不在位的情况）。
    @discardableResult
    func releaseManualDoor() -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        let c1 = readByte(EC.ctrl1)
        // 接管标志不在位：0x751 写了也会被拒，直接返回
        guard (c1 & EC.ctrl1APPresent) != 0 else { return FanReply(status: 0, result: UInt32(c1)) }
        // 已经 FAN_ABNORMAL 了：任何写入都会被拒，别再加一笔
        guard (c1 & 0x20) == 0 else { return FanReply(status: -3, result: UInt32(c1)) }
        // ① 放档位（接管标志在位才写得进）
        let released = ecWriteVerified(EC.fanCtrl, 0x00)?.ok ?? false
        guard released else {
            return FanReply(status: -1, result: UInt32(readByte(EC.fanCtrl)))
        }
        // ② 写回接管标志：EC 收回风扇管辖权 → 自己按 0x7AB 重算 0x751。
        //    写的是 0x01（bit0 保留）。实测这种状态 EC 照样按 0x7AB 调风扇（满载会爬速）。
        let r = ecWriteVerified(EC.ctrl1, doorIdleValue)
        return r ?? FanReply(status: -1, result: UInt32(readByte(EC.ctrl1)))
    }

    func setMode(_ mode: String) -> FanReply? {
        guard ["normal", "boost", "custom"].contains(mode) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        switch mode {
        case "normal":
            // 「交还 EC」的**正确**做法：先放档位，EC 自己按 0x7AB 重算 0x751 / 0x7A5。
            // 包内定案：「关闭：写 0x00 → EC 立刻收回管辖权，0x751 自动回落到 0x7AB 对应的值」。
            // 2.8.14：改为调用 releaseManualDoor()——以前这里第一笔就是 `0x741←0x00`，
            // 若此时 0x751 还挂着 0x40 / 0x8n，正好踩中「顺序反了 → FAN_ABNORMAL → 整片拒写」的坑。
            // 注意：它**不清** 0x741 bit0（AP exist 常驻），只把 0x751 交还。
            let r = releaseManualDoor()
            // 个别情况下 EC 收权后不会立刻重算 0x751，这里做一次
            // 「断言接管 → 改正 → 再交还」的兜底（交还同样走安全顺序）。
            let t = thermalLevel()
            if (1...3).contains(t) {
                let want = EC.fanControlFor(t)
                let cur = readByte(EC.fanCtrl)
                if cur != want {
                    if (ecWriteVerified(EC.ctrl1, readByte(EC.ctrl1) | EC.ctrl1APPresent)?.ok ?? false) {
                        writeIfDifferent(EC.fanCtrl, want)
                        writeIfDifferent(EC.ctrl3, EC.apOem3For(power: powerLevel(), thermal: t))
                    }
                    _ = releaseManualDoor()
                }
            }
            return r
        case "boost":
            // 基准模式：文档 §3.3 完整开链，见 setBenchmarkMode(_:)。
            return setBenchmarkMode(true)
        default:
            _ = ecWriteVerified(EC.ctrl1, readByte(EC.ctrl1) | EC.ctrl1APPresent)
            return ecWriteVerified(EC.fanCtrl, 0x80)
        }
    }

    // MARK: - 原厂「散热模式」与「系统功耗设置」（包内 FanService / PowerService 为准）
    //
    // 【关键：散热档存在 0x7AB 的低半字节，不是 0x751】
    //   0x7AB = (功耗档 << 4) | 散热档，功耗档 1/2/3，散热档 1/2/3
    //   0x11 = 高性能+性能，0x22 = 平衡+标准，0x33 = 节能+安静
    // 单独切散热档时只有低半字节变化（0x12 → 0x11），高半字节不动。
    // 早先用 0x751 判断模式会误判：三档里 EC 都把 0x751 写成 0xA0，
    // 而 0xA0 在 OEM 枚举里叫 User_HiMode，于是界面显示成「自定义」。

    /// 散热档（0x7AB 低半字节）：1 性能 / 2 标准 / 3 安静。0 表示不认识（自定义）。
    func thermalLevel() -> Int { Int(readByte(EC.fanModeIndex) & 0x0F) }

    /// 功耗档（0x7AB 高半字节）：1 高性能 / 2 平衡 / 3 节能。
    func powerLevel() -> Int { Int((readByte(EC.fanModeIndex) >> 4) & 0x0F) }

    /// 基准模式是否开启。判据 = **`0x751 == 0x40`（风扇全速档）**。
    ///
    /// 文档 §3.3：基准模式是 FanView 的 `m_BenchmarkMode` 软件态，EC 侧唯一可靠投影
    /// 就是 `0x751=0x40`（§4.5：0x40=全速 Boost，只有基准模式会出现）。文档里
    /// 基准模式与 `0x741` bit0 **无关** —— bit0 是「控制中心接管」标志，软件开着
    /// 就恒为 1，拿它参与判据等于恒真。
    ///
    /// 【2026-11-11 更正】上一版用「bit0 + 0x751==0x40」双条件，是把 bit0 误当
    /// 手动门留下的历史包袱；按文档口径还原为只看档位。
    func benchmarkMode() -> Bool {
        readByte(EC.fanCtrl) == EC.fanCtrlBoost
    }

    /// 风扇异常位（`0x741` bit5）。置起后整片风扇寄存器拒写，只能重启恢复。
    func fanAbnormal() -> Bool { (readByte(EC.ctrl1) & 0x20) != 0 }

    // MARK: - AP exist / 控制中心接管（键盘灯 10 分钟熄灯的解药）

    /// `0x741` bit0 = **AP exist：控制软件在线标志**（文档 §4.2）。
    ///
    /// 语义定案（2026-11-11，用户口径 + 文档 + 实测三方一致）：
    ///   · 控制台**打开就下发**（原厂 `AppAction.StartTimer_APExistToEC`：置 0x741 bit0=1，
    ///     之后 60s 续期；退出时清 0）。它宣告的是「有控制中心在管这台机器」。
    ///   · macOS 侧从来没有任何程序写过它，EC 认为无人接管 —— 于是 ITE 8291 键盘固件
    ///     按自己的空闲策略在 **10 分 40 秒**后掐灯（期间每分钟重发整套行数据帧也救不回来）。
    ///   · 置位常驻后同样不碰键盘，**13 分钟**灯仍然全亮，亮度字节一次都没被清零
    ///     （`ctrl=2 eff=51 bri=38` 全程不变）。
    ///
    /// 【为什么可以常驻】同一次实验里位开着跑 60 秒 CPU 满载：转速 2619 → 4286 RPM
    /// 自己爬上去了、`0x751` 保持 `0x00`，说明 EC 自动控风不受这一位影响
    /// —— 它只管「软件有没有接管」，不是风扇手动门。
    static let apPresentKey = "mcAPPresentHold"

    /// 开关（默认开）。关闭后回到旧行为：只在风扇写事务期间短暂置位。
    static var apPresentHold: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: apPresentKey) == nil { return true }
            return d.bool(forKey: apPresentKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: apPresentKey) }
    }

    /// 断言「控制中心在线」：把 `0x741` bit0 置 1，其余位原样保留。
    ///
    /// 与文档一致：打开软件下发一次，运行期由 helper 的守夜复查（被清才补写）。
    /// 已在位就**一笔都不写**（EC 写次数是稀缺资源，这一位是持久状态）。
    /// `FAN_ABNORMAL`（bit5）置起时整片风扇寄存器拒写，直接返回 -3 不硬来。
    @discardableResult
    func assertAPPresent() -> FanReply? {
        guard FanControl.apPresentHold else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        let c1 = readByte(EC.ctrl1)
        guard (c1 & 0x20) == 0 else { return FanReply(status: -3, result: UInt32(c1)) }
        guard (c1 & EC.ctrl1APPresent) == 0 else { return FanReply(status: 0, result: UInt32(c1)) }
        return ecWriteVerified(EC.ctrl1, c1 | EC.ctrl1APPresent)
    }

    /// 显式设置「控制中心在线」标志 —— 灯效页「AP 心跳」开关走这里（2026-11-13）。
    ///
    /// 与 `assertAPPresent()` 的分工：那个只负责「置 1」（守夜补写），这个双向可写，
    /// 并且**同步 `apPresentHold`** —— 关掉之后 60 秒守夜不会再把它顶回 1，
    /// 风扇事务交还时的 `doorIdleValue` 也跟着变成 `0x00`（真的没人接管）。
    ///
    /// 副作用要讲清楚：这一位是 ITE 8291 判断「有没有控制中心」的依据，清掉之后
    /// 键盘背光回到固件的 **10 分 40 秒空闲熄灯**策略；同时 EC 会拒收风扇档位写入
    /// （`0x751` 写了也当没看见），直到重新置 1。
    @discardableResult
    func setAPPresent(_ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        let c1 = readByte(EC.ctrl1)
        // FAN_ABNORMAL（bit5）期间整片风扇寄存器拒写，硬写只会多一笔无效流量
        guard (c1 & 0x20) == 0 else { return FanReply(status: -3, result: UInt32(c1)) }
        // 先落开关再写 EC：万一写失败，守夜也不会按旧值把用户的选择翻回去
        FanControl.apPresentHold = on
        let target = on ? (c1 | EC.ctrl1APPresent) : (c1 & ~EC.ctrl1APPresent)
        guard target != c1 else { return FanReply(status: 0, result: UInt32(c1)) }
        return ecWriteVerified(EC.ctrl1, target)
    }

    /// 退出控制台流程：**无条件**清 `0x741` bit0，不看 `apPresentHold`。
    ///
    /// 与 `setAPPresent(false)` 的区别：那个会改用户偏好（下次开 app 也不置 1），
    /// 这个只清硬件状态 —— 用户开着心跳正常用，退出时按原厂语义交还硬件，
    /// 下次启动 `ECAPPresentKeeper` 再按偏好决定要不要重新立起来。
    @discardableResult
    func clearAPPresentOnExit() -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        let c1 = readByte(EC.ctrl1)
        guard (c1 & EC.ctrl1APPresent) != 0 else { return FanReply(status: 0, result: UInt32(c1)) }
        return ecWriteVerified(EC.ctrl1, c1 & ~EC.ctrl1APPresent)
    }

    /// 「AP 心跳」的真实状态：直接读 `0x741`，不查缓存也不查偏好。
    /// 界面要显示的是「EC 现在认不认有控制中心」，不是「用户上次选了啥」——
    /// 两者会分叉（比如守夜被 FAN_ABNORMAL 挡住没能补写）。
    func appPresentState() -> (on: Bool, raw: UInt8) {
        let c1 = readByte(EC.ctrl1)
        return ((c1 & EC.ctrl1APPresent) != 0, c1)
    }

    /// Fn 锁实时状态（只读 2 字节，约 130 ms）。
    ///
    /// 为什么单独开这个方法：`/api/fan` 的 `misc` 走的是**长 TTL 缓存**
    /// （`fanState` 非 fresh 路径「不主动读 EC」），而 Fn+Esc 是硬件事件、
    /// 不会让缓存失效 —— 用户按完快捷键功能明明变了，misc 里的 `fn_lock`
    /// 还是上一次的值，设置页的开关就纹丝不动（2026-11-17 用户报告）。
    /// 本方法每次调用都现读，专供 UI 做 1–2 秒轮询。
    ///
    /// 语义（实测 2026-11-17）：
    /// · `0x07A4` bit3 = 总闸，为 0 时 EC 完全不处理 Fn+Esc；
    /// · `0x074E` bit4 = 状态，硬件键翻的只有这一位。
    func fnLockState() -> [String: Any] {
        let gate = (readByte(EC.apBiosByte) & EC.fnLockSwitch) != 0
        let raw = readByte(EC.biosCtrl1)
        return [
            "ok": true,
            "available": true,
            "fn_lock": (raw & EC.biosCtrl1FnLock) != 0 && gate,
            "fn_lock_switch": gate,
            "raw_74e": Int(raw),
        ]
    }

    /// 交还风扇调度权时的目标值：接管标志保持在线，写 `0x01`；只有用户显式关掉
    /// `apPresentHold` 才真的写 `0x00`（会连带 10 分钟熄灯回来）。
    private var doorIdleValue: UInt8 {
        FanControl.apPresentHold ? EC.ctrl1APPresent : 0x00
    }

    /// 启动对账用：`0x751` 停在**手动定速档**（0x80..0x87）。
    ///
    /// 【2026-11-11 更正】旧版靠「bit0 开着但 0x751≠0x40」判断残留门，是把 bit0
    /// 当手动门的历史包袱。bit0 现在是常驻的接管标志，永远为 1，不能作判据。
    /// 真正需要善后的只有「上次停在手动定速、进程被强杀」这一种：
    /// 0x751 还是 0x8n，交给 releaseManualDoor() 放回 0x00 即可（不动 bit0）。
    func staleDoorOpen() -> Bool {
        let f = readByte(EC.fanCtrl)
        guard (0x80...0x87).contains(f) else { return false }
        guard (readByte(EC.ctrl1) & 0x20) == 0 else { return false }
        // 有正常的档位索引（0x11/0x22/0x33 …）却停在手动定速 → 上次没善后的残留
        let idx = readByte(EC.fanModeIndex)
        return idx >= 0x11 && (idx & 0x0F) <= 3
    }

    /// 切换散热档（写**四个**寄存器，包内 `FanService.SetMode` 同款序列）：
    ///   · `0x751` 按散热档：性能 0x00 / 标准·安静 0xA0
    ///   · `0x7A5` 功耗档 + 散热档共同决定
    ///   · `0x7AB` 低半字节 = 散热档本体（EC 把整字节当「整组设置应用完毕」的收尾信号）
    ///   · `0x7B{功耗档-1}` 该功耗档自己的曲线索引槽
    /// 功耗档（高半字节）保持不变，原厂也不改它。
    ///
    /// 基准模式下直接拒绝：此时 0x751=0x40（全速）由基准覆盖态维持，
    /// 放行会把 0x751 打回 0x00/0xA0 —— 增压没了但基准开关还勾着，
    /// 必须取消再勾才恢复（原厂 UI 此时也整组置灰）。
    func setThermalLevel(_ level: Int) -> FanReply? {
        guard (1...3).contains(level) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        if benchmarkMode() {
            return FanReply(status: -2, result: 0)   // -2 = 基准模式进行中，拒绝
        }
        var power = powerLevel()
        if !(1...3).contains(power) { power = 1 }
        let updated = UInt8((power << 4) | level)
        let s1 = writeIfDifferent(EC.fanCtrl, EC.fanControlFor(level))
        let s2 = writeIfDifferent(EC.ctrl3, EC.apOem3For(power: power, thermal: level))
        let s3 = ecWriteVerified(EC.fanModeIndex, updated)?.ok ?? false
        let s4 = ecWriteVerified(EC.fanCurveProfile(power), updated)?.ok ?? false
        let back = readByte(EC.fanModeIndex)
        // 2.8.11：**以 0x7AB 是否真的落地为唯一判据**。
        // 2.8.13（用户要求「不要设置多余的 EC 写入」）：
        //   删掉了 2.8.12 加的「未落地就 resetConnection() + 整组重写一遍」。
        //   那一版失败时会再写一整组，把 EC 写入量翻倍、还制造未完成事务；
        //   而且它是在掩盖真 bug（ioCall 返回值被踩坏），并非连接陈旧。
        //   现在失败只回排障串，不再补写；0x741 也只在真失败时才读（省一笔读）。
        let landed = back == updated
        let abnormal = landed ? false : fanAbnormal()
        let steps = "751=\(s1 ? 1 : 0) 7A5=\(s2 ? 1 : 0) 7AB=\(s3 ? 1 : 0) IDX=\(s4 ? 1 : 0)"
            + " back=0x\(String(format: "%02X", back))"
        // -3：FAN_ABNORMAL（0x741 bit5）置起 —— 整片风扇寄存器拒写，只能重启/断电复位
        return FanReply(status: landed ? 0 : (abnormal ? -3 : -1),
                        result: UInt32(back), steps: steps)
    }

    /// 基准模式快照（文档 §3.3 开启链第一步：快照 当前 PL/dstate/0x751/0x7A5/0x7A6/0x7AB）。
    private struct BenchSnapshot {
        var pl1: UInt8 = 0
        var pl2: UInt8 = 0
        var gpu: UInt8 = 0
        var fanCtrl: UInt8 = 0
        var ctrl3: UInt8 = 0        // 0x7A5
        var ctrl4: UInt8 = 0        // 0x7A6
        var index: UInt8 = 0        // 0x7AB
        var valid = false
    }
    private static var benchSnapshot = BenchSnapshot()

    /// 读-改-写：只改 `mask` 覆盖的位，其余位原样保留。
    private func rmwWrite(_ addr: UInt32, _ mask: UInt8, _ value: UInt8) -> Bool {
        guard let r = ecRead(addr), r.ok else { return false }
        let cur = UInt8(r.result & 0xFF)
        let next = (cur & ~mask) | (value & mask)
        if next == cur { return true }
        return ecWriteVerified(addr, next)?.ok ?? false
    }

    /// 基准模式的 `0x7A5` 前两步（文档 §3.3 / §4.4）：bit7 PowerHigh=1 → bit4 OverBoost=1。
    /// 第三步（低 2 位 LED=01、清 bit2/bit3）要等 DynamicTemp 之后单独写，顺序按文档。
    /// 最终整字节 = `(cur & 0x60) | 0x91`。
    ///
    /// 【2026-11-11 更正】旧版一次写整字节 `0x99`（多带 bit3「用户高转速表」），
    /// 这正是当时「写完 0x7A5 后 0x751←0x40 被打回」的原因；文档值是 0x91。
    private func writeBenchmarkCtrl3Power() -> Bool {
        guard rmwWrite(EC.ctrl3, EC.ctrl3HighPwr, EC.ctrl3HighPwr) else { return false }
        return rmwWrite(EC.ctrl3, EC.ctrl3Overboost, EC.ctrl3Overboost)
    }

    /// 启用 / 关闭基准模式（文档 §3.3，与全量手册 line 73 的原厂链一致）。
    ///
    /// 开：快照 → Gaming PL(0x730/731→0x783/784) → dstate=1 → 0x7A5 bit7=1
    ///     → OverBoost=1 → DynamicTemp=1(0x7A6 bit1 清) → LED=01 → 0x7AB=0x11
    ///     → 0x751=0x40 →（高性能电源计划：macOS 无对应通道）
    /// 关：0x751 先放 0x00 → 快照整字节恢复 → 按快照 0x7AB 重放 SetPowerMode+SetFanMode。
    ///
    /// 【安全线】`0x7A5` 写不进就**不再写 0x751**，直接回滚 —— 顺序反了会让 EC
    /// 置 FAN_ABNORMAL(bit5)，之后整片风扇寄存器拒写，只能重启。
    /// `0x741` bit0 是「控制中心接管」标志，全程保持在线，这里只断言、不清零。
    func setBenchmarkMode(_ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        return on ? beginBenchmark() : endBenchmark()
    }

    private func beginBenchmark() -> FanReply? {
        var steps: [String] = []
        // 0. 快照（已在基准中就不覆盖，避免把基准态当原态存下来）
        if !benchmarkMode() || !FanControl.benchSnapshot.valid {
            FanControl.benchSnapshot = BenchSnapshot(
                pl1: readByte(EC.pl1), pl2: readByte(EC.pl2),
                gpu: readByte(EC.fanGpuSetting), fanCtrl: readByte(EC.fanCtrl),
                ctrl3: readByte(EC.ctrl3), ctrl4: readByte(EC.ctrl4),
                index: readByte(EC.fanModeIndex), valid: true)
            steps.append("snap=0x\(String(format: "%02X", FanControl.benchSnapshot.ctrl3))")
        }
        // ① 接管标志在位，否则后面整片写入都会被静默拒收
        let c1 = readByte(EC.ctrl1)
        if (c1 & EC.ctrl1APPresent) == 0 {
            _ = ecWriteVerified(EC.ctrl1, c1 | EC.ctrl1APPresent)
            steps.append("AP=1")
        }
        // ② Gaming PL
        let gpl1 = Self.plDefault(EC.gamingPl1Default, 65)
        let gpl2 = Self.plDefault(EC.gamingPl2Default, 100)
        let p1 = ecWriteVerified(EC.pl1, gpl1)?.ok ?? false
        let p2 = ecWriteVerified(EC.pl2, gpl2)?.ok ?? false
        steps.append("PL=\(p1 ? 1 : 0)\(p2 ? 1 : 0)(\(gpl1)/\(gpl2))")
        // ③ dstate 低 3 位 = 1
        let g = rmwWrite(EC.fanGpuSetting, 0x07, 0x01)
        steps.append("dstate=\(g ? 1 : 0)")
        // ④⑤ 0x7A5 PowerHigh=1、OverBoost=1
        let c3 = writeBenchmarkCtrl3Power()
        // ⑥ DynamicTemp 开（0x7A6 bit1 反逻辑清 0）
        let dt = modifyBit(EC.ctrl4, EC.ctrl4OverboostDynTempOff, false)?.ok ?? false
        // ⑦ 电源 LED 低 2 位=01（清 bit2/bit3）
        let led = c3 ? rmwWrite(EC.ctrl3, 0x0F, 0x01) : false
        steps.append("7A5=\(c3 && led ? 1 : 0) dyn=\(dt ? 1 : 0)")
        guard c3, led else {
            // 0x7A5 没落地 → 绝不写 0x751，回滚快照
            _ = restoreBenchSnapshot()
            steps.append("abort:7A5")
            return FanReply(status: -1, result: UInt32(readByte(EC.ctrl3)),
                            steps: steps.joined(separator: " "))
        }
        // ⑦ 模式索引 0x11（高 4 位功耗 1 / 低 4 位风扇 1）
        let i = ecWriteVerified(EC.fanModeIndex, 0x11)?.ok ?? false
        steps.append("7AB=\(i ? 1 : 0)")
        // ⑧ 风扇全速
        let f = ecWriteVerified(EC.fanCtrl, EC.fanCtrlBoost)?.ok ?? false
        steps.append("751=\(f ? 1 : 0)")
        let ok = i && f && benchmarkMode()
        if !ok { _ = restoreBenchSnapshot() }
        // ⑨ 高性能电源计划：macOS 无等价物（系统「节能」面板无 API 可编程切换）
        return FanReply(status: ok ? 0 : -1, result: UInt32(readByte(EC.fanCtrl)),
                        steps: steps.joined(separator: " "))
    }

    private func endBenchmark() -> FanReply? {
        guard benchmarkMode() || FanControl.benchSnapshot.valid else {
            return FanReply(status: 0, result: 0)
        }
        var steps: [String] = []
        // ① 先放全速档（接管标志仍在线，才写得进）
        let first = ecWriteVerified(EC.fanCtrl, 0x00)?.ok ?? false
        steps.append("751=\(first ? 1 : 0)")
        // ② 快照整字节恢复
        let snap = FanControl.benchSnapshot
        if snap.valid {
            let ok = restoreBenchSnapshot()
            steps.append("restore=\(ok ? 1 : 0)")
        }
        // ③ 重放 SetPowerMode + SetFanMode 全链（文档 §3.3「关」第二步）
        let idx = snap.valid ? snap.index : readByte(EC.fanModeIndex)
        let power = Int((idx >> 4) & 0x0F)
        let thermal = Int(idx & 0x0F)
        var replay = true
        if (1...3).contains(power), (1...3).contains(thermal) {
            replay = applyPowerPreset(power, thermalLevel: thermal)?.ok ?? false
            steps.append("replay=\(power)/\(thermal):\(replay ? 1 : 0)")
        }
        FanControl.benchSnapshot.valid = false
        let ok = first && replay
        return FanReply(status: ok ? 0 : -1, result: UInt32(readByte(EC.fanModeIndex)),
                        steps: steps.joined(separator: " "))
    }

    /// 把快照里的字节原样写回（0x751 除外 —— 调用点自己按安全顺序处理）。
    @discardableResult
    private func restoreBenchSnapshot() -> Bool {
        let s = FanControl.benchSnapshot
        guard s.valid else { return false }
        var ok = true
        ok = (ecWriteVerified(EC.ctrl3, s.ctrl3)?.ok ?? false) && ok
        ok = (ecWriteVerified(EC.ctrl4, s.ctrl4)?.ok ?? false) && ok
        ok = rmwWrite(EC.fanGpuSetting, 0x07, s.gpu & 0x07) && ok
        ok = (ecWriteVerified(EC.pl1, s.pl1)?.ok ?? false) && ok
        ok = (ecWriteVerified(EC.pl2, s.pl2)?.ok ?? false) && ok
        ok = (ecWriteVerified(EC.fanModeIndex, s.index)?.ok ?? false) && ok
        return ok
    }

    /// 原厂「系统功耗设置」的一档联动参数。
    struct PowerLink {
        let cciIndex: UInt8     // 0x11 / 0x22 / 0x33
        let apOem3: UInt8       // 0x7A5
        let apOem4: UInt8       // 0x7A6
        let gpuSetting: UInt8   // 0x78B
        let fanControl: UInt8   // 0x751
        let pl1Default: UInt32
        let pl2Default: UInt32
        let pl4Default: UInt32
        /// 兜底瓦数（EC 默认值区读不出合理数时才用）
        let fallback: (pl1: UInt8, pl2: UInt8, pl4: UInt8)
    }

    static let powerLinks: [Int: PowerLink] = [
        1: PowerLink(cciIndex: 0x11, apOem3: 0x89, apOem4: 0x00, gpuSetting: 0x01,
                     fanControl: 0x00, pl1Default: EC.gamingPl1Default,
                     pl2Default: EC.gamingPl2Default, pl4Default: EC.gamingPl4Default,
                     fallback: (65, 100, 0)),
        2: PowerLink(cciIndex: 0x22, apOem3: 0x88, apOem4: 0x02, gpuSetting: 0x01,
                     fanControl: 0xA0, pl1Default: EC.officePl1Default,
                     pl2Default: EC.officePl2Default, pl4Default: EC.officePl4Default,
                     fallback: (45, 65, 0)),
        3: PowerLink(cciIndex: 0x33, apOem3: 0x8E, apOem4: 0x02, gpuSetting: 0x02,
                     fanControl: 0xA0, pl1Default: EC.saverPl1Default,
                     pl2Default: EC.saverPl2Default, pl4Default: EC.saverPl4Default,
                     fallback: (35, 60, 0)),
    ]

    /// 套用「系统功耗设置」的一档。原厂点这一档是**功耗 + 散热两组一起写**：
    ///
    ///   功耗侧：`0x783` PL1、`0x784` PL2、`0x78B` FanGpuSetting、`0x7A6` ApOem4
    ///   散热侧：`0x751` FanControl、`0x7A5` ApOem3、`0x7AB` 档位索引、`0x7B{功耗档-1}` 曲线槽
    ///
    /// 写序很重要：先 PL、再散热附属位、最后写 `0x7AB` + 该档曲线槽收尾 ——
    /// EC 把档位索引当成「整组设置应用完毕」的信号。
    ///
    /// 基准模式是顶层覆盖态，此时原厂把「系统功耗设置」整组置灰，这里直接拒绝
    /// （否则会把 0x751 从 0x40 打回，增压失效但门还开着）。
    ///
    /// - Parameters:
    ///   - power: 1 高性能 / 2 平衡 / 3 节能
    ///   - thermalLevel: 要写的散热档 1/2/3；0 = 用该功耗档的默认值（即散热档=功耗档）。
    ///     原厂每个功耗档配的散热档单独保存，所以必须能单独指定。
    func applyPowerPreset(_ power: Int, thermalLevel: Int = 0) -> FanReply? {
        guard let link = FanControl.powerLinks[power] else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        if benchmarkMode() { return FanReply(status: -2, result: 0) }

        let pl1 = Self.plDefault(link.pl1Default, link.fallback.pl1)
        let pl2 = Self.plDefault(link.pl2Default, link.fallback.pl2)
        let thermal = (1...3).contains(thermalLevel) ? thermalLevel : Int(link.cciIndex & 0x0F)

        let p1 = ecWriteVerified(EC.pl1, pl1)?.ok ?? false
        let p2 = ecWriteVerified(EC.pl2, pl2)?.ok ?? false
        // PL4：包内三处调用全部是 writePl4: false —— 原厂实测**从不写 PL4**，
        // 所以这里也绝不碰（要手动改功率走 setPl4）。

        // 这两个只跟功耗档走，单独切散热档时不动
        let g1 = writeIfDifferent(EC.fanGpuSetting, link.gpuSetting)
        let g2 = writeIfDifferent(EC.ctrl4, link.apOem4)

        // 散热部分（功耗档一变，散热档跟着走 —— 原厂逻辑）
        let t1 = writeIfDifferent(EC.fanCtrl, EC.fanControlFor(thermal))
        let t2 = writeIfDifferent(EC.ctrl3, EC.apOem3For(power: power, thermal: thermal))

        // 档位索引最后写，EC 把它当成「整组设置应用完毕」的收尾信号
        let index = UInt8((power << 4) | thermal)
        let i1 = ecWriteVerified(EC.fanModeIndex, index)?.ok ?? false
        let i2 = ecWriteVerified(EC.fanCurveProfile(power), index)?.ok ?? false
        let back = readByte(EC.fanModeIndex)
        // 2.8.13：同 setThermalLevel —— 删掉「未落地就重开连接 + 整组重写」，
        // 失败只回排障串。写入序列与包内 PowerService.ApplyPreset 完全一致。
        let landed = back == index
        let abnormal = landed ? false : fanAbnormal()
        let steps = "PL=\(p1 ? 1 : 0)\(p2 ? 1 : 0) GPU=\(g1 ? 1 : 0) A4=\(g2 ? 1 : 0) "
            + "751=\(t1 ? 1 : 0) 7A5=\(t2 ? 1 : 0) 7AB=\(i1 ? 1 : 0) IDX=\(i2 ? 1 : 0)"
            + " back=0x\(String(format: "%02X", back))"
        return FanReply(status: landed ? 0 : (abnormal ? -3 : -1),
                        result: UInt32(back), steps: steps)
    }

    /// 读 EC 默认值区的瓦数；读不出合理值（0 或 >200）才用兜底。
    private static func plDefault(_ addr: UInt32, _ fallback: UInt8) -> UInt8 {
        let v = UInt8((FanControl.shared.ecRead(addr)?.result ?? 0) & 0xFF)
        return (v > 0 && v <= 200) ? v : fallback
    }

    func setPl1(_ watts: UInt8) -> FanReply? { ecWriteVerified(EC.pl1, watts) }
    func setPl2(_ watts: UInt8) -> FanReply? { ecWriteVerified(EC.pl2, watts) }
    func setPl4(_ watts: UInt8) -> FanReply? { ecWriteVerified(EC.pl4, watts) }


    /// 手动档位 0-7（实测占空比 24% → 53%，转速 2328 → 4278 RPM）
    /// ⚠️ 非原厂功能：本机能力位没有「用户档」，原厂 UI 也没有手动模式入口。
    /// 保留是因为实测 EC 认 0x80+n，但写成 0x80|n 会让 0x7AB 与 0x751 不一致，
    /// 退出时要靠 setMode("normal") 把 0x751 拉回 0xA0。
    func setLevel(_ level: Int) -> FanReply? {
        guard (0...7).contains(level) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        // 断言接管标志（读改写，保留 bit3 OnKey 等其它位），再写手动定速档
        _ = ecWriteVerified(EC.ctrl1, readByte(EC.ctrl1) | EC.ctrl1APPresent)
        return ecWriteVerified(EC.fanCtrl, UInt8(0x80 | UInt8(level)))
    }

    /// 按占空比百分比 0-100 选档（EC 不接受直写 PWM）
    func setPWM(_ percent: Int) -> FanReply? {
        let pct = max(0, min(100, percent))
        if pct >= 70 { return setMode("boost") }
        let level = min(7, Int((Double(pct) / 53.0 * 7).rounded()))
        return setLevel(level)
    }

    /// 旧 CTRL_3 直写路径（2026-10-15 实测走不通，保留仅供对照）
    func setProfile(_ profile: String) -> FanReply? {
        guard let cur = ecRead(EC.ctrl3) else { return nil }
        guard cur.ok else { return cur }
        var v = UInt8(cur.result & 0xFF)
        switch profile {
        case "quiet":  v = (v | EC.ctrl3FanQuiet) & ~EC.ctrl3Overboost
        case "balance": v = v & ~EC.ctrl3FanQuiet & ~EC.ctrl3Overboost
        case "perf":   v = (v | EC.ctrl3Overboost) & ~EC.ctrl3FanQuiet
        default: return nil
        }
        return ecWrite(EC.ctrl3, v)
    }

    /// 性能模式的正确入口：写 MyFanCCI_Mode_Index(0x07AB)
    /// 这条老路径只写索引、不动 0x751/0x7A5，EC 可能不重算散热档；
    /// 新代码请走 `applyPowerPreset(_:thermalLevel:)`。
    func setModeIndex(_ code: UInt32) -> FanReply? {
        guard [0x11, 0x22, 0x33].contains(code) else { return nil }
        return ecWriteVerified(EC.fanModeIndex, UInt8(code & 0xFF))
    }

    /// 透传 WMI 方法（调试用）
    func raw(_ methodID: UInt32, _ data: UInt32) -> FanReply? {
        call(SEL_RAW_METHOD, methodID, data)
    }

    /// CPU 性能档 0-3（CTRL_2 bit2-3）。实测本机写得进但无可观测效果，保留备用。
    ///
    /// ⚠️ 这是**唯一**故意用裸 `ecWrite` 的路径：没有调用方，纯排障备用。
    /// 走 `ecWriteVerified` 会在无用的开关门上多打 4 轮 EC 流量，不划算。
    func setTurbo(_ level: Int) -> FanReply? {
        guard (0...3).contains(level) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        let prev = UInt8((ecRead(EC.ctrl1)?.result ?? 0) & 0xFF)
        _ = ecWrite(EC.ctrl1, prev | EC.ctrl1APPresent)
        let cur = UInt8((ecRead(EC.ctrl2)?.result ?? 0) & 0xFF)
        let v = (cur & ~EC.ctrl2TurboLevelMask) | UInt8(level << 2)
        let r = ecWrite(EC.ctrl2, v)
        if prev & EC.ctrl1APPresent == 0 {
            // 还原：保留 bit0（AP exist / 控制中心接管），只把其余位写回去
            _ = ecWrite(EC.ctrl1, FanControl.apPresentHold ? (prev | EC.ctrl1APPresent) : prev)
        }
        return r
    }

    func turboLevel() -> Int? {
        guard let r = ecRead(EC.ctrl2), r.ok else { return nil }
        return Int(((r.result & 0xFF) >> 2) & 3)
    }

    /// 电池充电上限（包内 `PowerService.SetChargeLimit`，2026-10-23 两次实测定案）：
    ///   `值 = 0x80 | 百分比`，bit7 是「限制启用」，低 7 位是百分比；
    ///   `0x00` = 不限制（对应界面上的 100%）。
    ///   早先按「直接存百分比」理解是错的 —— 写 80 会被 EC 当成别的含义。
    func setChargeThreshold(_ pct: Int) -> FanReply? {
        let percent = max(50, min(100, pct))
        let value: UInt8 = percent >= 100 ? 0x00 : (0x80 | UInt8(percent))
        bizLock.lock()
        defer { bizLock.unlock() }
        return ecWriteVerified(EC.battCharge, value)
    }

    /// 读电池充电阈值：返回 (百分比, 是否已到达)
    /// 原始字节低 7 位为 0 表示「不限制」，界面上还原成 100%。
    func chargeThreshold() -> [String: Any]? {
        guard let r = ecRead(EC.battCharge), r.ok else { return nil }
        let v = UInt8(r.result & 0xFF)
        let raw = Int(v & EC.battChargeMask)
        return ["percent": raw == 0 ? 100 : raw,
                "raw": Int(v),
                "reached": (v & EC.battChargeReached) != 0]
    }

    // MARK: - 键盘 Fn 锁 / 触控板 / 风扇行为（qc71_laptop 交叉验证，2026-10-21）
    //
    // 全部是「读-改-写」：只动目标位，不踩掉同一寄存器里的其他位
    // （qc71 驱动的 SET_BIT 同款序列；这几位 qc71 都有 sysfs 读写属性，
    //  官方控制台同路径，语义可直接采信）。

    /// 读-改-写单个位（内部自持锁，可重入）。走 WriteVerified —— EC 会丢首写。
    /// `0x7A3 / 0x7A4 / 0x7A5 / 0x7A6 / 0x741` 这一片位很密，整字节覆盖会把别的位一起清掉。
    private func modifyBit(_ addr: UInt32, _ mask: UInt8, _ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        // 2026-10-26：读失败就绝不写。
        // 原来写的是 `ecRead(addr)?.result ?? 0`，读不到时 cur 会退化成 0，
        // 接着按整字节写下去 —— 同字节里别的位会被一起清掉。
        // 0x07C4 就是典型：bit7/bit3/bit1/bit0 归别的功能（0x8B = bit7|bit3|bit1|bit0），
        // 一旦在 kext 未连接时写进去，键盘背光那一位虽然对了，别的状态全被抹平。
        guard let r = ecRead(addr), r.ok else { return nil }
        let cur = UInt8(r.result & 0xFF)
        var v = cur
        if on { v |= mask } else { v &= ~mask }
        if v == cur {
            // 已经是目标状态：不重复写（避免把 toggle 语义的寄存器翻反）
            return FanReply(status: 0, result: UInt32(cur))
        }
        return ecWriteVerified(addr, v)
    }

    /// 原厂「系统调整」页 + 键盘/触控板/风扇行为 一次快照（UI 回读用）
    /// 读组不持 bizLock（长连接下物理调用已串行；持锁会放大看门狗超时影响面）
    func miscStatus() -> [String: Any] {
        func byte(_ a: UInt32) -> UInt8 {
            UInt8((ecRead(a)?.result ?? 0) & 0xFF)
        }
        let b1 = byte(EC.biosCtrl1)      // 0x074E
        let ac = byte(EC.acPowerCtrl)    // 0x0726
        let ab = byte(EC.apBiosByte)     // 0x07A4
        let c4 = byte(EC.ctrl4)          // 0x07A6
        let b3 = byte(EC.biosCtrl3)      // 0x07A3
        let kb = byte(EC.keyboardBacklightState)  // 0x07C4
        let st = byte(EC.statusByte)     // 0x0768
        let sm = byte(EC.silentModeStatus) // 0x045B
        return [
            // Fn 锁：状态位 0x074E bit4，**总闸** 0x07A4 bit3 必须同时为 1 才算生效
            // （2026-11-17 实测：gate=0 时 Fn+Esc 完全无效）。UI 真值取两者之与：
            // 总闸没立起来时即使 EC 里状态位是 1，按键映射也不会变。
            "fn_lock": (b1 & EC.biosCtrl1FnLock) != 0 && (ab & EC.fnLockSwitch) != 0,
            // 诊断用：单看 0x07A4 bit3（Fn 锁总闸 / AP 侧使能）
            "fn_lock_switch": (ab & EC.fnLockSwitch) != 0,
            "keyboard_backlight": (kb & EC.keyboardBacklightBit) != 0,
            "win_lock": (st & EC.statusByteWinLock) != 0,
            // 接电自动开机（0x0726 bit3），纯 EC 位，无状态影子寄存器
            "ac_auto_boot": (ac & EC.acAutoBootBit) != 0,
            "silent_mode": sm == 1,
            "benchmark": benchmarkMode(),
            // 2.7.7：touchpad_off 只是 EC 那一位的回读（诊断用），在本机是无效位，
            // UI 不能拿它当开关状态，否则拨了没反应还会自己弹回去。
            //
            // 触控板真实开关状态 **不在这里报**（2026-11-17 修正）：
            // 本方法由 helper 进程生成快照，而 HID open 需要「输入监控」（helper 没有），
            // 在 helper 里 `TrackpadLock.locked` 永远回落到 false → UI 每秒被这个假值
            // 打回「已启用」，表现为「关了又自己弹回开」。真值改由 app 进程读
            // `/api/touchpad`（NativeTrackpadLock.status()）。
            "touchpad_off": (c4 & EC.ctrl4TouchpadToggleOff) != 0,
            "overboost_dyn_temp_off": (c4 & EC.ctrl4OverboostDynTempOff) != 0,
            "fan_reduced_duty": (b3 & EC.biosCtrl3ReducedDuty) != 0,
            // 2.7.10：改名。0x7A3 bit6 是「禁用被动散热模式」，不是「风扇常转」。
            "passive_cooling_disabled": (b3 & EC.biosOem3PassiveBit) != 0,
        ]
    }

    /// Fn 锁（0x074E bit4 + 0x07A4 bit3）。
    ///
    /// 【2026-11-17 实测重定位 · 两位语义不同】
    /// · `0x07A4 bit3` = **功能总闸**（AP 侧使能）：只有它为 1，EC 才承认 Fn+Esc 这颗硬件键。
    ///   实测 gate=0 时连按 6 次 Fn+Esc，0x074E 一秒都没动；
    ///   gate=1 时按 1 次 Fn+Esc，0x074E 立刻 0x10 → 0x00，gate 自己不动。
    /// · `0x074E bit4` = **当前状态**（1 = F 区直接出媒体功能）。
    ///
    /// 所以这里 **总闸常开、只切状态位** —— 旧版两位同关会把 Fn+Esc 变成死键，
    /// 表现就是「开关能用，但键盘 Fn+Esc 失效、开关也不跟着动」。
    /// 单独置 gate=1 不改当前 F 区映射（早前实测：只写 0x07A4 → 按键映射不动）。
    func setFnLock(_ on: Bool) -> FanReply? {
        guard let r0 = modifyBit(EC.apBiosByte, EC.fnLockSwitch, true) else { return nil }
        guard let r1 = modifyBit(EC.biosCtrl1, EC.biosCtrl1FnLock, on) else { return r0 }
        return r1
    }

    /// 只把 Fn 锁总闸（0x07A4 bit3）立起来，不动状态位。
    /// helper 启动时调用一次：让登录后 Fn+Esc 就能用，不必先进 app 拨一次开关。
    /// 已在位就零写入。
    func ensureFnLockGate() -> FanReply? {
        guard let cur = ecRead(EC.apBiosByte) else { return nil }
        if (UInt8(cur.result & 0xFF) & EC.fnLockSwitch) != 0 {
            return FanReply(status: 0, result: cur.result)
        }
        return modifyBit(EC.apBiosByte, EC.fnLockSwitch, true)
    }

    /// 接电自动开机（`0x0726` bit3，内核 `AC_AUTO_BOOT_ENABLE`）。
    /// 用途：断电恢复 / 来电即自启，适合当台式机或远程主机用。
    /// 本机其余 7 位未知，所以走 `modifyBit`（读-改-写单 bit）。
    func setAcAutoBoot(_ on: Bool) -> FanReply? {
        modifyBit(EC.acPowerCtrl, EC.acAutoBootBit, on)
    }

    /// 键盘背光状态位（0x07C4 bit6）。原厂由服务写；关背光还要同时把灯效亮度归零，
    /// 否则只改这一位，灯还亮着（Windows 侧实测：TurnOff 关的是「灯效」）。
    func setKeyboardBacklightState(_ on: Bool) -> FanReply? {
        modifyBit(EC.keyboardBacklightState, EC.keyboardBacklightBit, on)
    }

    /// 禁用被动散热模式（0x7A3 bit6，包内 2026-10-24 三次实测双向确认）。
    /// 是**持久设置**（BIOS setup checkbox），不是一次性动作，也不需要触发字节。
    func setPassiveCooling(disabled: Bool) -> FanReply? {
        // 包内 PowerView：基准模式进行中「禁用被动散热模式」被一起锁定
        // （基准序列正占着 0x7A3/0x751，此时改 bit6 会被固件改回）
        if benchmarkMode() { return FanReply(status: -2, result: 0) }
        return modifyBit(EC.biosCtrl3, EC.biosOem3PassiveBit, disabled)
    }

    /// 触控板（0x07A6 bit6，1=禁用）
    func setTouchpad(enabled: Bool) -> FanReply? {
        modifyBit(EC.ctrl4, EC.ctrl4TouchpadToggleOff, !enabled)
    }

    /// 超频动态温控（0x07A6 bit1，1=关闭）
    func setOverboostDynTemp(enabled: Bool) -> FanReply? {
        modifyBit(EC.ctrl4, EC.ctrl4OverboostDynTempOff, !enabled)
    }

    /// 风扇降低占空比（0x07A3 bit5）：更安静。
    /// ⚠️ 包内未定案这一位（原厂仅注册表 `EnableFanDutyCycleReduction`），实验项。
    func setFanReducedDuty(_ on: Bool) -> FanReply? {
        modifyBit(EC.biosCtrl3, EC.biosCtrl3ReducedDuty, on)
    }

    // MARK: - 触发位开关（0x767 → 0x768 / 0x45B 回读）
    //
    // 【三个必须记住的坑】
    //   ① `0x767` 是 **toggle** 语义：每成功写一次就翻转一次，写 0x00 不起作用。
    //      所以调用前必须先确认当前状态，绝不能无条件写 —— 否则会把状态翻反。
    //   ② 状态位翻转要 **约 600ms** 才跟上，早期固定睡 150ms 回读必然读到旧值，
    //      于是明明锁上了却报「EC 未响应触发位」。这里改成轮询最多 1.5 秒。
    //   ③ USB 充电没有可靠的状态回读地址（0x768 没有对应位），只能写触发位、
    //      不做验证 —— 别把它当「已生效」的保证。

    /// Win 键锁定状态（0x768 bit0）
    func winKeyLocked() -> Bool { (readByte(EC.statusByte) & EC.statusByteWinLock) != 0 }

    func setWinKeyLock(_ locked: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        if winKeyLocked() == locked {
            return FanReply(status: 0, result: UInt32(locked ? 1 : 0))
        }
        _ = ecWriteVerified(EC.triggerByte, EC.triggerWinLock)
        for _ in 0..<30 {
            usleep(50_000)
            if winKeyLocked() == locked {
                return FanReply(status: 0, result: UInt32(locked ? 1 : 0))
            }
        }
        return FanReply(status: -1, result: UInt32(winKeyLocked() ? 1 : 0))
    }

    /// 安静模式状态（0x45B：0 关 1 开）
    func silentModeOn() -> Bool { readByte(EC.silentModeStatus) == 1 }

    func setSilentMode(_ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        if silentModeOn() == on { return FanReply(status: 0, result: UInt32(on ? 1 : 0)) }
        _ = ecWriteVerified(EC.triggerByte, EC.triggerSilentMode)
        for _ in 0..<24 {
            usleep(50_000)
            if silentModeOn() == on { return FanReply(status: 0, result: UInt32(on ? 1 : 0)) }
        }
        return FanReply(status: -1, result: UInt32(silentModeOn() ? 1 : 0))
    }

    /// USB 关机充电（0x767 bit4）。无状态回读，返回的只是「触发位写进去了」。
    func triggerUsbCharger() -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        return ecWriteVerified(EC.triggerByte, EC.triggerUsbCharger)
    }

    /// 风扇增压（0x767 bit2）：一次性动作，EC 会在温度降下来后自己退出。
    func triggerFanBoost() -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        return ecWriteVerified(EC.triggerByte, EC.triggerFanBoost)
    }

    // MARK: - 海岸灯

    /// 0-255 → EC 的 10 档（0,4,…,36）
    static func lightbarQuantize(_ v: Int) -> UInt8 {
        let c = max(0, min(255, v))
        let idx = Int((Double(c) / 255.0 * 9.0).rounded())
        return EC.lightbarLevels[max(0, min(9, idx))]
    }

    /// EC 的 0-36 → 0-255（供界面还原颜色）
    static func lightbarExpand(_ raw: UInt8) -> Int {
        let r = min(raw, EC.lightbarLevelMax)
        return Int((Double(r) / Double(EC.lightbarLevelMax) * 255.0).rounded())
    }

    /// 读一个字节（读失败返回 nil）
    private func lbByte(_ addr: UInt32) -> UInt8? {
        guard let r = ecRead(addr), r.ok else { return nil }
        return UInt8(r.result & 0xFF)
    }

    /// 海岸灯状态（读组无锁，v2.5.3.1）
    /// `rgb` 是 EC 原始档位（0-36），`rgb255` / `hex` 是展开到 0-255 的等价色。
    /// `breathing` = 睡眠展示开关（bit3 反逻辑：0 = 睡时展示灯效）。
    func lightbarStatus() -> [String: Any]? {
        guard let ctrl = lbByte(EC.lightbarCtrl),
              let r = lbByte(EC.lightbarRed),
              let g = lbByte(EC.lightbarGreen),
              let b = lbByte(EC.lightbarBlue) else { return nil }
        let mode: String
        if ctrl & EC.lightbarS0Off != 0 { mode = "off" }        // bit2 关灯位优先级最高
        else if ctrl & EC.lightbarRainbow != 0 { mode = "cycle" }
        else { mode = "static" }
        let e = [Self.lightbarExpand(r), Self.lightbarExpand(g), Self.lightbarExpand(b)]
        return ["ctrl": ctrl, "mode": mode,
                "breathing": (ctrl & EC.lightbarS3Off) == 0,
                "ap_exist": (ctrl & EC.lightbarAPPresent) != 0,
                "rgb": [r, g, b],
                "rgb255": e,
                "hex": String(format: "%02x%02x%02x", e[0], e[1], e[2])]
    }

    /// 设置海岸灯（按移植文档 §3.4 的位序，全是读改写）。
    ///
    /// 文档顺序：① bit2 灯开关 ② bit3 睡眠展示（关灯时**无条件**置 1）
    /// ③ bit7 多彩 ④ 最后才写颜色（原厂第 ③ 步是 BIOS RAM Combine，macOS 无该通道，
    /// 等价动作就是 EC 0x749-0x74B 直写）。
    ///
    /// - Parameters:
    ///   - rgb: 传 nil 表示**不动颜色寄存器**（切轮换/关灯时保留用户选的色）。
    ///   - mode: off / cycle / static
    ///   - breathing: 睡眠展示开关；nil = 不改这一位（只有关灯时被强制置 1）
    @discardableResult
    func lightbarSet(_ rgb: [Int]?, mode: String, breathing: Bool?) -> [String: Any]? {
        bizLock.lock()
        defer { bizLock.unlock() }
        guard var c = lbByte(EC.lightbarCtrl) else { return nil }
        let off = (mode == "off")

        // ① bit2 灯带开关
        if off { c |= EC.lightbarS0Off } else { c &= ~EC.lightbarS0Off }

        // ② bit3 睡眠展示：关灯时无条件置 1（文档「睡眠展示 关」条），
        //    开灯时按开关走；没传就保持原值。
        if off {
            c |= EC.lightbarS3Off
        } else if let b = breathing {
            c = b ? (c & ~EC.lightbarS3Off) : (c | EC.lightbarS3Off)
        }

        // ③ bit7 多彩
        if mode == "cycle" { c |= EC.lightbarRainbow } else { c &= ~EC.lightbarRainbow }

        // bit0 AP exist 常驻（原厂启动即置位，软件在场标志）
        c |= EC.lightbarAPPresent
        c &= EC.lightbarWritableMask

        ecWriteVerified(EC.lightbarCtrl, c)

        // ④ 颜色（状态位之后才落颜色，与原厂「先位后色」一致）
        if let rgb = rgb, !off {
            let r = UInt8(max(0, min(255, rgb.count > 0 ? rgb[0] : 0)))
            let g = UInt8(max(0, min(255, rgb.count > 1 ? rgb[1] : 0)))
            let b = UInt8(max(0, min(255, rgb.count > 2 ? rgb[2] : 0)))
            ecWriteVerified(EC.lightbarRed, Self.lightbarQuantize(Int(r)))
            ecWriteVerified(EC.lightbarGreen, Self.lightbarQuantize(Int(g)))
            ecWriteVerified(EC.lightbarBlue, Self.lightbarQuantize(Int(b)))
        }
        return lightbarStatus()
    }

    /// 启动置 `0x748` bit0（原厂 MyLightBar.SetApExist，移植文档 §3.4「启动初始化」第一步）。
    /// 已经在位就零写入。
    @discardableResult
    func lightbarAssertAPPresent() -> Bool {
        guard let c = lbByte(EC.lightbarCtrl) else { return false }
        if c & EC.lightbarAPPresent != 0 { return true }
        bizLock.lock()
        defer { bizLock.unlock() }
        let want = (c | EC.lightbarAPPresent) & EC.lightbarWritableMask
        return ecWriteVerified(EC.lightbarCtrl, want)?.ok ?? false
    }

    /// 一次性探测本机 EC 能力位（读组无锁，v2.5.3.1）
    func ecProbe() -> [String: Any] {
        func rb(_ a: UInt32) -> UInt8 {
            UInt8((ecRead(a)?.result ?? 0) & 0xFF)
        }
        let s1 = rb(EC.support1), s2 = rb(EC.support2), s5 = rb(EC.support5)
        let mi = rb(EC.fanModeIndex)
        let chargeRaw = Int(rb(EC.battCharge) & EC.battChargeMask)
        return [
            "proj_id": rb(EC.projID),
            "support_fan_boost": (s1 & 0x80) != 0,
            "support_lightbar": (s1 & 0x40) != 0,
            "support_silent_mode": (s2 & 0x01) != 0,
            "support_usb_charger": (s2 & 0x02) != 0,
            "support_fan_turbo": (s5 & 0x10) != 0,
            // 2.7.10：PL1/PL2 是**单字节瓦数**（实测 0x41=65W、0x64=100W），
            // 早先按两字节小端读是错的。
            "pl1": Int(rb(EC.pl1)),
            "pl2": Int(rb(EC.pl2)),
            "turbo": Int((rb(EC.ctrl2) >> 2) & 3),
            "modeindex": mi,
            "thermal_level": Int(mi & 0x0F),
            "power_level": Int((mi >> 4) & 0x0F),
            "benchmark": rb(EC.fanCtrl) == EC.fanCtrlBoost,
            "passive_cooling_disabled": (rb(EC.biosCtrl3) & EC.biosOem3PassiveBit) != 0,
            "fn_lock_switch": (rb(EC.apBiosByte) & EC.fnLockSwitch) != 0,
            "keyboard_backlight": (rb(EC.keyboardBacklightState) & EC.keyboardBacklightBit) != 0,
            "win_lock": (rb(EC.statusByte) & EC.statusByteWinLock) != 0,
            "silent_mode": rb(EC.silentModeStatus) == 1,
            // 原始低 7 位为 0 = 不限制，界面还原成 100%
            "charge": chargeRaw == 0 ? 100 : chargeRaw,
            "charge_raw": Int(rb(EC.battCharge)),
            "charge_reached": (rb(EC.battCharge) & EC.battChargeReached) != 0,
        ]
    }

    // MARK: - EC RAM 读写 + 状态快照

    func ecRead(_ addr: UInt32) -> FanReply? {
        call(SEL_EC_READ, addr & 0xFFFF, 0)
    }

    func ecWrite(_ addr: UInt32, _ value: UInt32) -> FanReply? {
        call(SEL_EC_WRITE, addr & 0xFFFF, value & 0xFFFF)
    }

    /// 重载：UInt8 掩码常量直接传入（内部加宽）
    func ecWrite(_ addr: UInt32, _ value: UInt8) -> FanReply? {
        ecWrite(addr, UInt32(value))
    }

    /// **写-回读校验-重试**（包内 `EcRam.WriteVerified` 的等价实现）。
    ///
    /// 【为什么所有写入都必须走这里】
    /// 2026-10-24 05:00 实测：EC 会**丢弃第一笔写入** —— 同一笔命令连发两次时，
    /// 第一次读回原值、第二次才落地，稳定复现十几次。对上层来说结论很确定：
    /// **任何单次 Write 都不可信，必须读回校验 + 重试**。
    /// 之前所有「写进去了但没生效」的假象，一大半是这条造成的。
    ///
    /// 时序照抄包内：写 → 等 20ms → 读回比对 → 不等就再等 60ms 重试，最多 4 次。
    @discardableResult
    func ecWriteVerified(_ addr: UInt32, _ value: UInt8, attempts: Int = 4) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        for _ in 0..<max(1, attempts) {
            _ = ecWrite(addr, value)
            usleep(20_000)
            let back = UInt8((ecRead(addr)?.result ?? 0) & 0xFF)
            if back == value {
                return FanReply(status: 0, result: UInt32(back))
            }
            usleep(60_000)
        }
        let back = UInt8((ecRead(addr)?.result ?? 0) & 0xFF)
        return FanReply(status: back == value ? 0 : -1, result: UInt32(back))
    }

    /// 值不同才写（包内 `WriteIfDifferent`）：减少无谓的 EC 流量，
    /// 也避免把已经很稳的状态反复重写。
    @discardableResult
    private func writeIfDifferent(_ addr: UInt32, _ value: UInt8) -> Bool {
        if UInt8((ecRead(addr)?.result ?? 0) & 0xFF) == value { return true }
        return (ecWriteVerified(addr, value)?.ok ?? false)
    }

    private func readByte(_ addr: UInt32) -> UInt8 {
        UInt8((ecRead(addr)?.result ?? 0) & 0xFF)
    }

    /// 实时组：**只读两个转速**。
    ///
    /// 2.8.15 按「EC 只在需要时读」重排：
    ///   * 保留 `0x0464` / `0x046C`（转速 —— 唯一真正需要实时的 EC 数据）
    ///   * 删除 `0x1809` / `0x1804`（PWM，界面不再显示这个数据）
    ///   * 删除 `0x043E`（EC 板级温度 —— 温度一律走 SMC / NVAccel）
    ///   * 移出 `0x0751` / `0x0741` / `0x07A5` / `0x07AB` → 见 modeStatus()，按需读一次
    ///
    /// 读组不持 bizLock（v2.5.3.1：长连接下每个物理调用已串行，读组无锁化）
    ///
    /// 【2026-11-18 转速错值修复】rpm 是 16 位**大端**，跨两个 EC 地址：
    /// 高位 `0x0464` / 低位 `0x0465`（GPU 同理 `0x046C` / `0x046D`）。
    /// kext 的 EC_READ 单次只回**一个字节**，旧代码只读了高位字节就按
    /// `(v&0xFF)<<8 | (v>>8)&0xFF` 硬算 —— 结果永远是「高位×256」，
    /// 以 256 RPM 为步长跳变（实测 0x0A → 显示 2560，真实 2610）。
    /// ecprobe 实测本机（AMW0 通道）：0464=0A 0465=32 → 0x0A32 = 2610 ✓
    func fanRPMStatus() -> [String: Any] {
        func rpmOf(hi: FanReply?, lo: FanReply?) -> Int {
            // 任一字节没读到就放弃这一拍（0 会被上层按「读数不可用」处理）
            guard let hi, hi.ok, let lo, lo.ok else { return 0 }
            return Int((hi.result & 0xFF) << 8 | (lo.result & 0xFF))
        }
        let rpm1hi = ecRead(EC.fanRPM1)
        let rpm1lo = ecRead(EC.fanRPM1 + 1)
        let rpm2hi = ecRead(EC.fanRPM2)
        let rpm2lo = ecRead(EC.fanRPM2 + 1)
        return [
            "rpm_cpu": rpmOf(hi: rpm1hi, lo: rpm1lo),
            "rpm_gpu": rpmOf(hi: rpm2hi, lo: rpm2lo),
            // 温度不走 EC：CPU 取 SMC 封装温度，GPU 取 SMC（本机无键时退 NVAccel 驱动上报）。
            "temp_cpu": TempSources.cpuCelsius(),
            "temp_gpu": TempSources.gpuCelsius(),
            "temp_gpu_edge": TempSources.gpuEdgeCelsius(),
        ]
    }

    /// 模式状态组：`0x0751`(风扇控制) / `0x0741`(AP exist + 异常位) /
    /// `0x07A5`(ApOem3) / `0x07AB`(功耗档<<4|散热档)，共 4 读。
    ///
    /// 只在「控制 / 实验性」页打开时读一次（或写操作后回读），不进轮询。
    func modeStatus() -> [String: Any] {
        func byteOf(_ r: FanReply?) -> UInt8 {
            UInt8((r?.result ?? 0) & 0xFF)
        }
        let ctrl = ecRead(EC.fanCtrl)
        let ctrl1 = ecRead(EC.ctrl1)
        let c3 = ecRead(EC.ctrl3)
        let mi = ecRead(EC.fanModeIndex)
        // 【2026-11-11】4 读全成功才算有效。EC 限速/争用时 ecRead 会失败，
        // 老代码把失败当 0 再被上层缓存一整天 —— 表现就是「基准模式明明全速，
        // 界面却显示未开启、0x751=0」。加这一位让上层拒绝缓存失败结果。
        let readOK = [ctrl, ctrl1, c3, mi].allSatisfy { ($0?.ok ?? false) }

        var mode: [String] = []
        let v = byteOf(ctrl)
        if v & EC.fanCtrlBoost != 0 { mode.append("BOOST") }
        if v & EC.fanCtrlAuto != 0 { mode.append("AUTO") }
        if v & EC.fanCtrlTurbo != 0 { mode.append("TURBO") }
        if v >= 0x80 { mode.append("LV\(v & 7)") }
        let prof = byteOf(c3)

        // EC 里的真实状态，用来校准界面显示。
        // 【2026-11-11】判据只看 0x751：0x40=基准全速 / 0x80..0x87=手动定速 /
        // 其余（0x00、0xA0…）=EC 自动调度。`0x741` bit0 是常驻的接管标志，不参与。
        let actual: String
        let actualLevel: Int
        if v == EC.fanCtrlBoost {
            actual = "boost"; actualLevel = 0
        } else if v >= 0x80 && v <= 0x87 {
            actual = "custom"; actualLevel = Int(v & 7)
        } else {
            actual = "normal"; actualLevel = 0
        }

        // 2.7.10：散热档 / 功耗档分开给出（0x7AB 的高低半字节），
        // 界面不再从 0x751 猜模式 —— 0xA0 在 OEM 枚举里叫 User_HiMode，
        // 拿它判断会把「标准/安静」显示成「自定义」。
        let miByte = byteOf(mi)
        let thermal = Int(miByte & 0x0F)
        let power = Int((miByte >> 4) & 0x0F)

        // 「manual」字段是历史输出键，含义已更正为「0x751 被手动定速档占用」；
        // 「benchmark」按文档口径只看 0x751=0x40，与 0x741 bit0（常驻接管标志）无关。
        let manualHeld = (v >= 0x80 && v <= 0x87)

        return [
            "fan_ctrl": v,
            "ctrl_1": byteOf(ctrl1),
            "_read_ok": readOK,
            "manual": manualHeld,
            "benchmark": v == EC.fanCtrlBoost,
            "fan_abnormal": (byteOf(ctrl1) & 0x20) != 0,
            "actual": actual,
            "actual_level": actualLevel,
            "profile": prof,
            "modeindex": miByte,
            "thermal_level": thermal,
            "power_level": power,
            "mode": mode.isEmpty ? "AUTO" : mode.joined(separator: " | "),
        ]
    }

    /// 兼容入口：实时组 + 模式组（5+ 读）。
    /// 只给「一次性全量」用（控制页首次进入、mcutil 调试），**不要**放进轮询。
    func fanStatus() -> [String: Any] {
        var out = fanRPMStatus()
        out.merge(modeStatus()) { _, b in b }
        return out
    }
}

// MARK: - 状态持久化（重启后 EC 回默认，服务启动时自动恢复）

/// 温度来源：**一律不碰 EC**。
///
/// 2.8.15 之前 `temp_cpu` 读的是 EC `0x043E`（EC 自己测的 CPU 附近板级温度），
/// 是整条读取链里唯一走 EC 的温度项。现在改走 SMC 封装温度，和「监测 / 性能」
/// 页的传感器表同源（TC0P，Stats 同款）。
/// GPU 温度从 2.7.6 起就是 NVAccel（IOKit 驱动上报），本来就不经过 EC，保持不动。
enum TempSources {
    // 2026-11-17（性能自查）：一拍内只读一次。
    //
    // `fanState()` 每次都会问 cpu / gpu / gpu_edge 三个温度，而 `/api/snapshot`
    // 每秒走一遍、`/api/fan` 与「全部信息」页也会各问一次。每次 `cpuCelsius()`
    // 都要 `try? SMC()` 建一条连接、读 1~5 个键、再关掉 —— 同一秒里这些调用
    // 拿到的必然是同一个数。1 秒 TTL 把它们合并成一次读，界面感知不到
    //（温度本来就是整秒变化的量）。
    private static let tempLock = NSLock()
    private static var tempCache: [String: (t: Double, v: Int)] = [:]
    private static let tempTTL: Double = 1.0

    private static func memo(_ key: String, _ body: () -> Int) -> Int {
        tempLock.lock()
        if let c = tempCache[key], Date().timeIntervalSince1970 - c.t < tempTTL {
            let v = c.v
            tempLock.unlock()
            return v
        }
        tempLock.unlock()
        let v = body()
        tempLock.lock()
        tempCache[key] = (Date().timeIntervalSince1970, v)
        tempLock.unlock()
        return v
    }

    /// CPU 温度（℃）。SMC 依次尝试封装/接近温度键，都拿不到返回 0（上层按「不可用」显示）。
    static func cpuCelsius() -> Int {
        memo("cpu") {
            guard let smc = try? SMC() else { return 0 }
            defer { smc.close() }
            for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H"] {
                if let v = smc.readValue(key), v > 0, v < 120 {
                    return Int(v.rounded())
                }
            }
            return 0
        }
    }

    /// GPU 温度（℃）。驱动未就绪/未上报时为 0。
    static func gpuCelsius() -> Int {
        memo("gpu") { NVAccelUtil.coreTemperatureC() ?? 0 }
    }

    /// GPU 核心边缘温度（℃）。与 `gpuCelsius()` 是两个不同测点，见 `edgeTemperatureC()`。
    /// 驱动只发一个温度键时返回 0，界面按「只有一个」降级显示。
    static func gpuEdgeCelsius() -> Int {
        memo("gpu_edge") { NVAccelUtil.edgeTemperatureC() ?? 0 }
    }

    /// 丢弃缓存（写了风扇/切换档位后要让温度立刻重读时用）
    static func invalidate() {
        tempLock.lock(); tempCache.removeAll(); tempLock.unlock()
    }
}

enum FanStateStore {
    private static var stateURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SkyCC", isDirectory: true)
        return dir.appendingPathComponent("fan_state.json")
    }()

    static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = d["mode"] as? String,
              ["normal", "boost", "custom", "curve"].contains(mode),
              let level = d["level"] as? Int, (0...7).contains(level) else { return nil }
        return ["mode": mode, "level": level]
    }

    @discardableResult
    static func save(_ mode: String, _ level: Int) -> Bool {
        let dir = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["mode": mode, "level": level]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return (try? data.write(to: stateURL)) != nil
    }

    static func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// 服务启动时调用：恢复上次设置的模式/等级
    static func apply() -> [String: Any] {
        guard let st = load() else {
            return ["ok": false, "reason": "no-saved-state"]
        }
        let fc = FanControl.shared
        let r: FanReply?
        if st["mode"] as? String == "custom" {
            r = fc.setLevel(st["level"] as? Int ?? 0)
        } else if st["mode"] as? String == "curve" {
            // 曲线模式：启动常驻控制环（环自身读 EC 温度并按曲线调速）
            FanCurveController.shared.start()
            r = FanReply(status: 0, result: 0)
        } else if st["mode"] as? String == "boost" {
            r = fc.setBenchmarkMode(true)
        } else {
            // 2.8.14：先清残留的手动定速档。上次若停在「手动 / 曲线」而进程是被强杀的
            // （或旧版本根本没交还档位），0x751 会一直挂在 0x8n，界面显示成「自定义」。
            // 处置只是把 0x751 放回 0x00，**不动 0x741 bit0**（那是在线标志）。
            // 基准模式（0x751=0x40）不在此列，不动。
            if fc.staleDoorOpen() {
                _ = fc.releaseManualDoor()
            }
            // 2.7.10：「交给 EC」不再盲写 0x751=0xA0。
            // 散热档的真相在 0x7AB 低半字节（EC 掉电才丢），盲写 0xA0 会把
            // 「散热性能」的机器重启后打成「标准」。这里改成按 0x7AB 重新推导
            // 0x751/0x7A5/曲线槽，等于「把当前档位重新应用一遍」。
            let t = fc.thermalLevel()
            if (1...3).contains(t) {
                r = fc.setThermalLevel(t)
            } else {
                r = fc.setMode("normal")
            }
        }
        return ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(), "state": st]
    }
}
