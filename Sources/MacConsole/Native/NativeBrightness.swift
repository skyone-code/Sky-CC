//
//  NativeBrightness.swift
//  Mac控制台 —— 屏幕亮度控制（原生移植）
//
//  对应 Python 版 python后端/bright.py + server.py 的 PWMWAKE_V5 段。
//
//  走 IOKit 公开显示参数接口：
//    IODisplayGetFloatParameter / IODisplaySetFloatParameter
//    参数名 kIODisplayBrightnessKey = "brightness"，取值 0.0 ~ 1.0。
//
//  遍历所有显示器（IODisplayConnect + IODisplay 两类都枚举，独显驱动加载后
//  显示栈会多出节点，单一类匹配会漏）。
//
//  PWM 模式兜底（PWMWAKE_V5）：面板默认处于 AUX 背光模式时不接受 PWM 引脚
//  输出，写系统亮度前先确保面板在 PWM 模式（委托 pwmwake / auxbright 二进制，
//  带 1.5s 节流）。
//

import Foundation
import IOKit
import IOKit.graphics    // IODisplayGet/SetFloatParameter 在 graphics 子模块

enum NativeBrightness {

    private static let kIOMasterPortDefault: mach_port_t = 0
    private static let brightnessKey = "brightness" as CFString

    /// 所有可调亮度显示节点的 io_object_t 列表
    private static func displayServices() -> [io_service_t] {
        var out: [io_service_t] = []
        for cls in ["IODisplayConnect", "IODisplay"] {
            guard let matching = IOServiceMatching(cls) else { continue }
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) == KERN_SUCCESS,
                  iter != 0 else { continue }
            while true {
                let svc = IOIteratorNext(iter)
                if svc == 0 { break }
                out.append(svc)
            }
            IOObjectRelease(iter)
        }
        return out
    }

    static func displayCount() -> Int { displayServices().count }

    /// 返回 {ok, percent, raw, displays}（与 Python get_brightness 一致）
    static func get() -> [String: Any] {
        var vals: [Float] = []
        let svcs = displayServices()
        defer { svcs.forEach { IOObjectRelease($0) } }
        for svc in svcs {
            var v: Float = 0
            if IODisplayGetFloatParameter(svc, 0, brightnessKey, &v) == KERN_SUCCESS {
                vals.append(v)
            }
        }
        guard !vals.isEmpty else {
            return ["ok": false, "error": "没有可通过 IOKit 调亮度的显示器"]
        }
        let pct = max(0, min(100, (vals.reduce(0, +) / Float(vals.count)) * 100))
        let rounded = (Double(pct) * 10).rounded() / 10
        return ["ok": true, "percent": rounded,
                "raw": Int((rounded / 100 * 255).rounded()), "displays": vals.count]
    }

    /// 设亮度，percent = 0..100。返回 {ok, percent, applied, total}
    static func set(_ percent: Double) -> [String: Any] {
        ensurePWMMode()
        let pct = max(0, min(100, percent))
        var applied = 0
        let svcs = displayServices()
        defer { svcs.forEach { IOObjectRelease($0) } }
        for svc in svcs {
            if IODisplaySetFloatParameter(svc, 0, brightnessKey, Float(pct / 100)) == KERN_SUCCESS {
                applied += 1
            }
        }
        if applied == 0 {
            return ["ok": false, "error": "显示器拒绝了亮度写入（外接屏常见）", "total": svcs.count]
        }
        return ["ok": true, "percent": pct, "applied": applied, "total": svcs.count]
    }

    // MARK: - PWMWAKE_V5：面板 PWM 模式兜底

    private static var lastEnsure: Double = 0
    private static let ensureLock = NSLock()

    /// 找 pwmwake / auxbright 二进制（候选顺序与 Python 版一致；
    /// 2.5.0 起随包路径迁到 native/bin/，旧 python/bin/ 作升级过渡兜底）
    static func pwmTool() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("bin/pwmwake"),
            URL(fileURLWithPath: "/usr/local/bin/pwmwake"),
            Bundle.main.resourceURL?.appendingPathComponent("native/bin/pwmwake"),
            Bundle.main.resourceURL?.appendingPathComponent("python/bin/pwmwake"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("bin/auxbright"),
        ].compactMap { $0 }
        for u in candidates where FileManager.default.isExecutableFile(atPath: u.path) {
            return u
        }
        return nil
    }

    static func auxbrightTool() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("bin/auxbright"),
            URL(fileURLWithPath: "/usr/local/bin/auxbright"),
            Bundle.main.resourceURL?.appendingPathComponent("native/bin/auxbright"),
            Bundle.main.resourceURL?.appendingPathComponent("python/bin/auxbright"),
        ].compactMap { $0 }
        for u in candidates where FileManager.default.isExecutableFile(atPath: u.path) {
            return u
        }
        return nil
    }

    /// 确保面板在 PWM 模式；返回 'pwmwake'/'auxbright'/nil（1.5s 内不重复）
    @discardableResult
    static func ensurePWMMode(minInterval: Double = 1.5) -> String? {
        ensureLock.lock()
        defer { ensureLock.unlock() }
        let now = Date().timeIntervalSince1970
        if now - lastEnsure < minInterval { return nil }
        lastEnsure = now
        if let tool = pwmTool(), run(tool, args: ["ensure"]) {
            return "pwmwake"
        }
        if let tool = auxbrightTool(), run(tool, args: ["pwm"]) {
            return "auxbright"
        }
        return nil
    }

    /// 读面板背光模式；成功返回 'PWM'/'AUX(DPCD)' 等，失败返回 nil
    static func panelBLMode() -> String? {
        guard let tool = auxbrightTool() else { return nil }
        guard let out = runCapture(tool, args: ["mode"], timeout: 6) else { return nil }
        for line in out.split(separator: "\n") {
            if line.contains("0x721") {
                let s = String(line)
                if let range = s.range(of: "(") {
                    return String(s[range.upperBound...]).replacingOccurrences(of: ")", with: "")
                }
                return s
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 子进程小工具（统一走 NativeProc：硬超时 + 信号升级，
    //          绝不在 waitUntilExit 上无界等待——面板断电时 mode 读取会卡死，
    //          无界等待会把 HTTP 服务线程永久挂死）

    @discardableResult
    static func run(_ url: URL, args: [String], timeout: TimeInterval = 6) -> Bool {
        NativeProc.runCapture(url.path, args, timeout: timeout).ok
    }

    static func runCapture(_ url: URL, args: [String], timeout: TimeInterval = 6) -> String? {
        let r = NativeProc.runCapture(url.path, args, timeout: timeout)
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
