import Foundation
import SwiftUI

/// 全局轮询 Store：所有页面共享一份后端快照。
///
/// 2.7.0 起：**1 秒一次、只发一个请求**（`/api/snapshot`）。
/// 旧实现并发打 5 个接口（all / fan / rgb / lightbar / volume_get），
/// 每个都是一次 XPC 往返 + JSON 解码；现在后端把风扇（走采样器热缓存）、
/// 音量（CoreAudio）都并进同一个 payload，UI 侧只剩一次往返。
///
/// 温度面（CPU/GPU）不走 EC：CPU 取 SMC（TC0P 等封装键），GPU 取 NVAccel 上报。
/// 转速面（EC 0x0464/0x046C：0x464=CPU 主风扇、0x46C=GPU 第二颗）仍由 helper 的后台采样器 2 秒采一次——EC 邮箱硬上限
/// ~15 次/秒，一次全扫 17 读就是 1.1 秒，1 秒轮询不可能直读（见坑 #55）。
/// 所以「UI 1 秒刷新、转速值 2 秒更新」，与 Stats 的 1 秒一致，快照本身 <50ms。
/// 90 秒曲线缓冲（2026-11-18 极限优化，见 MonitorStore.hist 注释）。
/// 独立 ObservableObject：只有画曲线的 HistoryCurve 订阅它，
/// 曲线追加点不再拖整棵监控页重算。
@MainActor
final class HistoryStore: ObservableObject {
    @Published var history: [String: [Double]] = [:]
    static let len = 90

    /// 按键追加一个点，超长截头（CoW 下只是 90 元素数组的追加，微秒级）
    func add(_ key: String, _ v: Double?) {
        guard let v, v.isFinite else { return }
        var h = history
        var arr = h[key] ?? []
        arr.append(v)
        if arr.count > Self.len { arr.removeFirst(arr.count - Self.len) }
        h[key] = arr
        history = h
    }
}

@MainActor
final class MonitorStore: ObservableObject {

    /// 单例：与 BackendService.shared 配对，app 启动即挂上轮询（不等主窗口出现）。
    static let shared = MonitorStore()

    @Published var overview: [String: Any] = [:]
    @Published var sensors: [String: Any] = [:]
    @Published var battery: [String: Any] = [:]
    @Published var disks: [[String: Any]] = []
    @Published var processes: [[String: Any]] = []
    @Published var fan: [String: Any] = [:]
    @Published var volume: [String: Any] = [:]
    @Published var rgb: [String: Any] = [:]
    @Published var lightbar: [String: Any] = [:]
    @Published var connected = false
    @Published var updatedAt: Date?
    /// 后端组包耗时（毫秒），显示在监控页头部，方便一眼看出性能有没有退化
    @Published var snapshotMs: Int = 0
    /// 快照计数：低频面（灯效）用它做分频。
    /// 2026-11-08：不再是 @Published —— 它每秒都变，却没人在界面上读它，
    /// 白白让所有订阅者重建一次视图。
    private(set) var tick: Int = 0
    /// 最近 90 秒的曲线数据（性能页画折线用，与 Stats 的实时图同思路）。
    /// 2026-11-18（极限优化）：拆出独立 HistoryStore —— 原来挂在 MonitorStore 上
    /// 每秒必发一次 objectWillChange，把整棵监控页拖着重算（哪怕温度/占用一拍
    /// 没变）。拆出去后只有画曲线的 HistoryCurve 订阅它，卡片主体只在真实
    /// 数据变化时重算，逐字段 diff 优化才真正生效。
    let hist = HistoryStore()

    private weak var backend: BackendService?
    private var loop: Task<Void, Never>?
    private var slowLoop: Task<Void, Never>?

    /// 基础间隔。真正生效的间隔见 `effectiveInterval`。
    var refreshInterval: TimeInterval = 1.0

