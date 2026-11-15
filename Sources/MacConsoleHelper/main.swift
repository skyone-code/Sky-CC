import Foundation

/// MacConsoleHelper：唯一持有硬件（EC / SMC / HID / 亮度）的后台进程。
///
/// 为什么要有这个进程（2026-10-22 用户决策）：
///   ① EC 是**独占串行**通道（单次读 ~65ms，物理上限 ~15 次/秒）。以前 UI 进程
///      自己读，UI 一崩、一重开、一多开就会撞车，实测 /api/fan 从 4s 退化到 16s。
///      收成一个进程后，launchd 保证全局只有一个持有者。
///   ② 风扇曲线守护必须比 UI 活得久。UI 关窗/崩溃/被 Kill 都不该让散热失控。
///   ③ 崩溃隔离：EC 驱动偶发把调用方搞崩（历史上有过），崩在 helper 里由 launchd
///      2 秒内拉起，UI 只是短暂「离线」，不会跟着死。
///
/// 进程形态：LaunchAgent（Mach service `com.macconsole.helper`），由 SMAppService
/// 从 app 内 `Contents/Library/LaunchAgents/` 注册，用户身份运行，无需 root。

// MARK: - 日志

private let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/macconsole-helper.log")

private let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    return f
}()

func hlog(_ s: String) {
    let line = "\(logFmt.string(from: Date())) [\(getpid())] \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    // 超过 512KB 就截断重来，避免日志无限长（这是守护进程，一跑几个月）
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? Int, size > 512 * 1024 {
        try? FileManager.default.removeItem(at: logURL)
    }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - 单实例锁
//
// launchd 已经保证同 label 只跑一个，但如果有人从终端手点二进制（排障时很可能），
// 就会出现第二个 EC 读者。用 flock 兜住：拿不到锁直接退，不抢硬件。

private var lockFD: Int32 = -1

func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("helper.lock").path
    lockFD = open(path, O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0 else { return false }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        close(lockFD)
        lockFD = -1
        return false
    }
    let pidText = "\(getpid())\n"
    ftruncate(lockFD, 0)
    _ = pidText.withCString { write(lockFD, $0, strlen($0)) }
    return true
}

// MARK: - XPC 服务

final class HelperService: NSObject, MCHelperProtocol {

    func mcGet(_ path: String, reply: @escaping ([String: Any]) -> Void) {
        guard let v = NativeAPI.handleGet(path) else {
            hlog("GET \(path) → 未知路径")
            reply(["ok": false, "error": "unknown path \(path)"])
            return
        }
        reply(["ok": true, "data": v])
    }

