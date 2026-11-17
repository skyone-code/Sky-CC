//
//  InputMonitorPermission.swift
//  Sky CC —— 「输入监控」（kTCCServiceListenEvent）授权
//
//  为什么需要单独处理：
//  输入监控不像相机/麦克风那样「一访问就弹框」，系统**只在 App 主动调用
//  IOHIDRequestAccess / CGRequestListenEventAccess 时**才会给出授权弹窗。
//  不请求的话，IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice) 会一直返回
//  kIOReturnNotPermitted（-536870174），表现为「双击没反应」，且系统设置里
//  连这个 App 都不会出现。
//

import Foundation
import AppKit
import IOKit.hid

enum InputMonitorPermission {

    /// 当前授权状态：granted / denied / unknown（从未询问过）
    static var state: IOHIDAccessType { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }

    static var granted: Bool { state == kIOHIDAccessTypeGranted }

    static var denied: Bool { state == kIOHIDAccessTypeDenied }

    /// 请求授权。
    /// - 状态未决（unknown）：系统弹原生授权框，返回用户的选择结果
    /// - 已拒绝：系统不再弹框（只能去系统设置里手动打开），直接返回 false
    @discardableResult
    static func request() -> Bool {
        if granted { return true }
        guard state == kIOHIDAccessTypeUnknown else { return false }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// 被拒时给一次明确指引（带跳转按钮）。只在主线程调用。
    /// - Parameter restartHint: 已授权但仍打不开设备时，提示需要重开 App
    static func presentGuidance(restartHint: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)

        let a = NSAlert()
        a.messageText = restartHint ? "授权已变更，需要重新打开 Sky CC" : "需要「输入监控」权限"
        a.informativeText = restartHint
            ? "「输入监控」授权刚被修改，系统要求 App 重启后才对新连接生效。\n请从菜单栏退出 Sky CC 再重新打开。"
            : "双击触控板左上角切换锁定，需要「输入监控」权限。\n请在「系统设置 → 隐私与安全性 → 输入监控」中勾选 Sky CC，然后重新打开 Sky CC。"
        a.alertStyle = .informational
        a.addButton(withTitle: restartHint ? "知道了" : "打开系统设置")
        a.addButton(withTitle: "稍后")
        if a.runModal() == .alertFirstButtonReturn, !restartHint {
            openSettings()
        }
    }
}