    /// 「有页面要 1 秒实时看」的需求计数（性能页这类逐秒变化的页面）。
    private var fastDemand = 0
    /// 主窗口是否可见（关窗 / 最小化后自动降频，常驻菜单栏不该一直全速跑）
    private var windowVisible = true

    func demandFast(_ on: Bool) {
        fastDemand = max(0, fastDemand + (on ? 1 : -1))
    }

    func setWindowVisible(_ visible: Bool) {
        let was = windowVisible
        windowVisible = visible
        // 从「不可见」切回「可见」：立刻补一拍。不可见期间界面收不到任何赋值，
        // 不补的话用户回到窗口时看到的是最多 3 秒前的数据。
        if visible, !was { Task { await refresh() } }
    }

    /// 实际轮询间隔：
    /// * 有页面要实时 → 1 秒
    /// * 主窗口不在（只剩菜单栏图标）→ 5 秒
    /// * 其它页面（控制 / 灯效 / 设置，本来就是静态的）→ 3 秒
    var effectiveInterval: TimeInterval {
        if fastDemand > 0 { return refreshInterval }
        return windowVisible ? 3.0 : 5.0
    }

    /// 2.8.15「按需读 EC」的两个需求计数：
    /// * liveFan   —— 有页面正在显示实时转速（性能页 / 风扇曲线页）
    /// * lighting  —— 灯效页可见（海岸灯状态要从 EC 读）
    /// 计数归零后 helper 侧的租约 10 秒内自然过期，EC 读取彻底停下。
    private var liveFanDemand = 0
    private var lightingDemand = 0

    func demandLiveFan(_ on: Bool) {
        liveFanDemand = max(0, liveFanDemand + (on ? 1 : -1))
    }

    func demandLighting(_ on: Bool) {
        lightingDemand = max(0, lightingDemand + (on ? 1 : -1))
    }

