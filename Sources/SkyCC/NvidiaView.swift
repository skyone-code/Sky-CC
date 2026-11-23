//
//  NvidiaView.swift
//  「NVIDIA 驱动」页：版本对照、驱动组件、显卡信息、更新与卸载
//
//  功能结构参考 Vela-X（Xelon233/Vela-X，GPLv3）的 NVIDIA 标签页，
//  展示组件全用本项目的公共层（Card / GroupTitle / Chip / KVRow），与其他页面同一套皮肤。
//  数据层在 NvidiaUpdate.swift。
//

import SwiftUI
import AppKit

/// NVIDIA 品牌 logo（用户提供的 24×24 绿眼 SVG，打包在 Contents/Resources/）。
/// NSImage 从 macOS 11 起原生支持 SVG，无需转位图。
enum NvidiaBrandIcon {
    /// 2026-11-17（性能自查）：原来是 computed property —— 侧边栏每次 body 求值
    /// （含 MonitorStore 每拍触发的全局重算）都会从磁盘重新读一遍 SVG。
    /// 品牌图是常量，首次读取后缓存。
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "NvidiaLogo", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }()
}

struct NvidiaView: View {
    @EnvironmentObject var store: MonitorStore
    /// 安装进度放窗口级单例（2026-11-22 用户报 bug：切页后视图销毁，进度回到 .idle，
    /// 看起来像下载断了，其实后台还在跑；回来只剩「安装」按钮）
    @ObservedObject private var center = DriverInstallCenter.shared
    @State private var components: [NvidiaUpdate.Component] = []
    @State private var state: NvidiaUpdateState = NvidiaUpdate.stateFromCache()
    @State private var release: NvidiaRelease? = NvidiaUpdate.cachedRelease
    @State private var showUninstallConfirm = false

