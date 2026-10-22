import SwiftUI

/// 键盘灯效页：静态颜色 / 灯效 / 分区配色 / 白平衡 / 记忆恢复
/// 交互原则（用户要求）：所有连续型控件（ColorPicker / 滑条 / 档位）拖动即生效，
/// 不再有「应用」按钮；只有「关闭键盘灯 / 标定 / 重置 / 恢复记忆」这类一次性动作保留按钮。
struct RGBView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    // 单色
    @State private var solidColor: Color = Color(hex: 0xffffff)
    @State private var solidBright: Double = 4
    private let presetColors: [Color] = [
        Color(hex: 0xffffff), Color(hex: 0xff3b30), Color(hex: 0xff9500), Color(hex: 0xffcc00),
        Color(hex: 0x34c759), Color(hex: 0x00a0ff), Color(hex: 0xaf52de), Color(hex: 0xff2d55)
    ]

    // 灯效
    private let effects: [(String, String)] = [
        ("breathing", "呼吸"), ("wave", "波浪"), ("rainbow", "彩虹"), ("ripple", "涟漪"),
        ("marquee", "跑马灯"), ("raindrop", "雨滴"), ("aurora", "极光"),
        ("random", "随机"), ("reactive", "按键响应"), ("reactiveripple", "响应涟漪"),
        ("reactiveaurora", "响应极光"), ("fireworks", "烟花")
    ]
    @State private var effect: String = "rainbow"
    @State private var effectSpeed: Double = 5
    @State private var effectBright: Double = 3
    @State private var effectCustomColor: Color = Color(hex: 0x00a0ff)
    @State private var effectUseCustom = false

    // 分区（6 区）
    private let zoneDefaults: [Color] = [
        Color(hex: 0xff3b30), Color(hex: 0xff9500), Color(hex: 0xffcc00),
        Color(hex: 0x34c759), Color(hex: 0x00a0ff), Color(hex: 0xaf52de)
    ]
    @State private var zones: [Color] = [Color(hex: 0xff3b30), Color(hex: 0xff9500), Color(hex: 0xffcc00),
                                         Color(hex: 0x34c759), Color(hex: 0x00a0ff), Color(hex: 0xaf52de)]
    @State private var zoneBright: Double = 4

    // 白平衡
    @State private var wbSlider: Double = 0
    @State private var wbObserved: Color = Color(hex: 0xffffff)

    @State private var toast: String?

    @StateObject private var locks = EditLocks()
    // 防抖任务（连续拖动 ColorPicker / 滑条时，只把最后一次值发给硬件）
    @State private var solidDebounce: Task<Void, Never>?
    @State private var effectColorDebounce: Task<Void, Never>?
    @State private var effectParamDebounce: Task<Void, Never>?
    @State private var zoneDebounce: Task<Void, Never>?

    private var rgbAvailable: Bool { store.rgb["available"] as? Bool ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !rgbAvailable {
                    unavailableCard
                } else {
                    // 2.7.2 重排：左列「当前状态 → 单色 → 分区配色」，右列「灯效 → 灯效通用」，
                    // 2.7.5：白平衡并进「灯效通用」（原「灯效记忆」改名），页面不再有独立的白平衡卡。
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            deviceCard
                            solidCard
                            zoneCard
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            effectCard
                            generalCard
                        }
                        .frame(width: 356)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .onAppear { syncFromBackend() }
        .onChange(of: store.updatedAt) { _, _ in syncFromBackend() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast != nil)
    }

    private var header: some View {
        PageHeader(title: "灯效", sub: "键盘 RGB · ITE 8291 · USB HID 直写",
                   trailing: AnyView(
                    HStack(spacing: 8) {
                        Circle().fill(rgbAvailable ? Theme.green : Theme.red).frame(width: 7, height: 7)
                        Text(rgbAvailable ? "设备在线" : "设备离线")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }))
    }

    private var unavailableCard: some View {
        Card(title: "设备状态") {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.badge.ellipsis").foregroundStyle(Theme.amber)
                Text(BackendService.string(store.rgb, "error") ?? "未检测到 ITE 8291 键盘灯设备（内屏盖屏/外接键盘时 HID 路径变化属正常）")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: - 设备信息
    private var deviceCard: some View {
        let info = BackendService.dict(store.rgb, "info")
        let state = BackendService.dict(store.rgb, "state")
        let profile = BackendService.dict(store.rgb, "profile")
        return Card(title: "当前状态") {
            HStack(spacing: 24) {
                // 色块示意
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: UInt32(BackendService.string(profile, "hex") ?? "ffffff", radix: 16) ?? 0xffffff))
                    .frame(width: 64, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                    .shadow(color: Color(hex: UInt32(BackendService.string(profile, "hex") ?? "ffffff", radix: 16) ?? 0).opacity(0.5), radius: 10)
                VStack(alignment: .leading, spacing: 6) {
                    KVRow(key: "设备", value: "\(BackendService.string(info, "product") ?? "ITE 8291") · \(BackendService.string(info, "vendor_id") ?? "")")
                    KVRow(key: "模式", value: profileModeLabel(BackendService.string(profile, "mode") ?? "—"))
                    KVRow(key: "颜色", value: "#\(BackendService.string(profile, "hex")?.uppercased() ?? "—")")
                    KVRow(key: "亮度档", value: "L\(BackendService.int(profile, "brightness") ?? 0)")
                    KVRow(key: "硬件回读", value: (state?.isEmpty ?? true) ? "—" : "mode=\(BackendService.int(state, "mode") ?? 0) program=\(BackendService.int(state, "program") ?? 0) speed=\(BackendService.int(state, "speed") ?? 0)")
                    if let updated = BackendService.string(profile, "updated") {
                        KVRow(key: "记忆时间", value: updated)
                    }
                }
            }
        }
    }

    private func profileModeLabel(_ m: String) -> String {
        switch m {
        case "color": return "单色"
        case "effect": return "灯效"
        case "zones": return "分区"
        case "off": return "关闭"
        default: return m
        }
    }

    // MARK: - 单色（选色即生效，自动记忆）
    private var solidCard: some View {
        Card(title: "单色 · 常亮指定颜色") {
            HStack(spacing: 10) {
                ColorPicker("", selection: $solidColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 30)
                    .onChange(of: solidColor) { _, c in
                        // 拖动取色会连续触发，防抖 200ms 只发最后一次
                        solidDebounce?.cancel()
                        solidDebounce = Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            locks.lock("solid")
                            await applySolid(c, Int(solidBright))
                        }
                    }
                ForEach(presetColors, id: \.self) { c in
                    Circle()
                        .fill(c)
                        .frame(width: 20, height: 20)
                        // 浅色主题：白色色板必须带描边才看得见（用户特别提醒过）
                        .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                        .onTapGesture {
                            locks.lock("solid")
                            solidColor = c
                            Task { await applySolid(c, Int(solidBright)) }
                        }
                }
                Spacer()
                Text(solidColor.toHex())
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
            }
            HStack {
                Text("亮度档").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                Spacer()
                SegmentedPicker(options: [(1.0, "L1"), (2.0, "L2"), (3.0, "L3"), (4.0, "L4")],
                                selection: $solidBright)
                    .frame(width: 220)
                    .onChange(of: solidBright) { _, b in
                        locks.lock("solid")
                        Task { await applySolid(solidColor, Int(b)) }
                    }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "关闭键盘灯", icon: "power", tint: Theme.red) {
                    Task {
                        let r = await backend.post("/api/rgb", ["mode": "off"])
                        showToast(r["ok"] as? Bool == true ? "键盘灯已关闭" : "失败")
                    }
                }
                Spacer()
            }
        }
    }

    private func applySolid(_ color: Color, _ bright: Int) async {
        let r = await backend.post("/api/rgb", [
            "mode": "color", "hex": color.toHex(), "brightness": bright, "save": 1
        ])
        if r["ok"] as? Bool != true {
            showToast("失败：\(BackendService.string(r, "error") ?? "")")
        }
    }

    // MARK: - 灯效（选灯效 / 拖速度 / 调亮度即生效）
    private var effectCard: some View {
        Card(title: "动态灯效") {
            // 窄列（306pt）下 3 列比 4 列松快：中文名字不会再被压成两行
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(effects, id: \.0) { eff in
                    let active = effect == eff.0
                    Button {
                        locks.lock("effect")
                        effect = eff.0
                        Task { await applyEffect() }
                    } label: {
                        Text(eff.1)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : Theme.dim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Theme.purple : Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? Theme.purple : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("速度").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                Slider(value: $effectSpeed, in: 1...10, step: 1)
                    .frame(maxWidth: 220)
                    .onChange(of: effectSpeed) { _, _ in
                        effectParamDebounce?.cancel()
                        effectParamDebounce = Task {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            locks.lock("effect")
                            await applyEffect()
                        }
                    }
                Spacer()
                Text("\(Int(effectSpeed))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
            }
            HStack {
                Text("亮度").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                SegmentedPicker(options: [(1.0, "L1"), (2.0, "L2"), (3.0, "L3"), (4.0, "L4")],
                                selection: $effectBright)
                    .frame(width: 220)
                    .onChange(of: effectBright) { _, _ in
                        locks.lock("effect")
                        Task { await applyEffect() }
                    }
                Spacer()
            }
            Toggle("用自定义颜色跑此灯效（命名色 0x14 + 槽位）", isOn: $effectUseCustom)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .onChange(of: effectUseCustom) { _, _ in
                    locks.lock("effect")
                    Task { await applyEffect() }
                }
            if effectUseCustom {
                HStack {
                    ColorPicker("", selection: $effectCustomColor, supportsOpacity: false)
                        .labelsHidden().frame(width: 44, height: 30)
                        .onChange(of: effectCustomColor) { _, c in
                            effectColorDebounce?.cancel()
                            effectColorDebounce = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                locks.lock("effect")
                                await applyEffect(c)
                            }
                        }
                    Text(effectCustomColor.toHex()).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                    Spacer()
                }
            }
            Text("自定义颜色无回读通道，实际颜色以肉眼为准（呼吸/彩虹等自带彩色的灯效选自定义色会被固件覆盖）")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
        }
    }

    private func applyEffect() async {
        await applyEffect(nil)
    }

    private func applyEffect(_ custom: Color?) async {
        var body: [String: Any] = [
            "mode": "effect", "style": effect,
            "speed": Int(effectSpeed), "brightness": Int(effectBright), "save": 1
        ]
        if effectUseCustom {
            body["hex"] = (custom ?? effectCustomColor).toHex()
        }
        let r = await backend.post("/api/rgb", body)
        if r["ok"] as? Bool != true {
            showToast("灯效失败：\(BackendService.string(r, "error") ?? "")")
        }
    }

    // MARK: - 分区（选色即生效）
    private var zoneCard: some View {
        Card(title: "分区配色 · 6 区独立颜色") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text("第 \(i + 1) 区").font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        ColorPicker("", selection: $zones[i], supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: zones[i]) { _, _ in
                                zoneDebounce?.cancel()
                                let bright = Int(zoneBright)
                                zoneDebounce = Task {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    locks.lock("zones")
                                    await applyZones(bright)
                                }
                            }
                    }
                    .padding(.vertical, 8)
                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            HStack {
                Text("亮度").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                SegmentedPicker(options: [(1.0, "L1"), (2.0, "L2"), (3.0, "L3"), (4.0, "L4")],
                                selection: $zoneBright)
                    .frame(width: 220)
                    .onChange(of: zoneBright) { _, b in
                        locks.lock("zones")
                        Task { await applyZones(Int(b)) }
                    }
                Spacer()
            }
        }
    }

    private func applyZones(_ bright: Int) async {
        let zs = zones.map { [$0.toHex().toRGB().0, $0.toHex().toRGB().1, $0.toHex().toRGB().2] }
        let r = await backend.post("/api/rgb", ["mode": "zones", "zones": zs, "brightness": bright])
        if r["ok"] as? Bool != true {
            showToast("分区失败：\(BackendService.string(r, "error") ?? "")")
        }
    }

    // MARK: - 灯效通用（记忆 + 白平衡，2.7.5 合并；原「灯效记忆」）
    private var generalCard: some View {
        Card(title: "灯效通用") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SecondaryButton(title: "立即恢复上次灯效", icon: "arrow.clockwise") {
                        Task {
                            let r = await backend.post("/api/rgb/apply", [:])
                            showToast(r["ok"] as? Bool == true ? "已恢复" : "恢复失败")
                        }
                    }
                    SecondaryButton(title: "清除记忆", icon: "trash", tint: Theme.red) {
                        Task {
                            let r = await backend.post("/api/rgb/forget", [:])
                            showToast(r["ok"] as? Bool == true ? "已清除（开机不再恢复）" : "失败")
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text("开机恢复由 com.macconsole.rgbrestore 登录项完成；EC 断电会丢灯效，所以每次变更都会自动记忆。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.line)

                GroupTitle(text: "白平衡", sub: "消除偏色")
                whiteBalanceBody
            }
        }
    }

    // MARK: - 白平衡（内容，2.7.5 起挂在「灯效通用」卡里）
    private var whiteBalanceBody: some View {
        let wg = BackendService.dict(store.rgb, "white_gain")
        let sliderPos = BackendService.int(wg, "slider") ?? 0
        let calibrated = sliderPos > 0
        let profMode = BackendService.string(BackendService.dict(store.rgb, "profile"), "mode") ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("增益滑条").font(.system(size: 12)).foregroundStyle(Theme.dim)
                Slider(value: $wbSlider, in: 0...100, step: 1)
                    .frame(maxWidth: 200)
                    .onChange(of: wbSlider) { _, v in
                        locks.lock("wb")
                        Task { await applyWhiteGain(t: v) }
                    }
                Spacer(minLength: 6)
                Text("t=\(Int(wbSlider))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.dim)
            }
            Text("当前增益 R \(BackendService.int(wg, "R") ?? 0) · G \(BackendService.int(wg, "G") ?? 0) · B \(BackendService.int(wg, "B") ?? 0)（1000 = 原色）")
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.dim2)
                .fixedSize(horizontal: false, vertical: true)
            // 标定状态：已标定 = 落盘记忆，重启/多次开关都不丢，直到再次标定或重置
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: calibrated ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(calibrated ? Theme.green : Theme.dim2)
                    .font(.system(size: 10.5))
                Text(calibrated ? "已标定并记忆（t=\(sliderPos)）—— 重启后自动恢复，再次标定或重置前一直有效"
                                : "未标定（当前为原色，无增益）")
                    .font(.system(size: 10.5)).foregroundStyle(calibrated ? Theme.green : Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if profMode == "effect" {
                Text("注意：当前是动态灯效模式，颜色由固件生成，增益不参与运算；"
                     + "标定对「单色 / 分区」模式生效（切过去即可看到效果）。")
                    .font(.system(size: 10)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ColorPicker("", selection: $wbObserved, supportsOpacity: false)
                    .labelsHidden().frame(width: 40, height: 26)
                SecondaryButton(title: "据此标定", icon: "eye") {
                    Task { await calibrateWhite() }
                }
                SecondaryButton(title: "重置", icon: "arrow.counterclockwise", tint: Theme.amber) {
                    Task {
                        _ = await backend.post("/api/rgb/whitegain/reset", [:])
                        wbSlider = 0
                        showToast("白平衡已重置")
                    }
                }
                Spacer(minLength: 0)
            }
            Text("标定后该点成为滑条端点（t=100），可继续微调；立即生效并记忆。")
                .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applyWhiteGain(t: Double) async {
        _ = await backend.post("/api/rgb/whitegain", ["t": Int(t)])
    }

    private func calibrateWhite() async {
        locks.lock("wb")
        let r = await backend.post("/api/rgb/whitecal", ["observed": wbObserved.toHex()])
        if r["ok"] as? Bool == true {
            wbSlider = 100
            showToast("标定完成，白平衡已更新并记忆（重启后自动恢复）")
        } else {
            showToast("标定失败：\(BackendService.string(r, "error") ?? "")")
        }
    }

    // MARK: - 记忆
    private var profileCard: some View {
        Card(title: "灯效记忆") {
            HStack(spacing: 10) {
                SecondaryButton(title: "立即恢复上次灯效", icon: "arrow.clockwise") {
                    Task {
                        let r = await backend.post("/api/rgb/apply", [:])
                        showToast(r["ok"] as? Bool == true ? "已恢复" : "恢复失败")
                    }
                }
                SecondaryButton(title: "清除记忆", icon: "trash", tint: Theme.red) {
                    Task {
                        let r = await backend.post("/api/rgb/forget", [:])
                        showToast(r["ok"] as? Bool == true ? "已清除（开机不再恢复）" : "失败")
                    }
                }
                Spacer()
            }
            Text("开机恢复由 com.macconsole.rgbrestore 登录项完成；EC 断电会丢灯效，所以每次变更都会自动记忆。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
        }
    }

    // MARK: -
    private func syncFromBackend() {
        guard rgbAvailable else { return }
        // 用户正在编辑单色时不回读（否则刚选的颜色被 profile 旧值刷回去）
        if locks.locked("solid") { return }
        let profile = BackendService.dict(store.rgb, "profile")
        if let hex = BackendService.string(profile, "hex"), hex.count == 6 {
            solidColor = Color(hex: UInt32(hex, radix: 16) ?? 0xffffff)
        }
        if let b = BackendService.int(profile, "brightness") { solidBright = Double(b) }
        // 白平衡滑条从后端真实增益回填（标定值落盘在 ~/Library/Application Support，
        // 重启后滑条必须显示记忆值，否则看起来像"没记住"）
        if !locks.locked("wb"),
           let s = BackendService.int(BackendService.dict(store.rgb, "white_gain"), "slider") {
            wbSlider = Double(s)
        }
    }

    private func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2200_000_000)
            if toast == s { toast = nil }
        }
    }
}

private extension String {
    func toRGB() -> (Int, Int, Int) {
        var hex = self
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return (0, 0, 0) }
        return (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
    }
}
