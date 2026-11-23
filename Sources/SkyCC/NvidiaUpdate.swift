//
//  NvidiaUpdate.swift
//  NVIDIA（NullMoth）驱动版本检测 + 一键安装
//
//  移植自 Vela-X（Xelon233/Vela-X，GPLv3）NvidiaUpdate.swift / DriverInstaller，
//  适配本项目（LAPQC71x）的差异：
//    · 版本源不是 NullMoth 上游，而是自维护 fork skyone-code/nvidia-macos-driver-LAPQC71
//      （release/2.9-telemetry 线，含 NVRMFB phantom HDMI 热插拔修复；
//       上游 v3.0 会覆盖掉这套自建二进制，所以更新以 fork 为准）。
//    · 安装包不是上游的 nullmoth-nvidia-<tag>.tar.gz + install.sh，
//      而是自建离线包 LAPQC71-NVIDIA-<tag>-fork.zip + install.command。
//    · 本机驱动走 /Library/Extensions（OC 不注入 NVRMFB）。
//
//  已安装版本来自本地（按可信度排序）：
//    1. /Library/Extensions/{NVRM,NVAccel,NVRMFB,NVRMAGDC}.kext 的 CFBundleShortVersionString
//    2. /Library/NullMoth/driver-version（安装脚本写入）
//    3. kmutil showloaded 里的 com.nullmoth.NVRM (x.y.z)
//
//  最新版本查询用 302 重定向拦截（0 字节正文、不耗 GitHub API 配额，
//  未登录配额只有 60 次/小时/出口 IP）；只有版本号变了才额外查一次 API 拿发布说明。
//

import Foundation
import CFNetwork
import SwiftUI

struct NvidiaRelease {
    var tag: String            // 2.9.2（去掉前缀 v）
    var name: String
    var published: Date?
    var pageURL: String
    var notes: String
    /// 检查更新时 API 给的离线包精确下载地址（Gitee/GitHub 都可能），nil = 未拿到
    var assetURL: String? = nil
}

enum NvidiaUpdateState: Equatable {
    case unknown                 // 还没查过
    case notInstalled            // 没装 NullMoth 驱动
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
        case .notInstalled: return "未安装"
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

enum NvidiaUpdate {

    /// 版本源：自维护 fork（含 NVRMFB phantom 修复）。上游 nullmoth/nvidia-macos-driver
    /// 的 v3.0 是「官方二进制」，一键装它会覆盖自建修复，所以不作为更新源。
    /// 仓库名必须用改名后的全名 LAPQC71：旧名 nvidia-macos-driver 会被 GitHub
    /// 301 重定向到新名，而检测只拦第一跳，拿到 301 就直接报错。
    static let repo = "skyone-code/nvidia-macos-driver-LAPQC71"
    static let releasesURL = "https://github.com/\(repo)/releases"
    private static let latestURL = "https://github.com/\(repo)/releases/latest"
    private static let apiURL = "https://api.github.com/repos/\(repo)/releases/latest"
    // Gitee 镜像仓（GitHub 不通时的兜底，tag 与 GitHub 一致但无 v 前缀）
    static let giteeRepo = "nvidia-macos-driver-LAPQC71"
    /// Gitee 的 releases/latest **页面**：302 跳转里就带 tag，0 API 配额（2026-11-17）
    private static let giteeLatestPage =
        "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(giteeRepo)/releases/latest"

    /// 手动「检查更新」的软节流：60 秒内重复点直接回缓存，不再联网。
    /// 302 不吃配额，但连点也没必要真发一串请求。
    private static let manualThrottle: TimeInterval = 60

