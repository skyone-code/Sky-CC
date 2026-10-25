import Foundation

/// 面板 PWM 模式保持（2.8.11）
///
/// 用户要求：**不要多一条登录项**，pwmwake 挂在 MacConsoleHelper 下面跑。
///
/// 设计要点：
///   · helper 自己就是 launchd 的 LaunchAgent（KeepAlive），helper 活着 pwmwake 就在；
///     helper 崩溃/升级重启时这里会重新拉一个 —— 等于「借」helper 那条登录项，
///     用户登录项列表里只有 helper 一条，看不到 pwmwake。
///   · pwmwake 只做一件事：把面板 DPCD 0x721 盯在 0x08（PWM 模式），
///     好让 macOS 原生亮度链路能驱动屏幕。**它不参与亮度调节**（亮度读写已从
///     控制台移除，走系统「显示器 → 亮度」）。
///   · 先 pgrep 再拉：helper 升级时子进程可能被 reparent 到 launchd 变成孤儿，
///     直接再拉一个会出现两个守护抢着写 DPCD。
enum PwmKeeper {

    /// 子进程句柄（只用于本进程内判断 + 退出时清理）
    private static var child: Process?
    private static let logPath = NSHomeDirectory() + "/Library/Logs/pwmwake.out.log"

    /// 随包的 pwmwake（Contents/Resources/native/bin/pwmwake）
    static func binaryURL() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        for rel in ["native/bin/pwmwake", "python/bin/pwmwake"] {
            let u = res.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }

    /// 已有 pwmwake 在跑吗（命令行精确匹配，避免误中带 pwmwake 字样的其它进程）
    static func isRunning() -> Bool {
        NativeProc.runCapture("/usr/bin/pgrep", ["-f", "(^|/)pwmwake$"], timeout: 3).ok
    }

    /// helper 启动时调用（幂等）。找不到二进制就安静跳过 —— 亮度功能已不在控制台，
    /// 缺 pwmwake 只影响睡眠唤醒后的亮度滑条，不影响风扇/灯效。
    @discardableResult
    static func startIfNeeded() -> Bool {
        guard let bin = binaryURL() else {
            print("[pwm] 包内没有 pwmwake，跳过面板模式保持")
            return false
        }
        if child?.isRunning == true {
            print("[pwm] pwmwake 子进程在运行")
            return true
        }
        if isRunning() {
            print("[pwm] 已有 pwmwake 在运行（可能是上一个 helper 留下的），不重复拉起")
            return true
        }
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let p = Process()
        p.executableURL = bin
        if let h = FileHandle(forWritingAtPath: logPath) {
            _ = try? h.seekToEnd()
            p.standardOutput = h
            p.standardError = h
        }
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            child = p
            print("[pwm] pwmwake 已由 helper 拉起 (pid \(p.processIdentifier))")
            return true
        } catch {
            print("[pwm] pwmwake 启动失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 立刻把模式钉一次（登录/唤醒这类事件之外，helper 启动时补一针）
    static func ensureOnce() {
        guard let bin = binaryURL() else { return }
        _ = NativeProc.runCapture(bin.path, ["ensure"], timeout: 5)
    }

    /// helper 退出时收掉子进程，避免留下孤儿
    static func stop() {
        if let c = child, c.isRunning {
            c.terminate()
            print("[pwm] 已结束 pwmwake 子进程")
        }
        child = nil
    }
}
