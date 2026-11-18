// ============================================================================
// 菜单栏监控（2026-11-16 重构·第二轮：S 飘带独立 + 监控项全量指标化）
//
// 用户定案：
//   1. **S 飘带（程序主图标）独立成一个状态项** —— 就是 MenuBarExtra，
//      面板 / openWindow / 双击唤窗逻辑全在里面，不拼接任何监控数字；
//   2. **其余监控信息拼接成另一个独立状态项**，原版 Stats Mini 双行风格
//      （7pt light 标签 + 12pt 数值，段距 4pt），点它打开主窗口；
//   3. 监控项全量指标化（「状态栏显示」页逐项开关）：
//        CPU：温度 / 频率 / 占用率 / 功耗 / 风扇转速 / 核显占用率 / 核显显存占用
//        GPU：温度 / 频率 / 占用率 / 功耗 / 风扇转速 / GR 占用率 / 显存占用
//        内存：占用率；硬盘：温度（每块盘独立开关）；网速：仅上行 / 仅下行 / 上下行
//
// 数据节奏：MonitorStore 的 /api/snapshot（窗口可见 3s / 隐藏 5s / 性能页 1s），
// 经 MetricsHub 喂给拼接条；状态项宽度随内容显式同步（syncContentWidth）。
//
// 本文件只负责：段定义（MenuBarSegment / SegmentRef）、数值计算助手、
// 监控状态项的创建与显隐。S 飘带在 SkyCCApp.swift 的 MenuBarLabel。
// ============================================================================

import Cocoa
import SwiftUI

// MARK: - 段定义

/// 菜单栏监控段（静态段）。硬盘是动态段（一块盘一段，见 SegmentRef.disk）。
/// 声明顺序 = 菜单栏拼接顺序（硬盘动态段插在网速前）。
enum MenuBarSegment: String, CaseIterable, Identifiable {
    // CPU 组
    case cpuTemp, cpuFreq, cpuUsage, cpuPower, cpuFan
    case igpuUsage, igpuVram
    // GPU 组
    case gpuTemp, gpuFreq, gpuUsage, gpuPower, gpuFan
    case grUsage, gpuVram
    // 内存
    case memUsage
    // 网速（网速组在菜单栏里排在动态硬盘段之后，见 currentSegments）
    case netDown, netUp, netBoth

    var id: String { rawValue }

    /// 开关的 UserDefaults 键（「状态栏显示」页逐项勾选）
    var defaultsKey: String { "menubar.seg.\(rawValue)" }

    /// 静态段默认只开：CPU 温度 / 内存占用率 / 网速上下行（与旧版默认观感一致）
    var defaultEnabled: Bool {
        switch self {
        case .cpuTemp, .memUsage, .netBoth: return true
        default: return false
        }
    }

    /// 「状态栏显示」页的分组（CPU / GPU / 内存 / 网速；硬盘是动态组）
    var group: SegmentGroup {
        switch self {
        case .cpuTemp, .cpuFreq, .cpuUsage, .cpuPower, .cpuFan, .igpuUsage, .igpuVram:
            return .cpu
        case .gpuTemp, .gpuFreq, .gpuUsage, .gpuPower, .gpuFan, .grUsage, .gpuVram:
            return .gpu
        case .memUsage: return .mem
        case .netDown, .netUp, .netBoth: return .net
        }
    }

    /// 设置页显示名
    var title: String {
        switch self {
        case .cpuTemp: return "温度"
        case .cpuFreq: return "频率"
        case .cpuUsage: return "占用率"
        case .cpuPower: return "功耗"
        case .cpuFan: return "风扇转速"
        case .igpuUsage: return "核显占用率"
        case .igpuVram: return "核显显存占用"
        case .gpuTemp: return "温度"
        case .gpuFreq: return "频率"
        case .gpuUsage: return "占用率"
        case .gpuPower: return "功耗"
        case .gpuFan: return "风扇转速"
        case .grUsage: return "GR 占用率"
        case .gpuVram: return "显存占用"
        case .memUsage: return "占用率"
        case .netDown: return "仅下行"
        case .netUp: return "仅上行"
        case .netBoth: return "上下行"
        }
    }

