//
//  NativeRGB.swift
//  Mac控制台 —— ITE 8291 键盘灯控制器 · 按 Windows 原厂复刻版重写
//
//  权威来源：GamingCenter.Replica（Windows 原厂逆向复刻）
//    Core/Lighting/Ite8291.cs      —— 协议、固件码表、ColorIndex、行缓冲布局
//    Core/Lighting/WkdColor.cs     —— 原厂颜色补偿（本目录 NativeWkdColor.swift）
//    DefaultRGBKB.exe 反编译        —— Translate_ITE_EffectIndex / HID_Set_* 原文
//
//  报文（IOHIDDeviceSetReport 的 buffer **不含** ReportID，reportID 单独传 0）：
//    0x08 SET_EFFECT      [0x08, ctrl, effect, speed, light, colorIndex, dir, save]
//                          ctrl: 0x01=熄灯 0x02=应用
//    0x09 SET_BRIGHTNESS  [0x09, 0x02, light]                亮度 0..50
//    0x14 SET_PALETTE     [0x14, 0x00, slot, R, G, B, 0, 0]  slot 1..7
//    0x16 SET_ROW_INDEX   [0x16, 0x00, row, 0, 0, 0, 0, 0]   选行后发 64 字节行数据
//    0x80 GET_FW_VERSION / 0x88 GET_EFFECT
//
//  行数据（64 字节，去掉 ReportID 后）：
//    [0] = 0，[1..21] = B，[22..42] = G，[43..63] = R
//    ⚠ 旧实现按 [0..20]=B 排布，整行横向错一位 —— 本次按原厂 IL 修正。
//
//  颜色必须先过 WkdColor（原厂在组 0x14 报文之前就做）。本文件所有写颜色
//  的入口统一过补偿，纯白因此是 255,50,170（Liteon）而不是 255,255,255。
//
//  灯效下发顺序（原厂 Set_ITE_Effect_Type_FwMode）：
//    ① 先写 N 个调色板槽（0x14，每笔 Sleep(1)）
//    ② 再发 0x08，color 字节 = ColorIndex（None 0 / Single 1 / Circular 8）
//    ⚠ 绝不能把「颜色个数」当 color 发（发 7 会让芯片只认最后一个槽）。
//

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// MARK: - 协议常量

private let rgbVID = 0x048d
/// 原厂 PID 白名单（包内 `Ite8291.ProductIds`）：0x6004 / 0x6006 / 0x600B / 0xCE00。
/// 本机（LAPQC71D）实测枚举出来的是 **0x6006**，只认 0xCE00 会直接「检测不到键盘」。
private let rgbPIDs: [Int] = [0x6004, 0x6006, 0x600B, 0xCE00]

/// 亮度量程上限（芯片原始值，**不是百分比**）。
///
/// 两款键盘固件的量程不一样（包内 2026-10-23 X15 实测）：
///   · QC71 原装键盘 固件 19.x → 0…50
///   · X15 键盘      固件 22.x → 0…100（发 101+ 会被固件钳到 0x64）
/// 写死 50 的后果：X15 上拖到最亮也只有一半。固件读不到时保守取 50。
/// 版本响应 `[0x80, major, minor, buildHi, buildLo, …]`，major ≥ 20 判 X15。
private var brightnessMaxCache: UInt8?

private func brightnessMax() -> UInt8 {
    if let v = brightnessMaxCache { return v }
    var maxV: UInt8 = 50
    if let kb = try? KeyboardRGB().open() {
        let fw = kb.getFirmware()
        kb.close()
        if let bytes = fw["version_bytes"] as? [UInt8], let major = bytes.first {
            maxV = major >= 20 ? 100 : 50
        }
    }
    brightnessMaxCache = maxV
    return maxV
}

/// 亮度百分比 0…100 → 0x08 / 0x09 报文的 light 字节（按固件量程等比换算）。
///
/// 2.8.3（用户要求）：界面上不再用 L1…L4 四档，改成 0…100 的滑条。
/// 芯片量程仍是 0…50（QC71）/ 0…100（X15），换算后发原始值。
private func rawFromPct(_ pct: Int) -> UInt8 {
    let m = Int(brightnessMax())
    let p = max(0, min(100, pct))
    return UInt8(clamping: (p * m + 50) / 100)
}

/// 芯片原始值 → 百分比（回读用）。
private func pctFromRaw(_ raw: UInt8) -> Int {
    let m = max(1, Int(brightnessMax()))
    return max(0, min(100, (Int(raw) * 100 + m / 2) / m))
}

/// 老存档迁移：2.8.2 及以前 profile 里存的是 1…4 等级，换算成 25 / 50 / 75 / 100。
/// 新值本身可能是 1…100 的百分比，只有 ≤4 才当旧等级处理（1% 这种极端值不值得区分）。
private func normalizePct(_ v: Int) -> Int {
    v <= 4 ? v * 25 : max(0, min(100, v))
}

private let numRows = 6
private let numCols = 21
private let rowLen = 64
// 64 字节行缓冲（不含 ReportID）：[0]=0，B 从 1 起，G 从 22 起，R 从 43 起
private let planeBlue = 1
private let planeGreen = 1 + numCols     // 22
private let planeRed = 1 + 2 * numCols   // 43

// MARK: - 固件灯效码（原厂 Translate_ITE_EffectIndex 全表）

enum KeyboardEffect: UInt8, CaseIterable {
    case single    = 0x01   // 单色常亮 Static
    case breathing = 0x02   // 呼吸
    case wave      = 0x03   // 波浪
    case reactive  = 0x04   // 按下响应
    case rainbow   = 0x05   // 彩虹
    case ripple    = 0x06   // 涟漪
    case marquee   = 0x09   // 跑马灯
    case raindrop  = 0x0A   // 雨滴
    case stack     = 0x0C   // 堆叠
    case impact    = 0x0D   // 冲击
    case aurora    = 0x0E   // 极光
    case neon      = 0x0F   // 霓虹
    case spark     = 0x11   // 火花
    case flash     = 0x12   // 闪烁
    case mix       = 0x13   // 混合
    case rippleO   = 0x16   // 扩散涟漪 RippleO
    case music     = 0x22   // 音乐律动
    case userMode  = 0x33   // 逐键自定义

