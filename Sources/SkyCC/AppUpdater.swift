import SwiftUI
import AppKit

// ============================================================================
// App 自更新中心（2026-11-15）
//
// 原实现挂在设置页 CapabilityMiscView 里 —— 问题：启动时设置页根本没打开，
// 「进入软件自动检查」没法触发，弹窗也没地方挂。抽成全局单例：
//
//   · 启动期（launchSilentCheck）：延迟 5 秒**静默**检查一次 —— 有更新才弹
//     「发现新版本」确认框，没有 / 失败 / 断网全部无声，不打扰；
//   · 设置页「检查更新」按钮：check(silent: false) —— 带转圈弹窗、
//     失败 / 已最新都有 toast（原有交互不变）；
//   · sheet + 两个 alert 挂在根视图（SkyCCApp），任何页面都能弹。
// ============================================================================

/// 自身检查更新的确认框数据（有新版本时填入）
struct AppUpdateInfo {
    /// 更新包形态：自研安装器（DMG，拉起「Sky CC 安装器.app」）或传统 pkg（installer CLI 静默装）
    enum Kind {
        case selfInstaller
        case pkg
    }
    let tag: String
    let assetURL: String  // release 资产里 .dmg（优先）或 .pkg 的 browser_download_url
    let sizeMB: Double
    let kind: Kind
}

/// 应用内自更新阶段：下载中 / 启动安装器 / 安装中，供弹窗切换内容
enum AppUpdatePhase: Equatable {
    case idle, downloading, launching, installing
}

extension AppUpdater {
    /// 「发现新版本」确认框文案（独立普通函数：在 ViewBuilder 里写复杂插值
    /// 会触发编译器 type-check 超时，2026-11-15）。走 Gitee 兜底时 sizeMB=0，不显示大小。
    static func updateConfirmMessage(_ info: AppUpdateInfo) -> String {
        let size = info.sizeMB > 0
            ? "（安装包 " + String(format: "%.1f", info.sizeMB) + " MB）"
            : ""
        let how = info.kind == .selfInstaller
            ? "将在软件内下载全新安装器，打开后点「开始安装」即可完成升级（自动清理旧版残留）。"
            : "将在软件内下载并自动安装，是否继续？"
        return "检测到新版本 " + info.tag + size
            + "，当前为 Build " + AppVersion.build + "。" + how
    }
}