    /// 设置页 / 明细行的 SF Symbol。
    /// ⚠ 网速三段原来的符号名是空的 —— Image(systemName:) 拿不到图会渲染成「？」
    /// （2026-11-16 用户反馈），换成与语义一致的有效符号名。
    /// 菜单栏拼接条本身按原版 Stats 风格**不放图标**（见 MenuBarMonitorBar），
    /// 这里的符号只出现在「状态栏显示」页与面板明细行。
    /// 「状态栏显示」页每行的采样来源灰字（2026-11-18 用户要求：填上开关与
    /// 文字之间的空档，同时标明数字从哪里读的）。
    var source: String {
        switch self {
        case .cpuTemp:   return "SMC · TC0P"
        case .cpuFreq:   return "MSR · IA32_PERF_STATUS"
        case .cpuUsage:  return "内核 mach 采样"
        case .cpuPower:  return "SMC · PCPT"
        case .cpuFan:    return "EC · 0x0464"
        case .igpuUsage: return "IOAccelerator"
        case .igpuVram:  return "IOAccelerator"
        case .gpuTemp:   return "NVAccel"
        case .gpuFreq:   return "NVAccel · core_mhz"
        case .gpuUsage:  return "NVAccel · 5s 均值"
        case .grUsage:   return "NVAccel · 瞬时"
        case .gpuPower:  return "NVAccel · power_avg"
        case .gpuFan:    return "EC · 0x046C"
        case .gpuVram:   return "NVAccel"
        case .memUsage:  return "内核 mach 采样"
        case .netDown, .netUp, .netBoth: return "getifaddrs 差值"
        }
    }

    var symbol: String {
        switch self {
        case .cpuTemp: return "thermometer.medium"
        case .cpuFreq: return "gauge"
        case .cpuUsage, .igpuUsage: return "cpu"
        case .cpuPower, .gpuPower: return "bolt.fill"
        case .cpuFan, .gpuFan: return "fanblades.fill"
        case .igpuVram, .gpuVram: return "memorychip"
        case .gpuTemp: return "thermometer.medium"
        case .gpuFreq: return "gauge"
        case .gpuUsage, .grUsage: return "bolt.horizontal.fill"
        case .memUsage: return "memorychip"
        case .netDown: return "arrow.down"
        case .netUp: return "arrow.up"
        case .netBoth: return "arrow.up.arrow.down"
        }
    }

    /// 菜单栏拼接条里的 Mini 标签。2026-11-16 用户定案：**只用大家认识的设备名**
    /// （CPU / iGPU / dGPU / RAM / SSD / NET），指标靠数值格式自己表达
    /// （62° / 1.6G / 42% / 12.3W / 2400）—— FREQ/LOAD/PWR 这类自造缩写没人认识。
    /// 独显用 dGPU（2026-11-16 用户要求，与 iGPU 对称更好认）；
    /// 网速上下行两段标签 NET，箭头数值表意；上下行一起的走 Speed 双行小件（无标签）。
    var menuLabel: String {
        switch self {
        case .cpuTemp, .cpuFreq, .cpuUsage, .cpuPower, .cpuFan:
            return "CPU"
        case .igpuUsage, .igpuVram:
            return "iGPU"
        case .gpuTemp, .gpuFreq, .gpuUsage, .grUsage, .gpuPower, .gpuFan, .gpuVram:
            return "dGPU"
        case .memUsage: return "RAM"
        case .netDown, .netUp: return "NET"
        case .netBoth:  return ""
        }
    }
}

/// 「状态栏显示」页分组
enum SegmentGroup: String, CaseIterable {
    case cpu, gpu, mem, disk, net
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .mem: return "内存"
        case .disk: return "硬盘"
        case .net: return "网速"
        }
    }
}

/// 菜单栏里实际拼接的一段（静态段或动态硬盘段）
enum SegmentRef: Identifiable, Equatable {
    case seg(MenuBarSegment)
    case disk(bsd: String, model: String)

    var id: String {
        switch self {
        case .seg(let s): return s.rawValue
        case .disk(let bsd, _): return "disk.\(bsd)"
        }
    }

    var group: SegmentGroup {
        switch self {
        case .seg(let s): return s.group
        case .disk: return .disk
        }
    }

    /// 设置页 / 明细行的显示名（硬盘带盘标识）
    var title: String {
        switch self {
        case .seg(let s): return s.title
        case .disk(_, let model):
            return model.isEmpty ? "硬盘温度" : "温度 · \(model)"
        }
    }

    var symbol: String {
        switch self {
        case .seg(let s): return s.symbol
        case .disk: return "internaldrive"
        }
    }

