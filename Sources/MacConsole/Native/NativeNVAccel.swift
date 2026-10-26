import Foundation
import IOKit

/// 独显（NVIDIA）利用率 —— 走 RM（Resource Manager）控制接口。
///
/// 背景：macOS 侧没有任何公开属性给出 NVIDIA 的 GPU 占用率。
/// exelban/Stats 读的是 `IOAccelerator.PerformanceStatistics["Device Utilization %"]`，
/// 但那张表是给驱动自己填的，N 卡驱动（nullmoth/nvidia-macos-driver）不填这一项，
/// 所以核显有值、独显永远是空。要拿到独显数字只能进 RM：
///
///   IOServiceOpen("NVAccel", type 0x4E560000)
///     → SEL_ESC(1) 通道
///     → NV_ESC_RM_ALLOC 建 NV01_ROOT_CLIENT(0x41)
///     → NV01_DEVICE_0(0x80) / NV0080_ALLOC
///     → NV20_SUBDEVICE_0(0x2080) / NV2080_ALLOC
///     → NV_ESC_RM_CONTROL 发 0x20802096
///        (NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2)
///
/// 协议来源：issue nullmoth/nvidia-macos-driver#324 里 GeekAudio 贴的 nvstatd.c，
/// 与 open-gpu-kernel-modules 的 ctrl id 一致。原作者的守护进程用 root 跑，
/// 本机实测**普通用户也能打开并拿到完整样本**（见坑 #63），所以不需要提权。
///
/// 这里所有结构体都用「原始字节 + 显式偏移」表达，不用 Swift struct：
/// Swift 的对齐规则和 C 在 `uint8_t type` 后面那道 3 字节 padding 上容易算错，
/// 而偏移错 4 字节就会读到别的字段且不报错——宁可按字节算，一眼能核对。
enum NVAccelUtil {

    // MARK: 常量

    private static let selEsc: UInt32 = 1
    private static let escRmAlloc: UInt32 = 0x2B
    private static let escRmControl: UInt32 = 0x2A
    private static let escRmFree: UInt32 = 0x29

    private static let clsRootClient: UInt32 = 0x41
    private static let clsDevice0: UInt32 = 0x80
    private static let clsSubdevice0: UInt32 = 0x2080

    private static let cmdPerfmonUtilV2: UInt32 = 0x2080_2096
    private static let sampleTypePerfmonUtil: UInt8 = 2
    private static let sampleCount = 72
    private static let sampleSize = 776          // sizeof(GPUMON_PERFMON_UTIL_SAMPLE)
    private static let paramsHeader = 16         // type/bufSize/count/tracker
    private static var paramsSize: Int { paramsHeader + sampleSize * sampleCount }   // 55888

    /// 样本内各引擎相对偏移（6 个引擎各 128 字节，紧接 8 字节 timeStamp）
    private static let offFb = 8
    private static let offGr = 8 + 128
    private static let offEnc = 8 + 256
    private static let offDec = 8 + 384

    // MARK: 状态

    /// 两条线程边界，别混：
    ///   · IOKit 那一套（conn/hClient/hSubdev/svcCache/buf）**只在 `queue` 上动**，串行队列本身就是锁；
    ///   · 跨线程读的只有下面 `latest/latestAt/refreshing/wanted`，由 `stateLock` 保护。
    /// 这样 `snapshot()` 不再在调用方线程做 IOKit —— 它是 UI 线程调的，GPU 掉到低功耗时
    /// 一次 RM 调用能到几十毫秒，同步做会蹭到界面。
    private static let stateLock = NSLock()
    private static let queue = DispatchQueue(label: "com.macconsole.nvutil", qos: .utility)

    private static var conn: io_connect_t = 0
    private static var hClient: UInt32 = 0
    private static var hDevice: UInt32 = 0
    private static var hSubdev: UInt32 = 0
    private static var failCount = 0
    /// 这个驱动**曾经**给出过真实数值。只升不降，连接重建时清零。
    ///
    /// 原来的判据是「最新一条样本四个引擎全 0 → 未上报」，但那条判据会闪：
    /// 空闲时总有一拍恰好四个引擎都是 0，界面就会在「0%」和「未上报」之间来回跳；
    /// 现在显示的是 5 秒均值，均值非零而 reported 为假，界面会直接显示「未上报」丢掉数据。
    /// 而「驱动到底报不报数值」这件事本身是稳定的（坏的驱动恒 0、好的驱动忙时非 0），
    /// 所以一次证明就够了 —— 72 秒窗口里只要忙过一次，就认定它在真实上报。
    private static var everReported = false
    private static var latest: [String: Any] = [
        "available": false, "reported": false,
        "gr_pct": 0.0, "fb_pct": 0.0, "enc_pct": 0.0, "dec_pct": 0.0,
        "gr_avg5_pct": 0.0, "gr_avg15_pct": 0.0,
    ]
    private static var latestAt: Double = 0
    private static var refreshing = false
    /// 有没有人在看。false 时把节奏放慢到 10 秒（不是停 —— 菜单栏那条也在读同一个快照，
    /// 停了就会显示旧值）。默认 true：没有任何界面登记时行为与以前一致。
    private static var wanted = true

