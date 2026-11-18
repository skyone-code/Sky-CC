//
//  NativeAPI.swift
//  Sky CC —— 本地后端 API 层（原生移植）
//
//  对应 Python 版 app-resources/server.py 的全部接口逻辑。JSON 输出形状与
//  Python 版逐字段一致（前端 web UI 与 SwiftUI 都按原形状解析）。
//
//  覆盖：
//    GET  /api/overview /api/sensors /api/battery /api/disks /api/processes
//         /api/rgb /api/fan /api/lightbar /api/all
//    POST /api/control /api/fan /api/lightbar /api/rgb
//         /api/rgb/apply /api/rgb/save
//         /api/ec/read
//
//  2026-11-18 清理：移除无 UI 的隐藏接口 —— /api/hid、/api/capability、
//  RGB 白平衡三接口（whitecal / whitegain / reset）、/api/rgb/forget、
//  doControl 的 caffeinate，以及 doFan 的 keyboard_backlight / silent_mode /
//  overboost_dyn_temp / fan_reduced_duty 四个分支。

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
        case "/api/rgb":        return rgbState()
        case "/api/fan":        return fanState()
        // 「AP 心跳」开关（灯效页，2026-11-13）：0x741 bit0 的真实状态。
        // 单独开一个端点而不是塞进 /api/fan —— 后者一次要读 17 个寄存器（≈1.1s），
        // 为了一位开关去加第 18 读不划算；这里只有一次读（~65ms）。
        case "/api/apbeat":
            let s = FanControl.shared.appPresentState()
            return ["ok": true, "ap_present": s.on, "ctrl1": Int(s.raw)]
        // Fn 锁实时状态（2026-11-17）：现读 0x074E / 0x07A4 两个字节（~130 ms），
        // **不走** /api/fan 那份 24h 的 misc 缓存 —— Fn+Esc 是硬件事件，
        // 缓存不会跟着变，设置页的开关就会和真实功能脱钩。
        case "/api/fnlock":
            guard FanControl.kextLoaded() else {
                return ["ok": true, "available": false, "fn_lock": false]
            }
            return FanControl.shared.fnLockState()
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
        case "/api/all":        return allPayload(slim: false)
        case "/api/snapshot":   return allPayload(slim: true)
        // GPU 路由开关状态（是否注入 gpu-router.dylib + 例外名单 + dylib 就位情况）
        case "/api/gpu":        return NativeGPU.state()
        // 触控板开关的真实状态（2026-11-17）：
        // 必须由**调用的进程自己读** —— HID open 需要「输入监控」授权，
        // helper（launchd 起的 LaunchAgent）没有，读到的永远是「未禁用」。
        case "/api/touchpad":   return TrackpadLock.status()
        // 独显利用率的「有没有人在看」信号 —— 2026-10-28 起**已废弃**，保留空壳。
        //
        // 旧实现在这里开 RM 通道、一次拷 55,888 字节回来，所以必须有「有人看才 1 秒一次、
        // 没人看降到 10 秒」的节流，app 侧还得经 XPC 把信号送进 helper。
        // 驱动 2.6.3 自己每秒采样并发布到 PerformanceStatistics，我们只读 IORegistry，
        // 一次微秒级、无内核锁，节流完全没必要了。
        // 两条路由留着只为「老 app + 新 helper」升级过渡期不报 404。
        case "/api/dgpu/want", "/api/dgpu/idle":
            return ["ok": true, "deprecated": true]
        default:
            return nil
        }
    }

    /// 全量快照（2.7.0 起统一入口）
    ///
    /// `/api/all`   = 全部字段（含 rgb / lightbar，给「全部信息」页）
    /// `/api/snapshot` = 高频精简版（去掉 GPU 原始统计与 HID/能力矩阵，给 1 秒轮询）
    ///
    /// 两个都包含 fan（走后台采样器的热缓存，不触发 EC 冷扫描），所以 UI 一次
    /// XPC 就能拿到所有卡片要的字段，不再并发打 5 个接口。
    private static func allPayload(slim: Bool) -> [String: Any] {
        let t0 = Date()
        var payload: [String: Any] = [:]
        payload["overview"] = NativeSystem.overview(slim: slim)
        payload["sensors"] = SMCSnapshot.snapshot()
        payload["battery"] = NativeSystem.battery(cached: true)
        payload["disks"] = NativeSystem.disks(cached: true)
        payload["processes"] = NativeSystem.processes(limit: slim ? 15 : 40)
        payload["fan"] = fanState()
        payload["volume"] = volumeState()
        payload["elapsed_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        if !slim {
            payload["rgb"] = rgbState()
            payload["lightbar"] = lightbarState()
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
        // GPU 路由：mode = "dgpu" 开 / "off" 关；exclude 增删 per-app 例外。
        // 只改 launchd 环境变量与策略文件，不碰 kext，也不需要 root。
        case "/api/gpu/mode":             return NativeGPU.setMode(params["mode"] as? String ?? "")
        case "/api/gpu/exclude":
            let on = (params["on"] as? NSNumber)?.boolValue
                ?? (params["on"] as? Bool) ?? false
            return NativeGPU.setExclude(params["bundle"] as? String ?? "", on: on)
        case "/api/control":              return doControl(params["action"] as? String ?? "", params)
        case "/api/fan":                  return doFan(params)
        case "/api/lightbar":             return doLightbar(params)
        case "/api/rgb":                  return doRGB(params)
        case "/api/rgb/apply":
            // 用户点「开」：先落总开关状态（enabled=true），再把存档灯效覆盖回去
            _ = RGBProfile.setEnabled(true)
            return RGBProfile.apply()
        case "/api/rgb/save":
            guard let prof = params["profile"] as? [String: Any], !prof.isEmpty else {
                return ["ok": false, "error": "profile 无效"]
            }
            return ["ok": RGBProfile.save(prof), "profile": prof]
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
        if !KeyboardRGB.available() {
            return ["available": false, "profile": prof ?? NSNull()]
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
                    "firmware": cachedFirmware(kb),
                    "profile": prof ?? NSNull(),
                    "profile_path": profilePath()]
        } catch {
            return ["available": false, "error": "\(error)",
                    "profile": prof ?? NSNull()]
        }
    }

    /// 固件版本终身不变，缓存起来（2026-11-18）。
    /// 之前每拍都发 0x80 查询 —— 除了拖慢轮询，还会把芯片 feature 缓冲里的
    /// 关灯报文覆盖成查询报文，直接导致 getState 的 off 判定被破坏（详见
    /// getState 的修复注释）。缓存后稳态零额外 HID 写入。
    private static let fwLock = NSLock()
    private static var fwCache: [String: Any]?

    private static func cachedFirmware(_ kb: KeyboardRGB) -> [String: Any] {
        fwLock.lock()
        defer { fwLock.unlock() }
        if let c = fwCache { return c }
        let fw = kb.getFirmware()
        fwCache = fw
        return fw
    }

    private static func profilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SkyCC/rgb_profile.json").path
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

        case "rgb":
            return doRGB(params)

        default:
            return ["ok": false, "error": "未知动作: \(action)"]
        }
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
                let styleName = params["style"] as? String ?? "rainbow"
                if let e = KeyboardCatalog.effect(forName: styleName), e.isSoftwareAnimation {
                    // AP 软件动画（霓虹/堆叠/冲击）没有固件效果号，下发只会把芯片推进
                    // 未定义态。真正画面由界面侧 `APEffectEngine` 逐帧走 matrix 通道。
                    result = ["ok": true, "mode": "effect", "ap": true,
                              "style": KeyboardCatalog.key(for: e),
                              "slots": palette?.count ?? 0, "effect_code": 0]
                } else {
                    let kr = try kb.setStyle(name: styleName,
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
                              "style": styleName,
                              "slots": palette?.count ?? 0,
                              "effect_code": KeyboardCatalog.effect(forName: styleName)?.rawValue ?? 0,
                              "hex": hexOut]
                }
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
                // 2026-11-11：AP 软件动画（霓虹/堆叠/冲击）每帧都带亮度，
                // 不然切到这两个效果时亮度会沿音乐律动上次留下的值。
                if let b = params["brightness"] as? Int { RGBActivity.zoneBrightness = b }
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

            // 2026-10-26（用户要求）：把「当前画面」提交进芯片 NVM。
            //
            // 原厂 `Set_ITE_Effect_Type_StaticMode` 的最后一步是 `HID_Set_Picture_12H(Save)`，
            // 我们一直缺这一步 —— 结果就是 NVM 里留的还是出厂亮度 36：灯被固件闲置熄掉后
            // 按一下键，芯片只会还你一个 36 的暗白。补上之后 NVM 才记住用户设的亮度。
            //
            // 排除项：
            //   · `off`  —— 提交进去会让键盘冷启动就是黑的；
            //   · `zones` / `matrix` —— 音乐律动每 83ms 一帧，每帧写 NVM 等于毁 flash；
            //   · save=0 —— 保活重放、频谱帧都走这个，绝不能碰 NVM。
            let wantSave = params["save"] as? Int ?? 1
            if wantSave == 1, result["ok"] as? Bool == true,
               ["effect", "color", "brightness", "keymap"].contains(mode) {
                usleep(20_000)
                _ = kb.setPicture(saved: 1)
            }
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

        // 2026-10-26（用户要求）：跟原厂对齐 —— 应用灯效时把 EC 状态位 0x07C4 bit6 一并置上，
        // 关灯时一并清掉。
        //
        // 原厂是「ControlCenter.exe 写注册表 → LaunchServGM 服务写 EC」的两段式，
        // macOS 没有那个常驻服务，所以在这里补写（读-改-写单 bit，不碰同字节的其它位）。
        //
        // zones / matrix 是流式刷帧（音乐律动每帧都走这里），**绝不能每帧写 EC** ——
        // 单次 EC 操作约 65ms，写进去帧率会掉到个位数；而这两种模式本来也只在灯亮着时才跑。
        if result["ok"] as? Bool == true, FanControl.kextLoaded() {
            let ecOn: Bool?
            switch mode {
            case "off":
                ecOn = false
            case "effect", "color", "keymap", "brightness":
                ecOn = true
            default:
                ecOn = nil
            }
            if let on = ecOn {
                result["ec_bit6"] = FanControl.shared.setKeyboardBacklightState(on)?.ok ?? false
            }
        }

        // 成功后自动记住，供开机恢复 / 「开」时覆盖回去。
        // 关灯（2026-11-18，用户定案）：只置总开关标记，灯效选项原样保留在存档里；
        // 绝不把 mode 覆盖成 off —— 否则下次「开」就没东西可恢复了。
        if result["ok"] as? Bool == true, params["remember"] as? Bool ?? true {
            if mode == "off" {
                result["remembered"] = RGBProfile.setEnabled(false)
            } else {
                let prof = RGBProfile.fromParams(params)
                result["remembered"] = RGBProfile.save(prof)
                result["profile"] = prof
            }
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
            // 【2026-11-11】读失败（EC 限速/争用）的结果**绝不入缓存**：老代码会把
            // 「4 读全失败 → 0x751=0」这份假数据钉死一整天，界面就一直显示
            // 「基准未开」而风扇其实在 0x40 全速。失败时回退旧缓存，没有就返回本次结果
            // （下次轮询会重读）。
            if (v["_read_ok"] as? Bool) == true {
                fanCache.put("mode", v)
            } else if let old = fanCache.get("mode", 86_400) as? [String: Any] {
                modeFlight.finish()
                return old
            }
            modeFlight.finish()
            return v
        }
        modeFlight.wait()
        if let v = fanCache.get("mode", 120.0) as? [String: Any] { return v }
        let v = FanControl.shared.modeStatus()
        if (v["_read_ok"] as? Bool) == true {
            fanCache.put("mode", v)
        } else if let old = fanCache.get("mode", 86_400) as? [String: Any] {
            return old
        }
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
        v["temp_gpu_edge"] = TempSources.gpuEdgeCelsius()
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

    /// 写操作后清空，保证紧接着的 GET 能看到新值。
    ///
    /// 【2026-11-11】光清缓存不够：写事务本身要 ~0.5–1s（多次 EC 写）。
    /// 界面 1 秒轮询的 GET 很可能在「缓存已清、写还没完」的窗口插进来，
    /// 读到 `0x751` 的中间态（例如刚被放成 0x00），随后被 24 小时 TTL 钉死 ——
    /// 表现就是「基准模式全速 5800 RPM，界面却显示未开启」。
    /// 所以这里再开一个 3 秒「强制重读」窗口，让写后的 GET 全部绕过缓存。
    private static let fanFreshLock = NSLock()
    private static var fanFreshUntil = Date.distantPast

    static func invalidateFanCache() {
        fanCache.clear()
        fanFreshLock.lock()
        fanFreshUntil = Date().addingTimeInterval(3)
        fanFreshLock.unlock()
    }

    private static var fanFreshWindowActive: Bool {
        fanFreshLock.lock()
        defer { fanFreshLock.unlock() }
        return Date() < fanFreshUntil
    }

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
            // 写操作后 3 秒内一律强制重读：宁可多几笔 EC 读，也不能把写事务的
            // 中间态缓存成一天（见 invalidateFanCache 的注释）。
            let mustFresh = fresh || fanFreshWindowActive
            if mustFresh {
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
                merged["temp_gpu_edge"] = TempSources.gpuEdgeCelsius()
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
            if mustFresh {
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
            // kext 没加载也要给温度：温度一律来自 SMC / NVAccel，本来就不经过 EC，
            // 没有理由跟着风扇驱动一起缺失。否则菜单栏 CPU 图标和「监测」页的
            // 温度会退化成「—」，看起来像「读不到系统温度」。
            out["live"] = [
                "rpm_cpu": 0,
                "rpm_gpu": 0,
                "temp_cpu": TempSources.cpuCelsius(),
                "temp_gpu": TempSources.gpuCelsius(),
                "temp_gpu_edge": TempSources.gpuEdgeCelsius(),
            ]
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
            // FanCurveController 正攥着 FAN_CTRL 手动权（0x0751 停在 0x8n），此时只写
            // 0x07AB 会出现「toast 报成功、风扇纹丝不动」——EC 在 0x751 交还后才认模式索引。
            // 必须先交还控制权：停曲线控制环 → setMode("normal") 放档位 + 补写 0x751=0xA0。
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

        // 基准模式（文档 §3.3 顶层覆盖态，EC 侧投影 = 0x751=0x40）
        if let on = params["benchmark"] as? Bool {
            FanCurveController.shared.stop()
            let r = fc.setBenchmarkMode(on)
            return ["ok": r?.ok ?? false, "reply": r?.dict ?? NSNull(), "benchmark": on]
        }

        // 键盘 Fn 锁 / 触控板 / 超频动态温控 / 风扇行为（qc71_laptop 交叉验证，
        // 2026-10-21）：都是读-改-写单位，与官方控制台同路径
        if let v = params["fn_lock"] as? Bool {
            guard let r = fc.setFnLock(v) else { return ["ok": false, "error": "写入失败"] }
            // 回读真值再返回：EC 对这两位有 1–2 秒过渡态（同 0x0726），
            // 直接回请求值会让 UI 先显示「开了」再被轮询打回去，看着像自己乱跳。
            let back = (fc.fnLockState()["fn_lock"] as? Bool) ?? v
            return ["ok": r.ok, "reply": r.dict, "fn_lock": back]
        }
        // 2026-11-17：`osd` 参数已摘。0x07A4 bit3 不是 OSD 开关，而是 Fn 锁的 AP 侧使能位，
        // 必须跟 0x074E bit4 一起写才生效 —— 已并入上面的 `fn_lock` 分支。
        // 接电自动开机（0x0726 bit3，内核 AC_AUTO_BOOT_ENABLE）。
        // 本机其余 7 位两份开源源码都没定义，只能读-改-写单 bit；写完立刻回读确认。
        if let v = params["ac_auto_boot"] as? Bool {
            guard let r = fc.setAcAutoBoot(v) else { return ["ok": false, "error": "写入失败"] }
            let back = (fc.miscStatus()["ac_auto_boot"] as? Bool) ?? v
            return ["ok": r.ok, "reply": r.dict, "ac_auto_boot": back]
        }
        // 和 0x767 那套不一样 —— 这是**持久状态位**，读-改-写，没有 toggle 语义，
        // 也不会连带抛电源键事件。关掉后键盘背光回到固件的 10 分 40 秒空闲熄灯。
        if let v = params["ap_present"] as? Bool {
            guard let r = fc.setAPPresent(v) else { return ["ok": false, "error": "写入失败"] }
            let now = fc.appPresentState()
            return ["ok": r.ok, "reply": r.dict,
                    "ap_present": now.on, "ctrl1": Int(now.raw)]
        }
        if let v = params["win_lock"] as? Bool {
            guard let r = fc.setWinKeyLock(v) else { return ["ok": false, "error": "写入失败"] }
            return ["ok": r.ok, "reply": r.dict, "win_lock": v]
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
            if out["via"] == nil { out["via"] = "hid-seize" }
            return out
        }
        if let v = params["touchpad"] as? Bool {
            // 正解：写触控板自己的 Feature Report 0x07（Surface/Button Switch），
            // 固件级停机 + 左上角指示灯同步点亮；失败才退回 HID 独占。
            let res = TrackpadLock.set(!v)
            var out = res
            out["touchpad"] = v
            if out["via"] == nil { out["via"] = "hid-seize" }
            return out
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
    /// 在内核里（kmutil showloaded 有 com.skycc.TongfangFan），界面却说没装，
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
        var mode: String
        if let s = c as? String {
            switch s {
            case "cycle", "static", "off": mode = s
            default:
                return ["ok": false, "error": "ctrl 取值无效"]
            }
        } else if let n = c as? Int, (0...255).contains(n) {
            // 兼容旧调用（数字控制字）：只用来推断三态，实际写入仍走读改写，
            // 免得把 bit0 AP exist / bit3 睡眠展示一起覆盖掉。
            let b = UInt8(n)
            mode = (b & EC.lightbarS0Off) != 0 ? "off"
                 : ((b & EC.lightbarRainbow) != 0 ? "cycle" : "static")
        } else {
            return ["ok": false, "error": "ctrl 取值无效"]
        }

        // 睡眠展示（0x748 bit3）：只有「开灯」时才允许改；关灯时文档要求无条件置 1。
        var breathing: Bool? = nil
        if let b = params["breathing"] as? Bool { breathing = b }

        guard let st = FanControl.shared.lightbarSet(rgb, mode: mode, breathing: breathing) else {
            return ["ok": false, "error": "写入后回读失败"]
        }
        var out = st
        out["ok"] = true
        out["available"] = true
        return out
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
        // 3.0.2.1：这一步只供界面「读一眼」用 —— UIControlPrefs.adoptHardwareIfNeeded
        // 拿它把 EC 真值抄进软件记忆，**不再往 EC 写任何东西**。只读这一次，之后不轮询。
        primeCache()
        // 海岸灯 AP exist（移植文档 §3.4「启动初始化」第一步）：0x748 bit0 置 1。
        // 已在位就零写入，不碰灯带其它位。
        if FanControl.kextLoaded() {
            _ = FanControl.shared.lightbarAssertAPPresent()
            // Fn 锁总闸（2026-11-17 实测）：0x07A4 bit3 必须为 1，EC 才承认 Fn+Esc
            // 这颗硬件组合键（gate=0 时连按 6 次，0x074E 一动不动）。这里只立这一位，
            // 不动 0x074E，所以不会改变当前的 F 区映射。已在位则零写入。
            let g = FanControl.shared.ensureFnLockGate()
            print("Fn 锁总闸(0x07A4 bit3): \(g?.ok == true ? "已确保在位" : "写入失败（EC 不可写）")")
        }
        // 启动时恢复存档灯效。存档 enabled=false（总开关关）时 apply() 内部走关灯，保持熄灭。
        //
        // 【2.8.12】以前这里恢复一次，另外还有一条 com.skycc.rgbrestore 登录项
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
