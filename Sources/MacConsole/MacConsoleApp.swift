import SwiftUI
import ServiceManagement
import AppKit

/// 主窗口修改了亮度/散热等设置后广播，菜单栏据此刷新显示。
/// MenuBarExtra 的 content 在 macOS 上常驻内存，不会自动跟随主窗口的状态变化，
/// 必须显式通知（这是「菜单栏显示与实际不符」bug 的修复核心之一）。
extension Notification.Name {
    static let macConsoleStateChanged = Notification.Name("MacConsoleStateChanged")
}

/// Bundle 版本号（侧边栏头部与「系统 → 版本」卡共用）
enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
    /// 硬件后端形态：2.5.0 起为进程内原生服务（无 Python 子进程）。
    /// 保留探测逻辑是为了升级过渡——旧版随包有 python-version.txt。
    static var backend: String {
        let roots = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python").path,
        ]
        for r in roots {
            let p = (r as NSString).appendingPathComponent("python-version.txt")
            if let s = try? String(contentsOfFile: p, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Python \(s.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        return "原生（进程内服务）"
    }
}

/// 激活策略：Info.plist 里 LSUIElement=1（agent，默认无 Dock、无主菜单）。
/// 主窗口打开时切 .regular → 左上角出现「Mac控制台」菜单（关闭/退出等齐全）；
/// 窗口关掉再切回 .accessory → 退回纯菜单栏常驻，不占 Dock。
/// （2026-10-19 修：用户反馈打开控制台后菜单栏没有程序名和关闭菜单）
enum AppPolicy {
    static func toRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
    static func toAccessory() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
    /// 主窗口判定：可见、不是面板、宽度够大（菜单栏面板只有 300 左右）
    static var noMainWindow: Bool {
        !NSApp.windows.contains { w in
            w.isVisible && !(w is NSPanel) && w.frame.width > 400
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 卸载器用：注销后台 helper 的 LaunchAgent 注册（SMAppService 的注册
        // 记录存在系统数据库里，光 bootout 或删 plist 是清不掉的）
        if CommandLine.arguments.contains("--unregister-helper") {
            let svc = SMAppService.agent(plistName: mcHelperAgentPlist)
            do {
                try svc.unregister()
                print("helper 已注销，status=\(svc.status.rawValue)")
            } catch {
                print("helper 注销失败：\(error.localizedDescription)")
            }
            exit(0)
        }
        // 开发用：--ui-shots <dir> 离屏渲染各页后退出（见 UIShot.swift）
        if UIShot.handleIfRequested() { return }
        // v2.4.3：恢复用户选的外观（浅色/深色/随系统，默认随系统）
        AppAppearance.current.apply()
        DispatchQueue.main.async { AppPolicy.toRegular() }
        // 菜单栏监控图标（AppKit 状态项，Stats 同款）：开关在「系统」页
        MenuBarMonitors.shared.start()
        // v2.5.x：服务随 app 启动即激活，不依赖主窗口弹出。
        // 否则开机自启（LSUIElement agent，主窗口不自动打开）后不点开界面，
        // helper 连接与菜单栏实时数据都不激活。start()/attach() 内部已幂等，
        // 主窗口 onAppear 再调一次也安全。
        Task { @MainActor in
            await BackendService.shared.start()
            await BackendService.shared.checkKext()
            MonitorStore.shared.attach(BackendService.shared)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if AppPolicy.noMainWindow { AppPolicy.toAccessory() }
            }
        }
    }
    /// 关窗口不退出（菜单栏继续常驻）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backend = BackendService.shared
    @StateObject private var store = MonitorStore.shared

    // 菜单栏监控项开关（Stats 式：每项一个图标 + 实时数值）

    var body: some Scene {
        // 主窗口：关闭后 app 不退出，继续在菜单栏后台运行；
        // 重新打开走菜单栏图标的「打开控制台」（openWindow id: main）
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(backend)
                .environmentObject(store)
                .frame(minWidth: 1020, minHeight: 660)
                .onAppear {
                    Task { await backend.start() }
                    Task { await backend.checkKext() }
                    store.attach(backend)
                    // 主窗口可见 → 切回 regular，菜单栏出现程序名/关闭/退出
                    AppPolicy.toRegular()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)

        // 菜单栏常驻图标：窗口关掉后控制台仍在后台运行，硬件状态实时可见
        MenuBarExtra {
            MenuBarView()
                .environmentObject(backend)
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        // window 风格：面板是独立小窗口，SwiftUI 控件原生渲染。
        // 默认 .menu 风格把控件强行压成 NSMenuItem——Slider 缩成一截、
        // HStack 间距错乱（2026-10-17 v2.3.1 截图实锤），不可用。
        .menuBarExtraStyle(.window)

    }
}


// MARK: - 菜单栏图标（风扇 + CPU 温度）
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        // 2026-10-19：温度改由「系统」页开关控制的监控图标显示，这里只留状态图标
        Image(systemName: store.connected ? "fanblades.fill" : "fanblades")
            .accessibilityLabel(store.connected ? "Mac控制台 · 已连接" : "Mac控制台 · 连接中断")
    }
}

