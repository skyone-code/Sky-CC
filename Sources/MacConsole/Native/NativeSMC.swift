//
//  NativeSMC.swift
//  Mac控制台 —— macOS SMC (System Management Controller) 读取（原生移植）
//
//  对应 Python 版 app-resources/smc.py：纯 IOKit AppleSMC 用户客户端，无第三方依赖。
//  本机（OpenCore + VirtualSMC）实测可用。提供 CPU 各核心温度、封装温度、
//  电流、功耗、电压。
//
//  与 Python 版的对应关系：
//    * SMCKeyData 结构布局逐字段对齐（共 80 字节，init 时 precondition 校验）；
//    * 走 IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC=2, ...)；
//    * read(key) = 先 READ_KEYINFO(9) 拿 size/type，再 READ_BYTES(5) 取数据；
//    * 解码表（sp78/sp87/sp96/sp5a/sp69/sp4b/fpe2/flt/ui*/si*/flag/ch8*/hex）一致。
//

import Foundation
import IOKit

// MARK: - 数据结构（与 Python ctypes.KeyData 逐字段对齐）

struct SMCVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // 显式补齐到 12 字节：C 编译器 / Python ctypes 的 sizeof(SMCKeyInfo) 都是 12
    // （9 字节数据 + 3 字节对齐填充），而 Swift 的 MemoryLayout.size 不含尾部
    // 填充（只有 9）。不补这 3 字节，父结构里 result/status/data8/data32/bytes
    // 会整体前移 3 字节，IOConnectCallStructMethod 直接踩错 ABI（曾致 SIGILL）。
    var _pad: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - SMC 客户端

enum SmcError: Error {
    case matchingFailed
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
}

final class SMC {
    static let kernelIndexSMC: UInt32 = 2
    static let cmdReadBytes: UInt8 = 5
    static let cmdReadKeyInfo: UInt8 = 9

    private var connect: io_connect_t = 0