    /// 有人在看：1 秒一次（固件就是 1 秒一条样本，更密拿到的还是同一条）。
    /// 没人看：10 秒一次，RM 调用降到 1/10。
    private static var ttl: Double { wanted ? 1.0 : 10.0 }

    /// NVAccel 的 io_service_t 只查一次。`IOServiceGetMatchingService` 每拍走一遍注册表是白花：
    /// 句柄在驱动重载前一直有效，连接失败时（下面 closeConnection）再连同它一起丢掉重查。
    private static var svcCache: io_service_t = 0
    /// 55,888 字节的查询缓冲只分配一次。原来每次 query 都 allocate + memset 全量。
    /// RM 会把 samples 整段覆盖写回，所以每拍只需清头部 16 字节。
    private static var buf: UnsafeMutableRawPointer?

    // MARK: 对外

    /// 返回：
    ///   available  —— 驱动是否提供 NVAccel 服务
    ///   reported   —— 驱动是否真的上报了利用率（**粘性**：曾经给出过非零值就一直为真，
    ///                 连接重建时清零。理由见 `everReported`）
    ///   gr/fb/enc/dec_pct —— 百分比（未上报时为 0）
    ///   gr_avg5_pct / gr_avg15_pct —— GR 引擎最近 5 / 15 秒的均值（百分比）
    ///
    /// 为什么要单列 `reported`：2.4.3 + NVK 时期的驱动会把整个样本结构写回来
    /// （时间戳递增、6 个引擎块结构完整、procId 恒为 0xFFFFFFFF），但 util 恒为 0，
    /// 即便用 Metal 把独显压到满载也是 0 —— 那条 ctrl 当时是「形状对、数值空」。
    /// 现在（驱动已更新，含 PR #323 的温度上报）实测有真实数值：
    ///   gr_pct 13.73 / fb_pct 1.20 / proc_id 159 / Temperature(C) 49℃
    /// 所以判据保留但含义变了：全 0 只代表「这一拍四个引擎都没动」，
    /// 界面据此显示「未上报」而不是一个假的 0%，避免把不可用当空闲。
    /// 采样节奏实测：72 条样本时间戳间隔 ≈1.0 秒（窗口 72 秒），不是 issue 里 3080 上的 14.4 秒。
    /// 数值本身是台阶式的（固件按整秒统计），所以对外再给一组 5 / 15 秒均值，
    /// 界面用均值显示，曲线才不会一秒一个尖。
    static func snapshot() -> [String: Any] {
        stateLock.lock()
        let now = Date().timeIntervalSince1970
        let out = latest
        let stale = (now - latestAt) >= ttl
        let kick = stale && !refreshing
        if kick { refreshing = true }
        stateLock.unlock()

        // 非阻塞：这一拍要更新就丢给后台队列，本次先返回上一拍的值。
        // UI 按 1 秒轮询，最多晚一拍；换来的是主线程永远不碰 IOKit。
        if kick { queue.async { refreshNow() } }
        return out
    }

    /// 有人看 / 没人看。没人看就把节奏从 1 秒放到 10 秒（不停，菜单栏还在读同一个快照）。
    ///
    /// ⚠ 这些静态状态是**按进程**的，而真正读 NVAccel 的是 helper 进程。
    /// 调用点必须落在 helper 里（`NativeAPI` 的 `/api/dgpu/want`、`/api/dgpu/idle`），
    /// app 进程里调只会改到一份没人用的副本。见 MonitorStore.syncDgpuDemand 的注释。
    static func setWanted(_ on: Bool) {
        stateLock.lock(); wanted = on; stateLock.unlock()
    }

    /// 预热：app 启动时先丢一拍到后台队列，让第一次 `/api/snapshot` 就有真值。
    /// 不做这一步的话，`snapshot()` 非阻塞的代价是启动后第一秒的 payload 里
    /// `available=false`，界面会闪一下「未找到 NVAccel 服务」。
    static func warmUp() {
        stateLock.lock()
        let kick = !refreshing
        if kick { refreshing = true }
        stateLock.unlock()
        if kick { queue.async { refreshNow() } }
    }

