import SwiftUI

// MARK: - 性能页（2.7.0 重写）
//
// 与「概览」页的分工：概览给一眼看全的即时值与曲线，这里给逐项深挖——
// 每核占用、内存分项、双显卡、每块卷、每块盘 SMART、每路风扇、电池全字段。
//
// 2.7.6（2026-10-22 用户要求）：删掉「进程 · CPU 占用 Top 10」卡片（连同 processRow）。
// 数据仍在：store.processes 照旧由快照下发，AllDataView 的原始数据页里还能看到，
// 只是性能页不再渲染这张卡。
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
                // 2026-10-26（用户定的版式）：核心温度并进 CPU 卡后，那张卡删掉，
                // 剩下 7 张按**实测高度**配对，让每一行的两张尽量一样高（空位最小）：
                //
                //   第 1 行  CPU 440      | GPU 425        → 差 15
                //   第 2 行  内存 339      | 网络 297       → 差 42
                //   第 3 行  存储 385      | 风扇 238 + 电池 236 = 488 → 差 103
                //
                // 这个配法是穷举出来的最优解（总空位 160pt）。其它配法都更差：
                //   内存|存储 + 网络|风扇+电池 → 237
                //   内存|风扇+电池 + 网络|存储 → 237
                // 想再收紧只能改卡片内容本身（比如存储卡多塞两行），不是排布问题。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        cpuCard.gridEqual()
                        gpuCard.gridEqual()
                    }
                    GridRow {
                        memCard.gridEqual()
                        netCard.gridEqual()
                    }
                    GridRow {
                        diskCard.gridEqual()
                        VStack(spacing: 14) {
                            fanCard
                            batteryCard
                        }
                        .gridEqual()
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .onAppear {
            // 2.8.15：本页显示实时转速 → 声明需求，helper 才按租约读 EC。
            // 切走即收回，10 秒后 EC 读取归零。
            // （独显利用率不再需要登记：驱动 2.6.3 自己每秒采样并发布，
            //   我们只是读 IORegistry，一次是微秒级，不存在「谁在看」的开关。）
            store.demandLiveFan(true)
        }
        .onDisappear {
            store.demandLiveFan(false)
        }
    }

    // MARK: 页头

    private var header: some View {
        PageHeader(
            title: "性能",
            sub: "每 1 秒刷新 · 一次快照取全 · 风扇转速随页面可见实时刷新",
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
                // 固定 0~100：自适应在空闲时会把 1~2% 的抖动拉成满幅，看着像满载。
                // 百分比指标本来就该有绝对刻度（内存那条曲线一直是这么画的）。
                Sparkline(points: store.history["cpu"] ?? [], color: Theme.blue,
                          maxValue: 100, minValue: 0)
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

                // 2026-10-26（用户要求）：原「CPU 核心温度」卡片整块并进来，那张卡删掉。
                // 占用和温度本来就是同一个东西的两个面，分两张卡反而要来回看。
                // 6 个物理核（SMC TC1C~TC6C）一排 6 格，跟上面 12 个逻辑核的 4 列错开，
                // 一眼能看出「6 核 12 线程」这个事实。
                if !coreTemps.isEmpty {
                    GroupTitle(text: "核心温度", sub: "6 个物理核 · TC1C~TC6C")
                        .help(packageTempsHelp)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                              spacing: 8) {
                        ForEach(Array(coreTemps.enumerated()), id: \.offset) { _, c in
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
                }

                Divider().overlay(Theme.line)
                // 2026-10-26（用户要求）：4 项从「2 列 2 行」改成一行，CPU 卡比 GPU 卡高的问题就没了。
                // 没用 FieldGrid(columns: 4)：等分后每列只有约 90pt，
                // 「5.80 / 5.56 / 5.71」在 12.5pt 等宽字下要 135pt，会被压成省略号。
                // 这里用 HStack + Spacer 让每项按内容取宽，再均匀铺开，视觉上和 4 列网格一样。
                HStack(alignment: .top, spacing: 0) {
                    cpuField("封装温度", "\(Fmt.celsius(store.cpuTemp > 0 ? store.cpuTemp : nil))℃")
                    Spacer(minLength: 10)
                    cpuField("封装功耗", Fmt.watts(store.cpuWatts))
                    Spacer(minLength: 10)
                    cpuField("负载 1m/5m/15m", loadText(load))
                    Spacer(minLength: 10)
                    cpuField("逻辑核数", "\(BackendService.int(store.cpu, "logical") ?? 0)")
                }
            }
        }
    }

    /// GPU 卡片底部的核显摘要：占用率 + 当前显存占用。
    /// 温度不在这里重复 —— CPU 卡里的「封装温度」就是它（同一颗 die），
    /// 原来显卡卡片里那个「≈ 封装温度」的近似值就是在说这件事。
    private var iGPUBlock: some View {
        let g = igpuInfo
        let detail = BackendService.dict(g, "detail")
        let name = BackendService.string(g, "name") ?? "Intel GPU"
        let util = BackendService.double(store.overview, "gpu_usage")
        // iGPU 没有独立显存：总量是动态上限（VRAM (Dynamic, Max)），
        // 当前占用来自 IOAccelerator 的 In use system memory。
        let stats = igpuStatEntry
        let used = BackendService.double(stats, "In use system memory")
            ?? BackendService.double(stats, "vramUsedBytes")
            ?? BackendService.double(stats, "gartUsedBytes")
        let cap = BackendService.string(detail, "VRAM (Dynamic, Max)")
            ?? BackendService.string(detail, "VRAM (Total)")
        let vramText: String = {
            guard let cap else { return "显存 —" }
            return "显存 \(Fmt.bytes(used)) / \(cap)"
        }()

        // 2026-10-26（用户要求「把显存并进右边」）：压成一行。
        // 原来是「占用条 + 显存」独占第二行，白吃 20pt 高，GPU 卡比 CPU 卡高出一截；
        // 现在 名称在左、占用条和百分比居中偏右、显存贴最右，一行说完。
        return HStack(spacing: 7) {
            Text("iGPU")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.cyan)
                .tracking(1.0)
            Text(name)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
            Spacer(minLength: 6)
            MiniBar(value: (util ?? 0) / 100, color: Theme.cyan, height: 6)
                .frame(width: 64)
            Text(util.map { "\(Fmt.tridiagonal($0))%" } ?? "—")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(util == nil ? Theme.dim2 : Theme.txt)
            // 显存贴最右且不允许被截断 —— 型号名可以缩，这个数字不能
            Text(vramText)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 3)
        }
    }

    /// system_profiler 里 bus 不是 PCIe 的那条就是核显（核显没有 Bus 字段，
    /// 只有 Connection Type: Internal）
    private var igpuInfo: [String: Any] {
        store.gpus.first { (BackendService.string($0, "bus") ?? "") != "PCIe" } ?? [:]
    }

    /// 核显的 IOAccelerator 统计（IntelAccelerator）。驱动 2.6.3 起 NVAccel 也发布
    /// PerformanceStatistics 了（利用率 + 温度），所以这里**必须**按 io_class 挑，
    /// 别按顺序猜，也别再用「第一条就是核显」那种假设。
    private var igpuStatEntry: [String: Any] {
        let stats = (BackendService.array(store.overview, "gpu_stats") as? [[String: Any]]) ?? []
        if let intel = stats.first(where: {
            (BackendService.string($0, "io_class") ?? "").localizedCaseInsensitiveContains("Intel")
        }) { return intel }
        return stats.first ?? [:]
    }

    /// 6 个物理核的温度（SMC TC1C~TC6C，来自 /api/snapshot 的 sensors.cores）
    private var coreTemps: [[String: Any]] {
        (BackendService.array(store.sensors, "cores") as? [[String: Any]]) ?? []
    }

    /// 封装温度那 5 个传感器的 tooltip。
    /// 卡片正文里只留一个 TC0P（就是「封装温度」那格），其余 TC0D/0E/0F/0H
    /// 属于排障数据 —— 以前它们在「温度传感器」卡里各占一行，现在收进这里，
    /// 数据没丢，只是不再占版面。
    private var packageTempsHelp: String {
        let pkg = (BackendService.array(store.sensors, "package") as? [[String: Any]]) ?? []
        guard !pkg.isEmpty else { return "SMC 封装温度不可用" }
        let parts = pkg.map { p in
            "\(BackendService.string(p, "name") ?? "—") "
                + String(format: "%.1f℃", BackendService.double(p, "celsius") ?? 0)
        }
        return "封装 / 接近温度（SMC）：\n" + parts.joined(separator: " · ")
    }

    /// 一行里的一个字段，样式与 FieldGrid 的单元格完全一致
    /// （10.5 灰标签 + 12.5 等宽主文字），只是宽度跟着内容走、不被等分列挤压。
    private func cpuField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
                .fixedSize()
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

    // MARK: - GPU（独显为主 + 核显摘要）

    /// 2026-10-26（用户定的版式）：卡片改回「GPU」，上半张是独显，下半张是核显。
    ///
    /// 上一版把 iGPU 挪进了 CPU 卡片（理由是「和 CPU 同 die、同温度传感器」），
    /// 但那样 CPU 卡越堆越杂，而这张卡本来就叫「显卡」。现在独显信息铺满上半张
    /// （GR 大数字 + 曲线 + 四引擎 + 字段网格），核显退回底部一小条摘要。
    private var gpuCard: some View {
        let g = dgpuInfo
        let detail = BackendService.dict(g, "detail")
        let reported = store.dgpuReported
        let gr = store.dgpuUtilAvg5
        let temp = store.gpuTemp
        let rpm = BackendService.int(store.live, "rpm_gpu") ?? 0
        let peak = (store.history["dgpu"] ?? []).max()

        return Card(title: "GPU",
                    trailing: { AnyView(Chip(text: dgpuShortName, color: Theme.amber)) }) {
            VStack(alignment: .leading, spacing: 12) {
                // 主数字 + 温度（与 CPU 卡片同一套排版：34pt 圆角数字、右侧温度）
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reported ? Fmt.tridiagonal(gr) : "—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(reported ? Theme.txt : Theme.dim2)
                    Text("%")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim2)
                    Text("GR · 5 秒均值")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.dim2)
                        .padding(.leading, 2)
                    Spacer(minLength: 8)
                    if temp > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("\(Fmt.celsius(temp))℃")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(store.tempColor(temp))
                        .help("NVAccel 上报的 GPU 核心温度（TSENS，PR #323）")
                    }
                }
                .help(dgpuDetailHelp)

                // 曲线固定 0~100：dGPU 空闲时 GR 只有 0.00~0.02，
                // 自适应 Y 轴会把这点噪声拉满整卡高度，跟旁边的「0%」自相矛盾。
                Sparkline(points: store.history["dgpu"] ?? [], color: Theme.amber,
                          maxValue: 100, minValue: 0)
                    .frame(height: 34)

                // 半列宽下四列排不开（每列只剩 100pt，"ENC 视频编码 0.0%" 会挤成两行），
                // 改成 2×2，和「存储」卡片的 FieldGrid 节奏一致。
                GroupTitle(text: "引擎占用", sub: "5 秒均值")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2),
                          spacing: 9) {
                    engineCell("GR", "3D 图形", gr, Theme.amber)
                    engineCell("FB", "显示合成", store.dgpuFbAvg5, Theme.cyan)
                    engineCell("ENC", "视频编码", store.dgpuEncAvg5, Theme.purple)
                    engineCell("DEC", "视频解码", store.dgpuDecAvg5, Theme.green)
                }

                Divider().overlay(Theme.line)
                // 温度不在这里重复 —— 主数字右边已经有一个更醒目的。
                // 3 列 8 项：半列宽下 4 列会把「90 秒峰值」压到换行。
                FieldGrid(rows: [
                    ("风扇", rpm > 0 ? "\(rpm) RPM" : "—"),
                    ("显存", BackendService.string(detail, "VRAM (Total)") ?? "—"),
                    ("链路", BackendService.string(detail, "PCIe Lane Width") ?? "—"),
                    ("Metal", BackendService.string(detail, "Metal Support") ?? "—"),
                    ("设备 ID", BackendService.string(detail, "Device ID") ?? "—"),
                    ("90 秒峰值", peak.map { String(format: "%.0f%%", $0) } ?? "—"),
                    ("均值窗口", "\(store.dgpuWindow) 秒"),
                    ("槽位", BackendService.string(detail, "Slot") ?? "—"),
                ], columns: 3)

                // 核显：和独显共用这张卡，但只占底部一小条（占用率 + 动态显存）。
                // 它和 CPU 同 die，温度看 CPU 卡里的「封装温度」就行，这里不重复。
                Divider().overlay(Theme.line)
                iGPUBlock

                // 只在异常时出现：正常空闲（GR 0% / FB 0.27%）不该再解释一遍
                if let hint = dgpuHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 主数字的 tooltip：半列宽下卡片里放不下的排障信息都收在这里。
    private var dgpuDetailHelp: String {
        let detail = BackendService.dict(dgpuInfo, "detail")
        let dev = BackendService.string(detail, "Device ID") ?? "—"
        let slot = BackendService.string(detail, "Slot") ?? "—"
        return "GR（3D 引擎）最近 5 秒均值 \(Fmt.tridiagonal(store.dgpuUtilAvg5))%，"
             + "15 秒均值 \(Fmt.tridiagonal(store.dgpuUtilAvg15))%，瞬时 \(Fmt.tridiagonal(store.dgpuUtil))%。\n"
             + "数据来自 NVAccel 的 PerformanceStatistics（驱动 2.6.3 每秒采样一次并发布，"
             + "已四舍五入成整数百分比）；均值是本机按拍记的 \(store.dgpuWindow) 秒窗口，"
             + "现有 \(store.dgpuSamples) 拍。\n"
             + "设备 \(dev) · \(slot)"
    }

    /// 单个引擎格子：名称 + 中文说明 + 百分比 + 细条
    private func engineCell(_ key: String, _ label: String,
                            _ v: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(color)
                    .tracking(0.4)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
                Spacer(minLength: 2)
                // 一位小数：FB 恒定 0.3%，取整会变成 0 就看不出这点固定开销了
                Text(String(format: "%.1f%%", v))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.txt)
            }
            MiniBar(value: v / 100, color: color, height: 5)
        }
    }

    /// 异常状态的说明。正常时返回 nil，卡片底部就不会多一行字。
    private var dgpuHint: String? {
        if !store.dgpuAvailable {
            return "未找到 NVAccel 服务 —— 驱动未加载或版本太旧，dGPU 利用率不可用。"
        }
        if !store.dgpuReported {
            return "NVAccel 在，但这一拍没有利用率键：驱动查询失败，或样本超过 5 秒没更新"
                 + "（驱动遇这两种情况会删键，而不是报 0）。稍等或跑个 3D 程序看看。"
        }
        return nil
    }

    /// system_profiler 里 bus 是 PCIe 的那条就是独显
    private var dgpuInfo: [String: Any] {
        store.gpus.first { (BackendService.string($0, "bus") ?? "") == "PCIe" } ?? [:]
    }

    /// 型号简称：`NVIDIA GeForce RTX 2070 Super with Max-Q Design` → `RTX 2070 Super`
    private var dgpuShortName: String {
        let raw = BackendService.string(dgpuInfo, "name") ?? ""
        guard !raw.isEmpty else { return "未识别" }
        return raw
            .replacingOccurrences(of: "NVIDIA GeForce ", with: "")
            .replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: " with Max-Q Design", with: "")
            .trimmingCharacters(in: .whitespaces)
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
    /// 底部一行小字「占空比 · 温度」。上一版把 % 做成 60pt 主数字、环铺满卡片，
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
        case "normal": return thermal ?? "交给 EC"
        case "boost": return "基准模式"
        case "custom": return "手动"
        case "curve": return "曲线"
        default: return thermal ?? "—"
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
            if !cycleAvailable {
                Text("循环次数读不到：本机 ACPI 电池信息没有这个字段（SMC B0CT=0），EC 侧也只有充电阈值 0x07B9。"
                     + "真实值存在电池的 SBS EEPROM，macOS 访问不到 —— 第三方程序（Stats）同样显示 0。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
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
