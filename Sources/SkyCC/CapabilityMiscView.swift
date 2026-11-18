import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// 设置页：外观与通用 / 版本 / 皮肤 / 系统调整 / 系统与启动参数
/// （2026-11-16 用户要求：卡片顺序调整为 外观+版本 → 皮肤 → 系统调整 → 系统与启动参数；
///   「菜单栏监控图标」整卡迁出本页 → 新侧边栏页「状态栏显示」（监测组，性能下面，
///   见 MenuBarStatusView.swift）。）
/// （2026-11-14 用户要求：
///   ① 删「后台服务」整卡；② 外观与通用挪到原后台服务的位置（左上）；
///   ③ 外观与通用里的「显卡路由」段迁入「系统调整」卡；
///   ④ 「系统与启动参数」从概览页迁来本页最下方。）
/// （2026-11-17 用户要求：「显卡路由」段从「系统调整」卡拆出，
///   独立成卡放到「设备控制」页、散热模式上方 —— 本页不再含显卡内容。）
struct MiscView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    // 皮肤（2026-11-15）：页面背景更换（预设配色 / 自定义图片）
    @EnvironmentObject private var skin: SkinCenter
    // 开机自启（SMAppService，替代旧「Sky CC开机启动.app」独立 toggle）
    @State private var launchAtLogin = false
    @State private var launchNote: String?
    // 外观（v2.4.3：浅色 / 深色 / 随系统，UserDefaults 持久化）
    @State private var appearance: AppAppearance = AppAppearance.current
    // 自身检查更新（2026-11-15）：逻辑抽到 AppUpdater 全局单例（启动期要静默检查，
    // 那时设置页可能没打开，状态/弹窗都不能挂这里）。本视图只放触发按钮 + 展示状态。
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // 2026-11-18（用户要求）：皮肤卡拆分 —— 预设配色 + 玻璃开关并入
                // 外观与通用卡（外观行下方）；背景图两行独立成「自定义背景」卡
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        generalCard.gridEqualFull()
                        aboutCard.gridEqualFull()
                    }
                    GridRow {
                        customBgCard.gridEqual().gridCellColumns(2)
                    }
                }
                // 「系统调整」整卡（显卡路由已拆去控制页，见 SystemTweakCard.swift）
                SystemTweakSection()
                // 「系统与启动参数」（自概览页迁来，用户要求置底）
                BootArgsCard()
            }
            .padding(22)
        }

        .toastOverlay()
        // 检查/下载/安装的 sheet 与两个 alert 都挂在根视图（SkyCCApp），
        // 启动期静默检查发现更新时设置页可能根本没打开
        .task {
            refreshLaunchState()
        }
    }

    /// 皮肤背景选图（2026-11-15）：本地选一张，拷贝进 App 支持目录持久化，整页立即生效
    private func pickSkinImage() {
        let panel = NSOpenPanel()
        panel.title = "选择背景图片"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if skin.setCustomImage(from: url) {
            ToastCenter.shared.show("背景图片已应用")
        } else {
            ToastCenter.shared.show("图片加载失败，请换一张试试")
        }
    }

    /// 侧边栏背景选图（2026-11-15）：不选时侧边栏跟随页面公共背景层
    private func pickSidebarImage() {
        let panel = NSOpenPanel()
        panel.title = "选择侧边栏背景图片"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if skin.setSidebarImage(from: url) {
            ToastCenter.shared.show("侧边栏背景已应用")
        } else {
            ToastCenter.shared.show("图片加载失败，请换一张试试")
        }
    }

    private var header: some View {
        PageHeader(title: "设置", sub: "外观与通用 · 自定义背景 · 系统调整 · 系统与启动参数")
    }

    // MARK: - 版本信息（2026-10-19：版本号搬进系统页，方便核对装的是哪一版）
    // 2026-11-18（用户定稿）：横版 lockup + 右侧上下摆「版本 Build」/「检查更新」；
    // 「控制台版本」行与底部 GPL 小字去掉。AppVersion 已提到文件作用域（SkyCCApp.swift）
    private static var logoComboHorizontal: NSImage? {
        // 2026-11-18：BrandAssets 多级减半预缩放（44pt @2x = 88px），消除大压缩比锯齿；
        // 64pt 会把版本卡撑得比外观卡高，导致左侧留白，缩回 44
        BrandAssets.prescaled("LogoComboHorizontal", targetPixelHeight: 88)
    }

    private var aboutCard: some View {
        let os = BackendService.dict(store.overview, "os")
        return Card(title: "版本") {
            VStack(spacing: 0) {
                // 头部：横版 lockup 在左（44，不撑高版本卡），
                // 版本号 + 检查更新按钮上下摆右对齐（同一行）
                HStack(spacing: 12) {
                    if let logo = Self.logoComboHorizontal {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(height: 44)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        Text("版本 \(AppVersion.short) (Build \(AppVersion.build))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.txt)
                            .monospacedDigit()
                        Button(updater.checkingUpdate ? "检查中…" : "检查更新") {
                            updater.check(silent: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.blue)
                        .controlSize(.small)
                        .disabled(updater.checkingUpdate || updater.updatePhase != .idle)
                    }
                }
                .padding(.bottom, 12)
                KVRow(key: "硬件后端", value: "SkyCC/1.0 · \(AppVersion.backend)")
                KVRow(key: "运行系统", value: "\(BackendService.string(os, "name") ?? "macOS") \(BackendService.string(os, "version") ?? "—") (\(BackendService.string(os, "build") ?? "—"))")
                KVRow(key: "机型", value: RealModel.displayName(overview: store.overview))
                KVRow(key: "EC 内核扩展", value: FanControl.kextLoaded() ? "SkyCCEC.kext · 已加载" : "未加载")
            }
        }
    }

    // MARK: - 菜单栏监控图标卡已于 2026-11-16 迁出到 MenuBarStatusView.swift

/// 状态栏主图标风格（2026-11-14 用户要求）：随系统（黑色模板）/ 白色 / 彩色。
/// 与菜单栏图标（MenuBarLabel）共用同一个 @AppStorage 键，改这里立即生效。
private struct MenuBarIconStylePicker: View {
    @AppStorage(UIControlPrefs.K.menubarIcon) private var style = "auto"

    var body: some View {
        Picker("", selection: $style) {
            Text("随系统").tag("auto")
            Text("浅色").tag("white")   // 白色固定切图（用户指定命名「浅色」，键仍为 white）
            Text("彩色").tag("color")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 168)
    }
}

    // MARK: - 自定义背景卡（2026-11-18 用户要求：皮肤卡拆分后剩余的图片两项独立成卡）
    // 2026-11-15 第三轮：图片行加框（panel2 底圆角，样式同核心温度块）
    private var customBgCard: some View {
        Card(title: "自定义背景") {
            VStack(alignment: .leading, spacing: 12) {
                skinImageRow(label: "自定义背景",
                             hasImage: skin.isCustomImage,
                             imageName: currentImageName(forKey: SkinCenter.imagePathKey, present: skin.isCustomImage),
                             pick: { pickSkinImage() },
                             clear: { skin.clearCustomImage() })
                skinImageRow(label: "侧边栏背景",
                             hasImage: skin.hasSidebarImage,
                             imageName: currentImageName(forKey: SkinCenter.sidebarImagePathKey, present: skin.hasSidebarImage),
                             pick: { pickSidebarImage() },
                             clear: { skin.clearSidebarImage() })
                Text("选图片后整页铺图并压一层底色蒙层；侧边栏不单独选图时跟随页面背景。选图后玻璃效果暂停生效，恢复默认后自动回到原配色。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardNote()
            }
        }
    }

    /// 读当前已选图片的文件名（present=false 或没记录时返回 nil）
    private func currentImageName(forKey key: String, present: Bool) -> String? {
        guard present, let path = UserDefaults.standard.string(forKey: key) else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// 背景图片 / 侧边栏背景 行：panel2 底 + 11pt 圆角框（样式与性能页核心温度块一致）
    private func skinImageRow(label: String, hasImage: Bool, imageName: String?,
                              pick: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.txt)
            if hasImage, let name = imageName {
                Text("当前：\(name)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Button("选择图片") { pick() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if hasImage {
                Button("恢复默认") { clear() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // 2026-10-17：从「Sky CC开机启动.app」（AppleScript toggle + autostart.sh
    // 的 LaunchAgent）迁移到 app 内设置。SMAppService 注册的登录项与
    // 系统设置 → 通用 → 登录项 是同一份数据，只是管理入口挪到了 app 里。
    private var generalCard: some View {
        Card(title: "外观与通用") {
            VStack(alignment: .leading, spacing: 12) {
                // 外观（2.7.5 从独立卡并入）。2026-11-14（用户要求）：
                // 顺序改为 随系统/浅色/深色；再改：按钮缩到与「状态栏主图标」
                // 一致（168 宽 small），右对齐，同行左侧加「外观」文字。
                // （不用 allCases —— 枚举声明序是 light/dark/system，那是存储顺序不动）
                HStack(spacing: 8) {
                    Text("外观").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.txt)
                    Spacer(minLength: 4)
                    Picker("", selection: $appearance) {
                        Text("随系统").tag(AppAppearance.system)
                        Text("浅色").tag(AppAppearance.light)
                        Text("深色").tag(AppAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 168)
                }
                .onChange(of: appearance) { _, new in
                    new.apply()
                    UserDefaults.standard.set(new.rawValue, forKey: AppAppearance.defaultsKey)
                }

                // 2026-11-18（用户要求）：预设配色 + 玻璃效果开关从皮肤卡迁入本卡（外观行下方）。
                // 开关随时可开可关（像系统设置的透明开关）：开 = 切到玻璃皮肤，关 = 回上一个皮肤。
                Divider().overlay(Theme.line)

                HStack(spacing: 10) {
                    Text("配色").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.txt)
                    HStack(spacing: 9) {
                        ForEach(SkinCenter.Preset.allCases) { p in
                            // 色板圆点 = 当前外观实际生效的那一档底色
                            Circle()
                                .fill(p.swatchColor)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                                .overlay {
                                    // 当前生效（选了图片时不算任何预设，只亮底色描边）
                                    if skin.preset == p && !skin.isCustomImage {
                                        Circle().strokeBorder(Theme.blue, lineWidth: 1.8)
                                            .padding(-3.5)
                                    }
                                }
                                .contentShape(Circle())
                                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { skin.select(p) } }
                                .help("背景配色：\(p.label)")
                        }
                    }
                    Spacer(minLength: 0)
                    // 玻璃效果开关（右对齐；选中玻璃色板时开关同步为开）
                    Toggle("玻璃效果", isOn: Binding(
                        get: { skin.glassOn },
                        set: { skin.setGlassEffect($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("开启后窗口透出桌面模糊、卡片更透（即玻璃配色）；关闭回到上一个配色。铺了自定义背景图时玻璃暂停生效。")
                }

                Divider().overlay(Theme.line)

                if #available(macOS 13.0, *) {
                    // 2026-11-14（用户要求）：开关右对齐，不再跟在文字后面
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动").font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.txt)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .onChange(of: launchAtLogin) { _, _ in
                        applyAutostart()
                    }

                    if let note = launchNote {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("与系统设置 → 通用 → 登录项 中的「Sky CC」同步。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardNote()
                } else {
                    Text("开机自动启动需要 macOS 13 或更高版本。")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }

                // 2026-11-14（用户要求）：状态栏主图标风格，放本卡（外观与通用）。
                // auto = 黑色模板图随菜单栏深浅色反色；white/color 为固定风格切图。
                // @AppStorage 直连 UserDefaults，菜单栏图标（MenuBarLabel）立即跟随。
                HStack(spacing: 8) {
                    // 2026-11-14（用户要求）：文字颜色与「开机自动启动」一致（主色，不再置灰）
                    Text("状态栏主图标").font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.txt)
                    Spacer(minLength: 4)
                    MenuBarIconStylePicker()
                }

                // 2026-11-14（用户要求）：显卡路由段从本卡迁入「系统调整」卡尾部。
            }
        }
    }

    @available(macOS 13.0, *)
    private func refreshLaunchState() {
        let mainOn = SMAppService.mainApp.status == .enabled
        launchAtLogin = mainOn
    }

    /// 开机自启只走 mainApp 一条登录项（静默启动已删除，2.8.15）。
    private func applyAutostart() {
        guard #available(macOS 13.0, *) else { return }
        do {
            removeLegacyAutostart()
            let main = SMAppService.mainApp
            if launchAtLogin {
                if main.status != .enabled { try main.register() }
            } else {
                if main.status == .enabled { try main.unregister() }
            }
            launchNote = nil
            ToastCenter.shared.show(launchAtLogin ? "已开启 · 开机自启" : "已关闭 · 开机自启")
        } catch {
            launchNote = "设置失败：\(error.localizedDescription)"
            refreshLaunchState()  // 回滚开关到真实状态
        }
    }

    /// 旧版开机自启的一次性迁移：autostart.sh 写的
    /// ~/Library/LaunchAgents/com.skycc.autostart.plist。
    /// 留着它会和 SMAppService 形成双重自启（登录时打开两个实例）。
    private func removeLegacyAutostart() {
        let plist = NSString(string: "~/Library/LaunchAgents/com.skycc.autostart.plist")
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plist) else { return }
        let label = "com.skycc.autostart"
        _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plist)
    }
}
