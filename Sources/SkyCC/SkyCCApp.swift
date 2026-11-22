import SwiftUI
import ServiceManagement
import AppKit

/// 主窗口修改了亮度/散热等设置后广播，菜单栏据此刷新显示。
/// MenuBarExtra 的 content 在 macOS 上常驻内存，不会自动跟随主窗口的状态变化，
/// 必须显式通知（这是「菜单栏显示与实际不符」bug 的修复核心之一）。
extension Notification.Name {
    static let skyCCStateChanged = Notification.Name("SkyCCStateChanged")
    /// 请求把主窗口叫出来（后台静默启动时，用户双击 app 或点菜单栏「打开控制台」）
    static let skyCCShowMain = Notification.Name("SkyCCShowMain")
    /// 请求切到某个标签页（object 传 Page.rawValue）。
    /// 2.8.3：控制页的「去灯效页」按钮（海岸灯搬去灯效页后留的入口）用它跳转。
    static let mcGotoPage = Notification.Name("SkyCCGotoPage")
    /// **跨进程**：第二个实例被单实例锁挡住时，用它请已在运行的实例把主窗口叫出来。
    /// 必须走 DistributedNotificationCenter（本地 NotificationCenter 出不了进程）。
    static let mcShowMainFromOther = Notification.Name("SkyCCShowMainFromOther")
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
/// 主窗口打开时切 .regular → 左上角出现「Sky CC」菜单（关闭/退出等齐全）；
/// 窗口关掉再切回 .accessory → 退回纯菜单栏常驻，不占 Dock。
/// （2026-10-19 修：用户反馈打开控制台后菜单栏没有程序名和关闭菜单）
enum AppPolicy {
    static func toRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // 2.7.8：setActivationPolicy 会重新向 WindowServer 注册进程，把已挂上的
        // Carbon 热键打掉 —— 每次改完策略必须重挂，否则触控板手势会静默失效
        GestureHotkey.shared.reregister(reason: "toRegular")
        hideWindowTitle()
    }

