//
//  NativeWkdColor.swift
//  Sky CC —— 原厂 LED 颜色补偿（WKDColor / cheatRGB_*）原生移植
//
//  来源：Windows 原厂 DefaultRGBKB.exe 反编译
//        LightingModel.WKDColor.cheatRGB_2ndME / cheatRGB_2p1ndME / cheatRGB_4Zone
//
//  为什么需要这一层：
//    这块键盘的三色 LED 亮度严重不平衡（蓝光偏强）。把用户选的 sRGB 值
//    直接当 PWM 发给芯片，纯白 255,255,255 出来是偏蓝的。原厂在交给 HID
//    之前先做一道固定的通道压缩：
//        Liteon    : R'=R, G'=50*G/255,  B'=170*B/255   （纯白 255,50,170）
//        Everlight : R'=R, G'=70*G/255,  B'=80*B/255    （纯白 255,70,80）
//        未知      : R'=R, G'=180*G/255, B'=200*B/255   （纯白 255,180,200）
//
//  供应商判定：读 EC 0x742（原厂 SupportByte5 / 十进制 1858）
//        bit2 (0x04) 置位 → Liteon
//        bit3 (0x08) 置位 → Everlight
//        都没置位           → Unknown（走最保守的第三套）
//
//  纯三原色（红/绿/蓝）原样放行 —— 单色只点亮一颗 LED，不存在配比问题。
//  这也解释了为什么只有混色（尤其白）偏色。
//

import Foundation

/// 键盘型号族：决定用哪一套补偿曲线。
enum KeyboardVariant {
    case meZone2nd      // MEZone_2nd_101 / 102（本机）
    case meZone2p1nd
    case fourZone
}

/// LED 供应商。数值与原厂常量一致（m_bitLiteon = 4 / m_bitEverlight = 8）。
enum LedVendor: UInt8 {
    case unknown = 0
    case liteon = 4
    case everlight = 8

    var label: String {
        switch self {
        case .liteon: return "Liteon"
        case .everlight: return "Everlight"
        case .unknown: return "Unknown"
        }
    }
}

enum WkdColor {
    /// 当前供应商。未探测时走原厂"未知"曲线，比不补偿更接近原厂观感。
    static var vendor: LedVendor = .unknown
    static var variant: KeyboardVariant = .meZone2nd
    /// 最近一次读到的 0x742 原始值（诊断用）。
    private(set) static var rawSupportByte5: UInt8?

    /// 按 EC 0x742 原始值判供应商（原厂静态构造里的同款逻辑）。
    @discardableResult
    static func detect(rawSupportByte5 value: UInt8?) -> LedVendor {
        guard let v = value else { return vendor }
        rawSupportByte5 = v
        if v & 0x04 != 0 { vendor = .liteon }
        else if v & 0x08 != 0 { vendor = .everlight }
        else { vendor = .unknown }
        return vendor
    }

    /// 键盘世代（原厂 `Is2p1nd`）：握手 VerHigh == 19 即 2.1 代，要换成 2p1nd 曲线。
    ///
    /// 移植文档 §3.5 / §16.1：「Is2p1nd = 握手 VerHigh==19」。
    /// 本机握手回 `80 13 07 00 …`（VerHigh = 0x13 = 19）→ 走 `cheatRGB_2p1ndME`。
    /// 以前这里是常量 `.meZone2nd`、从不按握手切换，等于一直在用 2.0 代曲线。
    ///
    /// 想临时回退到旧曲线：`defaults write com.macconsole.helper mcWkdForce2nd -bool YES`
    @discardableResult
    static func detectVariant(fwMajor: Int) -> KeyboardVariant {
        if UserDefaults.standard.bool(forKey: "mcWkdForce2nd") {
            variant = .meZone2nd
        } else {
            variant = (fwMajor == 19) ? .meZone2p1nd : .meZone2nd
        }
        return variant
    }

    static var variantLabel: String {
        switch variant {
        case .meZone2nd:   return "MEZone_2nd"
        case .meZone2p1nd: return "MEZone_2.1nd"
        case .fourZone:    return "4Zone"
        }
    }

