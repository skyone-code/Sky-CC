//
//  DriverInstallCenter.swift
//  驱动安装 / 卸载的进度状态中心（N 卡驱动页与网卡驱动页共用）
//
//  2026-11-22（用户报 bug）：两页的进度原来是页面自己的 @State，
//  一点别的页面，视图就被销毁、状态回到 .idle —— 后台的下载其实一直在跑，
//  回到驱动页却只剩一个「安装」按钮，再点一次还会重复下一份。
//  状态搬到窗口级单例：切页不丢，回来接着显示；也从根上挡住了「同一次安装被点两遍」。
//
//  真正干活的是 DriverInstaller / NetworkInstaller（静态函数，跑在全局队列，
//  本来就不随视图走），这里只负责把它们的回调结果存下来给界面看。
//

import SwiftUI

@MainActor
final class DriverInstallCenter: ObservableObject {
    static let shared = DriverInstallCenter()

    /// 一个驱动通道（N 卡 / 网卡）的安装进度
    struct Slot: Equatable {
        var phase: DriverInstallPhase = .idle
        /// 安装 / 卸载过程中回显的最后一行日志
        var log: String = ""
        var isUninstall = false        // 当前 phase 来自卸载流程（文案区分用）
        var uninstallDone = false      // 卸载成功后置位，卡片切到「已卸载」展示
    }

    @Published var nvidia = Slot()
    @Published var network = Slot()

    /// 哪个驱动通道
    enum Kind { case nvidia, network }

    func slot(_ kind: Kind) -> Slot {
        switch kind {
        case .nvidia:  return nvidia
        case .network: return network
        }
    }

    /// 开一次新的安装 / 卸载：清空上一次的日志与标志。
    /// 起始 phase 默认就占住「忙」，否则刚点完、第一条回调还没来的那几百毫秒里
    /// 按钮仍是可点的，连点两次会把同一份包下两遍。
    static func fresh(phase: DriverInstallPhase = .preparing,
                      isUninstall: Bool = false) -> Slot {
        Slot(phase: phase, log: "", isUninstall: isUninstall, uninstallDone: false)
    }
}
