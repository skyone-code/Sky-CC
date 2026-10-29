//
//  NativeSystem.swift
//  Mac控制台 —— 系统信息采集（原生移植）
//
//  对应 Python 版 server.py 的数据采集段。策略：
//    * sysctl / host_statistics / host_processor_info / getifaddrs / IORegistry
//      → 原生 API（不 fork 子进程）
//    * 2.5.4 起按 exelban/Stats 的做法继续收编子进程：
//        - 电池百分比/状态  pmset -g batt → IOPSCopyPowerSourcesInfo + IOPSGetPowerSourceDescription
//        - 磁盘容量        df -k        → getmntinfo_r_np()（statfs 数组，线程安全版）
//        - 系统 build      sw_vers      → sysctlbyname("kern.osversion")
//    * 仍保留子进程的只有：system_profiler（GPU 型号）、ps|top（进程）、
//      nvmetemp（硬盘温度，随包二进制）。
//      —— Stats 自己也是用 /bin/ps + /usr/bin/top 读进程的，libproc 的
//      PROC_PIDTASKINFO 对他人进程常 EPERM，且 %CPU 要给差分才有意义。
//

import Foundation
import IOKit
import IOKit.graphics
import IOKit.ps
import CoreWLAN

// MARK: - 小工具：sysctl / 子进程

private func sysctlString(_ key: String) -> String? {
    var size: size_t = 0
    sysctlbyname(key, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

private func sysctlInt(_ key: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// 执行命令返回 stdout（失败返回空串），与 Python sh() 语义一致。
/// 走 NativeProc（硬超时 + 信号升级）：本函数被 overview/disks/processes 等
/// 服务接口调用，子进程卡死会拖垮整个 HTTP 后端（2026-10-20 实测过）。
private func sh(_ cmd: [String], timeout: TimeInterval = 6) -> String {
    guard !cmd.isEmpty else { return "" }
    return NativeProc.runCapture(cmd[0], Array(cmd.dropFirst()), timeout: timeout).out
}

// MARK: - 小工具：IORegistry 属性 / statfs 定长字符数组

/// 读 IORegistry 里的整数属性（CFNumber / CFBoolean 都能落到 Int）。
/// 主端口一律传 0（kIOMainPortDefault），传 mach_task_self_ 会返回 0。
private func ioInt(_ svc: io_registry_entry_t, _ key: String) -> Int? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(
        svc, key as CFString, kCFAllocatorDefault, 0) else { return nil }
    let v = unmanaged.takeRetainedValue()
    if let n = v as? NSNumber { return n.intValue }
    if let b = v as? Bool { return b ? 1 : 0 }
    return nil
}

/// 读 IORegistry 里的布尔属性（CFBoolean 经 toll-free bridging 也能当 NSNumber）。
private func ioBool(_ svc: io_registry_entry_t, _ key: String) -> Bool? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(
        svc, key as CFString, kCFAllocatorDefault, 0) else { return nil }
    let v = unmanaged.takeRetainedValue()
    if let b = v as? Bool { return b }
    if let n = v as? NSNumber { return n.intValue != 0 }
    return nil
}

/// statfs 的 f_mntfromname / f_mntonname 是定长 CChar 元组，不能直接 String(cString:)。
private func tupleCString<T>(_ tuple: inout T, capacity: Int) -> String {
    withUnsafePointer(to: &tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}

// MARK: - 小工具：把 IORegistry / CFType 整个摊平成 JSON 安全结构
//
// 用户的诉求是「能读到的值都返回」，所以这里不再逐键挑，而是把整个属性字典
// 递归转成 JSONSerialization 认得的类型：
//   CFBoolean → Bool，CFNumber → Int/Double，CFString → String，
//   CFData → 十六进制（超过 64 字节截断，避免 BatteryData 之类的长 blob 撑爆响应），
//   CFArray/CFDictionary → 递归，其它 → description 字符串。

private let kMaxBlobHexBytes = 64

private func dataToHex(_ data: Data) -> String {
    let n = min(data.count, kMaxBlobHexBytes)
    var s = data.prefix(n).map { String(format: "%02x", $0) }.joined()
    if data.count > n { s += "…(\(data.count)B)" }
    return s
}

private func jsonSafe(_ value: Any) -> Any {
    if let n = value as? NSNumber {
        // CFBoolean 也桥接成 NSNumber，必须用 CFGetTypeID 区分
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        let d = n.doubleValue
        if d == d.rounded(), abs(d) < 9.0e15 { return n.intValue }
        return d
    }
    if let s = value as? String { return s }
    if let d = value as? Data { return dataToHex(d) }
    if let arr = value as? [Any] { return arr.map { jsonSafe($0) } }
    if let dict = value as? [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k] = jsonSafe(v) }
        return out
    }
    if let dict = value as? [AnyHashable: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out["\(k)"] = jsonSafe(v) }
        return out
    }
    return "\(value)"
}

/// 某个 IORegistry 节点的全部属性（已经过 jsonSafe 处理）。
private func ioAllProperties(_ svc: io_registry_entry_t) -> [String: Any] {
    var props: Unmanaged<CFMutableDictionary>? = nil
    let kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
    guard kr == KERN_SUCCESS, let unmanaged = props,
          let dict = unmanaged.takeRetainedValue() as? [String: Any] else { return [:] }
    var out: [String: Any] = [:]
    for (k, v) in dict { out[k] = jsonSafe(v) }
    return out
}

/// 按类名遍历 IORegistry，对每个节点执行 body（body 返回非 nil 则收下）。
private func ioForEach(_ className: String, _ body: (io_registry_entry_t) -> Void) {
    guard let matching = IOServiceMatching(className) else { return }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(0, matching, &iter) == KERN_SUCCESS, iter != 0 else { return }
    defer { IOObjectRelease(iter) }
    while true {
        let svc = IOIteratorNext(iter)
        if svc == 0 { break }
        body(svc)
        IOObjectRelease(svc)
    }
}

