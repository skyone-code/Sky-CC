//
//  NetworkView.swift
//  「网卡驱动」页：二合一驱动包（Wi-Fi + 蓝牙）版本对照 + 一键更新
//
//  2026-11-15 用户定案：更新走 NVIDIA 驱动同款模式 —— 一个 release 一个包
//  （两个 kext + 随包安装脚本），App 下载后提权执行包内脚本。
//
//  布局与 NvidiaView 同一套皮肤（Card / GroupTitle / Chip / KVRow）：
//    · 顶部组件卡：四个 kext（AirportItlwm-Tahoe / BlueToolFixup / IntelBluetoothFirmware /
//      IntelBTPatcher）的加载状态 + 版本（kmutil showloaded，ESP plist 回退）
//    · 一张更新卡：包版本（本机记录）→ GitHub 最新；检查更新 / 下载并安装
//    · 底部说明卡：包内脚本负责备份替换、重启生效
//  数据层在 NetworkUpdate.swift。
//

import SwiftUI
import AppKit

struct NetworkView: View {
    @State private var components: [String: NvidiaUpdate.Component] = [:]
    @State private var state: NetworkUpdateState = .unknown
    @State private var release: NetworkUpdate.NetworkRelease?
    @State private var phase: DriverInstallPhase = .idle
    @State private var log: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "网卡驱动", sub: "Wi-Fi / 蓝牙 · 版本对照 · 一键更新")
                // 2026-11-15（用户要求）：更新卡（网卡驱动包）放上面，驱动组件卡放下面
                updateCard
                componentsCard
            }
            .padding(22)
        }

        .onAppear(perform: refresh)
    }

    // MARK: - 数据

    private func refresh() {
        for spec in NetworkUpdate.specs {
            components[spec.id] = NetworkUpdate.component(spec)
        }
        state = NetworkUpdate.stateFromCache()
        release = NetworkUpdate.cachedRelease()
    }

    private func checkNow() {
        state = .checking
        NetworkUpdate.fetchLatest { result in
            switch result {
            case .success(let rel):
                release = rel
                state = NetworkUpdate.stateFromCache()
            case .failure(let error):
                state = .failed(installed: NetworkUpdate.installedTag ?? "未记录",
                                message: error.localizedDescription)
            }
        }
    }

    private func runInstall(tag: String) {
        log = ""
        NetworkInstaller.install(tag: tag) { p in
            phase = p
            if case .succeeded = p { refresh() }
        } onLog: { line in
            log = line
        }
    }

    // MARK: - 组件卡

    private var componentsCard: some View {
        Card(title: "驱动组件") {
            VStack(alignment: .leading, spacing: 0) {
                let rows = NetworkUpdate.specs.compactMap { spec in
                    components[spec.id].map { (spec, $0) }
                }
                ForEach(Array(rows.enumerated()), id: \.element.0.id) { index, pair in
                    let (_, item) = pair
                    HStack(spacing: 10) {
                        Circle()
                            .fill(item.loaded ? Theme.green
                                  : (item.present ? Theme.amber : Theme.dim2))
                            .frame(width: 7, height: 7)

                        Text(item.name)
                            .font(.system(size: 12, weight: .medium).monospaced())

                        Spacer()

                        Text(item.version)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.txt)
                            .textSelection(.enabled)

                        Chip(text: item.loaded ? "已加载" : (item.present ? "未加载" : "缺失"),
                             color: item.loaded ? Theme.green : (item.present ? Theme.amber : Theme.dim2))
                    }
                    .padding(.vertical, 6)

                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
                if rows.isEmpty {
                    Text("没有在本机找到这四个 kext（未加载且 ESP 未挂载）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    // MARK: - 更新卡（单张，二合一包）

    private var updateCard: some View {
        let release_ = release

        return Card(title: NetworkPackage.title) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: "wifi")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.cyan)
                        .frame(width: 46, height: 46)
                        .padding(.top, 2)

                    versionBlock(title: "已装包版本",
                                 version: state.installedVersion ?? NetworkUpdate.installedTag ?? "—",
                                 sub: NetworkUpdate.installedTag == nil ? "未通过 App 安装过（未记录）" : "")

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dim2)
                        .padding(.top, 14)

                    versionBlock(title: "GitHub 最新",
                                 version: state.latestVersion ?? release_?.tag ?? "—",
                                 sub: publishedText(release_),
                                 color: state.hasUpdate ? Theme.amber : Theme.txt)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 7) {
                        Chip(text: state.statusLabel,
                             color: state.statusColor,
                             filled: state.hasUpdate)
                        if state.isChecking {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if case .failed(_, let message) = state {
                    Text("检查失败：\(message)。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if state.hasUpdate {
                        Button {
                            runInstall(tag: state.latestVersion ?? release_?.tag ?? "")
                        } label: {
                            Text(phase.isBusy ? phase.label : "下载并安装 \(state.latestVersion ?? "")")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                        .disabled(phase.isBusy)

                        Button(state.isChecking ? "检查中…" : "重新检查") {
                            checkNow()
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.isChecking || phase.isBusy)
                    } else {
                        Button(state.isChecking ? "检查中…" : "检查更新") {
                            checkNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isChecking || phase.isBusy)
                    }

                    // 重新安装（2026-11-20 用户要求）：只有通过 App 装过一次
                    // （installedTag 有记录）才出现；优先装已知最新版，
                    // release 还没拿到过就先检查一次再装。
                    if NetworkUpdate.installedTag != nil, !phase.isBusy {
                        Button("重新安装") {
                            if let tag = state.latestVersion ?? release_?.tag {
                                runInstall(tag: tag)
                            } else {
                                checkNow()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(phase.isBusy)
                    }

                    Spacer()
                }

                if phase != .idle {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if phase.isBusy { ProgressView().controlSize(.small) }
                            Text(phase.label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(isFailed(phase) ? Theme.red : Theme.dim)
                        }
                        if case .downloading(let p) = phase {
                            ProgressView(value: p)
                                .progressViewStyle(.linear)
                                .tint(Theme.blue)
                        }
                        if !log.isEmpty {
                            Text(log)
                                .font(.system(size: 9.5).monospaced())
                                .foregroundStyle(Theme.dim2)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if case .installing = phase {
                            Text("安装由包内脚本执行（备份 / 替换 / 校验均由脚本负责），完成后需要重启生效。日志：\(NetworkInstaller.logPath)")
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

    private func isFailed(_ phase: DriverInstallPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func versionBlock(title: String, version: String, sub: String = "",
                              color: Color = Theme.txt) -> some View {
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

    private func publishedText(_ release: NetworkUpdate.NetworkRelease?) -> String {
        guard let date = release?.published else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "发布于 " + f.string(from: date)
    }
}
