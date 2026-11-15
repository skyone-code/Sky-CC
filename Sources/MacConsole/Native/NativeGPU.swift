//
//  NativeGPU.swift
//  Sky CC —— GPU 路由开关（默认使用哪块 GPU）
//
//  需求来源（用户原话）：「让 app 能跑在独显上，优先独显或者核显给一个开关就可以
//  （变相的独显直连）」。
//
//  为什么不是改驱动：默认 Metal 设备由 SkyLight/WindowServer 按「显示拥有者」决定，
//  内屏挂在 Intel 上，客户端没有 API 能改。唯一可行的用户态入口是 dyld interpose，
//  所以这里控制的是「往之后启动的进程里注入 gpu-router.dylib」+ 一份策略文件。
//
//  已验证（2026-11-05）：
//   · launchctl setenv 设置的变量确实被子进程继承（最小 app bundle 实测 166 个环境变量）
//   · 注入系统 app 会被 library validation 挡住但不崩溃（TextEdit 存活）
//   · 注入第三方 app 生效，并传播到它派生的 nvram / kmutil 子进程
//
//  **只影响之后启动的 app**：已经在跑的进程，环境变量在它启动时就固定了。
//

import Foundation

enum NativeGPU {

    /// 策略与排除名单的落盘位置（dylib 读同一个文件）
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("MacConsole", isDirectory: true)
    }
    static var policyURL: URL { supportDir.appendingPathComponent("gpu-policy.json") }

    /// 注入用的 dylib 落点，按优先级排列。
    ///
    /// · `/Library/GPUBundles`：**App Sandbox 可读**。系统 profile
    ///   `/System/Library/Sandbox/Profiles/application.sb:80` 是
    ///   `(allow file-read* process-exec (subpath "/Library"))`，只排除
    ///   Preferences / Logs / Caches / Managed Preferences / AppStore* 六个子目录。
    ///   NVMTLDriver.bundle 也在这个位置，WindowServer 这类沙箱进程能正常加载它即为实证。
    /// · `/usr/local/lib`：非沙箱 app 可用（旧路径）。沙箱 app 打开它会被拒，
    ///   崩溃报告原文是 `file system sandbox blocked open()`，dyld 随即 SIGABRT。
    /// · 包内副本：只作拷贝来源。macOS 26 起 LS 启动的进程读不了别的 app 的 bundle 内容。
    ///
    /// 注意：沙箱可读只是第一道闸门。库校验（library validation）是第二道，取决于目标进程的
    /// entitlement，本项目无法控制。2026-11-11 实测：QQ 主程序在 /Library 路径下注入成功、
    /// 不再崩溃（`gpu-router: injected into QQ (com.tencent.qq)`），所以第二道闸门没有拦。
    /// 但别的沙箱 app 未必同样宽松，真遇到 `code signature invalid` 就只能加进 exclude 名单。
    static let sandboxSafeURL = URL(fileURLWithPath: "/Library/GPUBundles/gpu-router.dylib")
    static let legacySystemURL = URL(fileURLWithPath: "/usr/local/lib/gpu-router.dylib")

    /// 系统级落点，前面的优先
    static var systemURLs: [URL] { [sandboxSafeURL, legacySystemURL] }

    /// 包内副本（只作拷贝来源，不作为注入路径）
    static var bundledURL: URL? {
        var v: [URL] = []
        if let r = Bundle.main.resourceURL {
            v.append(r.appendingPathComponent("gpu-router.dylib"))
        }
        // helper 以 Contents/MacOS 里的可执行文件运行，Bundle.main 有时解析到 Contents 本身
        v.append(URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Contents/Resources/gpu-router.dylib"))
        return v.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var dylibCandidates: [URL] {
        systemURLs + [bundledURL].compactMap { $0 }
    }

    static var dylibURL: URL? {
        dylibCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 当前选中的注入路径是否沙箱 app 可读（决定 QQ / 微信能否被注入）
    static var sandboxVisible: Bool {
        FileManager.default.fileExists(atPath: sandboxSafeURL.path)
    }

    /// 把包内 dylib 装到系统路径：优先 /Library/GPUBundles（root 权限，通常由安装器完成），
    /// 退而写 /usr/local/lib（admin 组可写）。两处内容过期都会覆盖。
    static func ensureSystemDylib() -> String? {
        let fm = FileManager.default
        guard let src = bundledURL else {
            // 没有包内副本：系统上只要有一份能用的就算成功
            if systemURLs.contains(where: { fm.fileExists(atPath: $0.path) }) { return nil }
            return "找不到 gpu-router.dylib（系统路径与 app 包内都没有）"
        }
        let srcData = try? Data(contentsOf: src)
        var installed: [String] = []
        var failures: [String] = []
        for dst in systemURLs {
            let dir = dst.deletingLastPathComponent()
            if let d = try? Data(contentsOf: dst), let s = srcData, d == s {
                installed.append(dst.path)          // 已是最新
                continue
            }
            // 目录不可写就别硬试：/Library/GPUBundles 是 root:wheel 755
            guard fm.isWritableFile(atPath: dir.path) else {
                if fm.fileExists(atPath: dst.path) { installed.append(dst.path) }
                failures.append("\(dir.path) 需要 root 权限")
                continue
            }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
                installed.append(dst.path)
            } catch {
                failures.append("\(dst.path): \(error.localizedDescription)")
            }
        }
        guard !installed.isEmpty else {
            return "安装 dylib 失败：" + failures.joined(separator: "；")
        }
        return nil
    }

    // MARK: - 策略文件

    static func readPolicy() -> [String: Any] {
        guard let d = try? Data(contentsOf: policyURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return ["mode": "dgpu", "exclude": [String]()] }
        var out = j
        if out["mode"] as? String == nil { out["mode"] = "dgpu" }
        if out["exclude"] as? [String] == nil { out["exclude"] = [String]() }
        return out
    }

    @discardableResult
    static func writePolicy(_ p: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: supportDir,
                                                    withIntermediateDirectories: true)
            let d = try JSONSerialization.data(withJSONObject: p,
                                               options: [.prettyPrinted, .sortedKeys])
            try d.write(to: policyURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func excludeList() -> [String] {
        (readPolicy()["exclude"] as? [String]) ?? []
    }

    // MARK: - launchd 环境变量

    /// 读当前 GUI 域里 DYLD_INSERT_LIBRARIES 的值。
    /// 走 `/bin/launchctl getenv` 子进程而不是私有 API：helper 是 LaunchAgent，
    /// 子和父同域，读写的是同一个 gui/<uid> domain。
    static func injectedValue() -> String? {
        let (out, ok) = NativeProc.runCapture("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"])
        guard ok else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 解析符号链接后的真实路径。
    /// /usr/local/lib 那份可能是指向 /Library/GPUBundles 的软链（2026-11-11 起），
    /// 光比字符串会把这种情况误判成「未注入」，所以两边都规范化后再比。
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func isInjected() -> Bool {
        guard let v = injectedValue() else { return false }
        let want = canonical(v)
        for cand in dylibCandidates where canonical(cand.path) == want { return true }
        return false
    }

    // MARK: - 开关

    /// mode: "dgpu" 开启（注入 + 策略=dgpu）/ "off" 关闭（unsetenv）
    static func setMode(_ mode: String) -> [String: Any] {
        if mode == "off" {
            let (_, ok) = NativeProc.runCapture("/bin/launchctl",
                                                ["unsetenv", "DYLD_INSERT_LIBRARIES"])
            guard ok else { return ["ok": false, "error": "launchctl unsetenv 失败"] }
            return ["ok": true, "mode": "off", "note": "之后启动的 app 回到 Apple 默认（核显）"]
        }

        guard mode == "dgpu" else { return ["ok": false, "error": "未知模式: \(mode)"] }

        // dylib 要落在系统路径：/Library/GPUBundles（沙箱 app 可读，需 root）
        // 或 /usr/local/lib（旧路径，沙箱 app 读不到）。缺失/过期就从包内拷贝过去
        if let err = ensureSystemDylib() {
            return ["ok": false, "error": err]
        }
        guard let dylib = dylibURL else {
            return ["ok": false,
                    "error": "找不到 gpu-router.dylib（应随 app 打包在 Contents/Resources）"]
        }

        // 策略先落盘，再注入：反过来的话，先启动的 app 会读到旧策略
        var p = readPolicy()
        p["mode"] = "dgpu"
        _ = writePolicy(p)

        let (out, ok) = NativeProc.runCapture("/bin/launchctl",
                                              ["setenv", "DYLD_INSERT_LIBRARIES", dylib.path])
        guard ok else {
            return ["ok": false, "error": "launchctl setenv 失败: \(out)"]
        }
        var note = "之后启动的 app 默认使用独显；已在运行的 app 需重启才生效"
        if !sandboxVisible {
            note += "；注入路径 \(dylib.path) 对沙箱 app 不可读（会 dyld 崩溃），"
                + "把 dylib 放到 \(sandboxSafeURL.path) 才对沙箱 app 可见"
        }
        return ["ok": true, "mode": "dgpu", "dylib": dylib.path,
                "sandboxVisible": sandboxVisible, "note": note]
    }

    /// 加/删 per-app 例外（名单里的 app 仍用核显）
    static func setExclude(_ bundleID: String, on: Bool) -> [String: Any] {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return ["ok": false, "error": "bundle id 为空"] }
        guard !id.hasPrefix("com.apple.") else {
            return ["ok": false, "error": "系统 app 本来就不会被接管，无需加入"]
        }
        var p = readPolicy()
        var ex = (p["exclude"] as? [String]) ?? []
        if on {
            if !ex.contains(id) { ex.append(id) }
        } else {
            ex.removeAll { $0 == id }
        }
        p["exclude"] = ex.sorted()
        guard writePolicy(p) else { return ["ok": false, "error": "写入策略文件失败"] }
        return ["ok": true, "exclude": p["exclude"] as? [String] ?? []]
    }

    /// 当前前台 GUI app 的 bundle id（方便一键加入例外）
    static func frontAppBundleID() -> String? {
        let script = "tell application \"System Events\" to get bundle identifier of first "
            + "application process whose frontmost is true"
        let (out, ok) = NativeProc.runCapture("/usr/bin/osascript", ["-e", script])
        guard ok else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - 状态

    static func state() -> [String: Any] {
        let p = readPolicy()
        let inj = injectedValue()
        let dylib = dylibURL
        var out: [String: Any] = [
            "mode": p["mode"] as? String ?? "dgpu",
            "injected": inj != nil,
            "injectedValue": inj ?? "",
            "dylib": dylib?.path ?? "",
            "dylibPresent": dylib != nil,
            // 沙箱 app（QQ/微信这类）能否读到注入的 dylib：只有 /Library 下的副本可以
            "sandboxVisible": sandboxVisible,
            "sandboxSafePath": sandboxSafeURL.path,
            "exclude": p["exclude"] as? [String] ?? [],
            "policyPath": policyURL.path,
            // 说明性字段，UI 直接展示，避免前端再拼字符串
            "effective": (inj != nil) ? "dGPU 优先" : "系统默认（核显）",
        ]
        if let f = frontAppBundleID() { out["frontApp"] = f }
        out["ok"] = true
        return out
    }
}
