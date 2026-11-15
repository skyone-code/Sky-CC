//
//  LocationPermission.swift
//  Sky CC —— Wi-Fi SSID 的定位服务授权申请
//
//  背景（用户 2026-11-14 反馈「性能页 Wi-Fi 显示未关联 / SSID 需定位授权」）：
//  macOS 14 起 CoreWLAN 的 SSID 被 privacy 门控 —— app 必须持有定位服务授权
//  才能读到当前连接的 Wi-Fi 名称。而系统设置里**不会**主动出现 Sky CC
//  的条目，唯一的出路是 app 自己声明 NSLocationUsageDescription 并调用
//  CLLocationManager.requestWhenInUseAuthorization()，系统才会弹一次授权框，
//  之后「隐私与安全性 → 定位服务」里才有可以管理的条目。
//
//  本组件只做三件事：
//   ① 系统定位服务开着、且本 app 还没决定（notDetermined）时申请一次；
//   ② 授权状态变化后广播一条通知，让网络卡下一拍快照自然刷新出 SSID；
//   ③ 绝不主动开始定位 —— requestWhenInUseAuthorization 只是拿授权，
//      不调用 startUpdatingLocation 就不会有任何定位行为。
//

import CoreLocation

extension Notification.Name {
    /// 定位授权状态变化（性能页网络卡用它触发一次立即刷新）
    static let locationAuthChanged = Notification.Name("MacConsoleLocationAuthChanged")
}

@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()

    private let manager = CLLocationManager()
    /// 本次进程只申请一次：用户拒了就不再骚扰，界面保持降级文案
    private var requested = false

    /// 当前是否已经拿到授权（macOS 上只有 .authorized 一档；iOS 的
    /// authorizedWhenInUse 在 macOS SDK 里不可用）
    var granted: Bool {
        manager.authorizationStatus == .authorized
    }

    /// 性能页 onAppear 调用：能申请就申请，已授权/已拒绝/系统服务关着都不弹
    func requestIfNeeded() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        guard manager.authorizationStatus == .notDetermined, !requested else { return }
        requested = true
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .locationAuthChanged, object: nil)
        }
    }
}