    private var installPhase: DriverInstallPhase { center.nvidia.phase }
    /// 安装/卸载过程中回显的最后一行日志
    private var installLog: String { center.nvidia.log }
    private var isUninstall: Bool { center.nvidia.isUninstall }   // 卸载流程产出的 phase（文案区分用）
    private var uninstallDone: Bool { center.nvidia.uninstallDone } // 卸载成功后置位，hero 卡切到「已卸载」展示

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 2026-11-14（用户要求）：与其他页对齐 —— 顶部大标题 PageHeader；
                // 工具条里的小字页名已全局去掉。
                header
                heroCard
                componentsCard
            }
            .padding(22)
        }

        .onAppear(perform: refresh)
        // 装完在同一页收尾；如果当时人在别的页面，回来时 onAppear 会重新读盘，一样能对上
        .onChange(of: installPhase) { _, new in
            guard case .succeeded = new else { return }
            components = NvidiaUpdate.components()
            state = NvidiaUpdate.stateFromCache()      // 卸载干净时它自己会给 .notInstalled
        }
        .confirmationDialog("确认卸载 NVIDIA 驱动？", isPresented: $showUninstallConfirm,
                            titleVisibility: .visible) {
            Button("卸载驱动（重启后生效）", role: .destructive) { runUninstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将以管理员权限执行 /Library/NullMoth/uninstall.sh：卸载四个驱动组件并删除 /Library/NullMoth。卸载后独显不再可用（回到纯核显），需要重启一次。")
        }
    }

    private var header: some View {
        PageHeader(title: "NVIDIA 驱动", sub: "版本对照 / 组件 / 一键安装")
    }

    private func refresh() {
        components = NvidiaUpdate.components()
        state = NvidiaUpdate.stateFromCache()
        release = NvidiaUpdate.cachedRelease
        // 2026-11-14（用户要求）：去掉每 6 小时自动检查更新机制 ——
        // 只保留手动「检查更新」按钮，进页不再自动发请求。
    }

    private func checkNow() {
        state = .checking
        NvidiaUpdate.fetchLatest { result in
            switch result {
            case .success(let rel):
                release = rel
                state = NvidiaUpdate.stateFromCache()
            case .failure(let error):
                state = .failed(installed: NvidiaUpdate.installedVersion() ?? "—",
                                message: error.localizedDescription)
            }
        } onEnrich: { rel in
            release = rel
            state = NvidiaUpdate.stateFromCache()
        }
    }

    // MARK: - 版本对照（hero 卡）

    private var heroCard: some View {
        Card(title: uninstallDone ? "驱动版本 · 已卸载，重启后生效"
             : (state.hasUpdate ? "驱动版本 · 有新版本 \(state.latestVersion ?? "")" : "驱动版本")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    // NVIDIA 绿眼 logo（用户要求，原页面没有图标）
                    if let logo = NvidiaBrandIcon.image {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 46, height: 46)
                            .padding(.top, 2)
                    }
                    versionBlock(title: "已安装",
                                 version: uninstallDone ? "已卸载"
                                          : (state.installedVersion ?? "—"),
                                 sub: uninstallDone ? "重启后生效"
                                      : (state.installedVersion == nil ? "未检测到驱动" : ""),
                                 color: uninstallDone ? Theme.amber : Theme.txt)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dim2)
                        .padding(.top, 14)

                    versionBlock(title: "GitHub 最新",
                                 version: state.latestVersion ?? release?.tag ?? "—",
                                 sub: publishedText,
                                 color: state.hasUpdate ? Theme.amber : Theme.txt)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 7) {
                        Chip(text: uninstallDone ? "已卸载" : state.statusLabel,
                             color: uninstallDone ? Theme.amber : state.statusColor,
                             filled: state.hasUpdate)
                        if state.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        // 2026-11-14（用户要求）：「每 6 小时自动检查」那行提示小字删除
                    }
                }

                if let notes = release?.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                if case .failed(_, let message) = state, !uninstallDone {
                    Text("检查失败：\(message)。版本号取自本地，不影响驱动本身。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if uninstallDone {
                        Text("卸载完成，重启后独显将回到纯核显状态")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                    } else if state.hasUpdate || state.installedVersion == nil {
                        // 2026-11-22（用户报 bug）：原来只有 hasUpdate 才给主按钮，
                        // 全新机器（没装过驱动、又没检测到新版本）界面上只剩
                        // 「检查更新」，根本找不到安装入口。未安装时主按钮就是「安装」。
                        Button {
                            beginInstall()
                        } label: {
                            // 失败后就地变成「重试」：安装流程已经停住、系统一个字节都没改，点一下重来
                            Text(installPhase.isBusy && !isUninstall
                                 ? installPhase.shortLabel
                                 : (installPhase.isFailed && !isUninstall
                                    ? "重试"
                                    : (state.hasUpdate
                                       ? "下载并安装 \(state.latestVersion ?? "")"
                                       : (state.latestVersion.map { "安装驱动 \($0)" } ?? "安装驱动"))))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                        .disabled(installPhase.isBusy)

                        Button(state.isChecking ? "检查中…" : (state.hasUpdate ? "重新检查" : "检查更新")) {
                            checkNow()
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isChecking || installPhase.isBusy)
                    } else {
                        Button(state.isChecking ? "检查中…" : "检查更新") {
                            checkNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isChecking || installPhase.isBusy)
                    }

                    // 重新安装（2026-11-20 用户要求）：本机装过驱动（installedVersion
                    // 有记录）才出现——没更新时也能重装，走 beginInstall
                    // （有缓存 tag 直接装最新版，没有就先查一次）
                    if state.installedVersion != nil, !installPhase.isBusy {
                        Button("重新安装") {
                            beginInstall()
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isChecking)
                    }

                    // 卸载：只有本机确实装了驱动才出现
                    if state.installedVersion != nil, !installPhase.isBusy {
                        Button("卸载驱动…", role: .destructive) {
                            showUninstallConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.red)
                    }

                    Spacer()
                }

                if installPhase != .idle {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if installPhase.isBusy { ProgressView().controlSize(.small) }
                            Text(phaseText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(installPhase.isFailed ? Theme.red : Theme.dim)
                        }
                        // 下载进度条（212 MB 离线包 / 首次安装 550 MB 固件包，光看百分比不够）
                        if let p = installPhase.progress {
                            ProgressView(value: p)
                                .progressViewStyle(.linear)
                                .tint(Theme.blue)
                        } else if installPhase.isDownloading {
                            ProgressView()      // 服务器没给长度时用不确定进度的条
                                .progressViewStyle(.linear)
                                .tint(Theme.blue)
                        }
                        if case .downloadingFirmware = installPhase {
                            Text("首次安装要从 NVIDIA 官方驱动包里取 GPU 固件（约 550 MB），下完逐个文件校验 SHA-256，只保留 4 个固件文件；已装过的固件会直接复用，不再下载。")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !installLog.isEmpty {
                            Text(installLog)
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(Theme.dim2)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if case .installing = installPhase {
                            Text(isUninstall
                                 ? "卸载过程会移除驱动组件并重建内核缓存，可能需要几分钟，期间请勿关机。日志：/tmp/mc-nvidia-uninstall.log"
                                 : "安装过程会替换 /Library/Extensions 驱动并重建内核缓存，可能需要几分钟，期间请勿关机。日志：\(DriverInstaller.logPath)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.dim2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// 卸载流程复用 DriverInstallPhase，把「安装」字样的文案替换掉
    private var phaseText: String {
        let raw = installPhase.label
        guard isUninstall else { return raw }
        return raw
            .replacingOccurrences(of: "安装中", with: "卸载中")
            .replacingOccurrences(of: "安装完成，请重启一次", with: "卸载完成，请重启一次")
            .replacingOccurrences(of: "失败：安装", with: "失败：卸载")
    }

    private func versionBlock(title: String, version: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim2)
            Text(version)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.dim2)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 112, alignment: .leading)
    }

    private var publishedText: String {
        guard let date = release?.published else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "发布于 " + f.string(from: date)
    }

    // MARK: - 驱动组件（状态点 + 状态签，与其他页同一套）

    private var componentsCard: some View {
        Card(title: "驱动组件") {
            VStack(alignment: .leading, spacing: 0) {
                // 显卡信息并入组件卡（2026-11-15 用户要求：样式与组件行一致，行间横线隔断）
                if !dgpu.isEmpty {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(store.dgpuReported ? Theme.green : Theme.amber)
                            .frame(width: 7, height: 7)

                        Text(BackendService.string(dgpu, "name") ?? "—")
                            .font(.system(size: 12, weight: .medium).monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)

                        Spacer()

                        Chip(text: store.dgpuReported ? "Metal 在线" : "遥测无数据",
                             color: store.dgpuReported ? Theme.green : Theme.amber)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.5)

                    HStack(spacing: 10) {
                        Circle()
                            .fill(store.dgpuReported ? Theme.green : Theme.amber)
                            .frame(width: 7, height: 7)

                        Text("遥测")
                            .font(.system(size: 12, weight: .medium).monospaced())

                        Spacer()

                        Chip(text: store.dgpuReported ? "在线" : "无数据",
                             color: store.dgpuReported ? Theme.green : Theme.amber)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.5)
                } else {
                    Text("没有检测到 NVIDIA 显卡（等性能页采集到后显示）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                        .padding(.vertical, 6)
                    Divider().opacity(0.5)
                }
                ForEach(Array(components.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(item.loaded ? Theme.green
                                  : (item.present ? Theme.amber : Theme.dim2))
                            .frame(width: 7, height: 7)

                        Text(item.name)
                            .font(.system(size: 12, weight: .medium).monospaced())

                        Text(item.bundleID)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(Theme.dim)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text(item.version)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.txt)
                            .textSelection(.enabled)

                        Chip(text: item.loaded ? "已加载" : (item.present ? "未加载" : "缺失"),
                             color: item.loaded ? Theme.green : (item.present ? Theme.amber : Theme.dim2))
                    }
                    .padding(.vertical, 6)

                    if index < components.count - 1 { Divider().opacity(0.5) }
                }
            }
        }
    }

    // MARK: - 显卡（并入驱动组件卡；原独立显卡卡已删）

    /// gpuInfo() 的 bus 是 PCIe 的那条就是独显（与性能页同一数据源）
    private var dgpu: [String: Any] {
        store.gpus.first { (BackendService.string($0, "bus") ?? "") == "PCIe" } ?? [:]
    }

    // MARK: - 通用

    // MARK: - 一键下载安装

    /// 点「下载并安装」：有版本号就直接装，没有就先查一次最新版本再装
    private func beginInstall() {
        guard !installPhase.isBusy else { return }
        if let tag = release?.tag {
            runInstall(tag: tag)
        } else {
            center.nvidia = DriverInstallCenter.fresh()   // 先占住「忙」，连点不会跑两份
            NvidiaUpdate.fetchLatest { result in
                switch result {
                case .success(let rel):
                    release = rel
                    state = NvidiaUpdate.stateFromCache()
                    runInstall(tag: rel.tag)
                case .failure(let error):
                    center.nvidia.phase = .failed("获取最新版本号失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func runInstall(tag: String) {
        // 起始就是 0%，既让按钮立刻不可点，也如实反映「马上下离线包」
        center.nvidia = DriverInstallCenter.fresh(phase: .downloading(progress: 0))
        DriverInstaller.install(tag: tag) { phase in
            center.nvidia.phase = phase
        } onLog: { line in
            center.nvidia.log = line
        }
    }

    private func runUninstall() {
        center.nvidia = DriverInstallCenter.fresh(phase: .authorizing, isUninstall: true)
        DriverInstaller.uninstall { phase in
            center.nvidia.phase = phase
            if case .succeeded = phase {
                center.nvidia.uninstallDone = true
            }
        } onLog: { line in
            center.nvidia.log = line
        }
    }
}
