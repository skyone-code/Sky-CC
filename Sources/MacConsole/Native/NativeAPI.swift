//
//  NativeAPI.swift
//  Mac控制台 —— 本地后端 API 层（原生移植）
//
//  对应 Python 版 python后端/server.py 的全部接口逻辑。JSON 输出形状与
//  Python 版逐字段一致（前端 web UI 与 SwiftUI 都按原形状解析）。
//
//  覆盖：
//    GET  /api/overview /api/sensors /api/battery /api/disks /api/processes
//         /api/hid /api/rgb /api/fan /api/lightbar /api/capability /api/all
//    POST /api/control /api/fan /api/lightbar /api/rgb
//         /api/rgb/apply /api/rgb/forget /api/rgb/save
//         /api/rgb/whitecal /api/rgb/whitegain /api/rgb/whitegain/reset
//

import Foundation
import IOKit
import CoreAudio

// MARK: - API 入口

// MARK: - EC 结果短 TTL 缓存
//
// 为什么必须有：EC 走同方 WMI 邮箱，单次读 ~65ms 且是全局单例资源。
// 一次 /api/fan 要读 17 个寄存器 ≈ 1.1s（10 个 fanStatus + 6 个 misc +
// 1 个充电阈值），而 UI 侧 MetricsHub（1s 循环）与 MonitorStore（2s 循环）
// 会重复请求同一个接口 —— 需求约 21 次/秒 > EC 物理上限约 15 次/秒，
// 通道长期过载，每个请求都在排队 + 退避重试（实测 kext 2.0.2 + 2.5.3.1：
// /api/fan 依次 4.8s → 8.8s → 12.6s，越来越慢）。
// 加缓存后同一 TTL 窗口内所有调用共享一次 EC 扫描，占用降到 ~30%。
//
// TTL 依据：风扇转速 / PWM / 温度变化慢 → 1.6s；misc 开关与充电阈值只
// 在用户操作时变 → 长 TTL，并且 POST 写操作会清空缓存，保证「改完立刻
// GET 能看到新值」。
private final class FanAPICache: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (at: Date, value: Any)] = [:]

    func get(_ key: String, _ ttl: TimeInterval) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.value
    }

    func put(_ key: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        store[key] = (Date(), value)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

/// 读一个 Float32 型 CoreAudio 设备属性（音量标量）。
/// 注意：SDK 里没有 kAudioHardwareServiceDeviceProperty_VirtualMainVolume
/// （那是 AudioHardwareService 的私有头），所以统一走 kAudioDevicePropertyVolumeScalar，
/// 依次尝试 master(0) → 通道 1 → 通道 2 → 1&2 平均。
private func audioVolumeScalar(_ dev: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: element)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

/// 读静音位（UInt32），同样 master → 通道 1 兜底。
private func audioMuted(_ dev: AudioDeviceID) -> Bool {
    for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
            return v != 0
        }
    }
    return false
}

/// 默认输出设备的音量/静音（CoreAudio，微秒级、无子进程）。
/// 返回 nil 表示拿不到（无默认输出设备），调用方应退回 osascript。
private func systemVolume() -> (volume: Int, muted: Bool)? {
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var devAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devAddr,
                                     0, nil, &size, &dev) == noErr,
          dev != kAudioObjectUnknown else { return nil }

    var scalar: Float32?
    for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
        if let v = audioVolumeScalar(dev, element: element) { scalar = v; break }
    }
    if scalar == nil {
        let a = audioVolumeScalar(dev, element: 1)
        let b = audioVolumeScalar(dev, element: 2)
        if let a, let b { scalar = (a + b) / 2 }
    }
    guard let s = scalar else { return nil }
    return (Int((s * 100).rounded()), audioMuted(dev))
}

enum NativeAPI {

    // MARK: GET

    static func handleGet(_ path: String) -> Any? {
        switch path {
        case "/api/overview":   return NativeSystem.overview()
        case "/api/sensors":    return SMCSnapshot.snapshot()
        case "/api/battery":    return NativeSystem.battery()
        case "/api/disks":      return NativeSystem.disks()
        case "/api/processes":  return NativeSystem.processes()
        case "/api/hid":        return NativeSystem.hidDevices()
        case "/api/rgb":        return rgbState()
        case "/api/fan":        return fanState()
        case "/api/lightbar":   return lightbarState()
        case "/api/capability": return capability()
        case "/api/all":        return allPayload(slim: false)
        case "/api/snapshot":   return allPayload(slim: true)
        default:
            return nil
        }
    }

    /// 全量快照（2.7.0 起统一入口）
    ///
    /// `/api/all`   = 全部字段（含 rgb / lightbar / hid / capability，给「全部信息」页）
    /// `/api/snapshot` = 高频精简版（去掉 GPU 原始统计与 HID/能力矩阵，给 1 秒轮询）
    ///
    /// 两个都包含 fan（走后台采样器的热缓存，不触发 EC 冷扫描），所以 UI 一次
    /// XPC 就能拿到所有卡片要的字段，不再并发打 5 个接口。
    private static func allPayload(slim: Bool) -> [String: Any] {
        let t0 = Date()
        var payload: [String: Any] = [:]
        payload["overview"] = NativeSystem.overview(slim: slim)
        payload["sensors"] = SMCSnapshot.snapshot()
        payload["battery"] = NativeSystem.battery()
        payload["disks"] = NativeSystem.disks()
        payload["processes"] = NativeSystem.processes(limit: slim ? 15 : 40)
        payload["fan"] = fanState()
        payload["volume"] = volumeState()
        payload["elapsed_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        if !slim {
            payload["rgb"] = rgbState()
            payload["lightbar"] = lightbarState()
            payload["hid"] = NativeSystem.hidDevices()
            payload["capability"] = capability()
        }
        return payload
    }

    /// 音量状态（CoreAudio 原生，微秒级）。不在这里兜底 osascript——
    /// 1 秒轮询的接口不允许出现 0.4–0.9s 的慢分支。
    static func volumeState() -> [String: Any] {
        if let s = systemVolume() {
            return ["ok": true, "volume": s.volume, "muted": s.muted, "via": "coreaudio"]
        }
        return ["ok": false, "volume": NSNull(), "muted": NSNull(), "via": "unavailable"]
    }