    /// 最近一次检查成功用的源（GitHub 不通走 Gitee 后，下载也要跟着走 Gitee）
    private static let sourceKey = "nvidia.latestSource"
    static var lastSource: ReleaseFallback.Source {
        get { ReleaseFallback.Source(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .github }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    /// 离线包资产名（release 上传时统一成 ASCII 名，URL 不用转义）。
    /// 不能带 NullMoth 字样——这是 fork 的发布，避免被当成官方包。
    static func assetName(tag: String) -> String { "LAPQC71-NVIDIA-\(tag)-fork.zip" }
    static func downloadURL(tag: String) -> String {
        // 检查更新时 API 给过精确资产地址就优先用（哪个源通的就用哪个）
        if let r = cachedRelease, r.tag == tag, let u = r.assetURL, !u.isEmpty { return u }
        if lastSource == .gitee {
            return "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(giteeRepo)/releases/download/\(tag)/\(assetName(tag: tag))"
        }
        return "https://github.com/\(repo)/releases/download/v\(tag)/\(assetName(tag: tag))"
    }

    /// 自动检查的最小间隔（手动点按钮不受限）
    static let autoCheckInterval: TimeInterval = 6 * 3600

    // MARK: - 本地已安装版本

    /// 看起来像版本号的才认（"2.9.1" 认，"见 VERSION 文件" 不认）
    private static func looksLikeVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.first?.isNumber == true
            && s.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// release 风格版本号：在纯数字点分之外放行带字母/连字符的段（"3.0-Patch.1"，2026-11-15
    /// 用户实测已装版本显示 3.0.1 而不是 3.0-Patch.1，根因就是这里把 ShortVersion 判为不合法）
    private static func looksLikeReleaseVersion(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 32 && s.first?.isNumber == true
            && s.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
    }

    static func installedVersion() -> String? {
        // 1) kext 的 Info.plist —— 与本机实际运行的二进制一一对应，最可信。
        //    读 CFBundleShortVersionString（release 风格，如 3.0-Patch.1）；
        //    CFBundleVersion 是 kmutil 要求的纯数字备份号（3.0.1），不是对外版本
        for name in componentNames {
            let path = "/Library/Extensions/\(name).kext/Contents/Info.plist"
            if let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
               let v = dict["CFBundleShortVersionString"] as? String,
               looksLikeReleaseVersion(v) {
                return v
            }
        }
        // 2) 安装脚本写的版本文件（纯数字点分）
        if let s = try? String(contentsOfFile: "/Library/NullMoth/driver-version", encoding: .utf8) {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeVersion(v) { return v }
        }
        // 3) 已加载的 kext（kmutil showloaded，普通用户可跑）
        for line in kextList.split(separator: "\n") where line.contains("com.nullmoth.NVRM") {
            if let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"),
               open < close {
                let v = String(line[line.index(after: open)..<close])
                if looksLikeVersion(v) { return v }
            }
        }
        return nil
    }

    // MARK: - 驱动组件（NVRM / NVAccel / NVRMFB / NVRMAGDC）

    static let componentNames = ["NVRM", "NVAccel", "NVRMFB", "NVRMAGDC"]

    struct Component: Identifiable {
        let name: String
        let version: String
        let present: Bool
        let loaded: Bool
        var id: String { name }
        var path: String { "/Library/Extensions/\(name).kext" }
        var bundleID: String { "com.nullmoth.\(name)" }
    }

    static func components() -> [Component] {
        let loaded = kextList
        return componentNames.map { name in
            let plist = "/Library/Extensions/\(name).kext/Contents/Info.plist"
            let dict = NSDictionary(contentsOfFile: plist) as? [String: Any]
            let version = (dict?["CFBundleShortVersionString"] as? String) ?? "—"
            return Component(name: name,
                             version: version,
                             present: FileManager.default.fileExists(atPath: plist),
                             loaded: loaded.contains("com.nullmoth.\(name) ("))
        }
    }

    /// kmutil showloaded 的输出（普通用户可跑；stderr 的「No variant specified」提示忽略）。
    /// 结果缓存：app 生命周期内驱动加载状态不会变（装完驱动要重启），只在安装成功后手动刷新。
    private static var _kextListCache: String?
    static var kextList: String {
        if let c = _kextListCache { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/kmutil")
        p.arguments = ["showloaded"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()   // 吞掉 stderr 提示
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        _kextListCache = text
        return text
    }
    static func invalidateKextListCache() { _kextListCache = nil }

    // MARK: - 版本比较

    /// "2.6.10" > "2.6.9"：逐段按数字比，缺位补 0
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 缓存

    private enum Keys {
        static let tag = "nvidia.latestTag"
        static let name = "nvidia.latestName"
        static let page = "nvidia.latestPage"
        static let notes = "nvidia.latestNotes"
        static let published = "nvidia.latestPublished"
        static let checkedAt = "nvidia.checkedAt"
        static let assetURL = "nvidia.latestAssetURL"   // 离线包精确下载地址（源感知）
    }

    static var lastChecked: Date? {
        guard let s = UserDefaults.standard.string(forKey: Keys.checkedAt) else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    static var cachedRelease: NvidiaRelease? {
        guard let tag = UserDefaults.standard.string(forKey: Keys.tag), !tag.isEmpty else { return nil }
        var published: Date?
        if let s = UserDefaults.standard.string(forKey: Keys.published) {
            published = ISO8601DateFormatter().date(from: s)
        }
        // 2026-11-15：fork 仓 release 文案已把「官方」改为「nullmoth」，但旧缓存里
        // 还是老文案（不点检查更新就一直显示）→ 读取时就地改写并回写 UserDefaults
        var notes = UserDefaults.standard.string(forKey: Keys.notes) ?? ""
        if notes.contains("在官方 3.0") {
            notes = notes.replacingOccurrences(of: "在官方 3.0", with: "在 nullmoth 3.0")
            UserDefaults.standard.set(notes, forKey: Keys.notes)
        }
        return NvidiaRelease(tag: tag,
                             name: UserDefaults.standard.string(forKey: Keys.name) ?? "",
                             published: published,
                             pageURL: UserDefaults.standard.string(forKey: Keys.page) ?? releasesURL,
                             notes: notes,
                             assetURL: UserDefaults.standard.string(forKey: Keys.assetURL))
    }

    private static func save(_ release: NvidiaRelease) {
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

    /// 用缓存 + 本地版本算出当前状态（不发网络请求）
    static func stateFromCache() -> NvidiaUpdateState {
        guard let installed = installedVersion() else { return .notInstalled }
        guard let release = cachedRelease else { return .unknown }
        return isNewer(release.tag, than: installed)
            ? .available(installed: installed, latest: release.tag)
            : .upToDate(installed: installed, latest: release.tag)
    }

    static var needsAutoCheck: Bool {
        guard let last = lastChecked else { return true }
        return Date().timeIntervalSince(last) > autoCheckInterval
    }

    // MARK: - 网络

    /// 拦截 302，只取 Location，不下载正文
    private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
        var location: String?
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            location = request.url?.absoluteString
            completionHandler(nil)
        }
    }

    /// 从 ".../releases/tag/v2.9.2" 里取出 "2.9.2"
    static func tag(from urlString: String?) -> String? {
        guard let urlString, let range = urlString.range(of: "/releases/tag/") else { return nil }
        var tag = String(urlString[range.upperBound...])
        if let q = tag.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            tag = String(tag[..<q])
        }
        if tag.hasPrefix("v") { tag.removeFirst() }
        return tag.isEmpty ? nil : tag
    }

    /// 第一步：拿最新版本号。
    ///
    /// 2026-11-17（用户要求「别把 API 打限流」）改成三级：
    ///   ① **Gitee 的 302**（`releases/latest` 页面，Location 里就是 tag）——
    ///      国内可达，且**一个字节 API 配额都不吃**，也不需要仓库里放 latest.json；
    ///   ② GitHub 的同一条 302（Gitee 不通时）；
    ///   ③ 两家页面都拿不到 tag，才落到 Gitee API（这一步才计配额）。
    /// 成功时记录 lastSource，供下载 URL 跟随同一源。
    private static func fetchTag(completion: @escaping (Result<String, Error>) -> Void) {
        let ua = "SkyCC/\(mcHelperBuildVersion)"
        ReleaseFallback.latestTag(from: giteeLatestPage, userAgent: ua) { gtag in
            if let gtag {
                lastSource = .gitee
                completion(.success(gtag))
                return
            }
            fetchTagFromGitHub { result in
                switch result {
                case .success(let tag):
                    lastSource = .github
                    completion(.success(tag))
                case .failure(let error):
                    fetchTagFromGitee { fallback in
                        if let fallback {
                            lastSource = .gitee
                            completion(.success(fallback))
                        } else {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    /// Gitee 镜像拿 tag（releases/latest API 的 tag_name，无 v 前缀；带 v 也剥掉）
    private static func fetchTagFromGitee(_ completion: @escaping (String?) -> Void) {
        ReleaseFallback.getDict(ReleaseFallback.giteeAPI(giteeRepo),
                                userAgent: "SkyCC/3.0") { dict in
            var tag = dict?["tag_name"] as? String ?? ""
            if tag.hasPrefix("v") { tag.removeFirst() }
            completion(tag.isEmpty ? nil : tag)
        }
    }

    /// 第一步的 GitHub 路径（302 拦截拿 tag）
    private static func fetchTagFromGitHub(completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: latestURL) else {
            completion(.failure(NSError(domain: "nvidia", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "URL 无效"])))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("SkyCC/3.0", forHTTPHeaderField: "User-Agent")

        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .default, delegate: catcher, delegateQueue: nil)
        session.dataTask(with: request) { _, response, error in
            defer { session.finishTasksAndInvalidate() }
            // 正常情况：302 → Location 里有 tag
            if let tag = tag(from: catcher.location) {
                completion(.success(tag))
                return
            }
            // 某些网络下不跳转，最终 URL 就是 tag 页
            if let finalURL = response?.url?.absoluteString, let tag = tag(from: finalURL) {
                completion(.success(tag))
                return
            }
            if let error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            completion(.failure(NSError(domain: "nvidia", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])))
        }.resume()
    }

    /// 第二步（可选）：只有版本号变了才查 API，补充发布说明与时间。
    /// 2026-11-15：GitHub 拿不到时换 Gitee 镜像；同时捕获离线包精确下载地址
    /// （assets 里按资产名匹配，安装时优先用它，下载源与检查源保持一致）。
    private static func fetchDetail(tag: String, completion: @escaping (NvidiaRelease?) -> Void) {
        if lastSource == .gitee {
            fetchDetailFromGitee(tag: tag, completion: completion)
            return
        }
        guard let url = URL(string: apiURL) else {
            fetchDetailFromGitee(tag: tag, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkyCC/3.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // GitHub 不通 → Gitee 兜底
                fetchDetailFromGitee(tag: tag, completion: completion)
                return
            }
            var published: Date?
            if let s = obj["published_at"] as? String {
                published = ISO8601DateFormatter().date(from: s)
            }
            let body = (obj["body"] as? String) ?? ""
            let notes = body
                .split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

            completion(NvidiaRelease(tag: tag,
                                     name: (obj["name"] as? String) ?? tag,
                                     published: published,
                                     pageURL: (obj["html_url"] as? String)
                                        ?? "https://github.com/\(repo)/releases/tag/v\(tag)",
                                     notes: notes,
                                     assetURL: ReleaseFallback.assetURL(in: obj, named: assetName(tag: tag))))
        }.resume()
    }

    /// 发布说明的 Gitee 路径（body 取第一行非空行，与 GitHub 路径的提取逻辑一致）
    private static func fetchDetailFromGitee(tag: String, completion: @escaping (NvidiaRelease?) -> Void) {
        ReleaseFallback.getDict(ReleaseFallback.giteeAPI(giteeRepo),
                                userAgent: "SkyCC/3.0") { dict in
            guard let dict else { completion(nil); return }
            var published: Date?
            // Gitee 的 release 对象可能只有 created_at（带时区偏移，ISO8601 能解析）
            if let s = (dict["published_at"] as? String) ?? (dict["created_at"] as? String) {
                published = ISO8601DateFormatter().date(from: s)
            }
            let body = (dict["body"] as? String) ?? ""
            let notes = body
                .split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            completion(NvidiaRelease(tag: tag,
                                     name: (dict["name"] as? String) ?? tag,
                                     published: published,
                                     pageURL: (dict["html_url"] as? String)
                                        ?? "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(giteeRepo)/releases/tag/\(tag)",
                                     notes: notes,
                                     assetURL: ReleaseFallback.assetURL(in: dict, named: assetName(tag: tag))))
        }
    }

    /// 异步：查最新版本，写缓存，回调在主线程。
    /// 版本号一拿到就回调（这是用户真正关心的部分），发布说明留到后台慢慢补。
    static func fetchLatest(completion: @escaping (Result<NvidiaRelease, Error>) -> Void,
                            onEnrich: ((NvidiaRelease) -> Void)? = nil) {
        // 60 秒软节流：刚查过就直接回缓存。302 本身不吃 API 配额，
        // 但连点按钮也没必要真发一串请求，用户体验上也没有区别。
        if let last = lastChecked, Date().timeIntervalSince(last) < manualThrottle,
           let cached = cachedRelease {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }
        fetchTag { tagResult in
            switch tagResult {
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }

            case .success(let tag):
                // 版本没变就直接复用缓存里的说明，省掉一次 API 调用
                if let cached = cachedRelease, cached.tag == tag {
                    save(cached)   // 只刷新检查时间
                    DispatchQueue.main.async { completion(.success(cached)) }
                    return
                }

                let pageURL = lastSource == .gitee
                    ? "https://gitee.com/\(ReleaseFallback.giteeOwner)/\(giteeRepo)/releases/tag/\(tag)"
                    : "https://github.com/\(repo)/releases/tag/v\(tag)"
                let basic = NvidiaRelease(tag: tag, name: tag, published: nil,
                                          pageURL: pageURL, notes: "")
                save(basic)
                DispatchQueue.main.async { completion(.success(basic)) }

                // 后台补发布说明：API 走不通也不影响版本判断
                guard let onEnrich else { return }
                fetchDetail(tag: tag) { detail in
                    guard let detail else { return }
                    save(detail)
                    DispatchQueue.main.async { onEnrich(detail) }
                }
            }
        }
    }
}

// MARK: - 一键下载并安装（自动执行 install.command）

/// 安装流程的阶段，供 UI 展示进度
enum DriverInstallPhase: Equatable {
    case idle
    case preparing                     // 正在取版本信息 / 建临时目录，还没开始下字节
    case downloading(progress: Double)
    /// 首次安装 GPU 固件包（约 550 MB）：total 为 0 表示服务器没给长度，界面只显示已下载量
    case downloadingFirmware(progress: Double, received: Int64, total: Int64)
    case extracting
    case authorizing                    // 已经弹出管理员密码框，等用户输入
    case installing(elapsed: Int)       // 后台以 root 跑安装脚本，秒数用于显示耗时
    case succeeded
    case failed(String)

    var label: String {
        switch self {
        case .idle:               return "未开始"
        case .preparing:          return "准备中…"
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .downloadingFirmware(let p, let got, let total):
            if total > 0 {
                return "下载 GPU 固件包 \(Int(p * 100))%（\(DriverInstallPhase.mbText(got)) / \(DriverInstallPhase.mbText(total)) MB）"
            }
            return "下载 GPU 固件包 \(DriverInstallPhase.mbText(got)) MB…"
        case .extracting:         return "解压中…"
        case .authorizing:        return "等待管理员授权…"
        case .installing(let s):  return "安装中… 已用 \(DriverInstallPhase.timeText(s))"
        case .succeeded:          return "安装完成，请重启一次"
        case .failed(let m):      return "失败：\(m)"
        }
    }

    static func timeText(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds) 秒" }
        return "\(seconds / 60) 分 \(String(format: "%02d", seconds % 60)) 秒"
    }

    /// 十进制的 MB（549727763 → 550），跟文案里的「约 550 MB」一致；用 MiB 会显示成 524 让人对不上
    static func mbText(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(max(0, bytes)) / 1_000_000)
    }

    /// 确定进度（0…1）。nil = 还不知道总量，或者根本不是下载阶段
    var progress: Double? {
        switch self {
        case .downloading(let p):                    return p
        case .downloadingFirmware(let p, _, let t):  return t > 0 ? p : nil
        default:                                     return nil
        }
    }

    /// 正在下载（进度可能未知，界面用不确定进度的条）
    var isDownloading: Bool {
        switch self {
        case .downloading, .downloadingFirmware: return true
        default:                                 return false
        }
    }

    /// 按钮上用的短文案（带 MB 的长文案留给状态行，否则按钮会被撑开）
    var shortLabel: String {
        switch self {
        case .downloadingFirmware(let p, _, let total):
            return total > 0 ? "下载固件包 \(Int(p * 100))%" : "下载固件包…"
        default:
            return label
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 下载 / 解压 / 授权 / 安装进行中
    var isBusy: Bool {
        switch self {
        case .idle, .succeeded, .failed: return false
        default: return true
        }
    }
}

// MARK: - 首次安装的 GPU 固件包（约 550 MB）

/// 离线包自己不带 GPU 固件：`pkgroot/fw_fetch.sh` 从 NVIDIA 官方 Linux 驱动包里读出来（约 550 MB），
/// 三条来源依次尝试——① 早先装过、四个文件仍符合 pin；② 手边已有的 `.run`；③ `curl -sS` 现场下载。
///
/// 第三条是静默的：550 MB 一段空白，用户只会以为卡死。而 `install.sh` 支持 `NULLMOTH_FW_RUN=<file>`
/// 把「手边已有的 .run」直接喂进去（走②，不再 curl），所以这里由 App 负责带进度下载 + 校验 SHA-256，
/// 安装脚本拿到的就是本地文件。
///
/// 版本号 / URL / SHA / 四个文件名都从包内 `fw_fetch.sh` 读，App 不写死——将来包换成新内核版本，
/// 这里自动跟着走；读不到（包结构变了）就退回脚本自己下载，没有进度但装得上。
enum DriverFirmware {
    struct Pins: Equatable {
        let version: String          // 620.73.04
        let url: String              // https://download.nvidia.com/.../NVIDIA-Linux-x86_64-<ver>.run
        let sha256: String
        let members: [String]        // 只要文件名：gsp_tu10x.bin …
    }

    /// 已装固件的位置，与 fw_fetch.sh 的 --installed 默认值一致；四个文件都在就直接复用，不联网
    static let installedRoot = "/Library/NullMoth/nvfw/nvidia"

    // MARK: 从离线包里读 pin

    /// 在离线包目录里找 `.tar.gz`，抽出其中的 `pkgroot/fw_fetch.sh` 并解析
    static func pins(inOfflinePackage dir: URL) -> Pins? {
        for tarball in tarballs(in: dir) {
            guard let text = member("pkgroot/fw_fetch.sh", of: tarball) else { continue }
            guard let ver = value("VER", in: text),
                  let rawURL = value("URL_RUN", in: text),
                  let sha = value("SHA_RUN", in: text),
                  let list = value("FW_MEMBERS", in: text) else { continue }
            // 脚本里写的是 URL_RUN=".../$VER/NVIDIA-Linux-x86_64-$VER.run"，$VER 要自己展开
            let url = rawURL
                .replacingOccurrences(of: "${VER}", with: ver)
                .replacingOccurrences(of: "$VER", with: ver)
            guard url.hasPrefix("https://"), sha.count == 64 else { continue }
            let members = list.split(separator: " ").map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty }
            guard !members.isEmpty else { continue }
            return Pins(version: ver, url: url, sha256: sha.lowercased(), members: members)
        }
        return nil
    }

    /// 离线包顶层的 tar 包（`nullmoth-nvidia-<x>.tar.gz`）
    private static func tarballs(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.lastPathComponent.hasSuffix(".tar.gz") }
    }

    /// 包里自带固件时（`pkgroot/Users/Shared/nvfw` 下有真文件），`install.sh` 直接 ditto 那一份，
    /// 根本不会调 `fw_fetch.sh` —— 这时候 App 再下 550 MB 纯属浪费。
    /// 布局不猜：把 `pkgroot/Users` 整个抽到临时目录里看有没有像样的文件
    /// （空目录不算，当前包就是空的，此时 install.sh 才去调 fw_fetch.sh）。
    static func packageCarriesFirmware(inOfflinePackage dir: URL) -> Bool {
        let fm = FileManager.default
        for tarball in tarballs(in: dir) {
            let tmp = fm.temporaryDirectory.appendingPathComponent("mc-fwchk-\(UUID().uuidString)")
            guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { continue }
            defer { try? fm.removeItem(at: tmp) }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", tarball.path, "-C", tmp.path, "pkgroot/Users"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()

            let nvfw = tmp.appendingPathComponent("pkgroot/Users/Shared/nvfw")
            guard let walker = fm.enumerator(at: nvfw, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let f as URL in walker {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 1_000_000 { return true }
            }
        }
        return false
    }

    /// `tar -xzOf` 只取一个成员，不落盘
    private static func member(_ path: String, of tarball: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzOf", tarball.path, path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 取脚本里的 `KEY=value`（值可能带引号）
    private static func value(_ key: String, in script: String) -> String? {
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key + "=") else { continue }
            let v = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: 已装 / 缓存 / 下载

    /// 四个固件文件都在（大小合理）→ 安装脚本会直接复用，不用下 550 MB
    static func isInstalled(_ pins: Pins) -> Bool {
        let dir = URL(fileURLWithPath: installedRoot).appendingPathComponent(pins.version)
        for name in pins.members {
            let f = dir.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  let size = attrs[.size] as? Int64, size > 1_000_000 else { return false }
        }
        return true
    }

    /// 缓存位置：升级重装时不必再下一次 550 MB（卸载会清 /Library/NullMoth）
    static func cacheURL(_ pins: Pins) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let name = URL(string: pins.url)?.lastPathComponent
            ?? "NVIDIA-Linux-x86_64-\(pins.version).run"
        return base
            .appendingPathComponent("com.skycc.console/nvfw/\(pins.version)")
            .appendingPathComponent(name)
    }

    /// 拿一份校验过的 `.run`：缓存命中直接用，否则带进度下载。
    /// 返回 nil 表示这一步没做成（网络/校验/解析），调用方退回让脚本自己下载，不阻断安装。
    /// 固件包下载失败的原因（带人话，直接显示给用户）
    struct DownloadProblem: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func localRun(_ pins: Pins,
                         onPhase: @escaping (DriverInstallPhase) -> Void) -> Result<URL, DownloadProblem> {
        let fm = FileManager.default
        let dest = cacheURL(pins)

        if fm.fileExists(atPath: dest.path) {
            if sha256(of: dest) == pins.sha256 {
                note("缓存命中：\(dest.path)")
                return .success(dest)
            }
            note("缓存 SHA 不符，删掉重下：\(dest.path)")
            try? fm.removeItem(at: dest)      // 上次下坏了，重来
        }
        guard let url = URL(string: pins.url) else {
            return .failure(DownloadProblem(message: "固件包地址无效：\(pins.url)"))
        }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(DownloadProblem(message: "无法创建缓存目录：\(error.localizedDescription)"))
        }

        let part = dest.appendingPathExtension("part")
        // 2026-11-23 用户定案：一次连接失败就静默跳过、丢给脚本那趟没进度的下载，这是错的。
        // 550 MB 归 App 管：重试 3 次（间隔 2s / 5s），三次都不成就停下报错，安装脚本一个字节都不碰。
        let attempts = 3
        var lastError = "未开始"
        for attempt in 1...attempts {
            try? fm.removeItem(at: part)       // 每次从头下（不用续传数据：会话失效后它并不可靠）
            if let error = transfer(url, to: part, onPhase: onPhase) {
                lastError = error
                note("第 \(attempt)/\(attempts) 次失败：\(error)")
                if attempt < attempts {
                    onPhase(.downloadingFirmware(progress: 0, received: 0, total: 0))   // 别停在旧百分比
                    Thread.sleep(forTimeInterval: attempt == 1 ? 2 : 5)
                }
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
            if sha256(of: part) == pins.sha256 {
                try? fm.removeItem(at: dest)
                guard (try? fm.moveItem(at: part, to: dest)) != nil else {
                    note("SHA 一致但挪进缓存失败：\(part.path) → \(dest.path)")
                    return .failure(DownloadProblem(message: "固件包无法存入缓存目录"))
                }
                note("第 \(attempt) 次成功：\(size) 字节，SHA 一致")
                return .success(dest)
            }
            lastError = "下载完成但校验不符（收到 \(size) 字节）"
            note("第 \(attempt)/\(attempts) 次\(lastError)，从头再来")
            try? fm.removeItem(at: part)
        }
        return .failure(DownloadProblem(message: "\(lastError)（已尝试 \(attempts) 次）"))
    }

    /// 一次传输：成功返回 nil，失败返回原因
    private static func transfer(_ url: URL, to part: URL,
                                 onPhase: @escaping (DriverInstallPhase) -> Void) -> String? {
        // 用代理而不是 task.progress：后者在 macOS 上 fractionCompleted 会走，
        // 但 completedUnitCount/totalUnitCount 一直停在 5/100 这种假值（实测），
        // 拿不到「已下载多少 MB / 共多少 MB」。
        let receiver = Receiver(part: part)
        var lastEmit = Date.distantPast
        var lastPercent = -1
        receiver.onProgress = { wrote, expected in
            // 550 MB 会切出上万次回调，全丢主线程会把 UI 卡住 —— 百分比变了（或过了 1 秒）才报
            let total = max(0, expected)      // -1 = 服务器没给长度
            let frac = total > 0 ? min(1, Double(wrote) / Double(total)) : 0
            let percent = Int(frac * 100)
            let due = percent != lastPercent || Date().timeIntervalSince(lastEmit) >= 1
            guard due else { return }
            lastPercent = percent
            lastEmit = Date()
            onPhase(.downloadingFirmware(progress: frac, received: wrote, total: total))
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60          // 只算「两包之间的空档」
        config.timeoutIntervalForResource = 3 * 3600   // 550 MB 慢网也别掐
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
        session.downloadTask(with: url).resume()
        receiver.done.wait()
        session.finishTasksAndInvalidate()
        return receiver.failure
    }

    /// 下载代理：把字节数报出去、把文件挪到 .part、结束时放行
    private final class Receiver: NSObject, URLSessionDownloadDelegate {
        let part: URL
        var onProgress: ((Int64, Int64) -> Void)?
        var failure: String?
        let done = DispatchSemaphore(value: 0)

        init(part: URL) { self.part = part }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
                failure = "HTTP \(code)"; return
            }
            do {
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.moveItem(at: location, to: part)
            } catch { failure = "落盘失败：\(error.localizedDescription)" }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                // 网络中断（-1005 连接丢失 / -1001 超时 / -1009 断网…）带上系统原因与错误码
                let ns = error as NSError
                failure = "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
            }
            done.signal()
        }
    }

    /// 诊断落盘：下载失败的真实原因（系统错误码 / HTTP 码 / 校验结果）记一行，
    /// 免得再出现「知道它跳过了、不知道为什么」这种只能猜的局面
    static func note(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/mc-nvidia-fw.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 550 MB 不进内存：交给系统的 shasum
    static func sha256(of file: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", file.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: " ").first.map { $0.lowercased() }
    }
}

/// 下载自建离线包（LAPQC71-NVIDIA-<tag>-fork.zip），解压后以管理员权限执行其中的 install.command。
///
/// 关键点（全部继承自 Vela-X 的踩坑记录）：
/// · 安装脚本要求 euid == 0，必须整段以 root 运行，而不是在脚本里调 sudo
///   （`do shell script` 没有 TTY，sudo 等不到密码）。
/// · AppleScript 字符串是**双引号**字面量：脚本路径用 `quoted form of "路径"` 让系统负责转义。
/// · 安装要重建内核缓存，可能几分钟。runner 用前台 exec 跑（do shell script 结束时会把
///   同进程组的后台子进程一起收掉），osascript 外套 `with timeout`，App 侧轮询日志回显。
struct DriverInstaller {
    /// 安装日志写在临时目录里，失败时把尾部几行展示出来
    static let logPath = "/tmp/mc-nvidia-install.log"

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
            let work = fm.temporaryDirectory.appendingPathComponent("mc-nvidia-\(tag)")
            try? fm.removeItem(at: work)
            guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil else {
                emit(.failed("无法创建临时目录")); return
            }

            // 1) 下载离线包（走系统代理，Clash 等无需额外配置）
            guard let url = URL(string: NvidiaUpdate.downloadURL(tag: tag)) else {
                emit(.failed("无法构造下载地址")); return
            }
            let archive = work.appendingPathComponent("offline.zip")
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
                    moveError = "下载失败（HTTP \(code)），检查网络或代理，或确认 release 里已上传离线包"
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

            // 2) 解压
            emit(.extracting)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", work.path]
            do {
                try tar.run(); tar.waitUntilExit()
                if tar.terminationStatus != 0 {
                    emit(.failed("解压失败（退出码 \(tar.terminationStatus)）")); return
                }
            } catch {
                emit(.failed("解压出错：\(error.localizedDescription)")); return
            }
            try? fm.removeItem(at: archive)   // 212 MB 的包留着没用

            // 3) 找到 install.command（离线包根目录，多层兜底）
            guard let script = findInstallScript(in: work) else {
                emit(.failed("解压包里没有找到 install.command")); return
            }
            let payload = script.deletingLastPathComponent()
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            // 3.5) 首次安装要先拿到 GPU 固件（约 550 MB）。包内脚本自己 curl 是静默的，
            //      所以由这里带进度下好、校验 SHA-256，再用 NULLMOTH_FW_RUN 交给 install.sh。
            //      已装过（/Library/NullMoth/nvfw 四个文件都在）就什么都不做，脚本会复用。
            var firmwareRun: String?
            if let pins = DriverFirmware.pins(inOfflinePackage: payload) {
                if DriverFirmware.isInstalled(pins) {
                    emitLog("已装的 GPU 固件 \(pins.version) 可复用，跳过 550 MB 下载")
                } else if DriverFirmware.packageCarriesFirmware(inOfflinePackage: payload) {
                    // 这种包里 install.sh 会直接 ditto 自带固件，fw_fetch.sh 根本不会被调用
                    emitLog("离线包自带 GPU 固件，安装脚本会直接使用，无需下载")
                } else {
                    switch DriverFirmware.localRun(pins, onPhase: emit) {
                    case .success(let local):
                        firmwareRun = local.path
                        emitLog("GPU 固件包已就绪（\(pins.version)，SHA-256 已校验）")
                    case .failure(let why):
                        // 2026-11-23 用户定案：重试过还失败就停下来报错，不许悄悄丢给脚本那趟没进度的下载。
                        // 此时安装脚本还没启动、系统一个字节都没改，重试一次不会有副作用。
                        DriverFirmware.note("放弃：\(why)")
                        emitLog("GPU 固件包下载失败：\(why)")
                        emit(.failed("GPU 固件包下载失败：\(why)。系统未做任何改动，联网后重试即可（详情：/tmp/mc-nvidia-fw.log）"))
                        return
                    }
                }
            } else {
                emitLog("没有读到包内 fw_fetch.sh 的固件来源，交给安装脚本自行下载（此段没有进度）")
            }

            // 4) 写 runner：cd 进离线包目录后 exec install.command，输出全部进日志。
            //    用 exec 而不是后台 &：Do shell script 结束时会收掉同进程组子进程，
            //    所以安装必须在前台跑完。
            let logURL = URL(fileURLWithPath: logPath)
            let runner = work.appendingPathComponent("run-install.sh")
            let fwLine = firmwareRun.map { "export NULLMOTH_FW_RUN=\(sh($0))" }
                ?? "# 没有本地固件包：fw_fetch.sh 走自己的下载路径"
            let runnerBody = """
            #!/bin/bash
            export LOG=\(sh(logURL.path))
            \(fwLine)
            cd \(sh(payload.path)) || {
              printf '   STOP: 无法进入安装目录\\n' > "$LOG"
              exit 2
            }
            : > "$LOG"
            printf '== Sky CC：开始安装 %s\\n' "$(date)" >> "$LOG"
            exec /bin/bash ./install.command >> "$LOG" 2>&1
            """
            do {
                try runnerBody.write(to: runner, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
            } catch {
                emit(.failed("无法写入安装脚本：\(error.localizedDescription)")); return
            }

            // 5) 弹管理员授权并执行。AppleScript 外面套 with timeout：
            //    do shell script 默认受 2 分钟 AppleEvent 超时限制（-1712）。
            emit(.authorizing)
            let result = runWithAdminPrivileges(executable: runner.path,
                                                logURL: logURL,
                                                deadline: 30 * 60) { elapsed, line in
                emit(.installing(elapsed: elapsed))
                if let line { emitLog(line) }
            }

            if result.timedOut {
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                copyLog(text)
                emit(.failed("安装超过 30 分钟仍未结束，已中断等待（日志：\(logPath)）"))
                return
            }

            NvidiaUpdate.invalidateKextListCache()
            let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if result.ok {
                copyLog(logText)
                try? fm.removeItem(at: work)
                emit(.succeeded)
            } else {
                copyLog(logText)
                try? fm.removeItem(at: work)
                emit(.failed(failureText(log: logText, osascriptOutput: result.output)))
            }
        }
    }

    /// 在目录（含多层子目录）里找 install.command，找不到再退回 install.sh
    private static func findInstallScript(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.lastPathComponent == "install.command" { return item }
        for item in items where item.lastPathComponent == "install.sh" { return item }
        for item in items where item.hasDirectoryPath {
            if let found = findInstallScript(in: item) { return found }
        }
        return nil
    }

    // MARK: - 一键卸载（执行 NullMoth 自带的 /Library/NullMoth/uninstall.sh）

    /// 卸载官方自带的 uninstall.sh（root 权限）：清掉四个驱动组件与 /Library/NullMoth。
    /// 机制与 install 对称：runner + osascript admin + 日志轮询，只是不下载任何东西。
    static func uninstall(onPhase: @escaping (DriverInstallPhase) -> Void,
                          onLog: @escaping (String) -> Void = { _ in }) {
        let emit: (DriverInstallPhase) -> Void = { p in
            DispatchQueue.main.async { onPhase(p) }
        }
        let emitLog: (String) -> Void = { line in
            DispatchQueue.main.async { onLog(line) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let script = "/Library/NullMoth/uninstall.sh"
            guard fm.fileExists(atPath: script) else {
                emit(.failed("没有找到 \(script)（驱动未安装？）")); return
            }

            let logURL = URL(fileURLWithPath: "/tmp/mc-nvidia-uninstall.log")
            let work = fm.temporaryDirectory.appendingPathComponent("mc-nvidia-uninstall")
            try? fm.removeItem(at: work)
            guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil else {
                emit(.failed("无法创建临时目录")); return
            }
            let runner = work.appendingPathComponent("run-uninstall.sh")
            let runnerBody = """
            #!/bin/bash
            export LOG=\(sh(logURL.path))
            cd /Library/NullMoth || {
              printf '   STOP: 无法进入 /Library/NullMoth\\n' > "$LOG"
              exit 2
            }
            : > "$LOG"
            printf '== Sky CC：开始卸载 %s\\n' "$(date)" >> "$LOG"
            exec /bin/bash ./uninstall.sh >> "$LOG" 2>&1
            """
            do {
                try runnerBody.write(to: runner, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
            } catch {
                emit(.failed("无法写入卸载脚本：\(error.localizedDescription)")); return
            }

            emit(.authorizing)
            let result = runWithAdminPrivileges(executable: runner.path,
                                                logURL: logURL,
                                                deadline: 15 * 60) { elapsed, line in
                emit(.installing(elapsed: elapsed))
                if let line { emitLog(line) }
            }

            NvidiaUpdate.invalidateKextListCache()
            let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if result.timedOut {
                copyLogTo(logText, "/tmp/mc-nvidia-uninstall.log")
                emit(.failed("卸载超过 15 分钟仍未结束，已中断等待（日志：/tmp/mc-nvidia-uninstall.log）"))
            } else if result.ok {
                copyLogTo(logText, "/tmp/mc-nvidia-uninstall.log")
                try? fm.removeItem(at: work)
                emit(.succeeded)
            } else {
                copyLogTo(logText, "/tmp/mc-nvidia-uninstall.log")
                try? fm.removeItem(at: work)
                emit(.failed(failureText(log: logText, osascriptOutput: result.output)))
            }
        }
    }

    private static func copyLogTo(_ text: String, _ path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 日志解析

    /// 安装脚本的 die() 都打 `STOP: ...`
    private static func stopReason(in text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let stop = lines.last(where: { $0.contains("STOP:") }),
              let range = stop.range(of: "STOP:") else { return nil }
        return String(stop[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// 失败原因按可信度排序：用户取消 > 脚本自己的 STOP > 日志最后一行 > osascript 报错
    private static func failureText(log: String, osascriptOutput: String) -> String {
        if isCancelled(osascriptOutput) { return "已取消授权" }
        if let stop = stopReason(in: log) { return stop }
        if let last = lastMeaningfulLine(in: log), !last.hasPrefix("== Sky CC") {
            return "安装中断：\(last)"
        }
        if osascriptOutput.isEmpty {
            return "安装失败（没有更多信息，可查看 \(logPath)）"
        }
        return "安装失败：\(osascriptOutput)"
    }

    private static func isCancelled(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("-128") || lowered.contains("cancel") || lowered.contains("取消")
    }

    private static func lastMeaningfulLine(in text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty && !$0.hasPrefix("EXIT=") })
    }

    private static func copyLog(_ text: String) {
        try? text.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    // MARK: - shell / AppleScript 引号

    /// shell 单引号字面量
    /// AppleScript 字符串转义（网卡页安装脚本同样要用）
    static func sh(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 双引号字面量：只要转义反斜杠和双引号
    private static func applescript(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 以管理员权限执行某个可执行文件；执行期间每 1.2 秒回调一次（已用秒数 + 日志新增的最后一行）。
    /// （2026-11-15 从 private 放开为 internal：网卡驱动页 NetworkInstaller 复用同一套提权/日志轮询机制）
    static func runWithAdminPrivileges(executable path: String,
                                               logURL: URL,
                                               deadline: TimeInterval,
                                               onTick: @escaping (Int, String?) -> Void)
        -> (ok: Bool, timedOut: Bool, output: String) {

        let script = """
        with timeout of 3600 seconds
        \tdo shell script (quoted form of \(applescript(path))) with administrator privileges
        end timeout
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]

        // 用临时文件而不是 Pipe：Pipe 写满缓冲会卡死，且 waitUntilExit 之前读不到内容
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mc-osascript-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            return (false, false, "无法建立临时输出文件")
        }
        p.standardOutput = handle
        p.standardError = handle
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
        }

        do {
            try p.run()
        } catch {
            return (false, false, error.localizedDescription)
        }

        let started = Date()
        var lastLine: String?
        while p.isRunning {
            if Date().timeIntervalSince(started) > deadline {
                p.terminate()
                return (false, true, "")
            }
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let line = lastMeaningfulLine(in: text)
            let elapsed = Int(Date().timeIntervalSince(started))
            if line != lastLine {
                lastLine = line
                onTick(elapsed, line)        // 有新行才回传，避免每 1.2 秒刷一次 UI
            } else {
                onTick(elapsed, nil)
            }
            Thread.sleep(forTimeInterval: 1.2)
        }
        p.waitUntilExit()

        let data = (try? Data(contentsOf: tmp)) ?? Data()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0, false, out)
    }
}