    func mcPost(_ path: String, params: [String: Any],
                reply: @escaping ([String: Any]) -> Void) {
        // 生命周期动作在 helper 本地处理，不进 NativeAPI（那是硬件/业务路由）
        if path == "/api/helper/shutdown" {
            // 升级 / 手动重启专用：**必须非零退出**。plist 的 KeepAlive 是
            // SuccessfulExit=false —— 非零才会被 launchd 用新二进制拉起来；
            // 写成 exit(0) 会变成「请求重启结果彻底没进程」。
            hlog("收到 shutdown 请求，退出以便 launchd 拉起新版本")
            reply(["ok": true])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                hlog("exit(75) —— 非零退出，交给 launchd 重启")
                exit(75)
            }
            return
        }
        // 「退出控制台」专用（2026-11-13 用户要求）：把机器完整交还，然后正常退出。
        //   ① 停曲线 / 交还风扇档位 —— helper 一走就没人守散热了，不能留着手动档位；
        //   ② 清 0x741 bit0 —— 原厂语义「退出时清 0」，键盘背光回到固件空闲熄灯策略；
        //   ③ exit(0) —— SuccessfulExit=false 下 launchd **不会**再拉起。
        //      下次打开控制台时 XPC 连过来，MachServices 会按需把它启动起来。
        if path == "/api/helper/quit-all" {
            hlog("收到 quit-all：停曲线 → 交还风扇 → 清 0x741 bit0 → exit(0)")
            FanCurveController.shared.stop()
            let handBack = FanControl.shared.releaseManualDoor()
            let cleared = FanControl.shared.clearAPPresentOnExit()
            let c1 = FanControl.shared.appPresentState().raw
            hlog("quit-all: 交还档位 ok=\(handBack?.ok ?? false) 清 bit0 ok=\(cleared?.ok ?? false) ctrl1=0x\(String(c1, radix: 16))")
            reply(["ok": true,
                   "released": handBack?.ok ?? false,
                   "cleared": cleared?.ok ?? false,
                   "ctrl1": Int(c1)])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                hlog("exit(0) —— 正常退出，launchd 不再拉起")
                exit(0)
            }
            return
        }
        guard let v = NativeAPI.handlePost(path, params) else {
            hlog("POST \(path) → 未知路径")
            reply(["ok": false, "error": "unknown path \(path)"])
            return
        }
        reply(["ok": true, "data": v])
    }

    func mcPing(_ reply: @escaping ([String: Any]) -> Void) {
        reply([
            "ok": true,
            "version": mcHelperBuildVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "kext": FanControl.kextLoaded(),
            "curve_active": FanCurveController.shared.active,
            "boot_at": bootEpoch,
        ])
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: MCHelperProtocol.self)
        conn.exportedObject = service
        conn.invalidationHandler = { hlog("客户端断开") }
        conn.resume()
        return true
    }
}

// MARK: - main

let bootEpoch = Int(Date().timeIntervalSince1970)

guard acquireSingleInstanceLock() else {
    hlog("已有实例持有硬件锁，本进程退出")
    exit(0)
}

hlog("helper 启动 version=\(mcHelperBuildVersion) exe=\(CommandLine.arguments.first ?? "?")")

let listener = NSXPCListener(machServiceName: mcHelperServiceName)
let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
hlog("XPC 监听就绪：\(mcHelperServiceName)")

// 硬件初始化放后台：startupSequence 会写 EC（风扇模式/键盘灯），阻塞几百毫秒到几秒，
// 不能挡住 XPC 接客，否则 UI 首帧必然超时。
DispatchQueue.global(qos: .userInitiated).async {
    // 2.7.7：触控板锁是「持有 HID 独占句柄」实现的，进程一死句柄就释放，
    // 所以正常情况下这里无事可做；留着是为了万一将来做成持久化锁，
    // 重启时能明确放开，不会出现「触控板永久锁死」。
    TrackpadLock.releaseAll()
    // AP exist 常驻：先把 EC 0x741 bit0 立起来 —— 这是「控制中心接管」标志
    // （文档 §4.2，原厂打开软件即下发），也是键盘灯 10 分钟熄灯的开关；
    // 再跑启动序列，序列里的风扇对账会看这一位决定能不能写寄存器。
    ECAPPresentKeeper.start()
    // 3.0.4.3：移除睡眠守卫。用户实测 0x741 bit0 全程为 0 时仍会在进 S3 后 25ms
    // 被一个未知 GPE 弹回，说明这一位与「睡下即醒」无关；守卫反而因 didWake 偶发
    // 不送达而把 holdSuspended 卡在 true，导致 bit0 再也不置 1。此处恢复原行为。
    hlog("开始启动序列（恢复散热模式 / 键盘灯 / 亮度守护）")
    NativeAPI.startupSequence()
    // 独显利用率预热：让第一份 /api/snapshot 就带上 dgpu 的真值。
    // 不预热的话首秒 payload 里 available=false，界面会闪一下「未找到 NVAccel 服务」。
    // 现在只是读一次 IORegistry 把本地滑动窗口填上第一拍（驱动 2.6.3 自己每秒采样）。
    NVAccelUtil.warmUp()
    // 灯效保活（闲置熄灯修补，见 NativeRGB.swift 的 RGBKeepAlive）
    RGBKeepAlive.start()
    hlog("启动序列完成，开启 EC 采样器")
    NativeAPI.startSampler()
}

dispatchMain()
