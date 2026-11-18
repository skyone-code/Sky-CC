import SwiftUI
import AppKit

// MARK: - 自定义「关于 Sky CC」窗口（2026-11-18 用户要求：默认关于面板太简陋）
//
// 系统默认面板只有 图标 + 名称 + 版本号 三行。这里换成品牌化的自定义窗口：
// 横版 lockup + 版本号 + 真实机型徽章（EC 平台识别）+ 运行环境信息行 +
// 检查更新按钮 + GPL-2.0 开源致谢。菜单栏「Sky CC → 关于 Sky CC」通过
// CommandGroup(replacing: .appInfo) 接入（见 SkyCCApp.commands）。

struct AboutView: View {
    @ObservedObject private var store = MonitorStore.shared
    @ObservedObject private var updater = AppUpdater.shared

    private static let logo: NSImage? =
        BrandAssets.prescaled("LogoComboHorizontal", targetPixelHeight: 104)

    var body: some View {
        VStack(spacing: 0) {
            // 品牌 + 版本
            VStack(spacing: 10) {
                if let logo = Self.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(height: 52)
                }
                Text("版本 \(AppVersion.short) (Build \(AppVersion.build))")
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
                // 真实机型徽章（EC 平台识别，与 hero 条 / 版本卡同口径）
                Text(RealModel.displayName(overview: store.overview))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.blue.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.28), lineWidth: 1))
            }
            .padding(.top, 26)
            .padding(.bottom, 18)

            Divider().overlay(Theme.line).padding(.horizontal, 22)

            // 运行环境信息行
            VStack(spacing: 0) {
                aboutRow("运行系统", value: osLine)
                aboutRow("EC 内核扩展",
                         value: FanControl.kextLoaded() ? "SkyCCEC.kext · 已加载" : "未加载")
                aboutRow("硬件后端", value: "SkyCC/1.0 · \(AppVersion.backend)")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 6)

            // 检查更新
            Button {
                updater.check(silent: false)
            } label: {
                Text(updater.checkingUpdate ? "检查中…" : "检查更新…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 150, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.blue)
            .controlSize(.small)
            .disabled(updater.checkingUpdate || updater.updatePhase != .idle)
            .padding(.top, 8)

            Spacer(minLength: 0)

            // 开源致谢（GPL-2.0 合规口径：仅 EC 驱动源自该项目）
            Text("EC 驱动基于开源项目 TongfangEnhancer (GPL-2.0)\n© 2026 Sky CC")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.dim2)
                .lineSpacing(3)
                .padding(.bottom, 18)
        }
        .frame(width: 340, height: 400)
        .background(Theme.bg)
    }

    private var osLine: String {
        let os = BackendService.dict(store.overview, "os")
        return "\(BackendService.string(os, "name") ?? "macOS") \(BackendService.string(os, "version") ?? "—")"
    }

    @ViewBuilder
    private func aboutRow(_ key: String, value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12)).foregroundStyle(Theme.txt)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }
}

/// 窗口管理：AppKit 直开（不走 Window scene —— 关于窗是单例浮窗，
/// 需要隐藏标题栏文字、固定大小、不抢主窗口状态）。
enum AboutWindowPresenter {
    /// 强引用持窗（局部变量出栈窗口会被释放，点第二次菜单就开不出来了）
    private static var window: NSWindow?

    static func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingView(rootView: AboutView())
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: host.frame.width, height: host.frame.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        w.title = "关于 Sky CC"
        // 玻璃窗口透明谓词按 identifier 排除本窗口（否则关于窗也会被改透明）
        w.identifier = NSUserInterfaceItemIdentifier("skycc.about")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}