    /// 菜单栏拼接条的 Mini 标签（硬盘沿用原版 Stats 的「SSD」）
    var menuLabel: String {
        switch self {
        case .seg(let s): return s.menuLabel
        case .disk: return "SSD"
        }
    }
}

// MARK: - 快照中枢（不变：1 秒一拍，来自 MonitorStore 的 /api/snapshot）

@MainActor
final class MetricsHub: ObservableObject {
    static let shared = MetricsHub()
    @Published var overview: [String: Any] = [:]
    @Published var live: [String: Any] = [:]
    /// SMC 传感器表（系统温度 / 功耗来源，和风扇 / EC 无关）
    @Published var sensors: [String: Any] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // 先用 store 里已有的快照垫一下（主窗口先开、菜单栏后建的场景）
        if !MonitorStore.shared.overview.isEmpty {
            overview = MonitorStore.shared.overview
            live = MonitorStore.shared.live
            sensors = MonitorStore.shared.sensors
        }
    }

    /// MonitorStore 每轮刷新后调用（同一主线程，不用再跨 actor）
    ///
    /// 2026-11-17（性能自查）：**值没变就不赋值**。原来三个 @Published 无条件赋值，
    /// 每个都会发 objectWillChange → 菜单栏 `MenuBarMonitorBar` 全量重算 + 一次
    /// fittingSize 测量（`syncContentWidth` 的双跳 async）。而温度和转速在一秒内
    /// 大多数时候根本没动。这里复用 MonitorStore 那套 NSDictionary 深比较
    /// （几十个键，微秒级），换掉一次 SwiftUI 图更新。
    func ingest(overview o: [String: Any], live l: [String: Any], sensors s: [String: Any]) {
        if MonitorStore.differs(overview, o) { overview = o }
        if MonitorStore.differs(live, l) { live = l }
        if MonitorStore.differs(sensors, s) { sensors = s }
    }

    /// 菜单栏 CPU 温度：直接取 SMC 快照（raw_temps 的 TC0P 等），不经 EC。
    static func cpuTempC(_ sensors: [String: Any], _ live: [String: Any]) -> Double? {
        if let raw = sensors["raw_temps"] as? [String: Any] {
            for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H"] {
                if let n = raw[key] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
            }
        }
        return BackendService.double(live, "temp_cpu")
    }

    /// 菜单栏 GPU 温度：NVAccel 上报的核心温度
    static func gpuTempC(_ sensors: [String: Any], _ live: [String: Any]) -> Double? {
        BackendService.double(live, "temp_gpu")
    }
}

// MARK: - 监控状态项 + 数值助手

@MainActor
final class MenuBarMonitors: NSObject {
    static let shared = MenuBarMonitors()
    static let iconsChanged = Notification.Name("MenuBarIconsChanged")

    /// 监控段拼接状态项（与 S 飘带的 MenuBarExtra 各自独立）
    private var monitorItem: NSStatusItem?
    /// 状态项里的 SwiftUI 宿主视图（宽度同步要用它的 fittingSize）
    private var monitorHost: NSHostingView<MenuBarMonitorBar>?

    func start() {
        UserDefaults.standard.register(defaults: [
            MenuBarSegment.cpuTemp.defaultsKey: MenuBarSegment.cpuTemp.defaultEnabled,
            MenuBarSegment.cpuFreq.defaultsKey: MenuBarSegment.cpuFreq.defaultEnabled,
            MenuBarSegment.cpuUsage.defaultsKey: MenuBarSegment.cpuUsage.defaultEnabled,
            MenuBarSegment.cpuPower.defaultsKey: MenuBarSegment.cpuPower.defaultEnabled,
            MenuBarSegment.cpuFan.defaultsKey: MenuBarSegment.cpuFan.defaultEnabled,
            MenuBarSegment.igpuUsage.defaultsKey: MenuBarSegment.igpuUsage.defaultEnabled,
            MenuBarSegment.igpuVram.defaultsKey: MenuBarSegment.igpuVram.defaultEnabled,
            MenuBarSegment.gpuTemp.defaultsKey: MenuBarSegment.gpuTemp.defaultEnabled,
            MenuBarSegment.gpuFreq.defaultsKey: MenuBarSegment.gpuFreq.defaultEnabled,
            MenuBarSegment.gpuUsage.defaultsKey: MenuBarSegment.gpuUsage.defaultEnabled,
            MenuBarSegment.gpuPower.defaultsKey: MenuBarSegment.gpuPower.defaultEnabled,
            MenuBarSegment.gpuFan.defaultsKey: MenuBarSegment.gpuFan.defaultEnabled,
            MenuBarSegment.grUsage.defaultsKey: MenuBarSegment.grUsage.defaultEnabled,
            MenuBarSegment.gpuVram.defaultsKey: MenuBarSegment.gpuVram.defaultEnabled,
            MenuBarSegment.memUsage.defaultsKey: MenuBarSegment.memUsage.defaultEnabled,
            MenuBarSegment.netDown.defaultsKey: MenuBarSegment.netDown.defaultEnabled,
            MenuBarSegment.netUp.defaultsKey: MenuBarSegment.netUp.defaultEnabled,
            MenuBarSegment.netBoth.defaultsKey: MenuBarSegment.netBoth.defaultEnabled,
        ])
        MetricsHub.shared.start()
        ensureMonitorItem()
    }

