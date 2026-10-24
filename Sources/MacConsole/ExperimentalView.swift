import SwiftUI

/// 实验性功能页（2.8.8 新增）
///
/// 用户要求：「实验性的功能单开一个标签页，把实验性的功能都放进实验性的标签页」。
///
/// 这里只放**原厂 Windows 控制台没有对应入口**、或 macOS 侧只能走非常规通路的能力：
///   ① 风扇手动档位 / 温控曲线（原厂 UI 只有 性能/标准/安静，能力位里也没有「用户档」）
///   ② ESC 功能键锁定（原厂写注册表 Features\FnKeyLock，macOS 无注册表 → 直接写同族 EC 位 0x074E bit4）
///   ③ EC 寄存器探针（只读，排障用；原厂肯定不会给用户看这个）
///
/// 硬性约束与其它页一致：所有写硬件的动作只能由用户操作产生，回读一律直接赋 @State。
struct ExperimentalView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    // 风扇：交给 EC / 手动档位 / 曲线
    @State private var fanMode: String = "normal"
    @State private var fanLevel: Double = 0
    /// 手动档位滑条是草稿：拖完必须点「确定应用」才写 EC（2.8.8 用户要求）
    @State private var levelDirty = false

    // ESC 功能键锁定（0x074E bit4）
    @State private var fnLock = false

    // EC 探针
    @State private var ecAddr: String = "0x07AB"
    @State private var ecValue: String = "—"
    @State private var ecBits: String = "—"
    @State private var ecNote: String?

    // 2.8.8：界面以软件记忆（UIControlPrefs）为准，不再需要锁窗口防回读覆盖

    private var kextOK: Bool { backend.kextLoaded }
    private var synced: Bool { !store.fan.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !kextOK { KextBanner() }
                header

                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        fanCard
                            .fixedSize(horizontal: false, vertical: true)
                        // 2.8.9（用户要求）：「常用 EC 地址」挪到风扇卡下方
                        commonAddrCard
                            .fixedSize(horizontal: false, vertical: true)
                            .kextGated(kextOK)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 14) {
                        fnLockCard
                            .kextGated(kextOK)
                        ecProbeCard
                            .kextGated(kextOK)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 372)
                }

                riskCard
            }
            .padding(22)
        }
        .background(Theme.bg)
        // 2.8.9：本页是唯一保留卡片说明的页面
        .environment(\.hideCardSubs, false)
        .onAppear {
            // 2.8.10：进页面只读软件记忆，不再拉 EC 快照
            syncFromBackend()
        }
        .onChange(of: store.updatedAt) { _, _ in syncFromBackend() }
        .toastOverlay()
    }

    private var header: some View {
        PageHeader(title: "实验性",
                   sub: "原厂没有入口的能力 · 手动风扇 / 非常规 EC 通路 / 寄存器探针",
                   trailing: AnyView(
                    HStack(spacing: 8) {
                        Circle().fill(Theme.amber).frame(width: 7, height: 7)
                        Text("改动即生效，请先读说明")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.panel, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))))
    }

    // MARK: - 回读
    //
    // 2.8.8：EC 只在启动初始化时读一次（UIControlPrefs.seedIfNeeded），之后界面
    // 全部以软件记忆为准 —— 拖动滑条 / 开关都不会被轮询刷回去。
    private func syncFromBackend() {
        guard !store.fan.isEmpty else { return }
        UIControlPrefs.seedIfNeeded(store.fan)

        if let m = UIControlPrefs.string(UIControlPrefs.K.fanMode) { fanMode = m }
        // 手动档位：草稿没点「确定应用」前，别用记忆值把用户正在拖的滑条打回去
        if !levelDirty, let lv = UIControlPrefs.int(UIControlPrefs.K.fanLevel) {
            fanLevel = Double(lv)
        }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.fnLock) { fnLock = v }
    }

    private func showToast(_ s: String) { ToastCenter.shared.show(s) }

    // MARK: - ① 风扇手动档位 / 曲线
    private var fanCard: some View {
        Card(title: "风扇 · 手动档位 / 温控曲线 · EC 0x0741 / 0x0751") {
            // 2.8.12：kext 未装时整段置灰（控件保留、布局不跳），顶部给一键安装
            if !kextOK { KextRequiredHint() }
            // 基准模式下 EC 的手动门被占用，这里整段置灰
            let benchmark = BackendService.bool(store.fan, "benchmark") ?? false
            Group {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("控制方式").font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.dim).frame(width: 62, alignment: .leading)
                        SegmentedPicker(options: [("normal", "交给 EC"), ("custom", "手动"), ("curve", "曲线")],
                                        selection: fanModeBinding)
                        Spacer(minLength: 0)
                    }
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.45 : 1)

                    if benchmark {
                        Text("基准模式开着（0x0751 = 0x40）。放开手动档位会把 0x0751 打回，增压失效但门还开着 —— "
                             + "要调风扇请先到「控制」页关掉基准模式。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if fanMode == "custom" {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("手动档位").font(.system(size: 12)).foregroundStyle(Theme.dim)
                                Spacer()
                                Text("L\(Int(fanLevel)) · \(Int(24 + fanLevel * 4.14))% 占空比")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                            }
                            Slider(value: fanLevelBinding, in: 0...7, step: 1)
                                .tint(Theme.blue)
                            HStack(spacing: 10) {
                                Button {
                                    Task { await applyManualLevel() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                                        Text("确定应用").font(.system(size: 12.5, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 15).padding(.vertical, 7)
                                    .background(Theme.blue, in: Capsule())
                                    .opacity(levelDirty ? 1 : 0.55)
                                }
                                .buttonStyle(.plain)
                                Text(levelDirty ? "有未应用的档位修改" : "滑条只是草稿，点「确定应用」才写 EC")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(levelDirty ? Theme.amber : Theme.dim2)
                                Spacer(minLength: 0)
                            }
                            Text("FAN_CTRL = 0x80 + 档位，写入前先开 CTRL_1 手动门 0x741 bit0；"
                                 + "退出「手动」或「曲线」时会自动关门（先放档位再清门），"
                                 + "交还 EC 后它按 0x7AB 重算 0x751。")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if fanMode == "curve" {
                        Divider().overlay(Theme.line)
                        FanCurveView()
                    } else {
                        Text("手动与曲线都关闭：散热完全交给 EC 固件，控制页的「散热模式」三档照常生效。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(benchmark && fanMode != "normal")
                .opacity(benchmark && fanMode != "normal" ? 0.45 : 1)
            }
            .kextGated(kextOK)
        }
    }

    private var fanModeBinding: Binding<String> {
        Binding(get: { fanMode }, set: { m in
            fanMode = m
            UIControlPrefs.set(UIControlPrefs.K.fanMode, m)
            if m == "custom" {
                // 选「手动」只是把滑条亮出来，真正写 EC 要等「确定应用」
                levelDirty = true
            } else {
                levelDirty = false
                Task { await applyFanMode(m) }
            }
        })
    }

    private var fanLevelBinding: Binding<Double> {
        Binding(get: { fanLevel }, set: { v in
            fanLevel = v
            levelDirty = true          // 只标脏，不写 EC
        })
    }

    /// 手动档位确认：把草稿写进 EC，并记住
    private func applyManualLevel() async {
        let lv = Int(fanLevel)
        UIControlPrefs.set(UIControlPrefs.K.fanLevel, lv)
        UIControlPrefs.set(UIControlPrefs.K.fanMode, "custom")
        let r = await backend.post("/api/fan", ["mode": "custom", "level": lv])
        if r["ok"] as? Bool == true {
            levelDirty = false
            showToast("手动档位已应用 · L\(lv) · \(Int(24 + fanLevel * 4.14))% 占空比")
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyFanMode(_ mode: String) async {
        var body: [String: Any] = [:]
        switch mode {
        case "normal":
            body["mode"] = "normal"
        case "curve":
            body["mode"] = "curve"
            // 曲线配置以磁盘为唯一真相（helper 与 UI 两侧都读它）
            let cfg = FanCurveStore.load() ?? .default
            body["source"] = cfg.source
            body["failsafe"] = cfg.failsafeTemp
            body["points"] = cfg.points.map { ["temp": $0.temp, "level": $0.level] }
        default:
            body["mode"] = "custom"
            body["level"] = Int(fanLevel)
        }
        let r = await backend.post("/api/fan", body)
        let name = ["normal": "交给 EC", "custom": "手动 L\(Int(fanLevel))", "curve": "温控曲线"][mode] ?? mode
        if r["ok"] as? Bool == true {
            showToast("风扇已切换到\(name)")
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - 常用 EC 地址（点一下直接灌进上面的探针并读取）
    private var commonAddrCard: some View {
        let items: [(String, String)] = [
            ("散热/功耗档", "0x07AB"),
            ("风扇控制", "0x0751"),
            ("手动门 CTRL_1", "0x0741"),
            ("CTRL_2", "0x0742"),
            ("充电阈值", "0x07B9"),
            ("BIOS 控制 3", "0x07A3"),
            ("AP BIOS 字节", "0x07A4"),
            ("Win 键触发", "0x0767"),
            ("Win 键回读", "0x0768"),
            ("安静模式回读", "0x045B"),
            ("海岸灯 CTRL", "0x0748"),
        ]
        return Card(title: "常用 EC 地址") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    Button {
                        ecAddr = it.1
                        Task { await readEC() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(it.0).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(it.1).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.cyan)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - ② ESC 功能键锁定（非常规通路）
    private var fnLockCard: some View {
        Card(title: "ESC 功能键锁定 · 非常规通路") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ESC 键功能键锁定").font(.system(size: 13, weight: .medium))
                        Text("原厂写注册表 Features\\FnKeyLock，macOS 无注册表通路 → 直接写同族 EC 位 0x074E bit4")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: fnLockBinding)
                        .toggleStyle(.switch)
                        .tint(Theme.blue)
                        .labelsHidden()
                }
                Text("这是「映射到同一个位」的推断实现，不是原厂在 macOS 上的既有行为；"
                     + "万一 ESC 手感不对，先把它关回去。")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fnLockBinding: Binding<Bool> {
        Binding(get: { fnLock }, set: { v in
            fnLock = v
            UIControlPrefs.set(UIControlPrefs.K.fnLock, v)
            Task { await applyFnLock(v) }
        })
    }

    private func applyFnLock(_ on: Bool) async {
        let r = await backend.post("/api/fan", ["fn_lock": on])
        if r["ok"] as? Bool == true {
            ToastCenter.shared.showSwitch("ESC 功能键锁定", on)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            UIControlPrefs.set(UIControlPrefs.K.fnLock, !on)
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - ③ EC 寄存器探针（只读）
    private var ecProbeCard: some View {
        Card(title: "EC 寄存器探针 · 只读") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("地址").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    TextField("0x07AB", text: $ecAddr)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 92)
                        .onSubmit { Task { await readEC() } }
                    SecondaryButton(title: "读取", icon: "eyedropper", tint: Theme.green) {
                        Task { await readEC() }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("数值").font(.system(size: 10)).foregroundStyle(Theme.dim2)
                        Text(ecValue).font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.txt)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("二进制").font(.system(size: 10)).foregroundStyle(Theme.dim2)
                        Text(ecBits).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 0)
                }
                if let note = ecNote {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("常用：0x07AB 散热/功耗档 · 0x0751 风扇控制 · 0x0741 手动门 · 0x07B9 充电阈值。"
                     + "只读，不提供写入 —— 写错位会让 EC 进入异常态，需要断电复位。")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readEC() async {
        guard let addr = parseAddr(ecAddr) else {
            ecNote = "地址格式不对，支持 0x07AB / 7AB / 1963"
            return
        }
        let r = await backend.post("/api/ec/read", ["addr": addr])
        if r["ok"] as? Bool == true, let v = BackendService.int(r, "value") {
            ecValue = String(format: "0x%02X (%d)", v, v)
            ecBits = String(v, radix: 2).leftPadding(to: 8)
            ecNote = nil
        } else {
            ecNote = "读取失败：\(BackendService.string(r, "error") ?? "未知")"
        }
    }

    private func parseAddr(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        guard let v = Int(t, radix: 16) ?? Int(t) else { return nil }
        return (0...0xFFFF).contains(v) ? v : nil
    }

    // MARK: - 风险说明
    private var riskCard: some View {
        Card(title: "为什么这些放在「实验性」") {
            VStack(alignment: .leading, spacing: 6) {
                bullet("手动档位 / 曲线：原厂 UI 只有 性能 / 标准 / 安静 三档，能力位 0x765 / 0x766 里也没有「用户档」。"
                       + "这是复刻版按 EC 手册自己推的写法定，实测可用但不保证在所有 BIOS 版本上都稳。")
                bullet("ESC 功能键锁定：原厂只写注册表，我们改在 macOS 上直接写同族 EC 位 —— 是推断，不是既有实现。")
                bullet("EC 探针：只读。真要写寄存器请用终端里的 mcutil，并在写之前先备份原值。")
                bullet("这些能力都不会随开机自启恢复（手动档位会被 EC 固件在下次上电时重置为自动）。")
                if !synced {
                    Text("读取中…").font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                }
            }
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Theme.amber).frame(width: 4.5, height: 4.5).padding(.top, 5.5)
            Text(s).font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension String {
    func leftPadding(to len: Int, with pad: String = "0") -> String {
        guard count < len else { return self }
        return String(repeating: pad, count: len - count) + self
    }
}
