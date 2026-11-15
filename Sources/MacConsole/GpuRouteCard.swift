import SwiftUI

/// 显卡路由段：「默认使用独显 / 跟随系统」+ per-app 例外名单。
///
/// 2026-11-05 引入，当时是「控制」页右列最下方的一张独立卡；2026-11-07（用户要求）
/// 搬进「设置」页的「外观与通用」卡里 —— 它改的是注入进各 app 的 gpu-router.dylib
/// 的行为，属于「设一次就不再动」的系统设定，不是控制页那些日常调、写 EC 的档位。
///
/// 这里只提供**段落**（不带 Card 外壳），2026-11-14 起由「系统调整」卡（SystemTweakSection）用分隔线接在尾部。
/// 真正干活的是注入进目标进程的 gpu-router.dylib，这段只控制「注不注入」+
/// per-app 例外名单。自带 @State：进页面读一次当前状态（`/api/gpu`），不轮询。
struct GpuRouteSection: View {
    @EnvironmentObject var backend: BackendService
    @Environment(\.hideCardSubs) private var hideCardSubs

    @State private var gpuOn: Bool
    @State private var gpuInfo: [String: Any] = [:]
    @State private var gpuBusy = false
    @State private var gpuMsg: String?

    // 2026-11-14（首帧记忆）：构造时同步读镜像，首帧即上次选择；
    // /api/gpu 异步回读对不上时再校正。
    init() {
        _gpuOn = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.gpuRoute) ?? false)
    }

    private var gpuExcludes: [String] { (gpuInfo["exclude"] as? [String]) ?? [] }

    private var gpuStatusText: String {
        if gpuInfo["dylibPresent"] as? Bool == false {
            return "缺少 gpu-router.dylib —— 重装或重新构建 app 后再试"
        }
        if gpuBusy { return "正在应用…" }
        if gpuOn { return "已开启：之后启动的 app 默认拿到独显" }
        return "已关闭：跟随系统（内屏挂在核显上，默认核显）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupTitle(text: "显卡 · 默认使用哪块 GPU")

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认使用独显").font(.system(size: 12.5, weight: .medium))
                    if !hideCardSubs {
                        Text("等价于 Windows「首选图形处理器 = 高性能 NVIDIA」。开启后新启动的 app 拿到的默认 Metal 设备是 RTX 2070S；画面仍由核显呈现（内屏物理接在核显上，这是 Optimus 的本义）。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.dim2)
                            .fixedSize(horizontal: false, vertical: true)
                            .cardNote()
                    }
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { gpuOn }, set: { setGpuMode($0) }))
                    .toggleStyle(.switch)
                    .disabled(gpuBusy || gpuInfo["dylibPresent"] as? Bool == false)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(gpuOn ? Color.green : Theme.dim2)
                    .frame(width: 6, height: 6)
                Text(gpuStatusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if gpuBusy { ProgressView().controlSize(.small) }
            }

            if let m = gpuMsg, !m.isEmpty {
                Text(m)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hideCardSubs {
                Text("只对之后启动的 app 生效；已在运行的 app 需退出重开。带 library validation 的 app（Safari、部分商业游戏）会拒绝注入，属于 macOS 限制。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.dim2)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardNote()
            }

            if !gpuExcludes.isEmpty {
                Text("这些 app 仍用核显").font(.system(size: 11.5, weight: .medium))
                ForEach(gpuExcludes, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("移除") { setGpuExclude(id, on: false) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }

            if let front = gpuInfo["frontApp"] as? String,
               !front.isEmpty, !gpuExcludes.contains(front), !front.hasPrefix("com.apple.") {
                // 2026-11-14（用户要求）：改成胶囊按钮——原来 .link 太不显眼
                Button {
                    setGpuExclude(front, on: true)
                } label: {
                    Text("把当前最前面的 App（\(front)）改为用核显")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.blue.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("把这个 app 加入核显例外名单（等价 Windows「此 app 用省电 GPU」）")
            }
        }
        // 进页面读一次当前状态（这条设置只在用户点击时变，不需要轮询）
        .task { await refreshGpu() }
    }

    private func refreshGpu() async {
        if let d = try? await backend.getJSON("/api/gpu") as? [String: Any] {
            gpuInfo = d
            gpuOn = (d["injected"] as? Bool) ?? false
            // 真值同步写回镜像：下次进页首帧就是它
            UIControlPrefs.set(UIControlPrefs.K.gpuRoute, gpuOn)
        }
    }

    private func setGpuMode(_ on: Bool) {
        gpuBusy = true
        gpuMsg = nil
        Task {
            let r = await backend.post("/api/gpu/mode", ["mode": on ? "dgpu" : "off"])
            gpuBusy = false
            gpuMsg = (r["ok"] as? Bool == true)
                ? (r["note"] as? String ?? "已应用")
                : (r["error"] as? String ?? "应用失败")
            await refreshGpu()
        }
    }

    private func setGpuExclude(_ id: String, on: Bool) {
        Task {
            let r = await backend.post("/api/gpu/exclude", ["bundle": id, "on": on])
            gpuMsg = (r["ok"] as? Bool == true) ? nil : (r["error"] as? String)
            await refreshGpu()
        }
    }
}
