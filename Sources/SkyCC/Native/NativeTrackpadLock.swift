//
//  NativeTrackpadLock.swift
//  Sky CC —— 触控板锁定（固件开关为主，HID 独占兜底）
//
//  ── 为什么不用 EC 的 CTRL_4 bit6 ──
//
//  qc71 的 ec.h 里有 `CTRL_4_TOUCHPAD_TOGGLE_OFF = BIT(6)`（0x07A6），
//  内核 uniwill-laptop 驱动也只用这一位。本机实测：写 0x40 回读成功并保持，
//  把 EC 页 0x0700–0x07FF 整页 dump 前后对比，**只有这 1 个字节变化**，
//  EC 不响应、不清除、无任何联动位 —— 它是状态镜像，不是命令位；
//  LKML 上 Uniwill 驱动的作者也明确写了 touchpad_toggle 属性「不生效，原因不明」。
//  全表里也不存在任何「触控板 LED」寄存器（0x07A5 是电源 LED，0x078C 是键盘背光）。
//
//  ── 正解：触控板自己的固件开关 ──
//
//  真实硬件是 I2C 上的 PixArt 093A:0255，它的 HID 报告描述符里带一条：
//
//      Report ID 0x07 —— Usage Page 0x0D(Digitizer)
//          bit0 = Surface Switch (0x57)
//          bit1 = Button Switch  (0x58)
//
//  这是**固件级**的「关掉触摸面/按键」开关，不是拦输入：
//  写 0x00 → 触控板自己停机，左上角那颗指示灯同步点亮（本机实测）；
//  写 0x03 → 恢复，灯灭。这也解释了为什么 OEM 手势能点灯 —— 走的就是这条路。
//  读同一个报告即可拿到真实状态（0x03 = 启用），不用再靠软件记忆。
//
//  ── 兜底 ──
//
//  万一固件通道打不开（无权限 / 设备不在），退回输入层独占：
//  IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice) 独占 VoodooInput 发布的
//  虚拟触控板，系统收不到触摸事件。功能可用，但灯不会亮。
//
//  【权限】两条路都要「输入监控」（kTCCServiceListenEvent），与 uid 无关；
//  app 进程 com.skycc.console 已获授权，所以实际调用走 NativeAPI 进程内。
//  句柄只存在内存里，进程结束自动释放，不会出现「锁死开不回来」。
//

import Foundation
import IOKit
import IOKit.hid

enum TrackpadLock {

    private static let lock = NSLock()
    /// 当前独占着的设备句柄（空 = 未走 HID 独占）
    private static var held: [HIDDevice] = []

    // MARK: - 固件开关常量

    private static let padVID = 0x093A          // PixArt
    private static let padPID = 0x0255
    private static let switchReportID: CFIndex = 0x07
    /// bit0 Surface Switch + bit1 Button Switch
    private static let switchOn: UInt8 = 0x03

    /// 固件状态缓存（避免 1 秒轮询反复开设备读报告）
    private static var fwDisabled = false
    private static var lastProbe = Date.distantPast

    // MARK: - 状态

    /// 触控板是否处于「已禁用」。固件位优先，回落 HID 独占。
    static var locked: Bool {
        lock.lock(); defer { lock.unlock() }
        let fw = probeFirmware() ?? fwDisabled
        return fw || !held.isEmpty
    }

