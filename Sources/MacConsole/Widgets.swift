import SwiftUI

// MARK: - 2.7.0 新界面的通用组件
//
// 设计取向：卡片更轻（去重阴影、圆角 14）、数字更大更等宽、状态用胶囊、
// 每张指标卡自带 90 秒迷你曲线 —— 视觉密度接近 Stats，但信息量按本机
// 实际能采到的字段铺满（不再只有几个指标）。

/// 胶囊标签
struct Chip: View {
    var text: String
    var color: Color = Theme.blue
    var filled = false
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.14))
            )
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.35), lineWidth: 0.8))
    }
}

/// 页头右侧的「实时状态」胶囊：连接点 + 组包耗时 + 最后更新时间
///
/// 组包耗时是这一版特意露出来的：1 秒轮询下它稳定在 40–60ms，
/// 一旦哪天涨到几百毫秒，一眼就能看出是后端退化了而不是界面卡。
struct LiveBadge: View {
    var connected: Bool
    var updatedAt: Date?
    var ms: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Theme.green : Theme.red)
                .frame(width: 7, height: 7)
            Text(connected ? "实时" : "未连接")
                .font(.system(size: 11.5))
                .foregroundStyle(connected ? Theme.dim : Theme.red)
            if ms > 0 {
                Text("\(ms) ms")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.dim2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.barBg, in: Capsule())
            }
            if let updatedAt {
                Text(updatedAt, style: .time)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.dim2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// 迷你折线（90 秒历史）
struct Sparkline: View {
    var points: [Double]
    var color: Color
    var maxValue: Double? = nil
    var minValue: Double? = nil
    var fill = true

    var body: some View {
        GeometryReader { geo in
            let vals = points.count > 1 ? points : [0, 0]
            let hiRaw = maxValue ?? (vals.max() ?? 1)
            let loRaw = minValue ?? (vals.min() ?? 0)
            let hi = max(hiRaw, loRaw + 0.0001)
            let lo = loRaw
            let span = max(hi - lo, 0.0001)
            let step = vals.count > 1 ? geo.size.width / CGFloat(vals.count - 1) : geo.size.width

            let line = Path { p in
                for (i, v) in vals.enumerated() {
                    let x = CGFloat(i) * step
                    let ratio = CGFloat(min(max((v - lo) / span, 0), 1))
                    let y = geo.size.height * (1 - ratio)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            if fill {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height))
                    for (i, v) in vals.enumerated() {
                        let x = CGFloat(i) * step
                        let ratio = CGFloat(min(max((v - lo) / span, 0), 1))
                        p.addLine(to: CGPoint(x: x, y: geo.size.height * (1 - ratio)))
                    }
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            }
            line.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 顶部 KPI 大卡：图标 + 标题 + 大数字 + 单位 + 曲线 + 备注
struct KPICard: View {
    var label: String
    var value: String
    var unit: String = ""
    var icon: String
    var tint: Color
    var series: [Double] = []
    var note: String? = nil
    var percent: Double? = nil      // 0...1，给了就在底部画细条
    /// 标题行右侧的附加控件（2.7.6：硬盘温度卡用它在卡片里选看哪块盘）
    var accessory: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .tracking(0.6)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let accessory { accessory }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.dim2)
                }
            }
            Group {
                if series.count > 1 {
                    Sparkline(points: series, color: tint)
                } else if let percent {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.barBg)
                            Capsule().fill(tint)
                                .frame(width: geo.size.width * min(max(percent, 0), 1))
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .frame(height: 22)
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topLeading) {
            // 左侧一条 3pt 的强调色，替代整卡配色，深浅色都稳
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 0)
                .allowsHitTesting(false)
        }
    }
}

/// 细进度条（0...1）
struct MiniBar: View {
    var value: Double
    var color: Color = Theme.blue
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Theme.barBg)
                RoundedRectangle(cornerRadius: height / 2).fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// 内存那种多段堆叠条
struct StackedBar: View {
    var segments: [(String, Double, Color)]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.1 }, 0.0001)
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(seg.2)
                        .frame(width: max(1, geo.size.width * CGFloat(seg.1 / total) - 1.5))
                }
            }
        }
        .frame(height: height)
    }
}

/// 页面内的分组标题
struct GroupTitle: View {
    var text: String
    var sub: String? = nil
    /// 2.8.9：分组说明默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.dim2)
                .tracking(1.2)
            // 原说明（注释保留，不删）：
            //   「0x07C4 bit6」这类寄存器位说明，按用户要求默认不显示
            if let sub, !hideCardSubs {
                Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.dim2.opacity(0.8))
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// 两列字段网格（比一长串 KVRow 省一半高度）
struct FieldGrid: View {
    var rows: [(String, String)]
    var columns: Int = 2

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
                         count: max(1, columns))
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.dim2)
                        .lineLimit(1)
                    Text(row.1)
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.txt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 圆环仪表（已删除 —— 2.8.15 优化时确认无调用点，见 MonitorView.fanBig 自绘圆环）

/// 一行「标签 …… 值」的紧凑行（比 KVRow 矮，用于长列表）
struct TightRow: View {
    var label: String
    var value: String
    var color: Color = Theme.txt
    var mono = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 数值格式化（全界面共用一套，避免各页口径不一）

enum Fmt {
    static func celsius(_ v: Double?) -> String {
        guard let v, v > 0 else { return "—" }
        return String(format: "%.0f", v)
    }
    static func bytes(_ b: Double?) -> String {
        guard let b, b > 0 else { return "0 B" }
        if b >= 1e12 { return String(format: "%.2f TB", b / 1e12) }
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0f MB", b / 1e6) }
        if b >= 1e3 { return String(format: "%.0f KB", b) }
        return String(format: "%.0f B", b)
    }
    static func rate(_ kbs: Double?) -> String {
        guard let kbs else { return "—" }
        if kbs >= 1024 { return String(format: "%.2f MB/s", kbs / 1024) }
        return String(format: "%.0f KB/s", kbs)
    }
    static func watts(_ w: Double?) -> String {
        guard let w else { return "—" }
        return String(format: "%.1f W", w)
    }
    static func minutes(_ m: Int?) -> String {
        guard let m, m > 0 else { return "—" }
        let h = m / 60, mm = m % 60
        return h > 0 ? "\(h) 小时 \(mm) 分" : "\(mm) 分"
    }
    static func tridiagonal(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f", v)
    }
}
