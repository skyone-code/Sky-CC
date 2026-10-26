import SwiftUI
import AppKit

// MARK: - 概览页（2.7.0 新增，替代原「仪表盘」）
//
// 定位：一屏看全 —— 这台机器是谁、现在什么状态、系统跑得怎么样。
// 与「性能」页的分工：
//   · 概览 = 6 个关键指标的即时值 + 90 秒曲线 + 设备/系统身份
//   · 性能 = CPU/内存/GPU/磁盘/网络/电池/风扇 的逐项深挖（每核、每卷、每个传感器）
//
// 所有数字都来自 MonitorStore 的同一份 /api/snapshot（1 秒一次、一次 XPC），
// 页面自己只在 .task 里跑一次 system_profiler 拿序列号与内存条（不参与轮询）。

struct OverviewView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore

    /// system_profiler 一次性探测（序列号 / 内存条），nil = 还没读到
    @State private var serial: String?
    @State private var dimms: [[String: String]] = []

    /// 硬盘温度看哪一块盘（2.7.6）：空 = 自动（首块 NVMe），否则是 bsd 名（disk0 / disk1）
    @AppStorage("mc.overview.diskTarget") private var diskTarget: String = ""
    /// GPU 使用率看哪颗 GPU（2.7.6）：igpu = 核显（IOAccelerator），dgpu = 独显（NVAccel RM）
    @AppStorage("mc.overview.gpuTarget") private var gpuTarget: String = "igpu"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !backend.kextLoaded { KextBanner() }
                header
                hero
                kpiGrid
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        deviceCard.gridEqual()
                        machineCard.gridEqual()
                    }
                    GridRow {
                        osCard.gridEqual().gridCellColumns(2)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.bg)
        .task { await probe() }
        .onAppear {
            // 概览页只有把 KPI 切到「独显」时才需要 1 秒一次查 NVAccel；
            // 默认看核显，那一套走 IOAccelerator，不碰 RM 通道。
            if gpuTarget == "dgpu" { store.demandDgpu(true) }
        }
        .onDisappear {
            // 只释放自己真正持有过的那一份，否则会把性能页的登记一起减掉
            if gpuTarget == "dgpu" { store.demandDgpu(false) }
        }
        .onChange(of: gpuTarget) { old, new in
            // 页面还在、只是换了目标：按 old → new 精确增减，不能只加不减
            if old == "dgpu" { store.demandDgpu(false) }
            if new == "dgpu" { store.demandDgpu(true) }
        }
    }

    // MARK: 头部

    private var header: some View {
        PageHeader(
            title: "概览",
            sub: "设备身份 · 关键指标 · 系统状态",
            trailing: AnyView(
                LiveBadge(connected: store.connected,
                          updatedAt: store.updatedAt,
                          ms: store.snapshotMs)
            ))
    }

    // MARK: 头图：机型 + 系统 + 四个状态量

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            // 左侧图标块：渐变底 + 白色 Mac 轮廓
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 66, height: 66)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(machineName)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.txt)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: macOSFull, color: Theme.blue)
                    Chip(text: modelID, color: Theme.dim)
                    Chip(text: store.connected ? "后台服务在线" : "后台服务离线",
                         color: store.connected ? Theme.green : Theme.red,
                         filled: !store.connected)
                }
                Text(cpuBrandClean + " · " + memLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 0) {
                heroStat("运行时间", compactUptime(BackendService.double(store.overview, "uptime") ?? 0), "clock")
                heroDivider
                heroStat("进程", "\(BackendService.int(store.overview, "process_count") ?? 0)", "list.bullet")
                heroDivider
                heroStat("热压", thermalText, "thermometer.medium")
                heroDivider
                heroStat("电源", powerModeText, "bolt")
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    private var heroDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 30).padding(.horizontal, 14)
    }

    private func heroStat(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(Theme.dim2)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
        }
    }

    // MARK: 六个关键指标（带 90 秒曲线）

    private var kpiGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        return LazyVGrid(columns: cols, spacing: 14) {
            KPICard(label: "CPU 使用率",
                    value: Fmt.tridiagonal(BackendService.double(store.overview, "cpu_usage")),
                    unit: "%",
                    icon: "cpu",
                    tint: Theme.blue,
                    series: store.history["cpu"] ?? [],
                    seriesMax: 100, seriesMin: 0,
                    note: coreNote)
            KPICard(label: "CPU 温度",
                    value: Fmt.celsius(store.cpuTemp > 0 ? store.cpuTemp : nil),
                    unit: "℃",
                    icon: "thermometer.medium",
                    tint: store.tempColor(store.cpuTemp),
                    series: store.history["cpuTemp"] ?? [],
                    note: "封装传感器 TC0P")
            KPICard(label: "内存",
                    value: Fmt.tridiagonal(BackendService.double(store.memory, "percent")),
                    unit: "%",
                    icon: "memorychip",
                    tint: Theme.purple,
                    series: store.history["mem"] ?? [],
                    note: memLine)
            KPICard(label: "GPU 使用率",
                    value: Fmt.tridiagonal(gpuUsageValue),
                    unit: "%",
                    icon: "display",
                    tint: Theme.cyan,
                    series: gpuUsageSeries,
                    // 必须固定 0~100：dGPU 空闲时 GR 只有 0.00~0.02（实测），
                    // 自适应会把这点噪声画成满幅锯齿，跟旁边的「0%」自相矛盾。
                    seriesMax: 100, seriesMin: 0,
                    note: gpuUsageNote,
                    accessory: AnyView(gpuPicker))
                .help(gpuUsageHelp)
            KPICard(label: "GPU 温度",
                    value: Fmt.celsius(store.gpuTemp > 0 ? store.gpuTemp : nil),
                    unit: "℃",
                    icon: "thermometer.high",
                    tint: store.tempColor(store.gpuTemp),
                    series: store.history["gpuTemp"] ?? [],
                    note: dgpuName + " · NVAccel 核心温度")
            KPICard(label: "硬盘温度",
                    value: Fmt.celsius(store.diskTemp),
                    unit: "℃",
                    icon: "internaldrive",
                    tint: store.tempColor(store.diskTemp ?? 0),
                    series: store.history["diskTemp"] ?? [],
                    note: diskTempNote,
                    accessory: AnyView(diskPicker))
        }
    }

    // MARK: 设备卡

    private var deviceCard: some View {
        Card(title: "设备") {
            VStack(spacing: 0) {
                dashRow("处理器", cpuBrandClean, coreNote)
                dashRow("内存", memLine, dimmSub)
                dashRow("图形", gpuNames, gpuSub)
                dashRow("启动卷", diskText, diskSub)
                dashRow("显示器", displayText, displaySub)
            }
        }
    }

    // MARK: 本机卡

    private var machineCard: some View {
        Card(title: "本机") {
            VStack(spacing: 0) {
                dashRow("机型标识符", modelID, nil)
                dashRow("序列号", serial ?? "读取中…", nil)
                dashRow("处理器", cpuBrandClean, coreNote)
                dashRow("内存", memLine, dimmSub)
                dashRow("系统", macOSFull, nil)
                dashRow("构建版本", BackendService.string(BackendService.dict(store.overview, "os"), "build") ?? "—", nil)
                dashRow("启动时间", compactUptime(BackendService.double(store.overview, "uptime") ?? 0), nil)
            }
        }
    }

    // MARK: 系统 / 启动参数

    private var osCard: some View {
        Card(title: "系统与启动参数") {
            let os = BackendService.dict(store.overview, "os")
            VStack(alignment: .leading, spacing: 12) {
                FieldGrid(rows: [
                    ("系统", "\(BackendService.string(os, "name") ?? "macOS") \(BackendService.string(os, "version") ?? "")"),
                    ("构建版本", BackendService.string(os, "build") ?? "—"),
                    ("架构", BackendService.string(BackendService.dict(store.overview, "cpu"), "arch") ?? "—"),
                    ("低电量模式", BackendService.bool(store.overview, "low_power_mode") == true ? "已开启" : "关闭"),
                ], columns: 2)
                if !bootArgs.isEmpty {
                    Divider().overlay(Theme.line)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BOOT ARGS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.dim2)
                            .tracking(0.9)
                        Text(bootArgs)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var bootArgs: String {
        let s = BackendService.string(BackendService.dict(store.overview, "os"), "boot_args") ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 行组件

    private func dashRow(_ key: String, _ value: String, _ sub: String?) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.txt)
                    .multilineTextAlignment(.trailing)
                if let sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: - 取值

    private var machineName: String {
        let model = BackendService.string(store.overview, "model") ?? "未知机型"
        return MacModelInfo.marketingName(model) ?? model
    }

    private var modelID: String {
        BackendService.string(store.overview, "model") ?? "—"
    }

    /// macOS 市场名 + 版本号（"macOS Tahoe 26.7.1"）
    private var macOSFull: String {
        let os = BackendService.dict(store.overview, "os")
        let ver = BackendService.string(os, "version") ?? "—"
        let major = Int(ver.split(separator: ".").first ?? "") ?? 0
        let name = macOSNames[major].map { "macOS \($0)" } ?? "macOS"
        return "\(name) \(ver)"
    }

    private let macOSNames = [
        26: "Tahoe", 15: "Sequoia", 14: "Sonoma",
        13: "Ventura", 12: "Monterey", 11: "Big Sur",
    ]

    private var cpuBrandClean: String {
        let raw = BackendService.string(store.cpu, "brand") ?? "—"
        return raw
            .replacingOccurrences(of: "Intel(R) Core(TM)", with: "Intel Core")
            .replacingOccurrences(of: " CPU", with: "")
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var coreNote: String {
        let p = BackendService.int(store.cpu, "physical") ?? 0
        let l = BackendService.int(store.cpu, "logical") ?? 0
        return p > 0 ? "\(p) 核 / \(l) 线程" : "—"
    }

    /// 内存总量（优先内存条实测值，退回 sysctl）
    private var memLine: String {
        if !dimms.isEmpty {
            let totalGB = dimms.reduce(0.0) { acc, d in
                let n = Double((d["size"] ?? "").replacingOccurrences(of: " GB", with: "")) ?? 0
                return acc + n
            }
            var parts = ["\(fmtCount(totalGB)) GB"]
            if let sp = Set(dimms.compactMap { $0["speed"] }).first { parts.append(sp) }
            if let t = Set(dimms.compactMap { $0["type"] }).first { parts.append(t) }
            return parts.joined(separator: " ")
        }
        let total = BackendService.double(store.memory, "total") ?? 0
        let used = BackendService.double(store.memory, "used") ?? 0
        guard total > 0 else { return "—" }
        return "\(fmtCount(used / 1e9)) / \(fmtCount(total / 1e9)) GB"
    }

    private var dimmSub: String? {
        guard !dimms.isEmpty else { return nil }
        let used = BackendService.double(store.memory, "used") ?? 0
        return "\(dimms.count) 条 · 已用 \(fmtCount(used / 1e9)) GB"
    }

    private var gpuNames: String {
        let names = store.gpus.compactMap { BackendService.string($0, "name") }
        return names.isEmpty ? "—" : names.joined(separator: " + ")
    }

    private var gpuSub: String? {
        let vrams = store.gpus.compactMap { g -> String? in
            guard let detail = BackendService.dict(g, "detail") else { return nil }
            return detail["VRAM (Total)"] as? String
        }
        return vrams.isEmpty ? nil : vrams.joined(separator: " + ")
    }

    /// 独显（PCIe 那张）——GPU 温度卡片说的就是它（2.7.6 起温度来自 NVAccel，不再读 EC 0x044F）
    private var dgpuName: String {
        let d = store.gpus.first { (BackendService.string($0, "bus") ?? "") == "PCIe" }
        return BackendService.string(d ?? store.gpus.first, "name") ?? "GPU"
    }

    /// 核显——IOAccelerator 的「Device Utilization %」属于它
    private var igpuName: String {
        let i = store.gpus.first { (BackendService.string($0, "bus") ?? "") != "PCIe" }
        return BackendService.string(i ?? store.gpus.first, "name") ?? "GPU"
    }

    private var rootDisk: [String: Any]? {
        store.disks.first { (BackendService.string($0, "mount") ?? "") == "/" } ?? store.disks.first
    }

    private var diskText: String {
        guard let d = rootDisk else { return "—" }
        let mount = BackendService.string(d, "mount") ?? "磁盘"
        return "\(mount) (\(fmtCount((BackendService.double(d, "total") ?? 0) / 1e9)) GB)"
    }

    private var diskSub: String? {
        guard let d = rootDisk else { return nil }
        let used = BackendService.double(d, "used") ?? 0
        let pct = BackendService.int(d, "percent") ?? 0
        return "已用 \(fmtCount(used / 1e9)) GB · \(pct)%"
    }

    private var displayText: String {
        guard NSScreen.main != nil else { return "—" }
        let inches = hypot(CGDisplayScreenSize(CGMainDisplayID()).width,
                           CGDisplayScreenSize(CGMainDisplayID()).height) / 25.4
        return "内建显示器 (\(fmtInches(inches))\")"
    }

    private var displaySub: String? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        let w = Int((screen.frame.width * scale).rounded())
        let h = Int((screen.frame.height * scale).rounded())
        var s = "\(w)x\(h)"
        let refresh = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        if refresh > 0 { s += ", \(Int(refresh.rounded()))Hz" }
        return s
    }

    private var thermalText: String {
        switch BackendService.string(store.overview, "thermal_state") ?? "" {
        case "nominal": return "正常"
        case "fair": return "偏高"
        case "serious": return "严重"
        case "critical": return "临界"
        default: return "—"
        }
    }

    private var powerModeText: String {
        BackendService.bool(store.overview, "low_power_mode") == true ? "低电量模式" : "常规"
    }

    /// 硬盘温度口径必须写清楚：nvmetemp 只取第一块支持 SMART 的 NVMe
    private var diskTempNote: String {
        let list = (BackendService.array(store.overview, "smart") as? [[String: Any]]) ?? []
        if !diskTarget.isEmpty,
           let d = list.first(where: { (BackendService.string($0, "bsd") ?? "") == diskTarget }) {
            if BackendService.bool(d, "ok") != true {
                return BackendService.string(d, "error") ?? "该盘 SMART 读取失败"
            }
            let model = BackendService.string(d, "model") ?? ""
            return model.isEmpty ? diskTarget : "\(diskTarget) · \(model)"
        }
        let d = BackendService.dict(store.overview, "disk_temp") ?? [:]
        if (d["ok"] as? Bool) != true {
            return BackendService.string(d, "error") ?? "读取中…"
        }
        return "NVMe SMART · 首块盘"
    }

    // MARK: - GPU 使用率（2.7.6：可选核显 / 独显）

    /// 核显走 IOAccelerator 的 "Device Utilization %"；独显走 NVAccel RM 的 3D 引擎
    /// （NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2，见 NativeNVAccel）。
    private var gpuUsageValue: Double? {
        if gpuTarget == "dgpu" {
            guard store.dgpuAvailable, store.dgpuReported else { return nil }
            // 与曲线同源：都取 5 秒均值，否则数字和折线会差一格台阶
            return store.dgpuUtilAvg5
        }
        return BackendService.double(store.overview, "gpu_usage")
    }

    private var gpuUsageSeries: [Double] {
        gpuTarget == "dgpu" ? (store.history["dgpu"] ?? []) : (store.history["gpu"] ?? [])
    }

    /// 这个百分比是「引擎占用率」，不是显存占用 —— 用户专门问过，写进 tooltip 里说明清楚。
    private var gpuUsageHelp: String {
        if gpuTarget == "dgpu" {
            return "dGPU：NVAccel RM 的 GPUMON perfmon（NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2），"
                 + "取 GR（3D 图形引擎）的忙碌时间占比。\n"
                 + "不是显存占用率。固件按整秒统计，这里显示的是最近 5 秒均值；"
                 + "瞬时 \(Fmt.tridiagonal(store.dgpuUtil))%，15 秒均值 \(Fmt.tridiagonal(store.dgpuUtilAvg15))%。"
        }
        return "iGPU：IOAccelerator 的 Device Utilization %，GPU 渲染引擎的忙碌时间占比。\n"
             + "不是显存占用率。显存占用看「显卡」卡片里的 显存 已用 / 总量。"
    }

    private var gpuUsageNote: String {
        if gpuTarget == "dgpu" {
            if !store.dgpuAvailable { return dgpuName + " · NVAccel 未就绪" }
            return store.dgpuReported ? dgpuName + " · 3D 引擎"
                                      : dgpuName + " · 驱动未上报利用率"
        }
        return igpuName
    }

    private var gpuPicker: some View {
        Menu {
            Button("iGPU · \(igpuName)") { gpuTarget = "igpu" }
            Button("dGPU · \(dgpuName)") { gpuTarget = "dgpu" }
        } label: {
            HStack(spacing: 2) {
                Text(gpuTarget == "dgpu" ? "dGPU" : "iGPU")
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .semibold))
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.barBg, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 硬盘温度卡右上角的选盘菜单（2.7.6 用户要求：可以选择显示哪一块硬盘的温度）
    private var diskPicker: some View {
        let list = (BackendService.array(store.overview, "smart") as? [[String: Any]]) ?? []
        return Menu {
            Button("自动（首块盘）") { diskTarget = "" }
            ForEach(Array(list.enumerated()), id: \.offset) { _, d in
                let bsd = BackendService.string(d, "bsd") ?? ""
                let model = BackendService.string(d, "model") ?? ""
                let ok = BackendService.bool(d, "ok") == true
                Button {
                    diskTarget = bsd
                } label: {
                    Text("\(bsd) · \(model.isEmpty ? "未知型号" : model)\(ok ? "" : "（不可读）")")
                }
                .disabled(bsd.isEmpty)
            }
        } label: {
            HStack(spacing: 2) {
                Text(diskTarget.isEmpty ? "首块" : diskTarget)
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .semibold))
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.barBg, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 一次性探测（序列号 / 内存条）

    private func probe() async {
        let info = await Task.detached(priority: .utility) { () -> [String: Any] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPHardwareDataType", "SPMemoryDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }.value

        if let hw = info["SPHardwareDataType"] as? [[String: Any]], let first = hw.first,
           let s = first["serial_number"] as? String {
            serial = s
        }
        if let mem = info["SPMemoryDataType"] as? [[String: Any]] {
            var items: [[String: String]] = []
            for entry in mem {
                guard let sub = entry["_items"] as? [[String: Any]] else { continue }
                for d in sub {
                    items.append([
                        "size": (d["dimm_size"] as? String) ?? "",
                        "speed": (d["dimm_speed"] as? String) ?? "",
                        "type": (d["dimm_type"] as? String) ?? "",
                        "slot": (d["_name"] as? String) ?? "",
                    ])
                }
            }
            dimms = items
        }
    }

    // MARK: 小工具

    private func compactUptime(_ s: Double) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
    }

    private func fmtCount(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func fmtInches(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// 机型 → 市场名 / 生产年份（mini 表，覆盖常见 Mac；查不到返回 nil，
/// 界面回退到 hw.model 原始标识符 / 「—」）。
/// 黑果机器的 hw.model 是 EFI 里仿冒的 Mac 标识，按它展示即可。
enum MacModelInfo {
    static let table: [String: (name: String, year: String)] = [
        // Apple Silicon 时代
        "MacBookPro18,1": ("MacBook Pro 16 英寸", "2021"),
        "MacBookPro18,2": ("MacBook Pro 16 英寸", "2021"),
        "MacBookPro18,3": ("MacBook Pro 14 英寸", "2021"),
        "MacBookPro18,4": ("MacBook Pro 14 英寸", "2021"),
        "MacBookPro17,1": ("MacBook Pro 13 英寸", "2020"),
        "MacBookAir10,1": ("MacBook Air 13 英寸", "2020"),
        // Intel 时代
        "MacBookPro16,4": ("MacBook Pro 16 英寸", "2019"),
        "MacBookPro16,1": ("MacBook Pro 16 英寸", "2019"),
        "MacBookPro16,2": ("MacBook Pro 13 英寸", "2020"),
        "MacBookPro16,3": ("MacBook Pro 13 英寸", "2020"),
        "MacBookPro15,4": ("MacBook Pro 13 英寸", "2019"),
        "MacBookPro15,1": ("MacBook Pro 15 英寸", "2018"),
        "MacBookPro15,2": ("MacBook Pro 15 英寸", "2018"),
        "MacBookPro15,3": ("MacBook Pro 15 英寸", "2018"),
        "MacBookPro14,3": ("MacBook Pro 13 英寸", "2017"),
        "MacBookPro14,2": ("MacBook Pro 13 英寸", "2017"),
        "MacBookPro14,1": ("MacBook Pro 13 英寸", "2017"),
        "MacBookPro13,3": ("MacBook Pro 15 英寸", "2016"),
        "MacBookPro13,2": ("MacBook Pro 13 英寸", "2016"),
        "MacBookPro13,1": ("MacBook Pro 13 英寸", "2016"),
        "MacBookAir9,1":  ("MacBook Air 13 英寸", "2020"),
        "MacBookAir8,2":  ("MacBook Air 13 英寸", "2019"),
        "MacBookAir8,1":  ("MacBook Air 13 英寸", "2018"),
        "MacBookAir7,2":  ("MacBook Air 13 英寸", "2015"),
        "MacBookAir7,1":  ("MacBook Air 11 英寸", "2015"),
        "iMac20,1":       ("iMac 27 英寸", "2020"),
        "iMac20,2":       ("iMac 27 英寸", "2020"),
        "iMac19,1":       ("iMac 27 英寸", "2019"),
        "iMac19,2":       ("iMac 21.5 英寸", "2019"),
        "iMac18,3":       ("iMac 27 英寸", "2017"),
        "iMac18,2":       ("iMac 21.5 英寸", "2017"),
        "iMac18,1":       ("iMac 21.5 英寸", "2017"),
        "iMacPro1,1":     ("iMac Pro", "2017"),
        "Macmini8,1":     ("Mac mini", "2018"),
        "Macmini7,1":     ("Mac mini", "2014"),
    ]
    static func marketingName(_ model: String) -> String? { table[model]?.name }
}
