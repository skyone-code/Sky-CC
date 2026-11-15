//
//  NativeHID.swift
//  Sky CC —— IOKit HID 用户态封装（原生移植）
//
//  对应 Python 版 app-resources/hid.py。
//
//  用途：打开 ITE 8291 (048d:6004/6006/600B/CE00) 键盘灯控制器，收发 HID Feature /
//  Output 报告。该设备挂的是通用 AppleUserHIDDevice，没有被系统事件驱动
//  独占，用户态可以直接 open + 写报告。
//
//  【安全提醒】写操作会真实改变键盘灯状态。
//

import Foundation
import IOKit
import IOKit.hid    // IOHIDReportType / IOHIDDeviceSetReport 等在 hid 子模块

private let kIOHIDOptionsTypeNone: IOOptionBits = 0
private let kIOHIDOptionsTypeSeizeDevice: IOOptionBits = 1

final class HIDDevice {
    private let service: io_service_t
    private let device: IOHIDDevice
    private let props: [String: Any]
    private var opened = false

    fileprivate init(service: io_service_t, device: IOHIDDevice, props: [String: Any]) {
        self.service = service
        self.device = device
        self.props = props
    }

    deinit {
        if opened { close() }
        IOObjectRelease(service)
    }

    // -- 属性 --
    var vendorID: Int? { props["VendorID"] as? Int }
    var productID: Int? { props["ProductID"] as? Int }
    var product: String? { props["Product"] as? String }
    var manufacturer: String? { props["Manufacturer"] as? String }
    var usagePage: Int? { props["PrimaryUsagePage"] as? Int }
    var usage: Int? { props["PrimaryUsage"] as? Int }
    var maxFeatureReportSize: Int? { props["MaxFeatureReportSize"] as? Int }
    var maxOutputReportSize: Int? { props["MaxOutputReportSize"] as? Int }
    var maxInputReportSize: Int? { props["MaxInputReportSize"] as? Int }

    func info() -> [String: Any] { props }

    // -- 开关 --
    func open(seize: Bool = false) throws {
        let opts: IOOptionBits = seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        let kr = IOHIDDeviceOpen(device, opts)
        if kr != KERN_SUCCESS {
            throw NSError(domain: "HIDDeviceOpen", code: Int(kr),
                          userInfo: [NSLocalizedDescriptionKey: "IOHIDDeviceOpen 失败 (kern_return=\(kr))"])
        }
        opened = true
    }

    func close() {
        if opened {
            IOHIDDeviceClose(device, kIOHIDOptionsTypeNone)
            opened = false
        }
    }

    // -- 报告收发 --
    /// 发送 Feature/Output 报告；返回 kern_return_t
    func setReport(_ payload: [UInt8], reportType: IOHIDReportType, reportID: CFIndex = 0) -> kern_return_t {
        guard !payload.isEmpty else { return kern_return_t(KERN_FAILURE) }
        var buf = payload
        return buf.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return kern_return_t(KERN_FAILURE) }
            return IOHIDDeviceSetReport(device, reportType, reportID, base, CFIndex(payload.count))
        }
    }
    func getReport(_ length: Int, reportType: IOHIDReportType, reportID: CFIndex = 0) -> (kern_return_t, Data?) {
        var buf = [UInt8](repeating: 0, count: max(1, length))
        var size = CFIndex(length)
        let kr = buf.withUnsafeMutableBufferPointer { ptr -> kern_return_t in
            guard let base = ptr.baseAddress else { return kern_return_t(KERN_FAILURE) }
            return IOHIDDeviceGetReport(device, reportType, reportID, base, &size)
        }
        if kr != KERN_SUCCESS { return (kr, nil) }
        return (kr, Data(buf.prefix(max(0, size))))
    }
}

// MARK: - 枚举

enum NativeHID {
    private static let propKeys = ["VendorID", "ProductID", "Product", "Manufacturer",
                                   "PrimaryUsagePage", "PrimaryUsage", "MaxFeatureReportSize",
                                   "MaxOutputReportSize", "MaxInputReportSize",
                                   "ReportDescriptor", "Transport", "LocationID", "Built-In",
                                   // 2.7.7：触控板锁定要靠它区分「VoodooInput 的虚拟设备」
                                   // 与真实硬件（虚拟设备 serial = "Voodoo Magic Trackpad 2 Simulator"）
                                   "SerialNumber"]

    /// 枚举 HID 设备，可按 VID/PID/UsagePage 过滤
    static func findDevices(vendorID: Int? = nil, productID: Int? = nil,
                            usagePage: Int? = nil) -> [HIDDevice] {
        guard let matching = IOServiceMatching("IOHIDDevice") else { return [] }
        var iter: io_iterator_t = 0
        // 主端口必须传 0（kIOMainPortDefault），传 mach_task_self_ 会枚举不到任何设备
        guard IOServiceGetMatchingServices(0, matching, &iter) == KERN_SUCCESS,
              iter != 0 else { return [] }
        defer { IOObjectRelease(iter) }

        var out: [HIDDevice] = []
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                IOObjectRelease(service)
                continue
            }
            var props: [String: Any] = [:]
            for key in propKeys {
                if let v = IOHIDDeviceGetProperty(dev, key as CFString) {
                    if let n = v as? NSNumber {
                        props[key] = n.intValue
                    } else if let s = v as? String {
                        props[key] = s
                    }
                }
            }
            if let vid = vendorID, props["VendorID"] as? Int != vid {
                IOObjectRelease(service)
                continue
            }
            if let pid = productID, props["ProductID"] as? Int != pid {
                IOObjectRelease(service)
                continue
            }
            if let up = usagePage, props["PrimaryUsagePage"] as? Int != up {
                IOObjectRelease(service)
                continue
            }
            out.append(HIDDevice(service: service, device: dev, props: props))
        }
        return out
    }
}
