//
//  NetworkUpdate.swift
//  「网卡驱动」页数据层：二合一驱动包（AirportItlwm-Tahoe + BlueToolFixup + 安装脚本）
//
//  2026-11-15 用户定案：模式与 NVIDIA 驱动完全一致 ——
//    · 唯一更新源 skyone213/AirportItlwm-AX200-Airdrop，一个 release 一个包
//    · tag 纯数字点分（2.4.1 / 2.4.1.1）= 包版本；资产 AirportItlwm-AX200-<tag>.zip
//    · zip 内：两个 kext + 随包安装脚本（install.command / install.sh 皆认，多层查找）
//    · App 只负责「下载 → 解压 → 提权执行包内脚本」；备份 / 替换 / 校验全部由脚本负责
//    · 本机组件版本照旧读已加载版本（kmutil showloaded），ESP Info.plist 回退
//    · 已安装的「包版本」记在 UserDefaults（脚本跑成功后写入）；没记录时不比对，直接允许安装
//

import Foundation
import SwiftUI

// MARK: - 更新源（单一二合一包）

enum NetworkPackage {
    static let repo = "skyone213/AirportItlwm-AX200-Airdrop"
    static let title = "网卡驱动包（Wi-Fi + 蓝牙）"
    /// Gitee 镜像仓（GitHub 不通时的兜底，tag 与 GitHub 一致但无 v 前缀）
    static let giteeRepo = "AirportItlwm-AX200-Airdrop"
    /// 最近一次检查成功用的源（下载 URL 跟随同一源）
    static let sourceKey = "network.pkg.latestSource"

    /// release 资产名（2026-11-15 用户定案）
    static func assetName(tag: String) -> String { "AirportItlwm-AX200-\(tag).zip" }
    static func downloadURL(tag: String) -> String {
        // 检查更新时 API 给过精确资产地址就优先用（哪个源通的就用哪个）
        if let r = NetworkUpdate.cachedRelease(), r.tag == tag,
           let u = r.assetURL, !u.isEmpty { return u }
        if UserDefaults.standard.string(forKey: sourceKey) == ReleaseFallback.Source.gitee.rawValue {
            return "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(giteeRepo)/releases/download/\(tag)/\(assetName(tag: tag))"
        }
        return "https://github.com/\(repo)/releases/download/v\(tag)/\(assetName(tag: tag))"
    }
    static var releasesURL: String { "https://github.com/\(repo)/releases" }
}

// MARK: - 组件规格（只用于组件卡的身份与版本展示，不含更新源）

struct NetworkKextSpec: Identifiable {
    let id: String            // "wifi" / "bt"
    let title: String         // 组件行显示名
    let kextName: String      // ESP 里的目录名（不带 .kext）
    let bundleID: String      // kmutil showloaded 里的 bundle id
    let sub: String           // 一句话说明
}

// MARK: - 状态机（与 NvidiaUpdateState 同形）

enum NetworkUpdateState: Equatable {
    case unknown                 // 还没查过
    case notInstalled            // 本机没有加载任何一个组件
    case checking
    case upToDate(installed: String, latest: String)
    case available(installed: String, latest: String)
    case failed(installed: String, message: String)

    var installedVersion: String? {
        switch self {
        case .upToDate(let i, _), .available(let i, _), .failed(let i, _): return i
        default: return nil
        }
    }

    var latestVersion: String? {
        switch self {
        case .upToDate(_, let l), .available(_, let l): return l
        default: return nil
        }
    }

    var hasUpdate: Bool {
        if case .available = self { return true }
        return false
    }

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    var statusLabel: String {
        switch self {
        case .unknown: return "未检查"
        case .notInstalled: return "未加载"
        case .checking: return "检查中…"
        case .upToDate: return "已是最新"
        case .available(_, let latest): return "有新版本 \(latest)"
        case .failed: return "检查失败"
        }
    }

