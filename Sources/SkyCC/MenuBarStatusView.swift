import SwiftUI

/// 状态栏显示页（2026-11-16 用户定案）：
/// 侧边栏「监测」组、性能下面。这里逐项勾选拼进菜单栏监控状态项的内容：
///   CPU：温度 / 频率 / 占用率 / 功耗 / 风扇转速 / 核显占用率 / 核显显存占用
///   GPU：温度 / 频率 / 占用率 / 功耗 / 风扇转速 / GR 占用率 / 显存占用
///   内存：占用率
///   硬盘：温度（一块盘一个开关，有几块显示几块）
///   网速：仅上行 / 仅下行 / 上下行
/// S 飘带（程序主图标）不在这里配置 —— 它是独立状态项，风格在设置页外观卡。
struct MenuBarStatusView: View {
    @EnvironmentObject var backend: BackendService
    @ObservedObject private var store = MonitorStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "状态栏显示", sub: "菜单栏监控项 · 逐项开关 · 按盘显示")
                menuBarCard
                previewCard
            }
            .padding(22)
        }
    }

    /// 监控项逐组开关
    private var menuBarCard: some View {
        Card(title: "菜单栏监控项") {
            VStack(alignment: .leading, spacing: 8) {
                // CPU 组
                groupHeader(SegmentGroup.cpu)
                ForEach(MenuBarMonitors.segments(in: .cpu)) { seg in
                    MenuBarToggleRow(icon: seg.symbol,
                                     title: seg.title,
                                     key: seg.defaultsKey,
                                     defaultOn: seg.defaultEnabled)
                }
                divider
                // GPU 组
                groupHeader(SegmentGroup.gpu)
                ForEach(MenuBarMonitors.segments(in: .gpu)) { seg in
                    MenuBarToggleRow(icon: seg.symbol,
                                     title: seg.title,
                                     key: seg.defaultsKey,
                                     defaultOn: seg.defaultEnabled)
                }
                divider
                // 内存组
                groupHeader(SegmentGroup.mem)
                ForEach(MenuBarMonitors.segments(in: .mem)) { seg in
                    MenuBarToggleRow(icon: seg.symbol,
                                     title: seg.title,
                                     key: seg.defaultsKey,
                                     defaultOn: seg.defaultEnabled)
                }
                divider
                // 硬盘组（动态：overview.smart 里的每块盘一个开关，显示该盘温度）
                groupHeader(SegmentGroup.disk)
                if diskRows.isEmpty {
                    Text("正在读取磁盘…")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                        .padding(.vertical, 4)
                } else {
                    ForEach(diskRows, id: \.bsd) { d in
                        MenuBarToggleRow(icon: "internaldrive",
                                         title: d.model.isEmpty ? d.bsd : "\(d.bsd) · \(d.model)",
                                         note: "温度",
                                         key: MenuBarMonitors.diskKey(d.bsd),
                                         defaultOn: false)
                    }
                }
                divider
                // 网速组
                groupHeader(SegmentGroup.net)
                ForEach(MenuBarMonitors.segments(in: .net)) { seg in
                    MenuBarToggleRow(icon: seg.symbol,
                                     title: seg.title,
                                     key: seg.defaultsKey,
                                     defaultOn: seg.defaultEnabled)
                }

                Text("开关实时生效。监控数字拼接在 S 飘带右侧的独立状态项里；全部关掉时该状态项隐藏。取不到的读数显示「—」，不显示假数字。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .padding(.top, 2)
                    .cardNote()
            }
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.line.opacity(0.6)).padding(.vertical, 3)
    }

    private func groupHeader(_ g: SegmentGroup) -> some View {
        Text(g.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.dim)
            .tracking(1.2)
            .padding(.vertical, 1)
    }

    // MARK: 磁盘清单（每秒快照里的 smart 数组）

    private struct DiskRow { let bsd: String; let model: String }

    private var diskRows: [DiskRow] {
        let list = (BackendService.array(store.overview, "smart") as? [[String: Any]]) ?? []
        return list.compactMap { d in
            let bsd = BackendService.string(d, "bsd") ?? ""
            guard !bsd.isEmpty else { return nil }
            return DiskRow(bsd: bsd, model: BackendService.string(d, "model") ?? "")
        }
    }

    // MARK: 实时预览（按当前勾选拼一遍，所见即菜单栏所得）

    private var previewCard: some View {
        Card(title: "预览") {
            VStack(alignment: .leading, spacing: 8) {
                MenuBarMonitorBarPreview()
                Text("实际渲染在菜单栏上（跟随系统深浅色），此处仅示意内容与顺序；窗口窄时预览自动换行，菜单栏里仍是一行拼接。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                    .cardNote()
            }
        }
    }
}

/// 通用开关行：图标 + 名称（+ 灰字备注）+ 开关。
/// 2026-11-16 精炼：原 MenuBarSegmentToggleRow / MenuBarDiskToggleRow 两套
/// 重复实现合并成一个（只有图标 / 标题 / 备注三个入参不同）。开关一变就发
/// iconsChanged 通知 —— 拼接条与预览卡都监听它立即重算段清单。
struct MenuBarToggleRow: View {
    let icon: String
    let title: String
    var note: String? = nil
    @AppStorage private var on: Bool

    init(icon: String, title: String, note: String? = nil, key: String, defaultOn: Bool) {
        self.icon = icon
        self.title = title
        self.note = note
        _on = AppStorage(wrappedValue: defaultOn, key)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(Theme.blue)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.dim2)
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

/// 预览：与 MenuBarMonitorBar 完全同一段渲染（MonitorSegmentView），所见即所得。
/// 2026-11-16 修 bug：原来是一行 HStack + fixedSize，主窗口开到最小宽度时
/// 右侧的段直接看不见（用户实测）；改用 FlowLayout 自动换行，
/// 窄窗口也能看到全部勾选项。实际菜单栏里仍是一行拼接。
private struct MenuBarMonitorBarPreview: View {
    @ObservedObject private var hub = MetricsHub.shared
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let refs = MenuBarMonitors.currentSegments(overview: hub.overview)
        FlowLayout(spacing: 8)
        {
            if refs.isEmpty {
                Text("（未勾选任何监控项）")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim2)
            }
            ForEach(refs) { ref in
                MonitorSegmentView(ref: ref,
                                   overview: hub.overview,
                                   live: hub.live,
                                   sensors: hub.sensors)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.line.opacity(0.6), lineWidth: 1))
        .onReceive(NotificationCenter.default.publisher(for: MenuBarMonitors.iconsChanged)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            revision &+= 1
        }
    }
}

/// 简单流式布局：一行放不下就折到下一行（预览卡窄窗口用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > bounds.width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                    anchor: .topLeading, proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
