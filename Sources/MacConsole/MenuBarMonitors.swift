import Cocoa
import SwiftUI

// ============================================================================
// 菜单栏监控图标（2026-10-19：按 exelban/Stats 同款几何重写，两轮用户反馈：
// 第一轮 ① NET 只有下行没有上行 ② 图标间缝隙偏大 ③ 整体样式与 Stats 不一致；
// 第二轮 ④ Mini 标签与数值叠层（SSD 快贴上 40°）⑤ NET→SSD 间距比 Stats 宽。
// ④的根因：本机菜单栏实测 22pt（视图 H=18），Stats 的标签 rect 是硬编码
// y=12，我写成 H-8 就低了 2pt；⑤的根因：Stats 速率文字默认右对齐贴项右缘，
// 我写成左对齐，项尾空了 ~21pt。均已按 Stats v3.0.22 源码常量修正。）
//
// 为什么不用 SwiftUI 的 MenuBarExtra 做这一排图标：
//   1) MenuBarExtra(isInserted:) 一旦使用，主窗口就不再自动创建（2.3.6 实测坑，
//      后端都不会启动），而且它也不支持运行时插拔单个图标；
//   2) 每个图标独立开关 + 各自的传感器面板，用 AppKit 状态项最直接。
//
// 样式基准（全部实测自 Stats v3.0.22 源码 Kit/Widgets/Mini.swift + Speed.swift，
// 注意：不是目测，用户机器菜单栏实测只有 22pt，视图 H=18）：
//   · Mini（CPU/RAM/GPU/SSD）：固定宽 31pt；标签 rect 硬编码 (0,12,31,7) 7pt light、
//     数值 rect 硬编码 (0,1,31,13) 12pt regular——两者都是 Stats 源码里的常量，
//     不要随 H 相对缩放（2.4.0 踩坑：H-8 在本机 22pt 菜单栏下标签低 2pt 叠层）。
//   · Speed（NET）：固定宽 55pt；文字 rect (7,·,48,·) 且**右对齐**
//     （Stats valueAlignment 默认 "right"），上行=上传（output，红点 y=10.5）、
//     下行=下载（input，蓝点）；速率 9pt light；格式十进制（"33 KB/s"，无流量也显示
//     "0 KB/s"）；圆点对应方向 ≥1KB/s 时用系统红/蓝，否则退化为文字色。
//     右对齐是 NET→下一项间距与 Stats 一致的关键；左对齐会在项尾空 ~21pt。
//   · 状态项：length = 内容精确宽度 + button.image = NSImage()（空图清掉默认
//     排版）——这是缝隙与 Stats 一样小的关键，固定宽/留白都会显缝隙。
//
// 数据源：MetricsHub 每 1 秒拉一次 /api/overview + /api/fan，状态项标题和
// 弹出面板共用这一份快照。开关状态存 UserDefaults（menubar.icon.<kind>），
// 「系统」页的开关改动通过 MenuBarMonitors.iconsChanged 通知触发重建。
// ============================================================================

