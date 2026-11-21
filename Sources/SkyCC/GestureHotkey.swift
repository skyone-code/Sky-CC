import Foundation
import AppKit
import IOKit
import IOKit.hid

/// 触控板左上角「双击锁定」手势的接管（2.7.8 → 2026-11-18 改 F13 直捕）
///
/// ## 实测证据（2026-10-22，本机 qc71 + VoodooI2C / VoodooPS2）
///
/// 用 IOHIDManager 监听 `Keyboard[PS2]`（VoodooPS2Keyboard 模拟，vid=0x05AC pid=0xFFFF）
/// 抓到的原始事件序列 —— 每次双击触控板左上角，都会在 5 毫秒内吐出这一组：
///
///     12:10:27.895  page=7 usage=227 value=1   ← Left GUI（Command）按下
///     12:10:27.893  page=7 usage=224 value=1   ← Left Control 按下
///     12:10:27.895  page=7 usage=104 value=1   ← F13 按下
///     12:10:27.900  page=7 usage=104 value=0   ← F13 抬起
///     12:10:27.905  usage=224 value=0
///     12:10:27.911  usage=227 value=0
///
/// 整组 5 毫秒完成，人手不可能按出这个速度 —— 设备合成的事件。
/// 即：**触控板固件 → EC → PS2 键盘控制器 → VoodooPS2Keyboard → 合成 Ctrl+Cmd+F13**。
///
/// ## 为什么 2026-11-18 之前用 Carbon 热键、之后改 IOHIDManager 直捕 F13
///
/// 旧实现：`RegisterEventHotKey(Ctrl+Cmd+F13)` —— 好处是不需要隐私权限。
/// 但修饰键匹配有个天然死穴：**用户在系统层重映射修饰键**（系统设置「修饰键」
/// 面板，或任意 hidutil 通道）会把合成组合里的 Ctrl / Cmd 改写成别的键
/// （比如 Cmd→无操作 后，固件合成的 Ctrl+Cmd+F13 到系统层就只剩 Ctrl+F13），
/// Carbon 热键失配，双击就「没反应」。2026-11-18 用户实锤踩中。
///
/// 新实现：IOHIDManager 监听同一设备的**原始元素事件**，只认 **F13（usage 0x68 /
/// page 0x07）按下**，完全不看修饰键 —— 修饰键映射怎么改，F13 都原样到达
/// （重映射表只覆盖 E0–E7 修饰键）。彻底免疫修饰键重映射。
///
/// 权限：IOHIDManager 收键盘原始事件需要「输入监控」授权。旧实现选 Carbon 就是为了
/// 绕开它，但触控板锁定的真正执行（kIOHIDOptionsTypeSeizeDevice，见 TrackpadAPI）
/// **本来就必须**有这个权限，app 的 bundle id 也早已在 TCC 名单里 —— 所以这个
/// 顾虑不再成立，切直捕没有额外成本。授权检查保留在 fire() 里（未授权时引导）。
///
/// 另外旧实现的「激活策略切换会打掉 Carbon 热键」的坑（2.7.8 装机版失效的原因）
/// 在 IOHIDManager 路径上不存在 —— observe 型监听与 WindowServer 无关，
/// `reregister()` 保留为兼容空操作。
///
/// ## 其余行为不变
///
/// 收到 F13 按下 → 切换触控板锁定，与控制页「触控板」开关走同一后端
/// （`touchpad_toggle` → HID 独占）。锁定灯是 EC 0x07A6 bit6 的活，
/// macOS 下拿不到 LED 控制权（见 NativeTrackpadLock.swift 头注）。
final class GestureHotkey {
    static let shared = GestureHotkey()

    /// 同一手势的去抖窗口。双击本身是两下轻点（间隔约 150-300ms），
    /// 固件合成一组事件；留 0.4s 既能合并偶发的双发（含双设备重复上报），
    /// 又不会吃掉连续两次独立双击。
    private let debounce: TimeInterval = 0.4
    private var lastFire = Date.distantPast

    /// 授权引导只在每次启动时弹一次，避免连点刷屏
    private var guidanceShown = false
    private var restartHintShown = false

    private var manager: IOHIDManager?
    private(set) var registered = false

    /// 诊断日志（`log show` 在沙箱里读不出来，只能自己落文件）
    private let logPath = "/tmp/mcgesture.log"

    private init() {}

    // MARK: - 诊断

    private func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(s)\n"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 注册（IOHIDManager 直捕 F13）

