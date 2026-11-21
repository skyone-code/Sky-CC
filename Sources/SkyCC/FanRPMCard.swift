import SwiftUI

/// 风扇卡片：CPU / dGPU 两个转速环 + 当前散热模式胶囊。
///
/// 3.0.4.5（2026-11-14 用户要求）：从「控制」页挪到「概览」页 —— 与存储、电池、
/// 设备身份卡同页，作为开机后的第一眼状态。
/// （2026-11-07 它曾从「性能」页挪到「控制」页。）
///
/// 因为要跨页面用，从 `MonitorView` 的 private var 抽成了独立 struct。
/// 注意别和 `ControlView` 里那个同名概念混淆：那里的 `fanManualCard` 是
/// **手动档位 / 温控曲线**的调节面板（写 EC 0x0741 / 0x0751），这里只是读数。
struct FanRPMCard: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        let avail = BackendService.bool(store.fan, "available") ?? false
        return Card(title: "风扇 · TongfangFan",
                    trailing: { Chip(text: fanModeText, color: Theme.blue) }) {
            if !avail {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.dim2)
                    Text(BackendService.string(store.fan, "hint") ?? "kext 未加载")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                }
            } else {
                // 2026-11-18（最小宽排查）：双环 158×2 + 34 = 350pt 固定宽，是全 app
                // 最宽的不可压缩内容 —— 概览页在「窗口最小宽 + 侧边栏」时被挤爆的
                // 元凶。改为按卡片实际宽度缩放环径，随窗口变窄跟着缩。
                // 2026-11-18（用户定案）：电池环才是尺寸基准，风扇环跟它对齐 ——
                // 电池环实际渲染约 140（右列 7 行文字高度钉住），上限从 190 降回 140。
                GeometryReader { geo in
                    let side = max(120, min(140, (geo.size.width - 34) / 2))
                    HStack(spacing: 34) {
                        fanBig("CPU", rpm: BackendService.int(store.live, "rpm_cpu") ?? 0,
                               temp: BackendService.int(store.live, "temp_cpu") ?? 0,
                               side: side)
                        fanBig("dGPU", rpm: BackendService.int(store.live, "rpm_gpu") ?? 0,
                               temp: BackendService.int(store.live, "temp_gpu") ?? 0,
                               side: side)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 底环色（2026-11-18 用户定案）：浅色用实灰 —— 玻璃态下 barBg 0.35 的
    //  浅色底环又淡到看不见；深色不变（仍用 barBg 的深色值+透明度）。
    private static let fanRingBase = Color(nsColor: NSColor(name: nil, dynamicProvider: { ap in
        (ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            ? NSColor(hex: 0x3a3b40).withAlphaComponent(0.45)
            : NSColor(hex: 0xaab1bb)
    }))

    /// 风扇环（2.7.2 → 2026-11-18 重做）：底环 + 进度环，主角仍是转速。
    ///
    /// 版面自上而下：风扇名（CPU / 独显）→ 大号 RPM 数字 → RPM 单位 →
    /// 底部一行小字温度。
    /// 进度环（2026-11-18 用户定案）：以 **6000 RPM 为满环**，起点 12 点钟
    /// 方向（顶）**逆时针**扫（12→9→6）；环色按绝对转速分档（<2500 绿 /
    /// 2500–3500 蓝 / 3500–4500 橙 / 4500+ 红），rpm 变化时 0.5s 缓动跟进。
    private func fanBig(_ name: String, rpm: Int, temp: Int, side: CGFloat = 140) -> some View {
        // 线宽与电池环同一公式：9 × side/110（140 满径时 ≈11.5，缩窗时同比变细）。
        let lw: CGFloat = 9 * side / 110
        // 环内文字随环径等比缩放（140 基准：满径时主数字回到 35，与旧版观感一致）。
        let ts = side / 140
        let progress = min(1.0, max(0.0, Double(rpm) / 6000.0))
        // 环色随转速分档（2026-11-18 用户定案，准数）：绿 → 蓝 → 橙 → 红，
        // 按绝对转速切：<2500 绿、2500–3500 蓝、3500–4500 橙、4500+ 红。
        let accent: Color = {
            switch Double(rpm) {
            case ..<2500: return Theme.green
            case ..<3500: return Theme.blue
            case ..<4500: return Theme.amber
            default: return Theme.red
            }
        }()
        return ZStack {
            Circle().stroke(Self.fanRingBase, lineWidth: lw)
            if progress > 0.004 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: -1)   // 镜像翻转：起点保持 12 点钟（顶），扫向改逆时针（12→9→6）
                    .animation(.easeInOut(duration: 0.5), value: rpm)
            }
            VStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 10.5 * ts, weight: .semibold))
                    .foregroundStyle(Theme.dim2)
                    .tracking(0.4)
                // 主角：转速。千分位由 Text 的本地化插值自动补（3,358）
                Text("\(rpm)")
                    .font(.system(size: 35 * ts, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 1)
                Text("RPM")
                    .font(.system(size: 8.5 * ts, weight: .semibold))
                    .foregroundStyle(Theme.dim2)
                    .tracking(1.1)
                HStack(spacing: 5) {
                    Text("\(temp)℃")
                        .font(.system(size: 10.5 * ts, weight: .semibold).monospacedDigit())
                        .foregroundStyle(store.tempColor(Double(temp)))
                }
                .padding(.top, 3)
            }
            .frame(width: side * 0.72)
        }
        .frame(width: side, height: side)
    }

    private var fanModeText: String {
        // 2.7.10：两组分开显示 —— 功耗档（0x7AB 高半字节）+ 散热档（低半字节）。
        // 以前只看 modeindex 三档，把散热档信息整个丢了。
        let power: String? = {
            switch BackendService.int(store.fan, "modeindex") {
            case 0x11: return "高性能"
            case 0x22: return "平衡"
            case 0x33: return "节能"
            default: return nil
            }
        }()
        let thermal: String? = {
            switch BackendService.int(store.fan, "thermal_level") {
            case 1: return "散热性能"
            case 2: return "散热标准"
            case 3: return "散热安静"
            default: return nil
            }
        }()
        if let p = power { return thermal.map { "\(p) · \($0)" } ?? p }
        switch BackendService.string(store.fan, "actual") ?? "" {
        case "normal": return thermal ?? "自动"
        case "boost": return "基准模式"
        case "custom": return "手动"
        case "curve": return "曲线"
        default: return thermal ?? "—"
        }
    }
}
