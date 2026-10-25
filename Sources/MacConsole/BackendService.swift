import Foundation
import AppKit
import ServiceManagement

/// app 侧后端门面：2.6.0 起**没有 HTTP 了**。
///
/// 数据面：全部经 XPC 调后台 helper（HelperClient），helper 是 EC/SMC/HID 的
/// 唯一持有者。UI 与「谁在读写硬件」彻底解耦 —— 界面退出/崩溃都不影响散热守护。
///
/// 历史：≤2.4.6 时 app spawn python3 server.py 走 HTTP；2.5.0 把服务搬进进程内
/// 仍是 HTTP；2.6.0 换成 XPC 后，8787 与内置 web 页面一并移除。
/// 需要命令行排障时用 `mcutil`（随包在 Contents/MacOS/）。
@MainActor
final class BackendService: ObservableObject {

    /// 单例：让 AppDelegate（与 SwiftUI 视图）共用同一实例。
    /// 服务必须在 app 启动即激活（不能等主窗口 onAppear），否则开机自启后
    /// 不点开界面、helper 连接与菜单栏实时数据都不激活。
    static let shared = BackendService()


    // MARK: - 发布状态
    @Published var helperOnline = false       // 后台 helper 是否在线（UI 真正依赖这个）
    @Published var helperVersion: String?
    @Published var helperPid: Int?
    @Published var kextLoaded = false
    @Published var kextInstalling = false
    @Published var lastError: String?


