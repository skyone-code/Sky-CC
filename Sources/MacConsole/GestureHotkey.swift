import Foundation
import Carbon.HIToolbox
import AppKit

/// 触控板左上角「双击锁定」手势的接管（2.7.8）
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
///     12:10:27.905  page=7 usage=224 value=0
///     12:10:27.911  page=7 usage=227 value=0
///
/// 整组 5 毫秒完成，人手不可能按出这个速度 —— 这是设备合成的事件，不是真按键。
/// 也就是说：**触控板固件 → EC → PS2 键盘控制器 → VoodooPS2Keyboard → 合成 Ctrl+Cmd+F13**。
///
/// ## 为什么在 macOS 下「没反应」
///
/// Windows 上这个组合由厂商驱动（Control Center）消费掉，转成「关触控板 + 点亮锁定灯」。
/// macOS 里没有任何组件消费 Ctrl+Cmd+F13，事件就这么掉在地上 —— 所以双击没反应、
/// 灯也不亮。不是 Voodoo 没映射，恰恰相反：Voodoo 映射得很好，只是没人接。
///
/// ## 本文件做的事
///
/// 用 Carbon `RegisterEventHotKey` 注册 Ctrl+Cmd+F13 全局热键（**不需要任何隐私权限**，
/// 不同于 CGEventTap / IOHIDManager 那种要「输入监控」的路子），收到就切换触控板锁定，
/// 与控制页的「触控板」开关走同一个后端接口（`/api/fan` 的 `touchpad_toggle` → HID 独占）。
///
/// 锁定灯本身点不亮 —— 那是 EC `CTRL_4(0x07A6) bit6` 的活，实测该位可写但系统侧无响应
/// （见 NativeTrackpadLock.swift 头部注释），macOS 下拿不到 LED 控制权。
///
/// ## 已验证（2026-10-22 12:16）
///
/// 用 NSApplication 事件循环 + 7 组候选修饰键同时注册，用户双击后日志：
///
///     REG ctrl+cmd status=0            ← 7 组全部注册成功
///     FIRED id=1                       ← 12:16:35.603，HID 侧同刻 usage=104
///     FIRED id=1                       ← 12:16:47.044，HID 侧同刻 usage=104
///
/// `id=1` 就是 `controlKey | cmdKey`，与固件实际发出的标志位一致。
/// 注意：验证时**必须**用 NSApplication 跑事件循环，纯 CLI 的 `CFRunLoopRun()`
/// 收不到 Carbon 热键事件（`RegisterEventHotKey` 照样返回 0，但事件不投递）。
///
/// ## 2.7.8 首个装机版失效的原因（已修）
///
/// 装机版双击没反应。外部探针证明：热键被测试进程抢到（`FIRED id=1`），
/// 而 app 没收到 —— 说明 app 的注册没生效。原因是 `NSApp.setActivationPolicy(_:)`
/// 会重新向 WindowServer 注册进程，**把已经挂上的 Carbon 热键打掉**。
/// 而 app 的注册顺序恰好是：`didFinishLaunching` 里先注册，随后
/// `DispatchQueue.main.async { AppPolicy.toAccessory() }` 异步改策略 —— 正好把刚注册的
/// 热键作废；之后每次开关窗口还会 `toRegular()` / `toAccessory()` 再打掉一次。
///
/// 修法：`AppPolicy` 每次改完策略都调 `reregister()` 重挂；另外 app 激活时也补挂一次。
/// 这些重挂都走 `stop()` + `start()`，不会累积重复的 handler。
final class GestureHotkey {
    static let shared = GestureHotkey()

    /// 同一手势的去抖窗口。双击本身是两下轻点（间隔约 150-300ms），
    /// 固件合成一组事件；留 0.4s 既能合并偶发的双发，又不会吃掉连续两次独立双击。
    private let debounce: TimeInterval = 0.4
    private var lastFire = Date.distantPast

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var reregisterScheduled = false
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

    // MARK: - 注册

    /// 在 applicationDidFinishLaunching 里调一次。幂等。
    @discardableResult
    func start() -> Bool {
        guard !registered else { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // 必须是 @convention(c) 无捕获闭包
        let hStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            GestureHotkey.shared.handle()
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard hStatus == noErr else {
            log("handler 安装失败 status=\(hStatus)")
            return false
        }

        // Ctrl + Command + F13（kVK_F13 = 0x69 = 105）
        let hkID = EventHotKeyID(signature: OSType(0x4D434753), id: 1)  // 'MCGS'
        let rStatus = RegisterEventHotKey(UInt32(kVK_F13),
                                          UInt32(controlKey | cmdKey),
                                          hkID,
                                          GetApplicationEventTarget(),
                                          0,
                                          &hotKeyRef)
        guard rStatus == noErr else {
            log("注册失败 status=\(rStatus)（可能被其他程序占用）")
            return false
        }

        registered = true
        log("已接管 Ctrl+Cmd+F13（policy=\(NSApp.activationPolicy().rawValue)）")

        // 兜底：app 激活时补挂一次（策略切换后可能被系统打掉）
        if observers.isEmpty {
            let o = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.reregister(reason: "didBecomeActive")
            }
            observers.append(o)
        }
        return true
    }

    /// 激活策略变化后重挂（`setActivationPolicy` 会让 Carbon 热键失效）
    func reregister(reason: String = "policy") {
        stop()
        let ok = start()
        log("重挂(\(reason)) → \(ok ? "成功" : "失败")")

        // 策略切换本身是异步落地的：立刻重挂有可能撞上过渡期、又被系统清掉。
        // 这里再补一次（用标志位合并多次调用，避免反复 stop/start 刷屏）。
        guard !reregisterScheduled else { return }
        reregisterScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.reregisterScheduled = false
            self.stop()
            let ok2 = self.start()
            self.log("延迟补挂 → \(ok2 ? "成功" : "失败")")
        }
    }

    func stop() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        registered = false
    }

    // MARK: - 触发

    /// 手势触发：切换触控板锁定状态
    private func handle() {
        let now = Date()
        guard now.timeIntervalSince(lastFire) > debounce else {
            log("去抖忽略（距上次 \(String(format: "%.2f", now.timeIntervalSince(lastFire)))s）")
            return
        }
        lastFire = now
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
            }
            NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
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
/// `com.macconsole.console` 早就在名单里了：
///
///     kTCCServiceListenEvent|com.macconsole.console|...
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
