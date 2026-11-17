//
//  SystemTweakCard.swift
//  Sky CC —— 「系统调整」卡（原厂 FastSwitch 页）
//
//  3.0.4.5（2026-11-14 用户要求）：整卡从「控制」页迁到「设置」页。
//  同日追加（用户要求）：
//   · 删掉「OSD 显示 / 安静模式 / 保持唤醒」三个开关；
//   · Win 键锁定的副作用说明改为用户指定文案。
//
//  3.0.7（2026-11-17 用户要求）：显卡路由段（GpuRouteSection）从本卡尾部拆出去，
//  独立成卡放「设备控制」页、位置在「散热模式」卡上方 —— 它调的是实时生效的
//  GPU 注入行为，跟本卡这些「设一次就不再动」的 BIOS 持久项不是一类。
//
//  自带 @State 与同步逻辑：进页面读一次 /api/fan/refresh（不轮询），
//  之后跟 store.updatedAt 对齐 EC 真值；写记忆（UIControlPrefs）+ 写 EC，
//  失败回滚记忆。
//

import SwiftUI
import AppKit

// MARK: - 通用开关行（标题 + 副标题 + 开关，点击即生效）
// （原 ControlView.swift 内的 private struct，随「系统调整」卡一起迁来并改为 internal）

struct MiscToggleRow: View {
    let title: String
    let sub: String
    @Binding var on: Bool
    let action: () -> Void
    /// 2.8.9：副标题默认隐藏（实验性页放行）
    @Environment(\.hideCardSubs) private var hideCardSubs

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.txt)
                // 副标题（寄存器说明）默认不显示；代码保留
                if !hideCardSubs && !sub.isEmpty {
                    Text(sub).font(.system(size: 11)).foregroundStyle(Theme.dim2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { on },
                set: { v in on = v; action() }))
            .toggleStyle(.switch)
            .tint(Theme.blue)
            .labelsHidden()
        }
    }
}

// MARK: - 系统调整卡