    // MARK: - 诊断日志（排查服务问题）
    private func diag(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/macconsole-swift.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - 启动 / 停止

    func start() async {
        diag("start() 被调用（纯 XPC 客户端，无 HTTP）")
        // 2.8.4：单实例改成内核 flock 原子锁（先于一切动作执行）。
        // 「开机自启」只有 mainApp 一条登录项（静默启动 2.8.15 已删除），
        // 但登录时仍可能与旧版本残留进程抢跑；flock 没有这个窗口期。
        if !acquireInstanceLock() {
            handOffToExistingInstance()
            exit(0)
        }
        terminateIfDuplicateInstance()
        // UI 的全部数据都来自后台 helper，这一步失败界面才会真没得用
        await ensureHelper()
    }

    // MARK: - 单实例锁

    /// flock 的文件句柄。进程退出（含被杀）时内核自动释放，不会留下死锁。
    private var instanceLockFD: Int32 = -1
    /// 本进程是否已经持有锁（start() 会被调用多次，重复 flock 同一文件会自我冲突）
    private var instanceLockAcquired = false

    /// 抢全局单实例锁。true = 本进程是唯一实例。
    private func acquireInstanceLock() -> Bool {
        // 本进程已经拿到过锁：直接放行。
        // flock 是按「打开文件描述」算的，同一进程再 open 一次同一个文件去加
        // LOCK_EX|LOCK_NB 会失败 —— 不判这个标志，第二次 start() 会把
        // 自己误判成「已有实例」然后 exit，表现就是 app 起来就没了。
        if instanceLockAcquired { return true }

        // 开发用 --ui-shots 时跳过：离屏截图要跟正在运行的实例并存。
        if CommandLine.arguments.contains("--ui-shots") { return true }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("app.lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // 拿不到锁文件（权限/磁盘异常）时不阻断启动，退回旧判断
            diag("单实例锁文件打不开（errno \(errno)），退回 NSRunningApplication 判断")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd
        instanceLockAcquired = true
        let pidText = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pidText.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    /// 已有实例在跑：请它把主窗口叫出来，然后自己退场。
    /// 跨进程用 DistributedNotificationCenter —— 本地 NotificationCenter 出不了进程。
    private func handOffToExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            .mcShowMainFromOther, object: nil, userInfo: nil, deliverImmediately: true)
        if let bid = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            // macOS 14 起 activateIgnoringOtherApps 无效果（已被废弃）：
            // 14+ 直接 activate()，老系统仍走旧参数。
            if #available(macOS 14.0, *) {
                other.activate()
            } else {
                other.activate(options: [.activateIgnoringOtherApps])
            }
        }
        diag("已有实例在运行，本实例退出并把窗口交给它")
    }

    /// 单实例：同一个 app 开两份会出现两个菜单栏图标、两条轮询。
    /// 2.8.4 起主路径是 flock（见 acquireInstanceLock），这里只作为兜底：
    /// 锁文件打不开时仍能靠它挡住明显重复的实例。
    private func terminateIfDuplicateInstance() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        // 开发用 --ui-shots 时跳过：离屏截图要跟正在运行的实例并存，
        // 否则必须先杀掉用户手上的窗口才能出图（helper 是 XPC 单例，多开无碍）。
        if CommandLine.arguments.contains("--ui-shots") { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            diag("检测到另一个 Mac控制台 实例（pid \(others.map(\.processIdentifier))），本实例退场")
            handOffToExistingInstance()
            exit(0)
        }
    }

    // MARK: helper 注册 / 版本握手
    //
    // 用 SMAppService（macOS 13+ 官方方式）注册随包 LaunchAgent：
    //   * 不需要 sudo、不需要手写 launchctl（实测 ad-hoc 签名也能注册成功）
    //   * 登录自动启动、KeepAlive 崩溃自愈、Mach service 天然全局单实例
    // 版本握手解决升级问题：app 被原地覆盖后，老 helper 进程还在跑旧代码，
    // 必须让它 exit(0) 让 launchd 用新二进制重启。
    func ensureHelper() async {
        let svc = SMAppService.agent(plistName: mcHelperAgentPlist)
        diag("helper 注册状态 = \(svc.status.rawValue)")
        if svc.status != .enabled {
            do {
                try svc.register()
                diag("helper 注册成功，状态 = \(svc.status.rawValue)")
            } catch {
                diag("helper 注册失败：\(error.localizedDescription)")
            }
        }

        // 等 helper 起来（首装/刚重启时需要一点时间）
        var health: [String: Any] = [:]
        for _ in 0..<20 {
            health = await HelperClient.shared.health(timeout: 2)
            if health["ok"] as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let online = health["ok"] as? Bool == true
        if !online {
            // 「已注册但进程不在」是装机脚本 bootout 之后的常见状态：
            // SMAppService 记着 .enabled，但 launchd 里那份 job 已经被卸掉，
            // 只调 register() 会直接返回成功却不会拉起进程。这里先注销再注册一次。
            diag("helper 未响应（状态 \(svc.status.rawValue)），尝试重新注册")
            try? await svc.unregister()
            try? svc.register()
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                health = await HelperClient.shared.health(timeout: 2)
                if health["ok"] as? Bool == true { break }
            }
        }
        helperOnline = health["ok"] as? Bool == true
        helperVersion = health["version"] as? String
        helperPid = health["pid"] as? Int
        diag("helper 在线=\(helperOnline) version=\(helperVersion ?? "-") pid=\(helperPid ?? -1)")

        guard helperOnline else {
            lastError = health["error"] as? String ?? "后台服务未启动"
            return
        }

        // 版本不一致 → 请它退出，launchd 会用新二进制重启
        let appVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        if let hv = helperVersion, !appVersion.isEmpty, hv != appVersion {
            diag("helper 版本 \(hv) ≠ app \(appVersion)，请求重启")
            _ = await HelperClient.shared.post("/api/helper/shutdown")
            HelperClient.shared.reset()
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let h = await HelperClient.shared.health(timeout: 2)
                if h["ok"] as? Bool == true, (h["version"] as? String) == appVersion {
                    helperOnline = true
                    helperVersion = appVersion
                    diag("helper 已重启到 \(appVersion)")
                    return
                }
            }
            diag("helper 重启后版本仍不匹配（继续使用现有实例）")
        }
    }

    /// 手动重启后台 helper（升级后兜底 / 排障用）
    func restartHelper() async {
        diag("手动请求重启 helper")
        _ = await HelperClient.shared.post("/api/helper/shutdown", [:], timeout: 5)
        HelperClient.shared.reset()
        helperOnline = false
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await ensureHelper()
    }

    /// app 退出/重启时调用。只断 XPC 连接，不碰 helper —— 它要继续守散热。
    func stop() {
        HelperClient.shared.reset()
        helperOnline = false
        diag("已断开 helper 连接（helper 继续运行）")
    }

    // MARK: - kext 检测与安装
    //
    // 【2.8.12 修 bug：kext 其实在内核里，界面却说「需要 TongfangFan.kext」】
    // 旧实现用 `/usr/sbin/ioreg -r -c TongfangFanDriver` 子进程判断，而且只在
    // app 启动 / 主窗口出现时各跑一次。两个后果：
    //   · 用户先开 app、后装 kext（或 app 启动那一刻 daemon 还没把 kext load 完），
    //     kextLoaded 就永远停在 false —— 散热/功耗/海岸灯都被当成「功能没了」；
    //   · readDataToEndOfFile + waitUntilExit 是无界等待，ioreg 一卡就把校验挂住。
    // 现在：进程内 IOKit 直判（瞬时、无子进程），并与 helper 的 ping 结果取或
    // （helper 是 EC 的唯一持有者，它说加载了就是加载了）；再加一个低频看门狗，
    // 状态一变界面自己跟上，装完 kext 不需要重启 app。
    func checkKext() async {
        let local = FanControl.kextLoaded()
        let remote = await helperReportsKext()
        let loaded = local || remote
        if loaded != kextLoaded {
            diag("kext 状态 → \(loaded ? "已加载" : "未加载")（app=\(local) helper=\(remote)）")
        }
        kextLoaded = loaded
    }

    /// helper 的 mcPing 里带 kext 字段（它用同一套 IOServiceMatching 直判）。
    /// helper 不在线时返回 false，由 app 侧直判兜底，不会误报「未加载」。
    private func helperReportsKext() async -> Bool {
        let h = await HelperClient.shared.health(timeout: 1.5)
        guard h["ok"] as? Bool == true else { return false }
        return h["kext"] as? Bool ?? false
    }

    /// kext 状态看门狗。
    /// 未加载 → 2s 一查（用户点「立即安装」输完密码后界面能立刻亮起来）；
    /// 已加载 → 20s 一查（外部 kmutil unload 也能跟上）。
    /// 只调 IOKit / XPC ping，不碰 EC，代价可以忽略。
    private var kextWatch: Task<Void, Never>?

    func startKextWatch() {
        guard kextWatch == nil else { return }
        kextWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait: UInt64 = self.kextLoaded ? 20 : 2
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled { return }
                await self.checkKext()
            }
        }
    }

    /// 一键安装：调用 app bundle 内的 install-kext.sh（kext 本体也内嵌在
    /// Contents/Resources/native/TongfangFan.kext，DMG 不再单独放 kext）。
    /// 需要管理员权限，脚本由 osascript 提权运行，用户会看到系统密码框。
    @discardableResult
    func installKextIfNeeded() async -> Bool {
        guard !kextInstalling else { return false }
        // 已经是加载状态就别再弹密码框
        await checkKext()
        guard !kextLoaded else { return true }

        kextInstalling = true
        defer { kextInstalling = false }

        // 安装脚本随包在 Resources/native/scripts/（兼容旧版 python/scripts/）
        let candidates = [
            "native/scripts/install-kext.sh",
            "python/scripts/install-kext.sh",
        ]
        guard let res = Bundle.main.resourceURL else {
            lastError = "找不到 app 资源目录"
            return false
        }
        guard let script = candidates
            .map({ res.appendingPathComponent($0).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            lastError = "包内缺少 install-kext.sh"
            diag("安装失败：bundle 内找不到 install-kext.sh")
            return false
        }
        diag("开始安装 kext：\(script)")

        let escaped = script.replacingOccurrences(of: "'", with: "'\\''")
        let src = "do shell script \"bash '\(escaped)'\" with administrator privileges"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", src]
        // 捕获输出：用户取消密码框时 osascript 返回 -128，要能说清是"取消"还是"失败"
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            lastError = "无法启动安装程序：\(error.localizedDescription)"
            return false
        }
        // 最多等 120 秒（够输密码 + kmutil load）
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if p.isRunning { p.terminate() }
        // 边跑边读已经来不及了（osascript 输出很短，管道不会写满），跑完再收
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        if !out.isEmpty { diag("安装输出：\(out.trimmingCharacters(in: .whitespacesAndNewlines))") }

        // 复核：kext load 是异步的，给内核 1.5 秒
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if FanControl.kextLoaded() { break }
        }
        await checkKext()
        if !kextLoaded {
            lastError = p.terminationStatus == 0
                ? "安装脚本执行完毕，但内核里仍没有 TongfangFanDriver（详见 /tmp/macconsole-kext-install.log）"
                : "安装未完成（可能取消了密码框）"
            diag("安装后仍未检测到 kext，status=\(p.terminationStatus)")
        } else {
            lastError = nil
            diag("kext 安装成功")
        }
        return kextLoaded
    }

    // MARK: - HTTP / XPC
    //
    // 2.6.0 起数据面改走 XPC（HelperClient）：UI 与硬件后端不再是同一个进程，
    // 也不再经过 TCP 回环。方法名保留 getJSON/postJSON，是为了让 MonitorStore
    // 与各页面调用点零改动。2.6.1 起 HTTP 服务（8787）与内置 web 页面已整体删除，
    // 只剩 mcGet/mcPost/mcPing 三个 XPC 入口，参数即原 HTTP 的 path+params。

    /// GET（任意结构：字典或数组）
    func getJSON(_ path: String) async throws -> Any {
        if let v = await HelperClient.shared.get(path) { return v }
        throw URLError(.cannotConnectToHost,
                       userInfo: [NSLocalizedDescriptionKey: HelperClient.shared.lastError ?? "helper 无响应"])
    }

    /// POST JSON body → 返回字典
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let r = await HelperClient.shared.post(path, body)
        // 只有传输层失败（XPC 不可达 / 超时）才 throw；业务失败（如 level 越界）
        // 照旧把 {ok:false, error:…} 原样交给调用方 —— 与旧版 HTTP 语义一致。
        if r["_xpc_error"] as? Bool == true {
            throw URLError(.cannotConnectToHost,
                           userInfo: [NSLocalizedDescriptionKey: r["error"] as? String ?? "helper 无响应"])
        }
        return r
    }

    func post(_ path: String, _ body: [String: Any] = [:]) async -> [String: Any] {
        do { return try await postJSON(path, body: body) }
        catch { return ["ok": false, "error": error.localizedDescription] }
    }

    // MARK: - 字典取值小工具
    static func int(_ d: Any?, _ key: String) -> Int? {
        (d as? [String: Any])?[key] as? Int
    }
    static func double(_ d: Any?, _ key: String) -> Double? {
        (d as? [String: Any])?[key] as? Double
    }
    static func string(_ d: Any?, _ key: String) -> String? {
        (d as? [String: Any])?[key] as? String
    }
    static func bool(_ d: Any?, _ key: String) -> Bool? {
        (d as? [String: Any])?[key] as? Bool
    }
    static func dict(_ d: Any?, _ key: String) -> [String: Any]? {
        (d as? [String: Any])?[key] as? [String: Any]
    }
    static func array(_ d: Any?, _ key: String) -> [Any]? {
        (d as? [String: Any])?[key] as? [Any]
    }
}
