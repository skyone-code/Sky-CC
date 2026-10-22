#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hid.py —— IOKit HID 用户态封装（ctypes，无第三方依赖）

用途: 打开 ITE 8291 (0x048d:0xce00) 键盘灯控制器，
      收发 HID Feature / Output 报告。

这个设备挂的是通用 AppleUserHIDDevice，没有被系统事件驱动独占，
所以用户态可以直接 open + 写报告。

【安全提醒】写操作会真实改变键盘灯状态。首次接触请先只用只读命令
          (0x80 读固件版本) 验证协议，再执行写命令。
"""
import ctypes
import ctypes.util

__all__ = ['HIDDevice', 'find_devices', 'REPORT_TYPE']

REPORT_TYPE = {'input': 0, 'output': 1, 'feature': 2}

_CF = None
_IOKIT = None
_LOADED = None


def _load():
    global _LOADED
    if _LOADED:
        return _LOADED

    cf_path = (ctypes.util.find_library('CoreFoundation')
               or '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    iokit_path = (ctypes.util.find_library('IOKit')
                  or '/System/Library/Frameworks/IOKit.framework/IOKit')

    CF = ctypes.CDLL(cf_path)
    IOKit = ctypes.CDLL(iokit_path)

    # ---- CoreFoundation ----
    CF.CFStringCreateWithCString.restype = ctypes.c_void_p
    CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                             ctypes.c_uint32]
    CF.CFNumberCreate.restype = ctypes.c_void_p
    CF.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                  ctypes.c_void_p]
    CF.CFNumberGetValue.restype = ctypes.c_bool
    CF.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                    ctypes.c_void_p]
    CF.CFStringGetCString.restype = ctypes.c_bool
    CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_long, ctypes.c_uint32]
    CF.CFGetTypeID.restype = ctypes.c_ulong
    CF.CFGetTypeID.argtypes = [ctypes.c_void_p]
    CF.CFStringGetTypeID.restype = ctypes.c_ulong
    CF.CFStringGetTypeID.argtypes = []
    CF.CFNumberGetTypeID.restype = ctypes.c_ulong
    CF.CFNumberGetTypeID.argtypes = []
    CF.CFRelease.restype = None
    CF.CFRelease.argtypes = [ctypes.c_void_p]

    # ---- IOKit ----
    IOKit.IOServiceMatching.restype = ctypes.c_void_p
    IOKit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    IOKit.IOServiceGetMatchingServices.restype = ctypes.c_int
    IOKit.IOServiceGetMatchingServices.argtypes = [
        ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    IOKit.IOIteratorNext.restype = ctypes.c_uint32
    IOKit.IOIteratorNext.argtypes = [ctypes.c_uint32]
    IOKit.IOObjectRelease.restype = ctypes.c_int
    IOKit.IOObjectRelease.argtypes = [ctypes.c_uint32]

    IOKit.IOHIDDeviceCreate.restype = ctypes.c_void_p
    IOKit.IOHIDDeviceCreate.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    IOKit.IOHIDDeviceOpen.restype = ctypes.c_int
    IOKit.IOHIDDeviceOpen.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    IOKit.IOHIDDeviceClose.restype = ctypes.c_int
    IOKit.IOHIDDeviceClose.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    IOKit.IOHIDDeviceGetProperty.restype = ctypes.c_void_p
    IOKit.IOHIDDeviceGetProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    IOKit.IOHIDDeviceSetReport.restype = ctypes.c_int
    IOKit.IOHIDDeviceSetReport.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_long,
        ctypes.POINTER(ctypes.c_uint8), ctypes.c_long]
    IOKit.IOHIDDeviceGetReport.restype = ctypes.c_int
    IOKit.IOHIDDeviceGetReport.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_long,
        ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_long)]

    _LOADED = dict(CF=CF, IOKit=IOKit)
    return _LOADED


kCFNumberIntType = 9
kCFStringEncodingUTF8 = 0x08000100
kIOHIDOptionsTypeNone = 0
kIOHIDOptionsTypeSeizeDevice = 1


def _cfstr(s):
    env = _load()
    return env['CF'].CFStringCreateWithCString(None, s.encode('utf-8'),
                                               kCFStringEncodingUTF8)


def _prop_to_py(env, ref):
    """把 CFTypeRef 转成 Python 值"""
    CF = env['CF']
    if not ref:
        return None
    tid = CF.CFGetTypeID(ref)
    if tid == CF.CFStringGetTypeID():
        buf = ctypes.create_string_buffer(512)
        if CF.CFStringGetCString(ref, buf, 512, kCFStringEncodingUTF8):
            return buf.value.decode('utf-8', 'replace')
        return None
    if tid == CF.CFNumberGetTypeID():
        out = ctypes.c_int(0)
        if CF.CFNumberGetValue(ref, kCFNumberIntType, ctypes.byref(out)):
            return out.value
        return None
    return None


class HIDDevice:
    """一个已打开的 IOHIDDevice"""

    def __init__(self, service, dev_ref, props):
        self._service = service
        self._dev = dev_ref
        self._props = props
        self._opened = False

    # -- 属性 --
    @property
    def vendor_id(self):
        return self._props.get('VendorID')

    @property
    def product_id(self):
        return self._props.get('ProductID')

    @property
    def product(self):
        return self._props.get('Product')

    @property
    def manufacturer(self):
        return self._props.get('Manufacturer')

    @property
    def usage_page(self):
        return self._props.get('PrimaryUsagePage')

    @property
    def usage(self):
        return self._props.get('PrimaryUsage')

    @property
    def max_feature_report_size(self):
        return self._props.get('MaxFeatureReportSize')

    @property
    def max_output_report_size(self):
        return self._props.get('MaxOutputReportSize')

    @property
    def max_input_report_size(self):
        return self._props.get('MaxInputReportSize')

    def info(self):
        return dict(self._props)

    # -- 开关 --
    def open(self, seize=False):
        env = _load()
        opts = kIOHIDOptionsTypeSeizeDevice if seize else kIOHIDOptionsTypeNone
        kr = env['IOKit'].IOHIDDeviceOpen(self._dev, opts)
        if kr != 0:
            raise OSError(f'IOHIDDeviceOpen 失败 (kern_return={kr})，'
                          f'设备可能被其他进程独占')
        self._opened = True
        return self

    def close(self):
        if self._opened:
            env = _load()
            env['IOKit'].IOHIDDeviceClose(self._dev, kIOHIDOptionsTypeNone)
            self._opened = False

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()
        return False

    # -- 报告收发 --
    def set_report(self, payload, report_type='feature', report_id=0):
        env = _load()
        buf = (ctypes.c_uint8 * len(payload))(*payload)
        kr = env['IOKit'].IOHIDDeviceSetReport(
            self._dev, REPORT_TYPE[report_type], report_id, buf, len(payload))
        return kr

    def get_report(self, length, report_type='feature', report_id=0):
        env = _load()
        buf = (ctypes.c_uint8 * length)()
        sz = ctypes.c_long(length)
        kr = env['IOKit'].IOHIDDeviceGetReport(
            self._dev, REPORT_TYPE[report_type], report_id, buf,
            ctypes.byref(sz))
        if kr != 0:
            return kr, None
        return kr, bytes(bytearray(buf)[:sz.value])


def find_devices(vendor_id=None, product_id=None, usage_page=None):
    """枚举 HID 设备，可按 VID/PID/UsagePage 过滤"""
    env = _load()
    CF, IOKit = env['CF'], env['IOKit']

    matching = IOKit.IOServiceMatching(b'IOHIDDevice')
    if not matching:
        return []
    it = ctypes.c_uint32(0)
    if IOKit.IOServiceGetMatchingServices(0, matching, ctypes.byref(it)) != 0:
        return []

    out = []
    while True:
        service = IOKit.IOIteratorNext(it)
        if not service:
            break
        dev = IOKit.IOHIDDeviceCreate(None, service)
        if not dev:
            IOKit.IOObjectRelease(service)
            continue

        props = {}
        for key in ('VendorID', 'ProductID', 'Product', 'Manufacturer',
                    'PrimaryUsagePage', 'PrimaryUsage', 'MaxFeatureReportSize',
                    'MaxOutputReportSize', 'MaxInputReportSize',
                    'ReportDescriptor', 'Transport', 'LocationID', 'Built-In'):
            kref = _cfstr(key)
            vref = IOKit.IOHIDDeviceGetProperty(dev, kref)
            if vref:
                v = _prop_to_py(env, vref)
                if v is not None:
                    props[key] = v
            if kref:
                CF.CFRelease(kref)

        if vendor_id is not None and props.get('VendorID') != vendor_id:
            IOKit.IOObjectRelease(service)
            continue
        if product_id is not None and props.get('ProductID') != product_id:
            IOKit.IOObjectRelease(service)
            continue
        if usage_page is not None and props.get('PrimaryUsagePage') != usage_page:
            IOKit.IOObjectRelease(service)
            continue

        out.append(HIDDevice(service, dev, props))

    IOKit.IOObjectRelease(it)
    return out


def release(devs):
    env = _load()
    for d in devs:
        try:
            d.close()
        except Exception:
            pass
        if getattr(d, '_service', 0):
            env['IOKit'].IOObjectRelease(d._service)
            d._service = 0


if __name__ == '__main__':
    print('=== 全部 HID 设备 ===')
    for d in find_devices():
        print(f'  {d.vendor_id:#06x}:{d.product_id:#06x}  page={d.usage_page} '
              f'usage={d.usage}  feat={d.max_feature_report_size} '
              f'out={d.max_output_report_size}  {d.product!r}')

    print()
    print('=== 目标: ITE 8291 (0x048d:0xce00) ===')
    devs = find_devices(vendor_id=0x048d, product_id=0xce00)
    if not devs:
        print('  未找到')
    else:
        for d in devs:
            print(f'  {d.product} | {d.manufacturer}')
            print(f'  UsagePage={d.usage_page:#x} Usage={d.usage}')
            print(f'  Feature报告={d.max_feature_report_size}B '
                  f'Output报告={d.max_output_report_size}B '
                  f'Input报告={d.max_input_report_size}B')