    /// 2026-11-15 用户要求：窗口标题栏的「Sky CC」文字去掉（每页顶上都顶着，不好看）。
    /// 只藏文字（titleVisibility = .hidden），标题栏本身保留 —— 拖拽区和红绿灯不受影响。
    /// 每次切回 regular 都刷一遍，防止 SwiftUI 重建窗口后失效。
    static func hideWindowTitle() {
        for w in NSApp.windows where !(w is NSPanel) && w.title == "Sky CC" {
            w.titleVisibility = .hidden
        }
    }
    static func toAccessory() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        GestureHotkey.shared.reregister(reason: "toAccessory")
    }
    /// 把 app 叫到前台。macOS 14 起 `activate(ignoringOtherApps:)` 已废弃且无效。
    static func activateApp() {
        NSApp.activate()
    }

    /// 主窗口判定：有标题栏（弹窗面板/悬浮件都没有）、可见、宽度够大。
    /// 2026-11-16 修「点打开控制台连窗口都不出现」：旧判定只看「非 NSPanel + 宽 >400」
    /// —— 但 MenuBarExtra .window 风格的弹窗也是普通窗口，弹窗开着时点按钮，
    /// 弹窗自己就被误判成「主窗口已在」，openWindow 被跳过。加 .titled 过滤
    /// （主窗口有标题栏，弹窗没有）杜绝误判。
    static func isMainWindow(_ w: NSWindow) -> Bool {
        !(w is NSPanel) && w.styleMask.contains(.titled) && w.isVisible && w.frame.width > 400
    }
    static var noMainWindow: Bool {
        !NSApp.windows.contains(where: isMainWindow)
    }

    /// 把主窗口叫到最前端（2026-11-16 用户反馈：菜单栏弹窗点「打开控制台」没反应）。
    /// 根因：按钮跑在 MenuBarExtra 的 .window 弹窗里，点击时 app 是 accessory 且
    /// **未激活**；紧接着弹窗关闭、焦点转移，`NSApp.activate()`（macOS 14+ 协作式
    /// 激活）在这种时机拿不到前台 —— 窗口建出来也压在别的 app 后面。
    /// 修法：异步等弹窗关完再行动；窗口没建出来（openWindow 是异步的）就多等几拍；
    /// 置顶用 `orderFrontRegardless()`——**app 不活跃也能把窗口放到最上层**，
    /// 不依赖 activate 成功。
    static func raiseMainWindow(attempt: Int = 0) {
        guard attempt < 8 else { return }          // ~1s 还没见窗口就放弃，别死循环
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if noMainWindow {
                raiseMainWindow(attempt: attempt + 1)   // openWindow 还没建完，再等一拍
                return
            }
            toRegular()
            NSApp.activate()
            for w in NSApp.windows where isMainWindow(w) {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    /// 关掉启动时 SwiftUI 自动建出来的主窗口（macOS 14 兜底，见 AppDelegate）
    static func closeMainWindows() {
        for w in NSApp.windows where !(w is NSPanel) && w.styleMask.contains(.titled) && w.frame.width > 400 {
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
        let args = CommandLine.arguments
        // 2026-11-17（MacConsole → SkyCC）：新 bundle id 在系统眼里是全新 app。
        // 先把旧的 UserDefaults / 数据目录 / com.macconsole.helper 搬过来并摘干净，
        // 否则后面读设置全是默认值，旧 helper 还会和新 helper 抢 EC。
        // 必须早于单实例闸门与任何 UIControlPrefs 读取。
        if !args.contains("--unregister-all") && !args.contains("--unregister-helper") {
            SkyCCMigrator.runIfNeeded()
        }
        // 卸载器的命令行模式要在「app 正开着」的时候也能跑，既不能抢锁退场，
        // 更不能顺手把正在跑的实例窗口叫出来。
        if args.contains("--unregister-all") || args.contains("--unregister-helper") { return }
        // --ui-shots 时 InstanceLock 内部会自动跳过（UIShot 见 Tools/UIShot.swift）
        InstanceLock.claimOrHandOff()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 卸载器用：一次清掉**全部** SMAppService 注册。
        // 这些记录在系统的后台任务数据库里，光 bootout 进程、删 LaunchAgents 里的
        // plist 都清不掉；不注销的话「系统设置 → 通用 → 登录项」会留下幽灵条目。
        //   ① com.skycc.helper     后台硬件守护（LaunchAgent）
        //   ② com.skycc.autostart  静默启动（2.8.15 已废，打包时已移除该 plist）
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
        // 2.8.11：登录项自愈（避免开机拉起两个实例）
        if #available(macOS 13.0, *) { AutostartHeal.run() }
        // v2.4.3：恢复用户选的外观（浅色/深色/随系统，默认随系统）
        AppAppearance.current.apply()
        // 2.8.15：静默启动已删除，常规进入 regular 策略
        // 2026-10-25：改为「登录项启动 = 纯后台」。之前这里无条件 toRegular()，
        // 开机时会在 Dock 里挂一个图标、还把主窗口顶到前面 —— 用户要的是无感后台。
        // 现在启动一律 .accessory（无 Dock、无应用菜单），主窗口只在被显式打开时出现。
        DispatchQueue.main.async { AppPolicy.toAccessory() }
        // 区分「登录项拉起」与「用户双击打开」：
        //
        // 2026-11-14（用户反馈，第二次修）：之前靠 NSApp.isActive —— 0.2s 内没激活
        // 就认定是登录项启动、收窗。但本 app 是 LSUIElement（accessory 策略），
        // **双击打开也常常不会把 isActive 置真**，轮询等到天荒地老都是 false，
        // 结果双击也收窗 →「被迫闪退」。isActive 这条路彻底放弃。
        //
        // 现在的判定（不依赖激活事件）：
        //   登录项拉起 = launchd 以服务方式拉起（XPC_SERVICE_NAME == 本 bundle id）
        //   且开机自启已开启。此时静默进后台，不弹窗；
        //   其余一切情况（双击、菜单栏唤起、spotlight 等）都亮主窗口。
        //   双击/退出重开在重启后 3 分钟内也一样亮窗 —— 判据与运行时间无关。
        var isLoginLaunch = (ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
                             == Bundle.main.bundleIdentifier)
        if #available(macOS 13.0, *) {
            isLoginLaunch = isLoginLaunch && (SMAppService.mainApp.status == .enabled)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSApp.isActive || !isLoginLaunch {
                NotificationCenter.default.post(name: .skyCCShowMain, object: nil)
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
    /// 退出流程是否已经启动（防止 terminateLater 期间再被问一次）
    private var shuttingDown = false

    /// 退出统一收口（2026-11-13 用户要求）：点「退出控制台」、Cmd+Q、Dock 退出，
    /// 全都先让 helper 把硬件交还干净再放行 —— 停曲线、放 `0x751` 档位、
    /// 清 `0x741` bit0，然后 helper 自己 `exit(0)`（plist 已改成 SuccessfulExit=false，
    /// 正常退出不会被 launchd 拉回来）。
    ///
    /// 必须用 `terminateLater`：这一步要过 XPC，是异步的；同步阻塞主线程会让
    /// 退出时界面卡住、Dock 图标转圈。`shutdownAll()` 自带 4 秒超时，
    /// helper 没响应也不会把 app 挂死在这里。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateNow }
        shuttingDown = true
        Task {
            await BackendService.shared.shutdownAll()
            await MainActor.run { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// 关窗口不退出（菜单栏继续常驻）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 退出前停掉键盘「软件动画」的推帧线程（霓虹/堆叠/冲击）。
    ///
    /// 原厂退出时键盘 RGB 是**不动**的（停在最后一帧），但推帧线程必须先死，
    /// 否则退出瞬间还可能往 HID 塞进半帧，画面停在撕裂状态。
    func applicationWillTerminate(_ notification: Notification) {
        APEffectEngine.shared.stop()
    }

    /// 静默启动时主窗口不存在，用户双击 app 图标 / 从 Dock 唤起要把窗口叫出来。
    /// 真正建窗口的动作在 MenuBarLabel 里（它常驻，能拿到 openWindow 环境值）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .skyCCShowMain, object: nil)
        }
        return true
    }
}

/// 登录项自愈（2.8.11）
///
/// 2.8.15：静默启动功能删除，`com.skycc.autostart` 这条 agent 不再使用。
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

/// 已废弃的「静默启动」LaunchAgent（`com.skycc.autostart`）清理
enum LegacyAutostart {
    static let label = "com.skycc.autostart"
    static let plistName = "com.skycc.autostart.plist"

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
struct SkyCCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backend = BackendService.shared
    @StateObject private var store = MonitorStore.shared
    // 皮肤中心（2026-11-15）：页面背景更换，设置页改配色/图片后全页面即时跟随
    @StateObject private var skin = SkinCenter.shared

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
        // 2026-11-18（用户要求）：默认关于面板太简陋 → 替换为自定义关于窗口
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 Sky CC") { AboutWindowPresenter.show() }
            }
        }

    }

    // 主窗口场景。
    //
    // **2.8.15 之前这里是 `WindowGroup(id:)` —— 那是「万能开窗器」**：
    // 每调一次 `openWindow(id: "main")` 就新建一个窗口，哪怕已经有一个在。
    // 双击 app 启动时 SwiftUI 先建好一个窗口，接着
    // `applicationDidFinishLaunching` 里那句 0.2s 后的 `.skyCCShowMain`
    // 又 openWindow 一次 —— 结果就是「退出控制台再打开，眼前两个控制台」。
    // `Window`（macOS 13+）天生单例：已存在时 openWindow 只会把它叫到前面。
    private var mainWindow: some Scene {
        Window("Sky CC", id: "main") {
            RootView()
                .environmentObject(backend)
                .environmentObject(store)
                .environmentObject(skin)
                .frame(minWidth: 1020, minHeight: 660)
                .onAppear {
                    Task { await backend.start() }
                    Task { await backend.checkKext() }
                    store.attach(backend)
                    // 主窗口可见 → 切回 regular，菜单栏出现程序名/关闭/退出
                    AppPolicy.toRegular()
                    AppPolicy.activateApp()
                    // 2026-11-17（MacConsole → SkyCC）：刚搬完家的那一次，提醒一句。
                    // 开机自启走 SMAppService.mainApp，是按 bundle id 绑定的 ——
                    // 域名一换，原来那条注册对新 app 不再生效，用户会以为「自启失灵」。
                    if SkyCCMigrator.consumeMigrationNotice() {
                        ToastCenter.shared.show("设置已从旧版本迁移 · 若原先开启过「开机自动启动」，请到设置里重新打开一次")
                    }
                }
                // 2026-11-08（性能）：窗口收起来（隐藏 / 最小化）时把轮询降到 5 秒。
                // 常驻菜单栏不需要每秒拉一次全量快照 —— 那是白白烧 CPU。
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didHideNotification)) { _ in
                    store.setWindowVisible(false)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didUnhideNotification)) { _ in
                    store.setWindowVisible(true)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.didMiniaturizeNotification)) { _ in
                    store.setWindowVisible(false)
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.didDeminiaturizeNotification)) { _ in
                    store.setWindowVisible(true)
                }
                // 2026-11-07（性能）：被别的窗口完全遮住也算「看不见」。
                // 之前只认隐藏 / 最小化，窗口丢在后台被盖住时仍按 3 秒全量刷新，
                // 每拍都要把整棵视图树重排一次（sample 里就是 NSWindow
                // updateConstraintsIfNeeded → NSISEngine 求解），而屏幕上一个像素都看不见。
                // 这里按「有没有任意一个可成为主窗口的窗口真正露在屏幕上」判定，
                // 菜单栏面板等附属窗口不参与，避免开合弹出面板时误判。
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.didChangeOcclusionStateNotification)) { _ in
                    let shown = NSApp.windows.contains {
                        $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized
                            && $0.occlusionState.contains(.visible)
                    }
                    store.setWindowVisible(shown)
                }
        }
        // 2026-11-18（用户定案「两态标题栏必须同模」+ 修「玻璃开着重启标题栏失效」）：
        // .titleBar 出生是标准标题栏，玻璃态靠运行时插 fullSizeContentView —— 事后
        // 插掩模时 SwiftUI 布局/安全区不跟着刷新，重启恢复玻璃时标题带就露底
        // （手动切换没事是因为窗口已活跃、布局会重算）。改 .hiddenTitleBar：
        // 窗口从出生起就是 fullSizeContentView + 透明标题栏，两态同一结构，
        // 玻璃只切窗口本体透明度，无事后补丁、无竞态。.titled 仍在，isMainWindow
        // 谓词（靠 .titled 区分弹窗）不受影响；标题文字隐藏（侧边栏已有 logo）。
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}


