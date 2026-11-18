//
//  SystemIdentity.swift
//  Sky CC —— 设备身份信息（原「概览」页拆出的公共组件）
//
//  3.0.3.7 合并（用户要求「概览和性能两页合成一页，去掉概览」）：
//   · 概览页 6 个 KPI 有 5 个与性能页重复（CPU 使用率/温度、内存、GPU 使用率/温度），
//     全部随页删除 —— 性能页的对应卡片更详细。
//   · hero 条精简成 MonitorHeroBar，挪到性能页顶部。
//   · 设备 / 本机 / 系统与启动参数三张身份卡挪到「设置」页顶部
//     （全部信息页在侧栏是隐藏的，放那里没人看得见）。
//
//  3.0.4.5（2026-11-14 用户要求）：恢复「概览」页 —— 身份卡 + 存储/电池/风扇
//  集中到 OverviewView；MonitorHeroBar 返回概览页顶部。
//  同日追加：设备 / 本机两张身份卡留在概览页；「系统与启动参数」抽成独立的
//  BootArgsCard，迁去「设置」页最下方（用户要求）。
//

import SwiftUI
import AppKit

// MARK: - 真实机型显示名（hero 条 / 机器卡 / 设置页版本卡共用）

enum RealModel {
    /// 真实机型优先（2026-11-18 用户要求）：
    /// SkyCCEC.kext 只匹配 ACPI PNP0C14（LAPQC71x 家族的 EC/WMI 平台），驱动实例
    /// 存在即说明这台机器是 Intel NUC 9 Extreme Laptop Kit——SMBIOS 的 hw.model
    /// 在黑果上是仿冒的（会假报 MacBook Pro），不可信。
    /// 检测不到 EC 平台（其他机器）再回退到 SMBIOS 市场名。
    /// 全称按 Intel ARK 官方命名：「Intel® NUC 9 Extreme Laptop Kit - LAPQC71D」。
    /// @MainActor：BackendService.string 等取值助手是 MainActor 隔离的，
    /// 调用点全部在视图层（hero 条 / 机器卡 / 设置页版本卡），跟着隔离即可。
    @MainActor
    static func displayName(overview: [String: Any]) -> String {
        if FanControl.kextLoaded() {
            let base = "Intel® NUC 9 Extreme Laptop Kit"
            // 子型号：四个型号 CPU 一致，只能看出厂独显（A=1660Ti B=2070MQ C=2060 D=2070SMQ）
            let dgpu = (BackendService.array(overview, "gpus") as? [[String: Any]] ?? [])
                .first { (BackendService.string($0, "bus") ?? "") == "PCIe" } ?? [:]
            let name = BackendService.string(dgpu, "name") ?? ""
            let devID = BackendService.dict(dgpu, "detail")
                .flatMap { BackendService.string($0, "Device ID") } ?? ""
            if let letter = Lapqc71Variant.letter(dgpuName: name, dgpuDeviceID: devID) {
                return "\(base) - LAPQC71\(letter)"
            }
            return "\(base) - LAPQC71x"
        }
        let model = BackendService.string(overview, "model") ?? "未知机型"
        return MacModelInfo.marketingName(model) ?? model
    }
}

// MARK: - LAPQC71x 子型号识别（2026-11-18 用户要求）

/// Intel NUC 9 Extreme Laptop Kit 家族只有 LAPQC71A/B/C/D 四个型号（Intel ARK，
/// 无 E）。四个型号 CPU 全部相同（i7-9750H + HM370 + UHD 630，黑果 SMBIOS 又是
/// 仿冒的，都拿不到），**唯一出厂差异是独显**：
///   LAPQC71A = GeForce GTX 1660 Ti            （TU116, device-id 0x2182）
///   LAPQC71B = RTX 2070 with Max-Q            （TU106, device-id 0x1F11）
///   LAPQC71C = RTX 2060                       （TU106, device-id 0x1F51）
///   LAPQC71D = RTX 2070 Super with Max-Q      （TU104, device-id 0x1E34）
/// 判定顺序：卡名匹配优先（装好 NVIDIA 驱动后 IOKit model 是完整卡名），
/// device-id 兜底（驱动没装上、name 是 unknown 时仍能认出）；
/// 两样都对不上（纯核显 / 独显被卸载 / 换了非出厂卡）返回 nil → 显示 LAPQC71x。
private enum Lapqc71Variant {
    static func letter(dgpuName: String, dgpuDeviceID: String) -> String? {
        let n = dgpuName.lowercased()
        let id = dgpuDeviceID.lowercased()
        // 注意顺序：必须先比 "2070 super" 再比 "2070"，否则 D 会被当成 B
        if n.contains("2070 super") || id == "0x1e34" { return "D" }
        if n.contains("2070")        || id == "0x1f11" { return "B" }
        if n.contains("2060")        || id == "0x1f51" { return "C" }
        if n.contains("1660")        || id == "0x2182" { return "A" }
        return nil
    }
}