    /// 完整状态（**只能在本进程读**，见下方「跨进程陷阱」）
    ///
    /// 跨进程陷阱（2026-11-17 用户报 bug 的根因）：
    /// 写走 app 进程（有「输入监控」），而快照 `/api/fan` 的 misc 由 helper 进程生成；
    /// helper 打不开 HID（open 返回 -536870174），`probeFirmware()` 返回 nil，
    /// 旧代码于是回落到进程内缓存 `fwDisabled`（默认 false）——**helper 永远报「未禁用」**。
    /// UI 每秒拿这个假值覆盖开关，表现就是「明明关了，开关又自己弹回打开」。
    /// 现在 helper 的 misc 不再报这一项，本卡直接在本进程读这里。
    static func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let fw = probeFirmware()            // nil = 读不到（无权限 / 设备不在）
        let seized = held.count
        let isLocked = (fw ?? fwDisabled) || seized > 0
        var out: [String: Any] = [
            "locked": isLocked,
            "enabled": !isLocked,
            "seized": seized,
            "probed": fw != nil,
            "via": fw != nil ? (seized > 0 ? "firmware+seize" : "firmware-switch")
                             : (seized > 0 ? "hid-seize" : "unavailable"),
        ]
        if let fw { out["firmware_disabled"] = fw }
        return out
    }

    // MARK: - 开关

    /// 锁定/解锁触控板（on = 锁定）。返回 {ok, locked, devices, via} 或 {ok:false, error}
    static func set(_ on: Bool) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        // 1) 首选：固件开关（连同左上角指示灯）
        if let err = firmwareWrite(disabled: on) {
            // 2) 兜底：HID 独占（灯不亮，但输入能拦住）
            return seizeSet(on, firmwareError: err)
        }

        // 固件已接管，把可能残留的独占句柄放掉，避免双重状态
        held.forEach { $0.close() }
        held = []
        return ["ok": true, "locked": on, "devices": 0,
                "via": "firmware-switch", "led": true]
    }

    /// 无论如何都放开（helper 启动时兜底调用，防上次残留把触控板锁死）
    static func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        held.forEach { $0.close() }
        held = []
        _ = firmwareWrite(disabled: false)
    }

    // MARK: - 固件开关实现

    private static func padDevice() -> HIDDevice? {
        let all = NativeHID.findDevices(vendorID: padVID, productID: padPID)
        if let i2c = all.first(where: { ($0.info()["Transport"] as? String) == "I2C" }) {
            return i2c
        }
        return all.first
    }

    /// 读 Switch 报告的当前值（0x03 = 启用；低 2 位为 0 = 已禁用）
    private static func firmwareRead(_ dev: HIDDevice) -> UInt8? {
        let (kr, data) = dev.getReport(16, reportType: kIOHIDReportTypeFeature,
                                       reportID: switchReportID)
        guard kr == KERN_SUCCESS, let data, !data.isEmpty else { return nil }
        // macOS 回填时首字节带 Report ID，个别固件不带，两种都认
        if data.count > 1, data[0] == UInt8(truncatingIfNeeded: switchReportID) {
            return data[1]
        }
        return data[0]
    }

    /// 写 Switch 报告。成功返回 nil，失败返回原因
    private static func firmwareWrite(disabled: Bool) -> String? {
        guard let dev = padDevice() else { return "未找到触控板 \(String(format: "%04X:%04X", padVID, padPID))" }
        do {
            try dev.open()
        } catch {
            return error.localizedDescription
        }
        defer { dev.close() }

        let want: UInt8 = disabled ? 0x00 : switchOn
        let kr = dev.setReport([want], reportType: kIOHIDReportTypeFeature,
                               reportID: switchReportID)
        guard kr == KERN_SUCCESS else {
            return "写 Feature Report 0x07 失败 (kern_return=\(kr))"
        }
        if let back = firmwareRead(dev), (back & switchOn) != want {
            return String(format: "回读校验不一致（0x%02X）", back)
        }
        fwDisabled = disabled
        lastProbe = Date()
        return nil
    }

    /// 每秒最多探一次真实状态
    private static func probeFirmware() -> Bool? {
        if Date().timeIntervalSince(lastProbe) < 1.0 { return fwDisabled }
        guard let dev = padDevice() else { return nil }
        do {
            try dev.open()
        } catch {
            return nil
        }
        defer { dev.close() }
        guard let v = firmwareRead(dev) else { return nil }
        lastProbe = Date()
        fwDisabled = (v & switchOn) == 0
        return fwDisabled
    }

    // MARK: - HID 独占兜底

    private static func seizeSet(_ on: Bool, firmwareError: String) -> [String: Any] {
        if on {
            if !held.isEmpty {
                return ["ok": true, "locked": true, "devices": held.count,
                        "via": "hid-seize", "led": false, "firmware_error": firmwareError]
            }
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
                        "error": firstError ?? "没有找到可独占的触控板设备",
                        "firmware_error": firmwareError]
            }
            held = picked
            return ["ok": true, "locked": true, "devices": picked.count,
                    "via": "hid-seize", "led": false, "firmware_error": firmwareError]
        }

        held.forEach { $0.close() }
        held = []
        return ["ok": true, "locked": false, "devices": 0,
                "via": "hid-seize", "led": false, "firmware_error": firmwareError]
    }

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
