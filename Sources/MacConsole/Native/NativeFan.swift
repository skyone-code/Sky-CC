//
//  NativeFan.swift
//  Mac控制台 —— TongfangFan.kext 用户态客户端（原生移植）
//
//  对应 Python 版 python后端/fanctl.py。
//
//  原理：
//    TongfangFan.kext 挂在 ACPI PNP0C14（WMI）设备上，暴露 TongfangFanDriver
//    IOService + TongfangFanUserClient。经 IOServiceGetMatchingService →
//    IOServiceOpen → IOConnectCallStructMethod(selector=0) 调用：
//        入参 12 字节: {u32 selector, u32 arg1, u32 arg2}
//        出参  8 字节: {i32 status, u32 result}
//
//  两个必须记住的坑（原样保留）：
//    1. 写风扇相关寄存器前必须先置 CTRL_1(0x0741) bit0 开「手动门」，否则 EC 静默拒收；
//    2. 不要直写 PWM(0x1804/0x1809) —— 会让 EC 停转风扇，只写 FAN_CTRL 档位。
//

import Foundation
import IOKit

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
    static let fanRPM1: UInt32      = 0x046C   // CPU 风扇转速（16位，大端）
    static let fanRPM2: UInt32      = 0x0464   // GPU 风扇转速
    static let fanTemp1: UInt32     = 0x043E   // CPU 附近温度（°C）
    static let fanTemp2: UInt32     = 0x044F   // GPU 附近板级温度（°C）—— 2.7.6 起已不再轮询，GPU 温度改走 NVAccel
    static let fanPWM1: UInt32      = 0x1809   // CPU 风扇占空比（量程 0-200）
    static let fanPWM2: UInt32      = 0x1804   // GPU 风扇占空比
    static let ctrl1: UInt32        = 0x0741   // bit0 = 手动风扇门（写事件，不是状态位）bit5 = 风扇异常
    static let ctrl2: UInt32        = 0x078C   // bit2-3 = TURBO_LEVEL(0-3)
    static let ctrl3: UInt32        = 0x07A5   // ApOem3：功耗档+散热档共同决定（0x88|…），基准期间 EC 自己维护
    static let fanModeIndex: UInt32 = 0x07AB   // 模式总开关 = (功耗档<<4)|散热档
    static let modeProfile1: UInt32 = 0x07B0   // 三档功耗各自的曲线索引槽（0x7B0/1/2）
    static let biosCtrl3: UInt32    = 0x07A3   // bit6 = 禁用被动散热模式（2026-10-24 三次实测双向确认）
    static let biosCtrl1: UInt32    = 0x074E   // bit4=Fn锁开关（qc71 BIOS_CTRL_1 / fn_lock）
    static let apBiosByte: UInt32   = 0x07A4   // bit3 = OSD 显示开关（原厂 LaunchServGM 写）
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
    static let lightbarCycle: UInt8  = 0x80    // 多彩轮换动画（出厂基线 = RAINBOW）
    static let lightbarStatic: UInt8 = 0x00    // 固定色（RAINBOW 关、S0_OFF 关）
    static let lightbarOff: UInt8    = 0x84    // 关灯（RAINBOW + S0_OFF）
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
    static let ctrl1ManualMode: UInt8 = 0x01
    static let ctrl3FanQuiet: UInt8 = 0x04
    static let ctrl3Overboost: UInt8 = 0x10
    static let ctrl3HighPwr: UInt8 = 0x80

    static let ctrl2TurboLevelMask: UInt8 = 0x0C  // bit2-3
    static let battChargeMask: UInt8 = 0x7F
    static let battChargeReached: UInt8 = 0x80

    // 键盘 / 触控板 / 风扇行为位（qc71_laptop 交叉验证 2026-10-21，均读-改-写）
    static let biosCtrl1FnLock: UInt8 = 0x10          // 0x074E bit4
    static let osdBit: UInt8 = 0x08                   // 0x07A4 bit3 = OSD 显示（**不是** Fn+Esc）
    static let ctrl4OverboostDynTempOff: UInt8 = 0x02 // 0x07A6 bit1（1=关闭动态温控）
    static let ctrl4TouchpadToggleOff: UInt8 = 0x40   // 0x07A6 bit6（1=禁用触控板）
    static let biosCtrl3ReducedDuty: UInt8 = 0x20     // 0x07A3 bit5（含义未经包内确认，实验位）
    /// 0x07A3 bit6：1 = 「禁用被动散热模式」已勾选。
    /// 【2026-10-24 00:33 / 00:38 / 00:49 三次实测双向确认】
    ///   早先的注释写成「风扇常转」是错的 —— 包内 `EcMap.BiosOem3PassiveBit` 定案为禁用被动散热。
    static let biosOem3PassiveBit: UInt8 = 0x40
    static let apOem3BenchmarkBit: UInt8 = 0x10       // 0x07A5 bit4 = 基准模式（EC 自己算的镜像，我们不写）
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