/// 图标种类（每个种类 = 菜单栏一个状态项 + 一个传感器面板）
enum MenuBarIconKind: String, CaseIterable, Identifiable {
    case cpu, mem, gpu, disk, net
    var id: String { rawValue }
    var defaultsKey: String { "menubar.icon.\(rawValue)" }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .mem: return "内存"
        case .gpu: return "GPU"
        case .disk: return "硬盘"
        case .net: return "网络"
        }
    }

    /// SF Symbols（「系统」页开关行用；菜单栏里按 Stats 风格不放图标）
    ///
    /// ⚠ 2.8.8 修 bug：原来网络用的是 `arrow.down.arrow.up`，这个符号名在
    /// SF Symbols 里**不存在**（正确的是 `arrow.up.arrow.down`），
    /// `Image(systemName:)` 拿不到图就直接留白 —— 用户看到的就是
    /// 「网络前面没有图标」。改名字前先用 NSImage(systemSymbolName:) 验一遍。
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .mem: return "memorychip"
        case .gpu: return "bolt.horizontal.fill"
        case .disk: return "internaldrive"
        case .net: return "arrow.up.arrow.down"
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .cpu, .mem, .net: return true
        case .gpu, .disk: return false
        }
    }

    /// Mini 视图里的标签（对齐 Stats：三字母大写）
    var menuLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .mem: return "RAM"
        case .gpu: return "GPU"
        case .disk: return "SSD"
        case .net: return "NET"
        }
    }

    /// 状态项宽度：与 Stats 逐一致——Mini 固定 31pt、Speed 两行 55pt
    /// GPU 例外：指标为「占用率」时并排显示核显/独显两列，Mini 的 31pt 装不下，走双列视图
    var itemWidth: CGFloat {
        switch self {
        case .net: return NetStatusItemView.width
        case .gpu: return MenuBarMetric.current(for: .gpu) == .usage
                        ? GpuStatusItemView.width
                        : MiniStatusItemView.width
        default: return MiniStatusItemView.width
        }
    }

    /// 该种类的菜单栏数值是否可切换指标
    /// 2.7.5：硬盘也加进来（温度 / 已用寿命），并且可以指定看哪块盘
    var supportsMetric: Bool {
        switch self {
        case .cpu, .gpu, .disk: return true
        case .mem, .net: return false
        }
    }

    /// 可选的显示指标（决定设置页那一行放哪些分段）
    var metricOptions: [MenuBarMetric] {
        switch self {
        case .cpu, .gpu: return [.temp, .usage]
        case .disk: return [.temp, .life]
        case .mem, .net: return []
        }
    }

    /// 显示指标的 UserDefaults 键（v2.4.5 新增）
    var metricKey: String { "menubar.metric.\(rawValue)" }

    /// 硬盘图标看哪块盘（存 bsd 名，空 = 第一块能读的盘）
    static let diskTargetKey = "menubar.disk.bsd"

    var defaultMetric: MenuBarMetric {
        switch self {
        case .cpu, .gpu, .disk: return .temp   // v2.4.5：用户要求默认显示温度
        case .mem, .net: return .usage
        }
    }
}

/// 菜单栏图标显示的指标（CPU/GPU/硬盘可切，在「设置」页选择）
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case usage = "usage"
    case temp = "temp"
    case life = "life"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .usage: return "占用率"
        case .temp: return "温度"
        case .life: return "已用寿命"
        }
    }

    /// 当前生效的指标（读 UserDefaults，带默认值回落）
    static func current(for kind: MenuBarIconKind) -> MenuBarMetric {
        guard kind.supportsMetric,
              let raw = UserDefaults.standard.string(forKey: kind.metricKey),
              let m = MenuBarMetric(rawValue: raw) else { return kind.defaultMetric }
        return m
    }
}

/// 后端快照中枢：菜单栏标题与弹出面板共用的唯一数据源
///
/// 2.7.0：不再自己轮询。旧实现每 2 秒额外打 /api/overview + /api/fan，
/// 而 MonitorStore 同期也在打快照——等于让 helper 重复组两份包、EC 采样器被
/// 两处同时触发（实测 /api/fan 延迟因此在 0.2–3.2s 之间乱跳）。
/// 现在数据统一由 MonitorStore 的 /api/snapshot（1 秒一次）推过来。
@MainActor
final class MetricsHub: ObservableObject {
    static let shared = MetricsHub()
    @Published var overview: [String: Any] = [:]
    @Published var live: [String: Any] = [:]
    /// SMC 传感器表（系统温度来源，和风扇 / EC 无关）
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
    func ingest(overview o: [String: Any], live l: [String: Any], sensors s: [String: Any]) {
        overview = o
        live = l
        sensors = s
        MenuBarMonitors.shared.refreshTitles()
    }

    /// 菜单栏 CPU 温度：**直接取 SMC 快照**（系统传感器表），不经过风扇 / EC 那条链。
    ///
    /// `live["temp_cpu"]` 在后端虽然也是 SMC 取的，但它挂在 fan payload 下面，
    /// 读代码时很容易被当成「风扇 / EC 数据」。菜单栏只要一个温度数字，
    /// 从 `sensors.raw_temps` 取最直接，也保证 kext 没加载时照样有值。
    static func cpuTempC(_ sensors: [String: Any], _ live: [String: Any]) -> Double? {
        if let raw = sensors["raw_temps"] as? [String: Any] {
            for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H"] {
                if let n = raw[key] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
            }
        }
        return BackendService.double(live, "temp_cpu")
    }

    /// 菜单栏 GPU 温度：NVAccel 上报的核心温度（本来就不经过 EC）。
    static func gpuTempC(_ sensors: [String: Any], _ live: [String: Any]) -> Double? {
        BackendService.double(live, "temp_gpu")
    }
}

@MainActor
final class MenuBarMonitors: NSObject {
    static let shared = MenuBarMonitors()
    static let iconsChanged = Notification.Name("MenuBarIconsChanged")

