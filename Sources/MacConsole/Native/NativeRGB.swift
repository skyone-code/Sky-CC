//
//  NativeRGB.swift
//  Mac控制台 —— ITE 8291 (048d:ce00) 键盘灯控制器 · 原生移植
//
//  对应 Python 版 python后端/rgbkb.py。
//
//  协议逆向来源（三份证据互相印证）:
//    1. OEM Control Center keyboard.dll 导出符号:
//       HID_Get_FirmwareVersion_80H / HID_Set_Effect_Type_08H /
//       HID_Set_Picture_12H / HID_Set_Color_14H / HID_Set_RowIndex_16H
//    2. rodgomesc/avell-unofficial-control-center (rev 0.03，同为 048d:ce00)
//       bmRequestType=0x21, bRequest=0x09, wValue=0x0300 → USB SET_REPORT
//    3. kirainmoe/tongfang-macos issue #28 与 gitlab it829x-reversing
//
//  8 字节 Feature 报告结构:
//    [0] 0x08 命令码  [1] 0x02 下发 / 0x01 熄灯
//    [2] 效果码       [3] 速度 01-0A (1 最快)
//    [4] 亮度 08/16/24/32  [5] 颜色码 01-08
//    [6] 附加(部分效果需要) [7] 保存 00/01
//
//  颜色下发（rev 0.03 真实方式）:
//    enable user mode -> 08 02 33 00 <亮度> 00 00 <保存>
//    然后逐行: 16 00 <row> + 64 字节「分平面」行缓冲
//              [0..20] 蓝 [21..41] 绿 [42..62] 红 [63] 填充
//

import Foundation
import IOKit
import IOKit.hid

// MARK: - 协议常量

private let rgbVID = 0x048d
private let rgbPID = 0xce00

private let brightnessMap: [Int: UInt8] = [1: 0x08, 2: 0x16, 3: 0x24, 4: 0x32]

private let programs: [String: UInt8] = [
    "breathing": 0x02, "wave": 0x03, "random": 0x04, "reactive": 0x04,
    "rainbow": 0x05, "ripple": 0x06, "reactiveripple": 0x07,
    "marquee": 0x09, "raindrop": 0x0A, "aurora": 0x0E,
    "reactiveaurora": 0x0E, "fireworks": 0x11,
]

