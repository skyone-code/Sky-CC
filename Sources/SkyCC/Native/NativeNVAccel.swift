import Foundation
import IOKit

/// 独显（NVIDIA）利用率 —— 直接读 NVAccel 发布的 `PerformanceStatistics`。
///
/// 背景（2026-10-28 换实现）：以前是**我们自己**去开 RM 通道，
///   IOServiceOpen("NVAccel") → SEL_ESC(1) → RM_ALLOC ROOT_CLIENT(0x41) /
///   NV01_DEVICE_0(0x80) / NV20_SUBDEVICE_0(0x2080) → RM_CONTROL 0x2080_2096
///   (NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2)，一次要填 72 条样本。
/// 那条路又长又脆：样本是 72 秒的环、`reported` 驱动不填、同步读会卡界面，
/// 于是被迫加后台线程 + 72 点环 + 粘性位 + 按需节流一整套。
///
/// **驱动 2.6.3（nullmoth/nvidia-macos-driver）把这件事做进内核了**：
///   `kexts/NVRM/accel/nvrm-accel.cpp` 起了一条独立 IOWorkLoop + IOTimerEventSource，
///   每秒通过 platform function `NVRMGpuUtilization` 向 NVRM 要一份
///   `NVRMUtilization{version, gr, fb, nvenc, nvdec, timestamp}`（ABI 版本 1，
///   单位是百分比 ×100），再用 250ms 的统计发布定时器把结果写进
///   NVAccel 的 `PerformanceStatistics`，**已经四舍五入成整数百分比**：
///
///     "GPU Core Utilization %" / "Device Utilization %"  ← gr   （同一个值，两份键）
///     "GPU Memory Utilization %"                          ← fb   （显存**带宽**占用，不是显存用量）
///     "GPU Video Engine Utilization %"                    ← nvenc
///     "GPU Video Decode Utilization %"                    ← nvdec
///
///   关键语义：查询失败、或样本超过 5 秒没更新时，驱动是 `removeObject` 把键**删掉**，
///   而不是写 0 ——「缺遥测 ≠ 空闲」。所以本文件用「键在不在」判 `reported`，
///   而不是拿 0 去猜。
///
/// 于是用户态这一侧只剩一件事：读 IORegistry。不开连接、不调 RM、不需要 root、
/// 不占内核锁；一次属性读是微秒级，可以放心在任意线程同步做（不再需要后台队列）。
///
/// 唯一丢掉的能力是**历史**：驱动只发布瞬时值，没有 72 条环了。
/// 所以 5 秒 / 15 秒均值改成**本地按拍滑动平均**（见 `Tick` / `ring`）：
/// 驱动本来就是 1 秒一拍，我们按 1 秒采样，窗口按时间过滤，抖动容忍到 0.85 秒。
enum NVAccelUtil {

    // MARK: 驱动发布的键名

    /// gr 有两份键：`GPU Core Utilization %` 是 2.6.3 起的正式名，
    /// `Device Utilization %` 是苹果 IOAccelerator 的通用名（驱动也一起写，
    /// 这样 iStat / Stats 这类通用面板能直接认出 N 卡）。优先取前者。
    private static let keyGrCore = "GPU Core Utilization %"
    private static let keyGrDevice = "Device Utilization %"
    private static let keyFb = "GPU Memory Utilization %"
    private static let keyEnc = "GPU Video Engine Utilization %"
    private static let keyDec = "GPU Video Decode Utilization %"

    // 温度。驱动现在同时发布两个温度键：
    //   `GPU Core Temperature(C)` —— TSENS 读到的 GPU 核心温度（更准，本机实测比
    //     旧的 `Temperature(C)` 高约 12℃：58 vs 46，前者才跟满载行为对得上）。
    //   `Temperature(C)`          —— 旧键（PR #323 时代），保留作兜底。
    // 优先取前者；拿不到再退回后者（老驱动只发后者）。
    private static let keyTempCore = "GPU Core Temperature(C)"
    private static let keyTemp     = "Temperature(C)"

