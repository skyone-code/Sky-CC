//
//  NativeTrackpadLock.swift
//  Mac控制台 —— 触控板锁定（软件独占，2.7.7）
//
//  ── 为什么不用 EC 的 CTRL_4 bit6 ──
//
//  qc71 的 ec.h 确实有 `CTRL_4_TOUCHPAD_TOGGLE_OFF = BIT(6)`（0x07A6），
//  但本机实测：写入成功、回读 0x40 也确实保持，**却没有任何效果**。
//  全量 `ioreg -l` 前后对比只有 IOKitDiagnostics 的计数噪声，设备树毫无变化；
//  触控板照常工作。原因很明确 —— 本机触控板走 I2C，由 VoodooI2C + VoodooInput
//  驱动，它在系统里发布的是一个**虚拟设备**：
//
//      name="Magic Trackpad 2"  transport=I2C  vid=0x05AC pid=0x0281
//      serial="Voodoo Magic Trackpad 2 Simulator"
//
//  而真实硬件是同一路 I2C 上的 vid=0x093A pid=0x0255（Elan）。
//  EC 那个位的语义是「让 EC 关掉 PS/2/SMBus 触控口」，对一条第三方 kext
//  自己在跑的 I2C 链路没有任何约束力 —— 所以写进去等于石沉大海。
//
//  ── 现在的做法 ──
//
//  从输入层解决：用 IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice)
//  独占 VoodooInput 发布的那块虚拟触控板，系统就收不到触摸事件了，
//  松开句柄即恢复。这也是 Karabiner 一类工具拦输入用的同一种机制。
//
//  【必须 root】普通用户调用一律返回 kIOReturnNotPermitted(-536870174)，
//  本机实测 4 个指针类设备全部如此。调用方是 MacConsoleHelper（LaunchDaemon，
//  root 身份），所以从 helper 里调用是可行的；app 进程直接调用会失败并如实报错。
//
//  【安全】句柄只存在内存里：helper 退出/崩溃 → 进程结束 → 句柄自动释放，
//  触控板立刻恢复，不会出现「锁死了再也开不回来」。
//

import Foundation
import IOKit
import IOKit.hid

enum TrackpadLock {

    private static let lock = NSLock()
    /// 当前独占着的设备句柄（空 = 未锁定）。持有引用 = 持有独占。
    private static var held: [HIDDevice] = []

    // MARK: - 状态

    static var locked: Bool {
        lock.lock(); defer { lock.unlock() }
        return !held.isEmpty
    }

    // MARK: - 开关

    /// 锁定/解锁触控板。返回 {ok, locked, devices} 或 {ok:false, error}
    static func set(_ on: Bool) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        if on {
            if !held.isEmpty { return ["ok": true, "locked": true, "devices": held.count] }
            var picked: [HIDDevice] = []
            var firstError: String?
            for d in candidates() {
                do {
                    try d.open(seize: true)
                    picked.append(d)
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            guard !picked.isEmpty else {
                return ["ok": false, "locked": false,
                        "error": firstError ?? "没有找到可独占的触控板设备"]
            }
            held = picked
            return ["ok": true, "locked": true, "devices": picked.count]
        }

        held.forEach { $0.close() }
        held = []
        return ["ok": true, "locked": false, "devices": 0]
    }

    /// 无论如何都放开（helper 启动时兜底调用，防上次残留）
    static func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        held.forEach { $0.close() }
        held = []
    }

    // MARK: - 候选设备

    /// 优先 VoodooInput 的模拟器（真正喂给系统的那一个），
    /// 退而求其次才是 I2C 上的其他指针设备。
    private static func candidates() -> [HIDDevice] {
        var pointer: [HIDDevice] = []
        // 指针类：usagePage 1 (Generic Desktop) / usage 2 (Mouse)，
        // 有的触控板报在 0x0D (Digitizer) 下，两处都扫
        for up in [1, 0x0D] {
            for d in NativeHID.findDevices(usagePage: up) where d.usage == 2 {
                pointer.append(d)
            }
        }

        var simulator: [HIDDevice] = []
        var i2c: [HIDDevice] = []
        for d in pointer {
            let info = d.info()
            let serial = (info["SerialNumber"] as? String) ?? ""
            let transport = (info["Transport"] as? String) ?? ""
            if serial.contains("Voodoo") {
                simulator.append(d)
            } else if transport == "I2C" {
                i2c.append(d)
            }
        }
        if !simulator.isEmpty { return simulator }
        return i2c
    }
}
