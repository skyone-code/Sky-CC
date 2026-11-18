import SwiftUI
import AppKit

// MARK: - 皮肤中心（2026-11-15 新功能：app 背景更换）
//
// 只替换**页面背景**这一层（各页 `.background(Theme.bg)` 的位置换成 `.pageBackground()`）：
//   · 预设配色 —— 六套页面底色（浅/深各一档），色板点选即切；
//   · 自定义图片 —— 从本地选一张图，整页铺图 + 底色蒙层压住保证卡片文字可读。
// 卡片（Theme.panel）、控件、文字配色全部不动 —— 「皮肤 = 页面背景」。
// 预设与图片互斥：点任何预设色板自动清掉自定义图片，回到纯色背景。
//
// 持久化：UserDefaults "skin.preset" / "skin.image.path"；
// 图片拷贝进 ~/Library/Application Support/SkyCC/（防原图被移动后失效）。
// 切换即时生效：SkinCenter 是 ObservableObject，从根视图注入，
// pageBackground 修饰器订阅它，任何变更都会触发使用页面的重绘。

final class SkinCenter: ObservableObject {
    static let shared = SkinCenter()

    // MARK: 预设配色

    enum Preset: String, CaseIterable, Identifiable {
        case ink, forest, violet, sand, ocean, rose, glass
        var id: String { rawValue }

        var label: String {
            switch self {
            case .ink:    return "默认"
            case .forest: return "墨绿"
            case .violet: return "紫夜"
            case .sand:   return "暖沙"
            case .ocean:  return "海青"
            case .rose:   return "玫瑰"
            case .glass:  return "玻璃"
            }
        }

        /// 页面底色（浅色外观 / 深色外观）。默认套 = Theme.bg 原值，
        /// 其余各套在明度上贴着原值的档位微调色相，卡片白/深灰底不变。
        /// glass 的底色只作兜底（蒙层 / 色板），玻璃本体走窗口 vibrancy + 染色层。
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

        /// 是否玻璃皮肤（窗口级 vibrancy + 表面超透，见 Theme.surfaceSkin）
        var isGlass: Bool { self == .glass }

        /// 动态底色（按当前外观自动切浅/深档）
        var bgColor: Color { Theme.dyn(light: lightHex, dark: darkHex) }

        /// 设置页色板圆点：用当前外观实际生效的那一档（圆点才和页面看起来一致）
        var swatchColor: Color {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return Color(hex: dark ? darkHex : lightHex)
        }
    }

    // MARK: 状态

    @Published private(set) var preset: Preset
    /// 自定义图片（nil = 未设置，走预设纯色）
    @Published private(set) var customImage: NSImage?
    /// 侧边栏专属背景图（nil = 跟随页面公共背景层，2026-11-15 用户要求）
    @Published private(set) var sidebarImage: NSImage?
    /// 上一个非玻璃皮肤（2026-11-18：玻璃效果开关「关」时回到这里；持久化）
    @Published private(set) var lastNonGlass: Preset

    static let presetKey = "skin.preset"
    static let imagePathKey = "skin.image.path"
    static let sidebarImagePathKey = "skin.sidebar.image.path"
    static let lastPresetKey = "skin.last.preset"

    private init() {
        let d = UserDefaults.standard
        // 2026-11-18（用户要求）：玻璃效果默认打开 —— 首次启动（无存储记录）直接进玻璃皮肤
        preset = Preset(rawValue: d.string(forKey: Self.presetKey) ?? "") ?? .glass
        lastNonGlass = Preset(rawValue: d.string(forKey: Self.lastPresetKey) ?? "") ?? .ink
        if lastNonGlass.isGlass { lastNonGlass = .ink }
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

    /// 玻璃效果开关的当前态（随皮肤自动同步；2026-11-18 改版：开关即选皮肤）
    var glassOn: Bool { preset.isGlass }

    /// 玻璃效果当前是否真正生效：玻璃皮肤 + 没铺自定义图片。
    /// Theme 的背景层 / 表面透明度 / 窗口透明都认这一个口径。
    var isGlassActive: Bool { preset.isGlass && customImage == nil }

    /// 当前页面底色（无自定义图片时 pageBackground 用它铺纯色）
    var bgColor: Color { preset.bgColor }

    // MARK: 操作

    /// 选预设配色：写 UserDefaults + 清自定义图片（两者互斥）
    func select(_ p: Preset) {
        preset = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.presetKey)
        if !p.isGlass {
            lastNonGlass = p
            UserDefaults.standard.set(p.rawValue, forKey: Self.lastPresetKey)
        }
        if isCustomImage { clearCustomImage() }
    }

    /// 玻璃效果开关（2026-11-18 改版：随时可开可关，像系统设置的透明开关）。
    /// 开 = 切到玻璃皮肤；关 = 回到上一个非玻璃皮肤。色板选中玻璃时开关自动为开。
    func setGlassEffect(_ on: Bool) {
        if on {
            guard !preset.isGlass else { return }
            select(.glass)
        } else {
            guard preset.isGlass else { return }
            select(lastNonGlass)
        }
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

    /// 清自定义图片，回到当前预设纯色
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