    var title: String {
        switch self {
        case .single: return "单色常亮"
        case .breathing: return "呼吸"
        case .wave: return "波浪"
        case .reactive: return "按下响应"
        case .rainbow: return "彩虹"
        case .ripple: return "涟漪"
        case .marquee: return "跑马灯"
        case .raindrop: return "雨滴"
        case .stack: return "堆叠"
        case .impact: return "冲击"
        case .aurora: return "极光"
        case .neon: return "霓虹"
        case .spark: return "火花"
        case .flash: return "闪烁"
        case .mix: return "混合"
        case .rippleO: return "扩散涟漪"
        case .music: return "音乐律动"
        case .userMode: return "逐键自定义"
        }
    }
}

/// `0x08` 第 6 字节 —— 原厂 ColorIndex（颜色方案编号），合法值只有 0/1/8。
enum ColorIndex: UInt8 {
    case none = 0       // 不用色：彩虹 / 音乐 / 逐键
    case single = 1     // 单色：只取调色板槽 1
    case circular = 8   // 循环：按整排调色板跑动效
}

enum KeyboardCatalog {
    /// 原厂 ME 变体在界面上真正提供的 15 个灯效（Flash/Mix/RippleO 只在 FourZone 提供）。
    static let meEffects: [KeyboardEffect] = [
        .single, .breathing, .wave, .reactive, .rainbow, .ripple, .raindrop,
        .marquee, .aurora, .spark, .music, .userMode, .neon, .stack, .impact,
    ]

    /// 原厂 7 色默认调色板（ME 变体，寄存器模板逐字节核对）。
    static let defaultPalette: [(Int, Int, Int)] = [
        (255, 0, 0), (243, 152, 0), (255, 241, 0), (0, 255, 0),
        (0, 0, 255), (0, 255, 255), (255, 0, 255),
    ]

    /// 这个灯效要用几个颜色（原厂 ColorBlock）。0/1/3/7。
    static func colorCount(_ e: KeyboardEffect) -> Int {
        switch e {
        case .rainbow, .music, .userMode: return 0
        case .single: return 1
        case .stack, .impact: return 3
        default: return 7
        }
    }

    /// 这个灯效该往 `0x08` 的 color 字节写什么。
    static func colorIndex(_ e: KeyboardEffect) -> ColorIndex {
        switch colorCount(e) {
        case 0: return .none
        case 1: return .single
        default: return .circular
        }
    }

    static func supportsDirection(_ e: KeyboardEffect) -> Bool {
        switch e {
        case .wave, .marquee, .aurora: return true
        default: return false
        }
    }

    /// 名称 → 灯效（兼容旧版 API 的灯效名）。
    static func effect(forName name: String) -> KeyboardEffect? {
        switch name.lowercased() {
        case "single", "static", "color", "mono": return .single
        case "breathing", "breath": return .breathing
        case "wave": return .wave
        case "reactive": return .reactive
        case "rainbow", "random": return .rainbow
        case "ripple": return .ripple
        case "marquee": return .marquee
        case "raindrop": return .raindrop
        case "stack": return .stack
        case "impact": return .impact
        case "aurora": return .aurora
        case "neon": return .neon
        case "spark", "fireworks": return .spark
        case "flash": return .flash
        case "mix": return .mix
        case "rippleo", "diffuseripple": return .rippleO
        case "music": return .music
        case "usermode", "user": return .userMode
        // 旧版命名不再对应原厂灯效，给最接近的
        case "reactiveripple": return .ripple
        case "reactiveaurora": return .aurora
        default: return nil
        }
    }

    /// 灯效 → 稳定 key（`effect(forName:)` 的反向，界面用）。
    static func key(for e: KeyboardEffect) -> String {
        switch e {
        case .single: return "single"
        case .breathing: return "breathing"
        case .wave: return "wave"
        case .reactive: return "reactive"
        case .rainbow: return "rainbow"
        case .ripple: return "ripple"
        case .marquee: return "marquee"
        case .raindrop: return "raindrop"
        case .stack: return "stack"
        case .impact: return "impact"
        case .aurora: return "aurora"
        case .neon: return "neon"
        case .spark: return "spark"
        case .flash: return "flash"
        case .mix: return "mix"
        case .rippleO: return "rippleo"
        case .music: return "music"
        case .userMode: return "usermode"
        }
    }
}

// MARK: - 键盘灯配置持久化位置

private var profileDir: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
}
private var profileURL: URL { profileDir.appendingPathComponent("rgb_profile.json") }
private var gainURL: URL { profileDir.appendingPathComponent("rgb_white_gain.json") }
private var endURL: URL { profileDir.appendingPathComponent("rgb_white_end.json") }

private let defaultGain: (Int, Int, Int) = (1000, 1000, 1000)
private let defaultEnd: (Int, Int, Int) = (1000, 300, 200)

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

// MARK: - 设备封装

final class KeyboardRGB {
    static let vid = rgbVID
    /// 原厂 PID 白名单（包内 `Ite8291.ProductIds`）。**不能只认 0xCE00**：
    /// 本机实测是真机 PID = 0x6006，写成 0xCE00 就会「控制台检测不到键盘」。
    static let pids = rgbPIDs
    /// 灯效接口的 usage page（原厂按 0xFF03 那一层发包）
    static let rgbUsagePage = 0xFF03

    private var dev: HIDDevice?

    /// 枚举所有白名单 PID，优先取 usage page = 0xFF03 的那个接口。
    static func findDevice() -> HIDDevice? {
        var candidates: [HIDDevice] = []
        for pid in pids {
            candidates += NativeHID.findDevices(vendorID: vid, productID: pid)
        }
        if candidates.isEmpty { return nil }
        // PrimaryUsagePage 决定这是不是灯效接口（本机实测 0xFF03）
        if let rgb = candidates.first(where: { $0.usagePage == rgbUsagePage }) {
            return rgb
        }
        // 退化：有 Feature 报文长度 8 的那个（0xFF03 接口的特征）
        if let feat = candidates.first(where: { ($0.maxFeatureReportSize ?? 0) == 8 }) { return feat }
        return candidates.first
    }