    /// 在 applicationDidFinishLaunching 里调一次。幂等。
    @discardableResult
    func start() -> Bool {
        guard !registered else { return true }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        // 只匹配内置 PS2 键盘（VoodooPS2 模拟的假 Apple 键盘），外接键盘不碰
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0xFFFF,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(m, matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { _, _, _, value in
            GestureHotkey.shared.onHIDValue(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        // observe 型打开（不 seize）—— 键盘照常给系统用，我们只是旁听
        let openRes = IOHIDManagerOpen(m, 0)
        guard openRes == kIOReturnSuccess else {
            log("IOHIDManagerOpen 失败 \(openRes)（输入监控未授权？）")
            return false
        }
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        manager = m
        registered = true
        log("已接管 F13 原始事件（IOHIDManager 直捕，修饰键免疫）")
        return true
    }

    /// 激活策略变化后不再需要重挂（IOHIDManager 与 WindowServer 无关），
    /// 保留空实现兼容旧调用点（AppPolicy）。
    func reregister(reason: String = "policy") {
        guard registered else { start(); return }
        log("重挂请求(\(reason)) → IOHIDManager 路径无需重挂，忽略")
    }

    func stop() {
        if let m = manager {
            IOHIDManagerClose(m, 0)
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        registered = false
    }

    // MARK: - 原始事件过滤

    /// 只认 F13 按下（page 0x07 键盘页 / usage 0x68 = F13），修饰键一律不参与判断
    private func onHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard UInt32(page) == UInt32(kHIDPage_KeyboardOrKeypad), usage == 0x68,  // 0x68 = F13
              IOHIDValueGetIntegerValue(value) == 1 else { return }
        fire()
    }

    // MARK: - 触发

    private func fire() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) > debounce else {
            log("去抖忽略（距上次 \(String(format: "%.2f", now.timeIntervalSince(lastFire)))s）")
            return
        }
        lastFire = now

        // 输入监控未授权时，手势本身收到了也执行不了：先让系统弹一次授权框，
        // 仍不可用就给明确指引（否则用户只会看到「双击没反应」）。
        if !InputMonitorPermission.granted {
            let ok = InputMonitorPermission.request()
            log("输入监控未授权 → 请求\(ok ? "通过" : "未通过")（state=\(InputMonitorPermission.state)）")
            if !ok {
                if !guidanceShown {
                    guidanceShown = true
                    InputMonitorPermission.presentGuidance()
                } else {
                    ToastCenter.shared.show("触控板手势需要「输入监控」权限")
                }
                return
            }
        }

        log("收到手势 → 请求后端翻转")

        Task { @MainActor in
            // 让后端原子翻转（它持有真实独占状态），而不是拿 UI 侧 1 秒轮询的缓存
            // 去算反值 —— 连点两次时那样会读到旧状态、原地踏步。
            let r = await TrackpadAPI.apply(["touchpad_toggle": true])
            let ok = (r["ok"] as? Bool) == true
            GestureHotkey.shared.log("后端返回 ok=\(ok) touchpad=\(r["touchpad"] ?? "nil") "
                                     + "error=\(r["error"] ?? "nil")")
            if ok, let enabled = r["touchpad"] as? Bool {
                ToastCenter.shared.showSwitch("触控板", enabled)
            } else if !ok {
                // 已授权但仍打不开设备：多半是授权刚变更、进程还没重新拿到权限
                let err = (r["error"] as? String) ?? ""
                if err.contains("输入监控") || err.contains("-536870174") {
                    if !GestureHotkey.shared.restartHintShown {
                        GestureHotkey.shared.restartHintShown = true
                        InputMonitorPermission.presentGuidance(restartHint: true)
                    }
                } else if !err.isEmpty {
                    ToastCenter.shared.show("触控板切换失败：\(err)")
                }
            }
            NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
        }
    }
}

// MARK: - 触控板锁定的调用通道

/// 为什么必须走**本进程**而不是后台 helper（2.7.9 实证）
///
/// 实测（root 也失败）：
///
///     uid=0 managerOpen=-536870174
///       Magic Trackpad 2[I2C]  seize=-536870174 ✗
///
/// `IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)` 需要进程有「输入监控」TCC 授权，
/// **与 uid 无关**。而 helper 是 `SMAppService.agent`，launchd 起的进程，用户没法
/// 把它加进白名单（白名单按路径记，且不会弹窗）；反过来 app 自己的 bundle id
/// `com.skycc.console` 早就在名单里了：
///
///     kTCCServiceListenEvent|com.skycc.console|...
///
/// 所以 HID 这一跳只能在 app 进程里做。`NativeAPI.handlePost` 就是进程内入口，
/// app 本来就链接了 Native/*.swift，直接调即可；kext 走用户态 io_connect 也通
/// （mcutil 独立进程同样能读写 EC）。
enum TrackpadAPI {
    @MainActor
    static func apply(_ params: [String: Any]) async -> [String: Any] {
        // 1) 本进程优先：只有 app 有输入监控权限
        if let r = NativeAPI.handlePost("/api/fan", params) as? [String: Any],
           r["ok"] as? Bool == true {
            return r
        }
        // 2) 兜底：万一本进程拿不到 kext，再问 helper（它会如实返回权限错误）
        return await BackendService.shared.post("/api/fan", params)
    }
}