    private var items: [MenuBarIconKind: NSStatusItem] = [:]
    private var itemViews: [MenuBarIconKind: NSView] = [:]
    private var buttonKinds: [ObjectIdentifier: MenuBarIconKind] = [:]
    private var currentKind: MenuBarIconKind?
    private var popover: NSPopover?
    /// 同一次点击去重：子视图 mouseDown 与按钮 action 可能同时触发（不同 macOS
    /// 版本行为不一致），0.35s 内同图标的第二次调用直接忽略，避免「开了又关」。
    private var lastClick: (kind: MenuBarIconKind, at: Date)?

    /// 诊断日志：排查菜单栏点击不走/双走时用（/tmp/macconsole-menubar.log）
    private func diag(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/macconsole-menubar.log")
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func start() {
        UserDefaults.standard.register(defaults: [
            MenuBarIconKind.cpu.defaultsKey: true,
            MenuBarIconKind.mem.defaultsKey: true,
            MenuBarIconKind.gpu.defaultsKey: false,
            MenuBarIconKind.disk.defaultsKey: false,
            MenuBarIconKind.net.defaultsKey: true,
            // v2.4.5：菜单栏 CPU 默认显示温度（占用率可在「系统」页切回）
            MenuBarIconKind.cpu.metricKey: MenuBarMetric.temp.rawValue,
            // GPU 例外：2026-10-26 用户要求 GPU 图标并排显示核显与独显两项，默认给占用率。
            // 想看温度在「系统」页切回「温度」即可，切回去就是原来的单列 31pt 图标。
            MenuBarIconKind.gpu.metricKey: MenuBarMetric.usage.rawValue,
        ])
        rebuild()
        NotificationCenter.default.addObserver(
            forName: Self.iconsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        MetricsHub.shared.start()
    }

    /// 按开关状态重建所有状态项（「系统」页开关变化时调用）
    func rebuild() {
        for kind in MenuBarIconKind.allCases {
            let want = UserDefaults.standard.bool(forKey: kind.defaultsKey)
            let has = items[kind] != nil
            if want && !has { createItem(kind) }
            if !want && has { removeItem(kind) }
        }
        // 指标可能也一起变了（GPU 温度↔占用率是两种视图、两种宽度），交给它按需重建
        refreshTitles()
    }

    private func createItem(_ kind: MenuBarIconKind) {
        let item = NSStatusBar.system.statusItem(withLength: kind.itemWidth)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        // Stats 同款紧凑三件套：
        //  ① 空 image——清掉按钮默认的 image/title 排版，自定义视图才不会有多余内边距
        //  ② length = 内容精确宽度——固定宽/留白都会显出缝隙（2.3.9 用户反馈的根因）
        //  ③ 自定义视图贴 (0, 2) 放入按钮，高度 = 菜单栏厚度 - 4（上下各 2pt）
        button.image = NSImage()
        button.title = ""
        let view = makeView(kind)
        view.frame = NSRect(x: 0, y: 2, width: kind.itemWidth,
                            height: max(0, NSStatusBar.system.thickness - 4))
        view.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        view.onClick = { [weak self] in self?.handleClick(kind, via: "view-mouseDown") }
        button.subviews = [view]
        item.length = kind.itemWidth
        item.autosaveName = "MacConsole_\(kind.rawValue)"
        // 点击双通道（2026-10-20 修复 macOS 15 菜单栏图标点不动）：
        //   通道① 按钮自身 target/action —— 某些系统版本上菜单栏窗口不会把鼠标事件
        //          送进按钮子视图，只有按钮自己能收到（原方案只挂子视图手势识别器，
        //          在 macOS 15 上实测完全不触发，macOS 26 正常）；
        //   通道② 子视图重写 mouseDown/rightMouseDown（见 MiniStatusItemView.onClick）。
        // 两条路都进 handleClick，内部按时间戳去重，绝不会一次点击开+关弹两遍。
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buttonKinds[ObjectIdentifier(button)] = kind
        items[kind] = item
        itemViews[kind] = view
        // 菜单栏本身就是「有人在看」——不加这一句，用户切到别的页面看菜单栏时
        // 独显那一格会 10 秒才动一次（NVAccelUtil 的按需节流），看着像卡住了。
        if kind == .gpu { MonitorStore.shared.demandDgpu(true) }
        updateView(kind)   // 立即填一次值，避免首帧空白
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let kind = buttonKinds[ObjectIdentifier(sender)] else { return }
        handleClick(kind, via: "button-action")
    }

    /// 点击统一入口（两条通道汇合处）。0.35s 内同图标的重复调用视为同一次点击。
    private func handleClick(_ kind: MenuBarIconKind, via: String) {
        let now = Date()
        if let last = lastClick, last.kind == kind, now.timeIntervalSince(last.at) < 0.35 {
            diag("click \(kind.rawValue) via \(via) —— 0.35s 内重复，去重忽略")
            return
        }
        lastClick = (kind, now)
        diag("click \(kind.rawValue) via \(via)")
        clicked(kind)
    }

    private func makeView(_ kind: MenuBarIconKind) -> NSView & StatusItemClickableView {
        switch kind {
        case .net: return NetStatusItemView()
        case .gpu where MenuBarMetric.current(for: .gpu) == .usage: return GpuStatusItemView()
        default: return MiniStatusItemView(label: kind.menuLabel)
        }
    }

    private func removeItem(_ kind: MenuBarIconKind) {
        if let it = items[kind] {
            if let b = it.button { buttonKinds.removeValue(forKey: ObjectIdentifier(b)) }
            NSStatusBar.system.removeStatusItem(it)
        }
        // 与 createItem 里的登记配对，别漏 —— 漏了会让 MonitorStore 的需求计数只增不减
        if kind == .gpu, items[kind] != nil { MonitorStore.shared.demandDgpu(false) }
        items[kind] = nil
        itemViews[kind] = nil
    }

    /// 点窗口外关闭弹窗的全局监听（2.7.1 修 bug）
    ///
    /// NSPopover 的 `.transient` 依赖「本应用是活动应用」才在外部点击时自动收，
    /// 而状态栏图标弹出的窗口不会把 app 变成 active —— 于是用户看到的现象就是
    /// 「点桌面不消失，只有再点一次图标才关」。这里补一个全局鼠标监听兜底：
    /// 鼠标事件不需要辅助功能授权（只有键盘事件才要）。
    private var outsideMonitor: Any?

    private func clicked(_ kind: MenuBarIconKind) {
        guard let item = items[kind], let button = item.button else { return }
        if let p = popover, p.isShown, currentKind == kind {
            closePopover()
            return
        }
        closePopover()
        let p = NSPopover()
        p.behavior = .transient
        p.contentSize = NSSize(width: panelWidth(kind), height: 96)
        p.contentViewController = NSHostingController(
            rootView: SensorPanelView(kind: kind).environmentObject(MetricsHub.shared))
        popover = p
        currentKind = kind
        // 先激活自己：.transient 与内部控件的键盘焦点都依赖 app 处于 active
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installOutsideMonitor()
    }

    /// 点任何别处（桌面 / 其它 app / 其它窗口）都收起弹窗
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func closePopover() {
        popover?.close()
        popover = nil
        currentKind = nil
        if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
    }

    private func panelWidth(_ kind: MenuBarIconKind) -> CGFloat {
        switch kind {
        case .mem, .net: return 268   // 三格
        // 2026-10-26：GPU 面板拆成 核显占用 / 独显占用 / 独显温度 三格，跟内存一样宽
        case .gpu: return 268
        // 2026-10-25：CPU 面板去掉风扇转速，只剩温度 + 占用两格
        case .cpu, .disk: return 196
        }
    }

    /// 由 hub 数据刷新图标。视图是 AppKit 自绘，这里只推数值 + needsDisplay；
    /// 顺手做存在性校验（视图被系统异常摘掉时重建）。
    ///
    /// 2026-10-26：还要校验**宽度**。GPU 的「占用率」是双列 64pt、「温度」是单列 31pt，
    /// 设置页切指标只调到这里（不重建状态项），宽度对不上就会沿用旧值 ——
    /// 64pt 的视图塞进 31pt 的项、或者 31pt 的视图占着 64pt 的位置，两种都难看。
    func refreshTitles() {
        let broken = items.filter { ($0.value.button?.subviews.isEmpty ?? true) }.map { $0.key }
        // 重建后 createItem 会把 length 设成 kind.itemWidth，所以这一条会自愈、不会每秒重来。
        // 留 0.5pt 容差：万一系统对 length 做了取整，也不至于每帧都判成「变了」而反复重建（会闪）。
        let resized = items.filter { abs($0.value.length - $0.key.itemWidth) > 0.5 }.map { $0.key }
        for kind in Set(broken + resized) {
            removeItem(kind)
            createItem(kind)
        }
        for kind in items.keys { updateView(kind) }
    }

    private func updateView(_ kind: MenuBarIconKind) {
        let overview = MetricsHub.shared.overview
        switch kind {
        case .cpu:
            // v2.4.5：CPU 按「系统」页设置的指标显示（默认温度）
            (itemViews[kind] as? MiniStatusItemView)?.value =
                Self.metricText(for: kind, overview: overview,
                                live: MetricsHub.shared.live,
                                sensors: MetricsHub.shared.sensors)
        case .gpu:
            // 双列视图（占用率模式）：核显 / 独显并排，各带标签
            if let v = itemViews[kind] as? GpuStatusItemView {
                v.igpu = Self.pctText(Self.igpuUsage(overview))
                v.dgpu = Self.pctText(Self.dgpuUsage(overview))
            } else {
                // 温度模式：还是原来的单列 Mini 图标
                (itemViews[kind] as? MiniStatusItemView)?.value =
                    Self.metricText(for: kind, overview: overview,
                                    live: MetricsHub.shared.live,
                                    sensors: MetricsHub.shared.sensors)
            }
        case .mem:
            let m = BackendService.dict(overview, "memory")
            (itemViews[kind] as? MiniStatusItemView)?.value =
                String(format: "%.0f%%", BackendService.double(m, "percent") ?? 0)
        case .disk:
            // 2.7.5：温度 / 已用寿命，数据来自 nvmesmart 的逐盘 SMART（overview.smart）
            (itemViews[kind] as? MiniStatusItemView)?.value =
                Self.diskText(for: overview)
        case .net:
            guard let v = itemViews[kind] as? NetStatusItemView else { return }
            let n = BackendService.dict(overview, "net") ?? [:]
            // 后端给的是 KiB/s（字节差 ÷1024）；Stats 按十进制（÷1000）格式化，
            // 先还原成 B/s 再走 Stats 同款阈值
            let up = (BackendService.double(n, "up_kbs") ?? 0) * 1024
            let down = (BackendService.double(n, "down_kbs") ?? 0) * 1024
            v.upload = Self.speedText(up)
            v.download = Self.speedText(down)
            v.uploadActive = up >= 1024
            v.downloadActive = down >= 1024
        }
    }

    /// Stats Units.getReadableSpeed 同款：十进制阈值，无流量显示 "0 KB/s"（不是 "0K"）
    static func speedText(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000:
            return "0 KB/s"
        case 1_000..<1_000_000:
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        case 1_000_000..<100_000_000:
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        case 100_000_000..<1_000_000_000:
            return String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000:
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        default:
            return String(format: "%.1f TB/s", bytesPerSecond / 1_000_000_000_000)
        }
    }

    /// v2.4.5：CPU/GPU 菜单栏数值——按「系统」页设置的指标取温度或占用率。
    /// 温度源是 MetricsHub.live 的 `temp_cpu`/`temp_gpu` —— 那是 SMC 封装温度
    /// 与 NVAccel 核心温度，**两者都不经过 EC**；占用源是 overview。
    static func metricText(for kind: MenuBarIconKind,
                           overview: [String: Any],
                           live: [String: Any],
                           sensors: [String: Any] = [:]) -> String {
        switch MenuBarMetric.current(for: kind) {
        case .usage:
            let key = kind == .cpu ? "cpu_usage" : "gpu_usage"
            return String(format: "%.0f%%", BackendService.double(overview, key) ?? 0)
        case .temp:
            // 系统温度：CPU 直接读 SMC（TC0P 等），GPU 读 NVAccel。都不经过 EC。
            let t = kind == .cpu ? MetricsHub.cpuTempC(sensors, live)
                                 : MetricsHub.gpuTempC(sensors, live)
            guard let t else { return "—" }
            return String(format: "%.0f°", t)
        case .life:
            return "—"
        }
    }

    /// 核显占用率：IOAccelerator 的 "Device Utilization %"（overview.gpu_usage）
    static func igpuUsage(_ overview: [String: Any]) -> Double? {
        BackendService.double(overview, "gpu_usage")
    }

    /// 独显占用率：NVAccel RM 的 GPUMON perfmon（issue #324），取 GR 引擎 **5 秒均值**。
    ///
    /// 为什么用均值：固件按整秒统计，瞬时值是一秒一跳的台阶（实测 0% → 99% 一步到位），
    /// 菜单栏只有一行字，跳起来比进度条更刺眼。均值在同一次查询里就算好了，零额外开销。
    ///
    /// 驱动没上报时返回 nil → 界面显示「—」而不是 0%。这条很重要：
    /// 2.4.3 + NVK 时期的驱动会把样本结构完整写回但 util 恒为 0，
    /// 显示成 0% 会让人以为「独显真的闲着」。
    static func dgpuUsage(_ overview: [String: Any]) -> Double? {
        let d = BackendService.dict(overview, "dgpu") ?? [:]
        guard (BackendService.bool(d, "reported") ?? false) else { return nil }
        // 回退到瞬时值：装的是新 app、helper 还没重启时 payload 里没有均值字段，
        // 这时宁可显示会跳台阶的瞬时值，也不要显示「—」让人以为功能坏了。
        return BackendService.double(d, "gr_avg5_pct") ?? BackendService.double(d, "gr_pct")
    }

    /// 菜单栏用的百分比文本（无值时给「—」）
    static func pctText(_ v: Double?) -> String {
        v.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    /// 2.7.5：硬盘图标选中的那块盘的 SMART 条目
    static func diskEntry(_ overview: [String: Any]) -> [String: Any] {
        let list = (BackendService.array(overview, "smart") as? [[String: Any]]) ?? []
        let want = UserDefaults.standard.string(forKey: MenuBarIconKind.diskTargetKey) ?? ""
        if !want.isEmpty,
           let e = list.first(where: { ($0["bsd"] as? String) == want }) { return e }
        return list.first(where: { ($0["ok"] as? Bool) == true }) ?? [:]
    }

    /// 硬盘图标的数值：温度（℃）或已用寿命（%）
    static func diskText(for overview: [String: Any]) -> String {
        let e = diskEntry(overview)
        switch MenuBarMetric.current(for: .disk) {
        case .life:
            guard let u = BackendService.int(e, "percentage_used") else { return "—" }
            return "\(u)%"
        default:
            if let t = BackendService.double(e, "temperature_c") { return String(format: "%.0f°", t) }
            // 没有逐盘 SMART 时退回旧的单盘温度接口
            let d = BackendService.dict(overview, "disk_temp")
            if (d?["ok"] as? Bool) == true, let t = BackendService.double(d, "temperature_c") {
                return String(format: "%.0f°", t)
            }
            return "—"
        }
    }
}

// MARK: - 点击弹出的传感器面板（样式对齐截图：小字类型在上，大字数值在下）

struct SensorPanelView: View {
    @EnvironmentObject var hub: MetricsHub
    let kind: MenuBarIconKind

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { t in
                tile(t.element.0, t.element.1, t.element.2)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    /// (标签, 数值, 单位)
    private var tiles: [(String, String, String)] {
        switch kind {
        case .cpu:
            // 2026-10-25 用户要求：只留温度 + 占用，风扇转速从这一格里删掉
            let temp = MetricsHub.cpuTempC(hub.sensors, hub.live)
            let usage = BackendService.double(hub.overview, "cpu_usage")
            return [("CPU 温度", temp.map { String(format: "%.0f", $0) } ?? "—", "℃"),
                    ("CPU 占用", usage.map { String(format: "%.0f", $0) } ?? "—", "%")]
        case .mem:
            let m = BackendService.dict(hub.overview, "memory")
            let pct = BackendService.double(m, "percent")
            let used = BackendService.double(m, "used")
            let total = BackendService.double(m, "total")
            return [("内存占用", pct.map { String(format: "%.0f", $0) } ?? "—", "%"),
                    ("已用", used.map { String(format: "%.1f", $0 / 1e9) } ?? "—", "GB"),
                    ("总量", total.map { String(format: "%.0f", $0 / 1e9) } ?? "—", "GB")]
        case .gpu:
            // 2026-10-26：核显与独显分开两格，标签写清楚是哪一颗。
            // 温度那一格是 NVAccel 上报的 GPU 核心温度（TSENS，PR #323）—— 那是独显的，所以标「独显温度」。
            let temp = MetricsHub.gpuTempC(hub.sensors, hub.live)
            let igpu = MenuBarMonitors.igpuUsage(hub.overview)
            let dgpu = MenuBarMonitors.dgpuUsage(hub.overview)
            return [("iGPU 占用", igpu.map { String(format: "%.0f", $0) } ?? "—", "%"),
                    ("dGPU 占用", dgpu.map { String(format: "%.0f", $0) } ?? "—", "%"),
                    ("dGPU 温度", temp.map { String(format: "%.0f", $0) } ?? "—", "℃")]
        case .disk:
            // 2.7.5：面板跟着「选中的那块盘」走
            let e = MenuBarMonitors.diskEntry(hub.overview)
            let t = BackendService.double(e, "temperature_c")
            let used = BackendService.int(e, "percentage_used")
            let spare = BackendService.int(e, "available_spare")
            return [("硬盘温度", t.map { String(format: "%.0f", $0) } ?? "—", "℃"),
                    ("已用寿命", used.map { "\($0)" } ?? "—", "%"),
                    ("可用备件", spare.map { "\($0)" } ?? "—", "%")]
        case .net:
            let n = BackendService.dict(hub.overview, "net") ?? [:]
            let down = BackendService.double(n, "down_kbs") ?? 0
            let up = BackendService.double(n, "up_kbs") ?? 0
            func f(_ v: Double) -> String { v >= 1024 ? String(format: "%.1f", v / 1024) : String(format: "%.0f", v) }
            let unit: String = (down >= 1024 || up >= 1024) ? "MB/s" : "KB/s"
            return [("下行", f(down), unit), ("上行", f(up), unit)]
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }
}


// MARK: - 菜单栏图标本体（AppKit 自绘，逐指标复刻 Stats 几何）

/// 菜单栏图标视图的点击出口。两条点击通道（子视图 mouseDown / 按钮 action）都经它
/// 汇入 MenuBarMonitors.handleClick。
protocol StatusItemClickableView: NSView {
    var onClick: (() -> Void)? { get set }
}

/// Stats「Mini」widget 同款（CPU/RAM/GPU/SSD）：
/// 固定宽 31pt；标签 rect (0,12,31,7) 7pt light、数值 rect (0,1,31,13) 12pt regular
/// ——硬编码对齐 Stats 源码，本机菜单栏 22pt（视图 18pt 高）下不缩放。
final class MiniStatusItemView: NSView, StatusItemClickableView {
    static let width: CGFloat = 31

    let label: String
    var value: String = "—" {
        didSet { if oldValue != value { needsDisplay = true } }
    }

    /// 点击回调（MenuBarMonitors 注入）。菜单栏窗口在部分 macOS 版本上不会把鼠标
    /// 事件送进按钮子视图（2026-10-20 实测：macOS 15 上「子视图 + 手势识别器」
    /// 完全不触发，macOS 26 正常），所以子视图自己也接一份，与按钮的 target/action
    /// 双保险；两条路径都汇入 MenuBarMonitors.handleClick，靠时间去重，不会双弹。
    var onClick: (() -> Void)?

    init(label: String) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 2, width: Self.width,
                                 height: max(0, NSStatusBar.system.thickness - 4)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent?) { onClick?() }
    override func rightMouseDown(with event: NSEvent?) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let textColor = NSColor.labelColor
        // 标签：Stats Mini.swift 硬编码 rect (x:0, y:12, w:31, h:7)，7pt light。
        // ⚠️ 不要改成 H-8 之类的相对定位：本机菜单栏实测 22pt（视图 H=18），
        // 相对定位会把标签压低 2pt 与数值叠层（2.4.0 用户反馈的 bug）。
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: textColor,
        ]
        NSAttributedString(string: label, attributes: labelAttributes)
            .draw(in: NSRect(x: 0, y: 12, width: Self.width, height: 7))
        // 数值：Stats 硬编码 rect (x:0, y:1, w:31, h:13)，12pt regular
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: textColor,
        ]
        NSAttributedString(string: value, attributes: valueAttributes)
            .draw(in: NSRect(x: 0, y: 1, width: Self.width, height: 13))
    }
}

