import SwiftUI
import AppKit

/// 全局视觉主题。
/// v2.4.3（2026-10-19）：全面支持深色模式——底色/文字/描边/强调色全部改为
/// 动态色（NSColor dynamicProvider，按当前 appearance 解析浅/深两套值）。
/// 之前只有侧边栏会随系统变色、内容区不变，就是这里全部写死浅色的缘故。
/// 用户可在「系统 → 外观」强制浅色/深色/随系统（UserDefaults "appearance"）。
/// 注意：键盘灯效页有「白色」颜色选项，所有色块/色板必须带描边，白底上才看得见。
enum Theme {
    // 底色系（浅色 / 深色）
    static let bg = Theme.dyn(light: 0xf6f7f9, dark: 0x17191d)        // 页面底
    static let panel = Theme.dyn(light: 0xffffff, dark: 0x22252a)     // 卡片
    static let panel2 = Theme.dyn(light: 0xeef0f4, dark: 0x2c3037)    // 控件底 / 磁贴内
    static let line = Theme.dyn(light: 0xe0e3e9, dark: 0x3a3f47)      // 描边
    static let barBg = Theme.dyn(light: 0xe6e9ee, dark: 0x383d45)     // 进度条底

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

/// 圆角卡片容器
struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: (() -> AnyView)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.dim2)
                        .tracking(1.1)
                    Spacer()
                    if let trailing { trailing() }
                }
            }
            content
            // 2026-10-19：撑满所在网格单元的高度，同行的卡片才会一样高
            // （Spacer(minLength: 0) 在没有额外空间时不占一点高度）
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// 数值磁贴（大数字 + 单位 + 可选进度条）
struct StatTile: View {
    var label: String
    var value: String
    var unit: String = ""
    var bar: Double? = nil       // 0...1
    var barColor: Color = Theme.blue
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.dim2)
                .tracking(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txt)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
            if let bar {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3.5).fill(Theme.barBg)
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(barColor)
                            .frame(width: geo.size.width * min(max(bar, 0), 1))
                    }
                }
                .frame(height: 7)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.dim2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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
                        .padding(.vertical, 7)
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
                Text("风扇、性能模式、充电阈值、海岸灯等硬件功能暂不可用。点击右侧按钮自动安装（需要管理员密码）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if backend.kextInstalling {
                ProgressView().scaleEffect(0.8)
            } else {
                SecondaryButton(title: "自动安装", icon: "lock.shield", isActive: true) {
                    Task { await backend.installKextIfNeeded() }
                }
            }
        }
        .padding(14)
        .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.4), lineWidth: 1))
    }
}

/// 不可用占位（kext 未装时的功能卡）
struct UnavailableCard: View {
    var title: String
    var body: some View {
        Card(title: title) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.dim2)
                Text("需要 TongfangFan.kext").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
        }
    }
}