    // ── 驱动新发布的其它传感器键（nmdrv 驱动把整组遥测都写进 PerformanceStatistics）──
    // 这些键以前我们没读，新接口把它们全部接进来。
    private static let keyMemTemp    = "GPU Memory Temperature(C)"   // 显存温度
    private static let keyCoreClock  = "GPU Core Clock(MHz)"         // 核心频率
    private static let keyMemClock   = "GPU Memory Clock(MHz)"       // 显存频率
    private static let keyVideoClock = "GPU Video Clock(MHz)"        // 视频时钟
    private static let keyCoreClockMax = "GPU Core Clock Max(MHz)"   // 核心频率上限
    private static let keyPState     = "GPU PState"                  // 当前 P 级（位掩码）
    private static let keyPowerLimit = "GPU Power Limit(W)"          // 功耗墙（W）
    private static let keyThrottle   = "GPU Throttle Mask"           // 降频原因位掩码

    // ── 驱动 2.7.2 遥测补丁新增（nvrm-telemetry-2.7.2）──
    //
    // 这些键以前驱动不发布，是补丁从 RM 的 RUSD 共享块和 BUS_GET_INFO_V2 里读出来的。
    // 老驱动上它们全部不存在 —— 取不到就是 NSNull，界面显示「—」，不是 bug。
    //
    // 功耗两个键（2026-11-08 更正旧注释）：本机（TU104 Max-Q）固件的 RUSD 功率块
    // **只填瞬时采样** —— `avg` 分区的时间戳是 `RUSD_TIMESTAMP_INVALID`(=0)，
    // 按 cl00de.h 的约定「时间戳无效 = 该数据不可用」，所以固件层没有平均值可分，
    // `GPU Power(W)` 这个固件平均分区键在本机永远不存在。
    //
    // 现在这个平均值是**驱动自己算的**（提交「publish the readings under the names
    // the monitoring tools read, and average the power ourselves」）：
    //   1 Hz 采瞬时值 → 8 拍环形缓冲 → `GPU Power Avg(W)` 报环均值（≈8 秒窗口），
    //   采样断流就清窗（宁可缺键，不拿旧值续命）。同一份均值还用
    //   `Total Power(W)` 这个苹果惯例名再发一次，给 iStat / Stats 之类通用面板读。
    //
    // 所以分工：
    //   `GPU Power Avg(W)`     ← 8 拍环均值，**界面主数字用它**（1 秒刷新下不闪）
    //   `GPU Power Instant(W)` ← 固件这一拍的瞬时值，空闲 6 W / 满载 115 W 硬台阶，
    //                            只适合看峰值或塞 tooltip
    private static let keyPowerAvg     = "GPU Power Avg(W)"          // 8 拍环均值（W）
    private static let keyPowerInstant = "GPU Power Instant(W)"      // 瞬时功耗（W）

    // PCIe 链路：cur 是当前速率，max 是插槽与卡协商出的上限。
    // 掉到 Gen1 / x8 时 cur 会小于 max，正好用来看链路有没有降级。
    private static let keyPcieGen      = "GPU PCIe Generation"
    private static let keyPcieWidth    = "GPU PCIe Width"
    private static let keyPcieMaxGen   = "GPU PCIe Max Generation"
    private static let keyPcieMaxWidth = "GPU PCIe Max Width"

    // 另外三个引擎：JPEG 编解码、光流加速器（TU104 没有 OFA，键在但恒 0）、显存控制器。
    private static let keyJpg     = "GPU NVJPG Utilization %"
    private static let keyOfa     = "GPU NVOFA Utilization %"
    private static let keyMemCtrl = "GPU Memory Controller Utilization %"

    /// 显存占用：驱动遥测 v3 从 RM 的 FB_GET_INFO_V2 拿的堆占用
    /// （"GPU VRAM Used(Bytes)" = heap - free，"GPU VRAM Total(Bytes)" = 整卡 8 GB）。
    /// 注意别被 IOAccelerator 的 gartUsedBytes 带偏 —— 那是 Intel 核显那条的键，
    /// NVAccel 的 PerformanceStatistics 里从来没有它。
    private static let keyVramUsed = "GPU VRAM Used(Bytes)"
    private static let keyVramTotal = "GPU VRAM Total(Bytes)"

    /// PCIe 链路错误计数（补丁从 RUSD `pciBusData` 读的 8 项）。
    /// 全部是**自开机以来的累计值**，不是速率 —— 判断链路健不健康看它有没有增长。
    private static let pcieErrorKeys: [(key: String, name: String)] = [
        ("GPU PCIe Line Code Errors",     "line_code"),
        ("GPU PCIe CRC Errors",           "crc"),
        ("GPU PCIe NAKs",                 "nak"),
        ("GPU PCIe L0s Exits",            "l0s"),
        ("GPU PCIe Correctable Errors",   "correctable"),
        ("GPU PCIe Nonfatal Errors",      "nonfatal"),
        ("GPU PCIe Fatal Errors",         "fatal"),
        ("GPU PCIe Unsupported Requests", "unsupported"),
    ]