    init() throws {
        precondition(MemoryLayout<SMCKeyData>.size == 80,
                     "SMCKeyData 布局必须为 80 字节（与 kext ABI 对齐）")
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SmcError.matchingFailed
        }
        // 主端口必须是 0（kIOMainPortDefault），不是 mach_task_self_：
        // 前者是「master port」语义，后者是任务端口，传错会返回 0（服务找不到）。
        // Python 版同样传 0，实测可用。
        let service = IOServiceGetMatchingService(0, matching)
        guard service != 0 else { throw SmcError.serviceNotFound }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS, conn != 0 else { throw SmcError.openFailed(kr) }
        connect = conn
    }

    deinit { close() }

    func close() {
        if connect != 0 {
            IOServiceClose(connect)
            connect = 0
        }
    }

    // -- 底层：一次 struct in/out 调用 --
    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        var outSize = MemoryLayout<SMCKeyData>.size    // size_t = Int
        return withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                withUnsafeMutablePointer(to: &outSize) { sizePtr in
                    IOConnectCallStructMethod(
                        connect, SMC.kernelIndexSMC,
                        UnsafeRawPointer(inPtr), MemoryLayout<SMCKeyData>.size,
                        UnsafeMutableRawPointer(outPtr), sizePtr)
                }
            }
        }
    }

    /// 返回 (raw_bytes | nil, data_type | nil)
    func read(_ key: String) -> (Data?, String?) {
        guard key.count == 4,
              let k32 = fourCC(key) else { return (nil, nil) }

        var infoIn = SMCKeyData()
        infoIn.key = k32
        infoIn.data8 = SMC.cmdReadKeyInfo
        var infoOut = SMCKeyData()
        if call(&infoIn, &infoOut) != KERN_SUCCESS || infoOut.result != 0 {
            return (nil, nil)
        }
        let size = Int(infoOut.keyInfo.dataSize)
        let dtype = fourCCString(infoOut.keyInfo.dataType)

        var rdIn = SMCKeyData()
        rdIn.key = k32
        rdIn.keyInfo.dataSize = infoOut.keyInfo.dataSize
        rdIn.data8 = SMC.cmdReadBytes
        var rdOut = SMCKeyData()
        if call(&rdIn, &rdOut) != KERN_SUCCESS || rdOut.result != 0 {
            return (nil, dtype)
        }
        // bytes 元组位于结构末尾（offset 48..<80），整块取出再切片
        var full = [UInt8]()
        withUnsafeBytes(of: &rdOut) { full = Array($0) }
        let start = full.count - 32
        return (Data(full[start..<min(start + size, full.count)]), dtype)
    }

    /// 直接返回解码后的数值/字符串，失败返回 nil
    func readValue(_ key: String) -> Double? {
        let (data, dtype) = read(key)
        return SMC.decode(dtype: dtype, data: data)
    }

    func keyCount() -> Int {
        guard let v = readValue("#KEY") else { return 0 }
        return Int(v)
    }

    // MARK: - 小工具

    private func fourCC(_ s: String) -> UInt32? {
        // key 是 4 字节 ASCII，按大端组成 u32
        var out: UInt32 = 0
        for ch in s.utf8 {
            out = (out << 8) | UInt32(ch)
        }
        return out
    }

    private func fourCCString(_ v: UInt32) -> String {
        // SMC 的 fourCC 在大端 UInt32 里：最高位字节是首字符
        // （Python 版 struct.pack('>I', dataType) 同理）。早期版本按低字节先取，
        // 把 "sp78" 解成 "87ps"，导致所有温度解码落空。
        // 注意每移位后都要 & 0xFF：UInt8(29552) 会触发越界陷阱（SIGILL）。
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - 类型解码（与 Python decode() 一致）

extension SMC {
    static func decode(dtype: String?, data: Data?) -> Double? {
        guard let dtype = dtype, let data = data else { return nil }
        let b = [UInt8](data)

        switch dtype {
        case "sp78", "sp87", "sp96", "sp5a", "sp69", "sp4b":
            guard b.count == 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            let div: Double
            switch dtype {
            case "sp78": div = 256.0
            case "sp87": div = 128.0
            case "sp96": div = 64.0
            case "sp5a": div = 1024.0
            case "sp69": div = 512.0
            case "sp4b": div = 2048.0
            default: div = 1.0
            }
            return Double(raw) / div
        case "fpe2":
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "flt":
            guard b.count == 4 else { return nil }
            return Double(Float(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16
                                | UInt32(b[2]) << 8 | UInt32(b[3])))
        case "ui8 ":
            guard b.count == 1 else { return nil }
            return Double(b[0])
        case "si8 ":
            guard b.count == 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        case "ui16":
            guard b.count == 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "si16":
            guard b.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "ui32":
            guard b.count == 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16
                          | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si32":
            guard b.count == 4 else { return nil }
            return Double(Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16
                                | UInt32(b[2]) << 8 | UInt32(b[3])))
        case "ui64":
            guard b.count == 8 else { return nil }
            var acc: UInt64 = 0
            for x in b { acc = (acc << 8) | UInt64(x) }
            return Double(acc)
        case "flag":
            guard let first = b.first else { return nil }
            return Double(first)
        case "ch8*":
            return nil    // 字符串键不参与数值快照
        case "hex", "hex_":
            return nil
        default:
            return nil
        }
    }
}

// MARK: - 高层封装：这台机器的实际可用传感器（对应 smc.snapshot()）

