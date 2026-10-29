import SwiftUI
import AppKit

/// 控制页：散热模式 / 系统功耗设置 / 系统调整 / 充电阈值 / 防休眠
///
/// 【术语映射（用户明确指定，别改）】
///   · 本页「散热模式」= 原厂 Windows 控制台的「散热模式」（EC 0x7AB 低半字节，性能/标准/安静）
///   · 本页「系统功耗设置」= 原厂同名项（EC 0x7AB 高半字节，高性能/平衡/节能）
///   · 本页「系统调整」= 原厂 FastSwitch 页那几个开关
///
/// 【2.8.3 用户要求】
///   · 删掉「显示屏性能」（macOS 没有显示驱动通路，留着只是假开关）
///   · 删掉屏幕亮度卡与输出音量卡（系统自带控件更顺手，本页不再重复）
///   · 删掉「其他 EC 位 · 非原厂实验能力」整卡
///   · 系统功耗三按钮去掉图标，只留文字
///   · 海岸灯整卡搬到灯效页
///   · 重新排版，卡片填满，不留大片空白
///
/// 【硬性约束：点进标签页只读不写】
///   本页所有写硬件的动作必须由用户真实操作产生。程序化回读一律直接改 @State，
///   绝不走 onChange —— 否则「回读把 thermal 从 2 改成 1」会被当成用户点了
///   「性能」，进页面就凭空写一次 EC。分段的 selection 全部换成自定义 Binding。
struct ControlView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    // 散热模式：1 性能 / 2 标准 / 3 安静（EC 0x7AB 低半字节）
    @State private var thermal: String = "2"
    // 基准模式（EC 0x741 手动门 + 0x751=0x40）
    @State private var benchmark = false
    // 系统功耗设置：0x11 / 0x22 / 0x33（EC 0x7AB 高半字节）
    @State private var perfIndex: Int = 0x11

    @State private var chargeThreshold: Double = 80
    @State private var caffeinateOn = false

    // 系统调整（原厂 FastSwitch 页）
    @State private var kbBacklight = true
    @State private var winLock = false
    @State private var osd = true
    @State private var silentMode = false
    @State private var passiveCoolingDisabled = false

    // 交互锁：2.8.8 起界面以「软件记忆」为准，不再需要锁窗口防回读覆盖

    /// 2.8.9：卡片说明/副标题默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    private var kextOK: Bool { backend.kextLoaded }
    /// 快照读回来了没有 —— 没读回来之前不显示「标准 / 高性能」这类可能骗人的高亮
    private var synced: Bool { !store.fan.isEmpty }

    var body: some View {
        // 2.8.8（用户要求）版式：
        //   左列 = 散热模式 ／ 电池充电阈值（充电阈值挪到散热模式下方）
        //   右列 = 系统调整（原「电源休眠抑制」并入这张卡，占原来充电阈值的位置）
        // 两列都不加 maxHeight / 固定下限：卡片按内容自然高度排，靠右列的项目数
        // 把两列拉到差不多高，卡片内部不留空洞。
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !kextOK { KextBanner() }
                    header

                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            // 两张卡都按内容高度排（fixedSize），多余高度交给下面的
                            // Spacer —— 否则 Card 内部的 Spacer 会把卡片撑到窗口底部，
                            // 卡片里空出一整块，比留背景更难看。
                            thermalCard
                                .fixedSize(horizontal: false, vertical: true)
                            chargeCard
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        systemCard
                            .frame(width: 420)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .background(Theme.bg)
        .onAppear {
            // 2.8.15（用户要求）：进控制页**读一次**当前设置（只这一次，不轮询）。
            // /api/fan/refresh 读模式组 + 开关组 + 充电阈值，不续转速采样租约。
            // 读完把真值合进 store.fan，再 syncFromBackend 让 UI 对齐硬件真值。
            Task {
                if let fresh = try? await backend.getJSON("/api/fan/refresh") as? [String: Any],
                   !fresh.isEmpty {
                    var f = store.fan
                    for k in ["live", "thermal_level", "power_level", "modeindex",
                              "benchmark", "misc", "charge", "actual", "actual_level"] {
                        if let v = fresh[k] { f[k] = v }
                    }
                    store.fan = f
                }
                syncFromBackend()
                syncCaffeinateIfNeeded()
            }
        }
        .onChange(of: store.updatedAt) { _, _ in
            syncFromBackend()
        }
        .toastOverlay()
    }

    private var header: some View {
        PageHeader(title: "控制",
                   sub: "散热模式 / 系统功耗设置 / 系统调整 / 充电阈值 · 所有开关以硬件真实回读为准",
                   trailing: AnyView(
                    HStack(spacing: 10) {
                        if !synced {
                            Text("读取中…").font(.system(size: 11)).foregroundStyle(Theme.dim2)
                        } else {
                            Text("\(thermalLabel) · \(powerLabel)\(benchmark ? " · 基准" : "")")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.dim)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Theme.panel, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                        }
                    }))
    }

    // MARK: - 从后端回读同步本地状态
    //
    // 2.8.8（用户要求）：**EC 只在启动初始化阶段读一次**，之后界面所有值都来自
    // 软件记忆（UIControlPrefs），不再每轮跟硬件对账。
    // 之前「点完 1 秒后被回读刷回去」的观感就是每轮读 EC 造成的；EC 里这些字节
    // 本来就是持久项，软件自己留一份权威副本更稳。
    private func syncFromBackend() {
        guard !store.fan.isEmpty else { return }
        // 本次启动的第一次有效快照：EC → 记忆（只此一次）
        UIControlPrefs.seedIfNeeded(store.fan)
        // 3.0.2.1（用户要求）：启动时**只读不应用** —— 把 EC 真值抄进记忆，
        // 一个字节都不往 EC 写。旧版这里拿记忆值去覆盖 EC，会把别处改过的设置
        // 强行改回去，已废弃。只跑一次。
        // 必须放在下面「从记忆渲染界面」之前，否则首帧显示的是旧记忆值。
        UIControlPrefs.adoptHardwareIfNeeded(store.fan)

        // 2.8.11（用户要求）：**散热模式 / 系统功耗设置这两项不走记忆，直接读 EC**。
        //   原厂逻辑是「动功耗 → 散热档跟着走；只动散热 → 功耗档不动」，
        //   两组是同一个字节 0x7AB 的高低半字节，必须显示硬件真值才不会错位。
        if let t = BackendService.int(store.fan, "thermal_level"), (1...3).contains(t) {
            thermal = String(t)
        }
        if let mi = BackendService.int(store.fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi) {
            perfIndex = mi
        }
        // 其余开关仍以记忆为准
        if let b = UIControlPrefs.bool(UIControlPrefs.K.benchmark) { benchmark = b }
        if let ch = UIControlPrefs.int(UIControlPrefs.K.charge) { chargeThreshold = Double(ch) }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.kbBacklight) { kbBacklight = v }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.winLock) { winLock = v }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.osd) { osd = v }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.silentMode) { silentMode = v }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.passiveCooling) { passiveCoolingDisabled = v }
        if let v = UIControlPrefs.bool(UIControlPrefs.K.caffeinate) { caffeinateOn = v }
    }

    private func showToast(_ s: String) {
        ToastCenter.shared.show(s)
    }

    // MARK: - 散热模式（= 原厂「散热模式」，EC 0x7AB 低半字节）
    //
    // 两者共用同一个字节 0x7AB：高半字节 = 功耗档，低半字节 = 散热档。
    // 原厂点「系统功耗设置」是「功耗 + 散热两组一起写」，单独切散热时只有低半字节变。
    private var thermalCard: some View {
        Card(title: "散热模式 · EC 0x0751 / 0x07AB") {
            // 2.8.12（用户要求）：kext 未检测到时**禁用置灰**，不再把控件整块换掉。
            // 置灰靠 .kextGated（disabled 会传染给所有子控件），顶部给「立即安装」。
            if !kextOK { KextRequiredHint() }

            Group {
                SegmentedPicker(options: [("1", "性能"), ("2", "标准"), ("3", "安静")],
                                selection: thermalBinding)
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.5 : 1)

                // 2.8.8（用户要求）：「禁用被动散热模式」从「系统调整」搬到这个位置
                // （原来放「启用基准模式」的地方）。它也是 BIOS 持久项，属于散热大类。
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("禁用被动散热模式").font(.system(size: 13, weight: .medium))
                        if !hideCardSubs {
                            Text("EC 0x7A3 bit6，BIOS 持久设置项（三次实测双向确认）")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: passiveCoolingBinding)
                        .toggleStyle(.switch)
                        .tint(Theme.blue)
                        .labelsHidden()
                }
                .disabled(benchmark)
                .opacity(benchmark ? 0.45 : 1)
                .padding(.top, 2)

                Divider().overlay(Theme.line).padding(.top, 2)

                GroupTitle(text: "系统功耗设置", sub: "FAN_MODE_INDEX 0x11 / 0x22 / 0x33")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    perfButton("高性能", 0x11, Theme.red)
                    perfButton("平衡", 0x22, Theme.blue)
                    perfButton("节能", 0x33, Theme.green)
                }
                .disabled(benchmark)
                .opacity(benchmark ? 0.5 : 1)

                // 2.8.8（用户要求）：「启用基准模式」挪到「系统功耗设置」下方。
                // 基准模式是顶层覆盖态：原厂此时把「散热模式」与「系统功耗设置」整组置灰。
                // 放行会把 0x751 从 0x40 打回，增压失效但门还开着。
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用基准模式").font(.system(size: 13, weight: .medium))
                        if !hideCardSubs {
                            Text("0x741 手动门 + 0x751=0x40，实测 5600 RPM；开启期间上面的散热档与功耗档会被接管")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: benchmarkBinding)
                        .toggleStyle(.switch)
                        .tint(Theme.amber)
                        .labelsHidden()
                }
                .padding(.top, 2)
            }
            .kextGated(kextOK)

            Divider().overlay(Theme.line).padding(.top, 2)

            // 2.8.8：手动档位 / 曲线 / ESC 功能键锁定 / EC 探针这些「非原厂能力」
            // 已整体搬到「实验性」页，这里只留一个入口，免得抢原厂功能的视觉位置。
            // 2.8.12：入口本身不需要 kext，所以不跟着置灰（否则 kext 没装时连「怎么装」都点不进去）。
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("手动风扇 / 温控曲线 / EC 探针").font(.system(size: 12.5, weight: .medium))
                    if !hideCardSubs {
                        Text("原厂 UI 没有入口的能力，已移到「实验性」页")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                SecondaryButton(title: "去实验性页", icon: "arrow.up.right", tint: Theme.amber) {
                    NotificationCenter.default.post(name: .mcGotoPage, object: "experimental")
                }
            }
        }
    }

    // MARK: - 只读回读时绝不触发的 Binding（2.8.3）
    private var thermalBinding: Binding<String> {
        Binding(get: { thermal }, set: { v in
            thermal = v
            UIControlPrefs.set(UIControlPrefs.K.thermal, v)   // 先记软件记忆
            Task { await applyThermal(Int(v) ?? 2) }
        })
    }

    private var benchmarkBinding: Binding<Bool> {
        Binding(get: { benchmark }, set: { v in
            benchmark = v
            UIControlPrefs.set(UIControlPrefs.K.benchmark, v)
            Task { await applyBenchmark(v) }
        })
    }

    /// 禁用被动散热（2.8.8 从「系统调整」搬进「散热模式」卡）
    private var passiveCoolingBinding: Binding<Bool> {
        Binding(get: { passiveCoolingDisabled }, set: { v in
            passiveCoolingDisabled = v
            UIControlPrefs.set(UIControlPrefs.K.passiveCooling, v)
            Task { await applySystem("passive_cooling_disabled", v, "禁用被动散热") }
        })
    }

    private var thermalLabel: String {
        ["1": "散热 性能", "2": "散热 标准", "3": "散热 安静"][thermal] ?? "散热 —"
    }

    private var powerLabel: String {
        switch perfIndex {
        case 0x11: return "功耗 高性能"
        case 0x22: return "功耗 平衡"
        case 0x33: return "功耗 节能"
        default: return "功耗 —"
        }
    }

    private func applyThermal(_ level: Int) async {
        let r = await backend.post("/api/fan", ["thermal": level])
        if r["ok"] as? Bool == true {
            showToast("已切换到散热 \(["", "性能", "标准", "安静"][max(1, min(3, level))])")
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            // 被基准模式拒了：把记忆与界面一起弹回上一个值，别让界面骗人
            if let prev = BackendService.int(r, "thermal_level"), (1...3).contains(prev) {
                UIControlPrefs.set(UIControlPrefs.K.thermal, String(prev))
            }
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyBenchmark(_ on: Bool) async {
        let r = await backend.post("/api/fan", ["benchmark": on])
        if r["ok"] as? Bool == true {
            showToast(on ? "基准模式已开启 · 5600 RPM" : "基准模式已关闭 · 回到 \(thermalLabel)")
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            UIControlPrefs.set(UIControlPrefs.K.benchmark, !on)
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - 系统功耗设置三钮（高性能 / 平衡 / 节能，无图标，只有文字）
    private func perfButton(_ title: String, _ code: Int, _ tint: Color) -> some View {
        let active = perfIndex == code
        let hex = String(format: "0x%02X", code)
        return Button {
            perfIndex = code
            UIControlPrefs.set(UIControlPrefs.K.perfIndex, code)
            Task { await applyPerf(code) }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(hex).font(.system(size: 9.5).monospacedDigit()).opacity(0.65)
            }
            .foregroundStyle(active ? .white : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(active ? tint : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? tint : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func applyPerf(_ code: Int) async {
        // 原厂这一下是「功耗 + 散热两组一起写」，不带 thermal_level 时
        // helper 用该功耗档的默认散热档（高性能→性能 / 平衡→标准 / 节能→安静）。
        let r = await backend.post("/api/fan", ["modeindex": code])
        if r["ok"] as? Bool == true {
            let names = [0x11: "高性能", 0x22: "平衡", 0x33: "节能"]
            var msg = "已切换到\(names[code] ?? "")"
            if r["curve_stopped"] as? Bool == true { msg += "（已退出曲线模式）" }
            showToast(msg)
            // 原厂这一下同时带散热档，记忆里的散热档也要跟着更新
            if let t = BackendService.int(r, "thermal_level"), (1...3).contains(t) {
                thermal = String(t)
                UIControlPrefs.set(UIControlPrefs.K.thermal, String(t))
            }
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - 系统调整（原厂 FastSwitch 页 + 电源休眠抑制，竖向单列）
    //
    //   发光灯效：键盘背光（0x7C4 bit6）/ 海岸灯（已移到灯效页）
    //   显示屏　：显示屏电源（macOS 侧走 pmset displaysleepnow，不经 EC）
    //   其他设置：Win 键锁定（0x767 bit0 → 0x768 bit0）、OSD 显示（0x7A4 bit3）
    //   散热相关：安静模式（0x767 bit3 → 0x45B）
    //   电源休眠：caffeinate（原「电源休眠抑制」整卡并入，2.8.8 用户要求）
    private var systemCard: some View {
        Card(title: "系统调整 · 原厂 FastSwitch 页") {
            // 2.8.12：这张卡里只有「键盘背光 / Win 键锁定 / OSD / 安静模式」要 EC，
            // 「显示屏电源」与「保持唤醒」是 macOS 本机能力 —— 所以按行门控，不整卡灰。
            if !kextOK { KextRequiredHint(text: "灰着的几项需要 TongfangFan.kext") }
            VStack(alignment: .leading, spacing: 11) {
                    GroupTitle(text: "发光灯效", sub: "0x07C4 bit6")
                    MiscToggleRow(title: "键盘背光",
                                  sub: "开 = 重发一次灯效（只改亮度点不亮，X15 实测），关 = CTRL_OFF",
                                  on: $kbBacklight) {
                        Task { await applySystem("keyboard_backlight", kbBacklight, "键盘背光") }
                    }
                    .kextGated(kextOK)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("海岸灯").font(.system(size: 13, weight: .medium))
                            if !hideCardSubs {
                                Text("轮换 / 固定色 / 总开关都在「灯效」页")
                                    .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        SecondaryButton(title: "去灯效页", icon: "arrow.up.right", tint: Theme.purple) {
                            NotificationCenter.default.post(name: .mcGotoPage, object: "lighting")
                        }
                    }

                    Divider().overlay(Theme.line)

                    GroupTitle(text: "显示屏", sub: "不经 EC")
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示屏电源").font(.system(size: 13, weight: .medium))
                            if !hideCardSubs {
                                Text("单击关闭内屏，动鼠标或按任意键恢复")
                                    .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        SecondaryButton(title: "关屏", icon: "moon.zzz", tint: Theme.purple) {
                            Task { await displaySleep() }
                        }
                    }

                    Divider().overlay(Theme.line)

                    GroupTitle(text: "其他设置", sub: "0x767 触发位 / 0x7A4 bit3")
                    MiscToggleRow(title: "Win 键锁定",
                                  sub: "0x767 bit0 触发 → 0x768 bit0 回读，状态 ~600ms 才跟上",
                                  on: $winLock) {
                        Task { await applySystem("win_lock", winLock, "Win 键锁定") }
                    }
                    .kextGated(kextOK)
                    MiscToggleRow(title: "OSD 显示",
                                  sub: "EC 0x7A4 bit3：关闭功能键的图片提示",
                                  on: $osd) {
                        Task { await applySystem("osd", osd, "OSD 显示") }
                    }
                    .kextGated(kextOK)

                    Divider().overlay(Theme.line)

                    GroupTitle(text: "散热相关", sub: "与「散热档 安静」是两回事")
                    MiscToggleRow(title: "安静模式",
                                  sub: "0x767 bit3 触发 → 0x45B 回读，降转速更安静",
                                  on: $silentMode) {
                        Task { await applySystem("silent_mode", silentMode, "安静模式") }
                    }
                    .kextGated(kextOK)

                    Divider().overlay(Theme.line)

                    // 2.8.8：原「电源休眠抑制」整卡并入本卡（用户要求），样式与其它开关一致
                    GroupTitle(text: "电源休眠抑制", sub: "caffeinate")
                    MiscToggleRow(title: "保持唤醒",
                                  sub: "阻止显示器与系统休眠，长实验用",
                                  on: caffeinateBinding) { }

                    if !hideCardSubs {
                        Text("开关即时生效；0x7A3 / 0x7A4 / 0x7A6 位很密，写位类操作全部走读-改-写 + 写后回读校验（EC 会丢第一笔）。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
        }
    }

    private func applySystem(_ key: String, _ value: Bool, _ name: String) async {
        // 先写软件记忆（界面立即以记忆为准），再写 EC
        if let prefKey = UIControlPrefs.prefKey(forFanKey: key) {
            UIControlPrefs.set(prefKey, value)
        }
        let r = await backend.post("/api/fan", [key: value])
        if r["ok"] as? Bool == true {
            ToastCenter.shared.showSwitch(name, value)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            // 硬件没认（触发位 toggle 语义下最容易翻反）→ 记忆回滚到相反值
            if let prefKey = UIControlPrefs.prefKey(forFanKey: key) {
                UIControlPrefs.set(prefKey, !value)
            }
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func displaySleep() async {
        let r = await backend.post("/api/control", ["action": "display_sleep"])
        if r["ok"] as? Bool == true {
            showToast("已关屏（动鼠标或按任意键恢复）")
        } else {
            showToast("关屏失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }

    // MARK: - 充电阈值（2.8.8：挪到「散热模式」卡下方，横向排布更紧凑）
    private var chargeCard: some View {
        Card(title: "电池充电阈值 · BATT_CHARGE_CTRL · EC 0x07B9") {
            if !kextOK { KextRequiredHint() }
            Group {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("充至").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        Text("\(Int(chargeThreshold))%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("停止").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                    }
                    if let reached = BackendService.bool(store.fan, "charge_reached") {
                        Text(reached ? "已到达" : "充电中")
                            .font(.system(size: 11.5))
                            .foregroundStyle(reached ? Theme.amber : Theme.green)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        ForEach([60, 70, 80, 90, 100], id: \.self) { v in
                            Button("\(v)%") {
                                chargeThreshold = Double(v)
                                Task { await applyCharge() }
                            }
                            .font(.system(size: 11.5, weight: Int(chargeThreshold) == v ? .semibold : .regular))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                Slider(value: $chargeThreshold, in: 0...100, step: 5) { editing in
                    if !editing { Task { await applyCharge() } }
                }
                .tint(Theme.green)
            }
            .kextGated(kextOK)
        }
    }

    private func applyCharge() async {
        let target = Int(chargeThreshold)
        UIControlPrefs.set(UIControlPrefs.K.charge, target)
        let r = await backend.post("/api/fan", ["charge": target])
        if r["ok"] as? Bool != true {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            syncFromBackend()
        }
    }


    private var caffeinateBinding: Binding<Bool> {
        Binding(get: { caffeinateOn }, set: { v in
            caffeinateOn = v
            UIControlPrefs.set(UIControlPrefs.K.caffeinate, v)   // 先记软件记忆，再下发
            Task { await applyCaffeinate(v) }
        })
    }

    /// 保持唤醒：**以软件记忆为准**（2.8.10）。只有记忆里还没有值时才去问一次
    /// caffeinate 进程（首次启动），之后进页面不再探进程、更不读 EC。
    private func syncCaffeinateIfNeeded() {
        if let v = UIControlPrefs.bool(UIControlPrefs.K.caffeinate) {
            caffeinateOn = v
            return
        }
        Task {
            let r = await backend.post("/api/control", ["action": "caffeinate"])
            if let on = r["on"] as? Bool {
                caffeinateOn = on
                UIControlPrefs.set(UIControlPrefs.K.caffeinate, on)
            }
        }
    }

    private func applyCaffeinate(_ on: Bool) async {
        let r = await backend.post("/api/control", ["action": "caffeinate", "on": on])
        if r["ok"] as? Bool == true {
            ToastCenter.shared.showSwitch("保持唤醒", on)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }
}

// MARK: - 通用开关行（标题 + 副标题 + 开关，点击即生效）
private struct MiscToggleRow: View {
    let title: String
    let sub: String
    @Binding var on: Bool
    let action: () -> Void
    /// 2.8.9：副标题默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                // 副标题（寄存器说明）默认不显示；代码保留
                if !hideCardSubs {
                    Text(sub).font(.system(size: 11)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { on },
                set: { v in on = v; action() }))
            .toggleStyle(.switch)
            .tint(Theme.blue)
            .labelsHidden()
        }
    }
}

// MARK: - Color → hex 工具
extension Color {
    func toHex() -> String {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
        #else
        return "000000"
        #endif
    }
}
