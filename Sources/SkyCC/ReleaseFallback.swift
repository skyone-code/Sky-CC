import Foundation

// ============================================================================
// 更新源双通道兜底（2026-11-15 用户要求）
//
// GitHub 在国内大多数时候不通，三个检查更新（App 自更新 / NVIDIA 驱动 / 网卡驱动）
// 都要有兜底：GitHub 拉不到 → 换 Gitee 镜像仓（tag 与 GitHub 保持一致）。
//
// Gitee API v5 与 GitHub 基本兼容（tag_name / name / body / assets[].browser_download_url），
// 两点差异在本模块做归一化处理：
//   · assets 里没有 size 字段 → 缺 size 时按 0 处理（调用方决定是否显示大小）；
//   · release tag 不带 v 前缀（GitHub 是 v3.0.5，Gitee 是 3.0.5）→ 调用方统一 trim。
// ============================================================================

enum ReleaseFallback {

    enum Source: String {
        case github, gitee
        var label: String { self == .github ? "GitHub" : "Gitee" }
    }

    static let giteeOwner = "skyone021396"

    /// Gitee releases/latest 的 API 地址
    static func giteeAPI(_ repo: String) -> String {
        "https://gitee.com/api/v5/repos/\(giteeOwner)/\(repo)/releases/latest"
    }

    // MARK: - 静态 latest.json 通道（2026-11-17 新增，最优先）
    //
    // 为什么加：两条 API 通道都可能整体不可用 ——
    //   · GitHub 匿名 API 未登录配额 60 次/小时/出口 IP，共享出口下容易 403；
    //   · Gitee 未认证 API 按出口 IP 限流，实测连公开仓都返回 403 Rate Limit Exceeded。
    // 结果就是「检查更新」永远失败，日志里只有一句 404。
    // 对策：仓库 main 分支放一个 latest.json，走 raw 直链（不是 API，不受限流），
    // 拿到 {tag, pkg_url, size, sha256} 后归一化成 GitHub release 同形状，调用方无感。
    // 文件维护：每次发版把 tag/pkg_url/size/sha256 改成新包的（sha256 用 shasum -a 256 取）。
    static let staticLatestURL = "https://gitee.com/skyone021396/Sky-CC/raw/main/latest.json"

    /// latest.json → GitHub release 同形状（tag_name / assets[]），AppUpdater 不用改解析。
    /// 2026-11-18：优先取 dmg_url（自研安装器），没有才回落 pkg_url。
    static func normalizeStatic(_ obj: [String: Any]) -> [String: Any]? {
        let rawTag = (obj["tag"] as? String) ?? (obj["version"] as? String)
        guard let tag = rawTag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { return nil }
        let dmgURL = (obj["dmg_url"] as? String) ?? ""
        let pkgURL = (obj["pkg_url"] as? String) ?? ""
        let useDMG = !dmgURL.isEmpty
        let url = useDMG ? dmgURL : pkgURL
        guard !url.isEmpty else { return nil }
        let name = useDMG
            ? ((obj["dmg_name"] as? String) ?? "Sky CC-\(tag)-LAPQC71x.dmg")
            : ((obj["pkg_name"] as? String) ?? "SkyCC-\(tag).pkg")
        var asset: [String: Any] = [
            "name": name,
            "browser_download_url": url,
        ]
        if let n = obj["size"] as? NSNumber { asset["size"] = n.intValue }
        var dict: [String: Any] = ["tag_name": tag, "assets": [asset]]
        if let notes = obj["notes"] as? String { dict["body"] = notes }
        return dict
    }

