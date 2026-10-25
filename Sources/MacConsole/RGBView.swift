import SwiftUI

/// 键盘灯效页：键盘灯效 / 逐键投影 / 海岸灯 / 记忆恢复
///
/// 【2.8.8 用户要求】
///   · 「动态灯效」标题改「键盘灯效」
///   · 「恢复原厂 7 色」按钮文字改「恢复」
///   · 删掉「白平衡」整段（原厂没有这个入口，且标定后颜色反而不准）
///   · 逐键自定义补上键盘投影：点哪个键、就点亮哪个颜色
///   · 海岸灯加一个总开关（开 = 回到上次的轮换/固定色，关 = CTRL_OFF）
///   · 修 bug：调完亮度滑条会跳回 0% / 1%（芯片回读把颜色的 G 通道当亮度）
///
/// 硬性约束：本页**所有**写硬件的动作只能由用户点击/拖动产生。
/// 程序化回读一律直接改 @State，绝不经过 onChange —— 否则一进页面就
/// 把界面默认值（比如「彩虹」「75%」）当成用户操作写进键盘。
struct RGBView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    /// 逐键矩阵规格（与芯片一致：6 行 × 21 列 = 126 个位置）
    private static let keyRows = 6
    private static let keyCols = 21

    /// 键盘上的一个键（2026-10-25 按原厂键位表重建）
    ///
    /// 来源：Intel NUC Software Studio 的 `KeyMapUS`（`MobileKeyboardLedMgr.dll`，
    /// 即原厂自己用的表）。一行固定 16 个网格位，`leds` 是该键实际点亮的 LED 索引
    /// （绝对索引 = 行×21 + 列）。大键占多位：左 Shift 3 位 3 颗灯，Enter / Tab /
    /// Caps / 空格等占多位但只有 1…2 颗灯，与真机一致。
    private struct KeyDef {
        var label: String
        var span: Int
        var leds: [Int]
    }

    /// 选中的键（键位下标，非 LED 下标）
    private struct KeyPick: Equatable { var row: Int; var idx: Int }

    private static func k(_ label: String, _ led: Int, _ span: Int = 1) -> KeyDef {
        KeyDef(label: label, span: span, leds: [led])
    }

    /// US 布局，6 行各 16 个网格位（ESC 行在最上 = LED 第 1 行）
    private static let layout: [[KeyDef]] = [
        [k("esc", 0), k("F1", 1), k("F2", 2), k("F3", 3), k("F4", 4), k("F5", 5),
         k("F6", 6), k("F7", 7), k("F8", 8), k("F9", 9), k("F10", 10), k("F11", 11),
         k("F12", 12), k("ins", 13), k("srlk", 14), k("del", 15)],
        [k("`", 21), k("1", 22), k("2", 23), k("3", 24), k("4", 25), k("5", 26),
         k("6", 27), k("7", 28), k("8", 29), k("9", 30), k("0", 31), k("-", 32),
         k("=", 33), KeyDef(label: "⌫", span: 2, leds: [35]), k("home", 36)],
        [KeyDef(label: "tab", span: 2, leds: [42]),
         k("Q", 44), k("W", 45), k("E", 46), k("R", 47), k("T", 48), k("Y", 49),
         k("U", 50), k("I", 51), k("O", 52), k("P", 53), k("[", 54), k("]", 55),
         k("\\", 56), k("pgup", 57)],
        [KeyDef(label: "caps", span: 2, leds: [63]),
         k("A", 65), k("S", 66), k("D", 67), k("F", 68), k("G", 69), k("H", 70),
         k("J", 71), k("K", 72), k("L", 73), k(";", 74), k("'", 75),
         KeyDef(label: "⏎", span: 2, leds: [76, 77]), k("pgdn", 78)],
        [KeyDef(label: "shift", span: 3, leds: [84, 85, 86]),
         k("Z", 87), k("X", 88), k("C", 89), k("V", 90), k("B", 91), k("N", 92),
         k("M", 93), k(",", 94), k(".", 95), k("/", 96),
         k("shift", 97), k("↑", 98), k("end", 99)],
        [KeyDef(label: "ctrl", span: 2, leds: [105]), k("fn", 107), k("⌘", 108),
         k("alt", 109), KeyDef(label: "space", span: 5, leds: [112]),
         k("alt", 115), k("menu", 116), k("ctrl", 117),
         k("←", 118), k("↓", 119), k("→", 120)],
    ]

    // MARK: - 灯效草稿
    @State private var effect: String = "rainbow"
    @State private var effectSpeed: Double = 5
    /// 亮度百分比（0…100）。以前是 L1…L4 等级，2.8.3 起改滑条。
    @State private var effectBright: Double = 75
    /// 方向：1 右 / 2 左 / 3 上 / 4 下（只有波浪 / 跑马灯 / 极光有意义）
    @State private var effectDirection: Double = 1
    /// 灯效草稿是否被改过（改过就不再被轮询回读覆盖）
    @State private var effectDirty = false

    private var effects: [(String, String)] {
        KeyboardCatalog.meEffects.map { (KeyboardCatalog.key(for: $0), $0.title) }
    }

    /// 当前灯效（用于取原厂的颜色的个数 / ColorIndex / 是否支持方向）
    private var currentEffect: KeyboardEffect {
        KeyboardCatalog.effect(forName: effect) ?? .rainbow
    }
    /// 这个灯效要用几个颜色 —— 原厂写死 0/1/3/7，**不是**用户随便调的滑块。
    private var paletteSize: Int { KeyboardCatalog.colorCount(currentEffect) }
    /// 是不是逐键自定义（0x33）：这个模式不用调色板，改用键盘投影
    private var isKeymap: Bool { currentEffect == .userMode }

    // 灯效颜色：固定 7 个槽位（原厂 ColorBlock 的 7 色默认调色板），
    // 实际下发几个由当前灯效决定（见 paletteSize）。
    @State private var palette: [Color] = KeyboardCatalog.defaultPalette.map {
        Color(hex: UInt32(($0.0 << 16) | ($0.1 << 8) | $0.2))
    }

    // MARK: - 逐键投影（2.8.8 新增，2026-10-25 换成真实键盘布局）
    /// 6 行 × 21 列的逐键颜色草稿（LED 级，下标 = 行×21 + 列）
    @State private var keymap: [[Color]] = Array(
        repeating: Array(repeating: Color(hex: 0x000000), count: 21), count: 6)
    /// 当前选中的键（键位下标，非 LED 下标）
    @State private var picked: KeyPick?
    /// 笔刷色：点投影里的键就用这个颜色
    @State private var brush: Color = Color(hex: 0x00A0FF)

    // MARK: - 海岸灯（2.8.3 从控制页搬入）
    @State private var lbMode: String = "cycle"       // cycle / static / off
    @State private var lbColor: Color = .blue
    /// 关灯前的模式，用来让开关「开」时回到原来的观感
    @State private var lbLastMode: String = "cycle"
    /// 海岸灯草稿是否被改过（草稿期间不被 5 秒回读覆盖）
    @State private var lbDirty = false

    /// 2.8.9：卡片说明默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    @StateObject private var locks = EditLocks()
    /// 音乐律动引擎（2026-10-25：固件 0x22 不自带动画，靠它抓系统音频实时上色）
    @ObservedObject private var music = MusicEngine.shared

    private var rgbAvailable: Bool { store.rgb["available"] as? Bool ?? false }
    private var lightbarAvailable: Bool { store.lightbar["available"] as? Bool ?? false }
    /// 海岸灯不可用的真实原因（2.8.12）：ok / stale / read / kext
    private var lightbarReason: String {
        if !backend.kextLoaded { return "kext" }
        return store.lightbar["reason"] as? String ?? "ok"
    }
    /// 快照读回来了没有 —— 没读回来之前控件置灰，避免界面的默认值被当成 EC 真值
    private var synced: Bool { !store.rgb.isEmpty }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !rgbAvailable {
                        unavailableCard
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            // 左：键盘灯效（宽，内容最多）
                            effectCard
                                .frame(maxWidth: .infinity, alignment: .top)
                            // 右：海岸灯 + 通用
                            VStack(spacing: 14) {
                                lightbarCard
                                generalCard
                                Spacer(minLength: 0)
                            }
                            .frame(width: 360)
                        }
                        // 2.8.8：原来这里给 HStack 一个 560 的固定下限，卡片被拉高、
                        // 内部空出一整块。改成按内容自然高度，再用下面这张设备信息卡
                        // 把剩下的版面填上（信息是真的有用，不是拿空白凑）。
                        deviceCard
                    }
                }
                .padding(22)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
        .background(Theme.bg)
        .onAppear {
            // 2.8.15：海岸灯没有软件记忆，状态只能从 EC 读。进灯效页读一次，
            // 切走即停（lightingDemand 门控 slowLoop）。键盘灯效仍读存档。
            store.demandLighting(true)
            syncFromBackend()
            Task { await store.refreshLightingOnce(backend) }
        }
        .onDisappear {
            store.demandLighting(false)
        }
        .onChange(of: store.updatedAt) { _, _ in syncFromBackend() }
        .toastOverlay()
    }

    private var header: some View {
        PageHeader(title: "灯效",
                   sub: "键盘 RGB · ITE 8291 · USB HID 直写 / 海岸灯 · EC 0x0748-0x074B",
                   trailing: AnyView(
                    HStack(spacing: 10) {
                        badge(on: rgbAvailable, onText: "键盘在线", offText: "键盘离线")
                        badge(on: lightbarAvailable, onText: "海岸灯可用", offText: "海岸灯离线")
                        if !synced {
                            Text("读取中…")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim2)
                        }
                    }))
    }

    private func badge(on: Bool, onText: String, offText: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Theme.green : Theme.red).frame(width: 7, height: 7)
            Text(on ? onText : offText)
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }

    private var unavailableCard: some View {
        Card(title: "设备状态") {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.badge.ellipsis").foregroundStyle(Theme.amber)
                Text(BackendService.string(store.rgb, "error")
                     ?? "未检测到 ITE 8291 键盘灯设备（内屏盖屏 / 外接键盘时 HID 路径变化属正常）")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: - 键盘灯效（先调好再点「确定应用」）
    private var effectCard: some View {
        Card(title: "键盘灯效") {
            // 灯效按钮：宽列自适应 4-5 列，窗口收窄回落 3 列
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(effects, id: \.0) { eff in
                    let active = effect == eff.0
                    Button {
                        effect = eff.0
                        effectDirty = true
                    } label: {
                        Text(eff.1)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : Theme.dim)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(active ? Theme.purple : Theme.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(active ? Theme.purple : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().overlay(Theme.line)

            // 速度 + 亮度：两条滑条并排，占满整行
            HStack(spacing: 16) {
                sliderRow(title: "速度", value: speedBinding, range: 1...10, tint: Theme.cyan,
                          display: "\(Int(effectSpeed))", sub: "1 慢 · 10 快")
                sliderRow(title: "亮度", value: brightBinding, range: 0...100, tint: Theme.amber,
                          display: "\(Int(effectBright))%", sub: "0-100 百分比")
            }

            // 方向：只有波浪 / 跑马灯 / 极光在原厂里带方向字节，其余写 0
            if KeyboardCatalog.supportsDirection(currentEffect) {
                HStack(spacing: 10) {
                    Text("方向").font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.dim).frame(width: 34, alignment: .leading)
                    SegmentedPicker(options: [(1.0, "右"), (2.0, "左"), (3.0, "上"), (4.0, "下")],
                                    selection: directionBinding)
                        .frame(maxWidth: 280)
                    Spacer(minLength: 0)
                }
            }

            Divider().overlay(Theme.line)

            if isKeymap {
                keymapSection
            } else {
                paletteSection
            }

            // 下发按钮 ＋ 未应用提示（整行，右对齐副文案，不留空）
            HStack(spacing: 10) {
                Button {
                    Task { await applyEffectConfirmed() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        Text("确定应用").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.purple, in: Capsule())
                    .opacity(effectDirty ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                Text(effectDirty ? "有未应用的修改" : "灯效 / 速度 / 亮度 / 颜色都是本地草稿，点「确定应用」才下发")
                    .font(.system(size: 11)).foregroundStyle(effectDirty ? Theme.amber : Theme.dim2)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if !hideCardSubs {
                Text(isKeymap
                     ? "逐键自定义会先发 0x08（固件码 0x33）进入逐键模式，再按 6 行 × 21 列逐行写 64 字节行数据；颜色同样先过原厂补偿。"
                     : "颜色先写命名色槽位 1-\(paletteSize)（HID 0x14），再发 0x08；"
                       + "0x08 的颜色字节写的是 ColorIndex（None/Single/Circular），不是颜色个数。"
                       + "颜色会先过原厂补偿表，所以纯白在 EC 里是 255,50,170 而不是 255,255,255。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 音乐律动的状态（2.7.x 起这个灯效一直是「无效」的：见 MusicEngine.swift）
            if currentEffect == .music {
                HStack(spacing: 6) {
                    Circle()
                        .fill(music.running ? Theme.green : Theme.dim2)
                        .frame(width: 6, height: 6)
                    Text(music.running
                         ? "运行中 · 跟随系统输出（12Hz 六段频谱）"
                         : (music.lastError.map { "未启动：\($0)" }
                            ?? "点「确定应用」开始抓取系统输出（Core Audio tap，无需屏幕录制权限）"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(music.running ? Theme.dim : Theme.amber)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 统一滑条行：标题 + 滑条 + 数值 + 备注（备注放右侧，避免左侧标签列宽不齐）
    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, tint: Color,
                           display: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                Text(display)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.txt)
            }
            Slider(value: value, in: range, step: 1)
                .tint(tint)
            Text(sub).font(.system(size: 10)).foregroundStyle(Theme.dim2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 调色板（除「逐键自定义」外的灯效）
    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                GroupTitle(text: "灯效颜色", sub: "原厂 ColorBlock · \(paletteSize) 色")
                Spacer(minLength: 8)
                if paletteSize > 0 {
                    SecondaryButton(title: "恢复", icon: "arrow.counterclockwise", tint: Theme.amber) {
                        palette = KeyboardCatalog.defaultPalette.map {
                            Color(hex: UInt32(($0.0 << 16) | ($0.1 << 8) | $0.2))
                        }
                        effectDirty = true
                    }
                }
            }
            if paletteSize == 0 {
                if !hideCardSubs {
                    Text("「\(currentEffect.title)」由固件自己生成彩色，不使用自定义调色板（原厂此灯效 ColorIndex = None）。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: max(1, min(7, paletteSize))), spacing: 8) {
                    ForEach(0..<min(7, paletteSize), id: \.self) { i in
                        VStack(spacing: 5) {
                            ColorPicker("", selection: $palette[i], supportsOpacity: false)
                                .labelsHidden()
                                .onChange(of: palette[i]) { _, _ in effectDirty = true }
                            Text("槽 \(i + 1)").font(.system(size: 9.5)).foregroundStyle(Theme.dim2)
                        }
                        .padding(.vertical, 8)
                        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: - 逐键投影
    //
    // 2026-10-25：用户拿原厂截图对比后要求「每个键跟我的键盘一模一样」。
    // 原来的 6×21 方格是芯片的灯位矩阵（21 列里只有前 16 列有灯），画出来右边
    // 一大片空的、也看不出哪个格是哪颗键。现在按原厂 KeyMapUS 画真实布局：
    // 每行 16 个网格位，大键按原厂宽度占位，标签就是键帽上的字。
    private var keymapSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                GroupTitle(text: "键盘投影", sub: "US 布局 · 85 键 · 每键对应真实灯位")
                Spacer(minLength: 8)
                if let p = picked {
                    Text("\(Self.layout[p.row][p.idx].label) · " + pickedHex)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.dim2)
                } else {
                    Text("点键位即用下方颜色点亮")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                }
            }

            // 键盘本体：宽度自适应，键高固定，16 个网格位一行
            GeometryReader { geo in
                let gap: CGFloat = 3
                let unit = max(10, min(34, (geo.size.width - gap * 15) / 16))
                VStack(spacing: gap) {
                    ForEach(0..<Self.layout.count, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<Self.layout[r].count, id: \.self) { i in
                                keyCap(row: r, idx: i, unit: unit)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(height: 6 * 22 + 5 * 3)

            // 笔刷色 + 快捷填充
            HStack(spacing: 8) {
                Text("颜色").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                ColorPicker("", selection: $brush, supportsOpacity: false)
                    .labelsHidden().frame(width: 40, height: 24)
                Text(brush.toHex().uppercased())
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.dim2)
                Divider().frame(height: 16)
                // 原厂 7 色做成快捷笔刷
                ForEach(0..<7, id: \.self) { i in
                    let c = KeyboardCatalog.defaultPalette[i]
                    Button {
                        brush = Color(hex: UInt32((c.0 << 16) | (c.1 << 8) | c.2))
                        if let p = picked { paint(row: p.row, idx: p.idx) }
                    } label: {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(hex: UInt32((c.0 << 16) | (c.1 << 8) | c.2)))
                            .frame(width: 18, height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                SecondaryButton(title: "整行填充", icon: "arrow.right.to.line", tint: Theme.blue) {
                    guard let p = picked else { return }
                    for c in 0..<Self.keyCols { keymap[p.row][c] = brush }
                    effectDirty = true
                }
                .disabled(picked == nil)
                .opacity(picked == nil ? 0.5 : 1)
                SecondaryButton(title: "全部填充", icon: "square.fill", tint: Theme.cyan) {
                    keymap = Array(repeating: Array(repeating: brush, count: Self.keyCols),
                                   count: Self.keyRows)
                    effectDirty = true
                }
                SecondaryButton(title: "清空", icon: "trash", tint: Theme.amber) {
                    keymap = Array(repeating: Array(repeating: Color(hex: 0x000000), count: Self.keyCols),
                                   count: Self.keyRows)
                    effectDirty = true
                }
                Spacer(minLength: 0)
            }

            if !hideCardSubs {
                Text("点键位 → 立刻用当前颜色点亮该键；大键（Shift / Enter / 空格）会一次点亮它全部的灯。"
                     + "布局与原厂键位表一致，空格键两侧的灯位也可以单独上色。")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 一个键帽：宽度 = 占位数 × 单元宽，颜色 = 该键第一颗灯的颜色
    private func keyCap(row: Int, idx: Int, unit: CGFloat) -> some View {
        let def = Self.layout[row][idx]
        let color = keymap[def.leds[0] / Self.keyCols][def.leds[0] % Self.keyCols]
        let isSel = picked == KeyPick(row: row, idx: idx)
        let w = unit * CGFloat(def.span) + 3 * CGFloat(def.span - 1)
        return Button {
            paint(row: row, idx: idx)
        } label: {
            Text(def.label)
                .font(.system(size: def.span > 1 ? 8.5 : 9.5, weight: .medium))
                .foregroundStyle(capTextColor(color))
                .lineLimit(1).minimumScaleFactor(0.55)
                .frame(width: w, height: 22)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(isSel ? Color.white : Theme.line, lineWidth: isSel ? 1.6 : 0.6))
        }
        .buttonStyle(.plain)
        .help("\(def.label) · LED \(def.leds.map(String.init).joined(separator: ","))")
    }

    /// 键帽文字颜色：亮底用黑字、暗底用白字（键没点亮时是纯黑，标签要看得见）
    private func capTextColor(_ c: Color) -> Color {
        let hex = c.toHex()
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return .white.opacity(0.8) }
        let l = (0.299 * Double((v >> 16) & 0xFF) + 0.587 * Double((v >> 8) & 0xFF)
                 + 0.114 * Double(v & 0xFF)) / 255
        return l > 0.55 ? .black.opacity(0.75) : .white.opacity(0.8)
    }

    /// 用笔刷色涂满一个键（大键 = 涂满它的所有灯位）
    private func paint(row: Int, idx: Int) {
        for led in Self.layout[row][idx].leds where led / Self.keyCols < Self.keyRows {
            keymap[led / Self.keyCols][led % Self.keyCols] = brush
        }
        picked = KeyPick(row: row, idx: idx)
        effectDirty = true
    }

    /// 选中键当前的颜色（没有选中就是笔刷色）
    private var pickedHex: String {
        guard let p = picked else { return brush.toHex().uppercased() }
        let led = Self.layout[p.row][p.idx].leds[0]
        return keymap[led / Self.keyCols][led % Self.keyCols].toHex().uppercased()
    }

    /// 速度 / 亮度：只有用户拖动才置脏（程序回读直接赋 @State，不经过 setter）
    private var speedBinding: Binding<Double> {
        Binding(get: { effectSpeed }, set: { effectSpeed = $0; effectDirty = true })
    }

    private var brightBinding: Binding<Double> {
        Binding(get: { effectBright }, set: { effectBright = $0; effectDirty = true })
    }

    /// 方向：只有用户拖动才置脏（程序回读直接赋 @State，不走这里）
    private var directionBinding: Binding<Double> {
        Binding(get: { effectDirection }, set: { effectDirection = $0; effectDirty = true })
    }

    /// 点「确定应用」才真正下发
    private func applyEffectConfirmed() async {
        // 音乐律动走另一条路：固件码 0x22 只是编号，芯片不会分析音频，
        // 原厂也是上位机抓音频自己做 FFT（见 MusicEngine.swift 顶部的说明）。
        if currentEffect == .music {
            await applyMusic()
            return
        }
        music.stop()
        var body: [String: Any] = ["save": 1, "brightness": Int(effectBright)]
        var summary: String
        if isKeymap {
            // 逐键：6 行 × 21 列的原始 RGB；补偿在 helper 里做
            let rows: [[[Int]]] = keymap.map { row in
                row.map { c in
                    let rgb = c.toHex().toRGB()
                    return [rgb.0, rgb.1, rgb.2]
                }
            }
            body["mode"] = "keymap"
            body["rows"] = rows
            summary = "逐键投影 · \(Self.keyRows)×\(Self.keyCols) · \(Int(effectBright))%"
        } else {
            let n = min(7, paletteSize)
            let colors: [[Int]] = (0..<max(0, n)).map { i in
                let rgb = palette[i].toHex().toRGB()
                return [rgb.0, rgb.1, rgb.2]
            }
            body["mode"] = "effect"
            body["style"] = effect
            body["speed"] = Int(effectSpeed)
            body["direction"] = KeyboardCatalog.supportsDirection(currentEffect) ? Int(effectDirection) : 0
            if !colors.isEmpty { body["colors"] = colors }
            summary = "\(effectName(effect)) · \(n == 0 ? "固件彩色" : "\(n) 色") · \(Int(effectBright))%"
        }
        let r = await backend.post("/api/rgb", body)
        if r["ok"] as? Bool == true {
            effectDirty = false
            // 写完锁 4 秒：芯片回读有 5 秒延迟，锁定窗口内不让轮询把滑条刷回去
            locks.lock("effect", 4.0)
            // 2.8.10：不再回读慢快照 —— 界面上就是刚写下去的值，读回来反而是旧态
            syncFromBackend()
            ToastCenter.shared.show("已应用 · \(summary)")
        } else {
            showToast("灯效失败：\(BackendService.string(r, "error") ?? "")")
        }
    }

    private func effectName(_ key: String) -> String {
        effects.first { $0.0 == key }?.1 ?? key
    }

    /// 音乐律动：启动音频抓取，亮度先设一次，之后每帧只发 6 行颜色
    private func applyMusic() async {
        guard music.start() else {
            showToast("音乐律动启动失败：\(music.lastError ?? "未知原因")")
            return
        }
        // 亮度单独设一次；不带 remember，避免把「音乐律动」写进存档（存档里没有它的动画）
        _ = await backend.post("/api/rgb",
                               ["mode": "brightness", "level": Int(effectBright), "remember": false])
        effectDirty = false
        locks.lock("effect", 4.0)
        showToast("音乐律动已启动 · 跟随系统输出")
    }

    // MARK: - 海岸灯（先调、再点确定生效）
    //
    // 注意：这里刻意不用 .onChange 去标 lbDirty —— 回读会把硬件当前值写回
    // lbMode，onChange 分不清「用户改的」和「回读改的」，结果一进页面就显示
    // 「有未应用的修改」。改成自定义 Binding：只有用户真正操作时才置脏。
    private var lbModeBinding: Binding<String> {
        Binding(get: { lbMode }, set: { m in
            lbMode = m
            if m != "off" { lbLastMode = m }
            lbDirty = false
            // 2.8.10：模式分段**即时生效**。
            // 之前只改草稿、不写记忆，下一个轮询周期又从记忆把 lbMode 刷回
            // 「多彩轮换」—— 用户看到的就是「点固定色立马跳回去」。
            Task { await applyLightbar(m) }
        })
    }

    private var lbColorBinding: Binding<Color> {
        Binding(get: { lbColor }, set: { lbColor = $0; lbDirty = true })
    }

    /// 海岸灯总开关（2.8.8 用户要求）：关 = CTRL_OFF，开 = 回到上次的轮换/固定色
    private var lbOnBinding: Binding<Bool> {
        Binding(get: { lbMode != "off" }, set: { on in
            lbMode = on ? lbLastMode : "off"
            lbDirty = true
            // 开关是即时动作，点了就写（不等「确定生效」）
            Task { await applyLightbar(nil) }
        })
    }

    private var lightbarCard: some View {
        Card(title: "海岸灯 · LIGHTBAR_CTRL · EC 0x0748-0x074B") {
            // 2.8.12：kext 真没装才整块置灰；「EC 本次读失败」只提示，控件照旧能点
            // （写路径与读路径是分开的，读失败往往只是邮箱被采样器占着）。
            if lightbarReason == "kext" {
                KextRequiredHint(text: "海岸灯要读写 EC，需要 TongfangFan.kext")
            } else if lightbarReason == "read" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10.5))
                    Text(store.lightbar["note"] as? String ?? "EC 读取失败")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.amber)
            }
            Group {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("海岸灯").font(.system(size: 13, weight: .medium))
                        Text(lbMode == "off" ? "已关闭（CTRL_OFF）" : "已开启")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: lbOnBinding)
                        .toggleStyle(.switch)
                        .tint(Theme.purple)
                        .labelsHidden()
                }
                Divider().overlay(Theme.line)
                SegmentedPicker(options: [("cycle", "多彩轮换"), ("static", "固定色")],
                                selection: lbModeBinding)
                if lbMode == "static" {
                    HStack(spacing: 10) {
                        ColorPicker("", selection: lbColorBinding, supportsOpacity: false)
                            .labelsHidden().frame(width: 44, height: 28)
                        Text("颜色").font(.system(size: 12)).foregroundStyle(Theme.dim)
                        Spacer(minLength: 4)
                        Text(lbColor.toHex().uppercased())
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await applyLightbar(nil) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                            Text("确定生效").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Theme.purple, in: Capsule())
                        .opacity(lbDirty ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    Text(lbDirty ? "有未应用的修改" : "轮换 / 固定色都只改控制字节，不动颜色寄存器")
                        .font(.system(size: 10.5)).foregroundStyle(lbDirty ? Theme.amber : Theme.dim2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .kextGated(lightbarReason != "kext")
        }
    }

    private func applyLightbar(_ mode: String?) async {
        let m = mode ?? lbMode
        var body: [String: Any] = ["ctrl": m]
        // 只有固定色才下发颜色；轮换/关闭不碰 RGB 寄存器，用户上次挑的色会被保留
        if m == "static" {
            body["hex"] = lbColor.toHex()
        }
        // 先记软件记忆（界面立刻以记忆为准），再写 EC
        UIControlPrefs.set(UIControlPrefs.K.lightbarMode, m)
        if m == "static" { UIControlPrefs.set(UIControlPrefs.K.lightbarHex, lbColor.toHex()) }
        let r = await backend.post("/api/lightbar", body)
        if r["ok"] as? Bool == true {
            let name: String
            switch m {
            case "cycle": name = "多彩轮换"
            case "static": name = "固定色"
            default: name = "关闭海岸灯"
            }
            lbDirty = false
            if m != "off" { lbLastMode = m }
            showToast("已切换到\(name)")
        } else {
            showToast("海岸灯失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }

    // MARK: - 灯效通用（记忆 + 关闭键盘灯）
    private var generalCard: some View {
        Card(title: "灯效通用") {
            VStack(alignment: .leading, spacing: 10) {
                // 360 宽的列里塞三个带文字的按钮会挤到换行，统一改紧凑版
                compactButton("恢复上次", "arrow.clockwise", Theme.blue) {
                    Task {
                        let r = await backend.post("/api/rgb/apply", [:])
                        showToast(r["ok"] as? Bool == true ? "已恢复上次灯效" : "恢复失败")
                        // 2.8.10：恢复后按存档刷新界面即可，不回读 EC
                        syncFromBackend()
                    }
                }
                compactButton("关闭键盘灯", "power", Theme.red) {
                    Task {
                        music.stop()
                        let r = await backend.post("/api/rgb", ["mode": "off"])
                        showToast(r["ok"] as? Bool == true ? "键盘灯已关闭" : "失败")
                    }
                }
                compactButton("清除记忆", "trash", Theme.amber) {
                    Task {
                        let r = await backend.post("/api/rgb/forget", [:])
                        showToast(r["ok"] as? Bool == true ? "已清除（开机不再恢复）" : "失败")
                    }
                }
                if !hideCardSubs {
                    Text("开机恢复由后台 helper 完成（不再单独注册登录项）；EC 断电会丢灯效，所以每次变更都会自动记忆。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 右列专用的整行按钮（比 SecondaryButton 矮，一行放一个，不会换行）
    private func compactButton(_ title: String, _ icon: String, _ tint: Color,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11.5))
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.txt)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint).frame(width: 2.5)
                    .padding(.vertical, 6)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 设备信息（把版面填满的东西必须是真的有用）
    private var deviceCard: some View {
        let info = BackendService.dict(store.rgb, "info")
        let fw = BackendService.dict(store.rgb, "firmware")
        let state = BackendService.dict(store.rgb, "state")
        let fwBytes = (fw?["version_bytes"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? "—"
        let maxV = BackendService.int(state, "brightness_max") ?? 0
        let items: [(String, String)] = [
            ("产品", BackendService.string(info, "product") ?? "—"),
            ("厂商 / 产品 ID", "\(BackendService.string(info, "vendor_id") ?? "—") / \(BackendService.string(info, "product_id") ?? "—")"),
            ("Usage Page", BackendService.string(info, "usage_page") ?? "—"),
            ("Feature 报文", "\(info?["feature_report_size"].map { "\($0)" } ?? "—") 字节"),
            ("LED 供应商", BackendService.string(info, "led_vendor") ?? "—"),
            ("固件版本", fwBytes),
            ("亮度量程", maxV > 0 ? "0…\(maxV)（界面按 0…100% 换算）" : "—"),
            ("当前灯效码", String(format: "0x%02X", BackendService.int(state, "program") ?? 0)),
            ("存档", BackendService.string(store.rgb, "profile_path")?.split(separator: "/").last.map(String.init) ?? "—"),
        ]
        return Card(title: "键盘设备 · ITE 8291 · 048D") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5),
                      alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, kv in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kv.0).font(.system(size: 10)).foregroundStyle(Theme.dim2)
                        Text(kv.1)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.txt)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !hideCardSubs {
                Text("★ 亮度按百分比显示：芯片真实量程因固件而异（QC71 fw19.x 是 0…50，X15 fw22.x 是 0…100），"
                     + "写入时按比例换算，所以 100% 在两种键盘上都是最亮。")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 回读（只读，绝不触发写硬件）
    private func syncFromBackend() {
        guard rgbAvailable else { return }

        let profile = BackendService.dict(store.rgb, "profile")
        let state = BackendService.dict(store.rgb, "state")
        let profMode = BackendService.string(profile, "mode") ?? ""

        // 刚写完的 4 秒内一律不回读灯效（芯片 feature 缓冲刷新有延迟，
        // 这时候读到的还是上一笔的调色板报文，会把滑条刷成 0%）。
        // 只跳过「灯效草稿」这一段，海岸灯照常回读。
        // 音乐律动运行中也不回读：它不下发灯效、只刷行数据，回读会把选择刷回去。
        if !effectDirty, !locks.locked("effect"), !music.running {
            if profMode == "keymap" {
                effect = KeyboardCatalog.key(for: .userMode)
                if let rows = profile?["rows"] {
                    keymap = Self.decodeKeymap(rows)
                }
            } else if profMode == "effect" {
                if let s = BackendService.string(profile, "style") { effect = s }
            }
            if let v = BackendService.int(profile, "speed") { effectSpeed = Double(v) }

            // 亮度：**优先存档值**（那就是我们真正写进芯片的值）。
            // 只有芯片明确回了一份 0x08 报文（brightness_valid）才采信 HID 回读。
            let valid = BackendService.bool(state, "brightness_valid") ?? false
            if valid, let pct = BackendService.int(state, "brightness_pct") {
                effectBright = Double(pct)
            } else if let v = BackendService.int(profile, "brightness") {
                effectBright = Double(v <= 4 ? v * 25 : v)   // 老存档 1…4 等级 → 25/50/75/100
            }

            // 0 = 无方向（老存档），归一到原厂默认「右」
            if let v = BackendService.int(profile, "direction"), (1...4).contains(v) {
                effectDirection = Double(v)
            }
            if let cs = BackendService.array(profile, "colors") as? [[Any]], !cs.isEmpty {
                var newPal: [Color] = palette
                for (i, c) in cs.prefix(7).enumerated() {
                    let r = c.count > 0 ? (c[0] as? Int ?? 0) : 0
                    let g = c.count > 1 ? (c[1] as? Int ?? 0) : 0
                    let b = c.count > 2 ? (c[2] as? Int ?? 0) : 0
                    newPal[i] = Color(hex: UInt32((r << 16) | (g << 8) | b))
                }
                palette = newPal
            }
        }

        // 海岸灯：模式与颜色都以软件记忆为准（EC 只在首次播种时读过一次）
        // 海岸灯：模式与颜色都以软件记忆为准（EC 只在首次播种时读过一次）。
        // 有未应用的改色草稿（lbDirty）时不要回写，否则取色器会被记忆值拽回去。
        UIControlPrefs.seedLightbarIfNeeded(store.lightbar)
        if !lbDirty {
            if let m = UIControlPrefs.string(UIControlPrefs.K.lightbarMode) {
                lbMode = m
                if m != "off" { lbLastMode = m }
            }
            if let hex = UIControlPrefs.string(UIControlPrefs.K.lightbarHex), hex.count == 6 {
                lbColor = Color(hex: UInt32(hex, radix: 16) ?? 0)
            }
        }
    }

    /// 存档里的 rows → 界面用的 6×21 Color 矩阵
    private static func decodeKeymap(_ raw: Any) -> [[Color]] {
        let normalized = RGBProfile.normalizeKeymap(raw)
        return normalized.map { row in
            row.map { c in Color(hex: UInt32((c[0] << 16) | (c[1] << 8) | c[2])) }
        }
    }

    private func showToast(_ s: String) {
        ToastCenter.shared.show(s)
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