/// GPU 双列图标：iGPU / dGPU 并排，各带一行标签。
///
/// 为什么要单独做一个视图：Mini 是 31pt 单列，塞不下两个「带标注」的百分比。
///
/// 宽度是按实测字宽定的，别随手改小：
///   11pt regular 下 "100%" = 29.40pt、"99%" = 24.38pt、"12%" = 22.11pt、"—" = 9.68pt
///   7pt  light   下 "iGPU" = 17.13pt、"dGPU" = 19.77pt
/// 所以列宽必须 ≥ 30pt（由 "100%" 决定），取 31pt 留 1.6pt 余量
/// （"100%" 是真会出现的：满载实测 99.01%）。标签比列宽窄，不会挤。
/// 总宽 31 + 2 + 31 = 64pt，比 NET 的 55pt 略宽，是菜单栏里最宽的一项，但已经是
/// 「两个带标签的百分比」的合理下限。
///
/// 行高与字号沿用 MiniStatusItemView 的硬编码几何（标签 y=12 h=7、数值 y=1 h=13），
/// 理由见那边的注释：相对定位在 22pt 菜单栏（视图 18pt 高）下会把两行叠在一起。
final class GpuStatusItemView: NSView, StatusItemClickableView {
    static let width: CGFloat = 64
    private static let colW: CGFloat = 31
    private static let gap: CGFloat = 2

