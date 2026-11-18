//
//  NativeRGB.swift
//  Sky CC —— ITE 8291 键盘灯控制器 · 按 Windows 原厂复刻版重写
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
///
/// 2026-10-26：加了「重试 + 落盘」。之前只要 `getFirmware()` 失败一次，整个进程
/// 就按 0…50 处理到退出 —— 而 0x12 提交 NVM 之后，这个错误量程会被**写进芯片 NVM**，
/// 之后每次按键唤醒都只有半亮。实测 mcutil 那条路就踩过：`rgb apply --force`
/// 把 100% 写成了原始值 50。现在读不到先重试 3 次，还不行就沿用上次成功记下的值。
private var brightnessMaxCache: UInt8?

private var brightnessMaxFile: URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SkyCC", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("rgb_brightmax.txt")
}

private func persistBrightnessMax(_ v: UInt8) {
    try? "\(v)".data(using: .utf8)?.write(to: brightnessMaxFile)
}

private func loadPersistedBrightnessMax() -> UInt8? {
    guard let s = try? String(contentsOf: brightnessMaxFile, encoding: .utf8),
          let v = UInt8(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          v == 50 || v == 100 else { return nil }
    return v
}

private func brightnessMax() -> UInt8 {
    if let v = brightnessMaxCache { return v }
    for _ in 0..<3 {
        if let kb = try? KeyboardRGB().open() {
            let fw = kb.getFirmware()
            kb.close()
            if let bytes = fw["version_bytes"] as? [UInt8], let major = bytes.first {
                let v: UInt8 = major >= 20 ? 100 : 50
                brightnessMaxCache = v
                persistBrightnessMax(v)
                return v
            }
        }
        usleep(120_000)
    }
    let v = loadPersistedBrightnessMax() ?? 50
    brightnessMaxCache = v
    return v
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
    /// ⚠️ 3.0.3.1 起这个码**不再用于下发**：原厂 `StaticMode` 发的是 0x33（见
    /// `setStyle` 里 `.single` 分支），本机 19.x 固件对 0x01 静默忽略。
    /// 保留这个 rawValue 只是为了存档/回读的兼容（老配置里 style 可能是 "single"）。
    case single    = 0x01   // 单色常亮 Static（原厂实际走 0x33）
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

    /// 本机固件的 `0x08` 通道**没有**这三个效果号（文档 §2.1 坑表 / §6 效果号表：
    /// 「0x08 通道没有 1/12/13/15 号，发进去 = 固件未定义态」）。
    ///
    /// 原厂它们是 **AP 软件动画**：`Set_ITE_Effect_Type_ApMode` 起一个 `AP_Effect_Task`
    /// 线程，上位机逐帧算 126 个灯位的颜色再走逐键通道灌下去。所以这三个下固件码
    /// 一定是无效的（用户实测：三个效果看起来一模一样）——要由 `APEffectEngine`
    /// 在界面侧逐帧驱动。
    var isSoftwareAnimation: Bool {
        switch self {
        case .neon, .stack, .impact: return true
        default: return false
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
        .appendingPathComponent("Library/Application Support/SkyCC", isDirectory: true)
}
private var profileURL: URL { profileDir.appendingPathComponent("rgb_profile.json") }

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
            "led_variant": WkdColor.variantLabel,
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
            // 顺手定键盘世代：VerHigh==19 → 2.1 代补偿曲线（原厂 Is2p1nd）
            WkdColor.detectVariant(fwMajor: Int(d[1]))
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
        // 关灯报文（0x08 0x01）也是 0x08 开头，但第 5 字节恒 0 —— 拿它当亮度
        // 会读出 ~2%（用户实测：关灯后亮度滑条闪 2% 又回 100%）。灯关着亮度
        // 无意义，一律回落到存档值（那是下次「开」要恢复的亮度）。
        let brightnessUsable = isEffectReport && d[1] != 0x01
        let pct: Int?
        if brightnessUsable {
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
            "brightness_valid": brightnessUsable,
            "brightness_source": brightnessUsable ? "hid" : (pct == nil ? "unknown" : "profile"),
            "colour": d[5],
            "direction": d[6],
        ]
        if let p = pct { st["brightness_pct"] = p }
        // 老键名保留：菜单栏 / 旧调用还在读 brightness_level（1…4）
        st["brightness_level"] = max(1, min(4, ((pct ?? 75) + 12) / 25))
        // 【2026-11-18 修复】off 不能再看缓冲里「上一笔报文」：rgbState 每次轮询
        // 都会有 feature 查询报文（0x88 / 0x80）写进同一个缓冲，下一拍读到的
        // 就是查询报文而非关灯报文 → off 恒为 false → 总开关被轮询顶回「开」
        //（用户反馈的 bug）。改用 0x88 现场查询芯片真实状态（纯查询，不重置
        // 固件熄灯计时）；查询失败才退回缓冲推导。
        if let q = queryState() {
            st["off"] = (q.control == 0x01 || q.brightness == 0)
        } else {
            st["off"] = (d[0] == 0x08 && d[1] == 0x01)
        }
        st["led_vendor"] = WkdColor.vendor.label
        st["led_variant"] = WkdColor.variantLabel
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

    /// `0x12` SET_PICTURE —— **把当前画面（调色板 + 亮度）提交进芯片 NVM**。
    ///
    /// 2026-10-26 补：原厂 `HID_Set_Picture_12H(Saved)`，报文
    /// `{0, 0x12, 0, 0, 8, Saved, 0, 0, 0}`（首字节是 ReportID，所以这里 8 字节从 0x12 起）。
    /// 原厂静态模式（`Set_ITE_Effect_Type_StaticMode`）的顺序是：
    ///   `0x08`(ctrl=2, effect=51, light, save) → 64 字节行数据 → **`0x12`(Saved)**
    ///
    /// 之前我们只发前两步，`0x08` 的 save 字节只标记灯效，**NVM 里那一份画面从来没被提交**，
    /// 所以芯片一直用出厂默认亮度 36 —— 灯被固件闲置熄掉后按一下键，回来的就是 36 而不是
    /// 用户设的 100。补上这一条之后 NVM 才会真正记住亮度。
    ///
    /// 只在「用户手动应用」（save=1）时发，保活重放（save=0）绝不能发 —— 那是 NVM 擦写。
    func setPicture(saved: Int) -> Int {
        feature([0x12, 0x00, 0x00, 0x08, UInt8(clamping: saved) & 0xFF, 0x00, 0x00, 0x00])
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

        // 3.0.3.1：**单色常亮必须走 UserMode（0x33）+ 6 行同一颜色**，不能发固件码 0x01。
        //
        // 原厂 `Set_ITE_Effect_Type_StaticMode`（IL RVA 0x277A8）第 3 条指令起就是
        //   `HID_Set_Effect_Type_08H(ctrl=2, effect=51, speed=0, light, color=0, dir=0, save)`
        // 然后才开 65 字节缓冲逐行灌。整份 `oem-ite-il2.txt` 里 `HID_Set_Effect_Type_08H`
        // **只有两个调用点**（StaticMode 0x277A8 / UserMode 0x2757C），effect 全是 51。
        // 原厂从来没发过 0x01 —— 那是从 `ite8291r3-ctl` 抄来的 8291**r3** 协议，
        // 本机 19.7 固件收下不报错、也不生效（2026-11-01 实测：回读 program=1 正常、
        // 画面不变；改发 0x33 + 全红矩阵立刻整块变红）。
        if effect == .single {
            let c = rgb ?? (palette?.first ?? [255, 255, 255])
            let row: [[Int]] = Array(repeating: c, count: numCols)
            let rows: [[[Int]]] = Array(repeating: row, count: numRows)
            return try setKeyMatrix(rows, brightness: brightness, save: save)
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
        for chipRow in 0..<numRows {
            // ⚠ 行序必须倒过来灌。原厂 `LM_ITE_RGB::Set_ITE_Effect_Type_UserMode`
            // （Keyboard-HID.md §行序）是 `src = col + (5 - 物理行) * 21`，
            // 而**芯片的物理行 0 = 键盘最下面一排**，我们传进来的数组是屏幕顺序
            // （0 = 最上面的 F 排）。以前直接对上号发，结果是整块画面**上下镜像** ——
            // 逐键投影和音乐律动柱状条都会「从顶部往下垂」。
            let srcRow = numRows - 1 - chipRow
            let arr = KeyboardRGB.buildRowBuffer(colors: rows[srcRow])
            // 原厂顺序：先选行、再写行数据；中间不能插回读
            _ = setRowIndex(chipRow)
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
            for chipRow in 0..<numRows {
                // 与 setMatrixRows 同一个道理：数组是屏幕顺序（0 = 最上面），
                // 芯片物理行是反的（0 = 最下面），所以倒过来取色。
                let c = cols[(numRows - 1 - chipRow) % cols.count]
                let arr = KeyboardRGB.buildRowBuffer(r: c.0, g: c.1, b: c.2)
                // 原厂 IL：选行后跟 WriteFeature + Sleep(1)，绝不能回读（回读会清行锁存）
                _ = setRowIndex(chipRow)
                usleep(1_000)
                last = output(arr, rowLen)
            }
        }
        return last
    }

    /// 把整个键盘设成单一颜色。
    ///
    /// 3.0.3.1：改成走 UserMode（0x33）+ 6 行同色矩阵。旧实现是
    /// 「0x14 槽 1 → 0x08 固件码 0x01」，在本机 19.7 固件上 0x01 不生效
    /// （原因见 `setStyle` 里 `.single` 分支的长注释）。
    func setColor(r: Int, g: Int, b: Int, brightness: Int = 75, save: Int = 1, repeat count: Int = 1) throws -> Int {
        let c = [r, g, b]
        let row: [[Int]] = Array(repeating: c, count: numCols)
        let rows: [[[Int]]] = Array(repeating: row, count: numRows)
        return try setKeyMatrix(rows, brightness: brightness, save: save)
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

    /// 总开关状态并入存档（2026-11-18，用户定案）：
    /// 关灯 = 只置 enabled=false，灯效字段原样保留；开灯 = 置 true 后由 apply()
    /// 把存档灯效覆盖回去。绝不把 mode 覆盖成 off —— 否则「开=恢复上次灯效」
    /// 就永远恢复不出来了（旧 bug：关一次灯后开灯无效）。
    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        var p = load() ?? ["mode": on ? "color" : "off", "hex": "#ff9500", "brightness": 75]
        p["enabled"] = on
        return save(p)
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
        guard var prof = profile ?? load() else {
            return ["ok": false, "error": "没有已保存的灯效配置"]
        }
        // 总开关状态（2026-11-18）：关灯时不把 mode 覆盖成 off，只置 enabled=false。
        // 恢复请求（profile 为空 = 开机恢复 / 旧调用）读到 enabled=false 就保持关灯；
        // 用户点「开」走 /api/rgb/apply，路由会先 setEnabled(true) 再到这里。
        if profile == nil, prof["enabled"] as? Bool == false {
            prof = ["mode": "off", "enabled": false]
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
                // 【2026-11-11】AP 软件动画（霓虹/堆叠/冲击）：本机固件 `0x08` 通道
                // 没有 12/13/15 号效果，照旧下发等于把芯片推进未定义态（用户实测：
                // 三个效果「点了都一样」）。配置照存（重启/唤醒后 UI 会按它重放），
                // 画面由 `APEffectEngine` 逐帧算、走 matrix 通道灌下去。
                if let e = KeyboardCatalog.effect(forName: prof["style"] as? String ?? ""),
                   e.isSoftwareAnimation {
                    return ["ok": true, "mode": "effect", "ap": true,
                            "style": KeyboardCatalog.key(for: e),
                            "note": "AP 软件动画：固件无此效果号，由界面逐帧驱动"]
                }
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

            // 2026-10-26：手动应用（save=1）时把画面提交进 NVM，芯片才会记住亮度。
            // 详见 `KeyboardRGB.setPicture` 的注释；save=0 的保活重放一律跳过。
            if save == 1, mode != "off" {
                usleep(20_000)
                _ = kb.setPicture(saved: 1)
            }
        } catch {
            return ["ok": false, "error": "\(error)", "mode": mode, "profile": prof]
        }
        var out: [String: Any] = [
            "ok": kr == 0, "kr": kr, "mode": mode, "profile": prof,
            "led_vendor": WkdColor.vendor.label,
            "led_variant": WkdColor.variantLabel,
        ]
        if let appliedRGB = appliedRGB { out["applied_rgb"] = appliedRGB }
        // 灯真的点亮了：把总开关状态落回存档（开机恢复 / doRGB 各分支共用本函数）
        if kr == 0, mode != "off" {
            prof["enabled"] = true
            _ = RGBProfile.save(prof)   // save 参数（Int）会遮蔽本枚举的 save()，须显式调用
        }
        return out
    }
}

// MARK: - 灯效活动标记（音乐律动帧与恢复动作的互斥信号）

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
// MARK: - AP exist 常驻（控制中心接管 / 键盘灯 10 分钟熄灯，2026-11-11）

/// 让 EC `0x741` bit0 一直是 1 —— 这一位就是文档 §4.2 的 **AP exist：控制软件在线标志**。
///
/// 原厂语义：控制台一打开就下发（`StartTimer_APExistToEC`），60s 续期，退出清 0。
/// 它宣告「有控制中心在管这台机器」；置 1 时 ITE 8291 固件的「十分钟没人管就关灯」
/// 策略被关掉，清 0 就恢复。项目早期把它误叫「手动风扇门」，实测已更正。
/// 详见 `FanControl.assertAPPresent()` 的注释。
///
/// 只在 helper（唯一持有 EC 的进程）里跑；**启动下发一次，之后每 60 秒读一次、
/// 被清掉才补写**，稳态下零写流量。风扇事务结束时也会保留这一位
/// （`FanControl.doorIdleValue`），这里兜底开机 EC 复位、休眠唤醒后状态丢失。
enum ECAPPresentKeeper {
    private static var started = false
    private static let queue = DispatchQueue(label: "com.skycc.appresent", qos: .utility)
    /// 固件计时器是 10 分钟量级，60 秒的守夜足够早。
    private static let interval: TimeInterval = 60

    static func start() {
        guard !started else { return }
        started = true
        _ = FanControl.shared.assertAPPresent()
        queue.async {
            while true {
                Thread.sleep(forTimeInterval: interval)
                autoreleasepool { _ = FanControl.shared.assertAPPresent() }
            }
        }
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