/// i7-9750H: 6 个物理核心。TC1C~TC6C 各核心温度，TC0P/TC0D/TC0E/TC0F/TC0H 封装/接近温度
enum SMCKeys {
    static let coreTemps = (1...8).map { "TC\($0)C" }
    static let packageTemps = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TC0p"]
    /// key: (名称, 单位)
    static let power: [(String, String, String)] = [
        ("PC0C", "CPU 电流", "A"),
        ("PC0R", "CPU 电流(读回)", "A"),
        ("PCPC", "封装电流", "A"),
        ("PCPR", "封装功率", "W"),
        ("PCPT", "封装总功率", "W"),
        ("PCTR", "CPU 总功率", "W"),
        ("PCAM", "电流(flt)", "A"),
        ("PCGC", "显示核心时钟", "GHz"),
        ("PCGM", "显示核心时钟", "GHz"),
        ("PCEC", "能效值", ""),
        ("PC3C", "核心电流", "A"),
        ("VC0C", "核心电压", "V"),
    ]
}

enum SMCSnapshot {
    /// 返回一份完整的传感器快照；SMC 不可用时 available=false。
    /// 输出形状与 Python smc.snapshot() 一致。
    static func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "available": false,
            "error": NSNull(),
            "key_count": 0,
            "cores": [[String: Any]](),
            "package": [[String: Any]](),
            "power": [[String: Any]](),
            "fan_available": false,
            "fan_note": NSNull(),
            "raw_temps": [String: Any](),
        ]

        do {
            let smc = try SMC()
            defer { smc.close() }
            out["available"] = true
            out["key_count"] = smc.keyCount()

            var cores: [[String: Any]] = []
            var packages: [[String: Any]] = []
            var powers: [[String: Any]] = []
            var rawTemps: [String: Any] = [:]

            for (i, key) in SMCKeys.coreTemps.enumerated() {
                if let v = smc.readValue(key) {
                    let rounded = (v * 10).rounded() / 10
                    cores.append(["name": "核心 \(i + 1)", "key": key, "celsius": rounded])
                    rawTemps[key] = rounded
                }
            }
            for key in SMCKeys.packageTemps {
                if let v = smc.readValue(key), v > 0 {
                    let rounded = (v * 10).rounded() / 10
                    packages.append(["name": key, "key": key, "celsius": rounded])
                    rawTemps[key] = rounded
                }
            }
            for (key, name, unit) in SMCKeys.power {
                if let v = smc.readValue(key), v != 0 {
                    powers.append(["key": key, "name": name, "unit": unit,
                                   "value": (v * 1000).rounded() / 1000])
                }
            }

            let fanNum = smc.readValue("FNum")
            let fac0 = smc.readValue("FAC0")
            let f0ac = smc.readValue("F0Ac")
            let hasFan = (f0ac ?? 0) != 0 || (fanNum ?? 0) != 0
            var fanKeys: [String: Any] = ["FNum": NSNull(), "FAC0": NSNull(), "F0Ac": NSNull()]
            if let v = fanNum { fanKeys["FNum"] = v }
            if let v = fac0 { fanKeys["FAC0"] = v }
            if let v = f0ac { fanKeys["F0Ac"] = v }

            out["cores"] = cores
            out["package"] = packages
            out["power"] = powers
            out["raw_temps"] = rawTemps
            out["fan_available"] = hasFan
            out["fan_keys"] = fanKeys
            if !hasFan {
                out["fan_note"] = ("SMC 的 FNum=0，即 VirtualSMC 没有建模风扇。"
                    + "风扇由 EC 固件独立控制，macOS 侧既读不到转速也写不了目标值。"
                    + "F0Ac / F0Mn / F0Mx / F0Tg 全部不存在。")
            }
        } catch let e as SmcError {
            out["error"] = "SMC 不可用: \(errorText(e))"
        } catch {
            out["error"] = "SMC 读取异常: \(error)"
        }
        return out
    }

    private static func errorText(_ e: SmcError) -> String {
        switch e {
        case .matchingFailed: return "IOServiceMatching(AppleSMC) 失败"
        case .serviceNotFound: return "系统中找不到 AppleSMC 服务"
        case .openFailed(let kr): return "IOServiceOpen 失败 (kern_return=\(kr))"
        case .callFailed(let kr): return "IOConnectCallStructMethod 失败 (kern_return=\(kr))"
        }
    }
}
