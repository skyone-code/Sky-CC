import SwiftUI

// MARK: - 性能页（2.7.0 重写）
//
// 3.0.4.5（2026-11-14 用户要求）：只留 CPU / GPU / 内存 / 网络四张卡；
// 存储、电池两卡迁去「概览」页（OverviewView.swift），风扇卡在「概览」页。
//
// 3.0.3.7 起是唯一的监测页（原「概览」页合并进来，见 SystemIdentity.swift）：
// 顶部机型 hero 条 + 每核占用、内存分项、双显卡、每块卷、每块盘 SMART、
// 每路风扇、电池全字段。
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

    /// 性能页 CPU / GPU 两张卡的竖向节奏（2026-11-07 用户要求：两卡逐行对齐、等高）。
    ///
    /// 卡片是 Grid 的一行，外高由 Grid 拉平，但**内部**各行原来各自按内容自然高度排：
    /// 曲线 44/34、每核占用 3 行 vs 引擎占用 2 行、核心温度一格 6 块 vs 驱动遥测一行
    /// 4 格 —— 累加起来「每核占用 / 引擎占用」「核心温度 / 驱动遥测」两处各偏 8pt 左右。
    ///
    /// 现在把「主数字」「曲线」「两个分组」**整段**（连 GroupTitle 一起）都钉死高度，
    /// 内容一律顶端对齐：余量只会留在区块内部，不会再把它下面的行推歪。
    /// 两张卡用的是同一组常量，所以这 4 段分界线必然落在相同的 y 上，卡高自然一致。
    private enum Rhy {
        static let hero: CGFloat = 44     // 34pt 圆角主数字那行
        static let spark: CGFloat = 44    // 曲线
        /// 「每核占用」（3 行 × 4 列）和「引擎占用」（2 行 × 2 列）**整段**。
        /// 连同 GroupTitle 一起钉死：只钉网格的话，标题行本身的微小差异还会往下传。
        static let blockA: CGFloat = 80
        /// 「核心温度」（1 行 6 块）和「驱动遥测」（1 行 6 格，外加可能出现的链路错误行）**整段**。
        static let blockB: CGFloat = 70
    }

    /// `GPU Throttle Mask` 的 bit0：**GPU 空闲**。
    /// 它描述的是「现在为什么跑在低频」，不是「有东西在压频率」，所以卡片里
    /// 一律滤掉这一位再决定要不要报警（见「驱动遥测」段）。掩码本身仍原样保留。
    private static let kThrottleIdleBit = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !backend.kextLoaded { KextBanner() }
                header
                // 3.0.4.5：机型 hero 条已按用户要求迁去「概览」页顶部。
                // 2026-10-26（用户定的版式）：核心温度并进 CPU 卡后，那张卡删掉，
                // 剩下的卡按**实测高度**配对，让每一行的两张尽量一样高（空位最小）。
                //
                // 2026-11-07（用户要求）：风扇卡整体挪到「控制」页（FanRPMCard）。
                // 3.0.4.5（用户要求）：存储 / 电池迁去「概览」页，本页只剩四卡两行。
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        cpuCard.gridEqual()
                        gpuCard.gridEqual()
                    }
                    GridRow {
                        memCard.gridEqual()
                        netCard.gridEqual()
                    }
                }
            }
            .padding(22)
        }

        .onAppear {
            // 2026-11-08（性能）：本页需要 1 秒逐拍刷新，在这里登记「快速轮询」需求；
            // 切到别的页面后自动降到 3 秒。
            // （3.0.4.5：实时转速租约随风扇卡搬到「概览」页，本页不再声明。）
            store.demandFast(true)
            // 2026-11-14（用户反馈）：Wi-Fi SSID 被 macOS 14 的定位服务门控，
            // 系统设置里不会主动出现本 app 的条目 —— 进页申请一次，系统弹授权框。
            LocationPermission.shared.requestIfNeeded()
        }
        .onDisappear {
            store.demandFast(false)
        }
        // 授权刚批下来：立即拉一拍快照，SSID 下一秒就出现在网络卡里
        .onReceive(NotificationCenter.default.publisher(for: .locationAuthChanged)) { _ in
            Task { await store.refresh() }
        }
    }

    // MARK: 页头

    private var header: some View {
        PageHeader(
            title: "性能",
            sub: "每 1 秒刷新 · 一次快照取全",
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
                    // 2026-11-08（用户要求）：核显利用率提到标题行、紧跟「CPU」——
                    // 它原来在卡片最下方那条摘要里，而那条已改成「显存占用」。
                    badge: { AnyView(igpuBadge) },
                    // 2026-11-07（用户要求）：型号并进右上角胶囊 —— 现在是
                    // 「i7-9750H @ 2.60GHz · 6C / 12T」。原来主数字右侧那格
                    // 腾给了封装温度 / 封装功耗。
                    // 2026-11-08（用户要求）：顺序对调 —— 型号在前、核心数在后，
                    // 读起来先知道「什么 CPU」再知道「几核几线程」。
                    trailing: { AnyView(Chip(text: "\(cpuBrandClean) · \(coreNote)",
                                             color: Theme.blue)) }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", usage))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.txt)
                    Text("%").font(.system(size: 13)).foregroundStyle(Theme.dim2)
                    // 2026-11-07（用户要求）：底部「1m / 5m / 15m / 逻辑核数」整行撤掉，
                    // 三条负载合并成这一串小字跟在百分比后面（样式对齐 GPU 卡那句
                    // 「GR · 5 秒均值」）。顺序仍是 1 分钟 / 5 分钟 / 15 分钟，
                    // 鼠标悬停能看到展开说明。
                    Text("负载 \(loadText(load))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.dim2)
                        .padding(.leading, 2)
                        .help(loadHelp(load))
                    Spacer(minLength: 8)
                    // 2026-11-07（用户要求）：封装温度 / 封装功耗从底部那行挪上来，
                    // 顶掉原来的型号文字。样式照搬 GPU 卡主数字右侧那个温度
                    // （10.5pt 图标 + 15pt 半粗等宽数字 + 按温度着色）。
                    // 型号改挂到右上角胶囊里（见 Card 的 trailing）。
                    HStack(spacing: 10) {
                        if store.cpuTemp > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "thermometer.medium")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(Fmt.celsius(store.cpuTemp))℃")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(store.tempColor(store.cpuTemp))
                            .help(packageTempsHelp)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(Fmt.watts(store.cpuWatts))
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(store.cpuWatts == nil
                                         ? Theme.dim2
                                         : Theme.amber.opacity(store.cpuWattsStale ? 0.6 : 1))
                        .help(powerHelp)
                    }
                }
                .frame(height: Rhy.hero, alignment: .leading)
                // 固定 0~100：自适应在空闲时会把 1~2% 的抖动拉成满幅，看着像满载。
                // 百分比指标本来就该有绝对刻度（内存那条曲线一直是这么画的）。
                Sparkline(points: store.history["cpu"] ?? [], color: Theme.blue,
                          maxValue: 100, minValue: 0)
                    .frame(height: Rhy.spark)

                if !cores.isEmpty {
                    // 整段（标题 + 网格）钉死到 Rhy.blockA —— 见 Rhy 的注释。
                    VStack(alignment: .leading, spacing: 6) {
                        GroupTitle(text: "每核占用", sub: "\(cores.count) 个逻辑核")
                        // 2.7.2：3 列改 4 列（12 核正好 3 行，卡片矮一截）
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                                  spacing: 7) {
                            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                                coreRow(i, v)
                            }
                        }
                    }
                    .frame(height: Rhy.blockA, alignment: .top)
                }

                // 2026-10-26（用户要求）：原「CPU 核心温度」卡片整块并进来，那张卡删掉。
                // 占用和温度本来就是同一个东西的两个面，分两张卡反而要来回看。
                // 6 个物理核（SMC TC1C~TC6C）一排 6 格，跟上面 12 个逻辑核的 4 列错开，
                // 一眼能看出「6 核 12 线程」这个事实。
                //
                // 2026-11-07（用户要求两卡逐行对齐）：这一行上面补一条分隔线 ——
                // GPU 卡的「驱动遥测」前面本来就有，补齐后两卡结构完全同构
                // （内容 · 线 · 第 2 组 · 线 · 底部摘要条）。
                Divider().overlay(Theme.line)
                if !coreTemps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
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
                    .frame(height: Rhy.blockB, alignment: .top)
                }

                // 2026-11-07（用户要求，第二次）：原来的「1m / 5m / 15m / 逻辑核数」
                // 四格整行撤掉 —— 三条负载已并成主数字后面的小字（见上）。
                // 这一行连同它上面的分隔线一起去掉，逻辑核数在右上角胶囊的
                // 「6C / 12T」里本来就有，不必重复。

                // 2026-11-07（用户要求）：核显摘要从 GPU 卡底部整体挪到 CPU 卡最下方
                // —— 核显和 CPU 同 die，放一起更合理。
                // 2026-11-08（用户要求，第三次）：Divider 到摘要行 12pt；
                // **不再**压缩卡片底部内边距 —— 上一版把底部压到 12pt 后这条
                // 几乎贴住卡片下沿（看着快出血了），所以 Card 的 `bottomGap/`
                // `bottomInset` 参数整个撤掉，卡片回到四边 16 的统一内边距
                // （内容最后一行到卡片下沿的实际观感是 28pt，因为尾部 Spacer 前
                // 还有 VStack 的 12pt 段间距）。
                VStack(alignment: .leading, spacing: 12) {
                    Divider().overlay(Theme.line)
                    iGPUBlock
                }
            }
        }
    }

    /// 独显摘要条：**显存占用**一条（2026-11-08 用户要求，第三次改版）。
    ///
    /// 版式沿革：
    /// - 2026-11-05：照搬 iGPU 那条的结构，条 = GR 利用率（与上方主数字同源）；
    /// - 2026-11-07：微调对齐，条 + 百分比 + 显存两行小字；
    /// - **2026-11-08（现在）**：条改画**显存占用**占比、去掉条旁百分比数字、
    ///   去掉「占用 x.x%」那行小字 —— 用户的原话是「看百分比条就行」。
    ///   理由也站得住：GR 利用率在上半张已经是 34pt 的主数字，这里再画一遍纯属重复；
    ///   而显存占用在卡片里原本只有一串数字，没有比例感。
    ///   右边只留「显存 33 MB / 8.6 GB」一行，与条同一行右对齐。
    private var dGPUBlock: some View {
        let vramText = store.dgpuVramText.map { "显存 \($0)" } ?? "显存 —"
        let vramPct = store.dgpuVramPct
        // 条恒给：没有数据时画空条（0），不隐藏 —— 摘要条的位置不能忽有忽无。
        // 条与文字紧贴，中间不加 Spacer，免得 8 GB 只为 33 MB 时中间空出一大段。
        return HStack(spacing: 7) {
            Text("dGPU")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .tracking(1.0)
            Text(dgpuShortName)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
            Spacer(minLength: 6)
            MiniBar(value: (vramPct ?? 0) / 100, color: Theme.amber, height: 6)
                .frame(width: 64)
                .help(vramPct.map { String(format: "显存占用 %.1f%%（条的比例）", $0) }
                      ?? "显存占用未知 —— 驱动这一拍没发布 VRAM 键")
            // 2026-11-08（用户要求补回）：条旁的百分比数字 —— 上一版按「看条就行」
            // 撤掉过，但光靠这么短一条看不准，还是把数字放回来。
            Text(vramPct.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(vramPct == nil ? Theme.dim2 : Theme.txt)
                .fixedSize()
                .help("显存占用百分比（= 条的比例，口径：heap − free）")
            Text(vramText)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 3)
                .help("显存占用（驱动遥测 v3，FB_GET_INFO_V2 口径：heap − free）")
        }
    }

    /// 核显摘要：**显存占用**一条（2026-11-08 用户要求，与 dGPU 那条改成同款）。
    ///
    /// 版式沿革：
    /// - 2026-11-07：从 GPU 卡底部整体挪到 CPU 卡最下方（核显与 CPU 同 die）；
    /// - **2026-11-08（现在）**：与 dGPU 那条统一 —— 条改画显存占用、去掉条旁百分比
    ///   数字、去掉「占用 x.x%」小字，只留「显存 1.2 GB / 16.00 GB」一行。
    ///   利用率没有丢：它被提到 **CPU 卡标题行**（见 `igpuBadge`），
    ///   因为这一条现在讲的是显存，不再是利用率。
    ///
    /// iGPU 没有独立显存：总量是动态上限（`VRAM (Dynamic, Max)`），
    /// 当前占用来自 IOAccelerator 的 `In use system memory`。
    private var iGPUBlock: some View {
        let g = igpuInfo
        let detail = BackendService.dict(g, "detail")
        let name = BackendService.string(g, "name") ?? "Intel GPU"
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
        // 显存占用率：used / 动态上限。上限来自 system_profiler 的
        // 「VRAM (Dynamic, Max)」，是 "16.00 GB" 这种字符串，得解析回字节。
        let vramPct: Double? = {
            guard let cap, let capBytes = Self.parseSize(cap), let u = used, u > 0 else { return nil }
            return min(100, u / Double(capBytes) * 100)
        }()

        // 结构与 dGPUBlock 逐字一致：名称在左 → Spacer → 条 → 显存单行贴右。
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
            MiniBar(value: (vramPct ?? 0) / 100, color: Theme.cyan, height: 6)
                .frame(width: 64)

                .help(vramPct.map { String(format: "显存占用 %.1f%%（条的比例）", $0) }
                      ?? "显存占用未知 —— 缺少「VRAM (Dynamic, Max)」或当前占用")
            // 2026-11-08（用户要求补回）：与 dGPU 那条同款 —— 条旁给百分比数字。
            Text(vramPct.map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(vramPct == nil ? Theme.dim2 : Theme.txt)
                .fixedSize()
                .help("显存占用百分比（= 条的比例；分母是 VRAM 动态上限）")
            // 显存贴最右且不允许被截断 —— 型号名可以缩，这个数字不能
            Text(vramText)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Theme.dim2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 3)
                .help("核显显存 = 系统内存动态分配（上限来自 VRAM (Dynamic, Max)），"
                      + "不是独立显存")
        }
    }

    /// CPU 卡标题行上的「iGPU 利用率」小标（2026-11-08 用户要求）。
    ///
    /// 在这个改动之前，核显利用率是 CPU 卡最下方那条摘要里的一个百分比数字；
    /// 那条改成「显存占用」之后，利用率就没地方放了 —— 用户要求提到标题旁边，
    /// 正好与 GPU 卡标题行的降频徽标形成对称（都用 `Card.badge`）。
    ///
    /// 数据源没有变，仍是 overview 的 `gpu_usage`（IOAccelerator 的
    /// `Device Utilization %`，由 Intel 核显驱动每秒更新）。
    @ViewBuilder
    private var igpuBadge: some View {
        let util = BackendService.double(store.overview, "gpu_usage")
        HStack(spacing: 4) {
            Text("iGPU 利用率")
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim2)
            Text(util.map { "\(Fmt.tridiagonal($0))%" } ?? "—")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(util == nil ? Theme.dim2 : Theme.cyan)
        }
        .fixedSize()
        .help("核显 3D 引擎占用（\(igpuName)），来自 IOAccelerator 的 Device Utilization %；"
              + "与整页一起每秒刷新。")
    }

    /// "16.00 GB" / "1536 MB" 这类容量字符串 → 字节数（system_profiler 的
    /// VRAM 口径，十进制单位，跟 Fmt.bytes 一致）。
    private static func parseSize(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.filter { "0123456789.".contains($0) }
        guard let num = Double(digits), num > 0 else { return nil }
        if t.uppercased().contains("TB") { return Int(num * 1e12) }
        if t.uppercased().contains("GB") { return Int(num * 1e9) }
        if t.uppercased().contains("MB") { return Int(num * 1e6) }
        if t.uppercased().contains("KB") { return Int(num * 1e3) }
        return Int(num)
    }

    /// system_profiler 里 bus 不是 PCIe 的那条就是核显（核显没有 Bus 字段，
    /// 只有 Connection Type: Internal）
    private var igpuInfo: [String: Any] {
        store.gpus.first { (BackendService.string($0, "bus") ?? "") != "PCIe" } ?? [:]
    }

    /// 核显名（动态取自 system_profiler，tooltip 不再写死型号）
    private var igpuName: String {
        let n = BackendService.string(igpuInfo, "name") ?? ""
        return n.isEmpty ? "核显" : n
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

    /// 封装功耗的 tooltip。
    /// PCPT 在 VirtualSMC 里是「能量差 ÷ 时间」，读太密那一拍就是 0（实测 1 秒间隔
    /// 命中率约 65%）。读 0 时用 10 秒内的上一拍真值顶上并打 stale 标记，
    /// 此时数字会降到 60% 不透明度 —— 数据是真的，只是不是这一秒的。
    private var powerHelp: String {
        let base = "CPU 封装功耗（SMC PCPT）"
        guard store.cpuWattsStale else {
            return base + "\nVSM C 的功率键是「能量差 ÷ 时间」算的；"
                + "这一拍取到了新值。"
        }
        let age = Double(store.cpuWattsAgeMs) / 1000
        return base + "\n这一拍 SMC 没算出新值（1 秒内能量增量为 0），"
            + String(format: "显示的是 %.1f 秒前的实测值。", age)
            + "数字会降为 60% 不透明度以作区分。"
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

    /// 2026-10-26（用户定的版式）：卡片改回「GPU」，只放独显。
    ///
    /// 版式几经反复，记录一下免得来回改：
    /// - 2026-10-26 把 iGPU 塞进 CPU 卡（理由：和 CPU 同 die），后因「CPU 卡越堆越杂」撤回；
    /// - 现在（2026-11-07）按用户要求又挪回 CPU 卡最下方 —— 这次 CPU 卡底部腾空了
    ///   （封装温度/功耗上移到主数字旁、「负载」拆成三格），放一条核显摘要不显挤。
    /// 本卡目前是：GR 大数字 + 曲线 + 四引擎 + 驱动遥测 + dGPU 摘要条。
    private var gpuCard: some View {
        let reported = store.dgpuReported
        // 2026-11-07（用户要求）：主数字改用瞬时值 —— 整页 1 秒刷新，
        // 只有这一项是 5 秒均值的话看着像卡住。
        let gr = store.dgpuUtil
        let temp = store.gpuTemp
        let edge = store.gpuEdgeTemp
        // 2026-11-08（用户要求）：功耗接回主数字行。主值用驱动自算的 8 拍环均值
        // （`GPU Power Avg(W)`）—— 固件瞬时值在 6 W / 115 W 之间硬跳，1 秒刷新会闪；
        // 瞬时值与功耗墙都收进 tooltip。
        let powerAvg = store.dgpuPowerAvg
        // 2026-11-07（用户要求）：核心温度 + 核心边缘温度并排，用 / 分隔。
        // 核心 = RUSD 固件读数（`GPU Core Temperature(C)`），
        // 边缘 = NVAccel 直读 TSENS 0x20460（`Temperature(C)`），两个不同测点，
        // 本机空闲实测 44 / 32℃（2026-11-08，BOOST=0 之后；此前 60 / 47℃）。
        // 只有其中一个时退化成单值，都拿不到才是「—」。
        let tempText: String = {
            switch (temp > 0, edge > 0) {
            case (true, true):  return "\(Fmt.celsius(temp))℃ / \(Fmt.celsius(edge))℃"
            case (true, false): return "\(Fmt.celsius(temp))℃"
            case (false, true): return "\(Fmt.celsius(edge))℃"
            default:            return "—"
            }
        }()

        return Card(title: "GPU",
                    // 2026-11-08（用户要求）：降频提示从「驱动遥测」网格底部挪到
                    // 标题行、紧跟「GPU」之后 —— 它解释的是整张卡当前的状态，
                    // 挂在遥测网格下面会被误读成「核心频率」那一格的注释。
                    badge: { AnyView(throttleBadge) },
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
                    Text("GR · 1 秒")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.dim2)
                        .padding(.leading, 2)
                    Spacer(minLength: 8)
                    // 2026-11-08（用户要求）：温度 + 功耗并排，样式与 CPU 卡那一对
                    // （封装温度 / 封装功耗）逐字一致 —— 10pt 间距、10.5pt 图标、
                    // 15pt 半粗等宽数字，两卡主数字行因此完全同构。
                    HStack(spacing: 10) {
                        if temp > 0 || edge > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "thermometer.medium")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(tempText)
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            }
                            // 取两者较高的那个决定颜色 —— 报警该看的是最热的点
                            .foregroundStyle(store.tempColor(max(temp, edge)))
                            .help("核心温度（RUSD 固件）/ 核心边缘温度（TSENS 0x20460）")
                        }
                        if let pw = powerAvg {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("\(Int(pw.rounded())) W")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            }
                            // 2026-11-08（用户要求）：与 CPU 卡的封装功耗同色 —— 固定琥珀，
                            // 不再按占墙比例分档。两卡同一指标必须同一颜色，否则并排看
                            // 会以为 GPU 那个「白」是某种告警等级。
                            .foregroundStyle(Theme.amber)
                            .help(gpuPowerHelp)
                        }
                    }
                }
                .help(dgpuDetailHelp)
                .frame(height: Rhy.hero, alignment: .leading)

                // 曲线固定 0~100：dGPU 空闲时 GR 只有 0.00~0.02，
                // 自适应 Y 轴会把这点噪声拉满整卡高度，跟旁边的「0%」自相矛盾。
                Sparkline(points: store.history["dgpu"] ?? [], color: Theme.amber,
                          maxValue: 100, minValue: 0)
                    .frame(height: Rhy.spark)

                // 半列宽下四列排不开（每列只剩 100pt，"ENC 视频编码 0.0%" 会挤成两行），
                // 改成 2×2，和「存储」卡片的 FieldGrid 节奏一致。
                // 与 CPU 卡的「每核占用」整段同高（Rhy.blockA）：那边 3 行核心、这边
                // 2 行引擎，自然高度差几 pt，钉死后下面「驱动遥测 / 核心温度」才齐。
                VStack(alignment: .leading, spacing: 6) {
                    GroupTitle(text: "引擎占用", sub: "1 秒")
                    // 半列宽四列排不开，2×2
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2),
                              spacing: 9) {
                        engineCell("GR", "3D 图形", gr, Theme.amber)
                        engineCell("FB", "显示合成", store.dgpuFb, Theme.cyan)
                        engineCell("ENC", "视频编码", store.dgpuEnc, Theme.purple)
                        engineCell("DEC", "视频解码", store.dgpuDec, Theme.green)
                    }
                }
                .frame(height: Rhy.blockA, alignment: .top)

                // 2026-11-05（用户要求）：撤掉字段网格（风扇/显存/链路/Metal/设备 ID/
                // 90 秒峰值/均值窗口/槽位）——排障类的静态信息看主数字的 tooltip 就够，
                // 卡片留给有变化的数据。温度不在这里重复 —— 主数字右边已经有一个更醒目的。

                // 驱动新发布的传感器（2026-11-03 接入）：核心/显存频率、P 级、功耗墙。
                // 这些键驱动有才显示，没有就自动「—」。
                Divider().overlay(Theme.line)
                // 整段（标题 + 网格）钉死到 Rhy.blockB，与 CPU 卡「核心温度」整段同高
                // —— 结构完全对称，底部摘要条才对得齐。
                // 2026-11-05（用户要求）：驱动遥测改 3 列。
                // 2026-11-07（用户要求）：撤掉瞬时功耗 / PCIe 链路后剩 4 项，改成 4 列一行。
                // 2026-11-08：降频提示整段挪到卡片标题行（`throttleBadge`），
                // 这里只剩标题 + 网格。
                VStack(alignment: .leading, spacing: 12) {
                    GroupTitle(text: "驱动遥测", sub: "NVAccel PerformanceStatistics")
                    VStack(alignment: .leading, spacing: 4) {
                        // 2026-11-08（用户要求）：6 项一行，不分行。
                        FieldGrid(rows: telemetryRows, columns: 6)
                        // 链路错误只在计数非零时出现（异常状态）。值是一串
                        // 「行编码 3 · CRC 1 · NAK 2」，塞进 1/6 宽的格子会被截断，
                        // 所以让它自占一行。
                        if let err = store.dgpuPcieErrorText {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.amber)
                                Text("链路错误：\(err)")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Theme.amber)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .frame(height: Rhy.blockB, alignment: .top)

                // 底部摘要条：只留 dGPU（样式与 iGPU 同款，见 dGPUBlock 注释）。
                // iGPU 那条已在 2026-11-07 按用户要求挪到 CPU 卡最下方。
                // 2026-11-08：与 CPU 卡逐字一致 —— Divider→行 12pt；卡片底部
                // 不再单独压缩（参数已撤，回到四边 16 的统一内边距）。
                VStack(alignment: .leading, spacing: 12) {
                    Divider().overlay(Theme.line)
                    dGPUBlock
                }

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

    /// GPU 卡标题行上的降频徽标（2026-11-08 用户要求：从「驱动遥测」网格底部
    /// 挪到标题后面，紧跟「GPU」两个字）。
    ///
    /// 为什么挪：这行原来排在遥测网格下面，正好落在「核心频率 300 MHz」那一格的正下方，
    /// 看着像在解释那个频率值。它其实是在解释**整张卡当前为什么跑在这个状态**。
    ///
    /// 为什么要把 bit0 滤掉：`GPU Throttle Mask` 的 **bit0 = GPU 空闲**，这不是降频
    /// 原因而是正常状态 —— P8 idle 时它恒置（本机实测 mask=1、GR 0%、功耗 5~6 W）。
    /// 不过滤的话正常空闲也会亮黄三角，看着像故障。滤掉后只有真降频原因
    /// （应用限频 / 功耗墙 / 温度保护 / 主板限制 …）才会出现。
    @ViewBuilder
    private var throttleBadge: some View {
        if let thr = store.dgpuThrottleMask, (thr & ~Self.kThrottleIdleBit) != 0 {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("降频：\(throttleText(thr & ~Self.kThrottleIdleBit))")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.amber)
            .fixedSize()
            .help("GPU Throttle Mask = 0x\(String(thr, radix: 16))"
                  + "（bit0「GPU 空闲」已滤掉，空闲不算降频）\n"
                  + "当前：\(throttleText(thr & ~Self.kThrottleIdleBit))")
        }
    }

    /// 「驱动遥测」网格的行：**固定 6 项、一行 6 列**（2026-11-08 用户要求）。
    ///
    /// 顺序按「先看什么」排：核心频率 → 显存频率 → P 级 → 功耗墙 → 显存控制器 → JPEG。
    ///
    /// 显存控制器 / JPEG 引擎原来是「有值才出现」的条件格，但这两个键在本机（TU104）
    /// 固件上恒为 0（实测 3D 满载 GR 98%、1605 MHz 时仍为 0，来自 `perfDevUtil` 那组），
    /// 条件格等于永远不出现。改成常显之后至少能看出「有这一项、它现在是 0」，
    /// 而不是让人以为卡片根本没读这两个数。
    ///
    /// 链路错误**不进网格**：它的值是一串「行编码 3 · CRC 1 · NAK 2」，塞进 1/6 宽的
    /// 格子会被截断；而且它只在计数非零时才该出现，放网格外单独一行更合适（见视图）。
    private var telemetryRows: [(String, String)] {
        [
            ("核心频率", store.dgpuCoreMHz.map { "\(Int($0)) MHz" } ?? "—"),
            ("显存频率", store.dgpuMemMHz.map { "\(Int($0)) MHz" } ?? "—"),
            // 显存占用挪到底部 dGPU 摘要条（与 iGPU 同款样式，2026-11-05）。
            // 显存温度 / 频率上限已按用户要求撤下（2026-11-05）：显存温度
            // 空闲时基本不动，频率上限是静态值，都不值得占一格。
            ("P 级", pstateText(store.dgpuPState)),
            ("功耗墙", store.dgpuPowerLimit.map { "\(Int($0)) W" } ?? "—"),
            ("显存控制器", store.dgpuMemCtrlPct.map { "\(Int($0))%" } ?? "—"),
            ("JPEG 引擎", store.dgpuJpgPct.map { "\(Int($0))%" } ?? "—"),
        ]
    }

    /// 主数字的 tooltip：半列宽下卡片里放不下的排障信息都收在这里。
    private var dgpuDetailHelp: String {
        let detail = BackendService.dict(dgpuInfo, "detail")
        let dev = BackendService.string(detail, "Device ID") ?? "—"
        let slot = BackendService.string(detail, "Slot") ?? "—"
        return "GR（3D 引擎）当前 \(Fmt.tridiagonal(store.dgpuUtil))%，"
             + "5 秒均值 \(Fmt.tridiagonal(store.dgpuUtilAvg5))%，"
             + "15 秒均值 \(Fmt.tridiagonal(store.dgpuUtilAvg15))%。\n"
             + "卡片上显示的是瞬时值，与整页 1 秒刷新同步。\n"
             + "数据来自 NVAccel 的 PerformanceStatistics（驱动 2.6.3 每秒采样一次并发布，"
             + "已四舍五入成整数百分比）；均值是本机按拍记的 \(store.dgpuWindow) 秒窗口，"
             + "现有 \(store.dgpuSamples) 拍。\n"
             // 2026-11-07：这两项从「驱动遥测」网格里撤下（用户要求腾位置），
             // 数据没丢，收进这里 —— 排障时仍能查到。
             // 2026-11-08：功耗已经回到主数字行（显示环均值），这里补齐三个值。
             + "功耗 均值 \(wattText(store.dgpuPowerAvg))"
             + " · 瞬时 \(wattText(store.dgpuPowerInstant))"
             + " · 墙 \(wattText(store.dgpuPowerLimit))\n"
             + "链路 \(store.dgpuPcieLinkText ?? "—")\n"
             + "设备 \(dev) · \(slot)"
    }

    /// GPU 功耗的 tooltip（主数字行那个「⚡ N W」）。
    ///
    /// 主值是**驱动自算的 8 拍环均值**，不是固件的平均值 —— 本机固件不填 RUSD 的
    /// 平均分区（时间戳 `RUSD_TIMESTAMP_INVALID`），均值是驱动 1 Hz 采样自己攒的。
    private var gpuPowerHelp: String {
        let pct: String = {
            guard let a = store.dgpuPowerAvg, let l = store.dgpuPowerLimit, l > 1 else { return "—" }
            return String(format: "%.0f%%", min(999, a / l * 100))
        }()
        return "dGPU 功耗（RUSD 功率块）\n"
             + "主数字 \(wattText(store.dgpuPowerAvg))"
             + "　驱动自算的 8 拍（≈8 秒）环均值，1 秒刷新下不跳\n"
             + "瞬时 \(wattText(store.dgpuPowerInstant))"
             + " · 功耗墙 \(wattText(store.dgpuPowerLimit))（已用 \(pct)）\n"
             + "本机固件只填瞬时采样，平均分区时间戳无效，"
             + "所以均值由驱动每秒采样后自己平均；采样断流时驱动清窗并撤键，显示回到「—」。\n"
             + "实测参考：空闲约 6 W，满载顶墙。"
    }

    /// 瓦数显示：整数 + W，取不到给「—」。
    /// 驱动侧发布的就是四舍五入后的整数瓦，这里不再加小数（省横向空间）。
    private func wattText(_ w: Double?) -> String {
        guard let w else { return "—" }
        return "\(Int(w.rounded())) W"
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
    /// 独显短名：去厂商标识，但**保留** "with Max-Q"（2026-11-07 用户要求：
    /// 全名是 RTX 2070 Super with Max-Q，不是 RTX 2070 Super —— 这是两张不同的卡，
    /// Max-Q 版本功耗墙 115W，标准版 175W，省掉就没区别了）。
    /// system_profiler 给的是 "with Max-Q Design"，尾巴那个 Design 是苹果加的，
    /// 缩成 "with Max-Q" 更短且与官方命名一致。
    private var dgpuShortName: String {
        let raw = BackendService.string(dgpuInfo, "name") ?? ""
        guard !raw.isEmpty else { return "未识别" }
        return raw
            .replacingOccurrences(of: "NVIDIA GeForce ", with: "")
            .replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: " with Max-Q Design", with: " with Max-Q")
            .trimmingCharacters(in: .whitespaces)
    }

    /// P 级位掩码 → 可读名称（驱动按「越低位越快」定义：0x1=P0 满速 … 0x1000=P12 最低）。
    /// 与 GPU传感器.command 脚本里的 pstate_name 同一张表。
    private func pstateText(_ mask: Int?) -> String {
        guard let m = mask else { return "—" }
        switch m {
        case 0: return "—"
        case 0x1: return "P0 满速"
        case 0x2: return "P1"
        case 0x4: return "P2"
        case 0x8: return "P3"
        case 0x10: return "P4"
        case 0x20: return "P5"
        case 0x40: return "P6"
        case 0x80: return "P7"
        case 0x100: return "P8"
        case 0x200: return "P9"
        case 0x400: return "P10"
        case 0x800: return "P11"
        case 0x1000: return "P12 最低"
        default: return String(format: "0x%X", m)
        }
    }

    /// 降频原因位掩码 → 可读说明（与脚本里的 throttle_name 同一张表）。
    ///
    /// 位序照 RM 的 `NV2080_CTRL_PERF_CLK_THROTTLE_REASON_*`：0=GPU 空闲、
    /// 1=应用限频、2=软件功耗墙、3=硬件降频、4=同步加速、5=软件温度保护、
    /// 6=硬件温度保护、7=硬件功耗刹车、8=显示时钟、9=主板限制、10=可靠性。
    ///
    /// 表里保留 bit0（"GPU 空闲"）是为了函数本身完整 —— 调用方（卡片告警）
    /// 会先滤掉它再传进来，因为空闲不是降频。
    private func throttleText(_ mask: Int) -> String {
        let bits: [(Int, String)] = [
            (0, "GPU 空闲"), (1, "应用限频"), (2, "软件功耗墙"), (3, "硬件降频"),
            (4, "同步加速"), (5, "软件温度保护"), (6, "硬件温度保护"), (7, "硬件功耗刹车"),
            (8, "显示时钟"), (9, "主板限制"), (10, "可靠性"),
        ]
        var out: [String] = []
        for (b, name) in bits where ((mask >> b) & 1) == 1 {
            out.append(name)
        }
        return out.isEmpty ? "未知" : out.joined(separator: " / ")
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
                Text(ssid ?? (on ? (LocationPermission.shared.granted
                                       ? "已关联（SSID 读取失败）"
                                       : "SSID 需定位授权 · 已在后台申请弹窗")
                                     : "Wi-Fi 已关闭"))
                    .help(on && ssid == nil
                          ? "macOS 14 起 SSID 属于隐私数据，需要定位服务授权；\n"
                            + "弹出授权框后选择「允许」，SSID 即可显示。\n"
                            + "若弹窗已消失：系统设置 → 隐私与安全性 → 定位服务 → Sky CC"
                          : "")
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

    /// 三条负载拼成一串：4.45 / 5.15 / 5.00（依次 1、5、15 分钟）。
    /// 2026-11-07（第二次）：从「三格各取一项」改回拼一串 —— 底部那行撤了，
    /// 这三个数整体挪到主数字旁边当小字。
    private func loadText(_ load: [Double]) -> String {
        guard !load.isEmpty else { return "—" }
        return load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    /// 那一串小字的悬停说明：补上「哪个数是几分钟」和「单核口径」。
    private func loadHelp(_ load: [Double]) -> String {
        guard load.count >= 3 else { return "系统负载（1 / 5 / 15 分钟均值）" }
        return "系统负载均值（load average），不是 CPU 占用率。\n"
            + "1 分钟 \(String(format: "%.2f", load[0]))　"
            + "5 分钟 \(String(format: "%.2f", load[1]))　"
            + "15 分钟 \(String(format: "%.2f", load[2]))\n"
            + "口径：可运行 + 不可中断的进程数，4 核满载约等于 4.00。"
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