/// 进程总数：libproc 的 proc_listallpids（Swift 没导出声明，手动绑定符号）。
/// 传 nil + 0 时直接返回当前进程数，不分配缓冲区。
@_silgen_name("proc_listallpids")
private func tf_procListAllPids(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32


// MARK: - 系统信息总入口

enum NativeSystem {

    // MARK: CPU 占用（host_processor_info 差值，对应 Python _cpu_sample/cpu_usage）

    private static var cpuTickTot: Double?
    private static var cpuTickIdle: Double?
    private static var cpuPct: Double?
    private static var cpuCoreTot: [Double] = []
    private static var cpuCoreIdle: [Double] = []
    private static var cpuCorePct: [Double] = []
    private static let cpuLock = NSLock()

    private static func cpuSample() -> (tot: Double, idle: Double,
                                       coreTot: [Double], coreIdle: [Double])? {
        var procCount: natural_t = 0
        var infoPtr: processor_info_array_t? = nil
        var msgCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), Int32(PROCESSOR_CPU_LOAD_INFO),
                                     &procCount, &infoPtr, &msgCount)
        guard kr == KERN_SUCCESS, let info = infoPtr else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(msgCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let n = Int(procCount)
        var tot: Double = 0, idle: Double = 0
        var coreTot = [Double](repeating: 0, count: n)
        var coreIdle = [Double](repeating: 0, count: n)
        for i in 0..<n {
            // 每 CPU 4 个 integer_t：user/system/idle/nice
            let base = i * 4
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let idleT = Double(info[base + Int(CPU_STATE_IDLE)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let t = user + system + idleT + nice
            tot += t
            idle += idleT
            coreTot[i] = t
            coreIdle[i] = idleT
        }
        return (tot, idle, coreTot, coreIdle)
    }

    /// 用两组采样算（总体占用, 每核占用）。prev 为空表示首次。
    private static func cpuDelta(_ now: (tot: Double, idle: Double,
                                        coreTot: [Double], coreIdle: [Double]),
                                 _ prevTot: Double?, _ prevIdle: Double?)
        -> (pct: Double?, cores: [Double]?) {
        guard let pt = prevTot, let pi = prevIdle else { return (nil, nil) }
        let dTot = now.tot - pt
        let dIdle = now.idle - pi
        var pct: Double? = nil
        if dTot > 0 { pct = (max(0, min(100, 100 * (1 - dIdle / dTot))) * 10).rounded() / 10 }
        var cores: [Double]? = nil
        if cpuCoreTot.count == now.coreTot.count, !now.coreTot.isEmpty {
            var out = [Double](repeating: 0, count: now.coreTot.count)
            for i in 0..<now.coreTot.count {
                let dt = now.coreTot[i] - cpuCoreTot[i]
                let di = now.coreIdle[i] - cpuCoreIdle[i]
                out[i] = dt > 0 ? (max(0, min(100, 100 * (1 - di / dt))) * 10).rounded() / 10 : 0
            }
            cores = out
        }
        return (pct, cores)
    }

    /// CPU 占用率（%）。首次调用自补一次采样（约 120ms）。
    /// 注意：不能在持锁状态下递归调用本函数——cpuLock 是非递归锁，
    /// 递归必死锁（曾致 /api/overview 永久挂起，实测）。
    static func cpuUsage() -> Double {
        cpuLock.lock()
        defer { cpuLock.unlock() }
        guard let s = cpuSample() else { return cpuPct ?? 0 }
        let prevTot = cpuTickTot
        let prevIdle = cpuTickIdle
        cpuTickTot = s.tot
        cpuTickIdle = s.idle
        let d = cpuDelta(s, prevTot, prevIdle)
        if let r = d.pct {
            cpuPct = r
            if let cores = d.cores { cpuCorePct = cores }
            cpuCoreTot = s.coreTot
            cpuCoreIdle = s.coreIdle
            return r
        }
        // 第一次调用：补采一次，免得前端第一帧闪一个「—」
        cpuCoreTot = s.coreTot
        cpuCoreIdle = s.coreIdle
        usleep(120_000)
        guard let s2 = cpuSample() else { return cpuPct ?? 0 }
        let d2 = cpuDelta(s2, s.tot, s.idle)
        if let r = d2.pct { cpuPct = r }
        if let cores = d2.cores { cpuCorePct = cores }
        cpuCoreTot = s2.coreTot
        cpuCoreIdle = s2.coreIdle
        cpuTickTot = s2.tot
        cpuTickIdle = s2.idle
        return cpuPct ?? 0
    }

    /// 最近一次采样得到的每核占用（%）。只是读取缓存，不触发新采样。
    static func cpuCoreUsage() -> [Double] {
        cpuLock.lock()
        defer { cpuLock.unlock() }
        return cpuCorePct
    }

    // MARK: 概览（对应 Python overview()）
    //
    // slim=true 给 1 秒轮询用：只裁掉 GPU 那一大坨 PerformanceStatistics
    // （几十 KB，NVAccel 有上百个键），其它字段一个不少。

    static func overview(slim: Bool = false) -> [String: Any] {
        let memsize = Double(sysctlInt("hw.memsize") ?? 0)

        // 内存：host_statistics64。除了 free/inactive 口径，还把小项全摊出来
        // （wired / compressed / purgeable / app / 每项字节数）——Activity Monitor
        // 能看到的这里都有。
        var usedMem = 0.0
        let totalMem = memsize
        var page = 4096.0
        var memDetail: [String: Any] = [:]
        if memsize > 0 {
            var vmStat = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutableBytes(of: &vmStat) { ptr -> kern_return_t in
                guard let base = ptr.bindMemory(to: integer_t.self).baseAddress else {
                    return kern_return_t(KERN_FAILURE)
                }
                return host_statistics64(mach_host_self(), HOST_VM_INFO64, base, &count)
            }
            if kr == KERN_SUCCESS {
                var pageSize: vm_size_t = 0
                host_page_size(mach_host_self(), &pageSize)
                page = Double(pageSize)
                let freeC = Double(vmStat.free_count) * page
                let inactiveC = Double(vmStat.inactive_count) * page
                let activeC = Double(vmStat.active_count) * page
                let wiredC = Double(vmStat.wire_count) * page
                let compressedC = Double(vmStat.compressor_page_count) * page
                let purgeableC = Double(vmStat.purgeable_count) * page
                let speculativeC = Double(vmStat.speculative_count) * page
                let externalC = Double(vmStat.external_page_count) * page
                let internalC = Double(vmStat.internal_page_count) * page
                usedMem = memsize - freeC - inactiveC
                if usedMem < 0 { usedMem = 0 }
                memDetail = [
                    "page_size": Int(page),
                    "free": freeC,
                    "inactive": inactiveC,
                    "active": activeC,
                    "wired": wiredC,
                    "compressed": compressedC,
                    "purgeable": purgeableC,
                    "speculative": speculativeC,
                    "external": externalC,
                    "internal": internalC,
                    // Activity Monitor 的「APP 内存」口径：internal - purgeable
                    "app": max(0, internalC - purgeableC),
                    "swapins": Double(vmStat.swapins),
                    "swapouts": Double(vmStat.swapouts),
                    "compressions": Double(vmStat.compressions),
                    "decompressions": Double(vmStat.decompressions),
                    "pageins": Double(vmStat.pageins),
                    "pageouts": Double(vmStat.pageouts),
                ]
            }
        }
        let memPercent = totalMem > 0 ? (usedMem / totalMem * 1000).rounded() / 10 : 0
        memDetail["percent_used"] = memPercent
        memDetail["available"] = max(0, totalMem - usedMem)
        memDetail["swap"] = swapUsage()

        // 负载：getloadavg() 直接问内核。
        // 旧实现 spawn `sysctl -n vm.loadavg` + 正则解析文本——每 2s 一次子进程，
        // 而 MonitorStore/MetricsHub 都在调 /api/overview，纯属浪费（见 2.5.4 说明）。
        var loadVals: [Double] = [0, 0, 0]
        var rawLoad = [Double](repeating: 0, count: 3)
        if getloadavg(&rawLoad, 3) > 0 { loadVals = rawLoad }

        // 开机时长：sysctlbyname("kern.boottime") 拿 struct timeval，比解析文本稳
        var uptimeSec = 0.0
        var bootEpoch: Double = 0
        var tv = timeval()
        var tvSize = size_t(MemoryLayout<timeval>.size)
        if sysctlbyname("kern.boottime", &tv, &tvSize, nil, 0) == 0, tv.tv_sec > 0 {
            bootEpoch = Double(tv.tv_sec)
            uptimeSec = Date().timeIntervalSince1970 - bootEpoch
        }

        let usage = cpuUsage()
        var cpu: [String: Any] = [
            "brand": sysctlString("machdep.cpu.brand_string") ?? "未知",
            "vendor": sysctlString("machdep.cpu.vendor") ?? "",
            "physical": sysctlInt("hw.physicalcpu") ?? 0,
            "logical": sysctlInt("hw.logicalcpu") ?? 0,
            "arch": sysctlString("hw.machine") ?? "",
            "features": sysctlString("machdep.cpu.features") ?? "",
            "leaf7_features": sysctlString("machdep.cpu.leaf7_features") ?? "",
            "usage": usage,
            "cores": cpuCoreUsage(),
        ]
        if let f = sysctlInt("hw.cpufrequency_max"), f > 0 {
            cpu["freq_mhz"] = f / 1_000_000
        } else {
            cpu["freq_mhz"] = NSNull()
        }
        for (label, key) in [("freq_min_mhz", "hw.cpufrequency_min"),
                             ("freq_cur_mhz", "hw.cpufrequency"),
                             ("l1i_cache", "hw.l1icachesize"),
                             ("l1d_cache", "hw.l1dcachesize"),
                             ("l2_cache", "hw.l2cachesize"),
                             ("l3_cache", "hw.l3cachesize")] {
            if let v = sysctlInt(key), v > 0 {
                cpu[label] = key.hasSuffix("cachesize") ? v : v / 1_000_000
            }
        }

        // 系统热压 / 低电量模式：NSProcessInfo（内核通过 notify 推送，零成本）
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  thermal = "nominal"
        case .fair:     thermal = "fair"
        case .serious:  thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }

        // operatingSystemVersionString 在 macOS 上是 "Version 15.8.1 (Build …)"，
        // 老逻辑 hasPrefix("macOS") 恒为假 → 一直报成 "Mac OS X"。按大版本号判。
        let osName = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 11
            ? "macOS" : "Mac OS X"
        var osDict: [String: Any] = [
            "name": osName,
            "version": osVersion(),
            // kern.osversion 就是 sw_vers 的 BuildVersion（实测 24H32），
            // 直接问内核，不再每 2s fork 一个 sw_vers
            "build": sysctlString("kern.osversion") ?? "",
            "kernel": sysctlString("kern.version") ?? "",
            "hostname": sysctlString("kern.hostname") ?? "",
            "boot_args": sysctlString("kern.bootargs") ?? "",
        ]
        // 注意 kern.osrelease 是字符串（"24.6.0"），kern.osrevision 是整数常量
        // （199506 = BSD 版本），别拿 sysctlString 去读它，会得到乱码字节。
        if let rel = sysctlString("kern.osrelease") { osDict["osrelease"] = rel }
        if let rev = sysctlInt("kern.osrevision") { osDict["osrevision"] = rev }

        return [
            "cpu": cpu,
            "memory": ["total": totalMem, "used": usedMem, "percent": memPercent,
                       "detail": memDetail],
            "load": loadVals,
            "cpu_usage": usage,
            "gpu_usage": gpuUsage() as Any,
            "gpu_stats": slim ? gpuDetailSlim() : gpuDetail(),
            // 独显（NVIDIA）利用率：驱动 2.6.3 起由内核每秒采样并发布到 NVAccel 的
            // PerformanceStatistics，这里只是读 IORegistry（见 NativeNVAccel）。
            // 核显那套 IOAccelerator 对 N 卡没有数据。值不可用时 reported=false。
            "dgpu": NVAccelUtil.snapshot(),
            "disk_temp": diskTemp() as Any,
            "smart": smartList(),
            "wifi": wifi(),
            "net": netUsage(),
            "uptime": Int(uptimeSec),
            "boot_time": bootEpoch > 0 ? Int(bootEpoch) : NSNull(),
            "thermal_state": thermal,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "process_count": Int(tf_procListAllPids(nil, 0)),
            "os": osDict,
            "model": sysctlString("hw.model") ?? "未知",
            "gpus": gpuInfo(),
        ]
    }

    /// vm.swapusage → struct xsw_usage（4 个 64/32 位字段拼的旧 ABI）。
    private struct XswUsage {
        var total: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var pagesize: UInt32 = 0
        var encrypted: Int32 = 0
    }

    private static func swapUsage() -> [String: Any] {
        var u = XswUsage()
        var size = MemoryLayout<XswUsage>.size
        guard sysctlbyname("vm.swapusage", &u, &size, nil, 0) == 0 else { return [:] }
        let pct = u.total > 0 ? (Double(u.used) / Double(u.total) * 1000).rounded() / 10 : 0
        return ["total": Int(u.total), "used": Int(u.used), "avail": Int(u.avail),
                "percent": pct, "encrypted": u.encrypted != 0]
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion != 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: GPU 信息（system_profiler 解析，与 Python 版同算法，缓存 30s）

    private static var gpuCacheTime: Double = 0
    private static var gpuCache: [[String: Any]]?

    /// macOS 下独显没驱动（本机 NVIDIA），system_profiler 只给 Device ID。
    /// 常见 NVIDIA Device ID → 型号（PCI 数据库实测）。
    private static let nvidiaIDs: [String: String] = [
        "1e81": "RTX 2080 Super", "1e82": "RTX 2080", "1e84": "RTX 2070 Super",
        "1e87": "RTX 2080", "1e89": "RTX 2060", "1e90": "RTX 2080 Max-Q",
        "1e91": "RTX 2070 Super", "1e93": "RTX 2080 Super Max-Q",
        "1f02": "RTX 2070 Super", "1f08": "RTX 2070", "1f10": "RTX 2070",
        "1f11": "RTX 2060", "1f12": "RTX 2060 Max-Q", "1f14": "RTX 2070",
        "2184": "GTX 1650 Super", "1c82": "GTX 1050 Ti", "1c81": "GTX 1050",
        "1b81": "GTX 1070", "1b06": "GTX 1080",
    ]

    static func gpuInfo() -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        if now - gpuCacheTime < 30, let v = gpuCache { return v }
        let out = sh(["/usr/sbin/system_profiler", "SPDisplaysDataType"], timeout: 20)
        var gpus: [[String: Any]] = []
        var cur: [String: Any]? = nil
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let indent = line.prefix(while: { $0 == " " }).count
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // GPU 名称：缩进恰为 4 个空格且以冒号结尾（子项缩进为 6、8，要排除）
            if indent == 4 && s.hasSuffix(":") {
                if let c = cur { gpus.append(c) }
                cur = ["name": String(s.dropLast()), "detail": [String: String]()]
                continue
            }
            if var c = cur, indent >= 6, let sep = s.firstIndex(of: ":") {
                var detail = c["detail"] as? [String: String] ?? [:]
                detail[String(s[..<sep]).trimmingCharacters(in: .whitespaces)] =
                    String(s[s.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                c["detail"] = detail
                cur = c
            }
        }
        if let c = cur { gpus.append(c) }
        gpus = gpus.map { normalizeGPU($0) }
        gpuCacheTime = now
        gpuCache = gpus
        return gpus
    }

    private static func normalizeGPU(_ g: [String: Any]) -> [String: Any] {
        var out = g
        let detail = g["detail"] as? [String: String] ?? [:]
        var name = g["name"] as? String ?? ""
        let model = (detail["Chipset Model"] ?? "").trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { name = model }
        if name.isEmpty || name == "Display" || name == "Graphics/Displays" {
            var vendor = (detail["Vendor"] ?? "")
            vendor = String(vendor.split(separator: "(").first ?? "").trimmingCharacters(in: .whitespaces)
            let dev = (detail["Device ID"] ?? "").trimmingCharacters(in: .whitespaces)
            let model2 = nvidiaIDs[dev.lowercased().replacingOccurrences(of: "0x", with: "")]
            name = [vendor, model2 ?? dev].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = "GPU" }
        }
        out["name"] = name
        out["bus"] = detail["Bus"] ?? ""
        out["vendor"] = detail["Vendor"] ?? ""
        return out
    }

    // MARK: GPU 占用率（IORegistry IOAccelerator PerformanceStatistics，缓存 1s）

    private static var gpuUsageTime: Double = 0
    private static var gpuUsageCache: Int?
    private static var gpuDetailCache: [[String: Any]] = []
    private static let gpuLock = NSLock()

    /// psutil 不管 GPU，走 IORegistry：IOAccelerator 节点的 PerformanceStatistics
    /// 字典里就有 "Device Utilization %"（与 exelban/Stats 同源）。
    ///
    /// 2.5.4 起把整个 Statistics 字典也返回（显存占用 / 分配量 / tiler 内存 /
    /// 每个加速器一条记录），不再只抠一个 utilization 数字。
    static func gpuDetail() -> [[String: Any]] {
        gpuLock.lock()
        defer { gpuLock.unlock() }
        let now = Date().timeIntervalSince1970
        if now - gpuUsageTime < 1.0, !gpuDetailCache.isEmpty || gpuUsageCache != nil {
            return gpuDetailCache
        }
        var list: [[String: Any]] = []
        var vals: [Int] = []
        ioForEach("IOAccelerator") { svc in
            guard let unmanaged = IORegistryEntryCreateCFProperty(
                svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else { return }
            guard let raw = unmanaged.takeRetainedValue() as? [String: Any] else { return }
            var e: [String: Any] = ["stats": jsonSafe(raw)]
            var ioClass = ""
            if let u = IORegistryEntryCreateCFProperty(
                svc, "IOClass" as CFString, kCFAllocatorDefault, 0),
               let s = u.takeRetainedValue() as? String {
                e["io_class"] = s
                ioClass = s
            }
            if let u = IORegistryEntryCreateCFProperty(
                svc, "model" as CFString, kCFAllocatorDefault, 0),
               let s = u.takeRetainedValue() as? String {
                e["model"] = s
            }
            for key in ["Device Utilization %", "GPU Activity(%)"] {
                if let n = raw[key] as? NSNumber {
                    e["utilization"] = n.intValue
                    // `gpu_usage`（概览 KPI / 菜单栏 / 核显那一行）只认核显。
                    // 驱动 2.6.3 起 NVAccel 也发布 "Device Utilization %"（见
                    // NativeNVAccel 顶部注释），再取「所有加速器的最大值」就会让
                    // 独显忙的时候把核显那个数字顶上去 —— 两个数字各归各的。
                    if !isNvidiaAccelerator(ioClass) { vals.append(n.intValue) }
                    break
                }
            }
            // 显存口径的几个键（Intel/AMD/NVIDIA 各有叫法，都摊出来）
            for key in ["In use system memory", "Alloc system memory",
                        "vramUsedBytes", "vramAllocatedBytes", "gartUsedBytes"] {
                if let n = raw[key] as? NSNumber { e[key] = n.intValue }
            }
            list.append(e)
        }
        gpuUsageTime = now
        gpuUsageCache = vals.isEmpty ? nil : vals.max()
        gpuDetailCache = list
        return list
    }

    static func gpuUsage() -> Int? {
        _ = gpuDetail()     // 同一份缓存，顺便刷新
        gpuLock.lock()
        defer { gpuLock.unlock() }
        return gpuUsageCache
    }

    /// 这条 IOAccelerator 是不是 NVIDIA 驱动的那条。
    ///
    /// 2.6.3 之前 NVAccel 不发布 "Device Utilization %"，所以「所有加速器取最大」
    /// 恰好只等于核显；现在 N 卡也有了，必须把两条区分开，否则 `gpu_usage`
    /// 会在独显满载时跳到独显的数字（核显那一格、概览 KPI、菜单栏全跟着错）。
    /// 独显的数字走 `dgpu`（NativeNVAccel），这里只服务核显。
    private static func isNvidiaAccelerator(_ ioClass: String) -> Bool {
        let s = ioClass.lowercased()
        return s.contains("nvaccel") || s.contains("nvrm") || s.contains("nvidia")
    }

    /// 精简版 GPU 统计（1 秒轮询用）：只留利用率与显存几项，丢掉上百个
    /// PerformanceStatistics 原始键。字段名与完整版一致，前端两种都能读。
    static func gpuDetailSlim() -> [[String: Any]] {
        let keys = ["io_class", "model", "utilization",
                    "In use system memory", "Alloc system memory",
                    "vramUsedBytes", "vramAllocatedBytes", "gartUsedBytes"]
        return gpuDetail().map { e in
            var o: [String: Any] = [:]
            for k in keys { if let v = e[k] { o[k] = v } }
            return o
        }
    }

    // MARK: 硬盘温度（随包 nvmetemp 二进制，缓存 15s）

    private static var diskTempTime: Double = 0
    private static var diskTempCache: [String: Any]?

    static func diskTemp() -> [String: Any] {
        let now = Date().timeIntervalSince1970
        if now - diskTempTime < 15, let v = diskTempCache { return v }
        var data: [String: Any] = ["ok": false, "error": "缺少 nvmetemp"]
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("native/bin/nvmetemp"),
            Bundle.main.resourceURL?.appendingPathComponent("python/bin/nvmetemp"),
            URL(fileURLWithPath: "/usr/local/bin/nvmetemp"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/nvmetemp"),
        ].compactMap { $0 }
        if let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            let raw = sh([exe.path], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                data = obj
            } else {
                data = ["ok": false, "error": "nvmetemp 输出异常"]
            }
        }
        diskTempTime = now
        diskTempCache = data
        return data
    }

    /// 这块 bsd 盘是物理设备还是 APFS 容器（diskutil 的 VirtualOrPhysical）
    private static func isPhysicalDisk(_ bsd: String) -> Bool {
        let raw = sh(["/usr/sbin/diskutil", "info", "-plist", bsd], timeout: 3)
        guard let d = raw.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(
                from: d, options: [], format: nil) as? [String: Any] else { return true }
        if let v = obj["VirtualOrPhysical"] as? String {
            return v.lowercased() == "physical"
        }
        return true
    }

    // MARK: 逐盘 SMART 列表（2.7.5：nvmesmart 按控制器枚举，两块盘都能读）
    //
    // 历史：2.7.0 用 nvmetemp —— 它是单盘工具（取首个匹配的控制器），本机两块 NVMe
    // 只有一块出数，另一块只能标「未覆盖」。2.7.5 起改用随包的 nvmesmart（Tools/nvmesmart.c）：
    // 遍历所有带 "NVMe SMART Capable" 属性的服务，逐块 SMARTReadData，输出 bsd/model/温度/
    // 备件/寿命/读写量。二进制缺失时回退到旧单盘路径。

    private static var nvmeSmartTime: Double = 0
    private static var nvmeSmartCache: [[String: Any]]?

    private static func nvmeSmartDisks() -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        if now - nvmeSmartTime < 15, let v = nvmeSmartCache { return v }
        var out: [[String: Any]] = []
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("native/bin/nvmesmart"),
            URL(fileURLWithPath: "/usr/local/bin/nvmesmart"),
        ].compactMap { $0 }
        if let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            let raw = sh([exe.path], timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = obj["disks"] as? [[String: Any]] {
                out = list
            }
        }
        nvmeSmartTime = now
        nvmeSmartCache = out
        return out
    }

    static func smartList() -> [[String: Any]] {
        let listed = nvmeSmartDisks()
        if !listed.isEmpty {
            return listed.sorted { a, b in
                (Int((a["bsd"] as? String ?? "").replacingOccurrences(of: "disk", with: "")) ?? 0)
                    < (Int((b["bsd"] as? String ?? "").replacingOccurrences(of: "disk", with: "")) ?? 0)
            }.map { d in
                var e = d
                e["covered"] = true
                if (d["ok"] as? Bool) != true, e["error"] == nil {
                    e["error"] = "SMART 读取失败（该盘不支持 log page 0x02 或控制器未响应）"
                }
                return e
            }
        }

        // —— 回退：随包 nvmetemp 单盘路径 ——
        let one = diskTemp()
        // 从挂载点反推物理盘（/dev/disk0s2 → disk0），去重排序
        var names = Set<String>()
        for d in disks() {
            guard let dev = d["device"] as? String, dev.hasPrefix("/dev/") else { continue }
            let base = dev.replacingOccurrences(of: "/dev/", with: "")
            if let r = base.range(of: "s\\d+$", options: .regularExpression) {
                names.insert(String(base[base.startIndex..<r.lowerBound]))
            } else {
                names.insert(base)
            }
        }
        let sorted = names.sorted { a, b in
            (Int(a.replacingOccurrences(of: "disk", with: "")) ?? 0)
                < (Int(b.replacingOccurrences(of: "disk", with: "")) ?? 0)
        }
        // 只留物理盘：disk2/disk3 这类是 disk0 上的 APFS 容器，不是独立 NVMe，
        // 列出来会让用户以为多了一整块盘（2.7.1 修正）。diskutil 一次约 60ms，
        // 外层 diskTemp 已有 15s 缓存，这里跟着一起缓存。
        let physical = sorted.filter { isPhysicalDisk($0) }
        var out: [[String: Any]] = []
        for (i, name) in physical.enumerated() {
            var e: [String: Any] = ["bsd": name]
            if i == 0, (one["ok"] as? Bool) == true {
                e.merge(one) { _, new in new }
                e["covered"] = true
            } else {
                e["ok"] = false
                e["covered"] = false
                e["error"] = "缺少 nvmesmart；nvmetemp 只能读首块盘"
            }
            out.append(e)
        }
        if out.isEmpty { out = [["bsd": "—", "ok": false, "covered": false, "error": "未发现 NVMe 盘"]] }
        return out
    }

    // MARK: 网络上下行速率（getifaddrs + if_data，跳过回环）

    private static var netTickTime: Double = 0
    private static var netTickSent: UInt64 = 0
    private static var netTickRecv: UInt64 = 0
    private static var netPrevPerIf: [String: (UInt64, UInt64)] = [:]
    private static let netLock = NSLock()

    /// 把 sockaddr 转成可读地址（AF_INET / AF_INET6，纯数字形式）。
    private static func sockaddrString(_ sa: UnsafePointer<sockaddr>?) -> String? {
        guard let sa = sa else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        let rc = getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        let s = String(cString: host)
        // 去掉 IPv6 的 %en0 之类的 scope 后缀
        return s.split(separator: "%").first.map(String.init)
    }

    // MARK: Wi-Fi（CoreWLAN，原生；不 spawn airport/networksetup）
    //
    // SSID 在 macOS 14+ 需要「定位服务」授权，LaunchAgent 里通常拿不到 —— 拿不到就
    // 不编造，返回 nil 让界面显示「需定位权限」。RSSI / 速率 / 信道 / 安全类型不需要授权。
    private static var wifiTime: Double = 0
    private static var wifiCache: [String: Any] = [:]

    static func wifi() -> [String: Any] {
        let now = Date().timeIntervalSince1970
        if now - wifiTime < 3, !wifiCache.isEmpty { return wifiCache }

        var out: [String: Any] = ["available": false]
        defer { wifiTime = now; wifiCache = out }

        guard let iface = CWWiFiClient.shared().interface(), iface.interfaceName != nil else {
            return out
        }
        out["available"] = true
        out["power_on"] = iface.powerOn()
        out["interface"] = iface.interfaceName ?? ""
        if let ssid = iface.ssid(), !ssid.isEmpty { out["ssid"] = ssid }
        out["rssi_dbm"] = iface.rssiValue()          // 0 = 未关联
        out["noise_dbm"] = iface.noiseMeasurement()
        out["tx_rate_mbps"] = iface.transmitRate()
        if let ch = iface.wlanChannel() {
            out["channel"] = ch.channelNumber
            let band: String
            switch ch.channelBand {
            case .band2GHz: band = "2.4 GHz"
            case .band5GHz: band = "5 GHz"
            case .band6GHz: band = "6 GHz"
            default: band = "—"
            }
            out["band"] = band
            out["channel_width_mhz"] = ch.channelWidth.rawValue
        }
        out["security"] = securityLabel(iface.security())
        out["bssid"] = iface.bssid() ?? NSNull()
        return out
    }

    private static func securityLabel(_ s: CWSecurity) -> String {
        switch s {
        case .none: return "开放"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal: return "WPA2"
        case .personal: return "WPA/WPA2"
        case .wpa3Personal: return "WPA3"
        case .wpa3Transition: return "WPA2/WPA3"
        case .enterprise, .wpaEnterprise, .wpaEnterpriseMixed,
             .wpa2Enterprise, .wpa3Enterprise: return "企业级"
        default: return "—"
        }
    }

    static func netUsage() -> [String: Any] {
        netLock.lock()
        defer { netLock.unlock() }

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return ["up_kbs": 0.0, "down_kbs": 0.0, "total_sent": 0, "total_recv": 0,
                    "interfaces": []]
        }
        defer { freeifaddrs(ifaddrPtr) }

        // 按网卡去重（每个地址族一行回报的都是接口累计值，取最大）
        var perName: [String: (UInt64, UInt64)] = [:]
        var addrs: [String: [String: [String]]] = [:]   // name → {"ipv4":[], "ipv6":[]}
        var netmask: [String: String] = [:]
        var flags: [String: UInt32] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard let namePtr = cur.pointee.ifa_name else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("lo") { continue }    // API 轮询走回环，算进去会是假流量
            flags[name] = UInt32(cur.pointee.ifa_flags)

            let family = cur.pointee.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_INET) {
                if let a = sockaddrString(cur.pointee.ifa_addr) {
                    addrs[name, default: [:]][ "ipv4", default: [] ].append(a)
                }
                if let m = sockaddrString(cur.pointee.ifa_netmask) { netmask[name] = m }
            } else if family == UInt8(AF_INET6) {
                if let a = sockaddrString(cur.pointee.ifa_addr) {
                    addrs[name, default: [:]][ "ipv6", default: [] ].append(a)
                }
            }
            guard let data = cur.pointee.ifa_data else { continue }
            // 注意：getifaddrs 给的 ifa_data 是 32 位计数的 struct if_data，
            // 不是 if_data64（后者是 routing socket / NET_RT_IFLIST2 用的）。
            // 早期版本按 if_data64 读，拿到的 ibytes 恒为 0、obytes 是个
            // 类似开机时间戳的野值 —— 实测对照 netstat -ib 才发现（2.5.4 修）。
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let entry = perName[name] ?? (0, 0)
            perName[name] = (max(entry.0, UInt64(stats.ifi_ibytes)),
                             max(entry.1, UInt64(stats.ifi_obytes)))
        }
        var sent: UInt64 = 0, recv: UInt64 = 0
        for (_, v) in perName { sent += v.1; recv += v.0 }

        /// 32 位计数器会翻转（4GiB 一圈），差分时按回绕处理，别直接丢一个采样
        func diff(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
            if cur >= prev { return cur - prev }
            return cur &+ 0x1_0000_0000 &- prev
        }

        let now = Date().timeIntervalSince1970
        let dt = netTickTime > 0 ? now - netTickTime : 0
        var up: Double = 0, down: Double = 0
        if dt > 0, netTickSent > 0 {
            up = Double(diff(sent, netTickSent)) / dt / 1024
            down = Double(diff(recv, netTickRecv)) / dt / 1024
        }
        netTickTime = now
        netTickSent = sent
        netTickRecv = recv

        // 分网卡速率（同一时间窗做差分）
        var ifList: [[String: Any]] = []
        for (name, v) in perName.sorted(by: { $0.value.1 > $1.value.1 }) {
            var iUp = 0.0, iDown = 0.0
            if dt > 0, let prev = netPrevPerIf[name] {
                iUp = Double(diff(v.1, prev.1)) / dt / 1024
                iDown = Double(diff(v.0, prev.0)) / dt / 1024
            }
            let f = flags[name] ?? 0
            ifList.append([
                "name": name,
                "up": (f & UInt32(IFF_UP)) != 0,
                "running": (f & UInt32(IFF_RUNNING)) != 0,
                "loopback": (f & UInt32(IFF_LOOPBACK)) != 0,
                "sent": v.1, "recv": v.0,
                "up_kbs": (iUp * 10).rounded() / 10,
                "down_kbs": (iDown * 10).rounded() / 10,
                "ipv4": addrs[name]?["ipv4"] ?? [],
                "ipv6": addrs[name]?["ipv6"] ?? [],
                "netmask": netmask[name] ?? NSNull(),
            ])
        }
        netPrevPerIf = perName

        return ["up_kbs": (up * 10).rounded() / 10,
                "down_kbs": (down * 10).rounded() / 10,
                "total_sent": sent, "total_recv": recv,
                "interfaces": ifList]
    }

    // MARK: 电池（AppleSmartBattery IORegistry + IOPowerSources）
    //
    // 2.5.4：百分比/状态从 `pmset -g batt` 换成 IOPowerSources 原生查询。
    // pmset 每次约 0.2–0.4s（fork + 进程启动 + 解析文本），而 MonitorStore 每 2s
    // 就走一次 /api/all → battery，纯属往 EC 的伤口上撒盐（与 EC 无关，但占时序）。
    // 取值口径与 pmset 一致：kIOPSCurrentCapacityKey 是 0–100 百分比。

    /// 电池状态中文标签（与旧 pmset 文本解析的输出保持一致，前端在用）
    private static func batteryStateLabel(isPresent: Bool, onAC: Bool,
                                          charging: Bool, charged: Bool,
                                          percent: Int?) -> String {
        if !isPresent { return "未知" }
        if onAC {
            if charging { return "充电中" }
            if charged || (percent ?? 0) >= 100 { return "已充满" }
            return "接通电源"
        }
        return "放电中"
    }

    static func battery() -> [String: Any] {
        // ── 1) AppleSmartBattery：容量/电压/电流/温度/循环次数（mAh、mV、mA、0.01℃）
        var d: [String: Int] = [:]
        var ioregAll: [String: Any] = [:]
        if let matching = IOServiceMatching("AppleSmartBattery") {
            // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会返回 0（找不到服务）
            let svc = IOServiceGetMatchingService(0, matching)
            if svc != 0 {
                defer { IOObjectRelease(svc) }
                for key in ["CurrentCapacity", "MaxCapacity", "AppleRawMaxCapacity",
                            "NominalChargeCapacity", "DesignCapacity", "Voltage",
                            "Amperage", "Temperature", "CycleCount", "ExternalConnected"] {
                    if let v = ioInt(svc, key) { d[key] = v }
                }
                // 整个节点的属性树（BatteryData / ChargerData / 各 cell 电压…）全带上
                ioregAll = ioAllProperties(svc)
            }
        }

        // ── 2) IOPowerSources：百分比 / 状态 / 剩余时间（对应 pmset 第一行）
        var percent: Int? = nil
        var onAC = (d["ExternalConnected"] ?? 0) != 0
        var charging = false
        var charged = false
        var isPresent = false
        var timeToEmpty: Int? = nil
        var timeToFull: Int? = nil
        var iopsDesc: [String: Any] = [:]
        var iopsList: [[String: Any]] = []
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let unmanaged = IOPSGetPowerSourceDescription(blob, ps) else { continue }
                let raw = unmanaged.takeUnretainedValue() as? [String: Any] ?? [:]
                let desc = jsonSafe(raw) as? [String: Any] ?? [:]
                iopsList.append(desc)
                // 只认内置电池（外接 UPS 也在这张表里）
                let type = raw[kIOPSTransportTypeKey] as? String ?? ""
                if type == kIOPSInternalType { isPresent = true }
                else if !raw.isEmpty { isPresent = true }

                if let c = raw[kIOPSCurrentCapacityKey] as? Int { percent = c }
                if let s = raw[kIOPSPowerSourceStateKey] as? String {
                    onAC = (s == kIOPSACPowerValue)
                }
                if let c = raw[kIOPSIsChargingKey] as? NSNumber { charging = c.boolValue }
                if let c = raw[kIOPSIsChargedKey] as? NSNumber { charged = c.boolValue }
                if let t = raw[kIOPSTimeToEmptyKey] as? Int, t > 0 { timeToEmpty = t }
                if let t = raw[kIOPSTimeToFullChargeKey] as? Int, t > 0 { timeToFull = t }
                if iopsDesc.isEmpty { iopsDesc = desc }
            }
        }

        // ── 3) 外接电源适配器详情（功率/厂商/序列号，pmset 不提供）
        var adapterWatts: Int? = nil
        var adapterAll: [String: Any] = [:]
        if let raw = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            adapterAll = jsonSafe(raw) as? [String: Any] ?? [:]
            if let w = raw[kIOPSPowerAdapterWattsKey] as? Int, w > 0 { adapterWatts = w }
        }

        let state = batteryStateLabel(isPresent: isPresent, onAC: onAC,
                                      charging: charging, charged: charged,
                                      percent: percent)

        // 保留 raw_text 字段（旧客户端在解析 pmset 文本），由原生值合成
        var raw = "现在："
        raw += onAC ? "使用交流电" : "使用电池"
        if let p = percent { raw += "；\(p)%" }
        raw += "；\(state)"
        if let t = timeToEmpty { raw += "；剩余 \(t / 60):\(String(format: "%02d", t % 60))" }
        if let t = timeToFull { raw += "；充满需 \(t / 60):\(String(format: "%02d", t % 60))" }

        // 循环次数：主路径就是 AppleSmartBattery 的 CycleCount（Stats 等第三方程序同源）。
        // 只有该键「完全不存在」时才回退到 SMC 的 B0CT（VirtualSMC 的电池键），
        // 这样在已有该键的机器上不会每次轮询都多开一个 AppleSMC 连接。
        //
        // 本机（OpenCore + VirtualSMC 1.3.8 + SMCBatteryManager 1.3.8）实测：
        //   AppleSmartBattery.CycleCount = 0
        //   BatteryData.CycleCount       = 0
        //   SMC B0CT                     = 0（ui16，键存在）
        //   IOReport Battery/BatteryCycleCount = 0
        //   IOPS 电源描述里连 Cycle Count 这个键都没有（只有 DesignCycleCount=1000）
        // 也就是说整条链路（ACPI 电池 → SMCBatteryManager → AppleSmartBattery → IOReport/IOPS）
        // 都是 0：这台机器的 ACPI 电池信息里没有循环次数字段，EC 侧也没有对应寄存器
        // （qc71 的 EC 只暴露 0x07B9 充电阈值）。真实值存在电池的 SBS EEPROM
        // （SMBus 命令 0x17），macOS 无法访问。属于平台限制，不是读取代码的问题。
        var cycleCountInt: Int? = (d["CycleCount"] as? NSNumber)?.intValue
        if cycleCountInt == nil, let smc = try? SMC(), let v = smc.readValue("B0CT") {
            cycleCountInt = Int(v)
        }

        let temp = d["Temperature"]
        var out: [String: Any] = [
            "percent": percent as Any,
            "state": state,
            "raw_text": raw,
            "charging": charging,
            "on_ac": onAC,
            "time_to_empty_min": timeToEmpty as Any,
            "time_to_full_min": timeToFull as Any,
            "adapter_watts": adapterWatts as Any,
            "voltage_mv": d["Voltage"] as Any,
            "amperage_ma": d["Amperage"] as Any,
            "temperature_c": (temp != nil && temp != 0) ? (Double(temp!) / 100 * 10).rounded() / 10 : NSNull(),
            "cycle_count": cycleCountInt ?? 0,
            // 0 既可能是「真 0 次」也可能是「平台没上报」，用这个标志区分，
            // 前端据此决定显示数字还是「—」+ 说明。
            "cycle_count_available": (cycleCountInt ?? 0) > 0,
            "design_capacity": d["DesignCapacity"] as Any,
            "max_capacity": d["MaxCapacity"] as Any,
            "raw_max_capacity": d["AppleRawMaxCapacity"] as Any,
            "nominal_charge_capacity": d["NominalChargeCapacity"] as Any,
            "current_capacity": d["CurrentCapacity"] as Any,
            "external_connected": onAC,
            // 瞬时功率 / 剩余电量（换算值，省得前端再算一遍）
            "power_w": (d["Voltage"] != nil && d["Amperage"] != nil)
                ? (Double(d["Voltage"]!) * Double(d["Amperage"]!) / 1_000_000 * 100).rounded() / 100
                : NSNull(),
            "charge_wh": (d["Voltage"] != nil && d["CurrentCapacity"] != nil)
                ? (Double(d["Voltage"]!) * Double(d["CurrentCapacity"]!) / 1_000_000 * 100).rounded() / 100
                : NSNull(),
            // IOPS 侧的健康/寿命/序列号（原生字段，比换算更权威）
            "health": iopsDesc["BatteryHealth"] as? String ?? NSNull(),
            "health_condition": iopsDesc["BatteryHealthCondition"] as? String ?? NSNull(),
            "design_cycle_count": iopsDesc["DesignCycleCount"] as Any,
            "serial": iopsDesc["Hardware Serial Number"] as? String ?? NSNull(),
            "name": iopsDesc["Name"] as? String ?? NSNull(),
            "optimized_charging": iopsDesc["Optimized Battery Charging Engaged"] as Any,
            "low_power_mode": iopsDesc["LPM Active"] as Any,
            // 完整原始数据（AppleSmartBattery 全属性 / IOPS 全部电源项 / 适配器）
            "ioreg": ioregAll,
            "iops": iopsDesc,
            "iops_all": iopsList,
            "adapter": adapterAll,
        ]
        // 健康度：优先 AppleRawMaxCapacity（MaxCapacity 在某些固件上是 0–100 刻度，
        // 拿它除 DesignCapacity 会得到荒谬值），两者都按 mAh 比
        let maxCap = d["AppleRawMaxCapacity"] ?? d["MaxCapacity"]
        if let design = d["DesignCapacity"], let maxCap = maxCap, design > 0 {
            out["health_percent"] = (Double(maxCap) / Double(design) * 1000).rounded() / 10
        } else {
            out["health_percent"] = NSNull()
        }
        return out
    }

    // MARK: 磁盘（getmntinfo_r_np，替代 df -k 解析）
    //
    // df 的本质就是 statfs 遍历挂载点，直接用 natvie 接口省一次 fork + 文本解析。
    // 用 _r_np 变体（返回 malloc 出来的数组）而不是 getmntinfo()：后者用静态缓冲区，
    // 并发请求下会互相踩（本服务是多线程 HTTP，已有多起因共享状态引发的挂死）。

    static func disks() -> [[String: Any]] {
        var ptr: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo_r_np(&ptr, MNT_NOWAIT)
        guard n > 0, let list = ptr else { return [] }
        defer { free(list) }

        let io = diskIOStats()
        var res: [[String: Any]] = []
        var seen = Set<String>()
        for i in 0..<Int(n) {
            var fs = list[i]
            let device = tupleCString(&fs.f_mntfromname, capacity: Int(MAXPATHLEN))
            let mount = tupleCString(&fs.f_mntonname, capacity: Int(MAXPATHLEN))
            let fstype = tupleCString(&fs.f_fstypename, capacity: Int(MFSNAMELEN))
            guard device.hasPrefix("/dev/") else { continue }
            // 系统卷宗组（Data/VM/Preboot…）与 / 共用同一块空间，报出来纯噪音
            if mount.hasPrefix("/System/Volumes/") || seen.contains(mount) { continue }
            seen.insert(mount)

            let bsize = UInt64(fs.f_bsize)
            let total = UInt64(fs.f_blocks) * bsize
            if total < 100 * 1024 * 1024 { continue }
            let freeBytes = UInt64(fs.f_bfree) * bsize
            let used = total >= freeBytes ? total - freeBytes : 0
            let avail = UInt64(fs.f_bavail) * bsize
            // df 的 Capacity% = Used / (Used + Avail)，即不把保留块算进分母
            let denom = used + avail
            let bsdn = (device as NSString).lastPathComponent  // /dev/disk3s1 → disk3s1

            var row: [String: Any] = [
                "device": device,
                "mount": mount,
                "fstype": fstype,
                "total": Int(total),
                "used": Int(used),
                "avail": Int(avail),
                "free": Int(freeBytes),
                "percent": denom > 0 ? Int((Double(used) / Double(denom) * 100).rounded()) : 0,
                // statfs 其余字段（df -k 丢掉的信息，一并返回）
                "block_size": Int(fs.f_bsize),
                "io_block_size": Int(fs.f_iosize),
                "blocks": Int(fs.f_blocks),
                "blocks_free": Int(fs.f_bfree),
                "blocks_avail": Int(fs.f_bavail),
                "files": Int(fs.f_files),
                "files_free": Int(fs.f_ffree),
                "fsid": Int(fs.f_fsid.val.0),
                "owner": Int(fs.f_owner),
                "subtype": Int(fs.f_fssubtype),
                "flags": Int(fs.f_flags),
                "read_only": (fs.f_flags & UInt32(MNT_RDONLY)) != 0,
                "local": (fs.f_flags & UInt32(MNT_LOCAL)) != 0,
            ]
            // 该卷对应物理盘的累计读写字节 / 速率（IOBlockStorageDriver 统计）
            if let stat = io[bsdn] {
                row["io"] = stat
            } else {
                // APFS 卷是 /dev/disk3s1，物理盘是 disk3 —— 退到父盘统计
                let parent = bsdn.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
                if let stat = io[parent] { row["io"] = stat }
            }
            res.append(row)
        }
        res.sort { ($0["total"] as? Int ?? 0) > ($1["total"] as? Int ?? 0) }
        return res
    }

    // MARK: 磁盘 I/O（IOBlockStorageDriver 的 Statistics 字典差分）

    private static var diskIOTime: Double = 0
    private static var diskIOPrev: [String: (UInt64, UInt64)] = [:]
    private static let diskIOLock = NSLock()

    /// BSD 名（disk0 这种整盘名）→ 累计读写字节 + 速率（kB/s）。
    /// 与 exelban/Stats 的 ActivityReader 同源：读 IOBlockStorageDriver 的
    /// "Statistics" 字典，既不读 /proc 也不跑 iostat。
    /// 键名用字面量（"Bytes (Read)" 等），避免 IOKit 头里的宏在 Swift 侧不可见。
    ///
    /// 注意 APFS：/dev/disk2s4s1 里的 disk2 是「合成容器」，物理盘其实是 disk1。
    /// 所以不能靠名字硬对，要从 driver 往下递归遍历所有 IOMedia，把整棵子树里的
    /// BSD 名都映射到同一个 driver 的统计上。
    private static func diskIOStats() -> [String: [String: Any]] {
        diskIOLock.lock()
        defer { diskIOLock.unlock() }

        var cur: [String: (UInt64, UInt64)] = [:]
        var out: [String: [String: Any]] = [:]

        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [:] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, matching, &iter) == KERN_SUCCESS, iter != 0 else {
            return [:]
        }
        defer { IOObjectRelease(iter) }

        while true {
            let drv = IOIteratorNext(iter)
            if drv == 0 { break }
            defer { IOObjectRelease(drv) }

            // 子节点是整盘 IOMedia，"BSD Name" 挂在那里
            var child: io_registry_entry_t = 0
            var bsd = ""
            if IORegistryEntryGetChildEntry(drv, kIOServicePlane, &child) == KERN_SUCCESS, child != 0 {
                if let u = IORegistryEntryCreateCFProperty(
                    child, "BSD Name" as CFString, kCFAllocatorDefault, 0),
                   let s = u.takeRetainedValue() as? String {
                    bsd = s
                }
                IOObjectRelease(child)
            }
            if bsd.isEmpty { continue }

            guard let u = IORegistryEntryCreateCFProperty(
                drv, "Statistics" as CFString, kCFAllocatorDefault, 0) else { continue }
            let stats = u.takeRetainedValue() as? [String: Any] ?? [:]
            func n(_ k: String) -> UInt64 {
                (stats[k] as? NSNumber)?.uint64Value ?? 0
            }
            let rd = n("Bytes (Read)"), wr = n("Bytes (Write)")
            cur[bsd] = (rd, wr)

            let now = Date().timeIntervalSince1970
            let dt = diskIOTime > 0 ? now - diskIOTime : 0
            var rkB = 0.0, wkB = 0.0
            if dt > 0, let p = diskIOPrev[bsd] {
                rkB = rd >= p.0 ? Double(rd - p.0) / dt / 1024 : 0
                wkB = wr >= p.1 ? Double(wr - p.1) / dt / 1024 : 0
            }
            let entry: [String: Any] = [
                "physical": bsd,
                "read_bytes": Int(rd),
                "write_bytes": Int(wr),
                "read_ops": Int(n("Operations (Read)")),
                "write_ops": Int(n("Operations (Write)")),
                "read_time_ms": Int(n("Total Time (Read)") / 1_000_000),
                "write_time_ms": Int(n("Total Time (Write)") / 1_000_000),
                "errors_read": Int(n("Errors (Read)")),
                "errors_write": Int(n("Errors (Write)")),
                "retries_read": Int(n("Retries (Read)")),
                "retries_write": Int(n("Retries (Write)")),
                "read_kbs": (rkB * 10).rounded() / 10,
                "write_kbs": (wkB * 10).rounded() / 10,
            ]
            out[bsd] = entry
            // 物理盘的整棵 IOMedia 子树（分区 / APFS 容器 / 快照）都指向这份统计
            for sub in descendantBSDs(drv) where sub != bsd {
                out[sub] = entry
            }
        }
        diskIOPrev = cur
        diskIOTime = Date().timeIntervalSince1970
        return out
    }

    /// 递归收集某个 IORegistry 节点下所有 IOMedia 的 BSD 名。
    private static func descendantBSDs(_ entry: io_registry_entry_t) -> [String] {
        var names: [String] = []
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == KERN_SUCCESS,
              childIter != 0 else { return names }
        defer { IOObjectRelease(childIter) }
        while true {
            let c = IOIteratorNext(childIter)
            if c == 0 { break }
            if let u = IORegistryEntryCreateCFProperty(
                c, "BSD Name" as CFString, kCFAllocatorDefault, 0),
               let s = u.takeRetainedValue() as? String {
                names.append(s)
            }
            names.append(contentsOf: descendantBSDs(c))
            IOObjectRelease(c)
        }
        return names
    }

    // MARK: 进程（ps 优先，top 回退）
    //
    // exelban/Stats 读进程也是 spawn /bin/ps 与 /usr/bin/top（libproc 的
    // PROC_PIDTASKINFO 对他人进程常返回 EPERM，且 %CPU 必须自己差分才有意义，
    // 首次采样只能给 0）。所以这里保留子进程，但加 2s 短缓存：
    // /api/all 与 /api/processes 会被两个轮询器同时打到，没必要 fork 两次。

    private static var procCacheTime: Double = 0
    private static var procCache: [[String: Any]] = []
    private static var procCacheLimit: Int = 0
    private static let procLock = NSLock()

    static func processes(limit: Int = 8) -> [[String: Any]] {
        procLock.lock()
        defer { procLock.unlock() }
        let now = Date().timeIntervalSince1970
        if now - procCacheTime < 2.0, procCacheLimit == limit, !procCache.isEmpty {
            return procCache
        }
        let rows = processesUncached(limit: limit)
        if !rows.isEmpty {
            procCacheTime = now
            procCache = rows
            procCacheLimit = limit
        }
        return rows
    }

    private static func processesUncached(limit: Int) -> [[String: Any]] {
        // 列多给一些：pid/user/state/rss/vsize/etime/nice/优先级 全都返回，
        // 前端用不上也不亏（一次 fork 的代价已经付了）。
        // 注意 macOS 的 ps 没有 thcount（那是 Linux 的），加了会整条命令报错。
        let fields = "pid,user,pcpu,pmem,rss,vsize,state,etime,ni,pri,comm"
        let out = sh(["/bin/ps", "-Ao", fields, "-r"], timeout: 8)
        var rows: [[String: Any]] = []
        for line in out.split(separator: "\n").dropFirst() {
            // comm 可能是含空格的路径，前 10 列定宽 + 剩余整段做名称
            let parts = line.split(maxSplits: 10, whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count >= 11, let cpu = Double(parts[2]), let mem = Double(parts[3]) else { continue }
            let name = String(parts[10]).trimmingCharacters(in: .whitespaces)
            rows.append([
                "pid": Int(parts[0]) ?? 0,
                "user": parts[1],
                "cpu": cpu,
                "mem": mem,
                "rss_kb": Int(parts[4]) ?? 0,
                "vsize_kb": Int(parts[5]) ?? 0,
                "state": parts[6],
                "elapsed": parts[7],
                "nice": Int(parts[8]) ?? 0,
                "priority": Int(parts[9]) ?? 0,
                "name": (name as NSString).lastPathComponent,
                "path": name,
            ])
            if rows.count >= limit { break }
        }
        if !rows.isEmpty { return rows }

        // 回退：top
        let top = sh(["/usr/bin/top", "-l", "1", "-n", String(limit * 2),
                      "-stats", "pid,command,cpu,mem"], timeout: 15)
        var started = false
        for line in top.split(separator: "\n") {
            if line.hasPrefix("PID") { started = true; continue }
            if !started { continue }
            let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard parts.count >= 4, let cpu = Double(parts[2]) else { continue }
            let mem = parts[3]
            var mb = 0.0
            if mem.hasSuffix("M") { mb = Double(mem.dropLast()) ?? 0 }
            else if mem.hasSuffix("G") { mb = (Double(mem.dropLast()) ?? 0) * 1024 }
            else if mem.hasSuffix("K") { mb = (Double(mem.dropLast()) ?? 0) / 1024 }
            rows.append(["pid": Int(parts[0]) ?? 0,
                         "cpu": cpu,
                         "mem": mb > 0 ? (mb / 1024 * 1000).rounded() / 10 : 0,
                         "name": (parts[1] as NSString).lastPathComponent])
            if rows.count >= limit { break }
        }
        return rows
    }

    // MARK: HID 设备列表（对应 Python hid_devices()）

    static func hidDevices() -> [[String: Any]] {
        NativeHID.findDevices().map { d in
            var out: [String: Any] = [
                "product": d.product ?? NSNull(),
                "manufacturer": d.manufacturer ?? NSNull(),
            ]
            out["vendor_id"] = d.vendorID.map { String(format: "%#06x", $0) } ?? NSNull()
            out["product_id"] = d.productID.map { String(format: "%#06x", $0) } ?? NSNull()
            out["usage_page"] = d.usagePage.map { String(format: "%#06x", $0) } ?? NSNull()
            out["usage"] = d.usage ?? NSNull()
            out["feature_size"] = d.maxFeatureReportSize ?? NSNull()
            out["output_size"] = d.maxOutputReportSize ?? NSNull()
            out["input_size"] = d.maxInputReportSize ?? NSNull()
            return out
        }
    }
}
