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

enum Theme {
    // 底色系（浅色 / 深色）
    // 2.8.11（用户要求）：深色下页面底太黑，按系统设置（macOS 深色）的观感整体提亮：
    //   页面底 ≈ 系统 windowBackground，卡片比底色略亮一档，控件再亮一档。
    //   原来是 0x17191d / 0x22252a / 0x2c3037，确实压得太死。
    static let bg = Theme.dyn(light: 0xf6f7f9, dark: 0x1e1f21)        // 页面底
    static let panel = Theme.dyn(light: 0xffffff, dark: 0x2a2b2e)     // 卡片
    static let panel2 = Theme.dyn(light: 0xeef0f4, dark: 0x34353a)    // 控件底 / 磁贴内
    static let line = Theme.dyn(light: 0xe0e3e9, dark: 0x3e3f44)      // 描边
    static let barBg = Theme.dyn(light: 0xe6e9ee, dark: 0x3a3b40)     // 进度条底

    // 文字系（灰阶；深色下整体提亮，不用纯白）
    static let txt = Theme.dyn(light: 0x2a2f37, dark: 0xe8eaef)       // 主文字
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
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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
    var valueColor: Color = Theme.txt
    var body: some View {
        HStack {
            Text(key).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
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