    // MARK: 本地滑动平均窗口

    /// 一拍采样（驱动 1 秒发布一次，这里也按 1 秒记一条）
    private struct Tick {
        var t: Double          // Date().timeIntervalSince1970
        var gr: Double
        var fb: Double
        var enc: Double
        var dec: Double
    }

    /// 两次入环的最小间隔：比 1 秒略小，容忍轮询抖动（UI 1 秒一轮会漂几十毫秒，
    /// 卡死 1.0 会隔拍丢样本，均值窗口就变成 2 秒一格）。
    private static let appendInterval: Double = 0.85
    /// 环最多留 24 拍（≈24 秒），够 15 秒窗口 + 一点冗余
    private static let ringCap = 24
    /// 超过这个年龄的拍直接丢（进程被挂起过、机器睡眠过）
    private static let ringMaxAge: Double = 20
    /// 对外声明的窗口长度（秒），写进 payload 供界面显示
    private static let windowSeconds: Double = 15

    private static let stateLock = NSLock()
    private static var ring: [Tick] = []

    // MARK: - 对外

    /// 返回（字段名沿用旧版，界面与 mcutil 不用改解析）：
    ///   available       —— NVAccel 服务在不在（驱动没加载 / 版本太旧时 false）
    ///   reported        —— 驱动这一拍有没有发布利用率。**不是粘性位**：
    ///                      驱动撤键就是 false，界面显示「—」而不是 0%。
    ///   gr/fb/enc/dec_pct —— 瞬时值，**整数百分比**（驱动已四舍五入）
    ///   gr_avg5_pct / gr_avg15_pct —— GR 最近 5 / 15 秒的本地滑动均值（可能是小数）
    ///   fb/enc/dec_avg5_pct        —— 另外三个引擎的 5 秒均值（口径与 GR 一致）
    ///   samples / window_s         —— 15 秒窗口里实际有几拍（排障用）
    ///   source                     —— 数据来源标识
    ///
    /// 注意：读 IORegistry 是同步的、微秒级，且不带任何内核锁，
    /// 所以这里**不再**做「非阻塞返回上一拍 + 后台队列刷新」那一套。
    static func snapshot() -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }

        var out: [String: Any] = [
            "available": false, "reported": false,
            "gr_pct": 0.0, "fb_pct": 0.0, "enc_pct": 0.0, "dec_pct": 0.0,
            "gr_avg5_pct": 0.0, "gr_avg15_pct": 0.0,
            "fb_avg5_pct": 0.0, "enc_avg5_pct": 0.0, "dec_avg5_pct": 0.0,
            "samples": 0, "window_s": windowSeconds,
            "source": "NVAccel.PerformanceStatistics",
        ]

        guard let svc = service() else {
            ring.removeAll()      // 驱动没了：历史一律作废，别拿旧值续命
            return out
        }
        defer { IOObjectRelease(svc) }
        out["available"] = true

        guard let stats = statsDict(svc) else {
            ring.removeAll()
            return out
        }
        // 键不在 = 这一拍没有有效遥测（驱动查询失败 / 样本超过 5 秒没更新）
        guard let gr = percent(stats, [keyGrCore, keyGrDevice]) else {
            ring.removeAll()
            return out
        }

        let fb = percent(stats, [keyFb]) ?? 0
        let enc = percent(stats, [keyEnc]) ?? 0
        let dec = percent(stats, [keyDec]) ?? 0
        let now = Date().timeIntervalSince1970

        // 入环（同一拍内被重复调用时不重复记 —— 比如 /api/all 与 /api/snapshot 撞一起）
        if let last = ring.last, now - last.t < appendInterval {
            // 不记新拍，但把最新值覆盖到这一拍上：界面拿到的瞬时值永远是最新的
            ring[ring.count - 1] = Tick(t: last.t, gr: gr, fb: fb, enc: enc, dec: dec)
        } else {
            ring.append(Tick(t: now, gr: gr, fb: fb, enc: enc, dec: dec))
        }
        if ring.count > ringCap { ring.removeFirst(ring.count - ringCap) }
        ring.removeAll { now - $0.t > ringMaxAge }

        out["reported"] = true
        out["gr_pct"] = gr
        out["fb_pct"] = fb
        out["enc_pct"] = enc
        out["dec_pct"] = dec

        // 顺带把驱动新发布的整组传感器一起带出去（显存温度 / 频率 / P 级 /
        // 功耗墙 / 降频掩码），界面在 GPU 卡片里展示。一次 IORegistry 读已经付了，
        // 多读几个键不花额外代价。
        out["sensors"] = sensorDetail()

        /// 窗口内均值。窗口里一拍都没有时（刚启动、或进程刚从长睡眠醒来）
        /// 退回当前拍 —— 宁可给一个会跳的瞬时值，也不要给 0。
        func average(_ window: Double, _ pick: (Tick) -> Double) -> Double {
            let take = ring.filter { now - $0.t <= window }
            guard !take.isEmpty else { return pick(ring.last!) }
            var sum = 0.0
            for t in take { sum += pick(t) }
            return sum / Double(take.count)
        }

        out["gr_avg5_pct"] = average(5) { $0.gr }
        out["gr_avg15_pct"] = average(windowSeconds) { $0.gr }
        out["fb_avg5_pct"] = average(5) { $0.fb }
        out["enc_avg5_pct"] = average(5) { $0.enc }
        out["dec_avg5_pct"] = average(5) { $0.dec }
        out["samples"] = ring.filter { now - $0.t <= windowSeconds }.count
        return out
    }

    /// 预热：让 helper 启动后的第一份 `/api/snapshot` 就带上真值。
    /// 现在读 IORegistry 不花钱，这里其实就是「先采一拍把环填上」，
    /// 免得第一个 5 秒均值窗口里只有一条样本。
    static func warmUp() {
        _ = snapshot()
    }

    /// 阻塞版，语义与 `snapshot()` 相同（保留这个名字是为了 `mcutil dgpu` 与旧调用点）。
    static func sampleOnce() -> [String: Any] {
        snapshot()
    }

    // MARK: - GPU 核心温度（2.7.6 起，替代 EC 0x044F）

    /// 读 NVAccel 自己上报的 GPU 核心温度（摄氏度）。
    ///
    /// 来源：nullmoth/nvidia-macos-driver PR #323（GeekAudio）——
    /// 驱动侧用 250ms 定时器读 TSENS(0x20460)，把摄氏度写进 NVAccel 服务的
    /// `PerformanceStatistics`（read-copy-modify-write，不动其他键）。
    /// 这就是 iStat 读 GPU 面板走的那条路径。
    ///
    /// 2026-11-03 起优先读 `GPU Core Temperature(C)`（驱动新发布的、更准的核心温度键，
    /// 本机空闲实测 44℃（2026-11-08，BOOST=0 之后；此前 58℃），而旧 `Temperature(C)`
    /// 只有 32℃），拿不到再退回旧键（老驱动只发后者）。范围校验仍按 PR 的 1..125℃ 处理，
    /// 不看 TSENS valid 位（GSP-RM 下恒为 0）。
    ///
    /// 为什么换掉 EC 0x044F：那个寄存器读的是「GPU 附近」的板级环境温度，
    /// 满载时几乎不动（本机实测 CPU 64→89℃ 时它只有 60→62℃），拿它当独显温度
    /// 会同时误导显示和风扇曲线。核心温度只有 TSENS 给得准。
    static func coreTemperatureC() -> Int? {
        guard let svc = service() else { return nil }
        defer { IOObjectRelease(svc) }
        guard let stats = statsDict(svc) else { return nil }
        for k in [keyTempCore, keyTemp] {
            if let n = stats[k] as? NSNumber {
                let c = n.intValue
                if c >= 1 && c <= 125 { return c }
            }
        }
        return nil
    }

    /// 核心边缘温度（`Temperature(C)`）。
    ///
    /// 2026-11-07（用户要求）：GPU 卡右上角要同时显示「核心」和「核心边缘」两个温度。
    /// 这两个键的来源不同，不是同一个数的两种写法：
    /// - `GPU Core Temperature(C)` ← 驱动遥测补丁从 RUSD 的 thermal instruction list 读的
    ///   固件温度，本机空闲实测 **44℃**（2026-11-08，BOOST=0 之后；此前 60℃），
    ///   随负载变化明显；
    /// - `Temperature(C)`          ← NVAccel 自己每 250 ms 直读 TSENS `0x20460`
    ///   （和 nouveau 的 gp100_temp_get 同一个寄存器），本机空闲实测 **32℃**。
    ///   相差 12℃ 不是误差，是两个不同测点。
    ///
    /// `coreTemperatureC()` 把后者当兜底；这里单独取出来，两者都有时并排显示。
    static func edgeTemperatureC() -> Int? {
        guard let svc = service() else { return nil }
        defer { IOObjectRelease(svc) }
        guard let stats = statsDict(svc) else { return nil }
        guard let n = stats[keyTemp] as? NSNumber else { return nil }
        let c = n.intValue
        return (c >= 1 && c <= 125) ? c : nil
    }

    /// 读取驱动新发布的整组传感器（显存温度 / 频率 / P 级 / 功耗墙 / 降频掩码）。
    ///
    /// 这些键是 nmdrv 驱动写进 NVAccel 节点 PerformanceStatistics 的遥测，
    /// 用户态只需一次 IORegistry 属性读。键不存在时对应字段为 NSNull（界面显示「—」）。
    /// 返回结构（字段都可能是 NSNull）：
    ///   mem_temp_c   —— 显存温度（℃）
    ///   core_mhz     —— 核心频率
    ///   mem_mhz      —— 显存频率
    ///   video_mhz    —— 视频时钟
    ///   core_max_mhz —— 核心频率上限
    ///   pstate       —— 当前 P 级（位掩码，0x1=P0 满速 … 0x1000=P12 最低）
    ///   power_limit_w—— 功耗墙（W）
    ///   power_avg_w  —— 功耗（W），驱动自算的 8 拍环均值，界面主数字用这个
    ///   power_instant_w —— 功耗（W），固件瞬时采样
    ///   throttle_mask—— 降频原因位掩码（0=无降频）
    static func sensorDetail() -> [String: Any] {
        guard let svc = service() else { return [:] }
        defer { IOObjectRelease(svc) }
        guard let stats = statsDict(svc) else { return [:] }

        func num(_ k: String) -> Any {
            (stats[k] as? NSNumber).map { $0 as Any } ?? NSNull()
        }
        return [
            "mem_temp_c":    num(keyMemTemp),
            "core_mhz":      num(keyCoreClock),
            "mem_mhz":       num(keyMemClock),
            "video_mhz":     num(keyVideoClock),
            "core_max_mhz":  num(keyCoreClockMax),
            "pstate":        num(keyPState),
            "power_limit_w": num(keyPowerLimit),
            "throttle_mask": num(keyThrottle),

            // 2.7.2 补丁新增
            "power_avg_w":     num(keyPowerAvg),
            "power_instant_w": num(keyPowerInstant),
            "pcie_gen":        num(keyPcieGen),
            "pcie_width":      num(keyPcieWidth),
            "pcie_max_gen":    num(keyPcieMaxGen),
            "pcie_max_width":  num(keyPcieMaxWidth),
            "pcie_errors":     pcieErrors(stats),
            "mem_ctrl_pct":    num(keyMemCtrl),
            "nvjpg_pct":       num(keyJpg),
            "nvofa_pct":       num(keyOfa),

            // 显存占用（驱动遥测 v3，FB_GET_INFO_V2 口径，2026-11-05 接入）
            "vram_used_bytes": num(keyVramUsed),
            "vram_size_bytes": num(keyVramTotal),
        ]
    }

    /// PCIe 错误计数（只放存在的键）。一个键都没有时返回空字典 ——
    /// 与「全 0」区分开：空 = 老驱动不发布这一组，全 0 = 链路干净。
    private static func pcieErrors(_ stats: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, name) in pcieErrorKeys {
            if let n = stats[key] as? NSNumber { out[name] = n.intValue }
        }
        return out
    }

    // MARK: - 底层

    /// NVAccel 是发布方；NVRM 只是兜底（老版本 / 半加载状态）。
    private static func service() -> io_service_t? {
        for name in ["NVAccel", "NVRM"] {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if svc != 0 { return svc }
        }
        return nil
    }

    private static func statsDict(_ svc: io_service_t) -> [String: Any]? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return unmanaged.takeRetainedValue() as? [String: Any]
    }

    /// 取一个整数百分比键，按候选顺序找第一个存在的；值做 0...100 钳位
    /// （驱动侧已经校验过 ≤10000 的 ×100 原始值，这里只防脏数据）。
    private static func percent(_ stats: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            if let n = stats[k] as? NSNumber {
                return min(100, max(0, n.doubleValue))
            }
        }
        return nil
    }
}