private let serviceClass = "TongfangFanDriver"
private let kextID = "com.macconsole.TongfangFan"

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

    /// 找服务：枚举所有 TongfangFanDriver，优先 ABBC0F6F 实例（真 WMBC）。
    private func findService() -> io_service_t? {
        guard let matching = IOServiceMatching(serviceClass) else {
            trace("findService: IOServiceMatching nil")
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

        var fallback: io_service_t = 0
        var target: io_service_t = 0
        while true {
            let svc = IOIteratorNext(iter)
            if svc == 0 { break }
            if serviceIsABBC(svc) {
                if target != 0 { IOObjectRelease(target) }
                target = svc
            } else if fallback == 0 {
                fallback = svc
            } else {
                IOObjectRelease(svc)
            }
        }
        if target != 0 {
            if fallback != 0 { IOObjectRelease(fallback) }
            return target
        }
        return fallback != 0 ? fallback : nil
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
    static func kextLoaded() -> Bool {
        guard let matching = IOServiceMatching(serviceClass) else { return false }
        // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会找不到服务
        let svc = IOServiceGetMatchingService(0, matching)
        guard svc != 0 else { return false }
        IOObjectRelease(svc)
        return true
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
        ecQueue = DispatchQueue(label: "macconsole.ec.mailbox", qos: .userInitiated)
        stateLock.unlock()
    }

    /// 串行 EC 通道：所有物理调用排进同一条串行 queue。
    /// 长连接≠串行——IOKit 不保证同一 connect 的并发调用顺序，kext 侧同时
    /// 进来的多个请求照样搅乱 EC 邮箱（实测），必须用户态自己串行化。
    /// 看门狗断路时整体替换（旧 queue 里挂死的 block 随之遗弃）。
    private var ecQueue: DispatchQueue =
        DispatchQueue(label: "macconsole.ec.mailbox", qos: .userInitiated)

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
            ecQueue = DispatchQueue(label: "macconsole.ec.mailbox", qos: .userInitiated)
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

    /// 交还 EC：**安全关闭** `0x741` 手动门（bit0）。
    ///
    /// 【2.8.14 用户要求】手动档位退出、温控曲线退出都必须调它。
    /// 以前 `setLevel()` 只管开门不管关门，用完手动档或曲线之后门一直挂在 `0x01`，
    /// `benchmarkMode()` 恒为真 —— 控制页的散热档 / 功耗档全被挡掉，
    /// 界面上就表现为「点了没反应」。
    ///
    /// 【顺序不能反】包内定案：先放档位 `0x751←0x00`（此时门还开着，才写得进），
    /// 最后才清门。反过来在 `0x751` 还挂着 `0x40` / `0x8n` 时直接清门，
    /// EC 会置 FAN_ABNORMAL（bit5），之后**整片风扇寄存器拒写，只能重启**。
    /// 放档位这一步失败就保留原样、不动门（风扇响着总比写不进去好）。
    ///
    /// - Returns: `status == 0` 表示门已处于关闭状态（含本来就没开）。
    @discardableResult
    func releaseManualDoor() -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        let c1 = readByte(EC.ctrl1)
        // 门本来就没开：什么都不用做
        guard (c1 & EC.ctrl1ManualMode) != 0 else { return FanReply(status: 0, result: UInt32(c1)) }
        // 已经 FAN_ABNORMAL 了：任何写入都会被拒，别再加一笔
        guard (c1 & 0x20) == 0 else { return FanReply(status: -3, result: UInt32(c1)) }
        // ① 放档位（门还开着才写得进）
        let released = ecWriteVerified(EC.fanCtrl, 0x00)?.ok ?? false
        guard released else {
            return FanReply(status: -1, result: UInt32(readByte(EC.fanCtrl)))
        }
        // ② 最后清门，EC 收回管辖权 → 自己按 0x7AB 重算 0x751
        let r = ecWriteVerified(EC.ctrl1, 0x00)
        return r ?? FanReply(status: -1, result: UInt32(readByte(EC.ctrl1)))
    }

    func setMode(_ mode: String) -> FanReply? {
        guard ["normal", "boost", "custom"].contains(mode) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        switch mode {
        case "normal":
            // 「交还 EC」的**正确**做法：先放档位再关手动门，EC 自己按 0x7AB 重算
            // 0x751 / 0x7A5。包内定案：「关闭：写 0x00 → EC 立刻收回管辖权，
            // 0x751 自动回落到 0x7AB 对应的值」。
            // 2.8.14：改为调用 releaseManualDoor()——以前这里第一笔就是 `0x741←0x00`，
            // 若此时 0x751 还挂着 0x40 / 0x8n，正好踩中包内 04:48 那个
            // 「顺序反了 → FAN_ABNORMAL → 整片拒写」的坑。
            let r = releaseManualDoor()
            // 个别情况下 EC 关门后不会立刻重算 0x751，这里做一次
            // 「开门 → 改正 → 再关门」的兜底（关门同样走安全顺序）。
            let t = thermalLevel()
            if (1...3).contains(t) {
                let want = EC.fanControlFor(t)
                let cur = readByte(EC.fanCtrl)
                if cur != want {
                    if (ecWriteVerified(EC.ctrl1, EC.ctrl1ManualMode)?.ok ?? false) {
                        writeIfDifferent(EC.fanCtrl, want)
                        writeIfDifferent(EC.ctrl3, EC.apOem3For(power: powerLevel(), thermal: t))
                    }
                    _ = releaseManualDoor()
                }
            }
            return r
        case "boost":
            // 基准模式：包内 2026-10-24 05:00 定案的顺序 —— 断言手动门 → 0x751←0x40。
            // 实测 2642 → 5615 RPM，0x768 由 EC 自己置成 0x04。
            return setBenchmarkMode(true)
        default:
            ecWriteVerified(EC.ctrl1, EC.ctrl1ManualMode)
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

    /// 基准模式是否开启。判据是**手动门** `0x741` bit0 —— 硬件状态只有这一位，
    /// `0x7A5` bit4 是 EC 按档位算出来的镜像，与基准无因果关系。
    func benchmarkMode() -> Bool { (readByte(EC.ctrl1) & EC.ctrl1ManualMode) != 0 }

    /// 风扇异常位（`0x741` bit5）。置起后整片风扇寄存器拒写，只能重启恢复。
    func fanAbnormal() -> Bool { (readByte(EC.ctrl1) & 0x20) != 0 }

    /// 启动对账用：手动门开着，但**不是**基准模式（`0x751 ≠ 0x40`）。
    ///
    /// 这种状态只可能是「手动档位 / 温控曲线用完没关门」留下的残留：
    /// 门挂在 `0x01` 会让 `benchmarkMode()` 恒为真，于是控制页的散热档、功耗档
    /// 全被 `-2` 拒绝，用户看到的就是「设置失效」。
    /// 基准模式（`0x751 = 0x40`）是用户显式打开的覆盖态，不能替他关。
    func staleDoorOpen() -> Bool {
        let c1 = readByte(EC.ctrl1)
        guard (c1 & EC.ctrl1ManualMode) != 0, (c1 & 0x20) == 0 else { return false }
        return readByte(EC.fanCtrl) != EC.fanCtrlBoost
    }

    /// 切换散热档（写**四个**寄存器，包内 `FanService.SetMode` 同款序列）：
    ///   · `0x751` 按散热档：性能 0x00 / 标准·安静 0xA0
    ///   · `0x7A5` 功耗档 + 散热档共同决定
    ///   · `0x7AB` 低半字节 = 散热档本体（EC 把整字节当「整组设置应用完毕」的收尾信号）
    ///   · `0x7B{功耗档-1}` 该功耗档自己的曲线索引槽
    /// 功耗档（高半字节）保持不变，原厂也不改它。
    ///
    /// 基准模式下直接拒绝：此时 0x741 门开着、0x751=0x40 由 EC 维持，
    /// 放行会把 0x751 打回 0x00/0xA0 —— 增压没了、门却还开着，
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

    /// 开启前的档位索引，供关闭基准时兜底还原（正常情况 EC 自己会落回原档）。
    private static var preBenchmarkIndex: UInt8 = 0

    /// 启用 / 关闭基准模式。
    ///
    /// 【顺序反了会出大事】基准生效期间直接清门（`0x741←0x00`）在极端情况下会让 EC
    /// 置 FAN_ABNORMAL(bit5)，之后**整片风扇寄存器拒写**，只能重启恢复。
    /// 正确路径：开门 → `0x751←0x40`；关闭时反过来 `0x751←0x00` → 关门。
    /// 顺序反了会触发 FAN_ABNORMAL（`0x741` 变 `0xA3`）导致整片风扇寄存器拒写。
    ///
    /// 【绝对不要再写这几个字节】`0x7A5` / `0x768` / `0x7AB` 都是 EC 按档位算出来的镜像。
    /// 实测 `0x7A5←0x99` 一写，紧接着的 `0x751←0x40` 就被打回（60ms 内回落）。
    func setBenchmarkMode(_ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        var ok = true
        if on {
            // 【包内定案 25 号文档】`0x741` 是**写事件**，不是持久状态位：
            // 即使读回已经是 0x01，也必须再写一次 —— 重写等于重新声明接管权。
            // 实测「只写 0x751←0x40」在接管权已失效时会被 EC 静默拒收（rc=1 但读回 0x00），
            // 「先写 0x741←0x01 再写 0x751←0x40」才会站住。所以这里**不做早退**。
            // 只有门本来就是开的时候才无需重新采样原档位（0x7AB 基准期间本就不动）。
            if !benchmarkMode() {
                FanControl.preBenchmarkIndex = readByte(EC.fanModeIndex)
            }
            // ① 断言手动门。这一步失败就没必要往下写了。
            ok = (ecWriteVerified(EC.ctrl1, EC.ctrl1ManualMode)?.ok ?? false)
            // ② 门开了才写增压档；0x768 由 EC 自己置成 0x04
            if ok { ok = (ecWriteVerified(EC.fanCtrl, EC.fanCtrlBoost)?.ok ?? false) }
            return FanReply(status: ok ? 0 : -1, result: UInt32(readByte(EC.statusByte)))
        }
        // 关闭：只有门开着才需要「先放档位再关门」这套顺序
        guard benchmarkMode() else { return FanReply(status: 0, result: 0) }
        ok = (ecWriteVerified(EC.fanCtrl, 0x00)?.ok ?? false)
        // 模式兜底：基准本身不碰 0x7AB，EC 会自己落回原档位（0xA0）。
        // 这一步只防「基准期间被别处改过 0x7AB」，**必须在关门之前写** ——
        // 0x7AB 也是风扇寄存器，门一关同样会被 EC 静默拒收。
        if ok {
            let pre = FanControl.preBenchmarkIndex
            if pre >= 0x11, pre <= 0x33, readByte(EC.fanModeIndex) != pre {
                _ = ecWriteVerified(EC.fanModeIndex, pre)
            }
        }
        // ③ 最后清门，EC 收回管辖权，0x751 落到 0x7AB 对应档位
        if ok { ok = (ecWriteVerified(EC.ctrl1, 0x00)?.ok ?? false) }
        return FanReply(status: ok ? 0 : -1, result: 0)
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
        ecWriteVerified(EC.ctrl1, EC.ctrl1ManualMode)
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
    func setTurbo(_ level: Int) -> FanReply? {
        guard (0...3).contains(level) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        let prev = UInt8((ecRead(EC.ctrl1)?.result ?? 0) & 0xFF)
        ecWrite(EC.ctrl1, EC.ctrl1ManualMode)
        let cur = UInt8((ecRead(EC.ctrl2)?.result ?? 0) & 0xFF)
        let v = (cur & ~EC.ctrl2TurboLevelMask) | UInt8(level << 2)
        let r = ecWrite(EC.ctrl2, v)
        if prev & EC.ctrl1ManualMode == 0 {
            ecWrite(EC.ctrl1, prev)
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
        let cur = UInt8((ecRead(addr)?.result ?? 0) & 0xFF)
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
        let ab = byte(EC.apBiosByte)     // 0x07A4
        let c4 = byte(EC.ctrl4)          // 0x07A6
        let b3 = byte(EC.biosCtrl3)      // 0x07A3
        let kb = byte(EC.keyboardBacklightState)  // 0x07C4
        let st = byte(EC.statusByte)     // 0x0768
        let sm = byte(EC.silentModeStatus) // 0x045B
        return [
            "fn_lock": (b1 & EC.biosCtrl1FnLock) != 0,
            // 2.7.10：0x7A4 bit3 是 **OSD 显示**，不是 Fn+Esc 快捷键。
            // 包内 EcMap.OsdBit 定案（原厂点「OSD 显示」→ 服务写 0x7A4 bit3）。
            "osd": (ab & EC.osdBit) != 0,
            "keyboard_backlight": (kb & EC.keyboardBacklightBit) != 0,
            "win_lock": (st & EC.statusByteWinLock) != 0,
            "silent_mode": sm == 1,
            "benchmark": benchmarkMode(),
            // 2.7.7：触控板状态改由「HID 独占」的真实状态给出。
            // touchpad_off 仍保留 EC 那一位的回读（诊断用），但它在本机是无效位，
            // UI 不能拿它当开关状态，否则拨了没反应还会自己弹回去。
            "touchpad_off": (c4 & EC.ctrl4TouchpadToggleOff) != 0,
            "touchpad_locked": TrackpadLock.locked,
            "overboost_dyn_temp_off": (c4 & EC.ctrl4OverboostDynTempOff) != 0,
            "fan_reduced_duty": (b3 & EC.biosCtrl3ReducedDuty) != 0,
            // 2.7.10：改名。0x7A3 bit6 是「禁用被动散热模式」，不是「风扇常转」。
            "passive_cooling_disabled": (b3 & EC.biosOem3PassiveBit) != 0,
        ]
    }

    /// Fn 锁（0x074E bit4）：开启后 F1-F12 直接触发功能键
    func setFnLock(_ on: Bool) -> FanReply? {
        modifyBit(EC.biosCtrl1, EC.biosCtrl1FnLock, on)
    }

    /// OSD 显示（0x07A4 bit3）。原厂由 LaunchServGM 服务写，复刻版直接补写。
    func setOsd(_ on: Bool) -> FanReply? {
        modifyBit(EC.apBiosByte, EC.osdBit, on)
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

    /// 海岸灯状态（读组无锁，v2.5.3.1）
    /// `rgb` 是 EC 原始档位（0-36），`rgb255` / `hex` 是展开到 0-255 的等价色。
    func lightbarStatus() -> [String: Any]? {
        func rb(_ a: UInt32) -> UInt8? {
            guard let r = ecRead(a), r.ok else { return nil }
            return UInt8(r.result & 0xFF)
        }
        guard let ctrl = rb(EC.lightbarCtrl),
              let r = rb(EC.lightbarRed),
              let g = rb(EC.lightbarGreen),
              let b = rb(EC.lightbarBlue) else { return nil }
        let mode: String
        if ctrl & 0x04 != 0 { mode = "off" }              // bit2 关灯位优先级最高
        else if ctrl & EC.lightbarCycle != 0 { mode = "cycle" }
        else { mode = "static" }
        let e = [Self.lightbarExpand(r), Self.lightbarExpand(g), Self.lightbarExpand(b)]
        return ["ctrl": ctrl, "mode": mode,
                "rgb": [r, g, b],
                "rgb255": e,
                "hex": String(format: "%02x%02x%02x", e[0], e[1], e[2])]
    }

    /// 设置海岸灯。`rgb` 传 nil 表示**不动颜色寄存器**（切轮换/关灯时保留用户选的色）。
    ///
    /// 写入顺序特意改成「先 RGB 再 ctrl」：ctrl 是固件侧的生效/latch 动作，
    /// 放最后写能保证颜色先就位，不会出现「切固定色后第一下还是旧色」。
    @discardableResult
    func lightbarSet(_ rgb: [Int]?, ctrl: UInt8) -> [String: Any]? {
        let c = ctrl & EC.lightbarWritableMask
        bizLock.lock()
        if let rgb = rgb {
            let r = UInt8(max(0, min(255, rgb.count > 0 ? rgb[0] : 0)))
            let g = UInt8(max(0, min(255, rgb.count > 1 ? rgb[1] : 0)))
            let b = UInt8(max(0, min(255, rgb.count > 2 ? rgb[2] : 0)))
            ecWriteVerified(EC.lightbarRed, Self.lightbarQuantize(Int(r)))
            ecWriteVerified(EC.lightbarGreen, Self.lightbarQuantize(Int(g)))
            ecWriteVerified(EC.lightbarBlue, Self.lightbarQuantize(Int(b)))
        }
        ecWriteVerified(EC.lightbarCtrl, c)
        bizLock.unlock()
        return lightbarStatus()
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
            "benchmark": (rb(EC.ctrl1) & EC.ctrl1ManualMode) != 0,
            "passive_cooling_disabled": (rb(EC.biosCtrl3) & EC.biosOem3PassiveBit) != 0,
            "osd": (rb(EC.apBiosByte) & EC.osdBit) != 0,
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
        var last: FanReply?
        for _ in 0..<max(1, attempts) {
            last = ecWrite(addr, value)
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
    ///   * 保留 `0x046C` / `0x0464`（转速 —— 唯一真正需要实时的 EC 数据）
    ///   * 删除 `0x1809` / `0x1804`（PWM，界面不再显示这个数据）
    ///   * 删除 `0x043E`（EC 板级温度 —— 温度一律走 SMC / NVAccel）
    ///   * 移出 `0x0751` / `0x0741` / `0x07A5` / `0x07AB` → 见 modeStatus()，按需读一次
    ///
    /// 读组不持 bizLock（v2.5.3.1：长连接下每个物理调用已串行，读组无锁化）
    func fanRPMStatus() -> [String: Any] {
        func rpmOf(_ r: FanReply?) -> Int {
            // qc71: rpm = b1 << 8 | b2（大端）
            let v = r?.result ?? 0
            return Int((v & 0xFF) << 8 | (v >> 8) & 0xFF)
        }
        let rpm1 = ecRead(EC.fanRPM1)
        let rpm2 = ecRead(EC.fanRPM2)
        return [
            "rpm_cpu": rpmOf(rpm1),
            "rpm_gpu": rpmOf(rpm2),
            // 温度不走 EC：CPU 取 SMC 封装温度，GPU 取 SMC（本机无键时退 NVAccel 驱动上报）。
            "temp_cpu": TempSources.cpuCelsius(),
            "temp_gpu": TempSources.gpuCelsius(),
        ]
    }

    /// 模式状态组：`0x0751`(风扇控制) / `0x0741`(手动门+异常位) /
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

        var mode: [String] = []
        let v = byteOf(ctrl)
        if v & EC.fanCtrlBoost != 0 { mode.append("BOOST") }
        if v & EC.fanCtrlAuto != 0 { mode.append("AUTO") }
        if v & EC.fanCtrlTurbo != 0 { mode.append("TURBO") }
        if v >= 0x80 { mode.append("LV\(v & 7)") }
        let prof = byteOf(c3)

        // EC 里的真实状态，用来校准界面显示
        let manual = (byteOf(ctrl1) & EC.ctrl1ManualMode) != 0
        let actual: String
        let actualLevel: Int
        if !manual {
            actual = "normal"; actualLevel = 0
        } else if v & EC.fanCtrlBoost != 0 {
            actual = "boost"; actualLevel = 0
        } else if v >= 0x80 {
            actual = "custom"; actualLevel = Int(v & 7)
        } else {
            actual = "custom"; actualLevel = 0
        }

        // 2.7.10：散热档 / 功耗档分开给出（0x7AB 的高低半字节），
        // 界面不再从 0x751 猜模式 —— 0xA0 在 OEM 枚举里叫 User_HiMode，
        // 拿它判断会把「标准/安静」显示成「自定义」。
        let miByte = byteOf(mi)
        let thermal = Int(miByte & 0x0F)
        let power = Int((miByte >> 4) & 0x0F)

        return [
            "fan_ctrl": v,
            "ctrl_1": byteOf(ctrl1),
            "manual": manual,
            "benchmark": manual,
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
    /// CPU 温度（℃）。SMC 依次尝试封装/接近温度键，都拿不到返回 0（上层按「不可用」显示）。
    static func cpuCelsius() -> Int {
        guard let smc = try? SMC() else { return 0 }
        defer { smc.close() }
        for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H"] {
            if let v = smc.readValue(key), v > 0, v < 120 {
                return Int(v.rounded())
            }
        }
        return 0
    }

    /// GPU 温度（℃）。驱动未就绪/未上报时为 0。
    static func gpuCelsius() -> Int {
        NVAccelUtil.coreTemperatureC() ?? 0
    }
}

enum FanStateStore {
    private static var stateURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
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
            // 2.8.14：先清残留的手动门。上次若停在「手动 / 曲线」而进程是被强杀的
            // （或旧版本根本没关门），门会一直挂在 0x01，导致下面 setThermalLevel
            // 直接被 benchmarkMode() 挡成 -2 —— 用户看到的就是「重启后散热档调不动」。
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
