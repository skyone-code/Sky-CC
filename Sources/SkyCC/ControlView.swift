import SwiftUI
import AppKit

/// 控制页：显卡路由 / 散热模式 / 系统功耗设置 / 系统调整 / 充电阈值 / 防休眠
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
    // 基准模式（文档 §3.3；EC 侧投影 = 0x751=0x40 风扇全速）
    @State private var benchmark = false
    // 系统功耗设置：0x11 / 0x22 / 0x33（EC 0x7AB 高半字节）
    @State private var perfIndex: Int = 0x11

    @State private var chargeThreshold: Double = 80

    // 显卡路由（2026-11-05 引入）：2026-11-07 曾搬去「设置 → 外观与通用」，
    // 2026-11-14 并入「设置 → 系统调整」尾部；**2026-11-17（用户要求）拆回本页**，
    // 独立成卡放在「散热模式」上方。段内自带 @State（见 GpuRouteCard.swift），
    // 本页只负责外壳与位置，不持有它的状态。

    // 禁用被动散热模式（留在本页「散热模式」卡内；3.0.4.5 「系统调整」卡已迁设置页）
    @State private var passiveCoolingDisabled = false

    // 风扇手动档位 / 温控曲线（原实验性页迁入，用户要求去掉实验性页）
    @State private var fanMode: String = "normal"
    @State private var fanLevel: Double = 0
    /// 手动档位滑条是草稿：拖完必须点「确定应用」才写 EC
    @State private var levelDirty = false

    // 交互锁：2.8.8 起界面以「软件记忆」为准，不再需要锁窗口防回读覆盖

    /// 2.8.9：卡片说明/副标题默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    private var kextOK: Bool { backend.kextLoaded }
    /// 快照读回来了没有 —— 没读回来之前不显示「标准 / 高性能」这类可能骗人的高亮
    private var synced: Bool { !store.fan.isEmpty }

    // 2026-11-14（用户要求，首帧记忆）：所有状态初始值在构造时同步读软件记忆，
    // 首帧即上次选择；EC 异步回读后如果对不上，再可见校正（用户允许）。
    // 之前是默认值起步 → 异步回读再「跳」到真位置，观感就是页面先停在默认。
    init() {
        _thermal = State(initialValue: UIControlPrefs.string(UIControlPrefs.K.thermal) ?? "2")
        _benchmark = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.benchmark) ?? false)
        _perfIndex = State(initialValue: UIControlPrefs.int(UIControlPrefs.K.perfIndex) ?? 0x11)
        _chargeThreshold = State(initialValue: Double(UIControlPrefs.int(UIControlPrefs.K.charge) ?? 80))
        _passiveCoolingDisabled = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.passiveCooling) ?? false)
        _fanMode = State(initialValue: UIControlPrefs.string(UIControlPrefs.K.fanMode) ?? "normal")
        _fanLevel = State(initialValue: Double(UIControlPrefs.int(UIControlPrefs.K.fanLevel) ?? 0))
    }

    var body: some View {
        // 3.0.4.5（用户要求）版式：散热模式｜手动档位/温控曲线｜电池充电阈值，通栏单列。
        // （风扇转速卡在「概览」页；「系统调整」卡在「设置」页。）
        // 3.0.7（2026-11-17 用户要求）：显卡路由卡从设置页拆回本页，置顶于散热模式之上。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !kextOK { KextBanner() }
                header
                gpuCard
                thermalCard
                fanManualCard
                chargeCard
            }
            .padding(22)
        }

        .onAppear {
            // 3.0.4.5：风扇卡已迁去「概览」页，实时转速租约随之搬走，本页不再声明。
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
            }
        }
        .onChange(of: store.updatedAt) { _, _ in
            syncFromBackend()
        }
        .toastOverlay()
    }

    private var header: some View {
        PageHeader(title: "控制",
                   sub: "显卡路由 / 散热模式 / 系统功耗设置 / 充电阈值 · 所有开关以硬件真实回读为准",
                   trailing: {
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
                       }
                   })
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
            // EC 真值同步写回记忆：下次进页 init() 的首帧就是它（记忆与 EC 保持新鲜）
            UIControlPrefs.set(UIControlPrefs.K.thermal, String(t))
        }
        if let mi = BackendService.int(store.fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi) {
            perfIndex = mi
            UIControlPrefs.set(UIControlPrefs.K.perfIndex, mi)
        }
        // 其余开关仍以记忆为准
        if let b = UIControlPrefs.bool(UIControlPrefs.K.benchmark) { benchmark = b }
        if let ch = UIControlPrefs.int(UIControlPrefs.K.charge) { chargeThreshold = Double(ch) }
        // 风扇手动档位（原实验性页迁入）：记忆为准，草稿没确认前不打回滑条
        if let m = UIControlPrefs.string(UIControlPrefs.K.fanMode) { fanMode = m }
        if !levelDirty, let lv = UIControlPrefs.int(UIControlPrefs.K.fanLevel) {
            fanLevel = Double(lv)
        }
    }

    private func showToast(_ s: String) {
        ToastCenter.shared.show(s)
    }

    // MARK: - 显卡路由（2026-11-17 从设置页拆回本页，置于散热模式上方）
    //
    // 只套 Card 外壳，段内自带头部说明与 /api/gpu 回读逻辑（GpuRouteCard.swift）。
    // 这张卡不碰 EC，所以**不做 kextGated 置灰** —— kext 没装时它照样可用。
    private var gpuCard: some View {
        Card(title: "显卡 · 独显白名单") {
            GpuRouteSection()
        }
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

                // 与「系统功耗设置」之间的分隔（样式沿用原来的横线）
                Divider().overlay(Theme.line).padding(.top, 2)

                GroupTitle(text: "系统功耗设置", sub: "FAN_MODE_INDEX 0x11 / 0x22 / 0x33")
                // 2026-11-07（用户要求，第三次）：不再用「三个独立方块」，
                // 改成与上面「散热模式」完全同构的分段条（同一 4pt 内距 + 11pt 外框 +
                // 30pt 段高），只把选中块的填充色换成各自档位的颜色。
                perfSegmented
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.5 : 1)

                // 2026-11-14（用户要求）：分隔线把「基准模式 + 禁用被动散热」两个开关
                // 与上方的系统功耗设置隔开（样式与散热模式/系统功耗设置之间那条一致）。
                // 基准模式是顶层覆盖态：原厂此时把「散热模式」与「系统功耗设置」整组置灰。
                // 放行会把 0x751 从 0x40 打回，增压失效但门还开着。
                Divider().overlay(Theme.line).padding(.top, 2)

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用基准模式").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.txt)
                        if !hideCardSubs {
                            Text("0x751=0x40 风扇全速，实测 5600 RPM；开启期间上面的散热档与功耗档会被接管")
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

                // 「禁用被动散热模式」按用户要求挪到「基准模式」下方（同属散热大类，
                // 也是 BIOS 持久项）
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("禁用被动散热模式").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.txt)
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
            }
            .kextGated(kextOK)
        }
    }

    // MARK: - 风扇手动档位 / 温控曲线（原「实验性」页整卡迁入，用户要求去掉实验性页）
    private var fanManualCard: some View {
        Card(title: "风扇 · 手动档位 / 温控曲线 · EC 0x0741 / 0x0751") {
            // kext 未装时整段置灰（控件保留、布局不跳）
            if !kextOK { KextRequiredHint() }
            // 基准模式下 0x751 由全速档接管，这里整段置灰
            let benchmark = BackendService.bool(store.fan, "benchmark") ?? false
            Group {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("控制方式").font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.txt)
                            .foregroundStyle(Theme.dim).frame(width: 62, alignment: .leading)
                        SegmentedPicker(options: [("normal", "自动"), ("custom", "手动"), ("curve", "曲线")],
                                        selection: fanModeBinding)
                        Spacer(minLength: 0)
                    }
                    .disabled(benchmark)
                    .opacity(benchmark ? 0.45 : 1)

                    if benchmark {
                        Text("基准模式开着（0x0751 = 0x40）。放开手动档位会把 0x0751 打回，增压失效但门还开着 —— "
                             + "请先关掉上面的基准模式。")
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
                            Text("FAN_CTRL = 0x80 + 档位；写入前需 0x741 bit0（AP exist / 控制中心接管）在位。"
                                 + "退出「手动」或「曲线」时会自动交还档位（先放 0x751=0x00），"
                                 + "EC 随即按 0x7AB 重算 0x751。")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if fanMode == "curve" {
                        Divider().overlay(Theme.line)
                        FanCurveView()
                    } else {
                        Text("手动与曲线都关闭：散热回到自动模式，由 EC 固件接管，上面的「散热模式」三档照常生效。")
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
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
        let name = ["normal": "自动", "custom": "手动 L\(Int(fanLevel))", "curve": "温控曲线"][mode] ?? mode
        if r["ok"] as? Bool == true {
            showToast("风扇已切换到\(name)")
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    // MARK: - 系统功耗设置（高性能 / 平衡 / 节能）
    //
    // 2026-11-07（用户要求，第三次）：外观改成与「散热模式」的 SegmentedPicker
    // **完全同构** —— 同一条 11pt 圆角外框 + 4pt 内距 + 30pt 段高 + 8pt 段圆角，
    // 未选中段透明、选中段填充；唯一区别是填充色按档位取红 / 蓝 / 绿，
    // 而不是统一蓝。这样上下两组切换器宽高、内距、圆角完全一致，只是颜色不同。
    private var perfSegmented: some View {
        HStack(spacing: 4) {
            perfSegment("高性能", 0x11, Theme.red)
            perfSegment("平衡", 0x22, Theme.blue)
            perfSegment("节能", 0x33, Theme.green)
        }
        .padding(4)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    private func perfSegment(_ title: String, _ code: Int, _ tint: Color) -> some View {
        let active = perfIndex == code
        return Button {
            perfIndex = code
            UIControlPrefs.set(UIControlPrefs.K.perfIndex, code)
            Task { await applyPerf(code) }
        } label: {
            Text(title)
                // 字号 / 字重规则与 SegmentedPicker 逐字对齐（12.5，选中 semibold）
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? tint : Color.clear)
                )
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    private func applySystem(_ key: String, _ value: Bool, _ name: String) async {
        // 先写软件记忆（界面立即以记忆为准），再写 EC。
        // （3.0.4.5：「系统调整」卡迁设置页后，本页只剩「禁用被动散热」一个布尔写位用到这里。）
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
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
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