    /// 左列 = iGPU，右列 = dGPU。无值时为「—」（驱动未上报 ≠ 0%）
    var igpu: String = "—" {
        didSet { if oldValue != igpu { needsDisplay = true } }
    }
    var dgpu: String = "—" {
        didSet { if oldValue != dgpu { needsDisplay = true } }
    }

    /// 点击回调（双通道 + 去重，见 MiniStatusItemView.onClick 注释）
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 2, width: Self.width,
                                height: max(0, NSStatusBar.system.thickness - 4)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent?) { onClick?() }
    override func rightMouseDown(with event: NSEvent?) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let textColor = NSColor.labelColor
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: textColor,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: textColor,
        ]
        for (i, pair) in [("iGPU", igpu), ("dGPU", dgpu)].enumerated() {
            let x = CGFloat(i) * (Self.colW + Self.gap)
            NSAttributedString(string: pair.0, attributes: labelAttributes)
                .draw(in: NSRect(x: x, y: 12, width: Self.colW, height: 7))
            NSAttributedString(string: pair.1, attributes: valueAttributes)
                .draw(in: NSRect(x: x, y: 1, width: Self.colW, height: 13))
        }
    }
}

/// Stats「Speed」(twoRows) widget 同款（NET）：
/// 固定宽 55pt；速率文字右对齐贴项右缘（Stats valueAlignment 默认 "right"），
/// 上行=上传（红点，Stats output y=10.5）、下行=下载（蓝点）；速率 9pt light；
/// 无流量也显示 "0 KB/s"（Stats 同款，不是裸 "0K"）；
/// 圆点颜色：对应方向速率 ≥1KB/s 时系统红/蓝，否则退化为文字色。
final class NetStatusItemView: NSView, StatusItemClickableView {
    static let width: CGFloat = 55

