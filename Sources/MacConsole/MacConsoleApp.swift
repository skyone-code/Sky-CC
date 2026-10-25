import SwiftUI
import ServiceManagement
import AppKit

/// 主窗口修改了亮度/散热等设置后广播，菜单栏据此刷新显示。
/// MenuBarExtra 的 content 在 macOS 上常驻内存，不会自动跟随主窗口的状态变化，
/// 必须显式通知（这是「菜单栏显示与实际不符」bug 的修复核心之一）。
extension Notification.Name {
    static let macConsoleStateChanged = Notification.Name("MacConsoleStateChanged")
    /// 请求把主窗口叫出来（后台静默启动时，用户双击 app 或点菜单栏「打开控制台」）
    static let macConsoleShowMain = Notification.Name("MacConsoleShowMain")
    /// 请求切到某个标签页（object 传 Page.rawValue）。
    /// 2.8.3：控制页的「去灯效页」按钮（海岸灯搬去灯效页后留的入口）用它跳转。
    static let mcGotoPage = Notification.Name("MacConsoleGotoPage")
    /// **跨进程**：第二个实例被单实例锁挡住时，用它请已在运行的实例把主窗口叫出来。
    /// 必须走 DistributedNotificationCenter（本地 NotificationCenter 出不了进程）。
    static let mcShowMainFromOther = Notification.Name("MacConsoleShowMainFromOther")
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
    static var backend: String { "原生（进程内服务）" }
}

