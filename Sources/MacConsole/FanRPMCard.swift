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
                    trailing: { AnyView(Chip(text: fanModeText, color: Theme.blue)) }) {
            if !avail {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.dim2)
                    Text(BackendService.string(store.fan, "hint") ?? "kext 未加载")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                }
            } else {
                // 2.7.2：环缩到 158pt 固定直径。上一版铺满整张卡（环比卡片还抢眼）
                // 被用户否掉——现在环只当背景仪表，尺度回落到「跟正文同量级」。
                HStack(spacing: 34) {
                    fanBig("CPU", rpm: BackendService.int(store.live, "rpm_cpu") ?? 0,
                           temp: BackendService.int(store.live, "temp_cpu") ?? 0)
                    fanBig("dGPU", rpm: BackendService.int(store.live, "rpm_gpu") ?? 0,
                           temp: BackendService.int(store.live, "temp_gpu") ?? 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
        }
    }

    /// 风扇环（2.7.2）：环只是「占空比」的可视化背景，主角是转速。
    ///
    /// 版面自上而下：风扇名（CPU / 独显）→ 大号 RPM 数字 → RPM 单位 →
    /// 底部一行小字温度。上一版把 % 做成 60pt 主数字、环铺满卡片，
    /// 视线全被环和百分比抓走，跟「风扇看的是转速」这件事相反。
    /// 风扇环（2.8.15）：2.7.2 起环是「占空比」背景，现在 PWM 不再采集，
    /// 环退回纯装饰底环，主角只有转速 + 温度。
    private func fanBig(_ name: String, rpm: Int, temp: Int) -> some View {
        let side: CGFloat = 158
        let lw: CGFloat = 9.5
        return ZStack {
            Circle().stroke(Theme.barBg, lineWidth: lw)
            VStack(spacing: 0) {
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.dim2)
                    .tracking(0.4)
                // 主角：转速。千分位由 Text 的本地化插值自动补（3,358）
                Text("\(rpm)")
                    .font(.system(size: 35, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 1)
                Text("RPM")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.dim2)
                    .tracking(1.1)
                HStack(spacing: 5) {
                    Text("\(temp)℃")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
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