    static func available() -> Bool { findDevice() != nil }

    init() throws {
        guard let d = Self.findDevice() else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "未找到 ITE 8291 键盘灯设备（048d:6004/6006/600B/CE00 都不在）"])
        }
        dev = d
    }

    deinit { close() }

    func open() throws -> KeyboardRGB {
        try dev?.open()
        return self
    }

    func close() { dev?.close() }

    func info() -> [String: Any] {
        guard let d = dev else { return [:] }
        return [
            "product": d.product ?? NSNull(),
            "manufacturer": d.manufacturer ?? NSNull(),
            "vendor_id": String(format: "%#06x", d.vendorID ?? 0),
            "product_id": String(format: "%#06x", d.productID ?? 0),
            "usage_page": String(format: "%#06x", d.usagePage ?? 0),
            "feature_report_size": d.maxFeatureReportSize ?? NSNull(),
            "output_report_size": d.maxOutputReportSize ?? NSNull(),
            "led_vendor": WkdColor.vendor.label,
            "support_byte5": WkdColor.rawSupportByte5.map { String(format: "%#04x", $0) } ?? NSNull(),
        ]
    }

    // MARK: 底层

    /// 发送 8 字节 Feature 报告（buffer 不含 ReportID，reportID 传 0）
    private func feature(_ payload8: [UInt8]) -> Int {
        var pkt = payload8 + [UInt8](repeating: 0, count: max(0, 8 - payload8.count))
        pkt = Array(pkt.prefix(8))
        return Int(dev?.setReport(pkt, reportType: kIOHIDReportTypeFeature, reportID: 0) ?? -1)
    }

    /// 发送 Output 报告（行颜色走这里，64 字节）
    private func output(_ payload: [UInt8], _ length: Int) -> Int {
        var pkt = payload + [UInt8](repeating: 0, count: max(0, length - payload.count))
        pkt = Array(pkt.prefix(length))
        return Int(dev?.setReport(pkt, reportType: kIOHIDReportTypeOutput, reportID: 0) ?? -1)
    }

    func readFeature(_ length: Int = 8) -> [UInt8]? {
        guard let (kr, data) = dev?.getReport(length, reportType: kIOHIDReportTypeFeature, reportID: 0),
              kr == KERN_SUCCESS, let data = data else { return nil }
        return [UInt8](data)
    }

    // MARK: 供应商探测

    /// 读 EC 0x742 判 LED 供应商（原厂静态构造同款）。
    static func detectLedVendor() -> LedVendor {
        guard let r = FanControl.shared.ecRead(0x742), r.ok else {
            return WkdColor.detect(rawSupportByte5: nil)
        }
        return WkdColor.detect(rawSupportByte5: UInt8(r.result & 0xFF))
    }

    // MARK: 查询

    func getFirmware() -> [String: Any] {
        _ = feature([0x80, 0, 0, 0, 0, 0, 0, 0])
        usleep(200_000)
        guard let d = readFeature(8) else { return ["raw": NSNull(), "version_bytes": NSNull()] }
        if d[0] == 0x80 {
            return ["raw": hexOf(d), "version_bytes": Array(d[1..<5])]
        }
        return ["raw": hexOf(d), "version_bytes": NSNull()]
    }

    /// 回读当前灯效状态。
    ///
    /// ⚠ 2.8.8 修 bug（用户反馈「调完亮度滑条又跳回 0% / 1%」）：
    /// 芯片**不会**自己刷新 feature 缓冲，`readFeature` 拿到的其实就是「上一笔
    /// 写下去的那条报文」。而一笔灯效要连发 1…7 条 `0x14` 调色板报文，最后一条
    /// 形如 `[0x14, 0x00, slot, R, G, B, 0, 0]` —— 这时 `d[4]` 是**颜色的 G 通道**，
    /// 不是亮度！纯红 `(255,0,0)` 的 G=0，于是亮度被读成 0%，纯绿某档读成 1%。
    ///
    /// 只有 `d[0] == 0x08`（SET_EFFECT 报文）时 `d[4]` 才是亮度字节。
    /// 其它情况一律回落到 `fallbackBrightness`（调用方传存档里的真实值）。
    func getState(fallbackBrightness: Int? = nil) -> [String: Any]? {
        guard let d = readFeature(8) else { return nil }
        let isEffectReport = (d[0] == 0x08)
        let pct: Int?
        if isEffectReport {
            pct = pctFromRaw(d[4])
        } else if let f = fallbackBrightness {
            pct = normalizePct(f)
        } else {
            pct = nil
        }
        var st: [String: Any] = [
            "raw": hexOf(d),
            "command": d[0],
            "mode": d[1],
            "program": d[2],
            "speed": d[3],
            // 亮度字节只在 0x08 报文里有效；别的报文下这里照原样给出，仅供排障
            "brightness_raw": d[4],
            "brightness_max": brightnessMax(),
            "brightness_valid": isEffectReport,
            "brightness_source": isEffectReport ? "hid" : (pct == nil ? "unknown" : "profile"),
            "colour": d[5],
            "direction": d[6],
        ]
        if let p = pct { st["brightness_pct"] = p }
        // 老键名保留：菜单栏 / 旧调用还在读 brightness_level（1…4）
        st["brightness_level"] = max(1, min(4, ((pct ?? 75) + 12) / 25))
        st["off"] = (d[0] == 0x08 && d[1] == 0x01)
        st["led_vendor"] = WkdColor.vendor.label
        return st
    }

    /// `0x88` GET_EFFECT —— **真查询**（不是回读上一笔报文）。
    ///
    /// 保活循环拿它当心跳：① 纯查询，不改灯效、不会闪；② 带回来芯片眼里的
    /// `ctrl`（0x01 关灯 / 0x02 应用）和亮度字节，能分清「被关了」还是「只是暗」。
    ///
    /// 返回 nil 有两种情况，都必须**什么都不写**（乱写就是那 10 秒一闪的来源）：
    ///   · 固件没按 0x88 回包；
    ///   · 回来的内容就是自己刚发出去的那条（`[0x88,0,0,0,0,0,0,0]`）——
    ///     多数 HID 键盘的 feature 缓冲只是「回显最后一笔报文」，这种回显
    ///     看起来「亮度=0」，照着它去重下发就会变成每 30 秒闪一次。
    func queryState() -> (control: UInt8, effect: UInt8, speed: UInt8, brightness: UInt8, color: UInt8)? {
        _ = feature([0x88, 0, 0, 0, 0, 0, 0, 0])
        usleep(40_000)
        guard let d = readFeature(8), d[0] == 0x88 else { return nil }
        // 0x88 的真实回包一定带内容（ctrl 1/2、亮度 > 0）；全零 = 回显，不算数
        guard d[1] != 0 || d[2] != 0 || d[4] != 0 || d[5] != 0 else { return nil }
        return (d[1], d[2], d[3], d[4], d[5])
    }

    // MARK: 控制

    /// 熄灯
    func disable() -> Int { feature([0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) }

    /// 单独调亮度（不改灯效）。pct = 0…100 百分比，芯片值按固件量程换算
    func setBrightness(_ pct: Int) throws -> Int {
        let raw = rawFromPct(pct)
        return feature([0x09, 0x02, raw, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// 原始 0x08 下发（内部用；effect 为固件码，brightness 是百分比）
    func setEffect(_ programCode: UInt8, speed: Int, brightness: Int,
                   colour: UInt8, program2: UInt8, save: Int) -> Int {
        feature([0x08, 0x02, programCode,
                 UInt8(clamping: speed) & 0xFF, rawFromPct(brightness),
                 colour & 0xFF, program2 & 0xFF, UInt8(clamping: save) & 0xFF])
    }

    /// 按灯效语义下发一次 0x08。
    func apply(_ effect: KeyboardEffect, speed: Int, brightness: Int,
               colorIndex: ColorIndex, direction: Int, save: Int) -> Int {
        setEffect(effect.rawValue, speed: speed, brightness: brightness,
                  colour: colorIndex.rawValue, program2: UInt8(clamping: direction),
                  save: save)
    }

    /// 0x14：把一个 RGB 写进命名色槽位（槽位 1..7）。颜色过原厂补偿。
    func setNamedColor(slot: Int, r: Int, g: Int, b: Int, compensate: Bool = true) -> Int {
        let s = max(1, min(7, slot))
        let (rr, gg, bb) = compensate
            ? WkdColor.convert(r, g, b)
            : (r, g, b)
        return feature([0x14, 0x00, UInt8(s) & 0xFF,
                        UInt8(clamping: rr) & 0xFF, UInt8(clamping: gg) & 0xFF,
                        UInt8(clamping: bb) & 0xFF, 0x00, 0x00])
    }

    /// 写一整组调色板槽 1…n（最多 7 个）。
    @discardableResult
    func setNamedPalette(_ colors: [[Int]]) -> Int {
        var written = 0
        for (i, c) in colors.prefix(7).enumerated() {
            let r = c.count > 0 ? c[0] : 0
            let g = c.count > 1 ? c[1] : 0
            let b = c.count > 2 ? c[2] : 0
            _ = setNamedColor(slot: i + 1, r: r, g: g, b: b)
            usleep(1_000)
            written += 1
        }
        return written
    }

    /// 按名称设置预设灯效（保留旧 API 签名）。
    ///
    /// 原厂流程：先写 N 个 0x14 调色板槽，再发 0x08；color 字节用 ColorIndex，
    /// 不是颜色个数。多色灯效靠 ColorIndex=8（循环）让芯片跑整排调色板。
    /// direction 只对 Wave/Marquee/Aurora 有效：1 右 / 2 左 / 3 上 / 4 下（原厂默认 1）。
    func setStyle(name: String, brightness: Int = 75, speed: Int = 5, save: Int = 1,
                  rgb: [Int]? = nil, slot: Int = 1, palette: [[Int]]? = nil,
                  direction: Int = 1) throws -> Int {
        guard let effect = KeyboardCatalog.effect(forName: name) else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未知灯效: \(name)"])
        }
        let slots = KeyboardCatalog.colorCount(effect)
        let ci = KeyboardCatalog.colorIndex(effect)
        let spd = max(0, min(10, speed))
        let rawDir = (1...4).contains(direction) ? direction : 1
        let dir = KeyboardCatalog.supportsDirection(effect) ? rawDir : 0

        if effect == .userMode {
            // 原厂 Set_ITE_Effect_Type_UserMode：speed=0、color=0、direction=0
            return setEffect(effect.rawValue, speed: 0, brightness: brightness,
                             colour: ColorIndex.none.rawValue, program2: 0, save: save)
        }

        // ① 先写调色板
        if ci != .none {
            if ci == .single {
                let c = rgb ?? (palette?.first ?? [255, 255, 255])
                _ = setNamedColor(slot: 1, r: c[0], g: c.count > 1 ? c[1] : 0, b: c.count > 2 ? c[2] : 0)
            } else {
                let colors: [[Int]]
                if let pal = palette, !pal.isEmpty {
                    colors = pal
                } else if let c = rgb {
                    colors = [c]
                } else {
                    colors = KeyboardCatalog.defaultPalette.map { [$0.0, $0.1, $0.2] }
                }
                _ = setNamedPalette(Array(colors.prefix(max(1, slots))))
            }
            usleep(2_000)
        }

        // ② 再发灯效
        return apply(effect, speed: spd, brightness: brightness,
                     colorIndex: ci, direction: dir, save: save)
    }

    /// 0x16 选择要写入的行 (0-5)
    func setRowIndex(_ row: Int) -> Int {
        feature([0x16, 0x00, UInt8(row) & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// 构造一行 64 字节缓冲（不含 ReportID）：
    /// [0]=0，[1..21]=B，[22..42]=G，[43..63]=R
    static func buildRowBuffer(r: Int, g: Int, b: Int) -> [UInt8] {
        var arr = [UInt8](repeating: 0, count: rowLen)
        for i in 0..<numCols {
            arr[planeBlue + i] = UInt8(clamping: b) & 0xFF
            arr[planeGreen + i] = UInt8(clamping: g) & 0xFF
            arr[planeRed + i] = UInt8(clamping: r) & 0xFF
        }
        return arr
    }

    /// 构造一行 **逐键** 64 字节缓冲：同一行的 21 个位置可以是 21 种不同颜色。
    ///
    /// 2.8.8（用户要求「逐键自定义要有键盘投影，能选哪个键点亮哪个颜色」）：
    /// 逐键模式（固件码 0x33）下，芯片按行锁存 21 个位置的 RGB 三平面，
    /// 所以逐键自定义 = 6 行 × 21 列 = 126 个可独立配色的位置。
    /// 颜色与 `setZoneColors` 一致，先过原厂补偿再写。
    static func buildRowBuffer(colors: [[Int]]) -> [UInt8] {
        var arr = [UInt8](repeating: 0, count: rowLen)
        for i in 0..<numCols {
            let c = i < colors.count ? colors[i] : [0, 0, 0]
            let (r, g, b) = WkdColor.convert(c.count > 0 ? c[0] : 0,
                                             c.count > 1 ? c[1] : 0,
                                             c.count > 2 ? c[2] : 0)
            arr[planeBlue + i] = UInt8(clamping: b) & 0xFF
            arr[planeGreen + i] = UInt8(clamping: g) & 0xFF
            arr[planeRed + i] = UInt8(clamping: r) & 0xFF
        }
        return arr
    }

    /// 进入逐键自定义模式 = 固件码 0x33
    func userMode(save: Int = 1, brightness: Int = 75) -> Int {
        setEffect(KeyboardEffect.userMode.rawValue, speed: 0, brightness: brightness,
                  colour: ColorIndex.none.rawValue, program2: 0, save: save)
    }

    /// 逐键矩阵下发（6 行 × 21 列，每个位置独立颜色）。
    ///
    /// 流程与原厂 UserMode 一致：
    ///   ① 0x08 + 固件码 0x33 进入逐键模式（必须先切，否则行数据不生效）
    ///   ② 每行：0x16 选行 → Sleep(1ms) → 64 字节 Output 行数据（21×RGB 三平面）
    /// 回读只会清行锁存，所以整段过程**绝不回读**。
    ///
    /// - Parameter rows: 6 行，每行 21 个 `[r,g,b]`；不足的位置按黑色补齐。
    func setKeyMatrix(_ rows: [[[Int]]], brightness: Int = 75, save: Int = 1) throws -> Int {
        _ = userMode(save: save, brightness: brightness)
        usleep(3_000)
        return try setMatrixRows(rows)
    }

    /// 只写 6 行行数据，**不切模式**。
    ///
    /// 音乐律动每帧都调用它：每帧重发一次 `0x08`（进逐键模式）会打断正在刷的
    /// 行数据，画面直接闪；调用方只要在「断流超过 1.5 秒」时补一次 `userMode`。
    func setMatrixRows(_ rows: [[[Int]]]) throws -> Int {
        guard rows.count == numRows else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "逐键矩阵需要 \(numRows) 行，收到 \(rows.count)"])
        }
        var last = -1
        for row in 0..<numRows {
            let arr = KeyboardRGB.buildRowBuffer(colors: rows[row])
            // 原厂顺序：先选行、再写行数据；中间不能插回读
            _ = setRowIndex(row)
            usleep(1_000)
            last = output(arr, rowLen)
        }
        return last
    }

    /// 按行下发颜色（键盘 6 行 × 21 列），颜色过原厂补偿。
    ///
    /// ⚠️ 只写行数据，**不会**切模式 —— 调用方必须保证芯片已经在逐键模式
    /// （`userMode`）。每帧都调 `userMode` 会让 0x08 打断正在刷的行，画面会闪。
    func setZoneColors(_ zones: [[Int]], repeat count: Int = 1) throws -> Int {
        guard !zones.isEmpty else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "zones 不能为空"])
        }
        let cols = zones.map { WkdColor.convert($0[0], $0[1], $0[2]) }
        var last = -1
        for _ in 0..<max(1, count) {
            for row in 0..<numRows {
                let c = cols[row % cols.count]
                let arr = KeyboardRGB.buildRowBuffer(r: c.0, g: c.1, b: c.2)
                // 原厂 IL：选行后跟 WriteFeature + Sleep(1)，绝不能回读（回读会清行锁存）
                _ = setRowIndex(row)
                usleep(1_000)
                last = output(arr, rowLen)
            }
        }
        return last
    }

    /// 把整个键盘设成单一颜色（完整流程：0x14 槽 1 → 0x08 单色）
    func setColor(r: Int, g: Int, b: Int, brightness: Int = 75, save: Int = 1, repeat count: Int = 1) throws -> Int {
        _ = setNamedColor(slot: 1, r: r, g: g, b: b)
        usleep(2_000)
        return apply(.single, speed: 0, brightness: brightness,
                     colorIndex: .single, direction: 0, save: save)
    }
}