/// 激活策略：Info.plist 里 LSUIElement=1（agent，默认无 Dock、无主菜单）。
/// 主窗口打开时切 .regular → 左上角出现「Mac控制台」菜单（关闭/退出等齐全）；
/// 窗口关掉再切回 .accessory → 退回纯菜单栏常驻，不占 Dock。
/// （2026-10-19 修：用户反馈打开控制台后菜单栏没有程序名和关闭菜单）
enum AppPolicy {
    static func toRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // 2.7.8：setActivationPolicy 会重新向 WindowServer 注册进程，把已挂上的
        // Carbon 热键打掉 —— 每次改完策略必须重挂，否则触控板手势会静默失效
        GestureHotkey.shared.reregister(reason: "toRegular")
    }
    static func toAccessory() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        GestureHotkey.shared.reregister(reason: "toAccessory")
    }
    /// 把 app 叫到前台。macOS 14 起 `activate(ignoringOtherApps:)` 已废弃且无效。
    static func activateApp() {
        NSApp.activate()
    }

    /// 主窗口判定：可见、不是面板、宽度够大（菜单栏面板只有 300 左右）
    static var noMainWindow: Bool {
        !NSApp.windows.contains { w in
            w.isVisible && !(w is NSPanel) && w.frame.width > 400
        }
    }

    /// 关掉启动时 SwiftUI 自动建出来的主窗口（macOS 14 兜底，见 AppDelegate）
    static func closeMainWindows() {
        for w in NSApp.windows where !(w is NSPanel) && w.frame.width > 400 {
            w.orderOut(nil)
            w.close()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 单实例闸门。**必须在这里**（窗口还没建出来的时刻）：以前放在
    /// `BackendService.start()` 里太晚，第二个进程的界面已经画到屏幕上了 ——
    /// 用户实测「退出控制台再打开，出现两个控制台」。
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 卸载器的命令行模式要在「app 正开着」的时候也能跑，既不能抢锁退场，
        // 更不能顺手把正在跑的实例窗口叫出来。
        let args = CommandLine.arguments
        if args.contains("--unregister-all") || args.contains("--unregister-helper") { return }
        // --ui-shots 时 InstanceLock 内部会自动跳过
        InstanceLock.claimOrHandOff()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 卸载器用：一次清掉**全部** SMAppService 注册。
        // 这些记录在系统的后台任务数据库里，光 bootout 进程、删 LaunchAgents 里的
        // plist 都清不掉；不注销的话「系统设置 → 通用 → 登录项」会留下幽灵条目。
        //   ① com.macconsole.helper     后台硬件守护（LaunchAgent）
        //   ② com.macconsole.autostart  静默启动（2.8.15 已废，打包时已移除该 plist）
        //   ③ mainApp                   旧「开机自启动」登录项（macOS 13+）
        // ② 只能在本 bundle 还带着那份 plist 时走 SMAppService 注销（老版本升级场景），
        // 见 LegacyAutostart 的注释。
        if CommandLine.arguments.contains("--unregister-all") {
            var out: [String] = []
            if #available(macOS 13.0, *) {
                let helper = SMAppService.agent(plistName: mcHelperAgentPlist)
                do { try helper.unregister(); out.append("helper=已注销") }
                catch { out.append("helper=\(error.localizedDescription)") }

                out.append(LegacyAutostart.unregisterRegistration())

                do { try SMAppService.mainApp.unregister(); out.append("mainApp=已注销") }
                catch { out.append("mainApp=\(error.localizedDescription)") }
            } else {
                out.append("macOS < 13，无 SMAppService 注册")
            }
            out.append("autostart-残留: " + LegacyAutostart.cleanLeftovers())
            print("unregister-all: " + out.joined(separator: " | "))
            exit(0)
        }
        // 卸载器用：只注销后台 helper 的 LaunchAgent 注册（保留兼容旧脚本）
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
        // 2.8.11：登录项自愈（避免开机拉起两个实例）
        if #available(macOS 13.0, *) { AutostartHeal.run() }
        // v2.4.3：恢复用户选的外观（浅色/深色/随系统，默认随系统）
        AppAppearance.current.apply()
        // 2.8.15：静默启动已删除，常规进入 regular 策略
        // 2026-10-25：改为「登录项启动 = 纯后台」。之前这里无条件 toRegular()，
        // 开机时会在 Dock 里挂一个图标、还把主窗口顶到前面 —— 用户要的是无感后台。
        // 现在启动一律 .accessory（无 Dock、无应用菜单），主窗口只在被显式打开时出现。
        DispatchQueue.main.async { AppPolicy.toAccessory() }
        // 用户自己双击 app 拉起时（进程启动即被激活）仍要看到界面；
        // 登录项启动时进程不是前台应用，就把 SwiftUI 自动建出来的主窗口收掉。
        // 0.2s 足够区分这两种情况，而且窗口通常还没画到屏幕上。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSApp.isActive {
                NotificationCenter.default.post(name: .macConsoleShowMain, object: nil)
            } else {
                AppPolicy.closeMainWindows()
            }
        }
        // 菜单栏监控图标（AppKit 状态项，Stats 同款）：开关在「系统」页
        MenuBarMonitors.shared.start()
        // 2.7.8：接管触控板左上角双击手势（固件合成 Ctrl+Cmd+F13，见 GestureHotkey.swift）
        // 必须常驻后台也能生效 —— 所以放在 delegate 而不是某个页面的 onAppear 里
        GestureHotkey.shared.start()
        // v2.5.x：服务随 app 启动即激活，不依赖主窗口弹出。
        // 否则开机自启（LSUIElement agent，主窗口不自动打开）后不点开界面，
        // helper 连接与菜单栏实时数据都不激活。start()/attach() 内部已幂等，
        // 主窗口 onAppear 再调一次也安全。
        Task { @MainActor in
            await BackendService.shared.start()
            await BackendService.shared.checkKext()
            // 2.8.12：kext 状态看门狗（未加载 2s / 已加载 20s）。用户装完 kext
            // 不必重启 app，界面自己从「需要 TongfangFan.kext」变成可用。
            BackendService.shared.startKextWatch()
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

    /// 静默启动时主窗口不存在，用户双击 app 图标 / 从 Dock 唤起要把窗口叫出来。
    /// 真正建窗口的动作在 MenuBarLabel 里（它常驻，能拿到 openWindow 环境值）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .macConsoleShowMain, object: nil)
        }
        return true
    }
}

