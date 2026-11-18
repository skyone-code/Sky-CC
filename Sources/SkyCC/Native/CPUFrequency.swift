//
//  CPUFrequency.swift
//  Sky CC —— CPU 实时运行频率（APERF / MPERF）
//
//  为什么需要它：macOS 的 sysctl 只暴露 `hw.cpufrequency`，那是**标称基频**
//  （i7-9750H 恒为 2600 MHz），满载也是这个数，看起来像卡住了。真实运行频率
//  必须从 MSR 读：
//      IA32_APERF (0xE8)  按「实际频率」计数
//      IA32_MPERF (0xE7)  按「基频」计数
//  两个窗口之间的比值就是睿频倍数：
//      真实频率 = 基频 × ΔAPERF / ΔMPERF
//
//  2026-11-18 实测修正（状态栏频率恒 2.60GHz 的根因）：rdmsr64 读的是
//  **执行那次的 CPU** 的计数器，而 user client 调用线程每次可能落在不同核，
//  两次读数来自不同核的绝对值，ΔMPERF 达 1e11 量级（墙钟上界的 ~100 倍），
//  同核校验拒掉全部窗口 → 永远回落 sysctl 假频率。
//  所以主路改读 **IA32_PERF_STATUS (0x198) bits 15:8**：当前核的实时倍频
//  （×100 MHz），单次读数即真频率，无窗口、无同核约束；线程迁移反而顺带
//  采样到不同核。APERF/MPERF 比值保留为校验通过时的精化路径。
//
//  ⚠ 若保留 APERF/MPERF 窗口判定（现在只作辅路），仍要遵守：
//
//  1. **必须是同一个核**。APERF/MPERF 是每核 MSR，而且核心被停核时两个计数器
//     一起停。线程在两次采样之间换核时，两次读到的绝对值属于不同计数器，差值
//     可能是「停核时长」量级（实测 ±1e11），相减还会变成负数（UInt64 下溢成
//     1.8e19）。判同核不能看增量大小，要用**墙钟上界**：
//         同核时 ΔMPERF 必然 ≤ 经过时间 × 基频
//     因为 MPERF 按基频计数，深度 C-state 只会让它更小。
//
//  2. **不能给 ΔMPERF 设下界**。核心大部分时间在 C-state 时 ΔMPERF 远小于
//     墙钟值，但比值依然有效（两个计数器一起停）。设下界会把合法样本全丢掉。
//
//  3. **比值 < 1 是合法的**。SpeedStep 会让核心降到基频以下（最低 800 MHz
//     ≈ 0.31×），不能把「小于 1」当成错误。
//

import Foundation
import IOKit

final class CPUFrequency {

    static let shared = CPUFrequency()

    // MARK: - 可调参数

    /// 保留几个有效读数取中位（抹掉单次抖动，又不至于拖慢响应）
    private let historySize = 5
    /// 短于这个窗口就先不消费（不更新基线），等下一次攒够再算。
    /// 0.4s 在 2.6GHz 上是 ~1e9 个 MPERF 计数，量化误差可以忽略。
    private let minWindowSec = 0.4
    /// 比值合理区间。0.2× ≈ 520 MHz，6× ≈ 15.6 GHz，超出必然是坏样本
    private let ratioRange: ClosedRange<Double> = 0.2...6.0
    /// 瞬时倍频合理区间（MHz）：i7-9750H 最低 P8 = 800 MHz，睿频单核 4.1 GHz
    private let instantRange: ClosedRange<Double> = 400.0...4_500.0
    /// 有效读数最多保鲜这么久，超过就当「拿不到」（界面显示 — 而不是冻结的数字）
    private let freshnessSec: TimeInterval = 5

    // MARK: - 状态（全部由 lock 保护）

    private let lock = NSLock()
    private var conn: io_connect_t = 0
    private var prevAperf: UInt64 = 0
    private var prevMperf: UInt64 = 0
    private var prevTicks: UInt64 = 0
    private var havePrev = false
    private var recent: [Double] = []
    private var lastMHz: Double = 0
    private var lastGoodAt: TimeInterval = 0
    // MARK: - 常量

    /// 标称基频（MHz）。拿不到就是 0，此时整个功能不可用。
    let baseMHz: Double
    private let tbNumer: Double
    private let tbDenom: Double

    private init() {
        var hz: Int64 = 0
        var len = MemoryLayout<Int64>.size
        if sysctlbyname("hw.cpufrequency", &hz, &len, nil, 0) != 0 || hz <= 0 {
            hz = 0
        }
        baseMHz = Double(hz) / 1_000_000

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tbNumer = Double(tb.numer)
        tbDenom = Double(tb.denom > 0 ? tb.denom : 1)
    }