    // MARK: POST

    static func handlePost(_ path: String, _ params: [String: Any]) -> Any? {
        // 写操作可能改 EC 状态（风扇模式/档位/misc 开关/充电阈值）→ 清缓存，
        // 避免紧接着的 GET 读到旧值。
        //
        // 但只读动作必须排除：MonitorStore 每 2 秒就 POST 一次 volume_get，
        // 若无差别清空，/api/fan 会一直退化成冷扫描（17 次 EC 读 ≈1.1s），
        // 还会和后台采样器撞车 —— 实测延迟在 0.2s ↔ 3.2s 之间乱跳。
        let action = params["action"] as? String ?? ""
        let readOnlyAction = (path == "/api/control")
            && (action == "volume_get" || action == "brightness_get")
        if !readOnlyAction { invalidateFanCache() }
        switch path {
        case "/api/control":              return doControl(params["action"] as? String ?? "", params)
        case "/api/fan":                  return doFan(params)
        case "/api/lightbar":             return doLightbar(params)
        case "/api/rgb":                  return doRGB(params)
        case "/api/rgb/apply":            return RGBProfile.apply()
        case "/api/rgb/forget":           return ["ok": RGBProfile.clear()]
        case "/api/rgb/save":
            guard let prof = params["profile"] as? [String: Any], !prof.isEmpty else {
                return ["ok": false, "error": "profile 无效"]
            }
            return ["ok": RGBProfile.save(prof), "profile": prof]
        case "/api/rgb/whitecal":
            // 由「肉眼看到的偏色」反算三通道增益（与 BetterRGB 同款算法）
            let observed = (params["observed"] as? String ?? "").replacingOccurrences(of: "#", with: "")
            guard let res = RGBGains.calcWhiteGains(observed) else {
                return ["ok": false, "error": "observed 颜色无效"]
            }
            RGBGains.save(res["R"] as? Int ?? 1000, res["G"] as? Int ?? 1000, res["B"] as? Int ?? 1000,
                          observed: observed)
            // 这次标定即成为滑条端点（对应 t=100），之后滑条可无损往外拖
            RGBSlider.saveEndpoint(res["R"] as? Int ?? 1000, res["G"] as? Int ?? 1000,
                                   res["B"] as? Int ?? 1000)
            let re = RGBProfile.apply()
            return ["ok": true, "white_gain": res, "slider": 100,
                    "reapplied": re["ok"] as? Bool ?? false]
        case "/api/rgb/whitegain":
            // 两种用法：直接给 R/G/B 增益，或给滑条位置 t（按端点插值）
            if let t = params["t"] as? Double {
                let g = RGBSlider.toGains(t)
                RGBGains.save(g.0, g.1, g.2)
                let re = RGBProfile.apply()
                return ["ok": true, "white_gain": ["R": g.0, "G": g.1, "B": g.2],
                        "slider": RGBSlider.fromGains(g),
                        "reapplied": re["ok"] as? Bool ?? false]
            } else {
                let g = RGBGains.save(params["R"] as? Int ?? 1000,
                                      params["G"] as? Int ?? 1000,
                                      params["B"] as? Int ?? 1000)
                let re = RGBProfile.apply()
                return ["ok": true, "white_gain": ["R": g.0, "G": g.1, "B": g.2],
                        "slider": RGBSlider.fromGains(g),
                        "reapplied": re["ok"] as? Bool ?? false]
            }
        case "/api/rgb/whitegain/reset":
            RGBGains.clear()
            RGBSlider.clearEndpoint()
            let re = RGBProfile.apply()
            return ["ok": true, "slider": 0, "reapplied": re["ok"] as? Bool ?? false]
        default:
            return nil
        }
    }

    // MARK: 键盘灯状态（对应 Python rgb_state()）

    /// 三位小数（等价 Python round(x, 3)）
    private static func round3(_ v: Double) -> Double {
        (v * 1000).rounded() / 1000
    }

    static func rgbState() -> [String: Any] {
        let prof = RGBProfile.load()
        let g = RGBGains.load()
        let e = RGBSlider.loadEndpoint()
        // 拆成小表达式，避免巨型字典字面量拖垮类型推断
        let gFactors = [round3(Double(g.0) / 1000), round3(Double(g.1) / 1000), round3(Double(g.2) / 1000)]
        let eFactors = [round3(Double(e.0) / 1000), round3(Double(e.1) / 1000), round3(Double(e.2) / 1000)]
        let (wr, wg, wb) = RGBGains.apply((255, 255, 255))
        var gains: [String: Any] = [:]
        gains["R"] = g.0
        gains["G"] = g.1
        gains["B"] = g.2
        gains["factors"] = gFactors
        gains["end"] = ["R": e.0, "G": e.1, "B": e.2]
        gains["end_factors"] = eFactors
        gains["slider"] = RGBSlider.fromGains(g)
        // 满白经校准后实际下发的 RGB（便于直观看出被压了多少）
        gains["white_rgb"] = [wr, wg, wb]
        if !KeyboardRGB.available() {
            return ["available": false, "profile": prof ?? NSNull(), "white_gain": gains]
        }
        do {
            let kb = try KeyboardRGB().open()
            defer { kb.close() }
            return ["available": true,
                    "info": kb.info(),
                    "state": kb.getState() ?? NSNull(),
                    "firmware": kb.getFirmware(),
                    "profile": prof ?? NSNull(),
                    "profile_path": profilePath(),
                    "white_gain": gains]
        } catch {
            return ["available": false, "error": "\(error)",
                    "profile": prof ?? NSNull(), "white_gain": gains]
        }
    }

