import SwiftUI

/// 控制页：散热模式 / 手动档位 / 性能模式 / 充电阈值 / 海岸灯 / 屏幕亮度 / 音量 / 防休眠
struct ControlView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    // 散热模式本地选择（与 EC 回读同步后更新）
    @State private var fanMode: String = "normal"     // normal / boost / custom
    @State private var fanLevel: Double = 0
    @State private var perfIndex: Int = 0x11          // 0x11 / 0x22 / 0x33
    @State private var chargeThreshold: Double = 80
    @State private var brightness: Double = 50
    @State private var brightnessDebounce: Task<Void, Never>? = nil
    @State private var volume: Double = 50
    @State private var muted = false
    @State private var caffeinateOn = false

    // 键盘 / 触控板 / 风扇行为（EC 0x074E / 0x07A4 / 0x07A6 / 0x07A3，qc71 交叉验证）
    @State private var fnLock = false
    @State private var fnLockSwitch = false
    @State private var touchpadOn = true
    @State private var overboostDynTemp = true
    @State private var fanReducedDuty = false
    @State private var fanAlwaysOn = false

    // 海岸灯
    @State private var lbMode: String = "cycle"       // cycle / static / off
    @State private var lbColor: Color = .blue

    @State private var toast: String?

    // 交互锁：用户刚操作过的项，锁定期内不被 1s 轮询回读覆盖
    // （否则点完「基准·最大」下一秒就被刷回「自动」，观感就是"跳回去"）
    @StateObject private var locks = EditLocks()
    @State private var lbColorDebounce: Task<Void, Never>?

    private var kextOK: Bool { backend.kextLoaded }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !kextOK { KextBanner() }
                header
                // 2.7.1 重排：原来是 8 张卡竖着堆三屏，找东西要滚。
                // 2.7.5：散热模式与性能模式合并成一张（两者都是 EC 散热策略，本来就是一路设置），
                //        海岸灯 / 休眠抑制上移补到原性能模式的位置，开关矩阵垫底。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        thermalCard.gridEqual()
                        VStack(spacing: 14) {
                            chargeCard
                            brightnessCard
                            volumeCard
                        }
                        .gridEqual()
                    }
                    GridRow {
                        lightbarCard.gridEqual()
                        sleepCard.gridEqual()
                    }
                    GridRow {
                        miscCard.gridEqual().gridCellColumns(2)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .onAppear {
            syncFromBackend()
            syncVolume()
            syncCaffeinate()
            Task { await loadBrightness() }
        }
        .onChange(of: store.updatedAt) { _, _ in
            syncFromBackend()
            syncVolume()
            syncCaffeinate()
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.75), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast != nil)
    }

    private var header: some View {
        PageHeader(title: "控制", sub: "散热 / 性能模式 / 充电阈值 / 亮度 / 音量 · 所有开关以硬件真实回读为准")
    }

    // MARK: - 从后端回读同步本地状态（用户红线：按钮高亮必须反映真实状态；
    //        但用户刚操作过的项在锁定期内不被回读覆盖，否则"点完就跳回去"）
    private func syncFromBackend() {
        guard !store.fan.isEmpty else { return }
        let actual = BackendService.string(store.fan, "actual") ?? BackendService.string(store.fan, "mode") ?? "normal"
        if !locks.locked("fanMode") {
            // 优先用保存的模式（曲线模式下 EC 实际态是 custom，必须以保存态判定分段高亮）
            let saved = BackendService.string(store.fan, "mode") ?? actual
            let valid = ["normal", "boost", "custom", "curve"]
            fanMode = valid.contains(saved) ? saved : "normal"
        }
        if !locks.locked("fanLevel") {
            fanLevel = Double(BackendService.int(store.fan, "actual_level") ?? 0)
        }
        if !locks.locked("perf"),
           let mi = BackendService.int(store.fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi) {
            perfIndex = mi
        }
        if !locks.locked("charge"), let ch = BackendService.int(store.fan, "charge") {
            chargeThreshold = Double(ch)
        }
        // 键盘/触控板/风扇行为：以 EC 回读为准（锁定期内不被轮询覆盖）
        if let misc = store.fan["misc"] as? [String: Any] {
            if !locks.locked("fnLock"), let v = BackendService.bool(misc, "fn_lock") { fnLock = v }
            if !locks.locked("fnLockSwitch"), let v = BackendService.bool(misc, "fn_lock_switch") { fnLockSwitch = v }
            if !locks.locked("touchpad"), let v = BackendService.bool(misc, "touchpad_off") { touchpadOn = !v }
            if !locks.locked("overboost"), let v = BackendService.bool(misc, "overboost_dyn_temp_off") { overboostDynTemp = !v }
            if !locks.locked("fanReducedDuty"), let v = BackendService.bool(misc, "fan_reduced_duty") { fanReducedDuty = v }
            if !locks.locked("fanAlwaysOn"), let v = BackendService.bool(misc, "fan_always_on") { fanAlwaysOn = v }
        }
        if !locks.locked("lb"), store.lightbar["available"] as? Bool == true {
            lbMode = BackendService.string(store.lightbar, "mode") ?? "cycle"
            if let hex = BackendService.string(store.lightbar, "hex"), hex.count == 6 {
                lbColor = Color(hex: UInt32(hex, radix: 16) ?? 0)
            }
        }
    }

    private func syncVolume() {
        guard !store.volume.isEmpty else { return }
        if !locks.locked("volume"), let v = BackendService.int(store.volume, "volume") {
            volume = Double(v)
        }
        if !locks.locked("muted") {
            muted = BackendService.bool(store.volume, "muted") ?? false
        }
    }

    /// 屏幕亮度初值：读系统亮度（PWM 模式下原生链路即真相源），而不是写死 50%
    private func loadBrightness() async {
        let r = await backend.post("/api/control", ["action": "brightness_get"])
        if let p = BackendService.double(r, "percent") {
            brightness = min(max(p, 0), 100)
            locks.lock("brightness")
        }
    }

    private func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2200_000_000)
            if toast == s { toast = nil }
        }
    }

    // MARK: - 散热模式（点击即切换，无「应用」按钮）
    // MARK: - 散热与性能模式（2.7.5 合并）
    //
    // EC 0x0751（FAN_CTRL 档位）与 0x07AB（FAN_MODE_INDEX 性能模式）本来就是
    // 同一套散热策略的两个旋钮——分开两张卡时，下面那张的三行说明还被用户嫌长。
    // 现在一张卡从上到下：散热模式段选 →（手动档位 / 曲线）→ 当前实际态 →
    // 分隔线 → 性能模式三钮，不再跟说明文字。
    private var thermalCard: some View {
        Card(title: "散热与性能模式 · EC 0x0751 / 0x07AB") {
            if !kextOK {
                Text("需要 TongfangFan.kext").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            } else {
                SegmentedPicker(
                    options: [("normal", "自动"), ("boost", "基准 · 最大"), ("custom", "手动"), ("curve", "曲线")],
                    selection: $fanMode)
                    .onChange(of: fanMode) { _, m in
                        locks.lock("fanMode")
                        Task { await applyFanMode(m) }
                    }
                if fanMode == "custom" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("手动档位").font(.system(size: 12)).foregroundStyle(Theme.dim)
                            Spacer()
                            Text("L\(Int(fanLevel)) · \(Int(24 + fanLevel * 4.14))% 占空比")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                        }
                        Slider(value: $fanLevel, in: 0...7, step: 1)
                            .tint(Theme.blue)
                            .onChange(of: fanLevel) { _, v in
                                locks.lock("fanLevel")
                                Task { await applyLevel(Int(v)) }
                            }
                        Text("L0-L7 对应 24%→53% 占空比（FAN_CTRL = 0x80+档位，需先经 CTRL_1 手动门 EC 0x0741 bit0 开启手动权）；重启后按保存的状态自动恢复")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    }
                    .padding(.top, 4)
                } else if fanMode == "curve" {
                    FanCurveView()
                        .padding(.top, 4)
                }
                Text("当前：\(modeLabel(BackendService.string(store.fan, "actual") ?? "—"))")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim2)
                    .padding(.top, 4)

                Divider().overlay(Theme.line).padding(.top, 6)

                GroupTitle(text: "性能模式", sub: "FAN_MODE_INDEX 0x11 / 0x22 / 0x33")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    // 平衡的图标不能用 scale.medium——该符号名在当前系统
                    // 不被识别，Image(systemName:) 静默渲染为空白，导致这个
                    // 按钮少一行内容、与另两个大小不一（2026-10-17 用户截图发现）。
                    // scale.3d 是同语义且各版本都存在的天秤符号。
                    perfButton("专业", "0x11", "cpu", Theme.red)
                    perfButton("平衡", "0x22", "scale.3d", Theme.blue)
                    perfButton("省电", "0x33", "leaf", Theme.green)
                }
            }
        }
    }

    private func modeLabel(_ m: String) -> String {
        switch m {
        case "normal": return "自动"
        case "boost": return "基准·最大"
        case "custom": return "手动 L\(Int(fanLevel))"
        default: return m
        }
    }

    private func applyFanMode(_ mode: String) async {
        var body: [String: Any] = [:]
        switch mode {
        case "normal": body["mode"] = "normal"
        case "boost": body["mode"] = "boost"
        case "curve":
            body["mode"] = "curve"
            // 曲线配置以磁盘为唯一真相（helper 和应用两侧都是读它、写它），
            // 不再从本进程的 FanCurveController 取 —— 那个控制器已搬进后台 helper。
            let cfg = FanCurveStore.load() ?? .default
            body["source"] = cfg.source
            body["failsafe"] = cfg.failsafeTemp
            body["points"] = cfg.points.map { ["temp": $0.temp, "level": $0.level] }
        default: body["mode"] = "custom"; body["level"] = Int(fanLevel)
        }
        let r = await backend.post("/api/fan", body)
        if r["ok"] as? Bool != true {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
        }
        // 广播给菜单栏：立即刷新散热模式显示（不等 1s 轮询）
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func applyLevel(_ lv: Int) async {
        _ = await backend.post("/api/fan", ["mode": "custom", "level": lv])
    }

    // MARK: - 性能模式三钮（2.7.5 起并入 thermalCard）
    private func perfButton(_ title: String, _ code: String, _ icon: String, _ tint: Color) -> some View {
        let active = perfIndex == Int(code.dropFirst(2), radix: 16)
        return Button {
            let v = Int(code.dropFirst(2), radix: 16) ?? 0x11
            locks.lock("perf")
            perfIndex = v
            Task { await applyPerf(v) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(code).font(.system(size: 9.5).monospacedDigit()).opacity(0.7)
            }
            .foregroundStyle(active ? .white : Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(active ? tint : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? tint : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func applyPerf(_ code: Int) async {
        let r = await backend.post("/api/fan", ["modeindex": code])
        if r["ok"] as? Bool == true {
            var msg = "已切换到\(["专业", "平衡", "省电"][[0x11, 0x22, 0x33].firstIndex(of: code) ?? 0])"
            if r["curve_stopped"] as? Bool == true { msg += "（已退出曲线模式）" }
            showToast(msg)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - 键盘与风扇行为（EC 0x074E / 0x07A4 / 0x07A6 / 0x07A3）
    private var miscCard: some View {
        Card(title: "键盘与风扇行为") {
            if !kextOK {
                Text("需要 TongfangFan.kext").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    MiscToggleRow(title: "Fn 锁", sub: "BIOS_CTRL_1 bit4（EC 0x074E）：开启后 F1-F12 直接触发功能键，无需按住 Fn",
                                  on: $fnLock) {
                        locks.lock("fnLock")
                        Task { await applyMisc("fn_lock", fnLock) }
                    }
                    MiscToggleRow(title: "Fn+Esc 快捷键", sub: "AP_BIOS_BYTE bit3（EC 0x07A4）：允许用 Fn+Esc 组合键切换 Fn 锁",
                                  on: $fnLockSwitch) {
                        locks.lock("fnLockSwitch")
                        Task { await applyMisc("fn_lock_switch", fnLockSwitch) }
                    }
                    MiscToggleRow(title: "触控板", sub: "CTRL_4 bit6（EC 0x07A6）：关闭 = 禁用触控板",
                                  on: $touchpadOn) {
                        locks.lock("touchpad")
                        Task { await applyMisc("touchpad", touchpadOn) }
                    }
                    MiscToggleRow(title: "超频动态温控", sub: "CTRL_4 bit1（EC 0x07A6）：关闭后超频不受动态温度限制",
                                  on: $overboostDynTemp) {
                        locks.lock("overboost")
                        Task { await applyMisc("overboost_dyn_temp", overboostDynTemp) }
                    }
                    Divider()
                    MiscToggleRow(title: "风扇降低占空比", sub: "BIOS_CTRL_3 bit5（EC 0x07A3）：降低占空比换取更安静",
                                  on: $fanReducedDuty) {
                        locks.lock("fanReducedDuty")
                        Task { await applyMisc("fan_reduced_duty", fanReducedDuty) }
                    }
                    MiscToggleRow(title: "风扇常转", sub: "BIOS_CTRL_3 bit6（EC 0x07A3）：低负载下风扇也不停转",
                                  on: $fanAlwaysOn) {
                        locks.lock("fanAlwaysOn")
                        Task { await applyMisc("fan_always_on", fanAlwaysOn) }
                    }
                }
                Text("开关即时生效；读-改-写不影响同寄存器其他位。与 Windows 控制台同路径（qc71 开源驱动交叉验证）。重启后回硬件默认。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .padding(.top, 2)
            }
        }
    }

    private func applyMisc(_ key: String, _ value: Bool) async {
        let r = await backend.post("/api/fan", [key: value])
        if r["ok"] as? Bool != true {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
        }
        // 广播给菜单栏：立即刷新（不等 1s 轮询）
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    // MARK: - 充电阈值
    private var chargeCard: some View {
        Card(title: "电池充电阈值 · BATT_CHARGE_CTRL · EC 0x07B9") {
            if !kextOK {
                Text("需要 TongfangFan.kext").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            } else {
                HStack {
                    Text("充至").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                    Text("\(Int(chargeThreshold))%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("停止充电").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                    Spacer()
                    if let reached = BackendService.bool(store.fan, "charge_reached") {
                        Text(reached ? "已到达" : "充电中")
                            .font(.system(size: 11.5))
                            .foregroundStyle(reached ? Theme.amber : Theme.green)
                    }
                }
                Slider(value: $chargeThreshold, in: 0...100, step: 5) { editing in
                    if !editing {
                        locks.lock("charge")
                        Task { await applyCharge() }
                    }
                }
                .tint(Theme.green)
                HStack(spacing: 8) {
                    ForEach([60, 70, 80, 90, 100], id: \.self) { v in
                        Button("\(v)%") {
                            locks.lock("charge")
                            chargeThreshold = Double(v)
                            Task { await applyCharge() }
                        }
                        .font(.system(size: 11.5, weight: Int(chargeThreshold) == v ? .semibold : .regular))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Text("BATT_CHARGE_CTRL bit0-6 = 截止百分比（0 = 100% 不限制），bit7 = 已到达自动停充")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
            }
        }
    }

    private func applyCharge() async {
        let r = await backend.post("/api/fan", ["charge": Int(chargeThreshold)])
        if r["ok"] as? Bool != true {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }

    // MARK: - 海岸灯（点击即切换）
    private var lightbarCard: some View {
        Card(title: "海岸灯 · LIGHTBAR_CTRL · EC 0x0748-0x074B") {
            if !kextOK || !(store.lightbar["available"] as? Bool ?? false) {
                Text("需要 TongfangFan.kext").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            } else {
                SegmentedPicker(options: [("cycle", "多彩轮换"), ("static", "固定色"), ("off", "关闭")],
                                selection: $lbMode)
                    .onChange(of: lbMode) { _, m in
                        locks.lock("lb")
                        Task { await applyLightbar(m) }
                    }
                if lbMode == "static" {
                    HStack {
                        ColorPicker("颜色", selection: $lbColor, supportsOpacity: false)
                            .onChange(of: lbColor) { _, _ in
                                // 拖动取色会连续触发，防抖 200ms 只发最后一次
                                lbColorDebounce?.cancel()
                                lbColorDebounce = Task {
                                    try? await Task.sleep(nanoseconds: 200_000_000)
                                    locks.lock("lb")
                                    await applyLightbar(nil)
                                }
                            }
                        Spacer()
                        Text(BackendService.string(store.lightbar, "hex")?.uppercased() ?? "")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.dim)
                    }
                }
                Text("LIGHTBAR_CTRL bit2 = 关灯 / bit7 = 轮换动画，R/G/B = EC 0x0749-0x074B；多彩轮换 = EC 自动循环，固定色 = 常亮指定颜色（前端三值均已肉眼验证）")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
            }
        }
    }

    private func applyLightbar(_ mode: String?) async {
        let m = mode ?? lbMode
        var body: [String: Any] = ["ctrl": m]
        if m == "static" {
            body["hex"] = lbColor.toHex()
        } else {
            body["hex"] = "000000"
        }
        let r = await backend.post("/api/lightbar", body)
        if r["ok"] as? Bool != true {
            showToast("海岸灯失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }

    // MARK: - 屏幕亮度（初值 = 硬件真实值；拖动即调）
    private var brightnessCard: some View {
        Card(title: "屏幕亮度 · 原生链路") {
            HStack {
                Image(systemName: "sun.min")
                Text("亮度").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                Spacer()
                Text("\(Int(brightness))%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            Slider(value: $brightness, in: 0...100, step: 1) { editing in
                if editing {
                    // 拖动中实时跟随（50ms 防抖），不再等松手（v2.3.3 用户要求）
                    locks.lock("brightness")
                    scheduleBrightnessApply()
                } else {
                    locks.lock("brightness")
                    brightnessDebounce?.cancel()
                    Task { await applyBrightness() }
                }
            }
            .tint(Theme.amber)
            HStack(spacing: 8) {
                Button("10%") { setBrightness(10) }
                Button("30%") { setBrightness(30) }
                Button("50%") { setBrightness(50) }
                Button("70%") { setBrightness(70) }
                Button("100%") { setBrightness(100) }
            }
            .controlSize(.small)
            Text("写入系统亮度，macOS 原生链路驱动面板（PWM 模式，自带原生渐变）；auxbright 守护保持模式，睡眠唤醒自动恢复。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
        }
    }

    private func setBrightness(_ v: Int) {
        locks.lock("brightness")
        brightness = Double(v)
        Task { await applyBrightness() }
    }

    private func applyBrightness(broadcast: Bool = true) async {
        let r = await backend.post("/api/control", ["action": "brightness", "value": Int(brightness)])
        if r["ok"] as? Bool != true {
            showToast("亮度失败：\(BackendService.string(r, "error") ?? "未知")")
        }
        // 广播给菜单栏：刷新其亮度显示（MenuBarExtra content 不会自动跟随）。
        // 拖动中的连续下发不广播，避免 50ms 一次的全量刷新风暴
        if broadcast {
            NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
        }
    }

    /// 拖动中实时下发（50ms 防抖合并，避免每像素打一次后端）
    private func scheduleBrightnessApply() {
        brightnessDebounce?.cancel()
        brightnessDebounce = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await applyBrightness(broadcast: false)
        }
    }

    // MARK: - 音量
    private var volumeCard: some View {
        Card(title: "输出音量") {
            HStack {
                Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                Text("音量").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                Spacer()
                Text("\(Int(volume))%").font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            Slider(value: $volume, in: 0...100, step: 1) { editing in
                if !editing {
                    locks.lock("volume")
                    Task { await applyVolume() }
                }
            }
            .tint(Theme.purple)
            HStack {
                SecondaryButton(title: muted ? "取消静音" : "静音",
                                icon: muted ? "speaker.wave.2" : "speaker.slash",
                                isActive: muted) {
                    locks.lock("muted")
                    let target = !muted
                    muted = target
                    Task {
                        let r = await backend.post("/api/control", ["action": target ? "mute" : "unmute"])
                        if r["ok"] as? Bool != true {
                            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func applyVolume() async {
        _ = await backend.post("/api/control", ["action": "volume", "value": Int(volume)])
    }

    // MARK: - 防休眠
    private var sleepCard: some View {
        Card(title: "电源休眠抑制 · caffeinate") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("保持唤醒").font(.system(size: 13, weight: .medium))
                    Text("阻止显示器与系统休眠，长实验用").font(.system(size: 11)).foregroundStyle(Theme.dim2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { caffeinateOn },
                    set: { v in
                        locks.lock("caffeinate")
                        caffeinateOn = v
                        Task { await applyCaffeinate(v) }
                    }))
                .toggleStyle(.switch)
                .tint(Theme.blue)
                .labelsHidden()
            }
        }
    }

    /// caffeinate 真实运行状态（按钮高亮必须反映真实状态，不是上次点了什么）
    private func syncCaffeinate() {
        if locks.locked("caffeinate") { return }
        Task {
            let r = await backend.post("/api/control", ["action": "caffeinate"])
            if let on = r["on"] as? Bool { caffeinateOn = on }
        }
    }

    private func applyCaffeinate(_ on: Bool) async {
        let r = await backend.post("/api/control", ["action": "caffeinate", "on": on])
        if r["ok"] as? Bool != true {
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.dim2)
            }
            Spacer()
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
