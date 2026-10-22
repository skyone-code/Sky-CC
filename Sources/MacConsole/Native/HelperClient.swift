import Foundation

/// app 侧的 XPC 客户端：把「HTTP 请求」换成「对 helper 的进程间调用」。
///
/// 对外只暴露 `call(path:params:)`，返回值与原 HTTP body 同构，所以
/// `BackendService.getJSON/postJSON` 只要换内部实现，上层（MonitorStore、
/// 各个 View、AllDataView）一行都不用改。
///
/// 连接策略：
///   * 懒建 + 复用一条 NSXPCConnection（XPC 连接本身很便宜，但每次重建要重新
///     握手，2 秒轮询下没必要）；
///   * `invalidationHandler` 里清空缓存引用，下次调用自动重连 —— helper 被
///     launchd 重启（升级/崩溃）后无需 app 干预；
///   * 每次调用带超时。XPC 在没有 helper 时不会「挂住」，但 helper 卡在 EC 上
///     时 reply 可能很晚才来，超时兜底让 UI 至少能显示「离线」而不是转圈。
final class HelperClient {

    static let shared = HelperClient()
    private init() {}

    private let lock = NSLock()
    private var conn: NSXPCConnection?

    /// 最近一次失败原因，供 UI 显示（不参与逻辑判断）
    private(set) var lastError: String?

    private func diag(_ s: String) {
        let line = "[\(Date())] [xpc] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/macconsole-swift.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: 连接

    private func connection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let c = conn { return c }

        let c = NSXPCConnection(machServiceName: mcHelperServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: MCHelperProtocol.self)
        // 断线（helper 崩溃/被 launchd 重启）→ 丢弃连接，下次调用重连
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.conn = nil
            self.lock.unlock()
            self.diag("连接失效，下次调用将重连")
        }
        c.interruptionHandler = { [weak self] in
            self?.diag("连接被中断（helper 可能正在重启）")
        }
        c.resume()
        conn = c
        diag("建立连接 \(mcHelperServiceName)")
        return c
    }

    /// 主动丢弃连接（helper 主动退出/升级后调用，避免拿到半死连接）
    func reset() {
        lock.lock()
        let old = conn
        conn = nil
        lock.unlock()
        old?.invalidate()
    }

    // MARK: 调用

    /// 一次性完成的「只答复一次」盒子：XPC 的 errorHandler 与 reply 有可能
    /// 都触发（同一请求先报错再回包），continuation 重复 resume 会直接崩。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var timer: Task<Void, Never>?
        private let cont: CheckedContinuation<[String: Any], Never>

        init(_ c: CheckedContinuation<[String: Any], Never>) { cont = c }

        func setTimer(_ t: Task<Void, Never>) {
            lock.lock()
            if done { lock.unlock(); t.cancel(); return }
            timer = t
            lock.unlock()
        }

        func finish(_ v: [String: Any]) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let t = timer
            timer = nil
            lock.unlock()
            t?.cancel()
            cont.resume(returning: v)
        }
    }

    /// 统一返回 `["ok": Bool, "data": Any, "error": String]`
    func call(_ path: String, params: [String: Any]? = nil,
              timeout: TimeInterval = 20) async -> [String: Any] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            let box = Once(cont)
            let t = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                box.finish(["ok": false, "error": "helper 超时 \(Int(timeout))s（\(path)）"])
            }
            box.setTimer(t)

            let c = self.connection()
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ err in
                let msg = err.localizedDescription
                box.finish(["ok": false, "error": "xpc 失败：\(msg)"])
            }) as? MCHelperProtocol else {
                box.finish(["ok": false, "error": "无法创建 XPC 代理"])
                return
            }
            if let params {
                proxy.mcPost(path, params: params) { box.finish($0) }
            } else {
                proxy.mcGet(path) { box.finish($0) }
            }
        }
    }

    /// GET，返回 data 段（与原 HTTP body 同构：字典或数组）
    func get(_ path: String, timeout: TimeInterval = 20) async -> Any? {
        let r = await call(path, params: nil, timeout: timeout)
        if r["ok"] as? Bool == true { return r["data"] }
        lastError = r["error"] as? String
        return nil
    }

    /// POST，返回 data 段。传输层失败时带 `_xpc_error: true` 标记，
    /// 好让上层区分「helper 连不上」和「业务拒绝」（比如 level 越界）。
    func post(_ path: String, _ params: [String: Any] = [:],
              timeout: TimeInterval = 30) async -> [String: Any] {
        let r = await call(path, params: params, timeout: timeout)
        if r["ok"] as? Bool == true {
            return (r["data"] as? [String: Any]) ?? [:]
        }
        let msg = r["error"] as? String ?? "unknown"
        lastError = msg
        return ["ok": false, "error": msg, "_xpc_error": true]
    }

    /// 健康检查（短超时，用于 UI 显示在线状态 / 版本握手）
    func health(timeout: TimeInterval = 2) async -> [String: Any] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            let box = Once(cont)
            let t = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                box.finish(["ok": false, "error": "ping 超时"])
            }
            box.setTimer(t)
            let c = self.connection()
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ err in
                box.finish(["ok": false, "error": err.localizedDescription])
            }) as? MCHelperProtocol else {
                box.finish(["ok": false, "error": "无法创建 XPC 代理"])
                return
            }
            proxy.mcPing { box.finish($0) }
        }
    }

}
