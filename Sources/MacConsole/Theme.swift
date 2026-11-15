import SwiftUI
import AppKit

/// 全局视觉主题。
/// v2.4.3（2026-10-19）：全面支持深色模式——底色/文字/描边/强调色全部改为
/// 动态色（NSColor dynamicProvider，按当前 appearance 解析浅/深两套值）。
/// 之前只有侧边栏会随系统变色、内容区不变，就是这里全部写死浅色的缘故。
/// 用户可在「系统 → 外观」强制浅色/深色/随系统（UserDefaults "appearance"）。
/// 注意：键盘灯效页有「白色」颜色选项，所有色块/色板必须带描边，白底上才看得见。
// MARK: - 卡片说明文字的全局开关（2.8.9）
//
// 用户要求：除「实验性」页以外，所有页面的**卡片标题后缀、分组说明、开关副标题、
// 底部小字注释**一律隐藏（代码保留，不删）。
// 默认 true = 隐藏；实验性页已删除（2026-11-14），需要显示副标题的页面自行覆写。
private struct HideCardSubsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var hideCardSubs: Bool {
        get { self[HideCardSubsKey.self] }
        set { self[HideCardSubsKey.self] = newValue }
    }
}

/// 卡片说明文字的通用开关：`hideCardSubs = true`（默认）时整段不渲染。
/// 用法：`Text("…").font(…).foregroundStyle(Theme.dim2).cardNote()`
private struct CardNoteModifier: ViewModifier {
    @Environment(\.hideCardSubs) private var hideCardSubs

    @ViewBuilder
    func body(content: Content) -> some View {
        if hideCardSubs { EmptyView() } else { content }
    }
}

extension View {
    /// 2.8.9：把一段「说明文字」接到全局隐藏开关上（代码保留，只是不显示）
    func cardNote() -> some View { modifier(CardNoteModifier()) }
}

// MARK: - 页面背景（2026-11-15 皮肤功能）
//
// 各页原来的 `.background(Theme.bg)` 统一换成 `.pageBackground()`：
//   · 无自定义图片 → 铺 SkinCenter 当前预设底色（动态浅/深）；
//   · 有自定义图片 → 整页铺图（scaledToFill + 裁边）再压一层底色蒙层
//     （不透明度 0.72，卡片文字可读性优先），卡片本身依旧是不透明 panel。
// 订阅 SkinCenter：设置页换皮肤 / 换图后，所有挂了本修饰器的页面立即重绘。
struct PageBackgroundModifier: ViewModifier {
    @EnvironmentObject private var skin: SkinCenter
    @Environment(\.colorScheme) private var colorScheme

    /// 图片蒙层不透明度：2026-11-15 用户定案 —— 浅色外观下背景图太淡，
    /// 多给 20% 显示（0.72 → 0.52）；深色维持 0.72。
    private var maskOpacity: Double { colorScheme == .light ? 0.52 : 0.72 }

    func body(content: Content) -> some View {
        ZStack {
            if let img = skin.customImage {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()
                }
                .ignoresSafeArea()
                skin.bgColor.opacity(maskOpacity).ignoresSafeArea()
            } else {
                skin.bgColor.ignoresSafeArea()
            }
            content
        }
    }
}

extension View {
    /// 页面背景：预设纯色或自定义图片 + 蒙层（皮肤功能入口，见 PageBackgroundModifier）
    func pageBackground() -> some View { modifier(PageBackgroundModifier()) }
}

// MARK: - 侧边栏背景（2026-11-15）
//
// 公共背景层在根视图（RootView 整个 NavigationSplitView 外面铺一次），
// 侧边栏 List 只铺半透明 panel 透下去。本修饰器处理「侧边栏专属图片」：
// 选了侧边栏背景图时，在 panel 下面铺图 + 蒙层（遮住公共层）；没选则不铺、
// 直接透到公共背景层 —— 不再有独立的第二层背景。
struct SidebarBackgroundModifier: ViewModifier {
    @EnvironmentObject private var skin: SkinCenter
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            if let img = skin.sidebarImage {
                GeometryReader { geo in
                    ZStack {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        skin.bgColor.opacity(colorScheme == .light ? 0.52 : 0.72)
                    }
                }
            }
        }
    }
}

extension View {
    /// 侧边栏背景：选了专属图就铺图+蒙层，否则透明透到公共背景层
    func sidebarBackground() -> some View { modifier(SidebarBackgroundModifier()) }
}

