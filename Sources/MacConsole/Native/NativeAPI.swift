//
//  NativeAPI.swift
//  Mac控制台 —— 本地后端 API 层（原生移植）
//
//  对应 Python 版 app-resources/server.py 的全部接口逻辑。JSON 输出形状与
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
        // 有页面正在看实时转速：续租（采样器这才开始转），返回缓存值。
        // 首次（缓存还没有转速）直接读一把，避免头一两秒显示 0。
        case "/api/fan/live":
            touchLiveLease()
            if fanCache.get("live", 86_400) == nil { return fanState(fresh: true, renewLease: true) }
            return fanState()
        // 「控制 / 实验性」页打开时：只读一次当前设置（模式组 + 开关组 + 充电阈值），
        // 不续转速采样租约 —— 这些页面不需要实时转速。
        case "/api/fan/refresh": return fanState(fresh: true, renewLease: false)
        case "/api/lightbar":   return lightbarState()
        case "/api/capability": return capability()
        case "/api/all":        return allPayload(slim: false)
        case "/api/snapshot":   return allPayload(slim: true)
        // 独显利用率的「有没有人在看」信号（2026-10-26）。
        //
        // 为什么要有这两条：`NVAccelUtil` 的静态状态跟着进程走，而真正读 NVAccel 的是
        // **helper 进程**（/api/snapshot 在这里组包）。app 侧的 NVAccelUtil 是另一份
        // 没人用的副本，直接在 app 里调 setWanted() 对 helper 毫无影响 ——
        // 所以这个信号必须经 XPC 送过来。
        //
        // 为什么用 GET 而不是 POST：handlePost 开头会 invalidateFanCache()，
        // 一次多余的风扇冷扫描是 17 次 EC 读 ≈1.1 秒，纯属白花。
        // 两条独立路径而不是带参数，是因为 GET 侧没有 params 通道。
        case "/api/dgpu/want":
            NVAccelUtil.setWanted(true)
            return ["ok": true, "wanted": true]
        case "/api/dgpu/idle":
            NVAccelUtil.setWanted(false)
            return ["ok": true, "wanted": false]
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
            && (action == "volume_get")
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
        case "/api/ec/read":
            // 2.8.8：实验性页的 EC 寄存器探针（**只读**，不提供写入）
            guard FanControl.kextLoaded() else {
                return ["ok": false, "error": "TongfangFan.kext 未加载"]
            }
            // JSON 传过来可能是 Int 也可能是 Double（XPC 桥接），两种都收
            let rawAddr: Int? = (params["addr"] as? Int) ?? (params["addr"] as? Double).map { Int($0) }
            guard let a = rawAddr, (1...0xFFFF).contains(a) else {
                return ["ok": false, "error": "地址无效（需要 1…0xFFFF）"]
            }
            guard let r = FanControl.shared.ecRead(UInt32(a)), r.ok else {
                return ["ok": false, "error": "EC 读取失败（地址 0x\(String(a, radix: 16, uppercase: true))）"]
            }
            let v = Int(r.result & 0xFF)
            return ["ok": true, "addr": a, "value": v,
                    "hex": String(format: "0x%02X", v)]
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
            // 2.8.8：亮度回读必须带存档值兜底 —— 芯片的 feature 缓冲只在 0x08 报文
            // 之后才是亮度，写完调色板（0x14）再读会把「颜色的 G 通道」当亮度，
            // 界面滑条就会跳回 0% / 1%（用户反馈的 bug）。
            let savedBright = prof?["brightness"] as? Int
            return ["available": true,
                    "info": kb.info(),
                    "state": kb.getState(fallbackBrightness: savedBright) ?? NSNull(),
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

        case "display_sleep":
            // 原厂「显示屏电源」那一项在 Windows 走 SC_MONITORPOWER；macOS 侧对应
            // `pmset displaysleepnow`（内核直接关背光，不需要辅助功能权限）。
            // 单向动作：屏幕黑了只能靠用户动鼠标/按键唤醒，所以界面不做开关。
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                return ["ok": p.terminationStatus == 0, "via": "pmset displaysleepnow"]
            } catch {
                return ["ok": false, "error": "\(error)"]
            }

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
                let level = params["level"] as? Int ?? 75
                let kr = try kb.setBrightness(level)
                RGBActivity.zoneBrightness = level   // 音乐律动重进逐键模式时沿用它
                result = ["ok": kr == 0, "kr": kr, "mode": "brightness"]
            case "effect":
                // 自带 hex 就走「命名色 0x14 + 槽位」，让灯效跑在自定义颜色上；
                // 2.7.6：给 colors 数组则写满命名色槽 1…n，支持多色灯效
                var effRGB: [Int]? = nil
                if let hex = params["hex"] as? String {
                    let hx = hex.replacingOccurrences(of: "#", with: "")
                    if hx.count == 6 {
                        effRGB = RGBUtil.hexToRgb(hx)
                    }
                }
                var palette: [[Int]]? = nil
                if let colors = params["colors"] as? [[Any]], !colors.isEmpty {
                    palette = colors.prefix(7).map { c in
                        [c.count > 0 ? (c[0] as? Int ?? 0) : 0,
                         c.count > 1 ? (c[1] as? Int ?? 0) : 0,
                         c.count > 2 ? (c[2] as? Int ?? 0) : 0]
                    }
                }
                let kr = try kb.setStyle(name: params["style"] as? String ?? "rainbow",
                                         brightness: params["brightness"] as? Int ?? 75,
                                         speed: params["speed"] as? Int ?? 5,
                                         save: params["save"] as? Int ?? 1,
                                         rgb: effRGB,
                                         slot: params["slot"] as? Int ?? 1,
                                         palette: palette,
                                         // 2.7.10：方向字节只对波浪/跑马灯/极光有意义，
                                         // setStyle 内部会按 supportsDirection 过滤；缺省取原厂「右」
                                         direction: params["direction"] as? Int ?? 1)
                // hex 回显：只在真的下发了 RGB 时才有意义。显式给 Any ——
                // 三元里混 String / NSNull 会被隐式提升成 Any? 再塞进字典（编译警告）。
                let hexOut: Any = (effRGB != nil ? (params["hex"] as? String) : nil) ?? NSNull()
                result = ["ok": kr == 0, "kr": kr, "mode": "effect",
                          "style": params["style"] as? String ?? "rainbow",
                          "slots": palette?.count ?? 0,
                          "effect_code": KeyboardCatalog.effect(forName: params["style"] as? String ?? "")?.rawValue ?? 0,
                          "hex": hexOut]
            case "color":
                let hx = (params["hex"] as? String ?? "#00a0ff").replacingOccurrences(of: "#", with: "")
                let rgb = hx.count == 6 ? RGBUtil.hexToRgb(hx) : [0, 160, 255]
                let kr = try kb.setColor(r: rgb[0], g: rgb[1], b: rgb[2],
                                         brightness: params["brightness"] as? Int ?? 75,
                                         save: params["save"] as? Int ?? 1)
                result = ["ok": kr == 0, "kr": kr, "mode": "color", "hex": hx]
            case "zones":
                let zones = (params["zones"] as? [[Any]] ?? []).map { z in
                    [z[0] as? Int ?? 0, z[1] as? Int ?? 0, z[2] as? Int ?? 0]
                }
                guard !zones.isEmpty else { return ["ok": false, "error": "zones 为空"] }
                // 亮度由调用方一次性设好（0x09 + 50ms 等待会把帧率压到个位数），
                // 这里只在显式给值时重设，并记下来给「重进逐键模式」用。
                if let b = params["brightness"] as? Int {
                    _ = try kb.setBrightness(b)
                    RGBActivity.zoneBrightness = b
                    usleep(50_000)
                }
                // 关键：芯片不在逐键模式时，行数据写进去等于白写（灯还停在原来的灯效上，
                // 看上去就是「音乐律动无效」）。断流超过 1.5s 就补一次 0x08 进模式。
                // 正常流帧间隔 ~83ms，只在首帧和断流恢复时才走这条路。
                let gap = Date().timeIntervalSince(RGBActivity.lastZones)
                if gap > 1.5 {
                    _ = kb.userMode(save: 0, brightness: RGBActivity.zoneBrightness)
                    usleep(3_000)
                }
                let kr = try kb.setZoneColors(zones, repeat: 1)
                RGBActivity.lastZones = Date()   // 告诉灯效保活：这边在刷帧，别插手
                result = ["ok": kr == 0, "kr": kr, "mode": "zones", "entered": gap > 1.5]
            case "keymap":
                // 2.8.8 逐键投影：6 行 × 21 列，每格一个颜色（固件码 0x33 + 行数据）
                let rows = RGBProfile.normalizeKeymap(params["rows"])
                let kr = try kb.setKeyMatrix(rows,
                                             brightness: params["brightness"] as? Int ?? 75,
                                             save: params["save"] as? Int ?? 1)
                result = ["ok": kr == 0, "kr": kr, "mode": "keymap",
                          "keys": RGBProfile.keyRows * RGBProfile.keyCols]
            case "matrix":
                // 音乐律动每帧走这里（2026-10-25）：21 段频谱 → 6 行 × 21 列逐键上色。
                // 与 keymap 的差别只有一点：**不每帧重进逐键模式** —— 每帧发一次 0x08
                // 会打断正在刷的行数据，画面会闪；断流超过 1.5s 才补一次。
                let rows = RGBProfile.normalizeKeymap(params["rows"])
                let gap = Date().timeIntervalSince(RGBActivity.lastZones)
                if gap > 1.5 {
                    _ = kb.userMode(save: 0, brightness: RGBActivity.zoneBrightness)
                    usleep(3_000)
                }
                let kr = try kb.setMatrixRows(rows)
                RGBActivity.lastZones = Date()   // 告诉灯效保活：频谱在跑，别插手
                result = ["ok": kr == 0, "kr": kr, "mode": "matrix", "entered": gap > 1.5]

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
        // 记账：写进 rgb_keepalive.log，和 0x88 的状态流水共用一条时间线。
        // 「灯自己灭了」这类问题就靠它分清是谁写的、写成了什么。
        if params["remember"] as? Bool ?? true {
            let bri = params["brightness"] as? Int ?? params["level"] as? Int
            RGBKeepAlive.note("write mode=\(mode) bri=\(bri.map(String.init) ?? "-") ok=\(result["ok"] as? Bool ?? false)")
        }
        return result
    }

    // MARK: EC 取数（走短 TTL 缓存 + 单飞扫描）

    private static let fanCache = FanAPICache()

    /// EC 扫描单飞盒（2.8.0 修「迟钝」的核心）。
    ///
    /// 以前缓存过期的那一瞬间，UI 的 1s 轮询、后台采样器、曲线环会同时发现
    /// 「缓存没了」，各起一把 fanStatus()（10 次 EC 读 ≈1.1s）。EC 邮箱是全局
    /// 串行资源，几把扫描互相踩，实测 /api/snapshot 的 elapsed_ms 在 32ms ↔
    /// 2203ms 之间跳 —— 慢的那几次就是多把扫描叠加的结果。
    ///
    /// 单飞后同一时刻全局只有一把扫描在跑，其余调用阻塞等它的结果
    /// （最坏 ~1.2s，也好过大家一起踩 EC 变成 2.2s+ 还没结果）。
    private final class ScanFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        private var waiters: [DispatchSemaphore] = []

        /// true = 调用方是执行者（负责扫描并 finish）；false = 已有扫描在飞
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if running { return false }
            running = true
            return true
        }

        /// 等在飞扫描落盘。执行者结束时会唤醒；超时兜底，绝不水挂。
        func wait(timeout: TimeInterval = 10) {
            lock.lock()
            if !running { lock.unlock(); return }   // 执行者已收尾，直接用缓存
            let sem = DispatchSemaphore(value: 0)
            waiters.append(sem)
            lock.unlock()
            _ = sem.wait(timeout: .now() + timeout)
        }

        func finish() {
            lock.lock()
            running = false
            let list = waiters
            waiters.removeAll()
            lock.unlock()
            for s in list { s.signal() }
        }
    }

    private static let liveFlight = ScanFlight()
    private static let modeFlight = ScanFlight()
    private static let miscFlight = ScanFlight()
    private static let lightbarFlight = ScanFlight()

    // MARK: 实时转速租约
    //
    // 2.8.15：EC 不再常驻轮询。app 侧「有页面正在看转速」时才续一条租约
    // （GET /api/fan/live 或 /api/fan/refresh），采样器只在租约有效期间转。
    // 页面切走 10 秒后租约自然过期，EC 读取归零 —— 包括 app 被关掉的情况。
    private final class LeaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var until = Date.distantPast
        func touch(_ seconds: TimeInterval) {
            lock.lock(); until = Date().addingTimeInterval(seconds); lock.unlock()
        }
        var active: Bool {
            lock.lock(); defer { lock.unlock() }
            return Date() < until
        }
    }

    private static let liveLease = LeaseBox()
    static let liveLeaseSeconds: TimeInterval = 10

    /// 有人要看实时转速 → 续租。租约过期后采样器自动停摆。
    static func touchLiveLease() { liveLease.touch(liveLeaseSeconds) }
    static var liveSamplingActive: Bool { liveLease.active }

    /// 实时组（只读 2 个转速）。TTL 2s。
    /// `force` 供采样器用（采样器自己就是刷新源，不能被 TTL 挡住）。
    private static func cachedLive(force: Bool = false) -> [String: Any] {
        if !force, let v = fanCache.get("live", 2.0) as? [String: Any] { return v }
        if liveFlight.tryClaim() {
            let v = FanControl.shared.fanRPMStatus()
            fanCache.put("live", v)
            liveFlight.finish()
            return v
        }
        // 已有扫描在飞：等结果，绝不跟着一起踩 EC
        liveFlight.wait()
        if let v = fanCache.get("live", 2.0) as? [String: Any] { return v }
        // 兜底（等超时且执行者没落盘）：自己扫一把
        let v = FanControl.shared.fanRPMStatus()
        fanCache.put("live", v)
        return v
    }

    /// 模式组（0x0751 / 0x0741 / 0x07A5 / 0x07AB，4 读）。
    /// 只在「控制 / 实验性」页打开时刷一次（`/api/fan/refresh`），TTL 给足，
    /// 免得 snapshot 每秒的请求把它反复拉起来。
    private static func cachedMode(force: Bool = false) -> [String: Any] {
        if !force, let v = fanCache.get("mode", 120.0) as? [String: Any] { return v }
        if modeFlight.tryClaim() {
            let v = FanControl.shared.modeStatus()
            fanCache.put("mode", v)
            modeFlight.finish()
            return v
        }
        modeFlight.wait()
        if let v = fanCache.get("mode", 120.0) as? [String: Any] { return v }
        let v = FanControl.shared.modeStatus()
        fanCache.put("mode", v)
        return v
    }

    /// 启动时读一次 EC（模式组 + 开关组 + 充电阈值）填进缓存，**不续租**。
    /// 供 helper 启动序列用：为「app 记忆对账」准备一份真实硬件快照，
    /// 只读这一次，之后由按需读取接管。
    static func primeCache() {
        guard FanControl.kextLoaded() else { return }
        _ = cachedMode(force: true)
        _ = cachedMisc(force: true)
        _ = cachedCharge(force: true)
    }

    /// 给 FanCurveController 用：**不产生任何 EC 读**。    /// 曲线只需要温度判断加减速，温度取 SMC / NVAccel；转速只取缓存（没有就是 0），
    /// 不会为了它去唤醒 EC。
    static func fanStatusCached() -> [String: Any] {
        var v = (fanCache.get("live", 86_400) as? [String: Any]) ?? [:]
        v["temp_cpu"] = TempSources.cpuCelsius()
        v["temp_gpu"] = TempSources.gpuCelsius()
        if v["rpm_cpu"] == nil { v["rpm_cpu"] = 0 }
        if v["rpm_gpu"] == nil { v["rpm_gpu"] = 0 }
        return v
    }

    /// 系统开关组（0x074E / 0x07A4 / 0x07A6 / 0x07A3 / 0x07C4 / 0x0768 / 0x045B，7 读）。
    /// 2.8.15：不再 8 秒一轮 —— 只有「控制 / 实验性」页打开时刷一次，TTL 给足。
    private static func cachedMisc(force: Bool = false) -> [String: Any] {
        if !force, let v = fanCache.get("misc", 120.0) as? [String: Any] { return v }
        if miscFlight.tryClaim() {
            let v = FanControl.shared.miscStatus()
            fanCache.put("misc", v)
            miscFlight.finish()
            return v
        }
        miscFlight.wait()
        if let v = fanCache.get("misc", 120.0) as? [String: Any] { return v }
        let v = FanControl.shared.miscStatus()
        fanCache.put("misc", v)
        return v
    }

    /// 海岸灯状态（4 次 EC 读 ≈0.4s）。以前每次 /api/lightbar 都现读，
    /// slowLoop 5s 一轮就是常驻 0.4s 的 EC 占用。加 5s TTL 缓存；
    /// POST 写操作会 invalidateFanCache，改完立刻能看到新值。
    private static func cachedLightbar() -> [String: Any]? {
        if let v = fanCache.get("lightbar", 5.0) as? [String: Any] { return v }
        if lightbarFlight.tryClaim() {
            let v = FanControl.shared.lightbarStatus()
            if v != nil { fanCache.put("lightbar", v!) }
            lightbarFlight.finish()
            return v
        }
        lightbarFlight.wait()
        if let v = fanCache.get("lightbar", 5.0) as? [String: Any] { return v }
        return FanControl.shared.lightbarStatus()
    }

    /// 充电阈值（1 次 EC 读）。2.8.15：不再 30 秒轮询，
    /// 只在「控制」页打开 / 修改阈值后刷新（`force`）。
    private static func cachedCharge(force: Bool = false) -> [String: Any]? {
        if !force, let v = fanCache.get("charge", 120.0) as? [String: Any] { return v }
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
    // /api/fan 在 0.19s 与 1.45s 之间跳。改成后台采样，GET 永远命中热缓存，
    // 延迟恒定在几十毫秒。
    //
    // 2.8.0 修了一个自己把自己坑了的漏洞：采样器原来调 cachedFanStatus()，
    // 而那个函数自己检查 TTL（5s）—— 采样间隔只有 2s，于是除了 TTL 到期
    // 那一下，采样器后续迭代全部命中缓存、根本不重扫。实际刷新周期退化
    // 成 5s，且刷新时机由「哪个请求先踩到过期」决定：那个请求独自吃 1.1s，
    // 若 UI 轮询恰好也到，两把扫描叠加成 2.2s（实测 elapsed_ms 32↔2203ms 跳）。
    // 现在采样器走 force 直扫（绕开 TTL），并和请求扫描共用单飞盒合并。
    //
    // 2.8.15 起改为「需求驱动」：采样器只在租约有效时刷实时转速（2 读），
    // 没人在看就完全静默。misc / charge 不再由采样器轮询，见 cachedMisc / cachedCharge。

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
                // 2.8.15：只有「有页面正在看转速」时才读 EC（租约由 UI 续）。
                // 租约过期 → 这轮一次 EC 读都不做，只睡 1 秒再查。
                if FanControl.kextLoaded(), liveLease.active {
                    _ = cachedLive(force: true)
                }
                // 按周期调度：扫描本身要时间，若「扫完再固定睡 2s」，
                // 实际周期会被拉长并超过 TTL，导致请求自己又扫一遍、和采样器撞车。
                let idle = !liveLease.active
                let interval = idle ? 1.0 : samplerInterval
                let spent = Date().timeIntervalSince(t0)
                let wait = max(0.2, interval - spent)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: 散热（对应 Python fan_state / do_fan）

    /// 风扇状态。
    ///
    /// - `fresh == false`（默认；`/api/snapshot` 每秒走这条）：**不产生 EC 读**，
    ///   实时组 / 模式组 / 开关组全部只取缓存。
    /// - `fresh == true`：重读实时组（2 读）+ 模式组（4 读）+ 开关组（7 读）。
    ///   `renewLease == true` 才续转速采样租约；「控制 / 实验性」页进页读一次设置
    ///   用 `renewLease: false` —— 只读一次当前设置，不拉起 10 秒转速采样。
    static func fanState(fresh: Bool = false, renewLease: Bool = false) -> [String: Any] {
        let loaded = FanControl.kextLoaded()
        let st = FanStateStore.load() ?? ["mode": "normal", "level": 0]
        var out: [String: Any] = [
            "available": loaded,
            "mode": st["mode"] as? String ?? "normal",
            "level": st["level"] as? Int ?? 0,
        ]
        if loaded {
            if fresh && renewLease { touchLiveLease() }
            var merged: [String: Any]
            let mode: [String: Any]
            if fresh {
                merged = cachedLive(force: true)
                mode = cachedMode(force: true)
            } else {
                // 非 fresh 路径不主动读 EC：优先取缓存（不限 TTL），
                // 只有缓存本来就缺（刚启动 / 写操作后清过）才补读一次，
                // 补完继续走缓存 —— 不是周期轮询。温度每次重取 SMC。
                merged = (fanCache.get("live", 86_400) as? [String: Any]) ?? cachedLive()
                mode = (fanCache.get("mode", 86_400) as? [String: Any]) ?? cachedMode()
                merged["temp_cpu"] = TempSources.cpuCelsius()
                merged["temp_gpu"] = TempSources.gpuCelsius()
            }
            merged.merge(mode) { _, b in b }
            out["live"] = merged
            // 界面以 EC 里的真实状态为准，保存的设置只用于「重启后自动恢复」
            out["actual"] = mode["actual"] ?? (st["mode"] as? String ?? "normal")
            out["actual_level"] = mode["actual_level"] ?? (st["level"] as? Int ?? 0)
            out["modeindex"] = mode["modeindex"] ?? NSNull()
            // 2.7.10：散热档 / 功耗档分别给出（0x7AB 高低半字节）。
            // 界面不再从 0x751 猜模式 —— 0xA0 在 OEM 枚举里叫 User_HiMode。
            out["thermal_level"] = mode["thermal_level"] ?? NSNull()
            out["power_level"] = mode["power_level"] ?? NSNull()
            out["benchmark"] = mode["benchmark"] ?? false
            let actual = out["actual"] as? String ?? "normal"
            let actualLevel = out["actual_level"] as? Int ?? 0
            let savedMode = st["mode"] as? String ?? "normal"
            let savedLevel = st["level"] as? Int ?? 0
            out["synced"] = (actual == savedMode && (actual != "custom" || actualLevel == savedLevel))
            if fresh {
                if let charge = cachedCharge(force: true) { out["charge"] = charge }
                out["misc"] = cachedMisc(force: true)
            } else {
                if let c = (fanCache.get("charge", 86_400) as? [String: Any]) ?? cachedCharge() {
                    out["charge"] = c
                }
                out["misc"] = (fanCache.get("misc", 86_400) as? [String: Any]) ?? cachedMisc()
            }
            out["curve"] = FanCurveController.shared.snapshot()
        } else {
            out["hint"] = ("TongfangFan.kext 未加载 —— 到「控制」或「实验性」页点「立即安装」"
                + "（kext 已内嵌在 app 里，只需输入一次管理员密码）")
        }
        return out
    }

    static func doFan(_ params: [String: Any]) -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["ok": false, "error": "TongfangFan.kext 未加载",
                    "hint": "到「控制」或「实验性」页点「立即安装」（kext 内嵌在 app 里）后重试"]
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
                return ["ok": false, "error": "modeindex 必须是 0x11(高性能)/0x22(平衡)/0x33(节能)"]
            }
            // 方案 A（2026-10-21 修复）：性能模式是「EC 接管」语义。若当前跑着曲线模式，
            // FanCurveController 正攥着 FAN_CTRL 手动权（0x0741 手动门开着），此时只写
            // 0x07AB 会出现「toast 报成功、风扇纹丝不动」——EC 在手动门关闭时才认模式索引。
            // 必须先交还控制权：停曲线控制环 → setMode("normal") 关手动门 + 补写 0x751=0xA0。
            //
            // 2.7.10：真正干活改成 applyPowerPreset —— 包内实测原厂点「系统功耗设置」
            // 是「功耗 + 散热两组一起写」（PL1/PL2 → 0x78B → 0x7A6 → 0x751 → 0x7A5 →
            // 0x7AB → 0x7B{n} 收尾）。只写 0x7AB 会让散热档不跟、曲线索引槽停在旧值。
            let curveWasActive = FanCurveController.shared.active
            FanCurveController.shared.stop()
            _ = fc.setMode("normal")
            let power = code >> 4
            let thermalArg = params["thermal_level"] as? Int ?? 0
            let r = fc.applyPowerPreset(power, thermalLevel: thermalArg)
            if r?.ok != true, r?.status == -2 {
                return ["ok": false, "error": "基准模式进行中，「系统功耗设置」整组不可用，请先取消基准模式",
                        "benchmark": true]
            }
            if r?.ok == true { FanStateStore.save("normal", 0) }
            let cur = (fc.ecRead(EC.fanModeIndex)?.result ?? 0) & 0xFF
            let ctrl3 = (fc.ecRead(EC.ctrl3)?.result ?? 0) & 0xFF
            let fanCtrl = (fc.ecRead(EC.fanCtrl)?.result ?? 0) & 0xFF
            var out: [String: Any] = ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(),
                                      "modeindex": cur,
                                      "thermal_level": cur & 0x0F, "power_level": (cur >> 4) & 0x0F,
                                      "ap_oem3": ctrl3, "fan_ctrl": fanCtrl,
                                      "curve_stopped": curveWasActive]
            if r?.ok != true {
                // 2.8.12：区分「EC 风扇异常位」与「写入没落地」——前者只能重启复位，
                // 后者多半是 EC 连接陈旧（内部已自动重连重试一次）。
                if r?.status == -3 {
                    out["error"] = "EC 报风扇异常位（0x741 bit5）：整片风扇寄存器拒写，需重启或断电一次"
                    out["fan_abnormal"] = true
                } else {
                    out["error"] = "0x7AB 未落地（\(r?.steps ?? "无返回")）"
                }
            }
            return out
        }

        // 散热模式（0x7AB 低半字节 1 性能 / 2 标准 / 3 安静）
        if let lv = params["thermal"] as? Int {
            guard (1...3).contains(lv) else {
                return ["ok": false, "error": "thermal 必须是 1(性能)/2(标准)/3(安静)"]
            }
            let curveWasActive = FanCurveController.shared.active
            FanCurveController.shared.stop()
            let r = fc.setThermalLevel(lv)
            if r?.status == -2 {
                return ["ok": false, "error": "基准模式进行中，「散热模式」不可切换，请先取消基准模式",
                        "benchmark": true]
            }
            if r?.ok == true { FanStateStore.save("normal", 0) }
            let cur = (fc.ecRead(EC.fanModeIndex)?.result ?? 0) & 0xFF
            var out: [String: Any] = ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(),
                                      "thermal_level": cur & 0x0F, "power_level": (cur >> 4) & 0x0F,
                                      "curve_stopped": curveWasActive]
            if r?.ok != true {
                if r?.status == -3 {
                    out["error"] = "EC 报风扇异常位（0x741 bit5）：整片风扇寄存器拒写，需重启或断电一次"
                    out["fan_abnormal"] = true
                } else {
                    out["error"] = "0x7AB 未落地（\(r?.steps ?? "无返回")）"
                }
            }
            return out
        }

        // 基准模式（顶层覆盖态：0x741 手动门 + 0x751=0x40）
        if let on = params["benchmark"] as? Bool {
            FanCurveController.shared.stop()
            let r = fc.setBenchmarkMode(on)
            return ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(), "benchmark": on]
        }

        // 键盘 Fn 锁 / 触控板 / 超频动态温控 / 风扇行为（qc71_laptop 交叉验证，
        // 2026-10-21）：都是读-改-写单位，与官方控制台同路径
        if let v = params["fn_lock"] as? Bool {
            guard let r = fc.setFnLock(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fn_lock": v]
        }
        // 2.7.10：0x7A4 bit3 是 OSD 显示（不是 Fn+Esc）。原厂由服务补写，复刻版直接写。
        if let v = params["osd"] as? Bool {
            guard let r = fc.setOsd(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "osd": v]
        }
        if let v = params["keyboard_backlight"] as? Bool {
            // 包内 SystemView 的关键一条（用户 X15 实测）：TurnOff 关掉的是「灯效」，
            // 之后单发 SetBrightness 是点不亮的 —— 开的时候必须重新下发一次完整灯效。
            // 所以这条命令是「EC 状态位 + 灯效通道」两段式，缺一段就会出现
            // 「开关是开的但键盘全黑」。
            let ec = fc.setKeyboardBacklightState(v)
            var led: [String: Any]
            if v {
                led = RGBProfile.apply()
            } else {
                var kr = -1
                if let kb = try? KeyboardRGB().open() {
                    kr = kb.disable()
                    kb.close()
                }
                led = ["ok": kr == 0, "kr": kr]
            }
            return ["ok": ec?.ok ?? false, "reply": ec?.dict ?? [:],
                    "keyboard_backlight": v,
                    "led": led,
                    "note": v ? "已重新下发灯效（单改亮度点不亮）" : "已发 CTRL_OFF 熄灯"]
        }
        if let v = params["win_lock"] as? Bool {
            guard let r = fc.setWinKeyLock(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "win_lock": v]
        }
        if let v = params["silent_mode"] as? Bool {
            guard let r = fc.setSilentMode(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "silent_mode": v]
        }
        if params["usb_charger"] != nil {
            guard let r = fc.triggerUsbCharger() else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "usb_charger": true,
                    "note": "0x767 bit4 是 toggle 触发位，且 0x768 无对应状态位，无法回读确认"]
        }
        if params["fan_boost"] as? Bool == true {
            guard let r = fc.triggerFanBoost() else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fan_boost": true]
        }
        // 2.7.10：0x7A3 bit6 是「禁用被动散热模式」（包内三次实测双向确认），
        // 不是「风扇常转」——旧参数名 fan_always_on 已废弃。
        if let v = params["passive_cooling_disabled"] as? Bool {
            guard let r = fc.setPassiveCooling(disabled: v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "passive_cooling_disabled": v]
        }
        if params["touchpad_toggle"] as? Bool == true {
            // 2.7.8：触控板左上角双击手势 → 原子翻转。
            //
            // 不能在 app 侧拿 monitor 的 1 秒轮询缓存算反值：连点两次时第二次读到的
            // 还是旧状态，算出同一个目标值，表现为「双击了没反应」。这里以 helper
            // 进程内的真实独占状态为准（TrackpadLock.locked 本身就是真相），
            // 读—翻转—写入一步做完，不受轮询延迟影响。
            let want = !TrackpadLock.locked
            var out = TrackpadLock.set(want)
            out["touchpad"] = want
            out["toggled"] = true
            out["via"] = "hid-seize"
            return out
        }
        if let v = params["touchpad"] as? Bool {
            // 2.7.7：EC 的 CTRL_4 bit6 在这台机器上是**无效位** —— 写入成功、回读保持，
            // 但设备树毫无变化（触控板走 I2C + VoodooI2C 虚拟设备，EC 管不到）。
            // 改用输入层独占：seize VoodooInput 发布的虚拟触控板，系统就收不到触摸了。
            // 需要 root，所以只有 helper（LaunchDaemon）里调用才会成功。
            let res = TrackpadLock.set(!v)
            var out = res
            out["touchpad"] = v
            out["via"] = "hid-seize"
            return out
        }
        if let v = params["overboost_dyn_temp"] as? Bool {
            guard let r = fc.setOverboostDynTemp(enabled: v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "overboost_dyn_temp": v]
        }
        if let v = params["fan_reduced_duty"] as? Bool {
            guard let r = fc.setFanReducedDuty(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "fan_reduced_duty": v]
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

    /// 海岸灯状态。
    ///
    /// 【2.8.12 修】以前只有 available 一个布尔，凡是 false 界面就一律显示
    /// 「需要 TongfangFan.kext，或当前机型没有海岸灯带」——用户明明看到 kext
    /// 在内核里（kmutil showloaded 有 com.macconsole.TongfangFan），界面却说没装，
    /// 于是以为整个硬件功能都没了。
    /// 现在带 `reason`：
    ///   ok / stale（EC 本次读失败，沿用上次成功值）/ read（从未读成功）/ kext（真没装）
    /// 并且保留上一次成功读数 —— EC 邮箱被采样器占着时不会让整张卡塌成一句提示。
    private static var lightbarLastGood: [String: Any]?

    static func lightbarState() -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["available": false, "reason": "kext",
                    "note": "TongfangFan.kext 未加载，EC 不可达"]
        }
        if let st = FanControl.shared.lightbarStatus() {
            var out = st
            out["available"] = true
            out["reason"] = "ok"
            lightbarLastGood = st
            return out
        }
        if let last = lightbarLastGood {
            var out = last
            out["available"] = true
            out["reason"] = "stale"
            out["note"] = "EC 本次读失败，显示上次读数"
            return out
        }
        return ["available": false, "reason": "read",
                "note": "EC 读失败（EC 正忙或本机没有海岸灯带），稍后自动重试"]
    }

    static func doLightbar(_ params: [String: Any]) -> [String: Any] {
        guard FanControl.kextLoaded() else {
            return ["ok": false, "error": "TongfangFan.kext 未加载"]
        }
        // 2.7.6：hex 变成可选。切「轮换 / 关闭」时不再把颜色写成 000000，
        // 这样用户上次挑的固定色会被保留，来回切不会丢。
        var rgb: [Int]? = nil
        if let raw = params["hex"] as? String {
            let hx = raw.replacingOccurrences(of: "#", with: "")
            guard hx.count == 6, hx.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                return ["ok": false, "error": "hex 颜色无效"]
            }
            rgb = RGBUtil.hexToRgb(hx)
        }

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
            ["name": "显卡信息", "detail": "system_profiler，iGPU + RTX 2070S 均可见"],
            ["name": "电池", "detail": "IORegistry AppleSmartBattery + pmset"],
            ["name": "磁盘占用", "detail": "df，含 Word / Windows 分区"],
            ["name": "键盘灯控制", "detail": "ITE 8291 (048d:6004/6006/600B/CE00，原厂 PID 白名单) HID Feature 报告，已实测可写"],
        ]
        var partial: [[String: Any]] = [
            ["name": "电池健康度", "detail": "VirtualSMC 对电池建模较粗：循环次数恒为 0、"
                + "设计容量 = 最大容量，容量读数可信度有限"],
        ]

        if fanKext {
            usable.append(["name": "散热模式（性能 / 标准 / 安静）",
                           "detail": "对应原厂「散热设置」。写 EC 0x0751（性能 0x00 / 标准·安静 0xA0）"
                + " + 0x07A5（功耗档+散热档共同决定）"
                + " + 0x07AB 低半字节（1/2/3）+ 该功耗档自己的曲线索引槽 0x7B{n-1}。"
                + "四个寄存器一起写才对 —— 0x7AB 是 EC 的「整组设置应用完毕」收尾信号，"
                + "只写 0x751 会在秒级内被 EC 覆盖回去"])
            usable.append(["name": "基准模式（增压 5000+ RPM）",
                           "detail": "入口是手动门 0x0741 bit0：先断言门（写事件，不是状态位），"
                + "再 0x751←0x40，EC 自己把 0x768 置成 0x04，实测 2642→5615 RPM。"
                + "关闭必须反序：先 0x751←0x00 再清门，EC 随即把 0x751 自己改回 0xA0。"
                + "顺序反了会触发 FAN_ABNORMAL（0x741 变 0xA3），整片风扇寄存器拒写，只能重启恢复"])
            usable.append(["name": "风扇转速与温度读数",
                           "detail": "绕开 SMC，直接读 EC 0x046C(CPU) / 0x0464(GPU)（大端，实测 "
                + ecLiveRPMText() + "），CPU 温度读 0x043E。"
                + "dGPU 温度自 2.7.6 起改读 NVAccel 上报的核心温度"
                + "（驱动侧 TSENS → PerformanceStatistics[\"Temperature(C)\"]，PR #323），"
                + "不再轮询 EC 0x044F。"
                + "实测两路 PWM 数值始终相同（12 进程满载全程 80→177 一致），"
                + "EC 给两颗风扇的是同一个占空比；转速差约 12% 来自风扇个体/型号差异，"
                + "不是接反。两颗风扇的归属由用户实物确认：他亲手换过 CPU 风扇，"
                + "转速较高的 0x046C 才是 CPU 风扇（2026-10-16 修正，之前标反）。"
                + "换掉 0x044F 的依据：同期 0x043E 从 64℃ 升到 89℃ 而 0x044F 仅 60→62℃，"
                + "说明它是 GPU 附近的板级环境温度，不是核心温度"])
            let prob = FanControl.shared.ecProbe()
            let mi = Int(prob["modeindex"] as? UInt8 ?? 0)
            let pLabel = ["高性能", "平衡", "节能"]
            let tLabel = ["性能", "标准", "安静"]
            let pl = Int(prob["power_level"] as? Int ?? 0)
            let tl = Int(prob["thermal_level"] as? Int ?? 0)
            let pName = (1...3).contains(pl) ? pLabel[pl - 1] : "未知"
            let tName = (1...3).contains(tl) ? tLabel[tl - 1] : "未知"
            usable.append(["name": "系统功耗设置（高性能 / 平衡 / 节能）",
                           "detail": "对应原厂「系统功耗设置」。写 EC 0x07AB（MyFanCCI_Mode_Index）"
                + " = (功耗档<<4)|散热档，即 0x11/0x22/0x33，"
                + "就是 BIOS「Power Mode」和键盘上那颗模式按钮的同一个开关，"
                + "键盘灯实时跟随（高性能=2 灯、平衡=1 灯、节能=不亮）。"
                + "原厂点这一档是「功耗 + 散热两组一起写」：PL1 0x783 / PL2 0x784 / "
                + "0x78B / 0x7A6 / 0x751 / 0x7A5 / 0x7AB / 0x7B{n-1}，我们照整张表写。"
                + "12 子进程满载实测：高性能档 CPU 算力最快、风扇随温度爬升 29→44%；"
                + "平衡档风扇最猛（78℃ 就 41~47%）、算力慢 4~5%；"
                + "节能档风扇压在 31% 不动、算力慢 5~9%（A/B/C/A 交叉复现）。"
                + String(format: "当前档位：0x%02X（%@ + 散热 %@）", mi, pName, tName)])
            let charge = prob["charge"] as? Int ?? 100
            usable.append(["name": "电池充电阈值",
                           "detail": "EC 0x07B9，值为 0x80|百分比（bit7 是「限制启用」，低 7 位是百分比），"
                + "0x00 = 不限制。实测 0xD0=80%、0xBC=60%；设 80 → 回读 0xD0，"
                + "bit7 reached 置位后停止充电。当前阈值 \(charge)%"])
            let misc = FanControl.shared.miscStatus()
            usable.append(["name": "系统调整（原厂 FastSwitch 页）",
                           "detail": "键盘背光 EC 0x07C4 bit6 / OSD 显示 0x07A4 bit3 / "
                + "Win 键锁定 0x0767 bit0 触发 → 0x0768 bit0 回读 / "
                + "安静模式 0x0767 bit3 触发 → 0x045B 回读 / "
                + "禁用被动散热 0x07A3 bit6。"
                + "0x767 是 **toggle** 语义（写一次翻一次，写 0x00 无效），"
                + "所以每次写前先读状态；状态位要 ~600ms 才跟上，这里轮询最多 1.5 秒。"
                + String(format: "当前：背光%@ / OSD %@ / Win锁%@ / 安静%@ / 禁用被动散热%@",
                         (misc["keyboard_backlight"] as? Bool ?? false) ? "开" : "关",
                         (misc["osd"] as? Bool ?? false) ? "开" : "关",
                         (misc["win_lock"] as? Bool ?? false) ? "锁定" : "解锁",
                         (misc["silent_mode"] as? Bool ?? false) ? "开" : "关",
                         (misc["passive_cooling_disabled"] as? Bool ?? false) ? "开" : "关")])
            usable.append(["name": "键盘与风扇行为（非原厂 / 实验位）",
                           "detail": "EC 0x074E bit4（Fn 锁）/ 0x07A6 bit6（触控板开关）/ "
                + "0x07A6 bit1（超频动态温控）/ 0x07A3 bit5（风扇降低占空比），"
                + "全部读-改-写单位，qc71_laptop 同族开源驱动交叉验证（sysfs 同款属性）。"
                + "原厂 UI 没有这些入口，属于复刻版追加的实验能力。"
                + String(format: "当前：Fn锁%@ / 触控板%@ / 动态温控%@ / 降载%@",
                         (misc["fn_lock"] as? Bool ?? false) ? "开" : "关",
                         (misc["touchpad_off"] as? Bool ?? false) ? "禁用" : "启用",
                         (misc["overboost_dyn_temp_off"] as? Bool ?? false) ? "关" : "开",
                         (misc["fan_reduced_duty"] as? Bool ?? false) ? "开" : "关")])
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
            partial.append(["name": "散热模式 / 系统功耗设置 / 系统调整 / 风扇转速 / 充电阈值 / 海岸灯",
                            "detail": "方案已备好（TongfangFan.kext），首次运行 app 会自动安装："
                + "散热模式（性能/标准/安静）+ 基准模式、系统功耗设置（高性能/平衡/节能）、"
                + "系统调整（键盘背光/海岸灯/Win 键锁/Fn 锁/OSD/安静模式/禁用被动散热）、"
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
                 "detail": "dGPU 占用率走 NVAccel 的 RM 控制接口"
                    + "（issue #324 的 GPUMON perfmon），iGPU 走 IOAccelerator 的 Device Utilization %；"
                    + "两者都是引擎忙碌时间占比，不是显存占用率。"
                    + "GPU 功耗 macOS 下没有用户态接口，本机未接入。"
                    + "iGPU 与 CPU 同封装、本机没有它的独立热敏"
                    + "（SMC 无 TG* 键），界面上 iGPU 那一格温度是 CPU 封装温度的参考值"],
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
        // 2.8.15：启动时**读一次** EC（模式组 + 系统开关组 + 充电阈值），填进缓存。
        // 这一步是「app 记忆对账」的数据源 —— UIControlPrefs.mismatches 拿它跟
        // 本地记忆比一次，不一致就把记忆值写回 EC。只读这一次，之后不再轮询。
        primeCache()
        // 启动时恢复上次保存的键盘灯效（含白平衡增益）。
        //
        // 【2.8.12】以前这里恢复一次，另外还有一条 com.macconsole.rgbrestore 登录项
        // （/bin/bash 跑 restore_rgb.sh）在登录时再恢复一次 —— 同一件事做两遍，
        // 用户登录项列表里还多一个 bash。现在登录项已删除，恢复完全由 helper 负责；
        // 把「开机初期 USB 键盘还没枚举完」的重试也从脚本搬到这里（后台队列，
        // 不拖住登录项清理这些后续动作）。
        DispatchQueue.global(qos: .utility).async {
            for attempt in 1...30 {
                let rr = RGBProfile.apply()
                if rr["ok"] as? Bool == true {
                    print("键盘灯效已恢复（第 \(attempt) 次）: mode=\(rr["mode"] as? String ?? "")")
                    return
                }
                let err = rr["error"] as? String ?? "\(rr)"
                // 没存过配置就没什么可恢复的，别重试
                if err.contains("没有已保存的灯效配置") {
                    print("键盘灯效无需恢复：还没有保存过配置")
                    return
                }
                if attempt == 1 || attempt % 5 == 0 {
                    print("键盘灯效恢复第 \(attempt) 次未成功：\(err)")
                }
                if attempt == 30 {
                    print("键盘灯效重试 30 次仍未恢复，放弃（不影响其它功能）")
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        // 登录项
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
