import SwiftUI
import ServiceManagement

/// 系统页：版本 / 外观 / 通用（开机自启）/ 菜单栏监控图标
/// （2026-10-19 v2.4.2：删除「能力矩阵」整页；「磁盘·df」「HID 设备」两卡删除，
///  「进程·CPU 占用 Top」移到监控页最下方（2.7.6 起该卡已从监控页删除）。
///  v2.4.3：新增「外观」卡——浅色/深色/随系统。
///  v2.4.5：菜单栏卡新增「CPU / GPU 显示指标」切换（温度/占用率，默认温度）。
///  2.7.6：删除「能力边界」卡；新增「静默启动」。
///  2.8.15：删除「静默启动」（用户：没用了）——开机自启只剩 mainApp 一条。）
struct MiscView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    // 开机自启（SMAppService，替代旧「Mac控制台开机启动.app」独立 toggle）
    @State private var launchAtLogin = false
    @State private var launchNote: String?
    // 外观（v2.4.3：浅色 / 深色 / 随系统，UserDefaults 持久化）
    @State private var appearance: AppAppearance = AppAppearance.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // 2.7.2 重排：左「后台服务 + 菜单栏图标」，右「版本 + 外观与通用」。
                // 2.7.6：原第三行「能力边界」通栏卡删除。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        helperCard.gridEqual()
                        aboutCard.gridEqual()
                    }
                    GridRow {
                        menuBarCard.gridEqual()
                        generalCard.gridEqual()
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .toastOverlay()
        .task {
            refreshLaunchState()
        }
    }

    /// 后台 helper 状态（2.6.0 起硬件读写全在它身上，UI 只是客户端）
    private var helperCard: some View {
        Card(title: "后台服务") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(backend.helperOnline ? Theme.green : Theme.red)
                        .frame(width: 7, height: 7)
                    Text(backend.helperOnline ? "运行中" : "未运行")
                        .font(.system(size: 12.5, weight: .medium))
                    if let v = backend.helperVersion {
                        Text("v\(v)").font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.dim2)
                    }
                    if let pid = backend.helperPid {
                        Text("pid \(pid)").font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.dim2)
                    }
                    Spacer()
                    Button("重启") {
                        Task { await backend.restartHelper() }
                    }
                    .controlSize(.small)
                }
                Text("EC / SMC / 键盘灯 / 亮度的唯一读写者。界面关闭或崩溃都不影响它——"
                     + "风扇曲线由它继续守护，崩溃后 launchd 会自动拉起。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardNote()
                if !backend.helperOnline, let e = backend.lastError {
                    Text(e).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var header: some View {
        PageHeader(title: "设置", sub: "后台服务 · 菜单栏图标 · 外观与开机")
    }

    // MARK: - 版本信息（2026-10-19：版本号搬进系统页，方便核对装的是哪一版）
    // AppVersion 已提到文件作用域（MacConsoleApp.swift），侧边栏头部共用
    private var aboutCard: some View {
        let os = BackendService.dict(store.overview, "os")
        return Card(title: "版本") {
            VStack(spacing: 0) {
                KVRow(key: "控制台版本", value: "Mac控制台 \(AppVersion.short) (Build \(AppVersion.build))")
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
    // 2026-10-17：从「Mac控制台开机启动.app」（AppleScript toggle + autostart.sh
    // 的 LaunchAgent）迁移到 app 内设置。SMAppService 注册的登录项与
    // 系统设置 → 通用 → 登录项 是同一份数据，只是管理入口挪到了 app 里。
    private var generalCard: some View {
        Card(title: "外观与通用") {
            VStack(alignment: .leading, spacing: 12) {
                // 外观（2.7.5 从独立卡并入）
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动").font(.system(size: 12.5, weight: .medium))
                            Text("登录后自动打开 Mac控制台（菜单栏常驻 + 硬件后台服务）")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .cardNote()
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, _ in
                        applyAutostart()
                    }

                    if let note = launchNote {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("与系统设置 → 通用 → 登录项 中的「Mac控制台」同步。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardNote()
                } else {
                    Text("开机自动启动需要 macOS 13 或更高版本。")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
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