    var statusColor: Color {
        switch self {
        case .upToDate: return Theme.green
        case .available: return Theme.amber
        case .failed: return Theme.red
        case .checking: return Theme.cyan
        default: return Theme.dim2
        }
    }
}

// MARK: - 数据层

enum NetworkUpdate {

    /// OpenCore kext 目录（ESP 分区挂载点）
    static let espKextsDir = "/Volumes/ESP/EFI/OC/Kexts"

    /// 参与版本对照的四个组件（2026-11-15 用户定案：固件两件也进组件卡）
    static let specs: [NetworkKextSpec] = [
        NetworkKextSpec(id: "wifi",
                        title: "Wi-Fi（AirportItlwm AX200 · Airdrop）",
                        kextName: "AirportItlwm-Tahoe",
                        bundleID: "com.zxystd.AirportItlwm",
                        sub: "Intel AX200 无线网卡驱动（自建构建：Tahoe + Airdrop）"),
        NetworkKextSpec(id: "bt",
                        title: "蓝牙（BlueToolFixup）",
                        kextName: "BlueToolFixup",
                        bundleID: "as.acidanthera.BlueToolFixup",
                        sub: "Intel 蓝牙服务修复（IntelBluetoothFirmware 配套）"),
        NetworkKextSpec(id: "btfw",
                        title: "蓝牙固件（IntelBluetoothFirmware）",
                        kextName: "IntelBluetoothFirmware",
                        bundleID: "com.zxystd.IntelBluetoothFirmware",
                        sub: "Intel 蓝牙固件上传"),
        NetworkKextSpec(id: "btpatch",
                        title: "蓝牙补丁（IntelBTPatcher）",
                        kextName: "IntelBTPatcher",
                        bundleID: "com.zxystd.IntelBTPatcher",
                        sub: "Intel 蓝牙运行期补丁"),
    ]

    static func spec(_ id: String) -> NetworkKextSpec {
        specs.first { $0.id == id } ?? specs[0]
    }

    // MARK: 本机已加载版本（组件卡）

    /// 看起来像版本号的才认
    private static func looksLikeVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.first?.isNumber == true
            && s.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// 从 kmutil showloaded 输出里取已加载版本（「本机加载的版本」，最权威）。
    /// 行样例：`   68    0 0xffffff…  as.acidanthera.BlueToolFixup (2.7.3) 6C00…`
    static func loadedVersion(bundleID: String) -> String? {
        for line in NvidiaUpdate.kextList.split(separator: "\n")
        where line.contains("\(bundleID) (") {
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"), open < close else { continue }
            let v = String(line[line.index(after: open)..<close])
            if looksLikeVersion(v) { return v }
        }
        return nil
    }

    /// ESP 上的 Info.plist 版本（ESP 未挂载返回 nil）
    static func espVersion(_ spec: NetworkKextSpec) -> String? {
        let path = "\(espKextsDir)/\(spec.kextName).kext/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let v = dict["CFBundleShortVersionString"] as? String,
              looksLikeVersion(v) else { return nil }
        return v
    }

    /// ESP 是否挂载（一键更新前检查用）
    static var espMounted: Bool {
        FileManager.default.fileExists(atPath: "\(espKextsDir)/")
    }

    /// 组件行（网卡驱动页 componentsCard）：加载版本优先，ESP plist 回退
    static func component(_ spec: NetworkKextSpec) -> NvidiaUpdate.Component? {
        let loaded = loadedVersion(bundleID: spec.bundleID)
        let esp = espVersion(spec)
        let version = loaded ?? esp ?? "—"
        if loaded == nil && esp == nil { return nil }
        return NvidiaUpdate.Component(name: spec.kextName,
                                      version: version,
                                      present: esp != nil,
                                      loaded: loaded != nil)
    }