    /// 阻塞版：等这一拍真的查完再返回。给 `mcutil dgpu` 这类一次性调用用 ——
    /// `snapshot()` 是非阻塞的，单次调用只会拿到初始的空值。
    static func sampleOnce() -> [String: Any] {
        queue.sync {
            refreshNow()
            stateLock.lock(); defer { stateLock.unlock() }
            return latest
        }
    }

    /// 真正干活的那一拍。**只在 `queue` 上跑**，所以 conn/hClient/buf 不需要加锁。
    private static func refreshNow() {
        let now = Date().timeIntervalSince1970
        var out: [String: Any] = [
            "available": false,
            "reported": false,
            "gr_pct": 0.0, "fb_pct": 0.0, "enc_pct": 0.0, "dec_pct": 0.0,
            "gr_avg5_pct": 0.0, "gr_avg15_pct": 0.0,
        ]
        defer {
            stateLock.lock()
            latest = out
            latestAt = now
            refreshing = false
            stateLock.unlock()
        }

        guard let svc = utilService() else { return }
        out["available"] = true

        guard connect(svc) else { return }

        guard let raw = query() else {
            // 连续失败可能是 GPU 复位，重建连接后再试一次
            failCount += 1
            if failCount >= 2 {
                closeConnection()
                failCount = 0
            }
            return
        }
        failCount = 0

        let gr = raw.gr, fb = raw.fb
        out["gr_pct"] = Double(gr) / 100
        out["fb_pct"] = Double(fb) / 100
        out["enc_pct"] = Double(raw.enc) / 100
        out["dec_pct"] = Double(raw.dec) / 100
        // 手上有 72 条（72 秒）历史，顺手给个滑动平均：单看瞬时值会一秒一跳。
        out["gr_avg5_pct"] = Double(raw.grAvg5) / 100
        out["gr_avg15_pct"] = Double(raw.grAvg15) / 100
        // 另外三个引擎的 5 秒均值：性能页的 dGPU 大卡片要把四个引擎并排显示，
        // 口径必须一致（都取均值），否则 GR 是均值、其余是瞬时，进度条会各跳各的。
        out["fb_avg5_pct"] = Double(raw.fbAvg5) / 100
        out["enc_avg5_pct"] = Double(raw.encAvg5) / 100
        out["dec_avg5_pct"] = Double(raw.decAvg5) / 100
        // 只要任一引擎有非零值，就认为驱动确实在上报
        out["reported"] = raw.reported
        out["proc_id"] = raw.procId
    }