enum Theme {
    // 底色系（浅色 / 深色）
    // 2.8.11（用户要求）：深色下页面底太黑，按系统设置（macOS 深色）的观感整体提亮：
    //   页面底 ≈ 系统 windowBackground，卡片比底色略亮一档，控件再亮一档。
    //   原来是 0x17191d / 0x22252a / 0x2c3037，确实压得太死。
    static let bg = Theme.dyn(light: 0xf6f7f9, dark: 0x1e1f21)        // 页面底

    // 表面色（卡片 / 控件 / 进度条底）—— 皮肤 + 外观双感知（2026-11-15 用户定案）：
    // 默认皮肤（ink 且无图片）= 原值实色，观感与历史版本完全一致；
    // 非默认预设配色 / 自定义图片时按透明度返色，背景从下面透出来。
    // 深色透明度基准 = hero 条的 panel 0.72（2026-11-15 用户定：「都做成 hero 那种」）；
    // **浅色外观整体再多透 10%**（panel 0.62 / panel2 0.28 / barBg 0.35）——
    // 用户反馈浅色下卡片、胶囊、侧边栏透明度不够。
    // panel2 / barBg 是**叠在卡片内**的二级表面：必须比卡片那层更透，否则叠成实色。
    // 用 computed var + 外观动态提供器：所有 fill/background(Theme.panel*) 调用点一次性生效。
    static var panel: Color { surfaceSkin(light: 0xffffff, dark: 0x2a2b2e, alphaLight: 0.62, alphaDark: 0.72) } // 卡片
    static var panel2: Color { surfaceSkin(light: 0xeef0f4, dark: 0x34353a, alphaLight: 0.28, alphaDark: 0.38) } // 卡片内磁贴 / 控件底
    static var barBg: Color { surfaceSkin(light: 0xe6e9ee, dark: 0x3a3b40, alphaLight: 0.35, alphaDark: 0.45) }  // 进度条底
    static let line = Theme.dyn(light: 0xe0e3e9, dark: 0x3e3f44)      // 描边

    /// 表面色的皮肤 + 外观开关：默认皮肤返实色；否则按当前外观给不同透明度
    /// （透明度也要随外观切换，所以不能在 base 上简单 .opacity —— 包一层动态提供器）
    private static func surfaceSkin(light: UInt32, dark: UInt32,
                                    alphaLight: Double, alphaDark: Double) -> Color {
        let skin = SkinCenter.shared
        if skin.preset == .ink && !skin.isCustomImage { return Theme.dyn(light: light, dark: dark) }
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? alphaDark : alphaLight)
        }))
    }

    // 文字系（灰阶；深色下整体提亮，不用纯白）
    // txt 浅色 0x2a2f37 → 0x4d545e（2026-11-15 用户反馈：浅色下黑字太扎眼，改灰；
    // 但必须比小提示的灰（dim 0x626b78）更深，不能撞色 —— 0x4d545e 介于两者之间）
    static let txt = Theme.dyn(light: 0x4d545e, dark: 0xe8eaef)       // 主文字
    static let dim = Theme.dyn(light: 0x626b78, dark: 0xa6aeb9)       // 次文字
    static let dim2 = Theme.dyn(light: 0x8b94a1, dark: 0x7b8290)      // 弱文字

    // 强调色（浅色下是白底可读的低饱和版；深色下换成提亮版，深底上也清晰）
    static let blue = Theme.dyn(light: 0x2f6fd6, dark: 0x5b9bf0)
    static let cyan = Theme.dyn(light: 0x0e8fa8, dark: 0x2bb8d4)
    static let green = Theme.dyn(light: 0x1f9d55, dark: 0x3cc47a)
    static let amber = Theme.dyn(light: 0xb97a0a, dark: 0xe0a83c)
    static let red = Theme.dyn(light: 0xcf3a3e, dark: 0xef5a5e)
    static let purple = Theme.dyn(light: 0x7355d6, dark: 0x9b82e8)

    static let accentGradient = LinearGradient(
        colors: [Theme.blue, Theme.cyan],
        startPoint: .leading, endPoint: .trailing)

    /// 动态色：按当前 appearance 在浅/深两套之间切换。
    /// 用 NSColor dynamicProvider 而不是 Asset Catalog——本工程 swiftc 直编，
    /// 没有 xcassets 资源编译阶段；bestMatch 能正确处理 vibrant / 高对比变体。
    static func dyn(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            // bestMatch 返回 NSAppearance.Name?，能正确处理 vibrant / 高对比变体
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension NSColor {
    /// 0xRRGGBB → NSColor（sRGB，供 Theme.dyn 的 dynamicProvider 用）
    /// （拆成本地变量：NSColor(sRGBRed:) 重载多，整行位运算会让类型检查器超时）
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// 外观模式（v2.4.3）：浅色 / 深色 / 随系统。
/// 持久化在 UserDefaults "appearance"，切换时立即写 NSApp.appearance 并全界面生效。
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "随系统"
        }
    }
    var symbol: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "laptopcomputer"
        }
    }
    static let defaultsKey = "appearance"
    /// 当前选择（没存过 = 随系统）
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }
    /// 应用到 NSApp：light/dark 写死外观；system 置 nil，跟随 macOS 自动切换
    func apply() {
        switch self {
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApplication.shared.appearance = nil
        }
    }
}

