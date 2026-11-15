import Foundation

/// 主 app（UI/HTTP）与后台 helper 之间的 XPC 契约。
///
/// 设计要点：**不按功能拆方法**，只保留一对 get/post，参数就是现有 HTTP 的
/// path + params。原因：`NativeAPI.handleGet/handlePost` 已经把全部动作收敛成
/// 「path + params → 字典」，照搬即可；新增接口不用改协议、不用两边同步签名，
/// 排查时也能用 curl 直接对照同一条 path 的返回。
///
/// 值域限制：跨进程只能传 NSSecureCoding 类型（NSDictionary / NSArray /
/// NSString / NSNumber / NSNull / NSData / NSDate）。本项目的数据结构恰好都是
/// 这几种，所以不用转 JSON，省一次编解码。

/// Mach service 名，必须与 LaunchAgent plist 里 MachServices 的键一致。
let mcHelperServiceName = "com.macconsole.helper"

/// 随包 LaunchAgent 的文件名（位于 App/Contents/Library/LaunchAgents/）。
let mcHelperAgentPlist = "com.macconsole.helper.plist"

/// 返回统一包成 `["ok": Bool, "data": Any, "error": String]`：
/// - 成功：`ok=true`，`data` 是原来 HTTP body 里那个对象（字典或数组）
/// - 失败：`ok=false`，`error` 是人可读原因
/// 这样客户端只有一种返回类型，XPC 侧也不用处理可选类型。
@objc(MCHelperProtocol)
protocol MCHelperProtocol {
    /// 等价于 GET /api/xxx
    func mcGet(_ path: String, reply: @escaping ([String: Any]) -> Void)
    /// 等价于 POST /api/xxx，body 即 params
    func mcPost(_ path: String, params: [String: Any],
                reply: @escaping ([String: Any]) -> Void)
    /// 健康检查：版本 / pid / kext 状态 / 曲线是否在跑
    func mcPing(_ reply: @escaping ([String: Any]) -> Void)
}
