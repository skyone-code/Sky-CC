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
    /// 名单里当前选中的 bundle id（− 按钮的作用对象；刷新后如果没了自动清空）
    @State private var selectedExclude: String?

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
                        .foregroundStyle(Theme.txt)
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

            // 2026-11-15（用户要求）：名单改成「带框列表 + 加号/减号」——
            //   · +：菜单（当前最前面的 App / 其他 App…文件选择器），把 app 加入核显名单；
            //   · −：移除列表里选中的 app（未选中时置灰）；
            //   · 行可点选，选中蓝底高亮；替代原来的 per-row「移除」链接和最前面 App 胶囊按钮。
            HStack(spacing: 6) {
                Text("使用核显的 App")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.txt)
                Text("（这些 app 不吃「默认独显」，强制走核显）")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim2)
                Spacer(minLength: 4)
                gpuListButtons
            }

            // 名单框：panel2 底 + 描边，与核心温度块同款容器
            VStack(alignment: .leading, spacing: 0) {
                if gpuExcludes.isEmpty {
                    Text("还没有添加 · 点右上角 + 把 app 加进来")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(gpuExcludes, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim2)
                            Text(id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(id == selectedExclude ? Theme.txt : Theme.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            if id == selectedExclude {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.blue.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedExclude = id }
                    }
                }
            }
            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1))
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
            // 选中的 app 若已被移除，清掉选中态
            if let s = selectedExclude, !gpuExcludes.contains(s) {
                selectedExclude = nil
            }
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
            if on, r["ok"] as? Bool == true { selectedExclude = id }
            await refreshGpu()
        }
    }

    // MARK: - 加号 / 减号（2026-11-15）

    /// 名单标题行右侧的 +/−：小方按钮，样式与核心温度块的胶囊一致
    private var gpuListButtons: some View {
        HStack(spacing: 5) {
            // +：菜单——最常用的是把当前最前面的 App 加进来，也支持从 /Applications 挑
            Menu {
                if let front = gpuInfo["frontApp"] as? String, !front.isEmpty,
                   !gpuExcludes.contains(front) {
                    Button {
                        if front.hasPrefix("com.apple.") {
                            gpuMsg = "系统 App（\(front)）会拒绝注入，加了也不生效，不添加"
                        } else {
                            setGpuExclude(front, on: true)
                        }
                    } label: {
                        Label("当前最前面的 App（\(front)）", systemImage: "rectangle.inset.filled")
                    }
                }
                Button {
                    pickAppToAdd()
                } label: {
                    Label("其他 App…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .frame(width: 22, height: 20)
                    .background(Theme.blue.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.blue.opacity(0.35), lineWidth: 0.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(gpuInfo["dylibPresent"] as? Bool == false)
            .help("添加使用核显的 App")

            // −：移除选中的 app
            Button {
                guard let s = selectedExclude else { return }
                setGpuExclude(s, on: false)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selectedExclude == nil ? Theme.dim2 : Theme.red)
                    .frame(width: 22, height: 20)
                    .background(Theme.panel2,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(selectedExclude == nil)
            .help("移除选中的 App")
        }
    }

    /// 文件选择器挑 app：读选中 .app 的 CFBundleIdentifier 加进名单
    private func pickAppToAdd() {
        let panel = NSOpenPanel()
        panel.title = "选择使用核显的 App"
        panel.message = "选择一个 .app，会把它的 Bundle ID 加入核显名单（对之后启动的 app 生效）"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
        guard let id, !id.isEmpty else {
            gpuMsg = "读不到 \(url.lastPathComponent) 的 Bundle ID，未添加"
            return
        }
        if gpuExcludes.contains(id) {
            gpuMsg = "\(id) 已经在名单里"
            return
        }
        if id.hasPrefix("com.apple.") {
            gpuMsg = "系统 App（\(id)）会拒绝注入，加了也不生效，不添加"
            return
        }
        setGpuExclude(id, on: true)
    }
}
