import SwiftUI

/// 显卡路由段：「启用显卡路由」总开关 + 独显白名单。
///
/// 2026-11-05 引入，当时是「控制」页右列最下方的一张独立卡；2026-11-07（用户要求）
/// 搬进「设置」页的「外观与通用」卡里；2026-11-14 并入「设置 → 系统调整」卡尾部。
/// **2026-11-17（用户要求）：从设置页拆回「设备控制」页，独立成卡放在「散热模式」上方**
/// —— 它调的是实时生效的 GPU 注入行为，与设置页那批「设一次就不动」的持久项不同类。
/// **2026-11-24（用户拍板）白名单化**：开关只管注入总闸；只有名单里的 app 默认拿独显，
/// 其余跟随系统。原「使用核显的 App」例外名单废弃（旧 exclude 字段不再读取）。
///
/// 这里只提供**段落**（不带 Card 外壳），由 ControlView 用 `Card(title:)` 包起来，
/// 卡片标题即「显卡 · 独显白名单」。
/// 真正干活的是注入进目标进程的 gpu-router.dylib，这段只控制「注不注入」+
/// 独显白名单。自带 @State：进页面读一次当前状态（`/api/gpu`），不轮询。
struct GpuRouteSection: View {
    @EnvironmentObject var backend: BackendService
    @Environment(\.hideCardSubs) private var hideCardSubs

    @State private var gpuOn: Bool
    @State private var gpuInfo: [String: Any] = [:]
    @State private var gpuBusy = false
    @State private var gpuMsg: String?
    /// 白名单里当前选中的 bundle id（− 按钮的作用对象；刷新后如果没了自动清空）
    @State private var selectedInclude: String?

    // 2026-11-14（首帧记忆）：构造时同步读镜像，首帧即上次选择；
    // /api/gpu 异步回读对不上时再校正。
    init() {
        _gpuOn = State(initialValue: UIControlPrefs.bool(UIControlPrefs.K.gpuRoute) ?? false)
    }

    private var gpuIncludes: [String] { (gpuInfo["include"] as? [String]) ?? [] }

    private var gpuStatusText: String {
        if gpuInfo["dylibPresent"] as? Bool == false {
            return "缺少 gpu-router.dylib —— 重装或重新构建 app 后再试"
        }
        if gpuBusy { return "正在应用…" }
        if gpuOn {
            return gpuIncludes.isEmpty
                ? "已开启：白名单为空，暂时没有 app 被接管"
                : "已开启：白名单里的 \(gpuIncludes.count) 个 app 默认拿独显，其余跟随系统"
        }
        return "已关闭：完全不注入，所有 app 跟随系统（默认核显）"
    }

    var body: some View {
        // 2026-11-17：分组标题上移成卡片标题（ControlView 的 gpuCard），
        // 段内不再重复一行「显卡 · 默认使用哪块 GPU」。
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用显卡路由").font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.txt)
                    if !hideCardSubs {
                        Text("注入机制的总闸：开启后新启动的进程会载入路由组件，但只有下面白名单里的 app 才默认拿到独显（RTX 2070S），名单外的 app 一律跟随系统（内屏挂在核显上）。关闭则完全不注入。")
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
            //   · +：菜单（当前最前面的 App / 其他 App…文件选择器），把 app 加入独显白名单；
            //   · −：移除列表里选中的 app（未选中时置灰）；
            //   · 行可点选，选中蓝底高亮；替代原来的 per-row「移除」链接和最前面 App 胶囊按钮。
            // 2026-11-24：名单语义从「核显例外」反转为「独显白名单」。
            HStack(spacing: 6) {
                Text("使用独显的 App")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.txt)
                Text("（白名单 · 只有这些 app 被路由到独显，其余按系统默认走核显）")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim2)
                Spacer(minLength: 4)
                gpuListButtons
            }

            // 名单框：panel2 底 + 描边，与核心温度块同款容器
            VStack(alignment: .leading, spacing: 0) {
                if gpuIncludes.isEmpty {
                    Text("还没有添加 · 点右上角 + 把 app 加进来")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim2)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(gpuIncludes, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim2)
                            Text(id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(id == selectedInclude ? Theme.txt : Theme.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            if id == selectedInclude {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.blue.opacity(0.16))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedInclude = id }
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
            if let s = selectedInclude, !gpuIncludes.contains(s) {
                selectedInclude = nil
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

    private func setGpuInclude(_ id: String, on: Bool) {
        Task {
            let r = await backend.post("/api/gpu/include", ["bundle": id, "on": on])
            gpuMsg = (r["ok"] as? Bool == true) ? nil : (r["error"] as? String)
            if on, r["ok"] as? Bool == true { selectedInclude = id }
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
                   !gpuIncludes.contains(front) {
                    Button {
                        if front.hasPrefix("com.apple.") {
                            gpuMsg = "系统 App（\(front)）会拒绝注入，加了也不生效，不添加"
                        } else {
                            setGpuInclude(front, on: true)
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
            .help("添加使用独显的 App")

            // −：移除选中的 app
            Button {
                guard let s = selectedInclude else { return }
                setGpuInclude(s, on: false)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selectedInclude == nil ? Theme.dim2 : Theme.red)
                    .frame(width: 22, height: 20)
                    .background(Theme.panel2,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(selectedInclude == nil)
            .help("移除选中的 App")
        }
    }

    /// 文件选择器挑 app：读选中 .app 的 CFBundleIdentifier 加入白名单
    private func pickAppToAdd() {
        let panel = NSOpenPanel()
        panel.title = "选择使用独显的 App"
        panel.message = "选择一个 .app，会把它的 Bundle ID 加入独显白名单（对之后启动的 app 生效）"
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
        if gpuIncludes.contains(id) {
            gpuMsg = "\(id) 已经在白名单里"
            return
        }
        if id.hasPrefix("com.apple.") {
            gpuMsg = "系统 App（\(id)）会拒绝注入，加了也不生效，不添加"
            return
        }
        setGpuInclude(id, on: true)
    }
}