// MARK: - 菜单栏图标（风扇 + CPU 温度）
/// 菜单栏主图标：app 图标里的「S」飘带。2026-11-14（用户要求）新增三风格可选：
///   随系统（黑色模板图，浅色栏显黑、深色栏显白，默认）/
///   白色（固定白，深色状态栏下好看）/
///   彩色（品牌彩色切图，带阴影）。
/// 选择存 UserDefaults（@AppStorage 直连），设置页一改这里立即跟着换。
/// helper 离线时统一降为半透明作区分。
///
/// 2026-11-16 重构·第二轮（用户定案）：S 飘带是**程序主图标，独立一个状态项**
/// —— 监控数字全部搬到 MenuBarMonitors 自建的独立 NSStatusItem 里拼接显示
/// （见 MenuBarMonitors.swift），本视图只渲染 S 飘带本身 + 弹窗/唤窗链路。
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UIControlPrefs.K.menubarIcon) private var iconStyle = "auto"

    /// 从 bundle 读 S 飘带切图（构建脚本拷到 Contents/Resources/）
    ///
    /// 2026-11-17（性能自查）：原来每次取图标都 `NSImage(contentsOf:)` 重新解码 PNG。
    /// 菜单栏 label 挂着 `@EnvironmentObject store`，MonitorStore 每拍发 objectWillChange
    /// → body 重算 → 每秒解码一次 PNG。`menuIcon` 是 computed，所以这条链一直在跑。
    /// 现在按「文件名 + 是否模板」缓存，只解码一次。
    private static var iconCache: [String: NSImage] = [:]

    private static func loadIcon(_ name: String, template: Bool) -> NSImage? {
        let key = "\(name)#\(template)"
        if let hit = iconCache[key] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = template
        img.size = NSSize(width: 18, height: 18)
        iconCache[key] = img
        return img
    }

    /// 按设置取当前风格的图标；找不到就回退黑色模板，再不行回退系统扇叶符号
    private var menuIcon: NSImage {
        let (name, template): (String, Bool) = {
            switch iconStyle {
            case "white": return ("MenuSIconWhite", false)
            case "color": return ("MenuSIconColor", false)
            default:      return ("MenuSIconTemplate", true)
            }
        }()
        return Self.loadIcon(name, template: template)
            ?? Self.loadIcon("MenuSIconTemplate", template: true)
            ?? NSImage(systemSymbolName: "fanblades.fill",
                       accessibilityDescription: "Sky CC") ?? NSImage()
    }

    var body: some View {
        // 主图标：S 飘带，风格由设置页「状态栏主图标」选择（随系统 / 白 / 彩色）；
        // 后台服务离线时降为半透明作区分。监控数字在右侧独立状态项（MenuBarMonitorBar）。
        Image(nsImage: menuIcon)
            .opacity(store.connected ? 1 : 0.45)
            .accessibilityLabel(store.connected ? "Sky CC · 已连接" : "Sky CC · 连接中断")
            // 静默启动时主窗口没被创建，双击 app 图标要靠这里把窗口叫出来。
            // 放在菜单栏图标上是因为它常驻实例化，能拿到 openWindow 环境值。
            .onReceive(NotificationCenter.default.publisher(for: .skyCCShowMain)) { _ in
                // 主窗口已经在（双击启动时 SwiftUI 自己建过一个）就只把它叫到前面，
                // 不要再 openWindow —— 那是第二个窗口的老来源
                if AppPolicy.noMainWindow { openWindow(id: "main") }
                AppPolicy.raiseMainWindow()
            }
            // 2.8.4：第二个实例（比如两条登录项各拉起一个）抢锁失败时，
            // 会在这里发一条跨进程通知，把已有实例的窗口叫出来 ——
            // 用户看到的就是「点一下，窗口出来了」，而不是「双开」或「点了没反应」。
            .onReceive(DistributedNotificationCenter.default().publisher(for: .mcShowMainFromOther)) { _ in
                if AppPolicy.noMainWindow { openWindow(id: "main") }
                AppPolicy.raiseMainWindow()
            }
    }
}