    /// 创建 / 更新监控状态项（S 飘带之外的那个）。没有勾任何监控段时隐藏。
    private func ensureMonitorItem() {
        if monitorItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // item.view 已 deprecated，但只有它能按内容自适应宽度（button 方案要自己算 frame）
            let host = NSHostingView(rootView: MenuBarMonitorBar())
            item.view = host
            monitorItem = item
            monitorHost = host
        }
        syncVisibility()
    }

    /// ★ 宽度同步（2026-11-16 用户实测修 bug）：
    /// NSHostingView 挂上状态项后，SwiftUI 内容再变宽，**状态项长度不会自动跟随**
    /// —— 内容被塞在旧宽度的框里互相叠压（实测「15.3W」直接叠上风扇「2232」、
    /// 网速三段叠成一团），段一多总宽超限还会被系统往左推到屏幕外。
    /// 每次内容变化（hub 每拍 / 开关切换）后按 fittingSize 显式回写 length。
    ///
    /// 实现细节：hub 一拍发 3 个 @Published，objectWillChange 会连响 3 次 ——
    /// 用 pending 标记把同一轮 runloop 的多次调用合并成一次测量；
    /// 双跳 async 保证跑到 SwiftUI 对 hosting view 的重排**之后**再量。
    private var widthSyncPending = false

    func syncContentWidth() {
        guard !widthSyncPending else { return }
        widthSyncPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.widthSyncPending = false
                guard let item = self.monitorItem, let host = self.monitorHost else { return }
                let w = host.fittingSize.width
                // variableLength 初始为 -2，跳过无意义值；0.5pt 抖动不回写（防每拍微动）
                guard w > 1, abs(item.length - w) > 0.5 else { return }
                item.length = w
            }
        }
    }

    /// 有勾段才显示状态项；盘列表变化时也会被调到
    func syncVisibility() {
        guard let item = monitorItem else { return }
        item.isVisible = !Self.currentSegments(overview: MetricsHub.shared.overview).isEmpty
    }

    /// 带快照的版本（MenuBarMonitorBar 每秒随 hub 调，避免读旧快照）
    func syncVisibility(with overview: [String: Any]) {
        guard let item = monitorItem else { return }
        item.isVisible = !Self.currentSegments(overview: overview).isEmpty
    }

    // MARK: 段清单

    /// 静态段开关缓存（2026-11-17 性能自查）。
    ///
    /// `currentSegments` 在 `MenuBarMonitorBar.body` 里每帧都会被调用一次，
    /// 而它原来每次都遍历 18 个 `MenuBarSegment` 读 `UserDefaults.bool(forKey:)`
    /// —— 每次读都要过一遍 CFPreferences 的锁。开关本身只会在用户点「状态栏显示」
    /// 页时变，缓存起来、收到 UserDefaults / 图标变更通知时失效即可。
    private static var enabledSegsCache: [MenuBarSegment] = []
    private static var enabledSegsValid = false

    static func invalidateSegmentCache() {
        enabledSegsValid = false
        diskToggleCache.removeAll()   // 2026-11-18：硬盘段开关缓存一起失效
    }

    private static func enabledSegs() -> [MenuBarSegment] {
        if enabledSegsValid { return enabledSegsCache }
        enabledSegsCache = MenuBarSegment.allCases.filter {
            UserDefaults.standard.bool(forKey: $0.defaultsKey)
        }
        enabledSegsValid = true
        return enabledSegsCache
    }

    /// 硬盘段开关缓存（2026-11-18 极限优化）。
    /// 静态段有 enabledSegsCache，动态硬盘段漏了同款 —— 每块盘每帧一次
    /// `UserDefaults.bool`（CFPreferences 锁），两块盘就是每帧两遍。
    /// 失效点与静态段一致（UserDefaults 变更 / 图标变更通知），见 invalidateSegmentCache。
    private static var diskToggleCache: [String: Bool] = [:]

    private static func diskEnabled(_ bsd: String) -> Bool {
        if let on = diskToggleCache[bsd] { return on }
        let on = UserDefaults.standard.bool(forKey: diskKey(bsd))
        diskToggleCache[bsd] = on
        return on
    }

    /// 当前拼进菜单栏的段（静态段按声明顺序；动态硬盘段插在网速前）
    static func currentSegments(overview: [String: Any]) -> [SegmentRef] {
        var out: [SegmentRef] = []
        var nets: [SegmentRef] = []
        let on = enabledSegs()
        for seg in MenuBarSegment.allCases {          // 保持声明顺序
            guard on.contains(seg) else { continue }
            let ref = SegmentRef.seg(seg)
            if seg.group == .net { nets.append(ref) } else { out.append(ref) }
        }
        // 硬盘：overview.smart 里的每块盘独立开关（一块盘一段温度）
        let disks = (BackendService.array(overview, "smart") as? [[String: Any]]) ?? []
        for d in disks {
            let bsd = BackendService.string(d, "bsd") ?? ""
            guard !bsd.isEmpty else { continue }
            if diskEnabled(bsd) {
                out.append(.disk(bsd: bsd, model: BackendService.string(d, "model") ?? ""))
            }
        }
        out.append(contentsOf: nets)
        return out
    }

    /// 某块盘的开关键（按 bsd 名，盘拔掉键自然失效）
    static func diskKey(_ bsd: String) -> String { "menubar.disk.\(bsd)" }

    /// 某组在设置页要列的静态段
    static func segments(in group: SegmentGroup) -> [MenuBarSegment] {
        MenuBarSegment.allCases.filter { $0.group == group }
    }

    // MARK: 数值文本

    /// 某段的数值文本。不可用时显示「—」，绝不显示假数字。
    static func valueText(_ ref: SegmentRef,
                          overview: [String: Any],
                          live: [String: Any],
                          sensors: [String: Any]) -> String {
        switch ref {
        case .disk(_, let bsd): return diskText(overview: overview, bsd: bsd)
        case .seg(let s): return valueText(s, overview: overview, live: live, sensors: sensors)
        }
    }

    static func valueText(_ seg: MenuBarSegment,
                          overview: [String: Any],
                          live: [String: Any],
                          sensors: [String: Any]) -> String {
        switch seg {
        // ---- CPU 组 ----
        case .cpuTemp:
            guard let t = MetricsHub.cpuTempC(sensors, live) else { return "—" }
            return String(format: "%.0f°", t)
        case .cpuFreq:
            let c = BackendService.dict(overview, "cpu") ?? [:]
            guard let mhz = BackendService.double(c, "freq_cur_mhz"), mhz > 0 else { return "—" }
            return compactMHz(mhz)
        case .cpuUsage:
            return String(format: "%.0f%%", BackendService.double(overview, "cpu_usage") ?? 0)
        case .cpuPower:
            guard let w = powerW(sensors, "PCPT") else { return "—" }
            return String(format: "%.1fW", w)
        case .cpuFan:
            let rpm = BackendService.int(live, "rpm_cpu") ?? 0
            return rpm > 0 ? "\(rpm)" : "—"
        case .igpuUsage:
            guard let u = igpuUsage(overview) else { return "—" }
            return String(format: "%.0f%%", u)
        case .igpuVram:
            guard let used = igpuVramBytes(overview) else { return "—" }
            return compactBytes(used)
        // ---- GPU 组 ----
        case .gpuTemp:
            guard let t = MetricsHub.gpuTempC(sensors, live), t > 0 else { return "—" }
            return String(format: "%.0f°", t)
        case .gpuFreq:
            guard let mhz = dgpuSensors(overview)["core_mhz"] as? Double, mhz > 0 else { return "—" }
            return compactMHz(mhz)
        case .gpuUsage:
            guard let u = dgpuUsageAvg(overview) else { return "—" }
            return String(format: "%.0f%%", u)
        case .grUsage:
            guard let u = dgpuUsageInstant(overview) else { return "—" }
            return String(format: "%.0f%%", u)
        case .gpuPower:
            guard let w = dgpuSensors(overview)["power_avg_w"] as? Double, w > 0 else { return "—" }
            return String(format: "%.1fW", w)
        case .gpuFan:
            let rpm = BackendService.int(live, "rpm_gpu") ?? 0
            return rpm > 0 ? "\(rpm)" : "—"
        case .gpuVram:
            guard let used = dgpuVramBytes(overview) else { return "—" }
            return compactBytes(used)
        // ---- 内存 ----
        case .memUsage:
            let m = BackendService.dict(overview, "memory") ?? [:]
            return String(format: "%.0f%%", BackendService.double(m, "percent") ?? 0)
        // ---- 网速（↑↓ 字形即图标）----
        case .netDown:
            let n = BackendService.dict(overview, "net") ?? [:]
            let down = (BackendService.double(n, "down_kbs") ?? 0) * 1024
            return "↓\(compactSpeed(down))"
        case .netUp:
            let n = BackendService.dict(overview, "net") ?? [:]
            let up = (BackendService.double(n, "up_kbs") ?? 0) * 1024
            return "↑\(compactSpeed(up))"
        case .netBoth:
            let n = BackendService.dict(overview, "net") ?? [:]
            let down = (BackendService.double(n, "down_kbs") ?? 0) * 1024
            let up = (BackendService.double(n, "up_kbs") ?? 0) * 1024
            return "↓\(compactSpeed(down)) ↑\(compactSpeed(up))"
        }
    }

    /// SMC 功率键读数（sensors.power 数组里按 key 找）
    private static func powerW(_ sensors: [String: Any], _ key: String) -> Double? {
        let list = (BackendService.array(sensors, "power") as? [[String: Any]]) ?? []
        for p in list where (BackendService.string(p, "key") ?? "") == key {
            return BackendService.double(p, "value")
        }
        return nil
    }

    /// 核显占用率：IOAccelerator 的 "Device Utilization %"（overview.gpu_usage）
    static func igpuUsage(_ overview: [String: Any]) -> Double? {
        BackendService.double(overview, "gpu_usage")
    }

    /// 核显显存占用：overview.gpu_stats 里 IntelAccelerator 条目的
    /// "In use system memory"（iGPU 没有独立显存，这是动态上限下的当前占用）
    static func igpuVramBytes(_ overview: [String: Any]) -> Double? {
        let stats = (BackendService.array(overview, "gpu_stats") as? [[String: Any]]) ?? []
        let entry = stats.first {
            (BackendService.string($0, "io_class") ?? "").localizedCaseInsensitiveContains("Intel")
        } ?? stats.first
        guard let entry else { return nil }
        return BackendService.double(entry, "In use system memory")
            ?? BackendService.double(entry, "vramUsedBytes")
            ?? BackendService.double(entry, "gartUsedBytes")
    }

    private static func dgpuSensors(_ overview: [String: Any]) -> [String: Any] {
        let d = BackendService.dict(overview, "dgpu") ?? [:]
        return BackendService.dict(d, "sensors") ?? [:]
    }

    private static func dgpuDict(_ overview: [String: Any]) -> [String: Any] {
        BackendService.dict(overview, "dgpu") ?? [:]
    }

    /// GPU 占用率（5 秒均值，耐看）。驱动没上报时 nil → 显示「—」。
    static func dgpuUsageAvg(_ overview: [String: Any]) -> Double? {
        let d = dgpuDict(overview)
        guard (BackendService.bool(d, "reported") ?? false) else { return nil }
        return BackendService.double(d, "gr_avg5_pct") ?? BackendService.double(d, "gr_pct")
    }

    /// GR 占用率（瞬时值）。同上，缺键显示「—」。
    static func dgpuUsageInstant(_ overview: [String: Any]) -> Double? {
        let d = dgpuDict(overview)
        guard (BackendService.bool(d, "reported") ?? false) else { return nil }
        return BackendService.double(d, "gr_pct")
    }

    /// 独显显存占用（GART 口径：vram_used_bytes，驱动 2.6.3+ 发布）
    static func dgpuVramBytes(_ overview: [String: Any]) -> Double? {
        guard (BackendService.bool(dgpuDict(overview), "reported") ?? false) else { return nil }
        guard let used = dgpuSensors(overview)["vram_used_bytes"] as? Double, used > 0 else { return nil }
        return used
    }

    /// 指定 bsd 的硬盘温度（SMART；15 秒缓存由后端做）
    static func diskText(overview: [String: Any], bsd: String) -> String {
        let list = (BackendService.array(overview, "smart") as? [[String: Any]]) ?? []
        let e = list.first { (BackendService.string($0, "bsd") ?? "") == bsd }
            ?? list.first { ($0["ok"] as? Bool) == true }
        guard let e else { return "—" }
        if let t = BackendService.double(e, "temperature_c") { return String(format: "%.0f°", t) }
        return "—"
    }

    // MARK: 紧凑格式

    /// 频率：完整单位 GHz / MHz（2026-11-16 用户要求 —— 只写 G/M 会和显存占用的
    /// M（MB）混淆）。段宽已自适应，长一点不遮邻段。
    static func compactMHz(_ mhz: Double) -> String {
        if mhz >= 1_000 { return String(format: "%.2fGHz", mhz / 1_000) }
        return String(format: "%.0fMHz", mhz)
    }

    /// 字节：完整单位 GB / MB（2026-11-16 用户要求，与频率 GHz/MHz 同口径，
    /// 裸 M/G 与频率歧义）。段宽自适应，长一点不遮邻段。
    static func compactBytes(_ bytes: Double) -> String {
        switch bytes {
        case 1_000_000_000...: return String(format: "%.1fGB", bytes / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.0fMB", bytes / 1_000_000)
        case 1_000...:         return String(format: "%.0fKB", bytes / 1_000)
        default:               return String(format: "%.0fB", bytes)
        }
    }

    /// 网速：十进制阈值，K/M/G 后缀（不带 /s，↓ 字形已表意）
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000:                  return "0"
        case 1_000..<1_000_000:         return String(format: "%.1fK", bytesPerSecond / 1_000)
        case 1_000_000..<1_000_000_000: return String(format: "%.1fM", bytesPerSecond / 1_000_000)
        default:                        return String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
        }
    }

    /// 网速：Stats Units.getReadableSpeed 同款（带 /s），Speed 双行小件使用
    static func netSpeedText(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000:                          return "0 KB/s"
        case 1_000..<1_000_000:                 return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        case 1_000_000..<100_000_000:           return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        case 100_000_000..<1_000_000_000:       return String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000: return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        default:                                return String(format: "%.1f TB/s", bytesPerSecond / 1_000_000_000_000)
        }
    }
}

