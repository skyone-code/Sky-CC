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

enum EC {
    static let fanCtrl: UInt32      = 0x0751   // bit4=TURBO bit5=AUTO bit6=BOOST, 0x80+n=级别
    static let fanRPM1: UInt32      = 0x046C   // CPU 风扇转速（16位，大端）
    static let fanRPM2: UInt32      = 0x0464   // GPU 风扇转速
    static let fanTemp1: UInt32     = 0x043E   // CPU 附近温度（°C）
    static let fanTemp2: UInt32     = 0x044F   // GPU 附近温度（°C）
    static let fanPWM1: UInt32      = 0x1809   // CPU 风扇占空比（量程 0-200）
    static let fanPWM2: UInt32      = 0x1804   // GPU 风扇占空比
    static let ctrl1: UInt32        = 0x0741   // bit0 = 手动风扇模式
    static let ctrl2: UInt32        = 0x078C   // bit2-3 = TURBO_LEVEL(0-3)
    static let ctrl3: UInt32        = 0x07A5   // bit2=静音 bit4=超频 bit7=高性能（随档位自动变，勿手写）
    static let fanModeIndex: UInt32 = 0x07AB   // 性能模式真正入口: 0x11/0x22/0x33
    static let modeProfile1: UInt32 = 0x07B0   // 上面三档的镜像
    static let biosCtrl3: UInt32    = 0x07A3   // bit5=降低占空比 bit6=常转
    static let biosCtrl1: UInt32    = 0x074E   // bit4=Fn锁开关（qc71 BIOS_CTRL_1 / fn_lock）
    static let apBiosByte: UInt32   = 0x07A4   // bit3=Fn+Esc快捷键开关（qc71 AP_BIOS_BYTE / fn_lock_switch）
    static let ctrl4: UInt32        = 0x07A6   // bit1=超频动态温控关闭 bit6=触控板关闭（qc71 CTRL_4）
    static let battCharge: UInt32   = 0x07B9   // bit0-6 = 百分比, bit7 = 已到达
    static let pl1: UInt32          = 0x0783   // 功耗墙 PL1（实测恒 0，固件未启用）
    static let pl2: UInt32          = 0x0784
    static let lightbarCtrl: UInt32 = 0x0748   // bit0/1/2/3/6/7 可写，bit4/5 被 EC 掩码
    static let lightbarRed: UInt32  = 0x0749
    static let lightbarGreen: UInt32 = 0x074A
    static let lightbarBlue: UInt32 = 0x074B
    static let pl4: UInt32          = 0x0785
    static let support1: UInt32     = 0x0765   // bit7 = 支持 FAN_BOOST
    static let support2: UInt32     = 0x0766   // bit0 = 支持静音模式（本机不支持）
    static let support5: UInt32     = 0x0742   // bit4 = FAN_TURBO, bit5 = FAN
    static let projID: UInt32       = 0x0740   // 项目 ID，本机 = 8

    // 海岸灯已验证取值（2026-10-16 肉眼验证）
    static let lightbarCycle: UInt8  = 0x80    // 多彩轮换动画（出厂基线）
    static let lightbarStatic: UInt8 = 0x00    // 固定色
    static let lightbarOff: UInt8    = 0x84    // 关灯（bit7 + bit2）
    static let lightbarWritableMask: UInt8 = 0xCF

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
    static let apBiosFnLockSwitch: UInt8 = 0x08       // 0x07A4 bit3
    static let ctrl4OverboostDynTempOff: UInt8 = 0x02 // 0x07A6 bit1（1=关闭动态温控）
    static let ctrl4TouchpadToggleOff: UInt8 = 0x40   // 0x07A6 bit6（1=禁用触控板）
    static let biosCtrl3ReducedDuty: UInt8 = 0x20     // 0x07A3 bit5
    static let biosCtrl3AlwaysOn: UInt8 = 0x40        // 0x07A3 bit6
}

private let serviceClass = "TongfangFanDriver"
private let kextID = "com.macconsole.TongfangFan"

// MARK: - 客户端

struct FanReply {
    var status: Int32 = 0
    var result: UInt32 = 0