// MARK: - 性能页顶部的 hero 条（原概览页 hero 的精简版）

struct MonitorHeroBar: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        // 2026-11-18（最小宽排查）：原布局「图标 + 机型名/3 芯片 + 右侧 4 统计」
        // 固有宽 ~780，是概览页在窗口最小宽 + 侧边栏（详情列 ~788）下被裁切的
        // 元凶 —— 芯片不换行、统计一行 4 格 + 3 分隔线，谁也压不动。
        // 用 ViewThatFits 提供宽窄两版：放得下用单行（现状），放不下统计
        // 整排换到第二行，芯片/名称行照旧 —— 内容不减，只是折行。
        ViewThatFits(in: .horizontal) {
            heroRow(statsBelow: false)
            heroRow(statsBelow: true)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func heroRow(statsBelow: Bool) -> some View {
        if statsBelow {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    heroIcon
                    nameColumn
                    Spacer(minLength: 12)
                }
                statsRow
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                heroIcon
                nameColumn
                Spacer(minLength: 12)
                statsRow
            }
        }
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accentGradient)
                .frame(width: 44, height: 44)
            Image(systemName: "laptopcomputer")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.white)
        }
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(machineName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
            HStack(spacing: 5) {
                Chip(text: macOSFull, color: Theme.blue)
                Chip(text: modelID, color: Theme.dim)
                Chip(text: store.connected ? "后台服务在线" : "后台服务离线",
                     color: store.connected ? Theme.green : Theme.red,
                     filled: !store.connected)
            }
        }
    }

    private var statsRow: some View {
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

    private var heroDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 26).padding(.horizontal, 12)
    }

    private func heroStat(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 9.5))
            }
            .foregroundStyle(Theme.dim2)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.txt)
                .lineLimit(1)
        }
    }

    // MARK: 取值（与原概览页同源）

    private var machineName: String {
        RealModel.displayName(overview: store.overview)
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

    private func compactUptime(_ s: Double) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
    }
}

// MARK: - 设备身份两卡（概览页顶部）

struct SystemIdentitySection: View {
    @EnvironmentObject var store: MonitorStore

    /// system_profiler 一次性探测（序列号 / 内存条），nil = 还没读到
    @State private var serial: String?
    @State private var dimms: [[String: String]] = []

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            // 2026-11-16（用户反馈）：设备卡 5 行、本机卡 7 行，高度不同；
            // GridRow 默认垂直居中会把矮的那张顶下去，两卡顶边错开。
            // 显式 .top 对齐，与下方风扇/电池行（HStack alignment: .top）一致。
            GridRow(alignment: .top) {
                deviceCard.gridEqual()
                machineCard.gridEqual()
            }
        }
        .task { await probe() }
    }

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

    // MARK: 取值

    private var machineName: String {
        RealModel.displayName(overview: store.overview)
    }

    private var modelID: String {
        BackendService.string(store.overview, "model") ?? "—"
    }

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

// MARK: - 系统与启动参数（原身份区第三卡，2026-11-14 用户要求迁去「设置」页底部）

struct BootArgsCard: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        Card(title: "系统与启动参数") {
            let os = BackendService.dict(store.overview, "os")
            VStack(alignment: .leading, spacing: 12) {
                FieldGrid(rows: [
                    ("系统", "\(BackendService.string(os, "name") ?? "macOS") \(BackendService.string(os, "version") ?? "")"),
                    ("构建版本", BackendService.string(os, "build") ?? "—"),
                    ("架构", BackendService.string(BackendService.dict(store.overview, "cpu"), "arch") ?? "—"),
                    ("低电量模式", BackendService.bool(store.overview, "low_power_mode") == true ? "已开启" : "关闭"),
                ], columns: 2)
                // BOOT ARGS 固定槽位（2026-11-18 用户要求）：没设置也占位显示「（未设置）」；
                // 有值时固定 44pt 高，超出部分出滚动条，卡片不随内容无限拉高。
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BOOT ARGS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.dim2)
                        .tracking(0.9)
                    if bootArgs.isEmpty {
                        Text("（未设置）")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.dim2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 44, alignment: .topLeading)
                    } else {
                        ScrollView(.vertical) {
                            Text(bootArgs)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 44)
                    }
                }
            }
        }
    }

    private var bootArgs: String {
        let s = BackendService.string(BackendService.dict(store.overview, "os"), "boot_args") ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
        "MacBookPro13,2": ("MacBook Pro 15 英寸", "2016"),
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
        "iMac18,1":       ("iMac 27 英寸", "2017"),
        "iMacPro1,1":     ("iMac Pro", "2017"),
        "Macmini8,1":     ("Mac mini", "2018"),
        "Macmini7,1":     ("Mac mini", "2014"),
    ]
    static func marketingName(_ model: String) -> String? { table[model]?.name }
}