    /// kext 是否提供 MSR 采样（连得上 user client）
    var isAvailable: Bool {
        guard baseMHz > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return ensureConn() != nil
    }

    // MARK: - 采样

    /// 采样一次，返回当前频率估计（MHz）。
    ///
    /// 采样点本身就是「上一次读数」，所以第一次调用只建立基线、返回 nil；
    /// 之后每次调用都用「上次 → 这次」的窗口算一个比值。
    /// 遇到跨核/坏样本时返回最近 5 秒内的旧值，没有旧值就返回 nil
    ///（调用方此时应回落到标称基频）。
    func sample() -> Double? {
        guard baseMHz > 0 else { return nil }

        lock.lock(); defer { lock.unlock() }

        let now = mach_absolute_time()
        guard let c = ensureConn(), let s = readSample(c) else {
            // 连接或调用失败：作废连接让下次重开，基线也要清
            if conn != 0 {
                // 不调 IOServiceClose —— 与 FanControl.invalidateConn 同样的理由：
                // 对可能还挂着调用的连接 close 有阻塞风险，宁可漏一个 user client
                conn = 0
            }
            havePrev = false
            return freshValueLocked()
        }

        // —— 主路：IA32_PERF_STATUS bits 15:8 = 当前核实时倍频（×100 MHz）——
        // 单次读数即真频率，无线窗口、无同核约束；调用线程迁移正好轮询不同核。
        // （深度 C-state 的核会读到最低倍频，中位滤波抹平单次抖动。）
        let mult = Double((s.perfStatus >> 8) & 0xFF)
        let instant = mult * 100.0
        if instantRange.contains(instant) {
            recent.append(instant)
            if recent.count > historySize { recent.removeFirst() }
            lastMHz = recent.sorted()[recent.count / 2]
            lastGoodAt = Date().timeIntervalSince1970
        }

        // —— 辅路：APERF/MPERF 窗口比值（仅同核窗口有效，见文件头注释）——
        // 有效时它比瞬时值平滑，覆盖 lastMHz。
        let prevA = prevAperf, prevM = prevMperf, prevT = prevTicks
        let hadBaseline = havePrev
        let elapsed = Double(now &- prevT) * tbNumer / tbDenom / 1e9

        // 窗口太短（有别的调用方插进来）就先不消费：基线不动，等下一个更长的窗口。
        if hadBaseline, elapsed < minWindowSec {
            return freshValueLocked()
        }

        prevAperf = s.aperf; prevMperf = s.mperf; prevTicks = now; havePrev = true

        guard hadBaseline else { return freshValueLocked() }

        let dA = Int64(bitPattern: s.aperf &- prevA)
        let dM = Int64(bitPattern: s.mperf &- prevM)
        let cap = elapsed * baseMHz * 1.1        // 同核时 ΔMPERF 的上界

        guard dA > 0, dM > 0, Double(dM) <= cap else {
            // 跨核窗口（调用线程换核了）：丢弃即可，主路瞬时值已经接管
            return freshValueLocked()
        }

        let ratio = Double(dA) / Double(dM)
        guard ratioRange.contains(ratio) else {
            return freshValueLocked()
        }

        lastMHz = baseMHz * ratio
        lastGoodAt = Date().timeIntervalSince1970
        return lastMHz
    }

    private func freshValueLocked() -> Double? {
        guard lastMHz > 0,
              Date().timeIntervalSince1970 - lastGoodAt < freshnessSec else { return nil }
        return lastMHz
    }

    // MARK: - 连接

    private func ensureConn() -> io_connect_t? {
        if conn != 0 { return conn }
        // 只有自维护的 SkyCCEC 提供 selector 1；旧 TongfangFan 没有 MSR
        guard let matching = IOServiceMatching("SkyCCECDriver") else { return nil }
        let svc = IOServiceGetMatchingService(0, matching)
        guard svc != 0 else {
            trace("cpufreq: 没有 SkyCCECDriver 实例")
            return nil
        }
        defer { IOObjectRelease(svc) }

        var c: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &c) == KERN_SUCCESS else {
            trace("cpufreq: IOServiceOpen 失败")
            return nil
        }
        conn = c
        return c
    }

    private struct MSRSample {
        var aperf: UInt64
        var mperf: UInt64
        var perfStatus: UInt64
    }

    private func readSample(_ c: io_connect_t) -> MSRSample? {
        var buf = [UInt8](repeating: 0, count: 24)
        var size = buf.count
        let kr = buf.withUnsafeMutableBytes { bp in
            IOConnectCallStructMethod(c, 1, nil, 0, bp.baseAddress!, &size)
        }
        guard kr == KERN_SUCCESS, size >= 24 else { return nil }
        return buf.withUnsafeBytes { raw in
            MSRSample(aperf: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                      mperf: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                      perfStatus: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        }
    }
}