    var ok: Bool { status == 0 }
    var dict: [String: Any] { ["status": Int(status), "result": result] }
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
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        var iter: io_iterator_t = 0
        // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会找不到服务
        guard IOServiceGetMatchingServices(0, matching, &iter) == KERN_SUCCESS,
              iter != 0 else { return nil }
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
        guard let s = findService() else { return nil }   // kext 未加载
        var c: io_connect_t = 0
        guard IOServiceOpen(s, mach_task_self_, 0, &c) == KERN_SUCCESS else {
            IOObjectRelease(s)
            return nil
        }
        svc = s          // 保续 service 引用（长连接存活期间不 release）
        conn = c
        return c
    }

    /// 作废连接：置 0 让下次 ensureConn 重开。
    /// 故意不调 IOObjectClose——对可能还挂着 outstanding 调用的连接 close
    /// 有同样阻塞风险；宁可泄漏一个 user-client（看门狗事件极罕见，重启回收）。
    private func invalidateConn() {
        conn = 0
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
            stateLock.lock()
            invalidateConn()
            ecQueue = DispatchQueue(label: "macconsole.ec.mailbox", qos: .userInitiated)
            stateLock.unlock()
            return FanReply(status: Int32(kIOReturnTimeout), result: 0)
        }
        return boxed
    }

    /// 裸 WMI 调用（只在串行 queue 内执行，天然无并发）
    private func ioCall(_ c: io_connect_t, _ selector: UInt32, _ arg1: UInt32, _ arg2: UInt32) -> FanReply? {
        var msg = Msg(selector: selector, arg1: arg1, arg2: arg2)
        var reply = FanReply()
        var outSize = MemoryLayout<FanReply>.size    // size_t = Int
        let kr = withUnsafeMutablePointer(to: &msg) { msgPtr in
            withUnsafeMutablePointer(to: &reply) { replyPtr in
                withUnsafeMutablePointer(to: &outSize) { sizePtr in
                    IOConnectCallStructMethod(
                        c, 0,
                        UnsafeRawPointer(msgPtr), MemoryLayout<Msg>.size,
                        UnsafeMutableRawPointer(replyPtr), sizePtr)
                }
            }
        }
        if kr != KERN_SUCCESS {
            // 连接级错误（kext 卸载/睡眠唤醒/权限变化）：作废，下次自动重开
            if kr == kIOReturnNoDevice || kr == kIOReturnNotPermitted || kr == kIOReturnOffline {
                stateLock.lock()
                if conn == c { invalidateConn() }
                stateLock.unlock()
            }
            return FanReply(status: Int32(kr), result: 0)
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

    func setMode(_ mode: String) -> FanReply? {
        guard ["normal", "boost", "custom"].contains(mode) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        switch mode {
        case "normal":
            // 关掉手动门 —— EC 立刻收回 FAN_CTRL/PWM 的管辖权并自行调度
            return ecWrite(EC.ctrl1, UInt32(0x00))
        case "boost":
            // 基准档：开手动门 + BOOST。实测 78% 占空比 / ~5500 RPM
            ecWrite(EC.ctrl1, EC.ctrl1ManualMode)
            return ecWrite(EC.fanCtrl, EC.fanCtrlBoost)
        default:
            ecWrite(EC.ctrl1, EC.ctrl1ManualMode)
            return ecWrite(EC.fanCtrl, UInt32(0x80))
        }
    }

    /// 手动档位 0-7（实测占空比 24% → 53%，转速 2328 → 4278 RPM）
    func setLevel(_ level: Int) -> FanReply? {
        guard (0...7).contains(level) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        ecWrite(EC.ctrl1, EC.ctrl1ManualMode)
        return ecWrite(EC.fanCtrl, UInt32(0x80 | UInt8(level)))
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
    func setModeIndex(_ code: UInt32) -> FanReply? {
        guard [0x11, 0x22, 0x33].contains(code) else { return nil }
        return ecWrite(EC.fanModeIndex, code)
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

    /// 电池充电阈值（0 = 不限制）。实测写 80 → 回读 0xD0（bit7 reached 置位）
    func setChargeThreshold(_ pct: Int) -> FanReply? {
        guard (0...100).contains(pct) else { return nil }
        bizLock.lock()
        defer { bizLock.unlock() }
        return ecWrite(EC.battCharge, UInt32(pct) & UInt32(EC.battChargeMask))
    }

    /// 读电池充电阈值：返回 (百分比, 是否已到达)
    func chargeThreshold() -> [String: Any]? {
        guard let r = ecRead(EC.battCharge), r.ok else { return nil }
        let v = UInt8(r.result & 0xFF)
        return ["percent": Int(v & EC.battChargeMask),
                "reached": (v & EC.battChargeReached) != 0]
    }

    // MARK: - 键盘 Fn 锁 / 触控板 / 风扇行为（qc71_laptop 交叉验证，2026-10-21）
    //
    // 全部是「读-改-写」：只动目标位，不踩掉同一寄存器里的其他位
    // （qc71 驱动的 SET_BIT 同款序列；这几位 qc71 都有 sysfs 读写属性，
    //  官方控制台同路径，语义可直接采信）。

    /// 读-改-写单个位（内部自持锁，可重入）
    private func modifyBit(_ addr: UInt32, _ mask: UInt8, _ on: Bool) -> FanReply? {
        bizLock.lock()
        defer { bizLock.unlock() }
        guard let cur = ecRead(addr), cur.ok else { return nil }
        var v = UInt8(cur.result & 0xFF)
        if on { v |= mask } else { v &= ~mask }
        return ecWrite(addr, v)
    }

    /// Fn 锁 / Fn+Esc / 触控板 / 超频动态温控 / 风扇行为 一次快照（UI 回读用）
    /// 读组不持 bizLock（长连接下物理调用已串行；持锁会放大看门狗超时影响面）
    func miscStatus() -> [String: Any] {
        func byte(_ a: UInt32) -> UInt8 {
            UInt8((ecRead(a)?.result ?? 0) & 0xFF)
        }
        let b1 = byte(EC.biosCtrl1)      // 0x074E
        let ab = byte(EC.apBiosByte)     // 0x07A4
        let c4 = byte(EC.ctrl4)          // 0x07A6
        let b3 = byte(EC.biosCtrl3)      // 0x07A3
        return [
            "fn_lock": (b1 & EC.biosCtrl1FnLock) != 0,
            "fn_lock_switch": (ab & EC.apBiosFnLockSwitch) != 0,
            "touchpad_off": (c4 & EC.ctrl4TouchpadToggleOff) != 0,
            "overboost_dyn_temp_off": (c4 & EC.ctrl4OverboostDynTempOff) != 0,
            "fan_reduced_duty": (b3 & EC.biosCtrl3ReducedDuty) != 0,
            "fan_always_on": (b3 & EC.biosCtrl3AlwaysOn) != 0,
        ]
    }

    /// Fn 锁（0x074E bit4）：开启后 F1-F12 直接触发功能键
    func setFnLock(_ on: Bool) -> FanReply? {
        modifyBit(EC.biosCtrl1, EC.biosCtrl1FnLock, on)
    }

    /// Fn+Esc 快捷键（0x07A4 bit3）：允许用 Fn+Esc 切换 Fn 锁
    func setFnLockSwitch(_ on: Bool) -> FanReply? {
        modifyBit(EC.apBiosByte, EC.apBiosFnLockSwitch, on)
    }

    /// 触控板（0x07A6 bit6，1=禁用）
    func setTouchpad(enabled: Bool) -> FanReply? {
        modifyBit(EC.ctrl4, EC.ctrl4TouchpadToggleOff, !enabled)
    }

    /// 超频动态温控（0x07A6 bit1，1=关闭）
    func setOverboostDynTemp(enabled: Bool) -> FanReply? {
        modifyBit(EC.ctrl4, EC.ctrl4OverboostDynTempOff, !enabled)
    }

    /// 风扇降低占空比（0x07A3 bit5）：更安静
    func setFanReducedDuty(_ on: Bool) -> FanReply? {
        modifyBit(EC.biosCtrl3, EC.biosCtrl3ReducedDuty, on)
    }

    /// 风扇常转（0x07A3 bit6）：低负载也不停转
    func setFanAlwaysOn(_ on: Bool) -> FanReply? {
        modifyBit(EC.biosCtrl3, EC.biosCtrl3AlwaysOn, on)
    }

    // MARK: - 海岸灯

    /// 海岸灯状态（读组无锁，v2.5.3.1）
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
        return ["ctrl": ctrl, "mode": mode,
                "rgb": [r, g, b],
                "hex": String(format: "%02x%02x%02x", r, g, b)]
    }

    @discardableResult
    func lightbarSet(_ rgb: [Int], ctrl: UInt8) -> [String: Any]? {
        let r = UInt8(max(0, min(255, rgb.count > 0 ? rgb[0] : 0)))
        let g = UInt8(max(0, min(255, rgb.count > 1 ? rgb[1] : 0)))
        let b = UInt8(max(0, min(255, rgb.count > 2 ? rgb[2] : 0)))
        let c = ctrl & EC.lightbarWritableMask
        bizLock.lock()
        ecWrite(EC.lightbarCtrl, UInt32(c))
        ecWrite(EC.lightbarRed, UInt32(r))
        ecWrite(EC.lightbarGreen, UInt32(g))
        ecWrite(EC.lightbarBlue, UInt32(b))
        bizLock.unlock()
        return lightbarStatus()
    }

    /// 一次性探测本机 EC 能力位（读组无锁，v2.5.3.1）
    func ecProbe() -> [String: Any] {
        func rb(_ a: UInt32) -> UInt8 {
            UInt8((ecRead(a)?.result ?? 0) & 0xFF)
        }
        let s1 = rb(EC.support1), s2 = rb(EC.support2), s5 = rb(EC.support5)
        return [
            "proj_id": rb(EC.projID),
            "support_fan_boost": (s1 & 0x80) != 0,
            "support_lightbar": (s1 & 0x40) != 0,
            "support_silent_mode": (s2 & 0x01) != 0,
            "support_fan_turbo": (s5 & 0x10) != 0,
            "pl1": Int(rb(EC.pl1)) | Int(rb(EC.pl1 + 1)) << 8,
            "pl2": Int(rb(EC.pl2)) | Int(rb(EC.pl2 + 1)) << 8,
            "turbo": Int((rb(EC.ctrl2) >> 2) & 3),
            "modeindex": rb(EC.fanModeIndex),
            "charge": Int(rb(EC.battCharge) & EC.battChargeMask),
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

    /// 风扇/温度/占空比状态（整组快照，避免与写入交错）
    /// 读组不持 bizLock（v2.5.3.1：长连接下每个物理调用已串行，读组无锁化）
    func fanStatus() -> [String: Any] {

        func byteOf(_ r: FanReply?) -> UInt8 {
            UInt8((r?.result ?? 0) & 0xFF)
        }
        func rpmOf(_ r: FanReply?) -> Int {
            // qc71: rpm = b1 << 8 | b2（大端）
            let v = r?.result ?? 0
            return Int((v & 0xFF) << 8 | (v >> 8) & 0xFF)
        }

        let rpm1 = ecRead(EC.fanRPM1)
        let rpm2 = ecRead(EC.fanRPM2)
        let t1 = ecRead(EC.fanTemp1)
        let t2 = ecRead(EC.fanTemp2)
        let p1 = ecRead(EC.fanPWM1)
        let p2 = ecRead(EC.fanPWM2)
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

        return [
            "rpm_cpu": rpmOf(rpm1),
            "rpm_gpu": rpmOf(rpm2),
            "temp_cpu": byteOf(t1),
            "temp_gpu": byteOf(t2),
            "pwm_cpu_pct": Int((Double(byteOf(p1)) * 100 / 255).rounded()),
            "pwm_gpu_pct": Int((Double(byteOf(p2)) * 100 / 255).rounded()),
            "fan_ctrl": v,
            "ctrl_1": byteOf(ctrl1),
            "manual": manual,
            "actual": actual,
            "actual_level": actualLevel,
            "profile": prof,
            "modeindex": byteOf(mi),
            "mode": mode.isEmpty ? "AUTO" : mode.joined(separator: " | "),
        ]
    }
}

// MARK: - 状态持久化（重启后 EC 回默认，服务启动时自动恢复）

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
        } else {
            r = fc.setMode(st["mode"] as? String ?? "normal")
        }
        return ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(), "state": st]
    }
}
