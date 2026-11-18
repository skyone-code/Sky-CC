import SwiftUI
import AppKit

// MARK: - 皮肤中心（2026-11-18 三版重构：预设全删 → 色板自选颜色 + 玻璃独立开关）
//
// 用户定案：「预设不保留，直接给一个色板，点开可以自行选择颜色」。
// 玻璃效果从预设成员里拆出来成为真正的独立开关 —— 色板管颜色、玻璃管材质，
// 两者正交可叠加（玻璃开着时，页面染色跟随所选颜色）。
//
// 只替换**页面背景**这一层（各页 `.background(Theme.bg)` 的位置换成 `.pageBackground()`）：
//   · 色板颜色 —— 浅色/深色外观各记一色，点选即改当前外观那一档；
//   · 玻璃效果 —— 窗口 vibrancy + 本体透明 + 染色层（染色 = 所选颜色）；
//   · 自定义图片 —— 整页铺图 + 底色蒙层压住保证卡片文字可读（与玻璃互斥）。
// 卡片（Theme.panel）、控件、文字配色全部不动 —— 「皮肤 = 页面背景」。
//
// 持久化：UserDefaults "skin.color.light" / "skin.color.dark" / "skin.glass.on"
//         / "skin.image.path"；图片拷贝进 ~/Library/Application Support/SkyCC/。
// 切换即时生效：SkinCenter 是 ObservableObject，从根视图注入，
// pageBackground 修饰器订阅它，任何变更都会触发使用页面的重绘。

final class SkinCenter: ObservableObject {
    static let shared = SkinCenter()

    // MARK: 状态

    /// 自选底色（浅色 / 深色外观各一档；色板改的是当前外观那一档）
    @Published private(set) var colorLight: UInt32
    @Published private(set) var colorDark: UInt32
    /// 玻璃效果独立开关（窗口透明 + 磨砂透桌面；默认开）
    @Published private(set) var glassOn: Bool
    /// 自定义图片（nil = 未设置，走色板纯色）
    @Published private(set) var customImage: NSImage?
    /// 侧边栏专属背景图（nil = 跟随页面公共背景层，2026-11-15 用户要求）
    @Published private(set) var sidebarImage: NSImage?

    static let colorLightKey = "skin.color.light"
    static let colorDarkKey = "skin.color.dark"
    static let glassKey = "skin.glass.on"
    static let imagePathKey = "skin.image.path"
    static let sidebarImagePathKey = "skin.sidebar.image.path"
    /// 旧版预设键（3.2.2 前的 7 色板），仅用于一次性迁移读取
    private static let legacyPresetKey = "skin.preset"

    /// 默认色 = 旧「默认」预设的两档底色
    static let defaultLight: UInt32 = 0xf6f7f9
    static let defaultDark: UInt32 = 0x1e1f21

    private init() {
        let d = UserDefaults.standard

        // 一次性迁移：旧预设值 → 新模型。选过玻璃 → 玻璃开；选过实色 → 玻璃关、
        // 该预设的浅/深两档色值抄进色板；没记录 → 玻璃开（2026-11-18 默认玻璃）+ 默认色。
        let legacy = d.string(forKey: Self.legacyPresetKey)
        glassOn = d.object(forKey: Self.glassKey) as? Bool
            ?? (legacy == "glass" || legacy == nil)

        if let lv = d.object(forKey: Self.colorLightKey) as? UInt32,
           let dv = d.object(forKey: Self.colorDarkKey) as? UInt32 {
            colorLight = lv; colorDark = dv
        } else if let old = legacy, let p = LegacyPreset(rawValue: old) {
            colorLight = p.lightHex; colorDark = p.darkHex
        } else {
            colorLight = Self.defaultLight; colorDark = Self.defaultDark
        }
        d.removeObject(forKey: Self.legacyPresetKey)
        d.removeObject(forKey: "skin.last.preset")

        if let path = d.string(forKey: Self.imagePathKey),
           let img = NSImage(contentsOfFile: path) {
            customImage = img
        } else {
            // 图丢了（被手动删掉等）→ 静默回纯色，把失效记录清掉
            d.removeObject(forKey: Self.imagePathKey)
        }
        if let path = d.string(forKey: Self.sidebarImagePathKey),
           let img = NSImage(contentsOfFile: path) {
            sidebarImage = img
        } else {
            d.removeObject(forKey: Self.sidebarImagePathKey)
        }
    }

    var isCustomImage: Bool { customImage != nil }
    var hasSidebarImage: Bool { sidebarImage != nil }

    /// 玻璃效果当前是否真正生效：玻璃开关开 + 没铺自定义图片。
    /// Theme 的背景层 / 表面透明度 / 窗口透明都认这一个口径。
    var isGlassActive: Bool { glassOn && customImage == nil }

    /// 当前外观的底色 hex（供 pageBackground / 蒙层 / 色板取值）
    private var currentHex: UInt32 {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? colorDark : colorLight
    }