// MARK: - 颜色小工具

enum RGBUtil {
    static func hexToRgb(_ s: String) -> [Int] {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6 else { return [255, 149, 0] }
        let chars = Array(h)
        return stride(from: 0, to: 6, by: 2).map {
            Int(String(chars[$0]) + String(chars[$0 + 1]), radix: 16) ?? 0
        }
    }
}

// MARK: - 灯效配置持久化 + 一键恢复

enum RGBProfile {
    static func save(_ profile: [String: Any]) -> Bool {
        var p = profile
        p["updated"] = timeFormatter.string(from: Date())
        let dir = profileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: p) else { return false }
        return (try? data.write(to: profileURL)) != nil
    }

    static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: profileURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return d
    }

    static func clear() -> Bool {
        do { try FileManager.default.removeItem(at: profileURL); return true }
        catch { return false }
    }

    /// 逐键矩阵规格：6 行 × 21 列
    static let keyRows = 6
    static let keyCols = 21

    /// 把任意来源的「逐键矩阵」归一化成严格的 6×21×3（缺的补黑，多的丢弃）。
    /// 存档 / XPC 传过来的都是 JSON 解出来的 `[[Any]]`，类型全靠这里兜住，
    /// 否则上面一层到处写 `as? [[[Int]]]` 会因为桥接差异静默变空。
    static func normalizeKeymap(_ raw: Any?) -> [[[Int]]] {
        var out = [[[Int]]](repeating: [[Int]](repeating: [0, 0, 0], count: keyCols),
                            count: keyRows)
        guard let rows = raw as? [Any] else { return out }
        for (r, rowAny) in rows.prefix(keyRows).enumerated() {
            guard let row = rowAny as? [Any] else { continue }
            for (c, cellAny) in row.prefix(keyCols).enumerated() {
                guard let cell = cellAny as? [Any], cell.count >= 3 else { continue }
                out[r][c] = [clamp8(cell[0]), clamp8(cell[1]), clamp8(cell[2])]
            }
        }
        return out
    }

    private static func clamp8(_ v: Any) -> Int {
        let n = (v as? Int) ?? Int((v as? Double) ?? 0)
        return max(0, min(255, n))
    }

    static func fromParams(_ params: [String: Any]) -> [String: Any] {
        let mode = params["mode"] as? String ?? "color"
        switch mode {
        case "off":
            return ["mode": "off"]
        case "keymap":
            return ["mode": "keymap",
                    "brightness": params["brightness"] as? Int ?? 75,
                    "rows": normalizeKeymap(params["rows"])]
        case "brightness":
            return ["mode": "brightness", "brightness": params["level"] as? Int ?? 75]
        case "effect":
            var prof: [String: Any] = [
                "mode": "effect",
                "style": params["style"] as? String ?? "rainbow",
                "brightness": params["brightness"] as? Int ?? 75,
                "speed": params["speed"] as? Int ?? 5,
                "direction": params["direction"] as? Int ?? 1,
            ]
            if let colors = params["colors"] as? [[Any]], !colors.isEmpty {
                let pal = colors.prefix(7).map { c in
                    [c.count > 0 ? (c[0] as? Int ?? 0) : 0,
                     c.count > 1 ? (c[1] as? Int ?? 0) : 0,
                     c.count > 2 ? (c[2] as? Int ?? 0) : 0]
                }
                prof["colors"] = pal
                if let first = pal.first {
                    prof["rgb"] = first
                    prof["hex"] = String(format: "%02x%02x%02x",
                                         first[0] & 0xFF, first[1] & 0xFF, first[2] & 0xFF)
                }
            } else if let hex = params["hex"] as? String {
                var hx = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
                if hx.count != 6 { hx = "ff9500" }
                prof["hex"] = hx
                prof["rgb"] = RGBUtil.hexToRgb(hx)
                prof["slot"] = params["slot"] as? Int ?? 1
            }
            return prof
        case "zones":
            let zones = (params["zones"] as? [[Any]] ?? []).map { z in
                [z[0] as? Int ?? 0, z[1] as? Int ?? 0, z[2] as? Int ?? 0]
            }
            return ["mode": "zones", "brightness": params["brightness"] as? Int ?? 75, "zones": zones]
        default:
            var hx = (params["hex"] as? String ?? "#ff9500")
            hx = hx.hasPrefix("#") ? String(hx.dropFirst()) : hx
            var rgb = RGBUtil.hexToRgb(hx)
            if hx.count != 6 || rgb.contains(where: { $0 < 0 }) {
                hx = "ff9500"; rgb = [255, 149, 0]
            }
            return ["mode": "color", "hex": hx, "rgb": rgb,
                    "brightness": params["brightness"] as? Int ?? 75]
        }
    }

    /// 按配置恢复灯效。返回 {'ok','kr','mode','profile','gains','applied_rgb'}
    ///
    /// - Parameter save: 1 = 写进芯片 NVM（正常应用）；0 = 只作用于当前会话。
    ///   灯效保活每分钟会重放一次存档，必须用 0，否则等于每分钟擦写一次 NVM。
    static func apply(_ profile: [String: Any]? = nil, save: Int = 1) -> [String: Any] {
        guard let prof = profile ?? load() else {
            return ["ok": false, "error": "没有已保存的灯效配置"]
        }
        guard KeyboardRGB.available() else {
            return ["ok": false, "error": "未检测到 ITE 8291 键盘灯设备"]
        }

        let mode = prof["mode"] as? String ?? "color"
        var kr = -1
        var appliedRGB: [Int]? = nil
        do {
            let kb = try KeyboardRGB().open()
            defer { kb.close() }
            _ = KeyboardRGB.detectLedVendor()
            switch mode {
            case "off":
                kr = kb.disable()
            case "brightness":
                kr = try kb.setBrightness(normalizePct(prof["brightness"] as? Int ?? 75))
            case "effect":
                var effRGB: [Int]? = prof["rgb"] as? [Int]
                if effRGB == nil, let hex = prof["hex"] as? String {
                    effRGB = RGBUtil.hexToRgb(hex)
                }
                let palette = (prof["colors"] as? [[Any]])?.map { c in
                    [c.count > 0 ? (c[0] as? Int ?? 0) : 0,
                     c.count > 1 ? (c[1] as? Int ?? 0) : 0,
                     c.count > 2 ? (c[2] as? Int ?? 0) : 0]
                }
                kr = try kb.setStyle(name: prof["style"] as? String ?? "rainbow",
                                     brightness: normalizePct(prof["brightness"] as? Int ?? 75),
                                     speed: prof["speed"] as? Int ?? 5,
                                     save: save,
                                     rgb: effRGB,
                                     slot: prof["slot"] as? Int ?? 1,
                                     palette: palette,
                                     direction: prof["direction"] as? Int ?? 1)
            case "zones":
                let zb = normalizePct(prof["brightness"] as? Int ?? 75)
                _ = try kb.setBrightness(zb)
                usleep(20_000)
                let zones = (prof["zones"] as? [[Any]] ?? []).map { z in
                    [z[0] as? Int ?? 0, z[1] as? Int ?? 0, z[2] as? Int ?? 0]
                }
                guard !zones.isEmpty else { return ["ok": false, "error": "配置里的 zones 为空"] }
                // 行数据只有在逐键模式下才生效
                _ = kb.userMode(save: save, brightness: zb)
                usleep(3_000)
                kr = try kb.setZoneColors(zones, repeat: 1)
            case "keymap":
                kr = try kb.setKeyMatrix(normalizeKeymap(prof["rows"]),
                                         brightness: normalizePct(prof["brightness"] as? Int ?? 75),
                                         save: save)
            default:  // color
                let rgb: [Int]
                if let r = prof["rgb"] as? [Int], r.count == 3 {
                    rgb = r
                } else {
                    rgb = RGBUtil.hexToRgb(prof["hex"] as? String ?? "#ff9500")
                }
                _ = try kb.setBrightness(normalizePct(prof["brightness"] as? Int ?? 75))
                usleep(20_000)
                kr = try kb.setColor(r: rgb[0], g: rgb[1], b: rgb[2],
                                     brightness: normalizePct(prof["brightness"] as? Int ?? 75), save: save)
                let conv = WkdColor.convert(rgb[0], rgb[1], rgb[2])
                appliedRGB = [conv.0, conv.1, conv.2]
            }
        } catch {
            return ["ok": false, "error": "\(error)", "mode": mode, "profile": prof]
        }
        let gains = RGBGains.load()
        var out: [String: Any] = [
            "ok": kr == 0, "kr": kr, "mode": mode, "profile": prof,
            "gains": [gains.0, gains.1, gains.2],
            "led_vendor": WkdColor.vendor.label,
        ]
        if let appliedRGB = appliedRGB { out["applied_rgb"] = appliedRGB }
        return out
    }
}