// MARK: - 监控拼接条（挂进独立 NSStatusItem 的 SwiftUI 视图）
//
// 2026-11-16（用户要求）恢复原版 Stats 风格：上一版做的「SF 图标 + 数值」一行式
// 已废弃（图标 9pt 被嫌太小、网速段符号名是空渲染成「？」）。现在与原版
// MiniStatusItemView / NetStatusItemView 一致：
//   · Mini 段：固定宽 31pt，上行 7pt light 三字母标签（CPU/RAM/…），下行 12pt 数值；
//   · 网速上下行：Stats Speed 同款 55pt 双行（上=上传红点、下=下载蓝点，
//     ≥1KB/s 点亮系统红/蓝，速率 9pt light 右对齐，带 /s）；
//   · 菜单栏里**不放任何 SF 图标** —— 图标只出现在「状态栏显示」页和面板明细行。
// 段间距 4pt（比原版独立状态项的系统间隙 ~8pt 紧凑，用户要求的拼接形式）。

struct MenuBarMonitorBar: View {
    @ObservedObject private var hub = MetricsHub.shared
    /// 开关变化 → revision +1 强制本帧重算段清单（hub 每秒也会刷，但开关要立即生效）
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let refs = MenuBarMonitors.currentSegments(overview: hub.overview)
        HStack(spacing: 4) {
            ForEach(refs) { ref in
                MonitorSegmentView(ref: ref,
                                   overview: hub.overview,
                                   live: hub.live,
                                   sensors: hub.sensors)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        // 点监控条 → 打开主窗口（复用 S 飘带上那条 .skyCCShowMain 链路）
        .onTapGesture {
            NotificationCenter.default.post(name: .skyCCShowMain, object: nil)
        }
        // 内容宽一变就把状态项长度跟上去（hub 每拍都会动数值）
        .onAppear { MenuBarMonitors.shared.syncContentWidth() }
        .onReceive(hub.objectWillChange) { _ in
            MenuBarMonitors.shared.syncContentWidth()
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarMonitors.iconsChanged)) { _ in
            MenuBarMonitors.invalidateSegmentCache()   // 开关变了，段清单要重算
            revision &+= 1
            MenuBarMonitors.shared.syncVisibility()
            MenuBarMonitors.shared.syncContentWidth()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            MenuBarMonitors.invalidateSegmentCache()   // 用户可能直接改了 defaults
            revision &+= 1
            MenuBarMonitors.shared.syncContentWidth()
        }
        // 盘列表 / 段清单随快照变化时同步显隐（一眼空就藏）
        .onReceive(hub.$overview) { o in
            MenuBarMonitors.shared.syncVisibility(with: o)
        }
    }
}