/// 登录项自愈（2.8.11）
///
/// 2.8.15：静默启动功能删除，`com.macconsole.autostart` 这条 agent 不再使用。
/// P2 清理：bundle 里也不再生成那份 plist（见 build-swift.sh）。
///
/// 清理因此分成两条腿：
///   · **SMAppService 注册** —— 只能寻址本 bundle `Contents/Library/LaunchAgents/`
///     里真实存在的 plist。所以老包（≤2.8.15）升级上来时还能正常注销；新包没有
///     这份文件，注册库里若还留着幽灵条目只能由用户在「登录项」里手删。
///   · **磁盘 / launchd 残留** —— 不依赖 plist 是否存在，随时可清。
enum AutostartHeal {
    @available(macOS 13.0, *)
    static func run() {
        let reg = LegacyAutostart.unregisterRegistration()
        let left = LegacyAutostart.cleanLeftovers()
        if reg != "autostart=未注册" || left != "无残留" {
            print("[autostart] \(reg)｜残留清理：\(left)")
        }
    }
}

/// 已废弃的「静默启动」LaunchAgent（`com.macconsole.autostart`）清理
enum LegacyAutostart {
    static let label = "com.macconsole.autostart"
    static let plistName = "com.macconsole.autostart.plist"

    /// 本 bundle 里是否还带着那份 plist（P2 清理后恒为 false）
    static var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path)
    }

    /// 注销系统注册。plist 不在包里时**不能**调这个 API —— 返回说明字符串代替。
    @available(macOS 13.0, *)
    static func unregisterRegistration() -> String {
        guard bundled else { return "autostart=无（打包时已移除该 plist）" }
        let agent = SMAppService.agent(plistName: plistName)
        guard agent.status != .notRegistered else { return "autostart=未注册" }
        do {
            try agent.unregister()
            return "autostart=已注销"
        } catch {
            return "autostart=\(error.localizedDescription)"
        }
    }

    /// 清 launchd 运行态与磁盘上的旧 plist（旧 autostart.sh 写过三个名字）。
    /// 走 NativeProc：launchctl 卡住不能让进程无界等待。
    @discardableResult
    static func cleanLeftovers() -> String {
        let uid = getuid()
        _ = NativeProc.runCapture("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        _ = NativeProc.runCapture("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])

        let dir = ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
        var removed: [String] = []
        for name in ["\(label).plist", "\(label).plist.disabled", ".\(label).plist.tmp"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: p),
               (try? FileManager.default.removeItem(atPath: p)) != nil {
                removed.append(name)
            }
        }
        return removed.isEmpty ? "无残留" : "已删 " + removed.joined(separator: "、")
    }
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
        //
        // 2026-10-25：登录项启动不应该弹窗。SwiftUI 的 SceneBuilder 不支持 if，
        // 没法按系统版本套 defaultLaunchBehavior(.suppressed)，所以统一在
        // AppDelegate 里用「启动 0.2s 后收窗」兜底（窗口还没画出来就关掉了）。
        mainWindow
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

    // 主窗口场景。
    //
    // **2.8.15 之前这里是 `WindowGroup(id:)` —— 那是「万能开窗器」**：
    // 每调一次 `openWindow(id: "main")` 就新建一个窗口，哪怕已经有一个在。
    // 双击 app 启动时 SwiftUI 先建好一个窗口，接着
    // `applicationDidFinishLaunching` 里那句 0.2s 后的 `.macConsoleShowMain`
    // 又 openWindow 一次 —— 结果就是「退出控制台再打开，眼前两个控制台」。
    // `Window`（macOS 13+）天生单例：已存在时 openWindow 只会把它叫到前面。
    private var mainWindow: some Scene {
        Window("Mac控制台", id: "main") {
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
                    AppPolicy.activateApp()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
    }
}


