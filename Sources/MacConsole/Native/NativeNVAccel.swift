import Foundation
import IOKit

/// 独显（NVIDIA）利用率 —— 走 RM（Resource Manager）控制接口。
///
/// 背景：macOS 侧没有任何公开属性给出 NVIDIA 的 GPU 占用率。
/// exelban/Stats 读的是 `IOAccelerator.PerformanceStatistics["Device Utilization %"]`，
/// 但那张表是给驱动自己填的，N 卡驱动（nullmoth/nvidia-macos-driver）不填这一项，
/// 所以核显有值、独显永远是空。要拿到独显数字只能进 RM：
///
///   IOServiceOpen("NVAccel", type 0x4E560000)
///     → SEL_ESC(1) 通道
///     → NV_ESC_RM_ALLOC 建 NV01_ROOT_CLIENT(0x41)
///     → NV01_DEVICE_0(0x80) / NV0080_ALLOC
///     → NV20_SUBDEVICE_0(0x2080) / NV2080_ALLOC
///     → NV_ESC_RM_CONTROL 发 0x20802096
///        (NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2)
///
/// 协议来源：issue nullmoth/nvidia-macos-driver#324 里 GeekAudio 贴的 nvstatd.c，
/// 与 open-gpu-kernel-modules 的 ctrl id 一致。原作者的守护进程用 root 跑，
/// 本机实测**普通用户也能打开并拿到完整样本**（见坑 #63），所以不需要提权。
///
/// 这里所有结构体都用「原始字节 + 显式偏移」表达，不用 Swift struct：
/// Swift 的对齐规则和 C 在 `uint8_t type` 后面那道 3 字节 padding 上容易算错，
/// 而偏移错 4 字节就会读到别的字段且不报错——宁可按字节算，一眼能核对。
enum NVAccelUtil {

    // MARK: 常量

    private static let selEsc: UInt32 = 1
    private static let escRmAlloc: UInt32 = 0x2B
    private static let escRmControl: UInt32 = 0x2A
    private static let escRmFree: UInt32 = 0x29

    private static let clsRootClient: UInt32 = 0x41
    private static let clsDevice0: UInt32 = 0x80
    private static let clsSubdevice0: UInt32 = 0x2080

    private static let cmdPerfmonUtilV2: UInt32 = 0x2080_2096
    private static let sampleTypePerfmonUtil: UInt8 = 2
    private static let sampleCount = 72
    private static let sampleSize = 776          // sizeof(GPUMON_PERFMON_UTIL_SAMPLE)
    private static let paramsHeader = 16         // type/bufSize/count/tracker
    private static var paramsSize: Int { paramsHeader + sampleSize * sampleCount }   // 55888

    /// 样本内各引擎相对偏移（6 个引擎各 128 字节，紧接 8 字节 timeStamp）
    private static let offFb = 8
    private static let offGr = 8 + 128
    private static let offEnc = 8 + 256
    private static let offDec = 8 + 384

    // MARK: 状态

    private static let lock = NSLock()
    private static var conn: io_connect_t = 0
    private static var hClient: UInt32 = 0
    private static var hDevice: UInt32 = 0
    private static var hSubdev: UInt32 = 0
    private static var cached: [String: Any] = [:]
    private static var cachedAt: Double = 0
    private static var failCount = 0

    /// 缓存 2 秒：UI 1 秒轮询两次里只真正打一次 ioctl（单次约 30µs，但没必要更密）
    private static let ttl: Double = 2.0

    // MARK: 对外

    /// 返回：
    ///   available  —— 驱动是否提供 NVAccel 服务
    ///   reported   —— 驱动是否真的上报了利用率（本机该驱动为 false，见下）
    ///   gr/fb/enc/dec_pct —— 百分比（未上报时为 0）
    ///
    /// 为什么要单列 `reported`：本机驱动（2.4.3 + NVK）会把整个样本结构写回来
    /// （时间戳递增、6 个引擎块结构完整、procId 恒为 0xFFFFFFFF），但 util 恒为 0，
    /// 即便用 Metal 把独显压到满载（实测单次 dispatch 80ms）也是 0。
    /// 也就是说这条 ctrl 在当前驱动上是「形状对、数值空」。
    /// 界面据此显示「驱动未上报」而不是一个假的 0%，避免把不可用当空闲。
    static func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if now - cachedAt < ttl, !cached.isEmpty { return cached }

        var out: [String: Any] = [
            "available": false,
            "reported": false,
            "gr_pct": 0, "fb_pct": 0, "enc_pct": 0, "dec_pct": 0,
        ]
        guard let svc = service() else {
            cached = out; cachedAt = now
            return out
        }
        defer { IOObjectRelease(svc) }
        out["available"] = true

        guard connect(svc) else {
            cached = out; cachedAt = now
            return out
        }

        guard let raw = query() else {
            // 连续失败可能是 GPU 复位，重建连接后再试一次
            failCount += 1
            if failCount >= 2 {
                closeConnection()
                failCount = 0
            }
            cached = out; cachedAt = now
            return out
        }
        failCount = 0