/// 卡片/分组标题的样式化。
///
/// 原本一律 `uppercased()`，但 dGPU / iGPU 这类标识符有语义大小写，
/// 转成全大写就成了 DGPU，读起来像缩写而不是「d + GPU」。
/// 规则：含小写字母的原样保留（中文没有大小写，不受影响），其余仍转大写 ——
/// 所以 CPU / 内存 / 风扇这些老标题的显示效果一点没变。
func styledLabel(_ t: String) -> String {
    t.contains(where: { $0.isLowercase }) ? t : t.uppercased()
}

/// 圆角卡片容器
struct Card<Content: View>: View {
    var title: String? = nil
    /// 标题文字**紧跟其后**的一个小徽标（2026-11-08 新增，给 GPU 卡的降频提示用）。
    /// 与 `trailing` 的区别：badge 贴着标题排、跟着标题走；trailing 靠右对齐。
    /// 默认 nil，所有既有 Card 调用不受影响。
    var badge: (() -> AnyView)? = nil
    var trailing: (() -> AnyView)? = nil
    @ViewBuilder var content: Content

    /// 2.8.9：卡片标题里 " · " 之后都是我写给排障用的寄存器说明（如
    /// 「散热模式 · EC 0X0751 / 0X07AB」）。默认整段隐藏，只留主标题；
    /// 实验性页把环境值设成 false 就连后缀一起显示。
    @Environment(\.hideCardSubs) private var hideCardSubs

    private var displayTitle: String? {
        guard let title else { return nil }
        guard hideCardSubs else { return title }
        let head = title.components(separatedBy: " · ").first ?? title
        return head.trimmingCharacters(in: .whitespaces)
    }

    /// 标题样式化。原本一律 `uppercased()`，但 dGPU / iGPU 这类标识符有语义大小写，
    /// 转成全大写就成了 DGPU，读起来像缩写而不是「d + GPU」。
    /// 规则见文件级 `styledLabel`。

    /// 卡片底色随皮肤（2026-11-15 用户反馈：皮肤应用后卡片仍是不透明实色，背景看不到）：
    ///   · 全部用 Theme.panel 半透明填充（0.72，与 hero 条同款）——2026-11-15 用户定案：
    ///     **不要磨砂**，图片模式下 ultraThinMaterial 的毛玻璃模糊不要，只要普通半透明；
    ///   · 默认皮肤 → panel 原值实色（观感与历史版本完全一致）。
    /// 直接引用 SkinCenter.shared（不走 environmentObject）：Card 用在菜单栏弹窗等
    /// 没注入皮肤环境的地方也不会崩，Published 变更照样触发重绘。
    @ObservedObject private var skin = SkinCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = displayTitle {
                HStack(spacing: 6) {
                    Text(styledLabel(t))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.dim2)
                        .tracking(1.1)
                    if let badge { badge() }
                    Spacer()
                    if let trailing { trailing() }
                }
            }
            content
            // 2026-10-19：撑满所在网格单元的高度，同行的卡片才会一样高
            // （Spacer(minLength: 0) 在没有额外空间时不占一点高度）
            Spacer(minLength: 0)
        }
        // 四边统一 16。注意尾部那个 `Spacer` 前面还有本 VStack 的 12pt 段间距，
        // 所以内容最后一行到卡片下沿的实际观感是 28pt（2026-11-08 实测）。
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 皮肤感知 computed var：默认皮肤 = 实色，非默认/图片模式 = 0.72 半透明
            // （与 hero 条同款普通半透明，不带毛玻璃模糊 —— 2026-11-15 用户定案不要磨砂）
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.panel)
        }
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        // 2026-11-08（性能）：去掉卡片投影。
        // 卡片底色本来就比页面底亮一档，深色下这层 5% 黑影肉眼几乎看不出，
        // 但每张卡每秒都要重新做一次离屏阴影合成（一页 6~8 张），
        // 拖动窗口时尤其拖后腿。用一条 1px 描边代替分隔感，成本降到零。
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.line.opacity(0.55), lineWidth: 0.8)
        )
    }
}