// MARK: - 菜单栏图标（风扇 + CPU 温度）
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 2026-10-19：温度改由「系统」页开关控制的监控图标显示，这里只留状态图标
        Image(systemName: store.connected ? "fanblades.fill" : "fanblades")
            .accessibilityLabel(store.connected ? "Mac控制台 · 已连接" : "Mac控制台 · 连接中断")
            // 静默启动时主窗口没被创建，双击 app 图标要靠这里把窗口叫出来。
            // 放在菜单栏图标上是因为它常驻实例化，能拿到 openWindow 环境值。
            .onReceive(NotificationCenter.default.publisher(for: .macConsoleShowMain)) { _ in
                // 主窗口已经在（双击启动时 SwiftUI 自己建过一个）就只把它叫到前面，
                // 不要再 openWindow —— 那是第二个窗口的老来源
                if AppPolicy.noMainWindow { openWindow(id: "main") }
                AppPolicy.toRegular()
                AppPolicy.activateApp()
            }
            // 2.8.4：第二个实例（比如两条登录项各拉起一个）抢锁失败时，
            // 会在这里发一条跨进程通知，把已有实例的窗口叫出来 ——
            // 用户看到的就是「点一下，窗口出来了」，而不是「双开」或「点了没反应」。
            .onReceive(DistributedNotificationCenter.default().publisher(for: .mcShowMainFromOther)) { _ in
                if AppPolicy.noMainWindow { openWindow(id: "main") }
                AppPolicy.toRegular()
                AppPolicy.activateApp()
            }
    }
}

