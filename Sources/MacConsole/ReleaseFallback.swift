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

    /// 拉最新 release 的 JSON dict：先 GitHub，失败（网络 / 超时 / 非 200 / 解析不出）换 Gitee。
    /// 两边都失败回调 dict=nil。completion 在后台线程。
    static func fetchLatest(githubAPI: String,
                            giteeRepo: String,
                            userAgent: String,
                            timeout: TimeInterval = 8,
                            completion: @escaping (_ dict: [String: Any]?, _ source: Source) -> Void) {

        get(githubAPI, userAgent: userAgent, timeout: timeout) { gh in
            if let gh { completion(gh, .github); return }
            get(giteeAPI(giteeRepo), userAgent: userAgent, timeout: timeout) { ge in
                completion(ge, ge != nil ? .gitee : .github)
            }
        }
    }

    /// 解析 release JSON dict（无发布 / 限流时 API 返回 {"message": ...}，没有 tag_name）
    private static func parse(_ data: Data?, _ resp: URLResponse?, _ error: Error?) -> [String: Any]? {
        guard error == nil,
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["tag_name"] as? String)?.isEmpty == false else { return nil }
        return obj
    }

    /// 通用 GET JSON dict（各模块自己编排多源顺序时用）
    static func getDict(_ urlString: String, userAgent: String,
                        timeout: TimeInterval = 8,
                        completion: @escaping ([String: Any]?) -> Void) {
        get(urlString, userAgent: userAgent, timeout: timeout, completion)
    }

    private static func get(_ urlString: String, userAgent: String, timeout: TimeInterval,
                            _ cb: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: urlString) else { cb(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            cb(parse(data, resp, error))
        }.resume()
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