    // MARK: - 302 直读 tag（2026-11-17 新增，0 API 配额）
    //
    // 为什么加：NVIDIA / 网卡驱动两页原先每次「检查更新」都要打一次 API
    // （GitHub 不通用 Gitee API 兜底），未认证按出口 IP 限流，点几下就 403。
    // 其实两家都支持 `releases/latest` 的 **302 跳转**，Location 末尾就是 tag ——
    // 拦住跳转、不读正文，一个字节 API 配额都不吃，也不要求仓库里放 latest.json。
    // 现在两页都是「302 拿 tag → tag 没变就不查 API」。
    private final class TagCatcher: NSObject, URLSessionTaskDelegate {
        var location: String?
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            location = request.url?.absoluteString
            completionHandler(nil)
        }
    }

    /// 从 ".../releases/tag/v3.0.7" 里取出 "3.0.7"（去掉 v 前缀与查询串）
    static func tagValue(from urlString: String?) -> String? {
        guard let urlString, let range = urlString.range(of: "/releases/tag/") else { return nil }
        var tag = String(urlString[range.upperBound...])
        if let q = tag.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            tag = String(tag[..<q])
        }
        if tag.hasPrefix("v") { tag.removeFirst() }
        return tag.isEmpty ? nil : tag
    }

    /// 打 `.../releases/latest`，只取 302 的 Location（或最终落地页）里的 tag。
    /// 不读正文、不碰 API；拿不到回调 nil（调用方再去试下一个源）。
    static func latestTag(from urlString: String,
                          userAgent: String,
                          timeout: TimeInterval = 8,
                          completion: @escaping (String?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let catcher = TagCatcher()
        let session = URLSession(configuration: .default, delegate: catcher, delegateQueue: nil)
        session.dataTask(with: req) { _, response, _ in
            defer { session.finishTasksAndInvalidate() }
            if let t = tagValue(from: catcher.location) { completion(t); return }
            // 某些网络下不跳转，最终 URL 本身就是 tag 页
            if let t = tagValue(from: response?.url?.absoluteString) { completion(t); return }
            completion(nil)
        }.resume()
    }

    /// 拉最新 release 的 JSON dict：静态 latest.json → GitHub → Gitee API。
    /// allowAPI = false 时只打静态文件一枪（启动静默检查用，避免每次开机都轰 Gitee / 吃 404）。
    /// 全部失败回调 dict=nil。completion 在后台线程。
    static func fetchLatest(githubAPI: String,
                            giteeRepo: String,
                            userAgent: String,
                            timeout: TimeInterval = 8,
                            staticJSON: String? = nil,
                            allowAPI: Bool = true,
                            completion: @escaping (_ dict: [String: Any]?, _ source: Source) -> Void) {

        // 两条 API 兜底（原逻辑，顺序不动）
        func viaAPI() {
            guard allowAPI else { completion(nil, .gitee); return }
            get(githubAPI, userAgent: userAgent, timeout: timeout) { gh in
                if let gh { completion(gh, .github); return }
                get(giteeAPI(giteeRepo), userAgent: userAgent, timeout: timeout) { ge in
                    completion(ge, ge != nil ? .gitee : .github)
                }
            }
        }

        guard let staticJSON else { viaAPI(); return }
        getRaw(staticJSON, userAgent: userAgent, timeout: timeout) { obj in
            if let obj, let dict = normalizeStatic(obj) {
                completion(dict, .gitee)   // 静态文件挂在 Gitee 仓里，源标签按 Gitee 记
                return
            }
            viaAPI()
        }
    }

    /// 解析 JSON 响应（只要 200 + 合法 JSON 对象；字段校验交给调用方）
    private static func parse(_ data: Data?, _ resp: URLResponse?, _ error: Error?) -> [String: Any]? {
        guard error == nil,
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// 通用 GET JSON dict（各模块自己编排多源顺序时用）
    static func getDict(_ urlString: String, userAgent: String,
                        timeout: TimeInterval = 8,
                        completion: @escaping ([String: Any]?) -> Void) {
        get(urlString, userAgent: userAgent, timeout: timeout, completion)
    }

    /// 原始 GET：只要 200 + JSON 对象就返回（latest.json 没有 tag_name，不能用 get）
    private static func getRaw(_ urlString: String, userAgent: String, timeout: TimeInterval,
                               _ cb: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: urlString) else { cb(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            cb(parse(data, resp, error))
        }.resume()
    }

    /// GitHub / Gitee 的 release GET：额外要求 tag_name 非空（无发布 / 限流时 API 只回 {"message": ...}）
    private static func get(_ urlString: String, userAgent: String, timeout: TimeInterval,
                            _ cb: @escaping ([String: Any]?) -> Void) {
        getRaw(urlString, userAgent: userAgent, timeout: timeout) { obj in
            guard let obj, (obj["tag_name"] as? String)?.isEmpty == false else { cb(nil); return }
            cb(obj)
        }
    }

    /// 从 release dict 的 assets 里按资产名精确找下载地址
    /// （Gitee 的 assets 还混着 source archive，按名字排除）
    static func assetURL(in dict: [String: Any], named assetName: String) -> String? {
        for a in (dict["assets"] as? [[String: Any]]) ?? [] {
            guard (a["name"] as? String) == assetName,
                  let u = a["browser_download_url"] as? String, !u.isEmpty else { continue }
            return u
        }
        return nil
    }
}