// MARK: - 灯效保活（2026-10-25）

/// 灯效活动标记：音乐律动每帧都会刷一次「逐行上色」，保活循环据此避让，
/// 免得不打字时把正在跑的频谱画面覆盖回旧灯效。
enum RGBActivity {
    private static let lock = NSLock()
    private static var zonesAt = Date.distantPast
    private static var zoneBright = 75

    static var lastZones: Date {
        get { lock.lock(); defer { lock.unlock() }; return zonesAt }
        set { lock.lock(); zonesAt = newValue; lock.unlock() }
    }

    /// 逐行上色用的亮度（音乐律动每帧都不带亮度，进逐键模式时得有个值）
    static var zoneBrightness: Int {
        get { lock.lock(); defer { lock.unlock() }; return zoneBright }
        set { lock.lock(); zoneBright = max(0, min(100, newValue)); lock.unlock() }
    }

    /// 15 秒内刷过逐行上色 = 音乐律动还活着
    static var musicActive: Bool { Date().timeIntervalSince(lastZones) < 15 }
}

/// 键盘背光「过一段时间自己熄灭」的修补（2026-10-25 第二版）。
///
/// **第一版为什么失败（用户实测）**：每 10 秒补一笔 `0x09` 亮度 —— 结果变成
/// 「每 10 秒亮一下又灭」的死循环。两个原因：
///   ① 原厂复刻版 `Ite8291.ReEnable` 的实测结论：`TurnOff` 发的是 `0x08 ctrl=0x01`，
///      之后**单发 `0x09` 亮度是点不亮的** —— 那笔报文从来没能把灯救回来，
///      它只是让 LED 驱动闪一下，属于「看着有动作、其实没修好」。
///   ② 灭灯不是芯片的主动行为（原厂 idle-off 是 Windows 服务端的 RawInput 计时器，
///      见 `IdleTimerSwitchKeyboardLed`）。能真的把灯掐掉的只剩两种可能：
///      USB 侧空闲（设备/主控进入低功耗）或 EC 断 LED 供电 —— 两者都靠
///      **持续有报文往来**才不会发生，而 10 秒一次的间隔已经太稀。
///
/// **第二版做法**：
///   ① 每 2.5 秒发一条 `0x88` GET_EFFECT 心跳 —— 纯查询，不改灯效、不会闪，
///      但足以把任何「空闲计时器」打回零；
///   ② 只有查询结果确实是「`ctrl=0x01` 关灯」或「亮度=0」时，才按存档完整
///      重下发一次（`0x08 ctrl=0x02`），并带 30 秒退避，避免连环闪。
/// 全程 HID，不碰 EC；音乐律动在跑的时候一次都不插手。
enum RGBKeepAlive {
    private static var started = false
    private static let queue = DispatchQueue(label: "com.macconsole.rgbkeepalive", qos: .utility)
    /// 心跳间隔。旧版 10 秒已经被证明压不住，这里取 2.5 秒（对 HID 来说微不足道）。
    private static let probeInterval: TimeInterval = 2.5
    /// 完整重下发的退避时间：灯灭了只救一次，30 秒内不再动手
    private static let restoreCooldown: TimeInterval = 30