    /// 当前页面底色（无自定义图片时 pageBackground 用它铺纯色）
    var bgColor: Color { Theme.dyn(light: colorLight, dark: colorDark) }

    /// ColorPicker 绑定用：当前外观那一档的颜色
    var pickerColor: Color { Color(hex: currentHex) }

    // MARK: 操作

    /// 色板选色：写到当前外观那一档（另一档不动）
    func setColor(_ c: Color) {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
        let hex = UInt32(round(ns.redComponent * 255)) << 16
              | UInt32(round(ns.greenComponent * 255)) << 8
              | UInt32(round(ns.blueComponent * 255))
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark { colorDark = hex } else { colorLight = hex }
        UserDefaults.standard.set(hex, forKey: dark ? Self.colorDarkKey : Self.colorLightKey)
    }

    /// 恢复默认底色（2026-11-18 用户要求）：浅/深两档一起回出厂值，玻璃开关不动
    func resetColor() {
        colorLight = Self.defaultLight
        colorDark = Self.defaultDark
        let d = UserDefaults.standard
        d.set(colorLight, forKey: Self.colorLightKey)
        d.set(colorDark, forKey: Self.colorDarkKey)
    }

    /// 玻璃效果开关：只切材质，与所选颜色无关
    func setGlassEffect(_ on: Bool) {
        glassOn = on
        UserDefaults.standard.set(on, forKey: Self.glassKey)
    }

    /// 设置自定义图片：拷贝进 App 支持目录持久化，成功返回 true
    @discardableResult
    func setCustomImage(from source: URL) -> Bool {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkyCC", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ok = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp"]
        let ext = ok.contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "png"
        let dest = dir.appendingPathComponent("skin-background.\(ext)")
        // 清掉旧扩展名的副本，目录里永远只有当前一张
        for e in ok where e != ext {
            try? fm.removeItem(at: dir.appendingPathComponent("skin-background.\(e)"))
        }
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: source, to: dest) } catch { return false }
        guard let img = NSImage(contentsOfFile: dest.path) else {
            try? fm.removeItem(at: dest)
            return false
        }
        customImage = img
        UserDefaults.standard.set(dest.path, forKey: Self.imagePathKey)
        return true
    }

    /// 清自定义图片，回到当前色板纯色
    func clearCustomImage() {
        if let p = UserDefaults.standard.string(forKey: Self.imagePathKey) {
            try? FileManager.default.removeItem(atPath: p)
        }
        customImage = nil
        UserDefaults.standard.removeObject(forKey: Self.imagePathKey)
    }

    // MARK: 侧边栏专属背景（2026-11-15：与页面背景分开选图；不选 = 跟随公共背景层）

    /// 设置侧边栏背景图（拷贝持久化，文件名前缀区分页面背景那张）
    @discardableResult
    func setSidebarImage(from source: URL) -> Bool {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkyCC", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ok = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp", "webp"]
        let ext = ok.contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "png"
        let dest = dir.appendingPathComponent("skin-sidebar.\(ext)")
        for e in ok where e != ext {
            try? fm.removeItem(at: dir.appendingPathComponent("skin-sidebar.\(e)"))
        }
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: source, to: dest) } catch { return false }
        guard let img = NSImage(contentsOfFile: dest.path) else {
            try? fm.removeItem(at: dest)
            return false
        }
        sidebarImage = img
        UserDefaults.standard.set(dest.path, forKey: Self.sidebarImagePathKey)
        return true
    }

    /// 清侧边栏背景图，回到跟随页面公共背景层
    func clearSidebarImage() {
        if let p = UserDefaults.standard.string(forKey: Self.sidebarImagePathKey) {
            try? FileManager.default.removeItem(atPath: p)
        }
        sidebarImage = nil
        UserDefaults.standard.removeObject(forKey: Self.sidebarImagePathKey)
    }
}

/// 旧 7 色板（3.2.2 前的预设，仅供迁移读取色值，不再出现在任何 UI 里）
private enum LegacyPreset: String {
    case ink, forest, violet, sand, ocean, rose, glass

    var lightHex: UInt32 {
        switch self {
        case .ink:    return 0xf6f7f9
        case .forest: return 0xeef3ee
        case .violet: return 0xf1eef7
        case .sand:   return 0xf7f2ea
        case .ocean:  return 0xeaf3f5
        case .rose:   return 0xf7eef0
        case .glass:  return 0xf0f3fb
        }
    }
    var darkHex: UInt32 {
        switch self {
        case .ink:    return 0x1e1f21
        case .forest: return 0x18201b
        case .violet: return 0x1e1a27
        case .sand:   return 0x221f1a
        case .ocean:  return 0x161f23
        case .rose:   return 0x241a1d
        case .glass:  return 0x1e2126
        }
    }
}
