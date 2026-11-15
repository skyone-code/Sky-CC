//
//  OverviewView.swift
//  Sky CC —— 概览页
//
//  3.0.4.5（2026-11-14 用户要求）重新拆页：
//   · 「性能」页只留 CPU / GPU / 内存 / 网络四张卡；
//   · 「控制」页的风扇转速卡、「性能」页的存储/电池两卡、「设置」页顶部的
//     设备 / 本机两张身份卡，全部集中到本页。
//   · 性能页顶部的机型 hero 条（MacBook Pro 16 英寸…）迁来本页最上方；
//     风扇 / 电池两卡并排双列；电池卡不再显示循环次数读不到的小字说明。
//
//  数据照旧来自 MonitorStore 的同一份快照，页面本身不发请求。
//  风扇实时转速需要 live 租约（demandLiveFan），进页面声明、离开收回 ——
//  这份租约原在性能页 / 控制页，随卡片一起搬到本页。
//

import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !backend.kextLoaded { KextBanner() }
                // 机型 hero 条（原性能页顶部，用户要求挪来本页最上方）
                header
                // 机型 hero 条（2026-11-14 用户要求：放在页标题之下、身份卡之上）
                MonitorHeroBar()
                // 设备 / 本机两张身份卡（内部双列）；系统与启动参数已迁设置页底部
                SystemIdentitySection()
                // 风扇 + 电池并排双列（用户要求同一行）；存储通栏：卷列表 + SMART
                HStack(alignment: .top, spacing: 14) {
                    FanRPMCard()
                        .frame(maxWidth: .infinity, alignment: .top)
                    batteryCard
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                diskCard
            }
            .padding(22)
        }
        .background(Theme.bg)
        .onAppear {
            // 风扇卡在本页：声明实时转速租约（helper 才按 1 秒读 EC），离开即收回
            store.demandLiveFan(true)
            // 本页有转速 / 电池等实时量，同样登记 1 秒快速轮询
            store.demandFast(true)
        }
        .onDisappear {
            store.demandLiveFan(false)
            store.demandFast(false)
        }
    }

    private var header: some View {
        PageHeader(
            title: "概览",
            sub: "设备 · 风扇 · 电池 · 存储",
            trailing: AnyView(
                LiveBadge(connected: store.connected,
                          updatedAt: store.updatedAt,
                          ms: store.snapshotMs)
            ))
    }

    // MARK: - 存储（自「性能」页整体迁入，代码未改）

    private var diskCard: some View {
        Card(title: "存储",
                    trailing: { AnyView(Chip(text: "\(store.disks.count) 个卷", color: Theme.green)) }) {
            VStack(alignment: .leading, spacing: 12) {
                if store.disks.isEmpty {
                    Text("读取中…").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                } else {
                    ForEach(Array(store.disks.enumerated()), id: \.offset) { _, d in
                        volumeRow(d)
                    }
                }
                Divider().overlay(Theme.line)
                // 2.7.1：逐盘 SMART（用户要求两块盘的都在这一块里）
                ForEach(Array(smartList.enumerated()), id: \.offset) { _, e in
                    smartBlock(e)
                }
            }
        }
    }

    /// 逐盘 SMART 条目（后端 smartList()）；未覆盖的盘会带 covered=false
    private var smartList: [[String: Any]] {
        (BackendService.array(store.overview, "smart") as? [[String: Any]]) ?? []
    }

    private func smartBlock(_ e: [String: Any]) -> some View {
        let ok = BackendService.bool(e, "ok") ?? false
        let covered = BackendService.bool(e, "covered") ?? false
        let bsd = BackendService.string(e, "bsd") ?? "—"
        let model = BackendService.string(e, "model") ?? ""
        let temp = BackendService.double(e, "temperature_c")
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.seal.fill" : "minus.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ok ? Theme.green : Theme.dim2)
                // 2.7.5：带上型号（OV NVME SSD 1TB P300 / SKHynix_HFS512GDE9X084N），
                // 一眼能分清是哪块盘
                Text(model.isEmpty ? "\(bsd) · NVMe SMART" : "\(bsd) · \(model)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if ok {
                    Text("\(Fmt.celsius(temp))℃")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(store.tempColor(temp ?? 0))
                } else {
                    Text(covered ? "读取失败" : "未覆盖")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim2)
                }
            }
            if ok {
                FieldGrid(rows: [
                    ("可用备件", "\(BackendService.int(e, "available_spare") ?? 0)%"),
                    ("已用寿命", "\(BackendService.int(e, "percentage_used") ?? 0)%"),
                    ("累计读取", Fmt.bytes((BackendService.double(e, "data_units_read") ?? 0) * 512_000)),
                    ("累计写入", Fmt.bytes((BackendService.double(e, "data_units_written") ?? 0) * 512_000)),
                ], columns: 2)
            } else {
                Text(BackendService.string(e, "error") ?? "读取中…")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func volumeRow(_ d: [String: Any]) -> some View {
        let pct = Double(BackendService.int(d, "percent") ?? 0)
        let rk = BackendService.double(d, "read_kbs") ?? 0
        let wk = BackendService.double(d, "write_kbs") ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(BackendService.string(d, "mount") ?? "—")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                Text(BackendService.string(d, "device") ?? "")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.dim2)
                Spacer(minLength: 6)
                Text("\(Fmt.bytes(BackendService.double(d, "used"))) / \(Fmt.bytes(BackendService.double(d, "total")))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                Text("\(Int(pct))%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct > 85 ? Theme.red : (pct > 65 ? Theme.amber : Theme.txt))
                    .frame(width: 34, alignment: .trailing)
            }
            MiniBar(value: pct / 100,
                    color: pct > 85 ? Theme.red : (pct > 65 ? Theme.amber : Theme.cyan),
                    height: 5)
            HStack(spacing: 10) {
                Text("↓ \(Fmt.rate(rk))").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.dim2)
                Text("↑ \(Fmt.rate(wk))").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.dim2)
                Spacer(minLength: 0)
                Text(BackendService.string(d, "fstype") ?? "")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.dim2)
            }
        }
    }

    // MARK: - 电池（自「性能」页整体迁入，代码未改）

    /// 循环次数是否真的读到了（0 既可能是「真 0 次」也可能是「平台没上报」）
    private var cycleAvailable: Bool {
        if let b = store.battery["cycle_count_available"] as? Bool { return b }
        return (BackendService.int(store.battery, "cycle_count") ?? 0) > 0
    }

    /// 读得到就显示「次数 / 设计次数」，读不到就显示「— / 设计次数」，
    /// 避免把「读不到」直接显示成「0」让人误以为电池是新的。
    private var cycleValueText: String {
        let c = BackendService.int(store.battery, "cycle_count") ?? 0
        let design = BackendService.int(store.battery, "design_cycle_count") ?? 0
        if cycleAvailable { return design > 0 ? "\(c) / \(design)" : "\(c)" }
        return design > 0 ? "— / \(design)" : "—"
    }

    private var batteryCard: some View {
        let pct = BackendService.double(store.battery, "percent") ?? 0
        let state = BackendService.string(store.battery, "state") ?? "—"
        let health = BackendService.string(store.battery, "health")
        return Card(title: "电池",
                    trailing: { AnyView(Chip(text: state, color: state.contains("充电") ? Theme.green : Theme.blue)) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 18) {
                    // 2.7.2：环跟着右列行数走，把卡片高度撑满（用户要求）；
                    // 用 GeometryReader 取高度而不是写死 128，右侧多出「剩余时间」时也会自适应。
                    batteryRing(pct)
                        .frame(width: 190)
                    VStack(spacing: 0) {
                        TightRow(label: "电压", value: String(format: "%.2f V",
                                 Double(BackendService.int(store.battery, "voltage_mv") ?? 0) / 1000))
                        TightRow(label: "电流", value: String(format: "%.0f mA",
                                 BackendService.double(store.battery, "amperage_ma") ?? 0))
                        TightRow(label: "功耗", value: Fmt.watts(BackendService.double(store.battery, "power_w")))
                        TightRow(label: "温度", value: String(format: "%.1f ℃",
                                 BackendService.double(store.battery, "temperature_c") ?? 0))
                        TightRow(label: "循环次数", value: cycleValueText)
                        TightRow(label: "健康度", value: health ?? "—",
                                 color: (health ?? "").contains("Good") ? Theme.green : Theme.txt)
                        TightRow(label: "满容量", value: "\(BackendService.int(store.battery, "max_capacity") ?? 0) mAh")
                        if let m = BackendService.int(store.battery, "time_to_empty_min"), m > 0 {
                            TightRow(label: "剩余时间", value: Fmt.minutes(m))
                        }
                    }
                }
            }
        }
    }

    /// 电池环：直径 = min(给定宽度, 行高)，所以右侧列表长多高、环就多高。
    private func batteryRing(_ pct: Double) -> some View {
        GeometryReader { geo in
            let side = max(72, min(geo.size.width, geo.size.height))
            let scale = side / 110
            ZStack {
                Circle().stroke(Theme.barBg, lineWidth: 9 * scale)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(pct, 0), 100) / 100))
                    .stroke(pct > 20 ? Theme.green : Theme.red,
                            style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: pct)
                VStack(spacing: 0) {
                    Text("\(Int(pct))")
                        .font(.system(size: 27 * scale, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.txt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("%")
                        .font(.system(size: 9.5 * scale))
                        .foregroundStyle(Theme.dim2)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
