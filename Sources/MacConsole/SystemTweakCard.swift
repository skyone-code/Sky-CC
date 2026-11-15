//
//  SystemTweakCard.swift
//  Sky CC —— 「系统调整」卡（原厂 FastSwitch 页）
//
//  3.0.4.5（2026-11-14 用户要求）：整卡从「控制」页迁到「设置」页。
//  同日追加（用户要求）：
//   · 删掉「OSD 显示 / 安静模式 / 保持唤醒」三个开关；
//   · 外观与通用卡里的「显卡路由」段（GpuRouteSection）迁入本卡尾部；
//   · Win 键锁定的副作用说明改为用户指定文案。
//
//  自带 @State 与同步逻辑：进页面读一次 /api/fan/refresh（不轮询），
//  之后跟 store.updatedAt 对齐 EC 真值；写记忆（UIControlPrefs）+ 写 EC，
//  失败回滚记忆。
//

import SwiftUI

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
                // 副标题（寄存器说明）默认不显示；代码保留
                if !hideCardSubs {
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

    // 系统调整（原厂 FastSwitch 页）：只剩 Win 键锁定（用户要求删 OSD / 安静模式 / 保持唤醒）
    @State private var winLock: Bool

    private var kextOK: Bool { backend.kextLoaded }

    // 2026-11-14（首帧记忆）：构造时同步读软件记忆，首帧即上次选择；
    // EC 回读对不上时再校正（用户允许）。
    init() {
        _winLock = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.winLock) ?? false)
    }

    var body: some View {
        Card(title: "系统调整 · 原厂 FastSwitch 页") {
            if !kextOK { KextRequiredHint(text: "Win 键锁定要 TongfangFan.kext") }
            VStack(alignment: .leading, spacing: 11) {
                GroupTitle(text: "显示屏", sub: "不经 EC")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示屏电源").font(.system(size: 13, weight: .medium))
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

                GroupTitle(text: "其他设置", sub: "0x767 触发位 / 0x7A4 bit3")
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

                // 2026-11-14（用户要求）：显卡路由段从「外观与通用」迁入本卡尾部。
                Divider().overlay(Theme.line)
                GpuRouteSection()
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
            }
        }
        .onChange(of: store.updatedAt) { _, _ in
            syncFromBackend()
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
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
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
