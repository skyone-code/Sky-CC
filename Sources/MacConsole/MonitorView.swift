import SwiftUI

// MARK: - 性能页（2.7.0 重写）
//
// 与「概览」页的分工：概览给一眼看全的即时值与曲线，这里给逐项深挖——
// 每核占用、内存分项、双显卡、每块卷、每块盘 SMART、每路风扇、电池全字段、进程 Top。
//
// 数据全部来自 MonitorStore 的同一份 /api/snapshot（1 秒一次、一次 XPC 往返），
// 页面本身不再发任何请求；曲线由 store.history 里的 90 点环形缓冲直接画。

struct MonitorView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !backend.kextLoaded { KextBanner() }
                header
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        cpuCard.gridEqual()
                        memCard.gridEqual()
                    }
                    GridRow {
                        gpuCard.gridEqual()
                        fanCard.gridEqual()
                    }
                    GridRow {
                        diskCard.gridEqual()
                        netCard.gridEqual()
                    }
                    GridRow {
                        batteryCard.gridEqual()
                        sensorCard.gridEqual()
                    }
                    GridRow {
                        processCard.gridEqual().gridCellColumns(2)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
    }

    // MARK: 页头

    private var header: some View {
        PageHeader(
            title: "性能",
            sub: "每 1 秒刷新 · 一次快照取全 · 风扇值跟随后台 2 秒采样",
            trailing: AnyView(
                LiveBadge(connected: store.connected,
                          updatedAt: store.updatedAt,
                          ms: store.snapshotMs)
            ))
    }

    // MARK: - CPU

    private var cpuCard: some View {
        let usage = BackendService.double(store.overview, "cpu_usage") ?? 0
        let cores = (store.cpu["cores"] as? [Double]) ?? []
        let load = (BackendService.array(store.overview, "load") as? [Double]) ?? []
        return Card(title: "CPU",
                    trailing: { AnyView(Chip(text: coreNote, color: Theme.blue)) }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", usage))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.txt)
                    Text("%").font(.system(size: 13)).foregroundStyle(Theme.dim2)
                    Spacer()
                    Text(cpuBrandClean)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim2)
                        .lineLimit(1)
                }
                Sparkline(points: store.history["cpu"] ?? [], color: Theme.blue)
                    .frame(height: 44)

                if !cores.isEmpty {
                    GroupTitle(text: "每核占用", sub: "\(cores.count) 个逻辑核")
                    // 2.7.2：3 列改 4 列（12 核正好 3 行，卡片矮一截）
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                              spacing: 7) {
                        ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                            coreRow(i, v)
                        }
                    }
                }

                Divider().overlay(Theme.line)
                // 2.7.2：1/5/15 分钟三条负载压成一个字段，值按「1m / 5m / 15m」顺序并列
                FieldGrid(rows: [
                    ("封装温度", "\(Fmt.celsius(store.cpuTemp > 0 ? store.cpuTemp : nil))℃"),
                    ("封装功耗", Fmt.watts(store.cpuWatts)),
                    ("负载 1m/5m/15m", loadText(load)),
                    ("逻辑核数", "\(BackendService.int(store.cpu, "logical") ?? 0)"),
                ], columns: 2)
            }
        }
    }

    private func coreRow(_ i: Int, _ v: Double) -> some View {
        HStack(spacing: 5) {
            Text("\(i)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .frame(width: 13, alignment: .trailing)
            MiniBar(value: v / 100,
                    color: v > 80 ? Theme.red : (v > 50 ? Theme.amber : Theme.blue),
                    height: 5)
                .frame(width: 34)
            Text(String(format: "%.0f", v))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .frame(width: 22, alignment: .trailing)
        }
    }

    // MARK: - 内存

    private var memCard: some View {
        let total = BackendService.double(store.memory, "total") ?? 0
        let used = BackendService.double(store.memory, "used") ?? 0
        let pct = BackendService.double(store.memory, "percent") ?? 0
        let d = store.memDetail
        let app = BackendService.double(d, "app") ?? 0
        let wired = BackendService.double(d, "wired") ?? 0
        let comp = BackendService.double(d, "compressed") ?? 0
        let other = max(0, total - app - wired - comp)
        let swap = BackendService.dict(d, "swap") ?? [:]
        return Card(title: "内存",
                    trailing: { AnyView(Chip(text: "\(Fmt.bytes(total)) 总量", color: Theme.purple)) }) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", pct))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.txt)
                    Text("%").font(.system(size: 13)).foregroundStyle(Theme.dim2)
                    Spacer()
                    Text("\(Fmt.bytes(used)) / \(Fmt.bytes(total))")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                Sparkline(points: store.history["mem"] ?? [], color: Theme.purple,
                          maxValue: 100, minValue: 0)
                    .frame(height: 40)

                StackedBar(segments: [
                    ("应用", app, Theme.purple),
                    ("联动", wired, Theme.blue),
                    ("压缩", comp, Theme.amber),
                    ("其它", other, Theme.dim2),
                ])
                legendRow([("应用", app, Theme.purple), ("联动", wired, Theme.blue),
                           ("压缩", comp, Theme.amber), ("其它", other, Theme.dim2)])

                Divider().overlay(Theme.line)
                FieldGrid(rows: [
                    ("应用内存", Fmt.bytes(app)),
                    ("联动内存", Fmt.bytes(wired)),
                    ("已压缩", Fmt.bytes(comp)),
                    ("可清除", Fmt.bytes(BackendService.double(d, "purgeable"))),
                    ("交换已用", Fmt.bytes(BackendService.double(swap, "used"))),
                    ("交换总量", Fmt.bytes(BackendService.double(swap, "total"))),
                ], columns: 2)
            }
        }
    }

    private func legendRow(_ items: [(String, Double, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).fill(it.2).frame(width: 7, height: 7)
                    Text("\(it.0) \(Fmt.bytes(it.1))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.dim2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - GPU

    private var gpuCard: some View {
        Card(title: "显卡",
             trailing: { AnyView(Chip(text: gpuChipText, color: Theme.cyan)) }) {
            VStack(alignment: .leading, spacing: 12) {
                if store.gpus.isEmpty {
                    Text("读取中…").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                } else {
                    ForEach(Array(store.gpus.enumerated()), id: \.offset) { i, g in
                        if i > 0 { Divider().overlay(Theme.line) }
                        gpuRow(g, index: i)
                    }
                }
                Divider().overlay(Theme.line)
                Text(gpuFootNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 卡片标题右侧的胶囊：核显一定有值，独显只有驱动上报时才带上
    private var gpuChipText: String {
        let igpu = Fmt.tridiagonal(BackendService.double(store.overview, "gpu_usage"))
        if store.dgpuReported {
            return "核显 \(igpu)% · 独显 \(Fmt.tridiagonal(store.dgpuUtil))%"
        }
        return "核显 \(igpu)%"
    }

    private func gpuRow(_ g: [String: Any], index: Int) -> some View {
        let name = BackendService.string(g, "name") ?? "GPU"
        let bus = BackendService.string(g, "bus") ?? ""
        let isDGPU = bus == "PCIe"
        let stats = gpuStatEntry(index)
        // 核显：IOAccelerator 的 Device Utilization %；独显：NVAccel RM 通道（issue #324）
        let rmReported = isDGPU && store.dgpuReported
        let util: Double? = isDGPU
            ? (rmReported ? store.dgpuUtil : nil)
            : (BackendService.double(stats, "utilization")
               ?? BackendService.double(store.overview, "gpu_usage"))
        let utilText: String = {
            guard let u = util else { return isDGPU ? "未上报" : "—" }
            return "\(Fmt.tridiagonal(u))%"
        }()
        let vramTotal = BackendService.string(BackendService.dict(g, "detail"), "VRAM (Total)")
        let vramUsed = BackendService.double(stats, "vramUsedBytes")
            ?? BackendService.double(stats, "In use system memory")
            ?? BackendService.double(stats, "gartUsedBytes")
        // 核显没有独立的 SMC 温度键（raw_temps 里只有 TC0P/TC1C…TC6C，intel GPU 与 CPU 同 die），
        // 所以按用户要求用封装温度加「≈」标出近似，而不是留空。
        let temp: Double? = isDGPU ? store.gpuTemp : (store.cpuTemp > 0 ? store.cpuTemp : nil)
        let tempPrefix = isDGPU ? "" : "≈"
        let vramText: String = {
            guard let t = vramTotal else { return "—" }
            return "显存 \(Fmt.bytes(vramUsed)) / \(t)"
        }()

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                Chip(text: isDGPU ? "独显" : "核显", color: isDGPU ? Theme.amber : Theme.cyan)
                Spacer(minLength: 6)
                if let temp, temp > 0 {
                    Text("\(tempPrefix)\(Fmt.celsius(temp))℃")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(store.tempColor(temp))
                        .help(isDGPU ? "EC 0x044F 直读独显温度" : "核显与 CPU 同一封装，取封装传感器近似值")
                }
            }
            HStack(spacing: 8) {
                MiniBar(value: (util ?? 0) / 100,
                        color: (util ?? 0) > 80 ? Theme.red : Theme.cyan,
                        height: 7)
                    .frame(width: 120)
                Text(utilText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(util == nil ? Theme.dim2 : Theme.txt)
                Spacer(minLength: 0)
                Text(vramText)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
            }
        }
    }

    /// 说明文案要跟着数据来源变：驱动上报了就说 RM 通道，没上报就直说不可用，
    /// 免得用户以为 0% 是「真的空闲」。
    private var gpuFootNote: String {
        if store.dgpuReported {
            return "核显：IOAccelerator 的 Device Utilization %；独显：NVAccel RM 的 GPUMON perfmon（issue #324）。"
        }
        if store.dgpuAvailable {
            return "核显：IOAccelerator 的 Device Utilization %。独显的 RM 通道已连通，但当前驱动把 util 恒填 0（金属满载实测仍为 0），因此显示「未上报」。"
        }
        return "核显：IOAccelerator 的 Device Utilization %。未找到 NVAccel 服务，独显利用率不可用。"
    }

    /// 把 gpu_stats（IOAccelerator 列表）与 gpus（system_profiler 列表）对上：
    /// 两张表顺序不保证一致，按 index 兜底即可——核显通常只有一条统计。
    private func gpuStatEntry(_ index: Int) -> [String: Any] {
        let stats = (BackendService.array(store.overview, "gpu_stats") as? [[String: Any]]) ?? []
        if index < stats.count { return stats[index] }
        return stats.first ?? [:]
    }

    // MARK: - 风扇

    private var fanCard: some View {
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
                           pwm: BackendService.int(store.live, "pwm_cpu_pct") ?? 0,
                           temp: BackendService.int(store.live, "temp_cpu") ?? 0)
                    fanBig("独显", rpm: BackendService.int(store.live, "rpm_gpu") ?? 0,
                           pwm: BackendService.int(store.live, "pwm_gpu_pct") ?? 0,
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
    /// 底部一行小字「占空比 · 温度」。上一版把 % 做成 60pt 主数字、环铺满卡片，
    /// 视线全被环和百分比抓走，跟「风扇看的是转速」这件事相反。
    private func fanBig(_ name: String, rpm: Int, pwm: Int, temp: Int) -> some View {
        let color = pwm > 70 ? Theme.amber : Theme.cyan
        let side: CGFloat = 158
        let lw: CGFloat = 9.5
        return ZStack {
            Circle().stroke(Theme.barBg, lineWidth: lw)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(pwm, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: pwm)
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
                    Text("\(pwm)%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                    Circle().fill(Theme.dim2.opacity(0.5)).frame(width: 2.5, height: 2.5)
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
        switch BackendService.int(store.fan, "modeindex") {
        case 0x11: return "专业"
        case 0x22: return "平衡"
        case 0x33: return "省电"
        default: break
        }
        switch BackendService.string(store.fan, "actual") ?? "" {
        case "normal": return "自动"
        case "boost": return "基准·最大"
        case "custom": return "手动"
        case "curve": return "曲线"
        default: return "—"
        }
    }

    // MARK: - 磁盘

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

    private func volumeRow(_ d: [String: Any]) -> some View {        let pct = Double(BackendService.int(d, "percent") ?? 0)
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

    // MARK: - 网络

    private var netCard: some View {
        let down = BackendService.double(store.net, "down_kbs") ?? 0
        let up = BackendService.double(store.net, "up_kbs") ?? 0
        let ifs = (BackendService.array(store.net, "interfaces") as? [[String: Any]]) ?? []
        let active = ifs.filter { (BackendService.bool($0, "up") ?? false)
            && !(BackendService.bool($0, "loopback") ?? false) }
        return Card(title: "网络",
                    trailing: { AnyView(Chip(text: "\(active.count) 个活动接口", color: Theme.cyan)) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    rateBlock("下行", down, Theme.cyan, "arrow.down")
                    rateBlock("上行", up, Theme.purple, "arrow.up")
                }
                Sparkline(points: store.history["down"] ?? [], color: Theme.cyan)
                    .frame(height: 26)
                Divider().overlay(Theme.line)
                FieldGrid(rows: [
                    ("累计接收", Fmt.bytes(BackendService.double(store.net, "total_recv"))),
                    ("累计发送", Fmt.bytes(BackendService.double(store.net, "total_sent"))),
                ], columns: 2)
                if !active.isEmpty {
                    ForEach(Array(active.prefix(3).enumerated()), id: \.offset) { _, it in
                        ifRow(it)
                    }
                }
                // 2.7.1：Wi-Fi 详情（用户要求补在下方）
                if (BackendService.bool(wifi, "available") ?? false) {
                    Divider().overlay(Theme.line)
                    wifiBlock
                }
            }
        }
    }

    private func rateBlock(_ label: String, _ kbs: Double, _ tint: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(Theme.dim2)
            Text(Fmt.rate(kbs))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Wi-Fi 卡片块：SSID / 信号 / 速率 / 信道 / 安全。
    /// SSID 在 macOS 14+ 要「定位服务」授权，未授权时拿不到——这里如实显示「未授权」，
    /// 不拿 BSSID 或占位字符串冒充网络名。
    private var wifiBlock: some View {
        let rssi = BackendService.int(wifi, "rssi_dbm") ?? 0
        let on = BackendService.bool(wifi, "power_on") ?? false
        let ssid = BackendService.string(wifi, "ssid")
        let quality = min(max((Double(rssi) + 95) / 55, 0), 1)   // -95dBm→0，-40dBm→1
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: on ? "wifi" : "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Theme.green : Theme.dim2)
                Text(ssid ?? (on ? "未关联 / SSID 需定位授权" : "Wi-Fi 已关闭"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ssid == nil ? Theme.dim2 : Theme.txt)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(BackendService.string(wifi, "security") ?? "—")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.dim2)
            }
            HStack(spacing: 8) {
                MiniBar(value: quality,
                        color: rssi > -60 ? Theme.green : (rssi > -75 ? Theme.amber : Theme.red),
                        height: 5)
                    .frame(width: 60)
                Text(rssi == 0 ? "—" : "\(rssi) dBm")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                Text("\(BackendService.int(wifi, "tx_rate_mbps") ?? 0) Mbps")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                Text(channelText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.dim2)
            }
        }
    }

    private var channelText: String {
        let ch = BackendService.int(wifi, "channel") ?? 0
        guard ch > 0 else { return "—" }
        let band = BackendService.string(wifi, "band") ?? ""
        return band.isEmpty ? "CH \(ch)" : "CH \(ch) · \(band)"
    }

    /// Wi-Fi 快照（后端 CoreWLAN 采集）
    private var wifi: [String: Any] { BackendService.dict(store.overview, "wifi") ?? [:] }

    private func ifRow(_ it: [String: Any]) -> some View {
        let name = BackendService.string(it, "name") ?? "—"
        let ip = ((BackendService.array(it, "ipv4") as? [String]) ?? []).first ?? "—"
        return HStack(spacing: 6) {
            Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.txt)
            Text(ip).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.dim2).lineLimit(1)
            Spacer(minLength: 0)
            Text("↓\(Fmt.rate(BackendService.double(it, "down_kbs")))  ↑\(Fmt.rate(BackendService.double(it, "up_kbs")))")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
        }
    }

    // MARK: - 电池

    private var batteryCard: some View {
        let pct = BackendService.double(store.battery, "percent") ?? 0
        let state = BackendService.string(store.battery, "state") ?? "—"
        let health = BackendService.string(store.battery, "health")
        return Card(title: "电池",
                    trailing: { AnyView(Chip(text: state, color: state.contains("充电") ? Theme.green : Theme.blue)) }) {
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
                    TightRow(label: "循环次数", value: "\(BackendService.int(store.battery, "cycle_count") ?? 0)")
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

    // MARK: - 传感器

    private var sensorCard: some View {
        let cores = (BackendService.array(store.sensors, "cores") as? [[String: Any]]) ?? []
        let pkg = (BackendService.array(store.sensors, "package") as? [[String: Any]]) ?? []
        return Card(title: "温度传感器 · SMC",
                    trailing: { AnyView(Chip(text: "TC0P \(Fmt.celsius(store.cpuTemp > 0 ? store.cpuTemp : nil))℃",
                                             color: store.tempColor(store.cpuTemp))) }) {
            if cores.isEmpty {
                Text((store.sensors["available"] as? Bool) == true ? "读取中…" : "SMC 不可用")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                              spacing: 8) {
                        ForEach(Array(cores.enumerated()), id: \.offset) { _, c in
                            let t = BackendService.double(c, "celsius") ?? 0
                            VStack(spacing: 3) {
                                Text(String(format: "%.0f°", t))
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(store.tempColor(t))
                                Text(BackendService.string(c, "name") ?? "")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.dim2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    if !pkg.isEmpty {
                        Divider().overlay(Theme.line)
                        FieldGrid(rows: pkg.map { p in
                            (BackendService.string(p, "name") ?? "—",
                             String(format: "%.1f ℃", BackendService.double(p, "celsius") ?? 0))
                        }, columns: 2)
                    }
                }
            }
        }
    }

    // MARK: - 进程

    private var processCard: some View {
        Card(title: "进程 · CPU 占用 Top 10",
             trailing: { AnyView(Text("ps -Ao … -r").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.dim2)) }) {
            if store.processes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                    Text("当前无高占用进程").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                }
            } else {
                let top = Array(store.processes.prefix(10))
                let maxCpu = max(top.compactMap { BackendService.double($0, "cpu") }.max() ?? 1, 1)
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, p in
                        processRow(i, p, maxCpu)
                    }
                }
            }
        }
    }

    private func processRow(_ i: Int, _ p: [String: Any], _ maxCpu: Double) -> some View {
        let cpu = BackendService.double(p, "cpu") ?? 0
        let mem = BackendService.double(p, "mem") ?? 0
        return HStack(spacing: 10) {
            Text("\(i + 1)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .frame(width: 18, alignment: .trailing)
            Text(BackendService.string(p, "name") ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
            MiniBar(value: cpu / maxCpu,
                    color: cpu > 50 ? Theme.red : (cpu > 20 ? Theme.amber : Theme.blue),
                    height: 6)
            Text(String(format: "%.1f%%", cpu))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .frame(width: 52, alignment: .trailing)
            Text(String(format: "%.1f%%", mem))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .frame(width: 48, alignment: .trailing)
            Text(BackendService.string(p, "user") ?? "")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim2)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 0.5)
        }
    }

    // MARK: - 取值

    private var cpuBrandClean: String {
        let raw = BackendService.string(store.cpu, "brand") ?? "—"
        return raw
            .replacingOccurrences(of: "Intel(R) Core(TM) ", with: "")
            .replacingOccurrences(of: " CPU", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var coreNote: String {
        let p = BackendService.int(store.cpu, "physical") ?? 0
        let l = BackendService.int(store.cpu, "logical") ?? 0
        return "\(p)C / \(l)T"
    }

    /// 三条负载挤成一行：6.45 / 7.14 / 7.25（对应 1、5、15 分钟）
    private func loadText(_ load: [Double]) -> String {
        guard !load.isEmpty else { return "—" }
        return load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }
}

/// Grid 单元格内撑满——同一行卡片等高、同列等宽的关键
extension View {
    /// 2.7.1：只撑宽，不再撑高。
    /// 之前用 maxHeight: .infinity 会把同一行每张卡都拉到最高那张的高度，
    /// 于是「风扇 / 电池 / 本机」这类内容少的卡下面会空出一大片（用户反馈的大空）。
    /// 现在卡片高度跟着内容走，行内对齐顶部，允许留小空。
    @ViewBuilder func gridEqual() -> some View {
        frame(maxWidth: .infinity, alignment: .top)
    }
}