    private static var lastRestore = Date.distantPast
    private static var lastState = ""
    private static var tick = 0

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rgb_keepalive.log")
    }()

    static func start() {
        guard !started else { return }
        started = true
        queue.async {
            while true {
                Thread.sleep(forTimeInterval: probeInterval)
                autoreleasepool { step() }
            }
        }
    }

    private static func step() {
        tick &+= 1
        // 音乐律动在跑：它自己每 83ms 刷一帧，既不缺报文也不该被打断
        guard !RGBActivity.musicActive else { return }
        guard let prof = RGBProfile.load(),
              (prof["mode"] as? String ?? "color") != "off" else { return }

        var probe: (control: UInt8, effect: UInt8, speed: UInt8, brightness: UInt8, color: UInt8)?
        do {
            let kb = try KeyboardRGB().open()
            defer { kb.close() }
            probe = kb.queryState()
        } catch {
            log("device=gone", force: true)
            return
        }
        guard let st = probe else {
            // 固件没回 0x88：心跳本身已经发出去了，别为了「保险」再补写 —— 补写就是闪
            log("query=nil")
            return
        }

        let off = st.control == 0x01 || st.brightness == 0
        log("ctrl=\(st.control) eff=\(st.effect) bri=\(st.brightness)\(off ? "  → 灭了" : "" )")
        guard off else { return }
        guard Date().timeIntervalSince(lastRestore) > restoreCooldown else { return }
        lastRestore = Date()
        let r = RGBProfile.apply(prof, save: 0)   // save:0 —— 保活不能反复擦芯片 NVM
        log("restore ok=\(r["ok"] as? Bool ?? false) mode=\(r["mode"] as? String ?? "?")", force: true)
    }

    /// 落盘一份状态流水（状态变化 / 每 24 拍≈1 分钟 / 强制）。排查「到底是被关了
    /// 还是只是暗」全靠这个文件：`ctrl=2 bri=38` 却黑着 = 芯片说亮、电源被掐了。
    private static func log(_ s: String, force: Bool = false) {
        guard force || s != lastState || tick % 24 == 0 else { return }
        lastState = s
        let line = "\(timeFormatter.string(from: Date())) \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - 白色微调（原厂补偿之后的二次手工微调）

/// 原厂补偿已经把三通道配比拉到接近中性白；这里保留一个二次微调，
/// 默认 (1000,1000,1000) = 不动。与旧版的区别：旧版用它来"补救"
/// 缺失的补偿，会在补偿补上之后过度修正，所以旧配置需要重置一次。
enum RGBGains {
    static func load() -> (Int, Int, Int) {
        guard let data = try? Data(contentsOf: gainURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // 只接受 Version 2（补偿上线后的配置）；旧版裸数组直接丢弃
              (d["Version"] as? Int ?? 0) >= 2,
              let r = d["R"] as? Int, let g = d["G"] as? Int, let b = d["B"] as? Int else {
            return defaultGain
        }
        return (clamp(r), clamp(g), clamp(b))
    }

    @discardableResult
    static func save(_ gr: Int, _ gg: Int, _ gb: Int, observed: String? = nil) -> (Int, Int, Int) {
        let g = (clamp(gr), clamp(gg), clamp(gb))
        let dir = gainURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload: [String: Any] = ["Version": 2, "R": g.0, "G": g.1, "B": g.2]
        if let observed = observed { payload["observed"] = observed }
        payload["updated"] = timeFormatter.string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: gainURL)
        }
        return g
    }

    @discardableResult
    static func clear() -> (Int, Int, Int) {
        try? FileManager.default.removeItem(at: gainURL)
        return defaultGain
    }

    static func apply(_ rgb: (Int, Int, Int)) -> (Int, Int, Int) {
        let (gr, gg, gb) = load()
        return (min(255, (rgb.0 * gr + 500) / 1000),
                min(255, (rgb.1 * gg + 500) / 1000),
                min(255, (rgb.2 * gb + 500) / 1000))
    }

    private static func clamp(_ v: Int) -> Int { max(50, min(1000, v)) }

    private static func srgbToLinear(_ c: Double) -> Double {
        let v = max(0, min(255, c)) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func calcWhiteGains(_ observedHex: String) -> [String: Any]? {
        var s = observedHex
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let r = Int(s[0..<2], radix: 16),
              let g = Int(s[2..<4], radix: 16), let b = Int(s[4..<6], radix: 16) else { return nil }
        let lin = (srgbToLinear(Double(r)), srgbToLinear(Double(g)), srgbToLinear(Double(b)))
        let strongest = max(lin.0, lin.1, lin.2)
        let weakest = min(lin.0, lin.1, lin.2)
        if strongest < 0.01 || weakest < 0.0005 { return nil }
        let out = [lin.0, lin.1, lin.2].map { ch -> Int in
            ch <= 1e-6 ? 1000 : max(50, min(1000, Int(weakest / ch * 1000.0 + 0.5)))
        }
        return ["R": out[0], "G": out[1], "B": out[2],
                "observed": s.lowercased(),
                "factors": out.map { (Double($0) / 1000 * 1000).rounded() / 1000 }]
    }
}

// MARK: - 滑条端点（让「去蓝强度」滑条可无跳变往返）

enum RGBSlider {
    static func loadEndpoint() -> (Int, Int, Int) {
        guard let data = try? Data(contentsOf: endURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultEnd
        }
        let r = max(50, min(1000, d["R"] as? Int ?? 1000))
        let g = max(50, min(1000, d["G"] as? Int ?? defaultEnd.1))
        let b = max(50, min(1000, d["B"] as? Int ?? defaultEnd.2))
        return (r, g, b)
    }

    @discardableResult
    static func saveEndpoint(_ gr: Int, _ gg: Int, _ gb: Int) -> (Int, Int, Int) {
        let g = (max(50, min(1000, gr)), max(50, min(1000, gg)), max(50, min(1000, gb)))
        let dir = endURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload: [String: Any] = ["R": g.0, "G": g.1, "B": g.2]
        payload["updated"] = timeFormatter.string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: endURL)
        }
        return g
    }

    @discardableResult
    static func clearEndpoint() -> (Int, Int, Int) {
        try? FileManager.default.removeItem(at: endURL)
        return defaultEnd
    }

    static func toGains(_ t: Double) -> (Int, Int, Int) {
        let end = loadEndpoint()
        let tt = max(0, min(100, t))
        let f = { (e: Int) -> Int in
            Int((1000 - Double(1000 - e) * tt / 100.0).rounded(.toNearestOrEven))
        }
        return (f(end.0), f(end.1), f(end.2))
    }

    static func fromGains(_ gains: (Int, Int, Int)? = nil) -> Int {
        let cur = gains ?? RGBGains.load()
        let end = loadEndpoint()
        var ts: [Double] = []
        for (c, e) in [(cur.0, end.0), (cur.1, end.1), (cur.2, end.2)] {
            let span = Double(1000 - e)
            if span <= 0 { continue }
            ts.append(Double(1000 - c) / span * 100.0)
        }
        guard !ts.isEmpty else { return 0 }
        let mx = ts.max() ?? 0
        return Int(max(0, min(100, mx.rounded(.toNearestOrEven))))
    }
}

// MARK: - 小工具

private func hexOf(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private extension String {
    subscript(range: Range<Int>) -> String {
        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(startIndex, offsetBy: range.upperBound)
        return String(self[start..<end])
    }
}