struct SystemTweakSection: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    @Environment(\.hideCardSubs) private var hideCardSubs

    // 系统调整（原厂 FastSwitch 页）：Win 键锁定 + Fn 锁（用户要求删 OSD / 安静模式 / 保持唤醒）
    @State private var winLock: Bool

    // 触控板开关（3.0.7）：固件 Feature Report 0x07 为主、HID 独占兜底；
    // 与双击触控板左上角手势同一通道。
    // 【2026-11-17 修正】真值只能在本进程读（TrackpadLock.status()）：
    // 写在本进程（app 有「输入监控」），而快照 misc 是 helper 生成的 —— helper
    // 打不开 HID，旧代码在它那边永远读到「未禁用」，UI 每秒被假值覆盖，
    // 表现就是「关了之后开关自己弹回开」。本卡不再看 misc 的这一项。
    @State private var trackpadOn: Bool = true
    /// 上次真实探测触控板的时间（每次探测要开一次 HID 设备，3 秒节流）
    @State private var lastPadProbe = Date.distantPast
    /// 写入代数：拨动开关时 +1，用来丢弃「写入前发起、写入后才回来」的旧读数
    @State private var padEpoch = 0

    // Fn 锁（2026-11-17）：就是键盘上 Esc 那颗 Fn Lk、Fn+Esc 切的那个功能。
    // 【实测结论】两位语义不同，不是「一起写」那么简单：
    //   · 0x07A4 bit3 = 功能总闸（AP 侧使能），必须常开 —— 它为 0 时 EC 根本不处理
    //     Fn+Esc（连按 6 次寄存器一秒都没动）；它为 1 时按一次 Fn+Esc，0x074E 立刻翻转；
    //   · 0x074E bit4 = 当前状态，Fn+Esc 翻的就是这一位。
    // 所以后端 `setFnLock` 现在「总闸常开、只切状态位」，本卡只管状态。
    // 语义：1 = F 区直接出媒体功能，0 = 需加 Fn。真值取两者之与。
    //
    // 【2026-11-17 二次修正】真值**不能**读 store.fan["misc"]["fn_lock"]：
    // 那份 misc 由 /api/fan 生成，非 fresh 路径吃的是 24 小时缓存（NativeAPI.fanState
    // 明确写了「非 fresh 路径不主动读 EC」），而 Fn+Esc 是硬件事件、不会让缓存失效。
    // 结果就是用户按了快捷键、功能真的切了，开关却纹丝不动 —— 也就是「两边状态没绑定」。
    // 现在改读专用端点 /api/fnlock（每次现读 0x074E / 0x07A4，~130 ms），
    // 页面可见时 1.2 秒轮询一次，硬件怎么切、开关就怎么跟。
    @State private var fnLock: Bool = false
    /// 上次自己写 Fn 锁的时间（写入后 1.6 秒内不让轮询覆盖，避开 EC 过渡态）
    @State private var lastFnWrite = Date.distantPast

    // 接电自动开机（2026-11-17）：0x0726 bit3，内核 AC_AUTO_BOOT_ENABLE。
    // 1 = 断电恢复 / 插上适配器即自动上电，0 = 必须按电源键。
    // 同一字节另 7 位含义未知，后端走读-改-写单 bit；真值取 misc.ac_auto_boot 回读。
    @State private var acAutoBoot: Bool = false

    // 挂载 EFI（2026-11-16 用户要求，1401 方案）
    @State private var efiMounting = false

    private var kextOK: Bool { backend.kextLoaded }

    // 2026-11-14（首帧记忆）：构造时同步读软件记忆，首帧即上次选择；
    // EC 回读对不上时再校正（用户允许）。
    init() {
        _winLock = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.winLock) ?? false)
        _fnLock   = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.fnLock) ?? false)
        _acAutoBoot = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.acAutoBoot) ?? false)
    }

    var body: some View {
        Card(title: "系统调整 · 原厂 FastSwitch 页") {
            if !kextOK { KextRequiredHint(text: "Win 键锁定要 TongfangFan.kext") }
            VStack(alignment: .leading, spacing: 11) {
                // 2026-11-16（用户要求）：挂载 EFI 放本卡第一位（显示屏上面）——
                // 1401 方案定位本机 OpenCore 所在的 EFI 分区并挂载。
                GroupTitle(text: "EFI 分区", sub: "1401 方案定位 · 机型校验")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("挂载 EFI").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.txt)
                        if !hideCardSubs {
                            Text("按 boot-path → 启动盘兜底定位 OpenCore 的 EFI 分区（校验机型，不会挂错救援盘），挂载后打开访达窗口。需要管理员授权。")
                                .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    SecondaryButton(title: efiMounting ? "挂载中…" : "挂载",
                                    icon: "externaldrive", tint: Theme.cyan) {
                        mountEFI()
                    }
                    .disabled(efiMounting)
                }

                Divider().overlay(Theme.line)

                GroupTitle(text: "显示屏", sub: "不经 EC")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示屏电源").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.txt)
                        if !hideCardSubs {
                            Text("单击关闭内屏，动鼠标或按任意键恢复")
                                .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    SecondaryButton(title: "关屏", icon: "moon.zzz", tint: Theme.purple) {
                        Task { await displaySleep() }
                    }
                }

                Divider().overlay(Theme.line)

                GroupTitle(text: "其他设置", sub: "0x767 触发位 / 0x74E bit4")
                MiscToggleRow(title: "触控板",
                              sub: "关闭后系统收不到触摸输入；双击触控板左上角也可切换",
                              on: $trackpadOn) {
                    Task { await applyTrackpad(trackpadOn) }
                }

                MiscToggleRow(title: "Fn 锁",
                              sub: "",
                              on: $fnLock) {
                    Task { await applyFnLock(fnLock) }
                }
                .kextGated(kextOK)

                // 2026-11-17（用户要求）：接电自动开机，放 Win 键锁定上方
                MiscToggleRow(title: "接电自动开机",
                              sub: "",
                              on: $acAutoBoot) {
                    Task { await applyAcAutoBoot(acAutoBoot) }
                }
                .kextGated(kextOK)

                MiscToggleRow(title: "Win 键锁定",
                              sub: "0x767 bit0 触发 → 0x768 bit0 回读，状态 ~600ms 才跟上",
                              on: $winLock) {
                    Task { await applySystem("win_lock", winLock, "Win 键锁定") }
                }
                .kextGated(kextOK)

                // 2026-11-14（用户指定文案）：拨动本开关会触发睡眠，属于 EC 副作用，
                // 黑屏的时候点点键盘就能打断睡眠。
                // 成因：EC 响应 0x767 bit0 时会额外抛一次 PWRBTN 固定事件，macOS 直接当
                // 「电源键」消费 → 关屏 / 睡眠。锁功能本身不受影响（0x768 bit0 回读正常）。
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 1)
                    Text("拨动本开关会触发睡眠，属于 EC 副作用；黑屏的时候点点键盘就能打断睡眠。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Theme.amber.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.amber.opacity(0.32), lineWidth: 1))

                // 2026-11-17（用户要求）：显卡路由段已从本卡拆出，
                // 独立成卡放「设备控制」页（见 ControlView.swift 的 gpuCard）。
            }
        }
        .onAppear {
            // 迁来本页后自己读一次当前设置（只这一次，不轮询）——
            // /api/fan/refresh 读模式组 + 开关组 + 充电阈值，合进 store.fan 后再对齐 UI。
            Task {
                if let fresh = try? await backend.getJSON("/api/fan/refresh") as? [String: Any],
                   !fresh.isEmpty {
                    var f = store.fan
                    for k in ["live", "thermal_level", "power_level", "modeindex",
                              "benchmark", "misc", "charge", "actual", "actual_level"] {
                        if let v = fresh[k] { f[k] = v }
                    }
                    store.fan = f
                }
                syncFromBackend()
                // 触控板状态：进页面强制读一次真实固件开关（不受 3 秒节流限制）
                refreshTrackpad(force: true)
                // Fn 锁：进页面立刻对一次真值，别等 1.2 秒后的第一次轮询
                probeFnLock()
            }
        }
        // Fn 锁跟随 Fn+Esc（2026-11-17 用户要求「两边状态必须一致」）：
        // 快捷键是纯硬件事件、没有通知源，只能轮询专用端点。
        // 视图消失时 .task 自动取消，不会在别的页面白读 EC。
        //
        // 2026-11-17（CPU 自查）：两处收紧 ——
        //   ① 间隔 1.2s → 1.5s（一次探测 = 一次 XPC + 两次 EC 读 ≈130ms，
        //      本机是设置页里最贵的一条周期任务）；
        //   ② **只在 app 前台时轮询**：用户切到别的窗口后，EC 里那一位变了也
        //      没人看，白读一整天。切回来时由 didBecomeActive 立刻补一读，
        //      所以看到的永远是最新值，不会「回来还是旧的」。
        .task {
            while !Task.isCancelled {
                if NSApp.isActive { probeFnLock() }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 回到前台：立刻对一次真值（后台期间 Fn+Esc 可能被按过好几次）
            probeFnLock()
            lastPadProbe = .distantPast
            refreshTrackpad()
        }
        .onChange(of: store.updatedAt) { _, _ in
            syncFromBackend()
        }
        // 双击触控板左上角的手势也在本进程改状态（GestureHotkey 会发这个通知）：
        // 收到就清掉节流，立刻重读一次，别等 3 秒后的下一次心跳。
        .onReceive(NotificationCenter.default.publisher(for: .skyCCStateChanged)) { _ in
            lastPadProbe = .distantPast
            refreshTrackpad()
        }
    }

    // MARK: 同步（只保留本卡用到的键）

    private func syncFromBackend() {
        guard !store.fan.isEmpty else { return }
        // 本次启动的第一次有效快照：EC → 记忆（只此一次）
        UIControlPrefs.seedIfNeeded(store.fan)
        // 3.0.2.1（用户要求）：启动时**只读不应用** —— 把 EC 真值抄进记忆。
        UIControlPrefs.adoptHardwareIfNeeded(store.fan)

        // 本卡的开关以软件记忆为准
        if let v = UIControlPrefs.bool(UIControlPrefs.K.winLock) { winLock = v }

        // 触控板：真值只能**本进程**读 —— HID open 要「输入监控」，helper 拿不到
        // （它读到的永远是「未禁用」，旧版就是被这个假值每秒打回「开」）。
        // 2026-11-17 起改读 TrackpadLock.status()，并做 3 秒节流（每次读要开一次设备）。
        refreshTrackpad()
        // Fn 锁：**故意不读** store.fan["misc"]["fn_lock"]。
        // 那份 misc 来自 /api/fan，非 fresh 路径吃 24 小时缓存；Fn+Esc 不会让它失效，
        // 于是开关永远停在上一次的值（旧版“按了快捷键开关不动”的根因）。
        // 真值统一由 probeFnLock() 走 /api/fnlock 现读。
        // 接电自动开机：0x0726 bit3，以 EC 回读为准（固件可能按策略改写）
        if let misc = store.fan["misc"] as? [String: Any],
           let acb = misc["ac_auto_boot"] as? Bool {
            acAutoBoot = acb
        }
    }

    // MARK: 挂载 EFI（2026-11-16 用户要求，1401 方案）

    /// 写脚本（函数体照搬 AirportItlwm install.command 的「1401 方案」定位段）→
    /// 管理员权限执行 → 成功 toast + 打开访达窗口；失败 toast 原因。
    private func mountEFI() {
        guard !efiMounting else { return }
        efiMounting = true
        let fm = FileManager.default
        let logURL = fm.temporaryDirectory
            .appendingPathComponent("SkyCC-efi-\(UUID().uuidString).log")
        let script = fm.temporaryDirectory
            .appendingPathComponent("SkyCC-mount-efi-\(UUID().uuidString).sh")
        do {
            try Self.mountEFIsh.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            efiMounting = false
            showToast("无法写入挂载脚本：\(error.localizedDescription)")
            return
        }
        let shPath = script.path
        DispatchQueue.global(qos: .userInitiated).async {
            // 提权执行是阻塞式（密码授权弹窗期间一直等到用户点完），放后台队列
            let result = DriverInstaller.runWithAdminPrivileges(executable: shPath,
                                                                logURL: logURL,
                                                                deadline: 180) { _, _ in }
            DispatchQueue.main.async {
                self.efiMounting = false
                try? fm.removeItem(at: script)
                try? fm.removeItem(at: logURL)
                if result.ok {
                    let mp = Self.marker(result.output, "MOUNT_POINT=") ?? ""
                    let oc = Self.marker(result.output, "OC_DIR=") ?? ""
                    if !mp.isEmpty {
                        showToast("EFI 已挂载：\(mp)\(oc.isEmpty ? "" : "（OpenCore：/\(oc)）")")
                        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
                    } else {
                        showToast("EFI 已挂载")
                    }
                } else {
                    // 取脚本输出的 STOP 行（已带原因）；没有就给通用文案
                    let reason = Self.stopReason(result.output)
                        ?? (result.output.isEmpty ? "授权未完成或脚本执行失败" : result.output)
                    showToast("挂载失败：\(reason)")
                }
            }
        }
    }

    /// 从脚本输出里取 "KEY=..." 标记值
    private static func marker(_ out: String, _ key: String) -> String? {
        out.split(separator: "\n")
            .first { $0.hasPrefix(key) }
            .map { String($0.dropFirst(key.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// 取 "STOP: xxx" 行去掉前缀
    private static func stopReason(_ out: String) -> String? {
        out.split(separator: "\n")
            .first { $0.hasPrefix("STOP:") }
            .map { $0.dropFirst("STOP:".count).trimmingCharacters(in: .whitespaces) }
    }

    private func showToast(_ s: String) {
        ToastCenter.shared.show(s)
    }

    private func applySystem(_ key: String, _ value: Bool, _ name: String) async {
        // 先写软件记忆（界面立即以记忆为准），再写 EC
        if let prefKey = UIControlPrefs.prefKey(forFanKey: key) {
            UIControlPrefs.set(prefKey, value)
        }
        let r = await backend.post("/api/fan", [key: value])
        if r["ok"] as? Bool == true {
            ToastCenter.shared.showSwitch(name, value)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            // 硬件没认（触发位 toggle 语义下最容易翻反）→ 记忆回滚到相反值
            if let prefKey = UIControlPrefs.prefKey(forFanKey: key) {
                UIControlPrefs.set(prefKey, !value)
            }
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    /// Fn 锁（0x074E bit4）：键盘上 Esc 那颗 Fn Lk，与 Fn+Esc 同一个位。
    /// 2026-11-17 实测：写 0/1 实时改变 F 区映射，EC 不会回改。
    @MainActor
    private func applyFnLock(_ on: Bool) async {
        UIControlPrefs.set(UIControlPrefs.K.fnLock, on)
        let r = await backend.post("/api/fan", ["fn_lock": on])
        if r["ok"] as? Bool == true {
            lastFnWrite = Date()
            if let v = r["fn_lock"] as? Bool { fnLock = v }
            ToastCenter.shared.showSwitch("Fn 锁", fnLock)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            fnLock = !on
            UIControlPrefs.set(UIControlPrefs.K.fnLock, !on)
            // 读回真值（不再用 syncFromBackend —— 它已经不读 misc 的 fn_lock 了）
            probeFnLock()
        }
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    /// 接电自动开机（0x0726 bit3）。
    /// 注意：能验证的只有「这一位写进去了」，真实行为要断电换电才能看出来 ——
    /// 所以这里不承诺「已生效」，只以 EC 回读为准。
    private func applyAcAutoBoot(_ on: Bool) async {
        UIControlPrefs.set(UIControlPrefs.K.acAutoBoot, on)
        let r = await backend.post("/api/fan", ["ac_auto_boot": on])
        if r["ok"] as? Bool == true {
            if let v = r["ac_auto_boot"] as? Bool { acAutoBoot = v }
            ToastCenter.shared.showSwitch("接电自动开机", on)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            acAutoBoot = !on
            UIControlPrefs.set(UIControlPrefs.K.acAutoBoot, !on)
            syncFromBackend()
        }
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    // MARK: Fn 锁真实状态（现读 EC，2026-11-17）

    /// 读一次 Fn 锁真值，把开关拨到硬件状态上。
    ///
    /// 走 `GET /api/fnlock`（helper 每次现读 `0x074E` / `0x07A4` 两个字节，约 130 ms），
    /// 不用 `/api/fan` 的 misc 缓存 —— 原因见 `fnLock` 属性上的注释。
    /// 由 body 的 `.task` 每 1.2 秒调一次，页面不可见时自动停。
    private func probeFnLock() {
        // 刚拨过开关：给 EC 1.6 秒过渡时间，别让轮询把「过渡态」当成真值顶回去
        guard Date().timeIntervalSince(lastFnWrite) > 1.6 else { return }
        Task {
            guard let r = try? await backend.getJSON("/api/fnlock") as? [String: Any],
                  r["available"] as? Bool != false,
                  let fn = r["fn_lock"] as? Bool else { return }
            await MainActor.run {
                if fn != fnLock {
                    fnLock = fn
                    // 记忆跟着硬件走：下次启动首帧就显示上次真实留下的状态
                    UIControlPrefs.set(UIControlPrefs.K.fnLock, fn)
                }
            }
        }
    }

    // MARK: 触控板真实状态（本进程读，2026-11-17）

    /// 读一次触控板固件开关，把开关拨到真值上。
    ///
    /// · 只能在 app 进程调：HID open 要「输入监控」，helper 拿不到，它读到的恒是「未禁用」；
    /// · 每次读要开一次 HID 设备（几十毫秒），所以默认 3 秒节流，页面出现 / 拨动开关后强制读；
    /// · IOKit 调用丢到后台队列，别在主流上卡一下。
    private func refreshTrackpad(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPadProbe) > 3 else { return }
        lastPadProbe = now
        let epoch = padEpoch
        DispatchQueue.global(qos: .utility).async {
            let s = TrackpadLock.status()
            DispatchQueue.main.async {
                // 这次读如果是「用户拨开关之前」发起的，读数已经过期，直接丢掉
                guard epoch == padEpoch else { return }
                guard let locked = s["locked"] as? Bool else { return }
                let enabled = !locked
                if enabled != trackpadOn { trackpadOn = enabled }
            }
        }
    }

    /// 触控板开关：写触控板固件开关（Feature Report 0x07），失败回落 HID 独占，
    /// 与双击触控板左上角手势同一条通道，需要「输入监控」授权。
    @MainActor
    private func applyTrackpad(_ enabled: Bool) async {
        if !InputMonitorPermission.granted {
            let ok = InputMonitorPermission.request()
            if !ok {
                InputMonitorPermission.presentGuidance()
                trackpadOn = !enabled        // 开关拨回去，别让界面说谎
                return
            }
        }

        let r = await TrackpadAPI.apply(["touchpad": enabled])
        if r["ok"] as? Bool == true {
            // 以写入结果为准（`locked` 是这个进程写完之后的状态），
            // 顺手把节流时间戳刷新掉，别让 3 秒内的旧探测把开关又拨回去
            padEpoch += 1
            lastPadProbe = Date()
            if let locked = r["locked"] as? Bool {
                trackpadOn = !locked
            } else if let v = r["touchpad"] as? Bool {
                trackpadOn = v
            }
            ToastCenter.shared.showSwitch("触控板", enabled)
        } else {
            showToast("失败：\(BackendService.string(r, "error") ?? "未知")")
            // 硬件没认 → 开关先弹回原样，再按真实状态校正一次（别拿记忆/default 猜）
            padEpoch += 1
            trackpadOn = !enabled
            refreshTrackpad(force: true)
        }
        NotificationCenter.default.post(name: .skyCCStateChanged, object: nil)
    }

    private func displaySleep() async {
        let r = await backend.post("/api/control", ["action": "display_sleep"])
        if r["ok"] as? Bool == true {
            showToast("已关屏（动鼠标或按任意键恢复）")
        } else {
            showToast("关屏失败：\(BackendService.string(r, "error") ?? "未知")")
        }
    }
}

// MARK: - 挂载 EFI 脚本（1401 方案）
//
// 函数体照搬 AirportItlwm-AX200-2.4.2/install.command 的「1401 方案」定位段
// （原始出处：/Applications/1401.app 的 nullmoth-setup.sh）：
//   booted_part（NVRAM boot-path 反查 OpenCore 本次引导所用分区）→
//   失败兜底 boot_esp（当前 macOS 所在物理盘的 EFI 分区）→
//   NTFS 拦截 → 挂载（已挂载就复用，**不卸载**）→
//   ocrel_in 按 boot-path 目录 → EFI/OC → EFI/BOOT 找 config.plist 并校验机型。
// 校验失败只报原因不乱挂；挂上后由 app 打开访达窗口。
// 输出约定：成功末两行 MOUNT_POINT=<挂载点> / OC_DIR=<OC 目录>；失败 STOP: <原因>。
private extension SystemTweakSection {
    static let mountEFIsh = #"""
    #!/bin/bash
    # 挂载 OpenCore 所在的 EFI 分区（1401 方案，照搬 AirportItlwm install.command）
    set -u
    PB=/usr/libexec/PlistBuddy
    OCGUID="4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"

    stop() { echo "STOP: $*" >&2; exit 2; }

    mnt() { diskutil info "$1" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}'; }

    is_ntfs() {
      diskutil info "$1" 2>/dev/null | grep -qiE '(Type \(Bundle\)|File System Personality):.*ntfs'; }

    boot_ocrel() {   # OpenCore 本次启动用的目录（读 NVRAM boot-path；不在 EFI/ 下或缺省时返回空）
      local bp p
      bp=$(nvram "$OCGUID:boot-path" 2>/dev/null | cut -f2-)
      case "$bp" in *\)*) ;; *) return 0;; esac
      p=${bp##*\)}; p=${p%%\%*}; p=$(printf '%s' "$p" | tr '\\' '/')
      while [ "${p#/}" != "$p" ]; do p=${p#/}; done
      case "$p" in */*) p=${p%/*};; *) return 0;; esac
      case "/$p/" in /EFI/*/) ;; *) return 0;; esac
      case "/$p/" in */../*|*/./*|*//*) return 0;; esac
      printf '%s\n' "$p"; }

    booted_part() {  # OpenCore 启动本机所用分区（boot-path 里的分区 UUID 反查设备号）
      local bp u d
      bp=$(nvram "$OCGUID:boot-path" 2>/dev/null | cut -f2-)
      u=$(printf '%s' "$bp" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
      [ -n "$u" ] || return 1
      for d in $(diskutil list | grep -oE 'disk[0-9]+s[0-9]+$' | sort -u); do
        diskutil info "$d" 2>/dev/null | grep -qi "Partition UUID: *$u" && { echo "$d"; return 0; }; done
      return 1; }

    boot_esp() {     # 当前 macOS 所在物理盘的 EFI 分区
      local c p w
      c=$(diskutil info / | awk -F': *' '/Part of Whole/{print $2}')
      p=$(diskutil info "$c" 2>/dev/null | awk -F': *' '/APFS Physical Store/{print $2}'); [ -n "$p" ] || p=$c
      w=$(diskutil info "$p" | awk -F': *' '/Part of Whole/{print $2}')
      diskutil list "$w" | awk '/ EFI /{print $NF}' | grep -E '^disk[0-9]+s[0-9]+$' | head -1; }

    ocrel_in() {     # $1 = 挂载点；找 OpenCore 目录并校验 config 是本机的（机型匹配）
      local d m bo c cm k
      m=$(sysctl -n hw.model 2>/dev/null); bo=$(boot_ocrel)
      for d in ${bo:+"$bo"} EFI/OC EFI/BOOT; do
        [ -f "$1/$d/config.plist" ] || continue
        [ "$d" = EFI/BOOT ] && [ ! -d "$1/$d/Kexts" ] && continue
        c="$1/$d/config.plist"; cm=""
        for k in PlatformInfo.Generic.SystemProductName PlatformInfo.SMBIOS.SystemProductName \
                 PlatformInfo.DataHub.SystemProductName; do
          cm=$("$PB" -c "Print :$k" "$c" 2>/dev/null); [ -n "$cm" ] && break; done
        [ -n "$m" ] && [ -n "$cm" ] && [ "$cm" != "$m" ] && continue
        echo "$d"; return 0; done
      return 1; }

    echo "== 定位 OpenCore 的 EFI 分区（1401 方案）=="
    D=""
    if D=$(booted_part); then
        echo "OpenCore 本次引导所用分区：$D"
    else
        D=$(boot_esp) || stop "无法确定当前启动盘的 EFI 分区"
        echo "当前启动盘的 EFI 分区：$D"
    fi
    is_ntfs "$D" && stop "$D 是 Windows(NTFS) 分区，OpenCore 不会从它启动 —— 请确认 OpenCore 所在的盘"

    MP=$(mnt "$D")
    if [ -z "$MP" ]; then
        diskutil mount "$D" >/dev/null 2>&1 || stop "挂载 $D 失败"
        MP=$(mnt "$D")
    fi
    [ -n "$MP" ] || stop "挂载后拿不到挂载点"
    if mount | grep -F " on $MP (" | grep -q read-only; then
        stop "macOS 把 $MP 挂载成了只读，改不了任何文件。常见原因：Windows 快速启动把 ESP 留成脏状态 —— 磁盘工具对该分区跑一次急救，或关掉 Windows 快速启动后完整关机一次再试"
    fi

    OCREL=$(ocrel_in "$MP" || true)
    [ -n "$OCREL" ] || stop "$D 上没有找到本机的 OpenCore（已按 boot-path 目录 → EFI/OC → EFI/BOOT 依次找 config.plist，并校验机型匹配）。它不是 OpenCore 的 ESP 或是别的机器的救援盘。分区仍挂在 $MP 供人工检查"

    echo "MOUNT_POINT=$MP"
    echo "OC_DIR=$OCREL"
    echo "已挂载：$MP（OpenCore 目录 /$OCREL）"
    exit 0
    """#
}