private let numRows = 6
private let numCols = 21
private let rowLen = 64
private let planeBlue = 0
private let planeGreen = numCols      // 21
private let planeRed = 2 * numCols    // 42

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
    static let pid = rgbPID

    private var dev: HIDDevice?

    static func available() -> Bool {
        !NativeHID.findDevices(vendorID: vid, productID: pid).isEmpty
    }

    init() throws {
        guard let d = NativeHID.findDevices(vendorID: Self.vid, productID: Self.pid).first else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未找到 ITE 8291 键盘灯设备 (048d:ce00)"])
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
        var out: [String: Any] = [
            "product": d.product ?? NSNull(),
            "manufacturer": d.manufacturer ?? NSNull(),
            "vendor_id": String(format: "%#06x", d.vendorID ?? 0),
            "product_id": String(format: "%#06x", d.productID ?? 0),
            "usage_page": String(format: "%#06x", d.usagePage ?? 0),
            "feature_report_size": d.maxFeatureReportSize ?? NSNull(),
            "output_report_size": d.maxOutputReportSize ?? NSNull(),
        ]
        return out
    }

    // MARK: 底层

    /// 发送 8 字节 Feature 报告 (report id = 0)
    private func feature(_ payload8: [UInt8]) -> Int {
        var pkt = payload8 + [UInt8](repeating: 0, count: max(0, 8 - payload8.count))
        pkt = Array(pkt.prefix(8))
        return Int(dev?.setReport(pkt, reportType: kIOHIDReportTypeFeature, reportID: 0) ?? -1)
    }

    /// 发送 Output 报告（颜色向量走这里）
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

    // MARK: 查询

    /// 0x80 查询固件版本
    func getFirmware() -> [String: Any] {
        _ = feature([0x80, 0, 0, 0, 0, 0, 0, 0])
        usleep(200_000)
        guard let d = readFeature(8) else {
            return ["raw": NSNull(), "version_bytes": NSNull()]
        }
        if d[0] == 0x80 {
            return ["raw": hexOf(d), "version_bytes": Array(d[1..<5])]
        }
        return ["raw": hexOf(d), "version_bytes": NSNull()]
    }

    /// 读回当前灯效状态字节
    func getState() -> [String: Any]? {
        guard let d = readFeature(8) else { return nil }
        var st: [String: Any] = [
            "raw": hexOf(d),
            "command": d[0],
            "mode": d[1],
            "program": d[2],
            "speed": d[3],
            "brightness_raw": d[4],
            "colour": d[5],
            "program2": d[6],
        ]
        for (lvl, raw) in brightnessMap where raw == d[4] {
            st["brightness_level"] = lvl
        }
        st["off"] = (d[0] == 0x08 && d[1] == 0x01)
        return st
    }

    // MARK: 控制

    /// 熄灯
    func disable() -> Int {
        feature([0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// 单独调亮度（不改灯效）
    func setBrightness(_ level: Int) throws -> Int {
        guard let raw = brightnessMap[level] else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "亮度等级取值 1-4"])
        }
        return feature([0x08, 0x02, 0x33, 0x00, raw, 0x00, 0x00, 0x00])
    }

    /// 直接下发效果包
    func setEffect(_ programCode: UInt8, speed: Int, brightness: Int,
                   colour: UInt8, program2: UInt8, save: Int) -> Int {
        feature([0x08, 0x02, programCode,
                 UInt8(clamping: speed) & 0xFF, brightnessMap[brightness] ?? 0x24,
                 colour & 0xFF, program2 & 0xFF, UInt8(clamping: save) & 0xFF])
    }

    /// 命令 0x14：把一个 RGB 写进「命名色」槽位（槽位 1-7）
    func setNamedColor(slot: Int, r: Int, g: Int, b: Int) -> Int {
        let s = max(1, min(7, slot))
        return feature([0x14, 0x00, UInt8(s) & 0xFF,
                        UInt8(clamping: r) & 0xFF, UInt8(clamping: g) & 0xFF,
                        UInt8(clamping: b) & 0xFF, 0x00, 0x00])
    }

    /// 按名称设置预设灯效。给了 rgb 就先写命名色槽位再让 colour 指向它。
    func setStyle(name: String, brightness: Int = 3, speed: Int = 5, save: Int = 1,
                  rgb: [Int]? = nil, slot: Int = 1) throws -> Int {
        guard let prog = programs[name] else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "未知灯效: \(name)"])
        }
        var colour: UInt8 = 0x08
        var prog2: UInt8 = 0x00
        switch name {
        case "rainbow": colour = 0x00
        case "marquee": colour = 0x08
        case "wave": colour = 0x00; prog2 = 0x01
        case "reactive", "reactiveaurora", "fireworks": prog2 = 0x01
        default: break
        }
        if let rgb = rgb {
            setNamedColor(slot: slot, r: rgb[0], g: rgb[1], b: rgb[2])
            usleep(50_000)
            colour = UInt8(slot & 0xFF)
        }
        return setEffect(prog, speed: speed, brightness: brightness,
                         colour: colour, program2: prog2, save: save)
    }

    /// 0x16 选择要写入的行 (0-5)
    func setRowIndex(_ row: Int) -> Int {
        feature([0x16, 0x00, UInt8(row) & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    /// 构造一行 64 字节的平面缓冲：蓝平面21 + 绿平面21 + 红平面21 + 填充
    static func buildRowBuffer(r: Int, g: Int, b: Int) -> [UInt8] {
        var arr = [UInt8](repeating: 0, count: rowLen)
        for i in 0..<numCols {
            arr[planeBlue + i] = UInt8(clamping: b) & 0xFF
            arr[planeGreen + i] = UInt8(clamping: g) & 0xFF
            arr[planeRed + i] = UInt8(clamping: r) & 0xFF
        }
        return arr
    }

    /// 进入用户自定义颜色模式 = 效果码 0x33
    func userMode(save: Int = 1, brightness: Int = 3) -> Int {
        feature([0x08, 0x02, 0x33, 0x00,
                 brightnessMap[brightness] ?? 0x24, 0x00, 0x00, UInt8(save) & 0xFF])
    }

    /// 按行下发颜色（键盘 6 行 × 21 列）
    func setZoneColors(_ zones: [[Int]], repeat count: Int = 1, save: Int = 1) throws -> Int {
        guard !zones.isEmpty else {
            throw NSError(domain: "KeyboardRGB", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "zones 不能为空"])
        }
        let cols = zones.map { RGBGains.apply(($0[0], $0[1], $0[2])) }
        var last = -1
        for _ in 0..<max(1, count) {
            for row in 0..<numRows {
                let (r, g, b) = cols[row % cols.count]
                let arr = KeyboardRGB.buildRowBuffer(r: r, g: g, b: b)
                _ = setRowIndex(row)
                usleep(20_000)
                last = output(arr, rowLen)
            }
        }
        return last
    }

    /// 把整个键盘设成单一颜色（完整流程）
    func setColor(r: Int, g: Int, b: Int, brightness: Int = 4, save: Int = 1, repeat count: Int = 1) throws -> Int {
        _ = userMode(save: save, brightness: brightness)
        usleep(50_000)
        return try setZoneColors([[r, g, b]], repeat: count, save: save)
    }
}

// MARK: - 颜色小工具

enum RGBUtil {
    static func hexToRgb(_ s: String) -> [Int] {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6 else { return [255, 149, 0] }
        return [(0, 2), (2, 4), (4, 6)].map { Int(h[$0..<$1], radix: 16) ?? 0 }
    }

    static func rgbToHex(_ rgb: [Int]) -> String {
        String(format: "#%02x%02x%02x", rgb[0] & 0xFF, rgb[1] & 0xFF, rgb[2] & 0xFF)
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

    /// 把 server 的 /api/rgb 参数归一化成可保存的 profile
    static func fromParams(_ params: [String: Any]) -> [String: Any] {
        let mode = params["mode"] as? String ?? "color"
        switch mode {
        case "off":
            return ["mode": "off"]
        case "brightness":
            return ["mode": "brightness", "brightness": params["level"] as? Int ?? 3]
        case "effect":
            var prof: [String: Any] = [
                "mode": "effect",
                "style": params["style"] as? String ?? "rainbow",
                "brightness": params["brightness"] as? Int ?? 3,
                "speed": params["speed"] as? Int ?? 5,
            ]
            if let hex = params["hex"] as? String {
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
            return ["mode": "zones", "brightness": params["brightness"] as? Int ?? 4, "zones": zones]
        default:
            var hx = (params["hex"] as? String ?? "#ff9500")
            hx = hx.hasPrefix("#") ? String(hx.dropFirst()) : hx
            var rgb = RGBUtil.hexToRgb(hx)
            if hx.count != 6 || rgb.contains(where: { $0 < 0 }) {
                hx = "ff9500"
                rgb = [255, 149, 0]
            }
            return ["mode": "color", "hex": hx, "rgb": rgb,
                    "brightness": params["brightness"] as? Int ?? 4]
        }
    }

    /// 按配置恢复灯效。返回 {'ok','kr','mode','profile','gains','applied_rgb'}
    static func apply(_ profile: [String: Any]? = nil) -> [String: Any] {
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
            switch mode {
            case "off":
                kr = kb.disable()
            case "brightness":
                kr = try kb.setBrightness(prof["brightness"] as? Int ?? 3)
            case "effect":
                var effRGB: [Int]? = prof["rgb"] as? [Int]
                if effRGB == nil, let hex = prof["hex"] as? String {
                    effRGB = RGBUtil.hexToRgb(hex)
                }
                kr = try kb.setStyle(name: prof["style"] as? String ?? "rainbow",
                                     brightness: prof["brightness"] as? Int ?? 3,
                                     speed: prof["speed"] as? Int ?? 5,
                                     save: 1,
                                     rgb: effRGB,
                                     slot: prof["slot"] as? Int ?? 1)
            case "zones":
                _ = try kb.setBrightness(prof["brightness"] as? Int ?? 4)
                usleep(50_000)
                let zones = (prof["zones"] as? [[Any]] ?? []).map { z in
                    [z[0] as? Int ?? 0, z[1] as? Int ?? 0, z[2] as? Int ?? 0]
                }
                guard !zones.isEmpty else {
                    return ["ok": false, "error": "配置里的 zones 为空"]
                }
                kr = try kb.setZoneColors(zones, repeat: 1, save: 1)
            default:  // color
                let rgb: [Int]
                if let r = prof["rgb"] as? [Int], r.count == 3 {
                    rgb = r
                } else {
                    rgb = RGBUtil.hexToRgb(prof["hex"] as? String ?? "#ff9500")
                }
                _ = try kb.setBrightness(prof["brightness"] as? Int ?? 4)
                usleep(50_000)
                kr = try kb.setZoneColors([rgb], repeat: 1, save: 1)
                let (ar, ag, ab) = RGBGains.apply((rgb[0], rgb[1], rgb[2]))
                appliedRGB = [ar, ag, ab]
            }
        } catch {
            return ["ok": false, "error": "\(error)", "mode": mode, "profile": prof]
        }
        var out: [String: Any] = [
            "ok": kr == 0, "kr": kr, "mode": mode, "profile": prof,
            "gains": [RGBGains.load().0, RGBGains.load().1, RGBGains.load().2],
        ]
        if let appliedRGB = appliedRGB { out["applied_rgb"] = appliedRGB }
        return out
    }
}

// MARK: - 白色光谱校准（对应 rgbkb 的 gains 段）

/// 实测：下发纯白 (255,255,255) 时键盘明显偏蓝 —— 蓝光 LED 效率远高于红/绿。
/// 让用户指出"纯白指令下肉眼看到的实际颜色"，转到线性光空间后以最弱通道为
/// 基准反算三通道衰减增益；只衰减过强通道。增益单位千分比，1000 = 不衰减。
enum RGBGains {
    static func load() -> (Int, Int, Int) {
        guard let data = try? Data(contentsOf: gainURL),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        var payload: [String: Any] = ["R": g.0, "G": g.1, "B": g.2]
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

    /// 把校准增益作用到一个 (r,g,b) 上
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

    /// 由「看到的颜色」反算三通道增益。observed 形如 '7f9bff'
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

/// 滑条只在「中性白(1000,1000,1000)」与一个可变端点之间线性插值：
///     gain(t) = 1000 - (1000 - end) * t / 100
/// 默认端点 (1000, 300, 200)；用户做过一次色块标定后端点被替换为标定结果。
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

    /// 滑条位置 0-100 → 增益三元组（中性白 → 端点 线性插值）
    static func toGains(_ t: Double) -> (Int, Int, Int) {
        let end = loadEndpoint()
        let tt = max(0, min(100, t))
        // Python round() 是银行家舍入，这里保持同款
        let f = { (e: Int) -> Int in
            Int((1000 - Double(1000 - e) * tt / 100.0).rounded(.toNearestOrEven))
        }
        return (f(end.0), f(end.1), f(end.2))
    }

    /// 增益三元组 → 滑条位置 0-100（取三通道中偏离中性最大的那个）
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