// MARK: - 菜单栏弹出面板（.window 风格）
// 2026-10-19 v2.4.2 按用户要求重整：删掉 CPU温度/显卡温度/散热三格与亮度滑块，
// 只保留两类——「散热模式」（补上「手动」档，手动时带 L0-L7 滑条）和
// 「系统功耗设置」（原「整机性能档」，三档按钮；2.7.10 按原厂 Windows 术语改名）。
struct MenuBarView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    // 2.7.10：与原厂术语对齐 —— 散热模式 1 性能 / 2 标准 / 3 安静，基准模式独立开关
    @State private var thermal: String = "2"
    @State private var benchmark = false
    @State private var perfIndex: Int = 0x11          // 0x11 / 0x22 / 0x33

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mac控制台")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("打开控制台") {
                    if AppPolicy.noMainWindow { openWindow(id: "main") }
                    AppPolicy.toRegular()
                    AppPolicy.activateApp()
                }
                .controlSize(.small)
            }

            // 散热模式（= 原厂「散热设置」：0x7AB 低半字节 1/2/3）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("散热模式")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if benchmark {
                        Text("基准中")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.amber)
                    }
                }
                Picker("散热模式", selection: thermalBinding) {
                    Text("性能").tag("1")
                    Text("标准").tag("2")
                    Text("安静").tag("3")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(benchmark)
                .opacity(benchmark ? 0.5 : 1)

                Toggle(isOn: benchmarkBinding) {
                    Text("基准模式").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // 系统功耗设置（= 原厂同名卡片：0x7AB 高半字节 0x11/0x22/0x33）
            // 2026-10-25 用户要求：与「散热模式」用同一种控件（分段选择器），
            // 去掉每档上方的小图标；两段样式因此完全一致。
            VStack(alignment: .leading, spacing: 6) {
                Text("系统功耗设置")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("系统功耗设置", selection: perfBinding) {
                    Text("高性能").tag(0x11)
                    Text("平衡").tag(0x22)
                    Text("节能").tag(0x33)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(benchmark)
                .opacity(benchmark ? 0.5 : 1)
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
            NSApplication.shared.activate()
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

    /// 系统功耗档（0x7AB 高半字节）。与散热模式同一套「软件记忆优先」逻辑：
    /// 只有用户点选才写记忆 + 下发，程序回读直接赋 @State 不经过 setter。
    private var perfBinding: Binding<Int> {
        Binding(
            get: { UIControlPrefs.int(UIControlPrefs.K.perfIndex) ?? perfIndex },
            set: { code in
                perfIndex = code
                UIControlPrefs.set(UIControlPrefs.K.perfIndex, code)
                Task { await applyPerf(code) }
            }
        )
    }

    /// 当前散热档（0x7AB 低半字节）。乐观更新窗口内以本地选择为准。
    ///
    /// 2.8.8：EC 只在启动时读一次，之后统一取软件记忆（UIControlPrefs），
    /// 与主窗口控制页共用同一份，两个界面不会互相打架。
    private var currentThermal: String {
        if let t = UIControlPrefs.string(UIControlPrefs.K.thermal) { return t }
        return thermal
    }

    private var thermalBinding: Binding<String> {
        Binding(
            get: { currentThermal },
            set: { newValue in
                thermal = newValue
                UIControlPrefs.set(UIControlPrefs.K.thermal, newValue)
                Task { await applyThermal(Int(newValue) ?? 2) }
            }
        )
    }

    /// 基准模式（0x741 手动门）。软件记忆优先。
    private var benchmarkBinding: Binding<Bool> {
        Binding(
            get: { UIControlPrefs.bool(UIControlPrefs.K.benchmark) ?? benchmark },
            set: { v in
                benchmark = v
                UIControlPrefs.set(UIControlPrefs.K.benchmark, v)
                Task { await applyBenchmark(v) }
            }
        )
    }

    private func syncFromBackend() {
        // EC 只在启动时读一次 → 播种软件记忆；之后一律读记忆
        UIControlPrefs.seedIfNeeded(store.fan)
        if let t = UIControlPrefs.string(UIControlPrefs.K.thermal) { thermal = t }
        if let mi = UIControlPrefs.int(UIControlPrefs.K.perfIndex), [0x11, 0x22, 0x33].contains(mi) {
            perfIndex = mi
        }
        if let b = UIControlPrefs.bool(UIControlPrefs.K.benchmark) { benchmark = b }
    }

    private func applyThermal(_ level: Int) async {
        _ = await backend.post("/api/fan", ["thermal": level])
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyBenchmark(_ on: Bool) async {
        _ = await backend.post("/api/fan", ["benchmark": on])
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
//   硬件 · 控制（散热模式、系统功耗设置、系统调整、充电阈值、亮度、音量、休眠——全部写 EC）
//   硬件 · 灯效（键盘 RGB、白平衡、灯效保存）
//   系统 · 全部信息（原生采集的每个字段，排查用）
//   系统 · 设置（外观、菜单栏图标、版本、能力边界）
struct RootView: View {
    enum Page: String, CaseIterable, Identifiable {
        case overview, performance, control, lighting, experimental, alldata, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "概览"
            case .performance: return "性能"
            case .control: return "控制"
            case .lighting: return "灯效"
            case .experimental: return "实验性"
            case .alldata: return "全部信息"
            case .settings: return "设置"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: return "设备 · 关键指标 · 系统"
            case .performance: return "曲线 · 温度 · 风扇 · 磁盘"
            case .control: return "散热 / 功耗 / 系统调整 / 充电"
            case .lighting: return "键盘 RGB / 逐键投影 / 海岸灯"
            case .experimental: return "手动风扇 / 非常规通路 / EC 探针"
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
            case .experimental: return "flask"
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
            case .experimental: return Theme.red
            case .alldata: return Theme.green
            case .settings: return Theme.dim
            }
        }
        /// 侧边栏分组标题
        var group: String {
            switch self {
            case .overview, .performance: return "监测"
            case .control, .lighting, .experimental: return "硬件"
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
        // 跨页跳转（控制页「去灯效页」）
        .onReceive(NotificationCenter.default.publisher(for: .mcGotoPage)) { note in
            if let raw = note.object as? String, let p = Page(rawValue: raw) {
                page = p
            }
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
        case .experimental: ExperimentalView()
        case .alldata: AllDataView()
        case .settings: MiscView()
        }
    }
}