    var upload: String = "0 KB/s" {
        didSet { if oldValue != upload { needsDisplay = true } }
    }
    var download: String = "0 KB/s" {
        didSet { if oldValue != download { needsDisplay = true } }
    }
    var uploadActive = false {
        didSet { if oldValue != uploadActive { needsDisplay = true } }
    }
    var downloadActive = false {
        didSet { if oldValue != downloadActive { needsDisplay = true } }
    }

    /// 点击回调（见 MiniStatusItemView.onClick 注释：双通道 + 去重）
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent?) { onClick?() }
    override func rightMouseDown(with event: NSEvent?) { onClick?() }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 2, width: Self.width,
                                height: max(0, NSStatusBar.system.thickness - 4)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let H = bounds.height
        let rowH = H / 2
        let textColor = NSColor.labelColor
        // Stats Speed.swift 默认 valueAlignment = "right"：速率文字右对齐贴在
        // 55pt 项右缘（rect x=7 宽 48）——这是 NET→下一项距离与 Stats 一样窄的关键，
        // 左对齐会在项尾部空出 ~21pt（2.4.0 用户反馈“网络到 SSD 距离宽”的根因）。
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .light),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
        // 上行（上传）：红点 + 速率，贴上排（Stats displayValueState="oi"：output 在上）
        NSAttributedString(string: upload, attributes: valueAttributes)
            .draw(in: NSRect(x: 7, y: rowH + 1, width: 48, height: rowH))
        // Stats drawDots（"oi"）：output（上传）圆点硬编码 y=10.5；
        // input（下载）圆点 y=(rowH-6)/2-0.2；本机 rowH=9 时 10.5 正好居中于上排
        dot(at: NSPoint(x: 0, y: 10.5),
            color: uploadActive ? .systemRed : textColor)
        // 下行（下载）：蓝点 + 速率，贴下排
        NSAttributedString(string: download, attributes: valueAttributes)
            .draw(in: NSRect(x: 7, y: 1, width: 48, height: rowH))
        dot(at: NSPoint(x: 0, y: (rowH - 6) / 2 - 0.2),
            color: downloadActive ? .systemBlue : textColor)
    }

    private func dot(at origin: NSPoint, color: NSColor) {
        color.set()
        NSBezierPath(ovalIn: NSRect(origin: origin, size: NSSize(width: 6, height: 6))).fill()
    }
}