/// 段渲染（状态项与「状态栏显示」页预览共用同一套，保证所见即所得）。
/// 2026-11-16（用户要求）：风扇转速段在数值前加风扇小图标 —— 两段裸数字
/// （CPU 2232 / GPU 2639）看不出哪个是哪个。
struct MonitorSegmentView: View {
    let ref: SegmentRef
    let overview: [String: Any]
    let live: [String: Any]
    let sensors: [String: Any]

    var body: some View {
        if case .seg(.netBoth) = ref {
            NetSpeedWidget(overview: overview)
        } else {
            MiniSegment(label: ref.menuLabel,
                        value: MenuBarMonitors.valueText(ref,
                                                         overview: overview,
                                                         live: live,
                                                         sensors: sensors),
                        valueIcon: Self.fanIcon(ref))
        }
    }

    /// 只有风扇转速段带图标
    static func fanIcon(_ ref: SegmentRef) -> String? {
        guard case .seg(let s) = ref, s == .cpuFan || s == .gpuFan else { return nil }
        return "fanblades"
    }
}

/// 原版 Stats Mini 风格段（MiniStatusItemView 同款）：上行 7pt light 标签、
/// 下行 12pt regular 数值，均左对齐，无图标。
/// 2026-11-16 用户要求：宽度**自适应**——31pt 只是下限（短值保持原版列宽，
/// 数字跳动不会牵动邻段）；"12.3W" / "100%" / "1.6G" 这类长值按内容撑开，
/// 不会压缩字号也不会蹭到下一段。右缘 3pt 内边距 + 段距 4pt = 长值后也有 7pt 空隙。
/// 2026-11-16 二改：
///   · 标签与数值的行距 1pt → 0（用户嫌中间隔太开）；
///   · 可选 valueIcon —— 风扇转速段数值前挂风扇小图（fanblades），不然
///     CPU 2232 / GPU 2639 两段裸数字分不清哪个是哪个。
struct MiniSegment: View {
    let label: String
    let value: String
    var valueIcon: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 7, weight: .light))
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: 2) {
                if let valueIcon {
                    // 2026-11-16（用户反馈）：不指定颜色，跟数值一样用默认前景色
                    // （跟随菜单栏深浅色，不搞特殊色）
                    Image(systemName: valueIcon)
                        .font(.system(size: 9, weight: .light))
                }
                Text(value)
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .frame(minWidth: 31, alignment: .leading)
        .padding(.trailing, 3)
    }
}