/// 键值行
struct KVRow: View {
    var key: String
    var value: String
    var valueColor: Color = Theme.dim   // 值比键浅一截（2026-11-15 用户定案）
    /// 行尾附加视图（2026-11-15：设置页版本行加「检查更新」按钮用；nil = 不加，所有旧调用不变）
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            // 2026-11-15 用户定案（第三轮）：键 = 标题颜色（Theme.txt，与侧边栏标题同灰），
            // 值比键浅一截（Theme.dim）。KVRow 全工程只有版本卡在用。
            Text(key).font(.system(size: 12.5)).foregroundStyle(Theme.txt)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            if let t = trailing { t.padding(.leading, 8) }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }
}

/// 分段选择器（模式切换用；选中即生效，由调用方接 onChange）
struct SegmentedPicker<T: Equatable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let selected = opt.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = opt.0 }
                } label: {
                    Text(opt.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Theme.dim)
                        // 长标签缩放而不是换行——否则该分段被撑高，三块大小不一致
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        // 2026-11-07：高度钉成 30（原来是 padding(.vertical, 7) 撑出来的
                        // ≈29pt）。控制页「系统功耗设置」那三个按钮也用 30，
                        // 两组按钮才能严格等高。
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Theme.blue : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// 次按钮（用于一次性动作：关闭键盘灯、标定、恢复记忆等）
struct SecondaryButton: View {
    var title: String
    var icon: String? = nil
    var tint: Color = Theme.blue
    var isActive = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : Theme.txt)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? tint : Theme.panel2)
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isActive ? tint : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 页面标题区
struct PageHeader: View {
    var title: String
    var sub: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.txt)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.dim2)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - kext 门控（2.8.12）
//
// 用户要求：所有「需要 TongfangFan.kext 才能调」的项，在没检测到 kext 时必须
// **禁用置灰**，而不是整块消失或显示一行「需要 kext」把控件顶掉。
// 做法：保留原控件（布局不跳），`.disabled(!ok)` 让 SwiftUI 环境里 isEnabled=false，
// 子控件全部不吃点击，再压一层透明度当视觉提示；卡片里另配一行
// `KextRequiredHint()`，把「为什么灰着」和「立即安装」一起说清楚。

extension View {
    /// 未加载时整块禁用 + 置灰
    func kextGated(_ ok: Bool) -> some View {
        self
            .disabled(!ok)
            .opacity(ok ? 1 : 0.42)
    }
}

/// 「这一项需要 kext」提示条（带一键安装）
struct KextRequiredHint: View {
    @EnvironmentObject var backend: BackendService
    /// 自定义说明（默认泛指这一块）
    var text: String = "需要 TongfangFan.kext 才能调整"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10.5))
            Text(text).font(.system(size: 11.5))
            Spacer(minLength: 6)
            if backend.kextInstalling {
                ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                Text("安装中…").font(.system(size: 11))
            } else {
                KextInstallButton()
            }
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.amber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.32), lineWidth: 1))
    }
}

/// 通用「立即安装」按钮（kext 已内嵌在 app bundle，点了弹系统密码框）
struct KextInstallButton: View {
    @EnvironmentObject var backend: BackendService

    var body: some View {
        Button {
            Task { await backend.installKextIfNeeded() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 10.5, weight: .semibold))
                Text("立即安装").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(Theme.amber, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(backend.kextInstalling)
        .help("把 app 自带的 TongfangFan.kext 装进 /Library/Extensions 并加载（需要管理员密码）")
    }
}

/// kext 未装横幅
struct KextBanner: View {
    @EnvironmentObject var backend: BackendService
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("散热内核扩展未加载")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.txt)
                Text(backend.kextInstalling
                     ? "正在安装 TongfangFan.kext（请在系统弹窗里输入管理员密码）…"
                     : "风扇、散热模式、功耗档、充电阈值、海岸灯等硬件功能暂不可用。kext 已内嵌在本 app 里，点右侧按钮一键安装。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let e = backend.lastError, !e.isEmpty, !backend.kextInstalling {
                    Text("上次安装：\(e)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if backend.kextInstalling {
                ProgressView().scaleEffect(0.8)
            } else {
                KextInstallButton()
            }
        }
        .padding(14)
        .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.4), lineWidth: 1))
    }
}