    private static func profilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole/rgb_profile.json").path
    }

    // MARK: 控制动作（对应 Python do_control()）

    static func doControl(_ action: String, _ params: [String: Any]) -> [String: Any] {
        switch action {
        case "volume_get":
            // 优先问 CoreAudio（微秒级、无子进程）；失败再退回 osascript。
            // 旧实现只走 osascript：实测 0.4–0.9s/次，而 MonitorStore 每 2s
            // 调一次，等于常驻一个慢请求。CoreAudio 是系统真相源，更快也更准。
            if let s = systemVolume() {
                return ["ok": true, "volume": s.volume, "muted": s.muted, "via": "coreaudio"]
            }
            let out = shOSAScript([
                "set v to output volume of (get volume settings)",
                "set m to output muted of (get volume settings)",
                "return (v as string) & \" \" & (m as string)",
            ]).trimmingCharacters(in: .whitespaces)
            let parts = out.split(separator: " ").map(String.init)
            if parts.count >= 2, let v = Int(parts[0]) {
                return ["ok": true, "volume": v, "muted": parts[1].lowercased() == "true"]
            }
            return ["ok": false, "error": "读取失败：" + (out.isEmpty ? "osascript 无输出" : out)]

        case "volume":
            let v = params["value"] as? Int ?? 50
            _ = shOSAScript(["set volume output volume \(max(0, min(100, v)))"])
            return ["ok": true, "volume": v]

        case "mute":
            _ = shOSAScript(["set volume output muted true"])
            return ["ok": true, "muted": true]

        case "unmute":
            _ = shOSAScript(["set volume output muted false"])
            return ["ok": true, "muted": false]

        case "brightness_get":
            // 新方案（2026-10-17）：面板在 PWM 模式下由 macOS 原生链路驱动，
            // 「系统亮度」就是真相源；旧的「读 DPCD 0x723 硬件真值」已失效。
            var b = NativeBrightness.get()
            if let mode = NativeBrightness.panelBLMode() { b["panel_mode"] = mode }
            b["via"] = "iokit"
            return b

        case "brightness":
            var v = Double(params["value"] as? Int ?? 50)
            v = max(0, min(100, v))
            // 单真相源架构：IOKit 改系统亮度 → 原生链路写 PWM 占空比 → 面板跟随。
            // 守护没在跑时先补一次模式切换，保证本次写入能到达屏幕。
            let applied = NativeBrightness.ensurePWMMode()
            var res = NativeBrightness.set(v)
            if res["ok"] as? Bool == true, let applied = applied {
                res["via"] = (res["via"] as? String ?? "iokit") + "+" + applied + "-ensure"
            } else if res["ok"] as? Bool == true, !brightnessDaemonAlive() {
                if let tool = NativeBrightness.pwmTool() ?? NativeBrightness.auxbrightTool() {
                    _ = NativeBrightness.run(tool, args: [tool.lastPathComponent == "pwmwake" ? "ensure" : "pwm"])
                    res["via"] = (res["via"] as? String ?? "iokit") + "+ensure-retry"
                }
            }
            if let mode = NativeBrightness.panelBLMode() { res["panel_mode"] = mode }
            return res

        case "caffeinate":
            // 不带 on 参数 = 查询当前状态（按钮高亮必须反映真实运行状态）
            guard let on = params["on"] as? Bool else {
                return ["ok": true, "on": caffeinateRunning()]
            }
            if on {
                if caffeinateRunning() {
                    return ["ok": true, "on": true, "note": "已在运行"]
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                p.arguments = ["-d", "-i", "-s"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let pidFile = caffeinatePIDURL()
                    let dir = pidFile.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? String(p.processIdentifier).write(to: pidFile,
                                                           atomically: true, encoding: .utf8)
                    return ["ok": true, "on": true, "pid": p.processIdentifier]
                } catch {
                    return ["ok": false, "error": "\(error)"]
                }
            } else {
                if let pid = caffeinatePID() {
                    kill(pid_t(pid), SIGTERM)
                }
                try? FileManager.default.removeItem(at: caffeinatePIDURL())
                return ["ok": true, "on": false]
            }

        case "rgb":
            return doRGB(params)

        default:
            return ["ok": false, "error": "未知动作: \(action)"]
        }
    }

    // MARK: caffeinate 辅助

    private static func caffeinatePIDURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole/.caffeinate.pid")
    }

    private static func caffeinatePID() -> Int? {
        guard let data = try? Data(contentsOf: caffeinatePIDURL()),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(s) else { return nil }
        return pid
    }

    private static func caffeinateRunning() -> Bool {
        guard let pid = caffeinatePID() else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    // MARK: RGB 动作（对应 Python do_rgb()）

    static func doRGB(_ params: [String: Any]) -> [String: Any] {
        guard KeyboardRGB.available() else {
            return ["ok": false, "error": "未检测到 ITE 8291 键盘灯设备"]
        }
        let mode = params["mode"] as? String ?? "color"
        var result: [String: Any] = ["ok": false, "error": "未知 RGB 模式: \(mode)"]
        do {
            let kb = try KeyboardRGB().open()
            defer { kb.close() }
            switch mode {
            case "off":
                let kr = kb.disable()
                result = ["ok": kr == 0, "kr": kr, "mode": "off"]
            case "brightness":
                let kr = try kb.setBrightness(params["level"] as? Int ?? 3)
                result = ["ok": kr == 0, "kr": kr, "mode": "brightness"]
            case "effect":
                // 自带 hex 就走「命名色 0x14 + 槽位」，让灯效跑在自定义颜色上
                var effRGB: [Int]? = nil
                if let hex = params["hex"] as? String {
                    let hx = hex.replacingOccurrences(of: "#", with: "")
                    if hx.count == 6 {
                        effRGB = RGBUtil.hexToRgb(hx)
                    }
                }
                let kr = try kb.setStyle(name: params["style"] as? String ?? "rainbow",
                                         brightness: params["brightness"] as? Int ?? 3,
                                         speed: params["speed"] as? Int ?? 5,
                                         save: params["save"] as? Int ?? 1,
                                         rgb: effRGB,
                                         slot: params["slot"] as? Int ?? 1)
                result = ["ok": kr == 0, "kr": kr, "mode": "effect",
                          "style": params["style"] as? String ?? "rainbow",
                          "hex": effRGB != nil ? (params["hex"] as? String ?? NSNull()) : NSNull()]
            case "color":
                let hx = (params["hex"] as? String ?? "#00a0ff").replacingOccurrences(of: "#", with: "")
                let rgb = hx.count == 6 ? RGBUtil.hexToRgb(hx) : [0, 160, 255]
                let kr = try kb.setColor(r: rgb[0], g: rgb[1], b: rgb[2],
                                         brightness: params["brightness"] as? Int ?? 4,
                                         save: params["save"] as? Int ?? 1)
                result = ["ok": kr == 0, "kr": kr, "mode": "color", "hex": hx]
            case "zones":
                let zones = (params["zones"] as? [[Any]] ?? []).map { z in
                    [z[0] as? Int ?? 0, z[1] as? Int ?? 0, z[2] as? Int ?? 0]
                }
                guard !zones.isEmpty else { return ["ok": false, "error": "zones 为空"] }
                _ = try kb.setBrightness(params["brightness"] as? Int ?? 4)
                usleep(50_000)
                let kr = try kb.setZoneColors(zones, repeat: 1, save: 1)
                result = ["ok": kr == 0, "kr": kr, "mode": "zones"]
            default:
                break
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

        // 成功后自动记住，供开机恢复
        if result["ok"] as? Bool == true, params["remember"] as? Bool ?? true {
            let prof = RGBProfile.fromParams(params)
            result["remembered"] = RGBProfile.save(prof)
            result["profile"] = prof
        }
        return result
    }

    // MARK: EC 取数（走短 TTL 缓存）

    private static let fanCache = FanAPICache()

    private static func cachedFanStatus() -> [String: Any] {
        if let v = fanCache.get("live", 5.0) as? [String: Any] { return v }
        let v = FanControl.shared.fanStatus()
        fanCache.put("live", v)
        return v
    }

    private static func cachedMisc() -> [String: Any] {
        if let v = fanCache.get("misc", 15.0) as? [String: Any] { return v }
        let v = FanControl.shared.miscStatus()
        fanCache.put("misc", v)
        return v
    }

    private static func cachedCharge() -> [String: Any]? {
        if let v = fanCache.get("charge", 45.0) as? [String: Any] { return v }
        guard let v = FanControl.shared.chargeThreshold() else { return nil }
        fanCache.put("charge", v)
        return v
    }

    /// 写操作后清空，保证紧接着的 GET 能看到新值
    static func invalidateFanCache() { fanCache.clear() }

    // MARK: 后台 EC 采样器
    //
    // 为什么要有：一次完整扫描 = 17 次 EC 读 ≈ 1.1s（EC 硬上限 ~15 次/秒）。
    // 若扫描由 HTTP 请求触发，请求方最坏要等满 1.1s —— 实测 2.5.4 首版
    // /api/fan 在 0.19s 与 1.45s 之间跳。改成后台每 2s 采一次样，GET 永远
    // 命中热缓存，延迟恒定在几十毫秒；EC 占用也收敛到 ~5.4 次/秒（36%）。
    //
    // TTL 必须 > 采样间隔（live TTL 3.0s > 2.0s），否则两次采样之间会出现
    // 「缓存过期 → 请求自己再扫一遍」的空档。

    private final class SamplerBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    private static let samplerBox = SamplerBox()
    static let samplerInterval: TimeInterval = 2.0

    static func startSampler() {
        guard samplerBox.task == nil else { return }
        samplerBox.task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let t0 = Date()
                if FanControl.kextLoaded() {
                    _ = cachedFanStatus()
                    _ = cachedMisc()
                    _ = cachedCharge()
                }
                // 按周期调度：扫描本身要 ~1.1s，若「扫完再固定睡 2s」，
                // 实际周期会变成 ~3.1s 并超过 live TTL，导致请求自己又扫一遍、
                // 和采样器撞车（实测尖峰 2.7–3.7s）。这里扣掉已耗时。
                let spent = Date().timeIntervalSince(t0)
                let wait = max(0.2, samplerInterval - spent)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: 散热（对应 Python fan_state / do_fan）

    static func fanState() -> [String: Any] {
        let loaded = FanControl.kextLoaded()
        let st = FanStateStore.load() ?? ["mode": "normal", "level": 0]
        var out: [String: Any] = [
            "available": loaded,
            "mode": st["mode"] as? String ?? "normal",
            "level": st["level"] as? Int ?? 0,
        ]
        if loaded {
            let live = cachedFanStatus()
            out["live"] = live
            // 界面以 EC 里的真实状态为准，保存的设置只用于「重启后自动恢复」
            out["actual"] = live["actual"] ?? (st["mode"] as? String ?? "normal")
            out["actual_level"] = live["actual_level"] ?? (st["level"] as? Int ?? 0)
            out["modeindex"] = live["modeindex"] ?? NSNull()
            let actual = out["actual"] as? String ?? "normal"
            let actualLevel = out["actual_level"] as? Int ?? 0
            let savedMode = st["mode"] as? String ?? "normal"
            let savedLevel = st["level"] as? Int ?? 0
            out["synced"] = (actual == savedMode && (actual != "custom" || actualLevel == savedLevel))
            if let charge = cachedCharge() {
                out["charge"] = charge
            }
            out["misc"] = cachedMisc()
            out["curve"] = FanCurveController.shared.snapshot()
        } else {
            out["hint"] = ("TongfangFan.kext 未加载 —— 点控制页的「自动安装」"
                + "或双击随附的「安装散热控制.command」（需管理员密码）")
        }
        return out
    }

    static func doFan(_ params: [String: Any]) -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["ok": false, "error": "TongfangFan.kext 未加载",
                    "hint": "点控制页「自动安装」或双击「安装散热控制.command」后重试"]
        }
        let fc = FanControl.shared
        let mode = params["mode"] as? String ?? ""

        if let prof = params["profile"] as? String {
            guard ["quiet", "balance", "perf"].contains(prof) else {
                return ["ok": false, "error": "profile 必须是 quiet/balance/perf"]
            }
            guard let r = fc.setProfile(prof) else {
                return ["ok": false, "error": "写入失败"]
            }
            return ["ok": r.ok, "reply": r.dict, "profile": prof]
        }

        if let code = params["modeindex"] as? Int {
            guard [0x11, 0x22, 0x33].contains(code) else {
                return ["ok": false, "error": "modeindex 必须是 0x11(专业)/0x22(平衡)/0x33(省电)"]
            }
            // 方案 A（2026-10-21 修复）：性能模式是「EC 接管」语义。若当前跑着曲线模式，
            // FanCurveController 正攥着 FAN_CTRL 手动权（0x0741 手动门开着），此时只写
            // 0x07AB 会出现「toast 报成功、风扇纹丝不动」——EC 在手动门关闭时才认模式索引。
            // 必须先交还控制权，顺序不能反：
            //   1) 停曲线控制环（它每 2s 按曲线覆写 FAN_CTRL，会把新模式的效果盖掉）
            //   2) setMode("normal") 写 0x0741=0 关手动门，EC 收回风扇管辖权
            //   3) 补写 0x0751=0xA0（qc71 驱动「自动模式」同款序列，双保险）
            //   4) 最后才写 0x07AB —— EC 按新模式自行调度
            // 曲线配置已落盘（FanCurveStore），用户随时可切回曲线模式恢复。
            let curveWasActive = FanCurveController.shared.active
            FanCurveController.shared.stop()
            _ = fc.setMode("normal")
            _ = fc.ecWrite(EC.fanCtrl, EC.fanCtrlAutoMode)
            guard let r = fc.setModeIndex(UInt32(code)) else {
                return ["ok": false, "error": "写入失败"]
            }
            if r.ok { FanStateStore.save("normal", 0) }
            let cur = (fc.ecRead(EC.fanModeIndex)?.result ?? 0) & 0xFF
            let ctrl3 = (fc.ecRead(EC.ctrl3)?.result ?? 0) & 0xFF
            let fanCtrl = (fc.ecRead(EC.fanCtrl)?.result ?? 0) & 0xFF
            return ["ok": r.ok, "reply": r.dict, "modeindex": cur, "ctrl3": ctrl3,
                    "fan_ctrl": fanCtrl, "curve_stopped": curveWasActive]
        }

        // 键盘 Fn 锁 / 触控板 / 超频动态温控 / 风扇行为（qc71_laptop 交叉验证，
        // 2026-10-21）：都是读-改-写单位，与官方控制台同路径
        if let v = params["fn_lock"] as? Bool {
            guard let r = fc.setFnLock(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fn_lock": v]
        }
        if let v = params["fn_lock_switch"] as? Bool {
            guard let r = fc.setFnLockSwitch(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fn_lock_switch": v]
        }
        if let v = params["touchpad"] as? Bool {
            guard let r = fc.setTouchpad(enabled: v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "touchpad": v]
        }
        if let v = params["overboost_dyn_temp"] as? Bool {
            guard let r = fc.setOverboostDynTemp(enabled: v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "overboost_dyn_temp": v]
        }
        if let v = params["fan_reduced_duty"] as? Bool {
            guard let r = fc.setFanReducedDuty(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fan_reduced_duty": v]
        }
        if let v = params["fan_always_on"] as? Bool {
            guard let r = fc.setFanAlwaysOn(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fan_always_on": v]
        }

        if let pct = params["charge"] as? Int {
            guard (0...100).contains(pct) else {
                return ["ok": false, "error": "充电阈值必须在 0-100"]
            }
            guard let r = fc.setChargeThreshold(pct) else {
                return ["ok": false, "error": "写入失败"]
            }
            return ["ok": r.ok, "reply": r.dict, "charge": pct]
        }

        // 曲线模式：解析配置（points/source/failsafe），启动常驻控制环
        if mode == "curve" {
            var cfg = FanCurveController.shared.config
            if let src = params["source"] as? String, ["cpu", "gpu", "max"].contains(src) {
                cfg.source = src
            }
            if let fs = params["failsafe"] as? Int, (60...110).contains(fs) {
                cfg.failsafeTemp = fs
            }
            if let arr = params["points"] as? [[String: Any]] {
                var pts: [FanCurvePoint] = []
                for d in arr {
                    guard let t = d["temp"] as? Int, let l = d["level"] as? Int,
                          (FanCurveConfig.tempMin...FanCurveConfig.tempMax).contains(t),
                          (0...FanCurveConfig.levelMax).contains(l) else { continue }
                    pts.append(FanCurvePoint(temp: t, level: l))
                }
                if pts.count >= 2 { cfg.points = pts.sorted { $0.temp < $1.temp } }
            }
            FanCurveController.shared.config = cfg
            FanCurveStore.save(cfg)
            FanCurveController.shared.start()
            FanStateStore.save("curve", 0)
            return ["ok": true, "mode": "curve", "curve": FanCurveController.shared.snapshot()]
        }

        if mode == "normal" || mode == "boost" {
            FanCurveController.shared.stop()   // 离场曲线模式
            let r = fc.setMode(mode)
            let level = params["level"] as? Int ?? 0
            let ok = r?.ok ?? false
            if ok { FanStateStore.save(mode, level) }
            return ["ok": ok, "reply": r?.dict ?? NSNull(), "mode": mode, "level": level]
        } else if params["level"] != nil || mode == "custom" {
            FanCurveController.shared.stop()   // 离场曲线模式
            let level = params["level"] as? Int ?? 0
            guard (0...7).contains(level) else {
                return ["ok": false, "error": "level 必须在 0-7"]
            }
            let r = fc.setLevel(level)
            let ok = r?.ok ?? false
            if ok { FanStateStore.save("custom", level) }
            return ["ok": ok, "reply": r?.dict ?? NSNull(), "mode": "custom", "level": level]
        } else {
            return ["ok": false, "error": "缺少 mode / level / profile"]
        }
    }

    // MARK: 海岸灯（对应 Python lightbar_state / do_lightbar）

    static func lightbarState() -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["available": false, "note": "TongfangFan.kext 未加载，EC 不可达"]
        }
        guard let st = FanControl.shared.lightbarStatus() else {
            return ["available": false, "note": "EC 读失败"]
        }
        var out = st
        out["available"] = true
        return out
    }

    static func doLightbar(_ params: [String: Any]) -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["ok": false, "error": "TongfangFan.kext 未加载"]
        }
        let hx = (params["hex"] as? String ?? "").replacingOccurrences(of: "#", with: "")
        guard hx.count == 6, hx.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            return ["ok": false, "error": "hex 颜色无效"]
        }
        let rgb = RGBUtil.hexToRgb(hx)

        let c = params["ctrl"] ?? params["mode"] ?? "cycle"
        var ctrl: UInt8
        if let s = c as? String {
            switch s {
            case "cycle":  ctrl = EC.lightbarCycle
            case "static": ctrl = EC.lightbarStatic
            case "off":    ctrl = EC.lightbarOff
            default:
                return ["ok": false, "error": "ctrl 取值无效"]
            }
        } else if let n = c as? Int, (0...255).contains(n) {
            ctrl = UInt8(n)
        } else {
            return ["ok": false, "error": "ctrl 取值无效"]
        }

        guard let st = FanControl.shared.lightbarSet(rgb, ctrl: ctrl) else {
            return ["ok": false, "error": "写入后回读失败"]
        }
        var out = st
        out["ok"] = true
        out["available"] = true
        return out
    }

    // MARK: 能力矩阵（对应 Python capability()）

    static func capability() -> [String: Any] {
        let fn = SMCSnapshot.snapshot()
        let fanKext = FanControl.kextLoaded()

        var usable: [[String: Any]] = [
            ["name": "CPU 各核心温度", "detail": "SMC TC1C~TC6C，6 个物理核心独立读数"],
            ["name": "CPU 封装温度", "detail": "SMC TC0P / TC0D / TC0E / TC0F / TC0H"],
            ["name": "CPU 电流与功耗", "detail": "SMC PC0C / PCPC / PCPT / PCTR (sp96 定点)"],
            ["name": "内存 / 负载 / 运行时间", "detail": "sysctl + host_statistics64"],
            ["name": "显卡信息", "detail": "system_profiler，核显 + RTX 2070S 均可见"],
            ["name": "电池", "detail": "IORegistry AppleSmartBattery + pmset"],
            ["name": "磁盘占用", "detail": "df，含 Word / Windows 分区"],
            ["name": "键盘灯控制", "detail": "ITE 8291 (048d:ce00) HID Feature 报告，已实测可写"],
            ["name": "屏幕亮度", "detail": "IOKit IODisplaySetFloatParameter 改系统亮度，"
                + "面板 PWM 模式下由 macOS 原生链路驱动屏幕"
                + "（auxbright 守护保持模式），系统滑条与控制台滑条同一真相源"],
        ]
        var partial: [[String: Any]] = [
            ["name": "电池健康度", "detail": "VirtualSMC 对电池建模较粗：循环次数恒为 0、"
                + "设计容量 = 最大容量，容量读数可信度有限"],
        ]

        if fanKext {
            usable.append(["name": "散热模式控制",
                           "detail": "kext → WMI ABBC0F6F → EC 邮箱(LDAT/HDAT/CMDL/CMDH)；"
                + "自动 / 基准·拉满(78%，约 5500 RPM) / 手动 L0-7(24%~53%)；"
                + "写入前先开 CTRL_1 手动门 —— 与 Windows Control Center 同路"])

            usable.append(["name": "风扇转速与温度读数",
                           "detail": "绕开 SMC，直接读 EC 0x046C(CPU) / 0x0464(GPU)（大端，实测 "
                + ecLiveRPMText() + "），温度 0x043E(CPU) / 0x044F(独显)。"
                + "实测两路 PWM 数值始终相同（12 进程满载全程 80→177 一致），"
                + "EC 给两颗风扇的是同一个占空比；转速差约 12% 来自风扇个体/型号差异，"
                + "不是接反。两颗风扇的归属由用户实物确认：他亲手换过 CPU 风扇，"
                + "转速较高的 0x046C 才是 CPU 风扇（2026-10-16 修正，之前标反）。"
                + "同期 0x043E 从 64℃ 升到 89℃ 而 0x044F 仅 60→62℃，"
                + "确认后者不在 CPU 那一路"])
            let prob = FanControl.shared.ecProbe()
            let mi = prob["modeindex"] as? UInt8 ?? 0
            usable.append(["name": "性能模式（专业 / 平衡 / 省电）",
                           "detail": "写 EC 0x07AB（MyFanCCI_Mode_Index）= 0x11/0x22/0x33，"
                + "就是 BIOS「Power Mode」和键盘上那颗模式按钮的同一个开关，"
                + "键盘灯实时跟随（专业=2 灯、平衡=1 灯、省电=不亮）。"
                + "12 子进程满载实测：专业档 CPU 算力最快、风扇随温度爬升 29→44%；"
                + "平衡档风扇最猛（78℃ 就 41~47%）、算力慢 4~5%；"
                + "省电档风扇压在 31% 不动、算力慢 5~9%（A/B/C/A 交叉复现）。"
                + "注意正确入口是 0x07AB，不是 CTRL_3 (0x07A5) 直写——"
                + "后者 bit2 被 EC 掩码，且模式索引有效时写入会被秒级覆盖。"
                + String(format: "当前档位：0x%02X（%s）", mi,
                         [0x11: "专业", 0x22: "平衡", 0x33: "省电"][mi] ?? "未知")])
            let charge = prob["charge"] as? Int ?? 0
            usable.append(["name": "电池充电阈值",
                           "detail": "EC 0x07B9，bit0-6 = 百分比，实测可写（设 80 → 回读 0xD0，"
                + "bit7 reached 置位后停止充电）；当前阈值 \(charge)%"])
            let misc = FanControl.shared.miscStatus()
            usable.append(["name": "键盘 Fn 锁 / 触控板 / 风扇行为",
                           "detail": "EC 0x074E bit4（Fn 锁）/ 0x07A4 bit3（Fn+Esc 快捷键）/ "
                + "0x07A6 bit6（触控板开关）/ 0x07A6 bit1（超频动态温控）/ "
                + "0x07A3 bit5-6（风扇降低占空比 / 常转），全部读-改-写单位，"
                + "qc71_laptop 同族开源驱动交叉验证（sysfs 同款属性）。"
                + String(format: "当前：Fn锁%@ / Fn+Esc%@ / 触控板%@ / 动态温控%@ / 降载%@ / 常转%@",
                         (misc["fn_lock"] as? Bool ?? false) ? "开" : "关",
                         (misc["fn_lock_switch"] as? Bool ?? false) ? "开" : "关",
                         (misc["touchpad_off"] as? Bool ?? false) ? "禁用" : "启用",
                         (misc["overboost_dyn_temp_off"] as? Bool ?? false) ? "关" : "开",
                         (misc["fan_reduced_duty"] as? Bool ?? false) ? "开" : "关",
                         (misc["fan_always_on"] as? Bool ?? false) ? "开" : "关")])
            if prob["support_lightbar"] as? Bool == true {
                usable.append(["name": "海岸灯（Lightbar / 灯条）",
                               "detail": "EC 0x0748 控制字节 + 0x0749-0x074B RGB，实测可写、回读一致。"
                    + "已肉眼验证三种状态：ctrl=0x80 多彩轮换动画（机器出厂行为）、"
                    + "ctrl=0x00 停在固定色（显示 RGB 寄存器里存的颜色）、ctrl=0x84 关灯——"
                    + "即 bit7 是「轮换/动画」位（不是开关位），bit2 才是关灯位。"
                    + "bit4/5 被 EC 掩码写不进去；bit0/1/3/6 语义未知"
                    + "（OEM 侧还有 WelcomeMode、BreathingLightEffect 未对应）。"
                    + "OEM 的 DefaultRGBLightbar.exe 同走这组寄存器；HID 侧 MyLightBar 设备"
                    + "本机不存在，EC 是唯一通路"])
            }
        } else {
            partial.append(["name": "散热 / 性能模式 / 风扇转速 / 充电阈值 / 海岸灯",
                            "detail": "方案已备好（TongfangFan.kext），首次运行 app 会自动安装：散热模式（自动/基准/手动）、性能模式（专业/平衡/省电）、"
                + "风扇转速与温度读数、电池充电阈值、海岸灯"])
        }

        return [
            "usable": usable,
            "partial": partial,
            "unavailable": [
                ["name": "硬盘 / NVMe 温度",
                 "detail": "所有来源都查过：SMC 只枚举出 TC* 一串 "
                    + "CPU 温度键（无 TH*/Tm*）；ioreg 里 "
                    + "IONVMeController 与 IOBlockStorageDevice "
                    + "都不上报温度（全系统唯一的 Temperature 键是电池的）；"
                    + "EC 页 0x04 整页扫描也没有像硬盘热敏的寄存器。"
                    + "常规做法要靠 smartctl（smartmontools），"
                    + "本机未安装且无 brew，且 macOS 读 NVMe SMART 需管理员权限"],
                ["name": "GPU 占用率与功耗",
                 "detail": "macOS 没有开放 GPU 利用率的用户态接口。"
                    + "独显 RTX 2070S 在 macOS 下只有一个 PCIe 设备条目"
                    + "（官方驱动早已停更、始终空载），核显 UHD 630 也不上报。"
                    + "核显与 CPU 同封装、本机没有它的独立热敏"
                    + "（SMC 无 TG* 键），界面上核显那一格是 CPU 封装温度的参考值"],
                ["name": "自定义风扇曲线（BIOS Fan Control Mode）",
                 "detail": "BIOS 里「Fan Control Mode」"
                    + "（Fixed/Custom/Cool/Balanced/Quiet/Fanless，"
                    + "NVRAM 0x12F4）才是真正的风扇设置，但运行时换不了："
                    + "OEM 地址表（keyboard.dll 774 个常量）里没有对应寄存器；"
                    + "MYFAN2 曲线单元格 0x0743-47 写得进、回读一致，却完全无效"
                    + "（改成温度断点或占空比值，风扇都毫无反应，"
                    + "与 PL 设置一样是 EC 独占的死单元格）；"
                    + "CTRL_3 (0x07A5) 低三位在模式索引有效时被 EC 秒级覆盖，"
                    + "清空索引后能写住但负载下测不出差异。"
                    + "结论：它是 POST 时按 NVRAM 一次性选好的内部曲线，"
                    + "之后 EC 自己调度。可试路径：BIOS 里设为 Custom 再重启，"
                    + "EC 可能就会启用曲线单元格（待验证）"],
            ],
            "smc": [
                "available": fn["available"] ?? false,
                "key_count": fn["key_count"] ?? 0,
                "fan_note": fn["fan_note"] ?? NSNull(),
            ],
        ]
    }

    private static func ecLiveRPMText() -> String {
        let s = FanControl.shared.fanStatus()
        return String(format: "CPU %d RPM / GPU %d RPM",
                      s["rpm_cpu"] as? Int ?? 0, s["rpm_gpu"] as? Int ?? 0)
    }

    // MARK: 亮度守护（对应 Python _brightness_daemon_alive / ensure_brightness_daemon）

    /// pwmwake（v5 事件驱动）或旧 auxbright watch 守护是否在跑。
    /// 走 NativeProc（3s 硬超时）：pgrep 在个别环境下会卡，无界等待会挂死调用方。
    /// 模式必须锚定：`pgrep -f pwmwake` 会误中任何命令行里带 "pwmwake" 字样的进程
    /// （比如终端里 tail 守护日志、自动化脚本的调用串），害得真没人跑时也不去拉守护。
    /// 守护进程的 cmdline 就是「…/pwmwake」且无参数，用 `(^|/)pwmwake$` 精确匹配。
    static func brightnessDaemonAlive() -> Bool {
        daemonRunning("(^|/)pwmwake$") || daemonRunning("auxbright watch")
    }

    /// pgrep -f 精确匹配（3s 硬超时，防个把环境里 pgrep 卡死）
    private static func daemonRunning(_ pattern: String) -> Bool {
        NativeProc.runCapture("/usr/bin/pgrep", ["-f", pattern], timeout: 3).ok
    }

    /// 确保亮度守护在跑。优先 pwmwake v5.x（事件驱动、镜像/假负载模式无盲区）——
    /// 无参数调用即守护模式，与 LaunchAgent `com.user.pwmwake` 的启动方式一致，
    /// 日志落到同一个 `~/Library/Logs/pwmwake.out.log`。
    /// 找不到 pwmwake 才回退 auxbright v4 watch（轮询式，镜像模式有盲区，仅兜底）。
    /// 守护脱离控制台独立存活（控制台关掉后系统滑条照样好用）。
    /// 两个背景（2026-10-20 实测踩坑）：
    /// ① LaunchAgent 的 program 路径改过布局（python/bin→native/bin），launchd 内存里的
    ///    旧任务不会自动重读，守护一旦死了就再也起不来——app 这层兜底专门补这个洞；
    /// ② 老版本 app 拉起的 auxbright watch 残留会长期存活（还可能从已进废纸篓的旧
    ///    bundle 里跑），让存活检查误判「已有守护」、挡住 pwmwake 上位，且 v4 在镜像
    ///    模式下根本钉不住面板（睡眠唤醒后面板掉 AUX 无人管）。pwmwake 就位后清掉它。
    static func ensureBrightnessDaemon() {
        if daemonRunning("(^|/)pwmwake$") {
            print("亮度守护已在运行")
            return
        }
        // 首选 pwmwake（LaunchAgent 同款二进制，无参 = 守护模式）
        if let pwm = NativeBrightness.pwmTool(), pwm.lastPathComponent == "pwmwake" {
            let logURL = URL(fileURLWithPath:
                NSHomeDirectory() + "/Library/Logs/pwmwake.out.log")
            if let h = try? FileHandle(forWritingTo: logURL) {
                try? h.seekToEnd()
                let p = Process()
                p.executableURL = pwm
                p.standardOutput = h
                p.standardError = h
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                    // pwmwake 就位后再清 v4 残留（顺序反了会有「都没守护」的空窗）
                    killStaleAuxbright()
                    print("pwmwake 守护已启动（PWM 模式保持，亮度走 macOS 原生链路）")
                } catch {
                    print("pwmwake 守护启动失败（不影响控制台）: \(error)")
                }
                return
            }
        }
        // 回退 auxbright v4 watch（旧守护，轮询式）
        if daemonRunning("auxbright watch") {
            print("auxbright 守护已在运行")
            return
        }
        guard let backend = NativeBrightness.auxbrightTool() else {
            print("找不到 pwmwake / auxbright 二进制，跳过守护启动")
            return
        }
        let logURL = URL(fileURLWithPath: "/tmp/auxbright-console.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) {
            try? h.seekToEnd()
            let p = Process()
            p.executableURL = backend
            p.arguments = ["watch"]
            p.standardOutput = h
            p.standardError = h
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
                print("auxbright 守护已启动（PWM 模式保持，亮度走 macOS 原生链路）")
            } catch {
                print("auxbright 守护启动失败（不影响控制台）: \(error)")
            }
        }
    }

    /// 清掉老版本 app 拉起的 auxbright watch 残留（v4：镜像模式钉不住面板，
    /// 还会让存活检查误判挡住 pwmwake）。只杀命令行精确匹配 `auxbright watch` 的进程。
    private static func killStaleAuxbright() {
        let r = NativeProc.runCapture("/usr/bin/pgrep", ["-f", "auxbright watch"], timeout: 3)
        guard r.ok, !r.out.isEmpty else { return }
        for tok in r.out.split(whereSeparator: { $0.isNewline || $0 == " " }) {
            if let pid = pid_t(tok) {
                kill(pid, SIGTERM)
                print("已清理旧版 auxbright watch 残留 (pid \(pid))")
            }
        }
    }

    // MARK: 登录项守护安装（对应 Python install_login_agents）

    static func installLoginAgents() {
        guard let res = Bundle.main.resourceURL else { return }
        // 2.5.0 起脚本随包在 native/scripts/（旧 python/scripts/ 作过渡兜底）
        let candidates = [
            res.appendingPathComponent("native/scripts/ensure-agents.sh"),
            res.appendingPathComponent("python/scripts/ensure-agents.sh"),
        ]
        guard let script = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { return }
        // 30s 硬超时（脚本要装登录项，可能碰 launchctl）；仍走 NativeProc 防无界等待
        let r = NativeProc.runCapture("/bin/zsh", [script.path], timeout: 30)
        for line in r.out.split(separator: "\n") {
            print("[agents]", line)
        }
        if !r.ok {
            print("登录项安装脚本异常退出（不影响本次使用）")
        }
    }

    // MARK: 服务启动序列（对应 Python main()）

    static func startupSequence() {
        // 启动时恢复上次保存的散热模式（EC 断电会回默认，跟键盘灯同理）
        let r = FanStateStore.apply()
        if r["ok"] as? Bool == true {
            let st = r["state"] as? [String: Any] ?? [:]
            let mode = st["mode"] as? String ?? ""
            if mode == "custom" {
                print("散热模式已恢复: custom 等级 \(st["level"] as? Int ?? 0)")
            } else {
                print("散热模式已恢复: \(mode)")
            }
        } else if r["reason"] as? String != "no-saved-state" && FanControl.kextLoaded() {
            print("散热模式恢复失败: \(r)")
        }
        // 启动时恢复上次保存的键盘灯效（含白平衡增益）
        let rr = RGBProfile.apply()
        if rr["ok"] as? Bool == true {
            print("键盘灯效已恢复: mode=\(rr["mode"] as? String ?? "")")
        } else {
            print("键盘灯效无需恢复: \(rr["error"] as? String ?? "\(rr)")")
        }
        // 亮度守护 + 登录项（系统亮度滑条保持可用的根本保证）
        ensureBrightnessDaemon()
        installLoginAgents()
    }

    // MARK: 小工具

    private static func shOSAScript(_ lines: [String]) -> String {
        var cmd: [String] = []
        for line in lines { cmd += ["-e", line] }
        // 10s 硬超时：osascript 可能卡在 TCC 授权弹窗上，无界等待会挂死服务线程
        return NativeProc.runCapture("/usr/bin/osascript", cmd, timeout: 10).out
    }
}