final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    private init() {}

    @Published var checkingUpdate = false
    /// 转圈 sheet 只跟**手动**检查走（2026-11-16 用户反馈：启动静默检查不该弹窗）
    @Published private(set) var spinnerVisible = false
    @Published var updatePhase: AppUpdatePhase = .idle
    @Published var downloadProgress: Double = 0
    @Published var updateInfo: AppUpdateInfo?
    @Published var showUpdateAlert = false
    @Published var showRelaunchAlert = false

    private var pollTimer: Timer?
    private var launchChecked = false

    // MARK: - 静默检查节流（2026-11-17）
    // 起因：Gitee 未认证 API 按出口 IP 限流，App 每次启动都联网一枪（连 GitHub 那枪恒 404），
    // 启动次数一多就把配额打光，之后连手动「检查更新」都只能拿到 403 / 404。
    // 现在的口径：
    //   · 启动静默检查：读 UserDefaults 里的上次检查时间，**24 小时内不再联网**；
    //     真到期了也只打静态 latest.json **一枪**（allowAPI: false，不碰 GitHub / Gitee API）；
    //   · 失败（断网 / 文件拉不到）：2 小时后再试，避免一次失败就整天不查；
    //   · 手动「检查更新」：不受节流影响，永远走全链路（静态 → GitHub → Gitee）。
    private enum ThrottleKeys {
        static let lastSilentCheck = "SkyCC.updater.lastSilentCheckAt"
    }
    private static let silentInterval: TimeInterval = 24 * 3600
    private static let silentRetryAfterFailure: TimeInterval = 2 * 3600

    /// 距上次启动检查是否已过节流窗口
    static func silentCheckDue(now: Date = Date()) -> Bool {
        let last = UserDefaults.standard.double(forKey: ThrottleKeys.lastSilentCheck)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= silentInterval
    }

    /// 记录本次静默检查时间；failed=true 时按「2 小时后重试」记（等价于把时间戳往前推）
    private static func markSilentCheck(failed: Bool, now: Date = Date()) {
        let stamp = failed ? now.timeIntervalSince1970 - (silentInterval - silentRetryAfterFailure)
                          : now.timeIntervalSince1970
        UserDefaults.standard.set(stamp, forKey: ThrottleKeys.lastSilentCheck)
    }

    /// sheet 是否该显示（手动检查的转圈 / 下载中 / 安装中）。
    /// 注意用 spinnerVisible 而不是 checkingUpdate —— 后者静默检查也会置位。
    var sheetVisible: Bool {
        spinnerVisible || updatePhase == .downloading || updatePhase == .installing
    }

    /// sheet 被手动关掉时：只在非检查期才复位下载状态
    func sheetDismissed() {
        if !checkingUpdate {
            updatePhase = .idle
            pollTimer?.invalidate()
        }
    }

    /// 进入软件自动检查（静默）：整个 App 生命周期只跑一次，延迟 5 秒
    /// 避开启动期的后端连接与首帧渲染
    func launchSilentCheck() {
        guard !launchChecked else { return }
        launchChecked = true
        // 24 小时内已经查过 → 这次开机干脆不联网（原实现是每次启动必打一枪）
        guard Self.silentCheckDue() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(silent: true)
        }
    }

    // MARK: - 检查更新（skyone-code/Sky-CC latest release；tag 去 v 后与 CFBundleVersion 纯数字比对）
    /// silent = true：无转圈、无失败 toast，只在有可用新版本时弹确认框
    /// 2026-11-15：GitHub 不通时兜底 Gitee 镜像仓（ReleaseFallback 双通道）
    func check(silent: Bool) {
        guard !checkingUpdate, updatePhase == .idle else { return }
        checkingUpdate = true
        spinnerVisible = !silent
        ReleaseFallback.fetchLatest(
            githubAPI: "https://api.github.com/repos/skyone-code/Sky-CC/releases/latest",
            giteeRepo: "Sky-CC",
            userAgent: "SkyCC/\(mcHelperBuildVersion)",
            staticJSON: ReleaseFallback.staticLatestURL,
            allowAPI: !silent) { [weak self] dict, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // 静默检查过就落时间戳（失败按 2 小时后再试记），手动检查不动这个窗口
                if silent { Self.markSilentCheck(failed: dict == nil) }
                self.checkingUpdate = false
                self.spinnerVisible = false
                guard let dict,
                      let tag = dict["tag_name"] as? String else {
                    if !silent {
                        ToastCenter.shared.show("检查失败：三个版本源都不可达（静态文件 / GitHub / Gitee）")
                    }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                if !Self.isNewer(latest, than: AppVersion.build) {
                    if !silent {
                        ToastCenter.shared.show("已是最新 · Build \(AppVersion.build)")
                    }
                    return
                }
                // 在 assets 里找安装包：**优先 .dmg（自研安装器，可视升级）**，
                // 没有才回落 .pkg（installer CLI 静默装）。Gitee 的 assets 没有
                // size 字段 → sizeMB 按 0，确认框里就不显示大小
                var dmg: (url: String, size: Int)?
                var pkg: (url: String, size: Int)?
                for a in (dict["assets"] as? [[String: Any]]) ?? [] {
                    let name = (a["name"] as? String ?? "").lowercased()
                    guard let url = a["browser_download_url"] as? String else { continue }
                    let size = a["size"] as? Int ?? 0
                    if name.hasSuffix(".dmg") && dmg == nil { dmg = (url, size) }
                    if name.hasSuffix(".pkg") && pkg == nil { pkg = (url, size) }
                }
                let chosen: AppUpdateInfo?
                if let d = dmg {
                    chosen = AppUpdateInfo(tag: latest, assetURL: d.url,
                                           sizeMB: Double(d.size) / 1_048_576,
                                           kind: .selfInstaller)
                } else if let p = pkg {
                    chosen = AppUpdateInfo(tag: latest, assetURL: p.url,
                                           sizeMB: Double(p.size) / 1_048_576,
                                           kind: .pkg)
                } else {
                    chosen = nil
                }
                guard let info = chosen else {
                    if !silent {
                        ToastCenter.shared.show("发现新版本 \(latest)，但发布里没有 .dmg / .pkg 安装包，无法应用内更新")
                    }
                    return
                }
                self.updateInfo = info
                self.showUpdateAlert = true
            }
        }
    }

    /// 下载更新包到临时目录（0.3s 轮询进度），完成后按形态分路：
    /// DMG → 挂载并拉起自研安装器；pkg → 走 installer CLI 静默装
    func startUpdate() {
        guard let info = updateInfo, let url = URL(string: info.assetURL) else { return }
        let fm = FileManager.default
        let ext = info.kind == .selfInstaller ? "dmg" : "pkg"
        let dest = fm.temporaryDirectory.appendingPathComponent("SkyCC-update-\(info.tag).\(ext)")
        try? fm.removeItem(at: dest)
        updatePhase = .downloading
        downloadProgress = 0
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollTimer?.invalidate()
                guard err == nil, let data,
                      let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    self.updatePhase = .idle
                    ToastCenter.shared.show("下载失败：\(err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")")
                    return
                }
                do { try data.write(to: dest) } catch {
                    self.updatePhase = .idle
                    ToastCenter.shared.show("保存安装包失败：\(error.localizedDescription)")
                    return
                }
                if info.kind == .selfInstaller {
                    self.updatePhase = .launching
                    DispatchQueue.global(qos: .userInitiated).async { self.mountAndHandOff(dmg: dest, tag: info.tag) }
                } else {
                    self.updatePhase = .installing
                    DispatchQueue.global(qos: .userInitiated).async { self.installDownloadedPkg(at: dest) }
                }
            }
        }
        task.resume()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            if task.countOfBytesExpectedToReceive > 0 {
                self?.downloadProgress = min(1, Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive))
            }
        }
    }

    // MARK: - DMG 自研安装器通道（2026-11-18）
    // 下载的是「Sky CC 安装器.app」的 DMG：挂载 → 找到安装器 app → open 拉起
    // → 主程序退出。后续的授权、6 步安装、进度展示全部交给安装器 UI，
    // 与首次安装完全同一套界面（含更新说明页）。

    /// hdiutil attach，返回挂载点路径（解析 plist 输出，不依赖 /Volumes 卷名）
    private func mountDMG(_ dmg: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for e in entities {
            if let m = e["mount-point"] as? String, !m.isEmpty { return m }
        }
        return nil
    }

    /// 在挂载点里找自研安装器 app（优先固定名，兜底根目录第一个 .app）
    private func findInstallerApp(in mount: String) -> URL? {
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: mount).appendingPathComponent("Sky CC 安装器.app")
        if fm.fileExists(atPath: preferred.path) { return preferred }
        if let names = try? fm.contentsOfDirectory(atPath: mount) {
            for name in names where name.hasSuffix(".app") {
                return URL(fileURLWithPath: mount).appendingPathComponent(name)
            }
        }
        return nil
    }

    /// 挂载 DMG 并拉起安装器；确认安装器跑起来后主程序退出。
    /// 失败只报错复位，不 degrade 到 pkg（发布资产里两者都在，用户可手选）。
    private func mountAndHandOff(dmg: URL, tag: String) {
        let fm = FileManager.default
        DispatchQueue.main.async { self.updatePhase = .launching }
        guard let mount = mountDMG(dmg) else {
            DispatchQueue.main.async {
                self.updatePhase = .idle
                ToastCenter.shared.show("更新失败：无法挂载安装器映像（可从 release 页手动下载 DMG）")
            }
            return
        }
        guard let appURL = findInstallerApp(in: mount) else {
            DispatchQueue.main.async {
                self.updatePhase = .idle
                ToastCenter.shared.show("更新失败：映像里没有找到安装器")
            }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.updatePhase = .idle
                    ToastCenter.shared.show("更新失败：无法启动安装器（\(error.localizedDescription)）")
                    return
                }
                // 安装器已在前台跑起来，主程序功成身退（安装器的第 1 步也会停旧进程）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        _ = fm // 静默 unused 警告
    }

    /// 写 runner（installer -pkg，日志重定向）→ 管理员权限执行 → 成功弹重启确认
    private func installDownloadedPkg(at pkg: URL) {
        let fm = FileManager.default
        let logURL = fm.temporaryDirectory.appendingPathComponent("SkyCC-update-\(UUID().uuidString).log")
        let runner = fm.temporaryDirectory.appendingPathComponent("SkyCC-install-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        export LOG=\(DriverInstaller.sh(logURL.path))
        : > "$LOG"
        printf '== Sky CC 自更新：安装 %s\\n' "$(date)" >> "$LOG"
        /usr/sbin/installer -pkg \(DriverInstaller.sh(pkg.path)) -target / >> "$LOG" 2>&1
        rc=$?
        printf 'installer 退出码 %d\\n' "$rc" >> "$LOG"
        exit "$rc"
        """
        do {
            try body.write(to: runner, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        } catch {
            DispatchQueue.main.async {
                self.updatePhase = .idle
                ToastCenter.shared.show("无法写入安装脚本：\(error.localizedDescription)")
            }
            return
        }
        let result = DriverInstaller.runWithAdminPrivileges(executable: runner.path,
                                                            logURL: logURL,
                                                            deadline: 15 * 60) { _, _ in }
        DispatchQueue.main.async {
            self.updatePhase = .idle
            let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: runner)
            try? fm.removeItem(at: logURL)
            if result.ok {
                try? fm.removeItem(at: pkg)
                self.showRelaunchAlert = true
            } else {
                let reason = logText.split(separator: "\n").last.map(String.init) ?? "安装器未完成（授权被取消？）"
                ToastCenter.shared.show("更新失败：\(reason)")
            }
        }
    }

    /// 重启自身：先派生一个被收养的 sh 子进程（父进程退出后仍存活），等 0.8s 再 open 新版
    func relaunchApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.8; open \(DriverInstaller.sh(Bundle.main.bundlePath))"]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }

    /// 纯数字点分段比较：a 是否大于 b（缺段按 0）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// 检查/下载/安装三阶段共用的弹窗内容（挂在根视图，见 SkyCCApp）
struct AppUpdateSheet: View {
    @ObservedObject var updater = AppUpdater.shared

    var body: some View {
        VStack(spacing: 16) {
            if updater.updatePhase == .downloading {
                ProgressView(value: updater.downloadProgress).frame(width: 240)
                Text("正在下载新版本… \(Int(updater.downloadProgress * 100))%")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim).monospacedDigit()
            } else if updater.updatePhase == .launching {
                ProgressView().controlSize(.regular)
                Text("正在启动全新安装器…")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
            } else if updater.updatePhase == .installing {
                ProgressView().controlSize(.regular)
                Text("正在安装更新（请在授权弹窗输入管理员密码）…")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
            } else {
                ProgressView().controlSize(.regular)
                Text("正在检查更新…")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
            }
        }
        .padding(30)
    }
}
