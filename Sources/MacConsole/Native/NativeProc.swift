//
//  NativeProc.swift
//  Mac控制台 —— 子进程执行（硬超时 + 信号逐级升级）
//
//  为什么需要它：Process.waitUntilExit() 是无界等待。子进程一旦卡在内核调用里
//  （2026-10-20 实测：屏幕休眠后面板断电，DPCD 类调用会卡死，
//  SIGTERM 也杀不掉），调用线程就被永久挂死——HTTP 服务线程挂一个，整个后端
//  无响应，只能杀进程。所有跑在服务路径上的子进程都必须走这里。
//
//  策略：timeout 到点 → SIGTERM → 0.5s 不退 → SIGKILL → 最多再等 2s → 放弃等待
//  （SIGKILL 都杀不掉的只可能是不可中断的 D 状态，等也没用，直接丢句柄）。
//

import Foundation

enum NativeProc {

    /// 跑命令抓 stdout。
    /// - Returns: (输出文本, 是否「正常退出且 status==0」)
    ///
    /// 必须「边跑边读」：pipe 的缓冲区只有 64KB（big pipe 也一样有限），
    /// 子进程输出一旦超过它就会阻塞在 write 上；而我们又在 waitpid 等它退出
    /// —— 双方互等，只能靠 timeout 兜底。2.5.4 实测：ps 从 3 列扩到 11 列后
    /// 输出约 90KB，/api/processes 从 50ms 变成 14–16s（全是超时 + 重试）。
    static func runCapture(_ launchPath: String, _ args: [String],
                           timeout: TimeInterval = 6) -> (out: String, ok: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ("", false)
        }

        // 后台线程持续抽干管道，主线程只管等进程退出
        let lock = NSLock()
        var collected = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            collected = d
            lock.unlock()
            group.leave()
        }

        if !waitBounded(p, timeout) {
            p.terminate()                                   // SIGTERM 礼让
            if !waitBounded(p, 0.5) {
                kill(p.processIdentifier, SIGKILL)          // 不识趣就杀
                _ = waitBounded(p, 2)                       // 最后兜底
            }
        }
        // 进程已退出 → 管道写端关闭 → 读线程随即读到 EOF；
        // 仍给 2s 兜底，避免极端情况下读线程卡住把服务线程带走
        _ = group.wait(timeout: .now() + 2)
        lock.lock()
        let data = collected
        lock.unlock()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (out, !p.isRunning && p.terminationStatus == 0)
    }

    /// 轮询等待至多 seconds；返回进程是否已退出
    private static func waitBounded(_ p: Process, _ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline {
            usleep(20_000)
        }
        return !p.isRunning
    }
}