    /// 把用户选的颜色换算成实际下发给 LED 的值。
    static func convert(_ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int) {
        let rr = UInt8(clamping: r), gg = UInt8(clamping: g), bb = UInt8(clamping: b)
        let out: (UInt8, UInt8, UInt8)
        switch variant {
        case .meZone2p1nd: out = cheat2p1ndME(rr, gg, bb)
        case .fourZone:    out = cheat4Zone(rr, gg, bb)
        case .meZone2nd:   out = cheat2ndME(rr, gg, bb)
        }
        return (Int(out.0), Int(out.1), Int(out.2))
    }

    // ─────────────────────────── cheatRGB_2ndME ───────────────────────────

    private static func cheat2ndME(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        switch vendor {
        case .liteon:    return liteon(r, g, b)
        case .everlight: return everlight(r, g, b)
        case .unknown:   return unknown(r, g, b)
        }
    }

    private static func liteon(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        if r == 255 && g == 255 && b == 255 { return (255, 50, 170) }
        if r == 243 && g == 152 && b == 0   { return (255, 19, 0) }
        if r == 255 && g == 241 && b == 0   { return (255, 50, 0) }
        if r == 0   && g == 255 && b == 255 { return (0, 50, 170) }
        if r == 138 && g == 0   && b == 255 { return (138, 0, 170) }

        // 暖色微调：红强、绿弱、蓝不深
        if r > 249 && g < 20 && b < 128 {
            return b < 100 ? (r, g, b / 10) : (r, g, b - 10)
        }
        if r < 20 && b < g { return (r, g, UInt8(170 * Int(b) / 255)) }
        if g < 20 && r < b { return (r, g, b) }
        return (r, UInt8(50 * Int(g) / 255), UInt8(170 * Int(b) / 255))
    }

    private static func everlight(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        if r == 255 && g == 255 && b == 255 { return (255, 70, 80) }
        if r == 243 && g == 152 && b == 0   { return (255, 25, 0) }
        if r == 241 && g == 90  && b == 36  { return (255, 5, 0) }
        if r == 247 && g == 147 && b == 30  { return (255, 15, 0) }
        if r == 255 && g == 241 && b == 0   { return (255, 70, 0) }
        if r == 0   && g == 255 && b == 255 { return (0, 70, 80) }
        if r == 138 && g == 0   && b == 255 { return (138, 0, 80) }

        if r > 249 && g < 20 && b < 128 {
            return b < 100 ? (r, g, b / 10) : (r, g, b - 10)
        }
        if r < 20 && b < g { return (r, g, UInt8(80 * Int(b) / 255)) }
        if g < 20 && r < b { return (r, g, b) }
        return (r, UInt8(70 * Int(g) / 255), UInt8(80 * Int(b) / 255))
    }

    private static func unknown(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        if r == 255 && g == 255 && b == 255 { return (255, 180, 200) }
        if r == 243 && g == 152 && b == 0   { return (255, 42, 0) }
        if r == 241 && g == 90  && b == 36  { return (255, 25, 0) }
        if r == 247 && g == 147 && b == 30  { return (255, 42, 0) }
        if r == 255 && g == 241 && b == 0   { return (255, 180, 0) }
        if r == 0   && g == 255 && b == 255 { return (0, 180, 200) }
        if r == 138 && g == 0   && b == 255 { return (138, 0, 200) }

        if r > 249 && g < 20 && b < 128 {
            return b < 100 ? (r, g, b / 10) : (r, g, b - 10)
        }
        if r < 20 && b < g { return (r, g, UInt8(200 * Int(b) / 255)) }
        if g < 20 && r < b { return (r, g, b) }
        return (r, UInt8(180 * Int(g) / 255), UInt8(200 * Int(b) / 255))
    }

    // ─────────────────────────── 其他变体 ───────────────────────────

    private static func cheat2p1ndME(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        if r == 255 && g == 255 && b == 255 { return (180, 105, 85) }
        if r == 243 && g == 152 && b == 0   { return (180, 30, 0) }
        if r == 255 && g == 241 && b == 0   { return (180, 105, 0) }
        if r == 0   && g == 255 && b == 255 { return (0, 105, 85) }
        if r == 138 && g == 0   && b == 255 { return (180, 0, 85) }
        return (UInt8(180 * Int(r) / 255), UInt8(105 * Int(g) / 255), UInt8(85 * Int(b) / 255))
    }

    private static func cheat4Zone(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        if r == 243 && g == 152 && b == 0 { return (255, 60, 0) }
        if r == 255 && g == 241 && b == 0 { return (255, 180, 0) }
        return (r, UInt8(180 * Int(g) / 255), b)
    }
}
