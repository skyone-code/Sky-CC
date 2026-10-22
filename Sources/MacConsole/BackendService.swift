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
        terminateIfDuplicateInstance()
        // UI 的全部数据都来自后台 helper，这一步失败界面才会真没得用
        await ensureHelper()
    }

    /// 单实例：同一个 app 开两份会出现两个菜单栏图标、两条轮询。
    /// 以前靠「8787 端口被占」判断，现在没有 HTTP 了，直接用系统 API 问。
    private func terminateIfDuplicateInstance() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        // 开发用 --ui-shots 时跳过：离屏截图要跟正在运行的实例并存，
        // 否则必须先杀掉用户手上的窗口才能出图（helper 是 XPC 单例，多开无碍）。
        if CommandLine.arguments.contains("--ui-shots") { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            diag("检测到另一个 Mac控制台 实例（pid \(others.map(\.processIdentifier))），本实例退场")
            NSApp.terminate(nil)
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
    func checkKext() async {
        kextLoaded = await ioregHasFanDriver()
    }

    private func ioregHasFanDriver() -> Bool {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-r", "-c", "TongfangFanDriver"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").contains("TongfangFanDriver")
    }

    /// 尝试提权安装 kext（真实机器弹系统密码框）。完成回调里带结果。
    func installKextIfNeeded() async {
        guard !kextLoaded, !kextInstalling else { return }
        kextInstalling = true
        defer { kextInstalling = false }

        // 安装脚本随包在 Resources/native/scripts/（兼容旧版 python/scripts/）
        let candidates = [
            "native/scripts/install-kext.sh",
            "python/scripts/install-kext.sh",
        ]
        guard let res = Bundle.main.resourceURL else { return }
        let script = candidates
            .map { res.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let script else { return }

        let escaped = script.replacingOccurrences(of: "'", with: "'\\''")
        let src = "do shell script \"bash '\(escaped)'\" with administrator privileges"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", src]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        // 最多等 90 秒（够输密码）
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        // 装完复核
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        kextLoaded = ioregHasFanDriver()
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

    func get(_ path: String) async -> Any? {
        try? await getJSON(path)
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