    func attach(_ backend: BackendService) {
        guard self.backend == nil else { return }
        self.backend = backend
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let iv = self?.effectiveInterval ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(iv * 1_000_000_000))
            }
        }
        // 灯效面（RGB 控制器 / 海岸灯）读的是 HID 与 EC，没必要 1 秒一次：
        // 单独 5 秒一轮，和主快照解耦，灯效页照样能即时看到自己刚下发的状态。
        slowLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSlow()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func refresh() async {
        guard let backend else { return }
        guard let snap = try? await backend.getJSON("/api/snapshot") as? [String: Any] else {
            if windowVisible { connected = false }
            return
        }

        // ---- 解析：主窗口在不在都要做，菜单栏图标吃的就是这份 ----
        let snapOverview = BackendService.dict(snap, "overview")
        let snapSensors  = BackendService.dict(snap, "sensors")
        let snapFan      = BackendService.dict(snap, "fan")
        // 有页面在看实时转速：额外打一次 /api/fan/live —— 既是取值也是「续租」。
        // 没有页面在看时这一整块不执行，helper 端也不会去读 EC。
        var freshFan = snapFan ?? [:]
        if liveFanDemand > 0, let lf = try? await backend.getJSON("/api/fan/live") as? [String: Any],
           !lf.isEmpty {
            freshFan = lf
        }
        // 菜单栏图标与弹出面板始终喂最新值，与主窗口是否可见无关
        MetricsHub.shared.ingest(overview: snapOverview ?? overview,
                                 live: BackendService.dict(freshFan, "live") ?? live,
                                 sensors: snapSensors ?? sensors)

        // 2026-11-07（性能）：主窗口不可见（隐藏 / 最小化 / 被完全遮挡）时到此为止。
        // 每给一个 @Published 赋值，SwiftUI 都会把整棵视图树标脏并重跑 AutoLayout。
        // 实测只剩菜单栏图标时仍有 25 ms/s，sample 显示全部落在
        // -[NSWindow updateConstraintsIfNeeded] → NSISEngine 约束求解上 ——
        // 而那块界面根本没人在看。数据上面已经喂给菜单栏了，界面不必重排。
        guard windowVisible else { return }

        // 2026-11-08（性能）：**值没变就不赋值**。
        // 每个 @Published 赋值都会让整棵视图树标脏重算；温度/转速/进程这些
        // 大部分时候和上一拍一模一样，逐字段用 NSDictionary 深比较一遍
        // （几十个键，微秒级）换掉一次几十毫秒的全量布局。
        if let o = snapOverview, Self.differs(overview, o) { overview = o }
        if let sn = snapSensors, Self.differs(sensors, sn) { sensors = sn }
        // 慢变字段分频：进程 / 磁盘 / 电池本来就不是逐秒变的，
        // 但它们每秒一换会让 15 行进程表、每卷容量条、电池详情一起重排 ——
        // 这几块正是 AutoLayout 求解的大头（sample 显示每秒 ~10% CPU 花在
        // updateConstraintsIfNeeded 上）。降频后每拍的布局重算量少一大半。
        tick &+= 1
        if tick % 3 == 1 {
            if let pr = BackendService.array(snap, "processes") as? [[String: Any]],
               Self.differs(processes, pr) { processes = pr }
        }
        if tick % 5 == 1 {
            if let b = BackendService.dict(snap, "battery"), Self.differs(battery, b) { battery = b }
            if let d = BackendService.array(snap, "disks") as? [[String: Any]],
               Self.differs(disks, d) { disks = d }
        }
        if !freshFan.isEmpty, Self.differs(fan, freshFan) { fan = freshFan }
        if let v = BackendService.dict(snap, "volume"), !v.isEmpty, Self.differs(volume, v) {
            volume = v
        }
        let ms = BackendService.int(snap, "elapsed_ms") ?? 0
        if snapshotMs != ms { snapshotMs = ms }
        if !connected { connected = true }
        // updatedAt 只在「需要显示时间」的页面用得上，1 秒一次足够，但也做 diff
        let now = Date()
        if updatedAt == nil || now.timeIntervalSince(updatedAt!) >= 0.9 { updatedAt = now }
        pushHistory()
    }

    /// 深比较两个 JSON 结构（字典 / 数组）。
    /// `Any` 不满足 Equatable，只能走 NSObject 的 isEqual —— Foundation 对
    /// NSDictionary / NSArray 的实现就是逐键递归比较，够用且不产生副作用。
    static func differs<T>(_ a: T, _ b: T) -> Bool {
        !(a as AnyObject).isEqual(b as AnyObject)
    }

    /// 把关心的几个指标压进曲线缓冲（1 秒一个点，90 点 = 90 秒）。
    /// 2026-11-18（极限优化）：写入拆到 HistoryStore，发布范围只剩曲线子视图；
    /// 原来的「整字典拷贝 + 900 点深比较」换成 HistoryStore.add 里按键追加
    /// （90 元素数组 CoW 追加，微秒级）。
    private func pushHistory() {
        hist.add("cpu", BackendService.double(overview, "cpu_usage"))
        hist.add("mem", BackendService.double(memory, "percent"))
        hist.add("gpu", BackendService.double(overview, "gpu_usage"))
        hist.add("cpuTemp", cpuTemp > 0 ? cpuTemp : nil)
        hist.add("gpuTemp", Double(BackendService.int(live, "temp_gpu") ?? 0))
        hist.add("rpm", Double(BackendService.int(live, "rpm_cpu") ?? 0))
        hist.add("power", cpuWatts)
        hist.add("down", BackendService.double(net, "down_kbs"))
        hist.add("up", BackendService.double(net, "up_kbs"))
        hist.add("diskTemp", diskTemp)
        // 独显利用率只在驱动真的上报时才进曲线，否则整条 0 线会误导。
        // 用 5 秒均值而不是瞬时值：驱动按整秒发布，瞬时值在 90 点折线上是一格一个台阶，
        // 而均值是本进程在 payload 里算好的本地滑动平均，不多花一次 IORegistry 读。
        hist.add("dgpu", dgpuReported ? dgpuUtil : nil)
    }

    func refreshSlow() async {
        guard let backend else { return }
        // 2.8.15：灯效面（RGB 控制器 + 海岸灯）读的是 HID 与 EC，
        // 只有「灯效」页可见时才轮询；其它页面一律不碰。
        guard lightingDemand > 0 else { return }
        await refreshLightingOnce(backend)
    }

    /// 灯效面单次刷新（RGB + 海岸灯）。供 onAppear 的「进页读一次」立即触发。
    func refreshLightingOnce(_ backend: BackendService) async {
        async let rgbReq = backend.getJSON("/api/rgb")
        async let lbReq = backend.getJSON("/api/lightbar")
        if let r = try? await rgbReq as? [String: Any] { rgb = r }
        if let l = try? await lbReq as? [String: Any] { lightbar = l }
    }

    // MARK: - 便捷读取

    var live: [String: Any] { BackendService.dict(fan, "live") ?? [:] }
    var memory: [String: Any] { BackendService.dict(overview, "memory") ?? [:] }
    var memDetail: [String: Any] { BackendService.dict(memory, "detail") ?? [:] }
    var cpu: [String: Any] { BackendService.dict(overview, "cpu") ?? [:] }
    var net: [String: Any] { BackendService.dict(overview, "net") ?? [:] }
    var gpus: [[String: Any]] { (BackendService.array(overview, "gpus") as? [[String: Any]]) ?? [] }

    /// 独显利用率（NVAccel 发布的 PerformanceStatistics，驱动 2.6.3 起）
    ///
    /// `available == false`：NVAccel 服务不在（驱动没装 / 没加载）。
    /// `reported == false`：服务在，但这一拍没有利用率键 —— 驱动查询失败，
    /// 或样本超过 5 秒没更新时会**把键删掉**（「缺遥测 ≠ 空闲」），界面必须显示「—」。
    var dgpu: [String: Any] { BackendService.dict(overview, "dgpu") ?? [:] }
    var dgpuReported: Bool { BackendService.bool(dgpu, "reported") ?? false }
    var dgpuAvailable: Bool { BackendService.bool(dgpu, "available") ?? false }
    /// GR（3D 引擎）瞬时占用率。驱动按整秒发布，所以它是一秒一跳的台阶值，
    /// 只适合放进 tooltip 或做差值判断，**不要直接拿来画曲线**。
    var dgpuUtil: Double { BackendService.double(dgpu, "gr_pct") ?? 0 }
    /// GR 最近 5 / 15 秒均值（本地滑动平均，见 NativeNVAccel 的 `ring`）。
    /// 界面显示用这两个：驱动只给瞬时值，历史是我们自己按拍记的。
    /// 兜底取瞬时值：payload 里没有均值字段时（老 helper）也不至于显示 0。
    var dgpuUtilAvg5: Double { BackendService.double(dgpu, "gr_avg5_pct") ?? dgpuUtil }
    var dgpuUtilAvg15: Double { BackendService.double(dgpu, "gr_avg15_pct") ?? dgpuUtil }

    /// 另外三个引擎的 5 秒均值（FB / NVENC / NVDEC）。
    ///
    /// FB（framebuffer）不是「没用」：这台机器的 dGPU 挂着 NVK 注册的虚拟显示
    /// （Main Display / 144Hz / Master Mirror），维持那块 surface 的扫描合成恒定占
    /// 一点点 —— 这就是 dGPU 的固定开销，也是 GR 显示 0% 时唯一非零的引擎。
    /// 注意 2.6.3 的口径是「显存**带宽**占用」，不是显存用量。
    /// 没有均值字段时回退到瞬时值（旧 helper）。
    var dgpuFbAvg5: Double {
        BackendService.double(dgpu, "fb_avg5_pct") ?? BackendService.double(dgpu, "fb_pct") ?? 0
    }
    var dgpuEncAvg5: Double {
        BackendService.double(dgpu, "enc_avg5_pct") ?? BackendService.double(dgpu, "enc_pct") ?? 0
    }
    var dgpuDecAvg5: Double {
        BackendService.double(dgpu, "dec_avg5_pct") ?? BackendService.double(dgpu, "dec_pct") ?? 0
    }

    // MARK: 1 秒口径（2026-11-07 用户要求：整页 1 秒刷新，不要 5 秒均值）
    //
    // 界面原来显示 5 秒滑动均值，理由是「驱动按整秒发布，瞬时值是台阶、
    // 直接显示会跳」。但整页本来就是 1 秒一轮，主数字用 5 秒均值就等于
    // 比其它数字慢半拍，看着像卡住。现在统一改用瞬时值，与刷新同步。
    // 均值字段仍然保留在 payload 里（tooltip 与排障会用到），只是不再上卡片。
    var dgpuFb: Double { BackendService.double(dgpu, "fb_pct") ?? 0 }
    var dgpuEnc: Double { BackendService.double(dgpu, "enc_pct") ?? 0 }
    var dgpuDec: Double { BackendService.double(dgpu, "dec_pct") ?? 0 }
    /// 15 秒窗口里实际有几拍（排障用：一直是 1 说明快照没在刷新）
    var dgpuSamples: Int { BackendService.int(dgpu, "samples") ?? 0 }
    /// 均值窗口长度（秒），界面字段网格里显示
    var dgpuWindow: Int { BackendService.int(dgpu, "window_s") ?? 15 }

    /// 驱动新发布的整组 dGPU 传感器（显存温度 / 频率 / P 级 / 功耗墙 / 降频掩码）。
    /// 字段都可能缺失（老驱动不发布），缺失时取出来是 NSNull / nil，界面显示「—」。
    var dgpuSensors: [String: Any] { BackendService.dict(dgpu, "sensors") ?? [:] }

    /// 显存温度（℃）。本机（TU104 的 RTX 2070S Max-Q）驱动不发布 `GPU Memory
    /// Temperature(C)` 这个键，所以这里通常是 nil —— 界面按「不可用」显示，不是 bug。
    var dgpuMemTemp: Double? { BackendService.double(dgpuSensors, "mem_temp_c") }
    /// 核心频率（MHz）
    var dgpuCoreMHz: Double? { BackendService.double(dgpuSensors, "core_mhz") }
    /// 显存频率（MHz）
    var dgpuMemMHz: Double? { BackendService.double(dgpuSensors, "mem_mhz") }
    /// 视频时钟（MHz）
    var dgpuVideoMHz: Double? { BackendService.double(dgpuSensors, "video_mhz") }
    /// 核心频率上限（MHz）
    var dgpuCoreMaxMHz: Double? { BackendService.double(dgpuSensors, "core_max_mhz") }
    /// 当前 P 级（位掩码，0x1=P0 满速 … 0x1000=P12 最低）
    var dgpuPState: Int? { BackendService.int(dgpuSensors, "pstate") }
    /// 功耗墙（W）
    var dgpuPowerLimit: Double? { BackendService.double(dgpuSensors, "power_limit_w") }
    /// 降频原因位掩码（0=无降频）
    var dgpuThrottleMask: Int? { BackendService.int(dgpuSensors, "throttle_mask") }

    // MARK: - 驱动 2.7.2 遥测补丁新增的字段
    //
    // 老驱动（含 2.6.3~2.7.1）没有这些键，取出来一律是 nil，界面显示「—」。

    /// 功耗（W）—— 驱动自算的 **8 拍环均值**，界面主数字用这个。
    ///
    /// 为什么不是固件的平均值：本机（TU104 Max-Q）RUSD 功率块只填瞬时采样，
    /// `avg` 分区的时间戳是 `RUSD_TIMESTAMP_INVALID`(=0)，固件层没有均值可分。
    /// 驱动 2.7.2-m4h 起自己 1 Hz 采样、存 8 拍环、报环均值；采样断流时它会
    /// **清窗并撤键**（宁可缺键也不拿旧值续命），所以这里偶尔会是 nil —— 显示「—」。
    var dgpuPowerAvg: Double? { BackendService.double(dgpuSensors, "power_avg_w") }

    /// 瞬时功耗（W）—— 固件这一拍的采样，空闲 6 W / 满载 115 W 的硬台阶。
    /// 1 秒刷新下直接当主数字会闪，所以只进 tooltip / 峰值判断。
    var dgpuPowerInstant: Double? { BackendService.double(dgpuSensors, "power_instant_w") }

    /// PCIe 当前 / 协商上限的速率与宽度（Gen 3 ×16 之类）
    var dgpuPcieGen: Int? { BackendService.int(dgpuSensors, "pcie_gen") }
    var dgpuPcieWidth: Int? { BackendService.int(dgpuSensors, "pcie_width") }
    var dgpuPcieMaxGen: Int? { BackendService.int(dgpuSensors, "pcie_max_gen") }
    var dgpuPcieMaxWidth: Int? { BackendService.int(dgpuSensors, "pcie_max_width") }

    /// 链路的单行描述：`Gen3 ×16`；当前与上限不一致时补一句（链路降级才看得出来）。
    var dgpuPcieLinkText: String? {
        guard let gen = dgpuPcieGen, let width = dgpuPcieWidth else { return nil }
        var text = "Gen\(gen) ×\(width)"
        if let mg = dgpuPcieMaxGen, let mw = dgpuPcieMaxWidth, mg != gen || mw != width {
            text += "（上限 Gen\(mg) ×\(mw)）"
        }
        return text
    }

    // MARK: 显存占用（GART 口径，2026-11-05 接入）

    var dgpuVramUsed: Double? { BackendService.double(dgpuSensors, "vram_used_bytes") }
    var dgpuVramSize: Double? { BackendService.double(dgpuSensors, "vram_size_bytes") }

    /// 「已用 / 总量」，两者都有才给文字。
    var dgpuVramText: String? {
        guard let u = dgpuVramUsed, let s = dgpuVramSize, s > 0 else { return nil }
        return "\(Fmt.bytes(u)) / \(Fmt.bytes(s))"
    }

    /// 占用率百分比（0~100）。
    var dgpuVramPct: Double? {
        guard let u = dgpuVramUsed, let s = dgpuVramSize, s > 0, u >= 0 else { return nil }
        return min(100, u / s * 100)
    }

    /// PCIe 链路错误：只在**有非零**时给一行文字（全 0 时不占版面）。
    /// 计数是自开机累计值，不是速率。
    var dgpuPcieErrors: [(String, Int)] {
        let dict = BackendService.dict(dgpuSensors, "pcie_errors") ?? [:]
        let names: [(String, String)] = [
            ("line_code", "行编码"), ("crc", "CRC"), ("nak", "NAK"),
            ("l0s", "L0s 退出"), ("correctable", "可纠正"),
            ("nonfatal", "非致命"), ("fatal", "致命"), ("unsupported", "不支持请求"),
        ]
        var out: [(String, Int)] = []
        for (key, label) in names {
            if let v = BackendService.int(dict, key), v > 0 { out.append((label, v)) }
        }
        return out
    }

    /// 链路错误行：`NAK 2 · CRC 1`；全部为 0 时 nil（不显示）
    var dgpuPcieErrorText: String? {
        let list = dgpuPcieErrors
        guard !list.isEmpty else { return nil }
        return list.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// 显存控制器 / JPEG 引擎占用（瞬时，补丁新发布的两项）
    var dgpuMemCtrlPct: Double? { BackendService.double(dgpuSensors, "mem_ctrl_pct") }
    var dgpuJpgPct: Double? { BackendService.double(dgpuSensors, "nvjpg_pct") }

    /// 独显温度：2.7.6 起由 NVAccel 上报的 GPU 核心温度（PR #323），不再读 EC 0x044F。
    /// 驱动未就绪/未上报时为 0，调用方按「不可用」处理。
    var gpuTemp: Double { Double(BackendService.int(live, "temp_gpu") ?? 0) }
    /// GPU 核心边缘温度（`Temperature(C)`，NVAccel 每 250 ms 直读 TSENS 0x20460）。
    /// 与 `gpuTemp` 是两个不同测点（本机空闲 47 vs 60），驱动只发一个键时为 0。
    var gpuEdgeTemp: Double { Double(BackendService.int(live, "temp_gpu_edge") ?? 0) }
    /// CPU 温度：优先 SMC 封装温度（TC0P，与 Stats 同源、读取更快），
    /// 拿不到再退后端快照的 `temp_cpu`（同一份 SMC 数据的另一个入口，**不是 EC**）。
    var cpuTemp: Double {
        if let raw = sensors["raw_temps"] as? [String: Any],
           let n = raw["TC0P"] as? NSNumber, n.doubleValue > 0 {
            return n.doubleValue
        }
        return Double(BackendService.int(live, "temp_cpu") ?? 0)
    }
    /// 硬盘温度（NVMe SMART，15 秒缓存）
    /// 2.7.6：概览页可以选看哪一块盘，选择存在 UserDefaults 里，
    /// 这里跟着走 —— 这样 KPI 卡和 90 秒曲线用的是同一块盘，不会对不上。
    var diskTemp: Double? {
        let target = UserDefaults.standard.string(forKey: "mc.overview.diskTarget") ?? ""
        if !target.isEmpty {
            for d in (BackendService.array(overview, "smart") as? [[String: Any]]) ?? [] {
                guard (BackendService.string(d, "bsd") ?? "") == target,
                      BackendService.bool(d, "ok") == true else { continue }
                if let t = BackendService.double(d, "temperature_c") { return t }
            }
        }
        let d = BackendService.dict(overview, "disk_temp") ?? [:]
        guard (d["ok"] as? Bool) == true else { return nil }
        return BackendService.double(d, "temperature_c")
    }
    /// 单个功率键的读数（含「是否沿用上一拍」信息，见 NativeSMC 的 powerCache 注释）
    private func powerEntry(_ key: String) -> (v: Double, stale: Bool, ageMs: Int)? {
        for p in (BackendService.array(sensors, "power") as? [[String: Any]]) ?? [] {
            guard BackendService.string(p, "key") == key,
                  let v = BackendService.double(p, "value") else { continue }
            return (v, BackendService.bool(p, "stale") ?? false,
                    BackendService.int(p, "age_ms") ?? 0)
        }
        return nil
    }
    /// 一次取齐 PCPT 三元组（2026-11-18 极限优化）：原来 cpuWatts / cpuWattsStale /
    /// cpuWattsAgeMs 各自线性扫一遍 sensors["power"]，CPU 卡一个 body 要扫 3 遍。
    func cpuPower() -> (watts: Double?, stale: Bool, ageMs: Int) {
        guard let e = powerEntry("PCPT") else { return (nil, false, 0) }
        return (e.v, e.stale, e.ageMs)
    }
    /// 封装功耗（SMC PCPT / PCPR）
    var cpuWatts: Double? { powerEntry("PCPT")?.v }
    /// 上一拍 SMC 没算出新值（1 秒内能量增量为 0），这个数是几秒前的实测值
    var cpuWattsStale: Bool { powerEntry("PCPT")?.stale ?? false }
    var cpuWattsAgeMs: Int { powerEntry("PCPT")?.ageMs ?? 0 }

    func tempColor(_ c: Double) -> Color {
        if c >= 85 { return Theme.red }
        if c >= 70 { return Theme.amber }
        return Theme.green
    }
}
