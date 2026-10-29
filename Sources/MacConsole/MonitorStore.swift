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
/// 转速面（EC 0x046C/0x0464）仍由 helper 的后台采样器 2 秒采一次——EC 邮箱硬上限
/// ~15 次/秒，一次全扫 17 读就是 1.1 秒，1 秒轮询不可能直读（见坑 #55）。
/// 所以「UI 1 秒刷新、转速值 2 秒更新」，与 Stats 的 1 秒一致，快照本身 <50ms。
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
    /// 快照计数：低频面（灯效）用它做分频
    @Published var tick: Int = 0
    /// 最近 90 秒的曲线数据（性能页画折线用，与 Stats 的实时图同思路）
    @Published var history: [String: [Double]] = [:]
    static let historyLen = 90

    private weak var backend: BackendService?
    private var loop: Task<Void, Never>?
    private var slowLoop: Task<Void, Never>?

    var refreshInterval: TimeInterval = 1.0

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
                let iv = self?.refreshInterval ?? 1.0
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
            connected = false
            return
        }
        overview = BackendService.dict(snap, "overview") ?? overview
        sensors = BackendService.dict(snap, "sensors") ?? sensors
        battery = BackendService.dict(snap, "battery") ?? battery
        if let d = BackendService.array(snap, "disks") as? [[String: Any]] { disks = d }
        if let p = BackendService.array(snap, "processes") as? [[String: Any]] { processes = p }
        if let f = BackendService.dict(snap, "fan"), !f.isEmpty { fan = f }
        // 有页面在看实时转速：额外打一次 /api/fan/live —— 既是取值也是「续租」。
        // 没有页面在看时这一整块不执行，helper 端也不会去读 EC。
        if liveFanDemand > 0, let lf = try? await backend.getJSON("/api/fan/live") as? [String: Any],
           !lf.isEmpty {
            fan = lf
        }
        if let v = BackendService.dict(snap, "volume"), !v.isEmpty { volume = v }
        snapshotMs = BackendService.int(snap, "elapsed_ms") ?? 0
        connected = true
        updatedAt = Date()
        tick &+= 1
        pushHistory()
        // 菜单栏图标与弹出面板共用这一份快照（不再自己轮询，见 MetricsHub 注释）
        MetricsHub.shared.ingest(overview: overview, live: live, sensors: sensors)
    }

    /// 把关心的几个指标压进环形缓冲（1 秒一个点，90 点 = 90 秒）
    private func pushHistory() {
        var h = history
        func add(_ k: String, _ v: Double?) {
            guard let v, v.isFinite else { return }
            var arr = h[k] ?? []
            arr.append(v)
            if arr.count > Self.historyLen { arr.removeFirst(arr.count - Self.historyLen) }
            h[k] = arr
        }
        add("cpu", BackendService.double(overview, "cpu_usage"))
        add("mem", BackendService.double(memory, "percent"))
        add("gpu", BackendService.double(overview, "gpu_usage"))
        add("cpuTemp", cpuTemp > 0 ? cpuTemp : nil)
        add("gpuTemp", Double(BackendService.int(live, "temp_gpu") ?? 0))
        add("rpm", Double(BackendService.int(live, "rpm_cpu") ?? 0))
        add("power", cpuWatts)
        add("down", BackendService.double(net, "down_kbs"))
        add("up", BackendService.double(net, "up_kbs"))
        add("diskTemp", diskTemp)
        // 独显利用率只在驱动真的上报时才进曲线，否则整条 0 线会误导。
        // 用 5 秒均值而不是瞬时值：驱动按整秒发布，瞬时值在 90 点折线上是一格一个台阶，
        // 而均值是本进程在 payload 里算好的本地滑动平均，不多花一次 IORegistry 读。
        add("dgpu", dgpuReported ? dgpuUtilAvg5 : nil)
        history = h
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
    /// 15 秒窗口里实际有几拍（排障用：一直是 1 说明快照没在刷新）
    var dgpuSamples: Int { BackendService.int(dgpu, "samples") ?? 0 }
    /// 均值窗口长度（秒），界面字段网格里显示
    var dgpuWindow: Int { BackendService.int(dgpu, "window_s") ?? 15 }

    /// 独显温度：2.7.6 起由 NVAccel 上报的 GPU 核心温度（PR #323），不再读 EC 0x044F。
    /// 驱动未就绪/未上报时为 0，调用方按「不可用」处理。
    var gpuTemp: Double { Double(BackendService.int(live, "temp_gpu") ?? 0) }
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
    /// 封装功耗（SMC PCPT / PCPR）
    var cpuWatts: Double? {
        for p in (BackendService.array(sensors, "power") as? [[String: Any]]) ?? [] {
            if BackendService.string(p, "key") == "PCPT" {
                return BackendService.double(p, "value")
            }
        }
        return nil
    }

    func tempColor(_ c: Double) -> Color {
        if c >= 85 { return Theme.red }
        if c >= 70 { return Theme.amber }
        return Theme.green
    }
}