// MARK: - 菜单栏弹出面板（.window 风格）
// 2026-10-19 v2.4.2 按用户要求重整：删掉 CPU温度/显卡温度/散热三格与亮度滑块，
// 只保留两类——「散热模式」（补上「手动」档，手动时带 L0-L7 滑条）和
// 「性能模式」（原「整机性能档」全局改名，三档按钮）。
struct MenuBarView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    @State private var fanMode: String = "normal"
    @State private var fanLevel: Double = 0
    @State private var perfIndex: Int = 0x11          // 0x11 / 0x22 / 0x33
    /// 乐观更新截止时刻：用户点了控件后 4 秒内以本地选择为准（后端轮询有 1s 延迟）
    @State private var overrideUntil: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac控制台")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("打开控制台") {
                    openWindow(id: "main")
                    AppPolicy.toRegular()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
            }

            // 散热模式（v2.4.2：新增「手动」；手动时给 L0-L7 档位滑条）
            VStack(alignment: .leading, spacing: 6) {
                Text("散热模式")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("散热模式", selection: fanModeBinding) {
                    Text("自动").tag("normal")
                    Text("基准 · 最大").tag("boost")
                    Text("手动").tag("custom")
                    Text("曲线").tag("curve")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if currentFanMode == "custom" {
                    HStack {
                        Text("手动档位").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("L\(Int(fanLevel)) · \(Int(24 + fanLevel * 4.14))% 占空比")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    Slider(value: $fanLevel, in: 0...7, step: 1) { editing in
                        if !editing {
                            overrideUntil = Date().addingTimeInterval(4)
                            Task { await applyLevel(Int(fanLevel)) }
                        }
                    }
                    .controlSize(.small)
                }
            }

            // 性能模式（v2.4.2 新增类目；原「整机性能档」改名，EC 0x07AB）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("性能模式")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("当前：\(perfName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    perfButton("专业", 0x11, Theme.red)
                    perfButton("平衡", 0x22, Theme.blue)
                    perfButton("省电", 0x33, Theme.green)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("退出控制台") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(VisualEffectBackground())
        .onAppear {
            syncFromBackend()
            // 2.7.1：MenuBarExtra 的 .window 面板同样依赖 app 处于 active 才会在
            // 点外部时收起；LSUIElement 常驻后台时不会自动激活，这里显式激活一次。
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            syncFromBackend()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .macConsoleStateChanged)) { _ in
            syncFromBackend()
        }
    }

    /// 性能模式三档按钮（紧凑版：图标 + 名称，选中即生效）
    private func perfButton(_ title: String, _ code: Int, _ tint: Color) -> some View {
        let active = perfIndex == code
        return Button {
            overrideUntil = Date().addingTimeInterval(4)
            perfIndex = code
            Task { await applyPerf(code) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: code == 0x11 ? "cpu" : (code == 0x22 ? "scale.3d" : "leaf"))
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(active ? Color.white : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? tint : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(active ? tint : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var currentFanMode: String {
        if let until = overrideUntil, Date() < until { return fanMode }
        let saved = BackendService.string(store.fan, "mode") ?? ""
        if saved == "curve" { return "curve" }
        let actual = BackendService.string(store.fan, "actual")
            ?? saved
        return (actual == "boost" || actual == "custom") ? actual : "normal"
    }

    private var fanModeBinding: Binding<String> {
        Binding(
            get: { currentFanMode },
            set: { newValue in
                fanMode = newValue
                overrideUntil = Date().addingTimeInterval(4)
                Task { await applyFanMode(newValue) }
            }
        )
    }

    /// 当前性能模式名（EC 0x07AB 回读优先，绝不反映"上次点了什么"）
    private var perfName: String {
        if let until = overrideUntil, Date() < until { return perfLabel(perfIndex) }
        if let mi = BackendService.int(store.fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi) {
            return perfLabel(mi)
        }
        return perfLabel(perfIndex)
    }

    private func perfLabel(_ code: Int) -> String {
        switch code {
        case 0x11: return "专业"
        case 0x22: return "平衡"
        case 0x33: return "省电"
        default: return "—"
        }
    }

    private func syncFromBackend() {
        fanMode = currentFanMode
        fanLevel = Double(BackendService.int(store.fan, "actual_level") ?? 0)
        if let mi = BackendService.int(store.fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi) {
            perfIndex = mi
        }
    }

    private func applyFanMode(_ m: String) async {
        var body: [String: Any] = ["mode": m]
        if m == "custom" { body["level"] = Int(fanLevel) }
        if m == "curve" {
            // 曲线配置以磁盘为唯一真相（helper 和应用两侧都是读它、写它），
            // 不再从本进程的 FanCurveController 取 —— 那个控制器已搬进后台 helper。
            let cfg = FanCurveStore.load() ?? .default
            body["source"] = cfg.source
            body["failsafe"] = cfg.failsafeTemp
            body["points"] = cfg.points.map { ["temp": $0.temp, "level": $0.level] }
        }
        _ = await backend.post("/api/fan", body)
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyLevel(_ lv: Int) async {
        _ = await backend.post("/api/fan", ["mode": "custom", "level": lv])
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyPerf(_ code: Int) async {
        _ = await backend.post("/api/fan", ["modeindex": code])
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }
}

// MARK: - macOS 材质背景
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 根视图：侧边栏 + 详情
//
// 2.7.0 重排：原来六个平铺页（仪表盘/监控/全部信息/控制/键盘灯效/系统）语义混乱——
// 「仪表盘」与「监控」有一半重叠，「控制」里塞了散热/充电/亮度/音量/休眠五类东西。
// 现在按「看」与「改」两分：
//   监测 · 概览（身份 + 6 个关键指标 + 系统）
//   监测 · 性能（每核 / 内存分项 / 双显卡 / 每卷 / SMART / 风扇 / 电池 / 进程）
//   硬件 · 控制（散热模式、性能模式、充电阈值、亮度、音量、休眠——全部写 EC）
//   硬件 · 灯效（键盘 RGB、白平衡、灯效保存）
//   系统 · 全部信息（原生采集的每个字段，排查用）
//   系统 · 设置（外观、菜单栏图标、版本、能力边界）
struct RootView: View {
    enum Page: String, CaseIterable, Identifiable {
        case overview, performance, control, lighting, alldata, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "概览"
            case .performance: return "性能"
            case .control: return "控制"
            case .lighting: return "灯效"
            case .alldata: return "全部信息"
            case .settings: return "设置"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: return "设备 · 关键指标 · 系统"
            case .performance: return "曲线 · 温度 · 风扇 · 磁盘"
            case .control: return "散热 / 性能 / 充电 / 亮度"
            case .lighting: return "键盘 RGB / 白平衡"
            case .alldata: return "原生采集的每个字段"
            case .settings: return "版本 / 外观 / 菜单栏"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .performance: return "waveform.path.ecg"
            case .control: return "slider.horizontal.3"
            case .lighting: return "keyboard"
            case .alldata: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
        var tint: Color {
            switch self {
            case .overview: return Theme.blue
            case .performance: return Theme.cyan
            case .control: return Theme.amber
            case .lighting: return Theme.purple
            case .alldata: return Theme.green
            case .settings: return Theme.dim
            }
        }
        /// 侧边栏分组标题
        var group: String {
            switch self {
            case .overview, .performance: return "监测"
            case .control, .lighting: return "硬件"
            case .alldata, .settings: return "系统"
            }
        }
        static let groups = ["监测", "硬件", "系统"]
        /// 侧边栏可见项。`alldata`（全部信息）按用户要求隐藏——原生字段表是排障用的，
        /// 留在代码里（case 与 AllDataView 都还在），需要时把这里过滤去掉即可恢复。
        static func inGroup(_ g: String) -> [Page] {
            allCases.filter { $0.group == g && $0 != .alldata }
        }
    }

    @State private var page: Page = .overview
    @EnvironmentObject private var backend: BackendService
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                // 侧边栏顶部：app 图标 + 名称 + 版本号（v2.4.3 新增）
                Section {
                    appHeaderRow
                }
                .listRowSeparator(.hidden)

                ForEach(Page.groups, id: \.self) { g in
                    Section {
                        ForEach(Page.inGroup(g)) { p in
                            navRow(p)
                                .tag(p)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text(g)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(1.0)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 270)
            // 侧边栏左下角：连接状态 + 退出控制台
            .safeAreaInset(edge: .bottom) { footerRow }
        } detail: {
            detailView
                .navigationTitle(page.title)
        }
    }

    /// 侧边栏一项：彩色圆角图标 + 标题 + 副标题
    private func navRow(_ p: Page) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(p.tint)
                .frame(width: 24, height: 24)
                .background(p.tint.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title).font(.system(size: 12.5, weight: .medium))
                Text(p.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 侧边栏顶部行：app 图标 + 「Mac控制台」+ 版本号
    private var appHeaderRow: some View {
        HStack(spacing: 11) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac控制台")
                    .font(.system(size: 14, weight: .semibold))
                Text("版本 \(AppVersion.short)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    /// app 图标：优先 bundle 里的 AppIcon.icns（构建脚本装到 Contents/Resources/），
    /// 回退系统 NSApplicationIcon（裸跑二进制时也能显示）
    private var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(named: NSImage.Name("NSApplicationIcon")) ?? NSImage()
    }

    /// 侧边栏左下角：后台服务状态 + 退出按钮
    private var footerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.connected ? Theme.green : Theme.red)
                .frame(width: 6, height: 6)
            Text(store.connected ? "helper 在线" : "helper 离线")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("退出控制台")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(VisualEffectBackground(material: .sidebar))
    }

    @ViewBuilder
    private var detailView: some View {
        switch page {
        case .overview: OverviewView()
        case .performance: MonitorView()
        case .control: ControlView()
        case .lighting: RGBView()
        case .alldata: AllDataView()
        case .settings: MiscView()
        }
    }
}
