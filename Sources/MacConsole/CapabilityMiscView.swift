import SwiftUI
import ServiceManagement

/// 设置页：外观与通用 / 版本 / 菜单栏监控图标 / 系统调整 / 系统与启动参数
/// （2026-11-14 用户要求：
///   ① 删「后台服务」整卡；② 外观与通用挪到原后台服务的位置（左上）；
///   ③ 外观与通用里的「显卡路由」段迁入「系统调整」卡；
///   ④ 「系统与启动参数」从概览页迁来本页最下方。）
struct MiscView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    // 开机自启（SMAppService，替代旧「Sky CC开机启动.app」独立 toggle）
    @State private var launchAtLogin = false
    @State private var launchNote: String?
    // 外观（v2.4.3：浅色 / 深色 / 随系统，UserDefaults 持久化）
    @State private var appearance: AppAppearance = AppAppearance.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // 2026-11-14（用户要求）：删「后台服务」卡，外观与通用挪到左上；
                // 菜单栏图标单独一张通栏；系统调整 + 系统与启动参数置底。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        generalCard.gridEqual()
                        aboutCard.gridEqual()
                    }
                    GridRow {
                        menuBarCard.gridEqual().gridCellColumns(2)
                    }
                }
                // 「系统调整」整卡（显卡路由已并入，见 SystemTweakCard.swift）
                SystemTweakSection()
                // 「系统与启动参数」（自概览页迁来，用户要求置底）
                BootArgsCard()
            }
            .padding(22)
        }
        .background(Theme.bg)
        .toastOverlay()
        .task {
            refreshLaunchState()
        }
    }

    private var header: some View {
        PageHeader(title: "设置", sub: "外观与通用 · 菜单栏图标 · 系统调整 · 系统与启动参数")
    }

    // MARK: - 版本信息（2026-10-19：版本号搬进系统页，方便核对装的是哪一版）
    // AppVersion 已提到文件作用域（MacConsoleApp.swift），侧边栏头部共用
    private var aboutCard: some View {
        let os = BackendService.dict(store.overview, "os")
        return Card(title: "版本") {
            VStack(spacing: 0) {
                KVRow(key: "控制台版本", value: "Sky CC \(AppVersion.short) (Build \(AppVersion.build))")
                KVRow(key: "硬件后端", value: "MacConsole/1.0 · \(AppVersion.backend)")
                KVRow(key: "运行系统", value: "\(BackendService.string(os, "name") ?? "macOS") \(BackendService.string(os, "version") ?? "—") (\(BackendService.string(os, "build") ?? "—"))")
                KVRow(key: "机型", value: BackendService.string(store.overview, "model") ?? "—")
            }
        }
    }

    // MARK: - 菜单栏监控图标（每行：图标 + 名称 + 指标分段 + 开关，2.7.5 合并成一行）
    private var menuBarCard: some View {
        Card(title: "菜单栏监控图标") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MenuBarIconKind.allCases.enumerated()), id: \.offset) { i, kind in
                    if i > 0 { Divider().overlay(Theme.line.opacity(0.6)) }
                    MenuBarIconToggleRow(kind: kind)
                }
                Text("开关实时生效。点开图标弹出该传感器的详细读数（温度 / 占用 / 转速 / 寿命等）。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .padding(.top, 2)
                    .cardNote()
            }
        }
    }

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

/// 单个图标一行：图标 + 名称 +（可选）指标分段 +（硬盘）选盘 + 开关
private struct MenuBarIconToggleRow: View {
    let kind: MenuBarIconKind
    @AppStorage private var on: Bool

    init(kind: MenuBarIconKind) {
        self.kind = kind
        _on = AppStorage(wrappedValue: kind.defaultEnabled, kind.defaultsKey)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(Theme.blue)
            Text(kind.title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 40, alignment: .leading)
            if kind.supportsMetric {
                MenuBarMetricPicker(kind: kind)
                if kind == .disk {
                    MenuBarDiskPicker()
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $on)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: on) { _, _ in
                    NotificationCenter.default.post(name: MenuBarMonitors.iconsChanged, object: nil)
                }
        }
        .padding(.vertical, 2)
    }
}

/// 菜单栏指标切换（分段控件，@AppStorage 直写 UserDefaults）
private struct MenuBarMetricPicker: View {
    let kind: MenuBarIconKind
    @AppStorage private var metric: String

    init(kind: MenuBarIconKind) {
        self.kind = kind
        _metric = AppStorage(wrappedValue: kind.defaultMetric.rawValue, kind.metricKey)
    }

    var body: some View {
        Picker("", selection: $metric) {
            ForEach(kind.metricOptions) { m in
                Text(m.label).tag(m.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 128)
        .onChange(of: metric) { _, _ in
            // 立即刷新菜单栏数值（不等下一轮 1 秒轮询）
            MenuBarMonitors.shared.refreshTitles()
        }
    }
}

/// 硬盘图标看哪块盘（2.7.5）：菜单里列出 overview.smart 里的所有 NVMe
private struct MenuBarDiskPicker: View {
    @AppStorage(MenuBarIconKind.diskTargetKey) private var target: String = ""

    private var disks: [[String: Any]] {
        (BackendService.array(MonitorStore.shared.overview, "smart") as? [[String: Any]]) ?? []
    }

    var body: some View {
        Menu {
            ForEach(Array(disks.enumerated()), id: \.offset) { _, d in
                let bsd = d["bsd"] as? String ?? ""
                let model = d["model"] as? String ?? ""
                Button {
                    target = bsd
                    MenuBarMonitors.shared.refreshTitles()
                } label: {
                    Text(model.isEmpty ? bsd : "\(bsd) · \(model)")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(target.isEmpty ? "默认盘" : target)
                Image(systemName: "chevron.down").font(.system(size: 7.5))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 74)
    }
}

    // MARK: - 开机自启（SMAppService）
    //
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
                    Text("外观").font(.system(size: 12.5, weight: .medium))
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
                Text("切换浅色 / 深色界面；「随系统」跟随 macOS 的外观设置自动切换。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardNote()

                Divider().overlay(Theme.line)

                if #available(macOS 13.0, *) {
                    // 2026-11-14（用户要求）：开关右对齐，不再跟在文字后面
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动").font(.system(size: 12.5, weight: .medium))
                            Text("登录后自动打开 Sky CC（菜单栏常驻 + 硬件后台服务）")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .cardNote()
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
    /// ~/Library/LaunchAgents/com.macconsole.autostart.plist。
    /// 留着它会和 SMAppService 形成双重自启（登录时打开两个实例）。
    private func removeLegacyAutostart() {
        let plist = NSString(string: "~/Library/LaunchAgents/com.macconsole.autostart.plist")
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plist) else { return }
        let label = "com.macconsole.autostart"
        _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plist)
    }
}