    // MARK: 包版本（与组件版本分开：tag 记录在 UserDefaults，脚本装成功后写入）

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        NvidiaUpdate.isNewer(candidate, than: current)
    }

    private enum Keys {
        static let installedTag = "network.pkg.installedTag"
        static let tag = "network.pkg.latestTag"
        static let name = "network.pkg.latestName"
        static let page = "network.pkg.latestPage"
        static let notes = "network.pkg.latestNotes"
        static let published = "network.pkg.latestPublished"
        static let checkedAt = "network.pkg.checkedAt"
        static let assetURL = "network.pkg.latestAssetURL"   // zip 包精确下载地址（源感知）
        static let source = NetworkPackage.sourceKey
    }

    /// 本机记录的已安装包版本（nil = 从未通过 App 装过，或手动装的）
    static var installedTag: String? {
        get { UserDefaults.standard.string(forKey: Keys.installedTag) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.installedTag) }
    }

    static func lastChecked() -> Date? {
        guard let s = UserDefaults.standard.string(forKey: Keys.checkedAt) else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    struct NetworkRelease {
        var tag: String
        var name: String
        var published: Date?
        var pageURL: String
        var notes: String
        /// 检查更新时 API 给的 zip 包精确下载地址（Gitee/GitHub 都可能），nil = 未拿到
        var assetURL: String? = nil
    }

    /// 最近一次检查成功用的源
    static var lastSource: ReleaseFallback.Source {
        get { ReleaseFallback.Source(rawValue: UserDefaults.standard.string(forKey: Keys.source) ?? "") ?? .github }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.source) }
    }

    static func cachedRelease() -> NetworkRelease? {
        let d = UserDefaults.standard
        guard let tag = d.string(forKey: Keys.tag), !tag.isEmpty else { return nil }
        var published: Date?
        if let s = d.string(forKey: Keys.published) {
            published = ISO8601DateFormatter().date(from: s)
        }
        return NetworkRelease(tag: tag,
                              name: d.string(forKey: Keys.name) ?? "",
                              published: published,
                              pageURL: d.string(forKey: Keys.page) ?? NetworkPackage.releasesURL,
                              notes: d.string(forKey: Keys.notes) ?? "",
                              assetURL: d.string(forKey: Keys.assetURL))
    }

    private static func save(_ release: NetworkRelease) {
        let d = UserDefaults.standard
        d.set(release.tag, forKey: Keys.tag)
        d.set(release.name, forKey: Keys.name)
        d.set(release.pageURL, forKey: Keys.page)
        d.set(release.notes, forKey: Keys.notes)
        let iso = ISO8601DateFormatter()
        d.set(release.published.map { iso.string(from: $0) } ?? "", forKey: Keys.published)
        d.set(iso.string(from: Date()), forKey: Keys.checkedAt)
        d.set(release.assetURL ?? "", forKey: Keys.assetURL)
    }

    /// 用缓存 + 本机记录的包版本算状态（不发网络请求）。
    /// 没有包版本记录时不比对——视为可安装（installed 显示「未记录」）。
    static func stateFromCache() -> NetworkUpdateState {
        let installed = installedTag ?? "未记录"
        guard let release = cachedRelease() else { return .unknown }
        if let have = installedTag, !isNewer(release.tag, than: have) {
            return .upToDate(installed: installed, latest: release.tag)
        }
        return .available(installed: installed, latest: release.tag)
    }

    // MARK: 网络（与 App 自更新同思路：先拿 tag（0 API 配额），真出新版本才查一次 API）
    //
    // 2026-11-17：302 拦截统一收进 ReleaseFallback.latestTag（这里原先自己写了一份
    // RedirectCatcher，功能重复，已删）。

    /// 手动「检查更新」的软节流：60 秒内重复点直接回缓存，不联网。
    private static let manualThrottle: TimeInterval = 60

    private static var userAgent: String { "SkyCC/\(mcHelperBuildVersion)" }

    /// Gitee / GitHub 的 `releases/latest` 页面（302 的 Location 里就带 tag）
    private static var giteeLatestPage: String {
        "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(NetworkPackage.giteeRepo)/releases/latest"
    }
    private static var githubLatestPage: String {
        "https://github.com/\(NetworkPackage.repo)/releases/latest"
    }

    /// 拿最新 release。
    ///
    /// 2026-11-17（用户要求「别把 API 打限流」）改成和 App 自更新同一个思路：
    ///   ① Gitee `releases/latest` 的 **302** —— 国内可达，**0 API 配额**，
    ///      也不需要仓库里放 latest.json（拦下跳转、不读正文）；
    ///   ② GitHub 的同一条 302（Gitee 不通时）；
    ///   ③ 两家页面都拿不到 tag，才落到 Gitee API（这一步才计配额）。
    /// 拿到 tag 之后：**与缓存同 tag 就只刷检查时间、一次 API 都不打**；
    /// 只有真出了新版本，才查一次 API 补发布说明与资产地址。
    static func fetchLatest(completion: @escaping (Result<NetworkRelease, Error>) -> Void) {
        // 60 秒软节流：刚查过就直接回缓存
        if let last = lastChecked(), Date().timeIntervalSince(last) < manualThrottle,
           let cached = cachedRelease() {
            completion(.success(cached))
            return
        }
        ReleaseFallback.latestTag(from: giteeLatestPage, userAgent: userAgent) { tag in
            if let tag {
                NetworkUpdate.lastSource = .gitee
                resolve(tag: tag, fromGitee: true, completion: completion)
                return
            }
            ReleaseFallback.latestTag(from: githubLatestPage, userAgent: userAgent) { gtag in
                if let gtag {
                    NetworkUpdate.lastSource = .github
                    resolve(tag: gtag, fromGitee: false, completion: completion)
                    return
                }
                // 两家页面都不可达 → API 兜底（会耗配额，正常情况下走不到这一步）
                giteeAPILatest { release in
                    if let release {
                        NetworkUpdate.lastSource = .gitee
                        completion(.success(release))
                    } else {
                        completion(.failure(NSError(domain: "network", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Gitee / GitHub 都不可达"])))
                    }
                }
            }
        }
    }

    /// tag → release：同 tag 用缓存（零 API），新 tag 先给基础信息、再后台补说明。
    private static func resolve(tag: String, fromGitee: Bool,
                                completion: @escaping (Result<NetworkRelease, Error>) -> Void) {
        if let cached = cachedRelease(), cached.tag == tag {
            save(cached)              // 只刷新 checkedAt
            completion(.success(cached))
            return
        }
        let pageURL = fromGitee
            ? "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(NetworkPackage.giteeRepo)/releases/tag/\(tag)"
            : "https://github.com/\(NetworkPackage.repo)/releases/tag/v\(tag)"
        let basic = NetworkRelease(tag: tag, name: tag, published: nil, pageURL: pageURL, notes: "")
        save(basic)
        completion(.success(basic))
        // 后台补发布说明 / 精确资产地址：失败不影响版本判断
        if fromGitee {
            giteeAPILatest(expectedTag: tag) { _ in }
        } else {
            fetchDetailFromGitHub(tag: tag) { _ in }
        }
    }

    /// Gitee API（**会耗配额**：只在「页面 302 拿不到」或「新版本补说明」时各用一次）
    private static func giteeAPILatest(expectedTag: String? = nil,
                                       _ completion: @escaping (NetworkRelease?) -> Void) {
        ReleaseFallback.getDict(ReleaseFallback.giteeAPI(NetworkPackage.giteeRepo),
                                userAgent: userAgent) { dict in
            guard let dict, var tag = dict["tag_name"] as? String, !tag.isEmpty else {
                completion(nil); return
            }
            if tag.hasPrefix("v") { tag.removeFirst() }
            // 后台补说明时 latest 可能已经比手上的 tag 新 → 对不上就丢弃，别覆盖
            if let expected = expectedTag, expected != tag { completion(nil); return }
            var published: Date?
            // Gitee 的 release 对象可能只有 created_at（带时区偏移，ISO8601 能解析）
            if let s = (dict["published_at"] as? String) ?? (dict["created_at"] as? String) {
                published = ISO8601DateFormatter().date(from: s)
            }
            let base = "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(NetworkPackage.giteeRepo)"
            save(NetworkRelease(tag: tag,
                                name: dict["name"] as? String ?? tag,
                                published: published,
                                pageURL: "\(base)/releases/tag/\(tag)",
                                notes: dict["body"] as? String ?? "",
                                assetURL: ReleaseFallback.assetURL(in: dict, named: NetworkPackage.assetName(tag: tag))))
            completion(cachedRelease())
        }
    }

    /// GitHub API 补说明（只在新 tag 时调一次；失败静默，不影响版本判断）
    private static func fetchDetailFromGitHub(tag: String,
                                              _ completion: @escaping (NetworkRelease?) -> Void) {
        let repo = NetworkPackage.repo
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard error == nil, let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var apiTag = obj["tag_name"] as? String else {
                completion(nil); return
            }
            if apiTag.hasPrefix("v") { apiTag.removeFirst() }
            // 后台补说明期间 latest 已经变了 → 丢弃，别把新 tag 的信息写到旧 tag 上
            if apiTag != tag { completion(nil); return }
            var published: Date?
            if let s = obj["published_at"] as? String {
                published = ISO8601DateFormatter().date(from: s)
            }
            save(NetworkRelease(tag: tag,
                                name: obj["name"] as? String ?? tag,
                                published: published,
                                pageURL: "https://github.com/\(repo)/releases/tag/v\(tag)",
                                notes: obj["body"] as? String ?? "",
                                assetURL: ReleaseFallback.assetURL(in: obj, named: NetworkPackage.assetName(tag: tag))))
            completion(cachedRelease())
        }.resume()
    }
}

// MARK: - 一键更新安装器（NVIDIA 同模式）

/// 下载 release zip → 解压 → 找包内安装脚本 → 管理员权限执行。
/// 与 DriverInstaller / NVIDIA 离线包安装完全同构：runner + osascript admin + 日志轮询。
/// 备份 / 替换 / 校验逻辑全部在包内脚本里（用户随包提供），App 不越俎代庖。
struct NetworkInstaller {
    static let logPath = "/tmp/mc-network-install.log"

    static func install(tag: String,
                        onPhase: @escaping (DriverInstallPhase) -> Void,
                        onLog: @escaping (String) -> Void = { _ in }) {
        let emit: (DriverInstallPhase) -> Void = { p in
            DispatchQueue.main.async { onPhase(p) }
        }
        let emitLog: (String) -> Void = { line in
            DispatchQueue.main.async { onLog(line) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("mc-network-\(tag)")
            try? fm.removeItem(at: work)
            guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil else {
                emit(.failed("无法创建临时目录")); return
            }

            // 1) 下载 release 资产
            guard let url = URL(string: NetworkPackage.downloadURL(tag: tag)) else {
                emit(.failed("无法构造下载地址")); return
            }
            let archive = work.appendingPathComponent("release.zip")
            let group = DispatchGroup()
            var moveError: String?
            group.enter()
            let task = URLSession.shared.downloadTask(with: url) { tmpURL, response, err in
                defer { group.leave() }
                if let err {
                    moveError = err.localizedDescription
                    return
                }
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    moveError = "下载失败（HTTP \(code)）：确认 \(NetworkPackage.repo) release v\(tag) 里有 \(NetworkPackage.assetName(tag: tag))"
                    return
                }
                guard let tmpURL else { moveError = "下载未返回文件"; return }
                do { try fm.moveItem(at: tmpURL, to: archive) }
                catch { moveError = error.localizedDescription }
            }
            let obs = task.progress.observe(\.fractionCompleted) { obj, _ in
                emit(.downloading(progress: obj.fractionCompleted))
            }
            task.resume()
            group.wait()
            _ = obs
            if let moveError { emit(.failed(moveError)); return }

            // 2) 解压（ditto 处理 zip）
            emit(.extracting)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archive.path, work.path]
            do {
                try unzip.run(); unzip.waitUntilExit()
                if unzip.terminationStatus != 0 {
                    emit(.failed("解压失败（退出码 \(unzip.terminationStatus)）")); return
                }
            } catch {
                emit(.failed("解压出错：\(error.localizedDescription)")); return
            }
            try? fm.removeItem(at: archive)

            // 3) 在包里找安装脚本（根目录或多层子目录；install.command 优先，install.sh 兜底，
            //    与 NVIDIA 离线包的 findInstallScript 同一套查找）
            guard let script = findInstallScript(in: work) else {
                emit(.failed("包里没有安装脚本（install.command / install.sh）")); return
            }
            let payload = script.deletingLastPathComponent()
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            // 4) 写 runner：cd 进包目录后 exec 包内脚本，输出全部进日志。
            //    用 exec 而不是后台 &：do shell script 结束时会收掉同进程组子进程，
            //    所以安装必须在前台跑完。
            let logURL = URL(fileURLWithPath: logPath)
            let runner = work.appendingPathComponent("run-install.sh")
            let runnerBody = """
            #!/bin/bash
            export LOG=\(DriverInstaller.sh(logURL.path))
            cd \(DriverInstaller.sh(payload.path)) || {
              printf '   STOP: 无法进入安装目录\\n' > "$LOG"
              exit 2
            }
            : > "$LOG"
            printf '== Sky CC：开始安装网卡驱动包 %s\\n' "$(date)" >> "$LOG"
            exec /bin/bash \(DriverInstaller.sh(script.lastPathComponent)) >> "$LOG" 2>&1
            """
            do {
                try runnerBody.write(to: runner, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
            } catch {
                emit(.failed("无法写入安装脚本：\(error.localizedDescription)")); return
            }

            // 5) 管理员授权执行（复用 DriverInstaller 的提权与日志轮询）
            emit(.authorizing)
            let result = DriverInstaller.runWithAdminPrivileges(executable: runner.path,
                                                                logURL: logURL,
                                                                deadline: 20 * 60) { elapsed, line in
                emit(.installing(elapsed: elapsed))
                if let line { emitLog(line) }
            }

            if result.timedOut {
                emit(.failed("更新超过 20 分钟仍未结束，已中断等待（日志：\(logPath)）"))
                return
            }

            NvidiaUpdate.invalidateKextListCache()
            if result.ok {
                NetworkUpdate.installedTag = tag      // 包版本记录，供下次比对
                emit(.succeeded)
            } else {
                let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                emit(.failed("更新失败（详见日志 \(logPath)）："
                             + (logText.split(separator: "\n").last.map(String.init) ?? "")))
            }
        }
    }

    /// 在目录（含多层子目录）里找安装脚本：install.command 优先，install.sh 兜底
    private static func findInstallScript(in dir: URL) -> URL? {
        let fm = FileManager.default
        let name = dir.lastPathComponent
        if name == "install.command" || name == "install.sh" { return dir }
        guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let sorted = children.sorted { $0 < $1 }
        for preference in ["install.command", "install.sh"] {
            if let hit = sorted.first(where: { $0 == preference }) {
                return dir.appendingPathComponent(hit)
            }
        }
        for child in sorted where !child.hasPrefix(".") {
            let full = dir.appendingPathComponent(child)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full.path, isDirectory: &isDir)
            if isDir.boolValue, let found = findInstallScript(in: full) { return found }
        }
        return nil
    }
}