    /// 连接状态（诊断用）
    static var connected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return (latest["available"] as? Bool) ?? false
    }

    // MARK: GPU 核心温度（2.7.6 起，替代 EC 0x044F）

    /// 读 NVAccel 自己上报的 GPU 核心温度（摄氏度）。
    ///
    /// 来源：nullmoth/nvidia-macos-driver PR #323（GeekAudio）——
    /// 驱动侧用 250ms 定时器读 TSENS(0x20460)，把摄氏度写进 NVAccel 服务的
    /// `PerformanceStatistics["Temperature(C)"]`（read-copy-modify-write，不动其他键）。
    /// 这就是 iStat 读 GPU 面板走的那条路径。
    ///
    /// 为什么换掉 EC 0x044F：那个寄存器读的是「GPU 附近」的板级环境温度，
    /// 满载时几乎不动（本机实测 CPU 64→89℃ 时它只有 60→62℃），拿它当独显温度
    /// 会同时误导显示和风扇曲线。核心温度只有 TSENS 给得准。
    ///
    /// 两个细节按 PR 的说明处理：
    ///   ① 驱动启动 5s 后才开始读 BAR0，此前的值不可用 → 读不到就返回 nil；
    ///   ② GSP-RM 下 TSENS 的 valid 位恒为 0（这也是 gp100_therm_new() 在
    ///      这些卡上放弃 attach 的原因），驱动改用「落在 1..125℃」做有效性判断，
    ///      所以这里也只做范围校验，不看 valid 位。
    ///
    /// 注意：这是 IORegistry 属性读，不开 RM 通道、不需要 root、不碰 BAR0。
    static func coreTemperatureC() -> Int? {
        guard let svc = service() else { return nil }
        defer { IOObjectRelease(svc) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let v = unmanaged.takeRetainedValue()
        guard let dict = v as? [String: Any],
              let n = dict["Temperature(C)"] as? NSNumber else { return nil }
        let c = n.intValue
        return (c >= 1 && c <= 125) ? c : nil
    }

    // MARK: 底层

    private static func service() -> io_service_t? {
        for name in ["NVAccel", "NVRM"] {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if svc != 0 { return svc }
        }
        return nil
    }

    private static func closeConnection() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
        hClient = 0; hDevice = 0; hSubdev = 0
        // 驱动重载后旧的 io_service_t 已经失效：一起丢掉，下一拍重新匹配。
        // `everReported` 也一起清 —— 换了驱动实例，之前的证明就不作数了。
        everReported = false
        if svcCache != 0 { IOObjectRelease(svcCache); svcCache = 0 }
    }

    /// 查询路径专用的 service 句柄（缓存，不释放）。温度那条仍走 `service()` + defer release。
    private static func utilService() -> io_service_t? {
        if svcCache != 0 { return svcCache }
        guard let s = service() else { return nil }
        svcCache = s
        return s
    }

    @discardableResult
    private static func connect(_ svc: io_service_t) -> Bool {
        if hSubdev != 0 { return true }
        if conn == 0 {
            var c: io_connect_t = 0
            let kr = IOServiceOpen(svc, mach_task_self_, 0x4E56_0000, &c)
            guard kr == KERN_SUCCESS else { return false }
            conn = c
        }
        hClient = alloc(0, clsRootClient, nil, 0)
        guard hClient != 0xFFFF_FFFF else { closeConnection(); return false }

        // NV0080_ALLOC：deviceId@0, hClientShare@4, hTargetClient@8,
        // hTargetDevice@12, flags@16, vaSpaceSize@24, vaStart@32, vaLimit@40, vaMode@48
        let a80 = UnsafeMutableRawPointer.allocate(byteCount: 56, alignment: 8)
        memset(a80, 0, 56)
        a80.storeBytes(of: hClient, toByteOffset: 4, as: UInt32.self)
        hDevice = alloc(hClient, clsDevice0, a80, 56)
        a80.deallocate()
        guard hDevice != 0xFFFF_FFFF else { closeConnection(); return false }

        let a2080 = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        a2080.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
        hSubdev = alloc(hDevice, clsSubdevice0, a2080, 4)
        a2080.deallocate()
        guard hSubdev != 0xFFFF_FFFF else { closeConnection(); return false }
        return true
    }

    /// 一发 escape：`IOConnectCallMethod(conn, SEL_ESC, &cmd, 1, 结构体入, 结构体出)`
    /// 同一个缓冲区既作入参又作出参，与 nvstatd.c 一致（驱动就地改写 status/hObjectNew）。
    private static func esc(_ cmd: UInt32, _ buf: UnsafeMutableRawPointer, _ size: Int) -> Bool {
        var cmdIn = UInt64(cmd)
        var outSize = size
        let kr = IOConnectCallMethod(conn, selEsc, &cmdIn, 1,
                                     buf, size, nil, nil, buf, &outSize)
        return kr == KERN_SUCCESS
    }

    /// NVOS21（32B）：hRoot@0 hObjectParent@4 hObjectNew@8 hClass@12 pAllocParms@16 paramsSize@24 status@28
    private static func alloc(_ parent: UInt32, _ cls: UInt32,
                              _ parms: UnsafeMutableRawPointer?, _ parmsSize: Int) -> UInt32 {
        let b = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { b.deallocate() }
        memset(b, 0, 32)
        b.storeBytes(of: hClient, toByteOffset: 0, as: UInt32.self)
        b.storeBytes(of: parent, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: cls, toByteOffset: 12, as: UInt32.self)
        b.storeBytes(of: UInt64(UInt(bitPattern: parms)), toByteOffset: 16, as: UInt64.self)
        b.storeBytes(of: UInt32(parmsSize), toByteOffset: 24, as: UInt32.self)
        guard esc(escRmAlloc, b, 32) else { return 0xFFFF_FFFF }
        guard b.load(fromByteOffset: 28, as: UInt32.self) == 0 else { return 0xFFFF_FFFF }
        return b.load(fromByteOffset: 8, as: UInt32.self)
    }

    /// NVOS54（32B）：hClient@0 hObject@4 cmd@8 flags@12 params@16 paramsSize@24 status@28
    private static func control(_ h: UInt32, _ cmd: UInt32,
                               _ parms: UnsafeMutableRawPointer, _ size: Int) -> UInt32 {
        let b = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { b.deallocate() }
        memset(b, 0, 32)
        b.storeBytes(of: hClient, toByteOffset: 0, as: UInt32.self)
        b.storeBytes(of: h, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: cmd, toByteOffset: 8, as: UInt32.self)
        b.storeBytes(of: UInt64(UInt(bitPattern: parms)), toByteOffset: 16, as: UInt64.self)
        b.storeBytes(of: UInt32(size), toByteOffset: 24, as: UInt32.self)
        guard esc(escRmControl, b, 32) else { return 0xFFFF_FFFF }
        return b.load(fromByteOffset: 28, as: UInt32.self)
    }

    private struct Sample {
        var gr: UInt32, fb: UInt32, enc: UInt32, dec: UInt32, procId: UInt32
        /// 滑动平均（pct*100），取环里时间戳最新的 5 / 15 条。
        /// GR 是主指标，给 5 秒和 15 秒两档；另外三个引擎只给 5 秒 ——
        /// 它们本来就是常量或 0（FB 维持虚拟 framebuffer ≈0.27，ENC/DEC 通常 0），
        /// 多算一档 15 秒没有信息量。
        var grAvg5: UInt32, grAvg15: UInt32
        var fbAvg5: UInt32, encAvg5: UInt32, decAvg5: UInt32
        /// 驱动是否真的在上报数值（粘性，见 `everReported`）
        var reported: Bool
    }

    private static func query() -> Sample? {
        // 缓冲只分配一次：RM 会把 72 条样本整段覆盖写回，每拍只需清头部（type/bufSize/count/tracker）。
        if buf == nil {
            buf = UnsafeMutableRawPointer.allocate(byteCount: paramsSize, alignment: 8)
            memset(buf!, 0, paramsSize)
        }
        let p = buf!
        memset(p, 0, paramsHeader)
        p.storeBytes(of: sampleTypePerfmonUtil, toByteOffset: 0, as: UInt8.self)
        // bufSize 必须是 72 条的整段：给 8 条 / 2 条 / 1 条，RM 一律回 status 0x1f（实测）。
        p.storeBytes(of: UInt32(sampleSize * sampleCount), toByteOffset: 4, as: UInt32.self)

        let st = control(hSubdev, cmdPerfmonUtilV2, p, paramsSize)
        guard st == 0 else { return nil }

        // 72 条是一个**环**，samples[0] 不是最新的 —— 实测加压时 samples[0] = 0.00%，
        // 而时间戳最大的那条 = 99.02%，且最新样本的索引每秒往前走一格（21 → 27 / 5 秒）。
        // 所以按 timeStamp 排序后再取：最新的一条给瞬时值，末尾 5 / 15 条给滑动平均。
        struct Row {
            var ts: UInt64
            var gr: UInt32, fb: UInt32, enc: UInt32, dec: UInt32, pid: UInt32
        }
        var rows: [Row] = []
        rows.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let off = paramsHeader + i * sampleSize
            let ts = p.load(fromByteOffset: off, as: UInt64.self)
            if ts == 0 { continue }        // 刚启动时环还没填满，空槽位跳过
            rows.append(Row(ts: ts,
                            gr: p.load(fromByteOffset: off + offGr, as: UInt32.self),
                            fb: p.load(fromByteOffset: off + offFb, as: UInt32.self),
                            enc: p.load(fromByteOffset: off + offEnc, as: UInt32.self),
                            dec: p.load(fromByteOffset: off + offDec, as: UInt32.self),
                            pid: p.load(fromByteOffset: off + offGr + 8, as: UInt32.self)))
        }
        guard let n = rows.max(by: { $0.ts < $1.ts }) else { return nil }
        rows.sort { $0.ts < $1.ts }

        func average(_ k: Int, _ pick: (Row) -> UInt32) -> UInt32 {
            let take = min(k, rows.count)
            guard take > 0 else { return 0 }
            var sum: UInt64 = 0
            for i in (rows.count - take)..<rows.count { sum += UInt64(pick(rows[i])) }
            return UInt32(sum / UInt64(take))
        }
        // 任一条样本有任一引擎非零 → 驱动确实在给数值（按位或判零，比逐个比较省事）
        if !everReported, rows.contains(where: { ($0.gr | $0.fb | $0.enc | $0.dec) != 0 }) {
            everReported = true
        }
        return Sample(gr: n.gr, fb: n.fb, enc: n.enc, dec: n.dec, procId: n.pid,
                      grAvg5: average(5) { $0.gr },
                      grAvg15: average(15) { $0.gr },
                      fbAvg5: average(5) { $0.fb },
                      encAvg5: average(5) { $0.enc },
                      decAvg5: average(5) { $0.dec },
                      reported: everReported)
    }
}