/// 菜单栏弹窗里的分段选择器（自绘）。
///
/// 为什么不用 `Picker(.segmented)`：NSSegmentedControl 的宽度是「文字总宽 + 内建边距」，
/// 不同的选项文字长度会得到不同的整体宽度，且 `.frame(maxWidth:)` 拉不动它 ——
/// 菜单栏面板里「散热模式」和「系统功耗设置」两组按钮因此永远对不齐。
/// 自绘版每段 `frame(maxWidth: .infinity)` 等分容器宽度，两组严格同宽同高。
struct MenuSegmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button {
                    selection = opt.0
                } label: {
                    Text(opt.1)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Theme.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(on ? Theme.blue : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
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

    // 显卡路由（2026-11-07 用户要求加进弹窗）
    @State private var gpuOn = false
    @State private var gpuBusy = false
    @State private var gpuUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sky CC")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("打开控制台") {
                    // 2026-11-16：不再用 noMainWindow 拦 —— Window 场景是单例，
                    // 已存在时 openWindow 只把它叫到前面，永远安全；靠判定拦反而
                    // 会因弹窗误判而把 openWindow 跳过（连窗口都不出现的根因）。
                    openWindow(id: "main")
                    // 弹窗面板关闭会吞掉激活时机，延后到面板关完再置顶
                    // （含窗口还没建出来的重试）。
                    AppPolicy.raiseMainWindow()
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
                // 2026-11-07（用户要求，第二次）：**不再用系统 Picker(.segmented)**。
                // macOS 的 NSSegmentedControl 宽度由「标签文字总宽」决定，
                // 加 .frame(maxWidth: .infinity) 也不会真的拉伸（它只吃 ideal 宽度），
                // 所以「性能/标准/安静」永远比「高性能/平衡/节能」窄一截。
                // 改成自绘分段：每段 frame(maxWidth: .infinity) 等分，
                // 两组控件因为容器宽度相同而严格等宽、等高、圆角一致。
                MenuSegmented(options: [("1", "性能"), ("2", "标准"), ("3", "安静")],
                              selection: thermalBinding)
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.5 : 1)
            }

            // 系统功耗设置（= 原厂同名卡片：0x7AB 高半字节 0x11/0x22/0x33）
            // 2026-10-25 用户要求：与「散热模式」用同一种控件（分段选择器），
            // 去掉每档上方的小图标；两段样式因此完全一致。
            VStack(alignment: .leading, spacing: 6) {
                Text("系统功耗设置")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                MenuSegmented(options: [(0x11, "高性能"), (0x22, "平衡"), (0x33, "节能")],
                              selection: perfBinding)
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.5 : 1)
            }

            // 2026-11-07（用户要求）：把「默认使用独显」也放进菜单栏弹窗 ——
            // 这是最常临时切的一项（想让某个 app 用独显就跑一趟菜单栏）。
            // 与「设备控制」页里的 GpuRouteSection 共用同一接口 /api/gpu，
            // 这里只留开关 + 一行状态，例外名单仍在「设备控制」页管理。
            VStack(alignment: .leading, spacing: 6) {
                Text("显卡")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("默认使用独显").font(.system(size: 11.5))
                    Spacer(minLength: 4)
                    Toggle("", isOn: Binding(get: { gpuOn }, set: { setGpuMode($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(gpuBusy || gpuUnavailable)
                }
                // 2026-11-18（用户要求）：基准模式行挪到显卡状态提示行下方，
                // 与「默认使用独显」行同构 —— 11.5 号文字 + mini 开关右对齐。
                Text(gpuStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("基准模式").font(.system(size: 11.5))
                    Spacer(minLength: 4)
                    Toggle("", isOn: benchmarkBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
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
        .frame(width: 220)
        .background(VisualEffectBackground())
        .onAppear {
            syncFromBackend()
            Task { await refreshGpu() }
            // 2.7.1：MenuBarExtra 的 .window 面板同样依赖 app 处于 active 才会在
            // 点外部时收起；LSUIElement 常驻后台时不会自动激活，这里显式激活一次。
            NSApplication.shared.activate()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            syncFromBackend()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .skyCCStateChanged)) { _ in
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

    // MARK: - 显卡路由（菜单栏弹窗内的精简版）

    private var gpuStatusText: String {
        if gpuUnavailable { return "缺少显卡路由组件，需重装 app" }
        if gpuBusy { return "正在应用…" }
        return gpuOn ? "已开启：之后启动的 app 拿到独显"
                     : "已关闭：跟随系统（默认核显）"
    }

    private func refreshGpu() async {
        guard let d = try? await backend.getJSON("/api/gpu") as? [String: Any] else { return }
        gpuUnavailable = (d["dylibPresent"] as? Bool) == false
        gpuOn = (d["injected"] as? Bool) ?? false
    }

    private func setGpuMode(_ on: Bool) {
        gpuBusy = true
        gpuOn = on                       // 乐观更新，回读再校正
        Task {
            let r = await backend.post("/api/gpu/mode", ["mode": on ? "dgpu" : "off"])
            gpuBusy = false
            if r["ok"] as? Bool != true { gpuOn = !on }
            await refreshGpu()
        }
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

    /// 基准模式（文档 §3.3）。软件记忆优先。
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    private func applyBenchmark(_ on: Bool) async {
        _ = await backend.post("/api/fan", ["benchmark": on])
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    private func applyPerf(_ code: Int) async {
        _ = await backend.post("/api/fan", ["modeindex": code])
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
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
//   监测 · 性能（每核 / 内存分项 / 双显卡 / 每卷 / SMART / 电池）
//   监测 · 概览（机型 hero + 身份卡 + 风扇 + 电池 + 存储）
//   硬件 · 控制（散热模式、手动风扇/温控曲线、充电阈值——全部写 EC）
//   硬件 · 灯效（键盘 RGB、逐键投影、海岸灯）
//   硬件 · NVIDIA 驱动（版本对照、组件、一键安装/卸载）
//   系统 · 全部信息（原生采集的每个字段，排查用）
//   系统 · 设置（外观、菜单栏图标、版本、系统调整）
// 3.0.3.7：「概览」页删除（用户要求）——6 个 KPI 有 5 个与性能页重复，hero 挪到性能页
// 顶部，设备/本机/系统三张身份卡挪到设置页（见 SystemIdentity.swift）。
struct RootView: View {
    enum Page: String, CaseIterable, Identifiable {
        case overview, performance, menubar, control, lighting, nvidia, network, alldata, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "设备概览"
            // 2026-11-17（用户要求）：侧边栏项由「设备监测」改为「性能监测」
            case .performance: return "性能监测"
            case .menubar: return "状态栏显示"
            case .control: return "设备控制"
            case .lighting: return "灯光矩阵"
            case .nvidia: return "NVIDIA 驱动"
            case .network: return "网卡驱动"
            case .alldata: return "全部信息"
            case .settings: return "设置"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: return "设备 · 风扇 · 电池 · 存储"
            case .performance: return "CPU · GPU · 内存 · 网络"
            case .menubar: return "监控项逐项开关 · 按盘显示"
            case .control: return "散热 / 功耗 / 风扇手动 / 充电"
            case .lighting: return "键盘 RGB / 逐键投影 / 海岸灯"
            case .nvidia: return "版本对照 / 组件 / 一键安装"
            case .network: return "Wi-Fi / 蓝牙 · 一键更新"
            case .alldata: return "原生采集的每个字段"
            case .settings: return "外观 / 菜单栏 / 系统调整"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "gauge"
            case .performance: return "waveform.path.ecg"
            case .menubar: return "menubar.dock.rectangle"
            case .control: return "slider.horizontal.3"
            case .lighting: return "keyboard"
            case .nvidia: return "chip"
            case .network: return "wifi"
            case .alldata: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
        var tint: Color {
            switch self {
            case .overview: return Theme.blue
            case .performance: return Theme.cyan
            case .menubar: return Theme.blue
            case .control: return Theme.amber
            case .lighting: return Theme.purple
            case .nvidia: return Theme.green
            case .network: return Theme.cyan
            case .alldata: return Theme.green
            case .settings: return Theme.dim
            }
        }
        /// 侧边栏分组标题
        var group: String {
            switch self {
            case .overview, .performance, .menubar: return "监测"
            case .control, .lighting: return "硬件"
            case .nvidia, .network: return "驱动"
            case .alldata, .settings: return "系统"
            }
        }
        static let groups = ["监测", "硬件", "驱动", "系统"]
        /// 侧边栏可见项。`alldata`（全部信息）按用户要求隐藏——原生字段表是排障用的，
        /// 留在代码里（case 与 AllDataView 都还在），需要时把这里过滤去掉即可恢复。
        static func inGroup(_ g: String) -> [Page] {
            allCases.filter { $0.group == g && $0 != .alldata }
        }
    }

    @State private var page: Page = .overview
    // 最小宽度（2026-11-18 用户定案）：整窗最小 = 1020，**与侧边栏无关** ——
    // 侧边栏展开时详情列 = 1020 − 侧边栏实际宽（~788），各页卡片必须能压到
    // 这个宽度（概览双环/电池环已改自适应，灯效页右列 360 之外的左列自适应，
    // 其余页的网格/文本全部可压缩）。窗口级下限由 Window 场景根部的
    // frame(minWidth: 1020) 提供，不再做 1020 + 侧边栏的动态 contentMinSize。
    @EnvironmentObject private var backend: BackendService
    // 2026-11-17（性能自查）：**不要**在这里持有 MonitorStore。
    // @EnvironmentObject / @ObservedObject 是「整对象订阅」——只要 store 发出
    // objectWillChange（每秒至少一次：overview / sensors / history / updatedAt…），
    // RootView 的 body 就整体重算：侧边栏 18 行 List + 详情页 + 整窗 AutoLayout
    // 全部重来。而这里真正用到的只有 `connected` 一个布尔（侧边栏底部状态点）。
    // 现在那个状态点抽成独立的 SidebarFooter（自己订阅 store），RootView 不再
    // 因为监控数据每拍变化而重建骨架。

    var body: some View {
        NavigationSplitView {
            // 2026-11-15：body 拆小（sidebar / RootUpdateOverlays modifier）——
            // 整块写在 body 里编译器 type-check 会超时
            sidebar
        } detail: {
            detailView
            // 2026-11-18（用户定案）：整窗最小宽 = 1020（含侧边栏），详情列不再
            // 挂自己的 frame(minWidth:) —— 之前那道框会跟侧边栏列抢宽度，把
            // 侧边栏挤到 210 下限以下、内容整体溢出裁切。详情列宽度 =
            // 窗口宽 − 侧边栏实际宽，各页卡片必须能在 ~788 下跟着压缩。
            // 2026-11-14（用户要求）：去掉详情列顶部工具条里的小字页名 ——
            // 每页内容区已有 PageHeader 大标题，重复了。窗口标题仍是「Sky CC」。
        }
        // 跨页跳转（控制页「去灯效页」）
        .onReceive(NotificationCenter.default.publisher(for: .mcGotoPage)) { note in
            if let raw = note.object as? String, let p = Page(rawValue: raw) {
                page = p
            }
        }
        // 2026-11-15 用户定案（第三轮）：公共背景层提到整窗（侧边栏 + 详情共用一张图/一个底色），
        // 各页不再单独铺背景
        .pageBackground()
        // 2026-11-15（用户要求）：App 自更新 UI 挂根视图 —— 启动期静默检查发现更新时
        // 设置页可能根本没打开，sheet/alert 必须任何页面都能弹（拆进独立 ViewModifier，
        // 避免 body 太大触发编译器 type-check 超时）
        .modifier(RootUpdateOverlays())
    }

    /// 侧边栏（从 body 拆出，2026-11-15：body 整块太大编译器会超时）
    private var sidebar: some View {
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
        // 2026-11-18（探针 A/B 对照 + 用户定案）：不再用 .listStyle(.sidebar)——
        // 用户更喜欢单独 List 的观感（选中态是普通高亮，不带 sidebar 样式的
        // 系统材质语义）；背景透明度仍由下面这组 modifier 控制。
        .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 270)
        // 2026-11-15 用户定案（第三轮）：侧边栏**透到公共背景层**，不再有独立背景层 ——
        // 公共背景（皮肤预设色 / 背景图）在根视图整窗铺一次（见 body 最外层 .pageBackground()），
        // 侧边栏只隐藏 List 系统底 + 铺与卡片同款的半透明 panel；若选了侧边栏专属图，
        // sidebarBackground() 在 panel 底下再铺那张图（遮住公共层），没选就直达公共层。
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .sidebarBackground()
        // 侧边栏左下角：连接状态 + 退出控制台
        // （2026-11-17：抽成独立视图，只为它自己订阅 MonitorStore —— 见 SidebarFooter）
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }

    /// App 自更新 UI（sheet + 两个 alert + 启动静默检查），挂根视图的 modifier。
    /// 拆出独立类型（2026-11-15）：body 里全写在一起编译器 type-check 超时。
    /// @ObservedObject 持有单例：@Published 状态变化时这里重算，sheet/alert 才会弹出来。
    private struct RootUpdateOverlays: ViewModifier {
        @ObservedObject private var updater = AppUpdater.shared
        func body(content: Content) -> some View {
            content
                // sheet：手动检查的转圈 / 下载进度 / 安装进度（AppUpdateSheet）
                .sheet(isPresented: Binding(
                    get: { updater.sheetVisible },
                    set: { if !$0 { updater.sheetDismissed() } })) {
                    AppUpdateSheet()
                }
                // 静默/手动检查发现新版本 → 确认框（更新 / 取消）
                .alert("发现新版本", isPresented: Binding(
                    get: { updater.showUpdateAlert },
                    set: { updater.showUpdateAlert = $0 }),
                    presenting: updater.updateInfo) { info in
                    Button("更新") { updater.startUpdate() }
                    Button("取消", role: .cancel) {}
                } message: { info in
                    // 文案在 AppUpdater.updateConfirmMessage 生成（ViewBuilder 里写复杂插值会超时）
                    Text(AppUpdater.updateConfirmMessage(info))
                }
                // 安装完成 → 重启确认
                .alert("更新完成", isPresented: Binding(
                    get: { updater.showRelaunchAlert },
                    set: { updater.showRelaunchAlert = $0 })) {
                    Button("重启 Sky CC") { updater.relaunchApp() }
                    Button("稍后", role: .cancel) {}
                } message: {
                    Text("新版本已安装完成，重启 Sky CC 后生效。")
                }
                // 进入软件自动检查更新（静默）：延迟 5 秒跑一次，有更新才弹窗，没有/失败无声
                .task { updater.launchSilentCheck() }
        }
    }

    /// 侧边栏一项：彩色圆角图标 + 标题 + 副标题
    private func navRow(_ p: Page) -> some View {
        HStack(spacing: 10) {
            // NVIDIA 页用品牌 logo（用户提供的绿眼 SVG），其余页仍用 SF Symbols
            if p == .nvidia, let logo = NvidiaBrandIcon.image {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .padding(0)
                    .background(Theme.green.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: p.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(p.tint)
                    .frame(width: 24, height: 24)
                    .background(p.tint.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                // 2026-11-15 用户反馈：浅色下侧边栏黑字（默认 primary）太扎眼 → 主文字灰；
                // 选中项在蓝色高亮底上必须反白（浅色下深灰字看不清）
                Text(p.title).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(p == page ? Color.white : Theme.txt)
                Text(p.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(p == page ? Color.white.opacity(0.75) : Theme.dim2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 侧边栏顶部：横版 lockup（2026-11-18 定稿：再放大 + 去掉版本号）
    private var appHeaderRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let logo = Self.cachedLogoHorizontal {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
    }

    /// 横版组合标（构建时拷到 Resources/LogoComboHorizontal.png）
    /// 2026-11-18：改走 BrandAssets 多级减半预缩放（1644px 直接缩 56pt 必出锯齿）
    private static let cachedLogoHorizontal: NSImage? =
        BrandAssets.prescaled("LogoComboHorizontal", targetPixelHeight: 112)

    // （旧侧边栏 app 图标缓存已删：2026-11-18 侧边栏改用横版 lockup 后无人引用）

    @ViewBuilder
    private var detailView: some View {
        switch page {
        case .overview: OverviewView()
        case .performance: MonitorView()
        case .menubar: MenuBarStatusView()
        case .control: ControlView()
        case .lighting: RGBView()
        case .nvidia: NvidiaView()
        case .network: NetworkView()
        case .alldata: AllDataView()
        case .settings: MiscView()
        }
    }
}

// MARK: - 侧边栏底部状态条

/// 侧边栏左下角：后台服务状态 + 退出按钮。
///
/// 2026-11-17（性能自查）从 RootView 抽出来独立成视图：
/// 它只需要 `MonitorStore.connected` 一个字段，如果让它跟着 RootView 一起订阅
/// 整个 store，监控数据每拍（1~5 秒）都会把侧边栏 List、详情页、整窗约束求解
/// 全部重算一遍 —— 采样里那条 `updateConstraintsIfNeeded → NSISEngine` 热点
/// 就是这么来的。现在重算范围收敛到这一行 HStack。
private struct SidebarFooter: View {
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
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
        // 2026-11-15：List 整体已铺 Theme.panel（侧边栏统一底），这里不再叠一层
        // （叠两层同款半透明会把底部颜色加深，和卡片不一致）
    }
}
