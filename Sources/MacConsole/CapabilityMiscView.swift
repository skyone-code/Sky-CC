import SwiftUI
import ServiceManagement

/// 系统页：版本 / 外观 / 通用（开机自启）/ 菜单栏监控图标
/// （2026-10-19 v2.4.2：删除「能力矩阵」整页；「磁盘·df」「HID 设备」两卡删除，
///  「进程·CPU 占用 Top」移到监控页最下方。v2.4.3：新增「外观」卡——浅色/深色/随系统。
///  v2.4.5：菜单栏卡新增「CPU / GPU 显示指标」切换（温度/占用率，默认温度）。）
struct MiscView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    // 开机自启（SMAppService，替代旧「Mac控制台开机启动.app」独立 toggle）
    @State private var launchAtLogin = false
    @State private var launchNote: String?
    // 外观（v2.4.3：浅色 / 深色 / 随系统，UserDefaults 持久化）
    @State private var appearance: AppAppearance = AppAppearance.current
    // 能力边界（v2.5.3.1：把 /api/capability 的能力矩阵放回 UI，含 EC 寄存器映射摘要）
    @State private var capability: [String: Any] = [:]
    @State private var capLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // 2.7.2 重排：左「后台服务 + 菜单栏图标」，右「版本 + 外观与通用」，
                // 能力边界通栏放最底——它是最长的参考资料，不该挡在常用开关前面。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        helperCard.gridEqual()
                        aboutCard.gridEqual()
                    }
                    GridRow {
                        menuBarCard.gridEqual()
                        generalCard.gridEqual()
                    }
                    GridRow {
                        capabilityCard.gridEqual().gridCellColumns(2)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .task {
            refreshLaunchState()
            await loadCapability()
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
                if !backend.helperOnline, let e = backend.lastError {
                    Text(e).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var header: some View {
        PageHeader(title: "设置", sub: "后台服务 · 菜单栏图标 · 外观与开机 · 能力边界")
    }

    // MARK: - 能力边界（v2.5.3.1：可用/部分可用清单 + EC 寄存器映射）
    private func loadCapability() async {
        if let d = await backend.get("/api/capability") as? [String: Any] {
            capability = d
        }
        capLoading = false
    }

    private var capabilityCard: some View {
        let usable = (BackendService.array(capability, "usable") as? [[String: Any]]) ?? []
        let partial = (BackendService.array(capability, "partial") as? [[String: Any]]) ?? []
        let un = (BackendService.array(capability, "unavailable") as? [[String: Any]]) ?? []
        return Card(title: "能力边界") {
            if capLoading {
                Text("读取中…").font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // 摘要行：三组数量一眼可见，细项折在下面（原来一长串 ✅/⚠️/❌ 占满屏）
                    HStack(spacing: 8) {
                        Chip(text: "可用 \(usable.count)", color: Theme.green)
                        Chip(text: "部分可用 \(partial.count)", color: Theme.amber)
                        Chip(text: "不可用 \(un.count)", color: Theme.red)
                        Spacer(minLength: 8)
                        Text("以实机探测为准（qc71 同族开源驱动交叉验证）")
                            .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            capGroup(usable, title: "可用", color: Theme.green)
                            capGroup(partial, title: "部分可用", color: Theme.amber)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            capGroup(un, title: "不可用", color: Theme.red)
                            Divider().overlay(Theme.line)
                            ecMapBlock
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// 一组能力条目：小色条 + 标题 +（可展开的）细项
    private func capGroup(_ items: [[String: Any]], title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 11)
                Text("\(title)（\(items.count)）")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                DisclosureGroup {
                    Text(BackendService.string(item, "detail") ?? "")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 3)
                } label: {
                    Text(BackendService.string(item, "name") ?? "")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .tint(color)
            }
        }
    }

    /// EC 寄存器映射摘要（v2.5.3.1，名称 = qc71 官方命名，本机全扫实测）
    private var ecMapBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EC 寄存器映射（ABBC0F6F WMI，qc71 官方命名）")
                .font(.system(size: 11.5, weight: .medium))
            let rows: [(String, String)] = [
                ("FAN_CTRL · 0x0751", "散热档位 0x80+n（配 CTRL_1 手动门）"),
                ("CTRL_1 · 0x0741", "bit0 手动门：EC 自动调度 / app 接管"),
                ("FAN_MODE_INDEX · 0x07AB", "性能模式 0x11 专业 / 0x22 平衡 / 0x33 省电"),
                ("CTRL_2 · 0x078C", "bit2-3 Turbo 档位"),
                ("BATT_CHARGE_CTRL · 0x07B9", "充电阈值（0 = 100%）"),
                ("LIGHTBAR_CTRL · 0x0748-74B", "海岸灯模式 + RGB"),
                ("BIOS_CTRL_1 · 0x074E", "bit4 Fn 锁"),
                ("AP_BIOS_BYTE · 0x07A4", "bit3 Fn+Esc 快捷键"),
                ("CTRL_4 · 0x07A6", "bit6 触控板 / bit1 超频动态温控"),
                ("BIOS_CTRL_3 · 0x07A3", "bit5 降占空比 / bit6 常转"),
                ("0x043E/044F · 0x046C/0464", "CPU/GPU 温度与转速（只读监视）"),
                ("0x1804/1809", "PWM 遥测（禁写：会停转风扇）"),
            ]
            ForEach(rows, id: \.0) { k, v in
                HStack(alignment: .top, spacing: 8) {
                    Text(k).font(.system(size: 10).monospacedDigit())
                        .frame(width: 178, alignment: .leading)
                    Text(v).font(.system(size: 10)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("实测无效区：PL1/2/4（0x0783-85）与 SUPPORT_5（0x0742）被 EC 秒级还原；0x07AC-AE + 0x07B0-B2 为静态码表死数据；0x0786-78A 为 EC 默认 PWM 阶梯（只读）。")
                .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: - 外观（2.7.5 已并入「外观与通用」卡，这里只保留取值逻辑）

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

                Divider().overlay(Theme.line)

                if #available(macOS 13.0, *) {
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动").font(.system(size: 12.5, weight: .medium))
                            Text("登录后自动打开 Mac控制台（菜单栏常驻 + 硬件后台服务）")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        setLaunchAtLogin(on)
                    }
                    if let note = launchNote {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                    }
                    Text("与系统设置 → 通用 → 登录项 中的「Mac控制台」同步。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                } else {
                    Text("开机自动启动需要 macOS 13 或更高版本。")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private func refreshLaunchState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on {
                removeLegacyAutostart()  // 清掉旧版 LaunchAgent，避免双重自启
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchNote = nil
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
