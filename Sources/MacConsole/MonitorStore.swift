import Foundation
import SwiftUI

/// 全局轮询 Store：所有页面共享一份后端快照。
///
/// 2.7.0 起：**1 秒一次、只发一个请求**（`/api/snapshot`）。
/// 旧实现并发打 5 个接口（all / fan / rgb / lightbar / volume_get），
/// 每个都是一次 XPC 往返 + JSON 解码；现在后端把风扇（走采样器热缓存）、
/// 音量（CoreAudio）都并进同一个 payload，UI 侧只剩一次往返。
///
/// EC 面（风扇/温度）仍由 helper 的后台采样器 2 秒采一次——EC 邮箱硬上限
/// ~15 次/秒，一次全扫 17 读就是 1.1 秒，1 秒轮询不可能直读（见坑 #55）。
/// 所以「UI 1 秒刷新、风扇值 2 秒更新」，与 Stats 的 1 秒一致，快照本身 <50ms。
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
        if let v = BackendService.dict(snap, "volume"), !v.isEmpty { volume = v }
        snapshotMs = BackendService.int(snap, "elapsed_ms") ?? 0
        connected = true
        updatedAt = Date()
        tick &+= 1
        pushHistory()
        // 菜单栏图标与弹出面板共用这一份快照（不再自己轮询，见 MetricsHub 注释）
        MetricsHub.shared.ingest(overview: overview, live: live)
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
        // 独显利用率只在驱动真的上报时才进曲线，否则整条 0 线会误导
        add("dgpu", dgpuReported ? dgpuUtil : nil)
        history = h
    }

    func refreshSlow() async {
        guard let backend else { return }
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

    /// 独显利用率（NVAccel RM 通道，issue #324）
    /// `reported == false` 表示驱动把样本结构写回来了但 util 恒为 0（本机 2.4.3 就是这个状态），
    /// 界面必须显示「未上报」而不是 0%。
    var dgpu: [String: Any] { BackendService.dict(overview, "dgpu") ?? [:] }
    var dgpuReported: Bool { BackendService.bool(dgpu, "reported") ?? false }
    var dgpuAvailable: Bool { BackendService.bool(dgpu, "available") ?? false }
    var dgpuUtil: Double { BackendService.double(dgpu, "gr_pct") ?? 0 }

    /// 独显温度：EC 0x044F 读的是 PCIe 那张卡
    var gpuTemp: Double { Double(BackendService.int(live, "temp_gpu") ?? 0) }
    /// CPU 温度：优先 SMC 封装温度（TC0P，与 Stats 同源、读取更快），
    /// 拿不到再退 EC 的 temp_cpu（两路实测同值）。
    var cpuTemp: Double {
        if let raw = sensors["raw_temps"] as? [String: Any],
           let n = raw["TC0P"] as? NSNumber, n.doubleValue > 0 {
            return n.doubleValue
        }
        return Double(BackendService.int(live, "temp_cpu") ?? 0)
    }
    /// 硬盘温度（NVMe SMART，15 秒缓存）
    var diskTemp: Double? {
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