/// Stats Speed 双行网速小件（原版 NetStatusItemView 同款）：
/// 上排 = 上传（红点）、下排 = 下载（蓝点）；速率 9pt light；
/// ≥1KB/s 点亮系统红/蓝，否则圆点退化为文字色；无流量显示 "0 KB/s"（不是裸 "0"）。
/// 宽度自适应（原版固定 55pt 会截断 "12.3 MB/s" 这种长速率）：圆点 + 内容宽，
/// 右缘 3pt 内边距，与邻段保持呼吸空间。
struct NetSpeedWidget: View {
    let overview: [String: Any]

    var body: some View {
        let n = BackendService.dict(overview, "net") ?? [:]
        let up = (BackendService.double(n, "up_kbs") ?? 0) * 1024
        let down = (BackendService.double(n, "down_kbs") ?? 0) * 1024
        VStack(alignment: .leading, spacing: 1) {
            speedRow(MenuBarMonitors.netSpeedText(up), active: up >= 1024, dotColor: .systemRed)
            speedRow(MenuBarMonitors.netSpeedText(down), active: down >= 1024, dotColor: .systemBlue)
        }
        .padding(.trailing, 3)
    }

    private func speedRow(_ text: String, active: Bool, dotColor: NSColor) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color(nsColor: dotColor) : Color.primary.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .light).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
    }
}