        let gr = raw.gr, fb = raw.fb
        out["gr_pct"] = Double(gr) / 100
        out["fb_pct"] = Double(fb) / 100
        out["enc_pct"] = Double(raw.enc) / 100
        out["dec_pct"] = Double(raw.dec) / 100
        // 只要任一引擎有非零值，就认为驱动确实在上报
        out["reported"] = (gr + fb + raw.enc + raw.dec) > 0
        out["proc_id"] = raw.procId
        cached = out
        cachedAt = now
        return out
    }

    /// 连接状态（诊断用）
    static var connected: Bool {
        lock.lock(); defer { lock.unlock() }
        return hSubdev != 0
    }

    // MARK: 底层

    private static func service() -> io_service_t? {
        for name in ["NVAccel", "NVRM"] {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if svc != 0 { return svc }
        }
        return nil
    }

    private static func closeConnection() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
        hClient = 0; hDevice = 0; hSubdev = 0
    }

    @discardableResult
    private static func connect(_ svc: io_service_t) -> Bool {
        if hSubdev != 0 { return true }
        if conn == 0 {
            var c: io_connect_t = 0
            let kr = IOServiceOpen(svc, mach_task_self_, 0x4E56_0000, &c)
            guard kr == KERN_SUCCESS else { return false }
            conn = c
        }
        hClient = alloc(0, clsRootClient, nil, 0)
        guard hClient != 0xFFFF_FFFF else { closeConnection(); return false }

        // NV0080_ALLOC：deviceId@0, hClientShare@4, hTargetClient@8,
        // hTargetDevice@12, flags@16, vaSpaceSize@24, vaStart@32, vaLimit@40, vaMode@48
        let a80 = UnsafeMutableRawPointer.allocate(byteCount: 56, alignment: 8)
        memset(a80, 0, 56)
        a80.storeBytes(of: hClient, toByteOffset: 4, as: UInt32.self)
        hDevice = alloc(hClient, clsDevice0, a80, 56)
        a80.deallocate()
        guard hDevice != 0xFFFF_FFFF else { closeConnection(); return false }

        let a2080 = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        a2080.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
        hSubdev = alloc(hDevice, clsSubdevice0, a2080, 4)
        a2080.deallocate()
        guard hSubdev != 0xFFFF_FFFF else { closeConnection(); return false }
        return true
    }

    /// 一发 escape：`IOConnectCallMethod(conn, SEL_ESC, &cmd, 1, 结构体入, 结构体出)`
    /// 同一个缓冲区既作入参又作出参，与 nvstatd.c 一致（驱动就地改写 status/hObjectNew）。
    private static func esc(_ cmd: UInt32, _ buf: UnsafeMutableRawPointer, _ size: Int) -> Bool {
        var cmdIn = UInt64(cmd)
        var outSize = size
        let kr = IOConnectCallMethod(conn, selEsc, &cmdIn, 1,
                                     buf, size, nil, nil, buf, &outSize)
        return kr == KERN_SUCCESS
    }

    /// NVOS21（32B）：hRoot@0 hObjectParent@4 hObjectNew@8 hClass@12 pAllocParms@16 paramsSize@24 status@28
    private static func alloc(_ parent: UInt32, _ cls: UInt32,
                              _ parms: UnsafeMutableRawPointer?, _ parmsSize: Int) -> UInt32 {
        let b = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { b.deallocate() }
        memset(b, 0, 32)
        b.storeBytes(of: hClient, toByteOffset: 0, as: UInt32.self)
        b.storeBytes(of: parent, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: cls, toByteOffset: 12, as: UInt32.self)
        b.storeBytes(of: UInt64(UInt(bitPattern: parms)), toByteOffset: 16, as: UInt64.self)
        b.storeBytes(of: UInt32(parmsSize), toByteOffset: 24, as: UInt32.self)
        guard esc(escRmAlloc, b, 32) else { return 0xFFFF_FFFF }
        guard b.load(fromByteOffset: 28, as: UInt32.self) == 0 else { return 0xFFFF_FFFF }
        return b.load(fromByteOffset: 8, as: UInt32.self)
    }

    /// NVOS54（32B）：hClient@0 hObject@4 cmd@8 flags@12 params@16 paramsSize@24 status@28
    private static func control(_ h: UInt32, _ cmd: UInt32,
                               _ parms: UnsafeMutableRawPointer, _ size: Int) -> UInt32 {
        let b = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { b.deallocate() }
        memset(b, 0, 32)
        b.storeBytes(of: hClient, toByteOffset: 0, as: UInt32.self)
        b.storeBytes(of: h, toByteOffset: 4, as: UInt32.self)
        b.storeBytes(of: cmd, toByteOffset: 8, as: UInt32.self)
        b.storeBytes(of: UInt64(UInt(bitPattern: parms)), toByteOffset: 16, as: UInt64.self)
        b.storeBytes(of: UInt32(size), toByteOffset: 24, as: UInt32.self)
        guard esc(escRmControl, b, 32) else { return 0xFFFF_FFFF }
        return b.load(fromByteOffset: 28, as: UInt32.self)
    }

    private struct Sample {
        var gr: UInt32, fb: UInt32, enc: UInt32, dec: UInt32, procId: UInt32
    }

    private static func query() -> Sample? {
        let p = UnsafeMutableRawPointer.allocate(byteCount: paramsSize, alignment: 8)
        defer { p.deallocate() }
        memset(p, 0, paramsSize)
        p.storeBytes(of: sampleTypePerfmonUtil, toByteOffset: 0, as: UInt8.self)
        p.storeBytes(of: UInt32(sampleSize * sampleCount), toByteOffset: 4, as: UInt32.self)

        let st = control(hSubdev, cmdPerfmonUtilV2, p, paramsSize)
        guard st == 0 else { return nil }

        // samples[0] 起点在 16；引擎块内 util@0、procId@8
        func u(_ engineOff: Int) -> UInt32 {
            p.load(fromByteOffset: paramsHeader + engineOff, as: UInt32.self)
        }
        return Sample(gr: u(offGr), fb: u(offFb), enc: u(offEnc), dec: u(offDec),
                      procId: u(offGr + 8))
    }
}
