#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
屏幕亮度控制（macOS 原生，不依赖任何外部命令行工具）

走的是 IOKit 的公开显示参数接口：
    IODisplayGetFloatParameter / IODisplaySetFloatParameter
关键信息是display 参数名：kIODisplayBrightnessKey = "brightness"，取值 0.0 ~ 1.0。

比 auxbright 更好的地方：
  1. 不需要任何第三方二进制；
  2. 会遍历所有显示器（内置 + 外接的 AppleDisplay 通道），而不是只认主屏；
  3. 读写对称，UI 上的滑条可以反映真实当前亮度。

已知限制：走 DDC/CI 的外接显示器这个接口可能不认，
那种情况下会返回 ok=False，但不会崩。
"""

import ctypes
import ctypes.util

__all__ = ['get_brightness', 'set_brightness', 'display_count']

K_IOMASTERPORTDEFAULT = 0
K_IODISPLAY_BRIGHTNESS_KEY = b'brightness'
K_CFSTRINGENCODING_UTF8 = 0x08000100


def _load():
    iokit_path = ctypes.util.find_library('IOKit')
    cf_path = ctypes.util.find_library('CoreFoundation')
    if not iokit_path or not cf_path:
        return None, None
    iokit = ctypes.CDLL(iokit_path, use_errno=True)
    cf = ctypes.CDLL(cf_path, use_errno=True)

    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p,
                                             ctypes.c_char_p,
                                             ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]

    iokit.IOServiceMatching.restype = ctypes.c_void_p
    iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]

    iokit.IOServiceGetMatchingServices.argtypes = [
        ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
    iokit.IOIteratorNext.argtypes = [ctypes.c_uint]
    iokit.IOIteratorNext.restype = ctypes.c_uint
    iokit.IOObjectRelease.argtypes = [ctypes.c_uint]

    iokit.IODisplayGetFloatParameter.argtypes = [
        ctypes.c_uint, ctypes.c_uint32, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float)]
    iokit.IODisplaySetFloatParameter.argtypes = [
        ctypes.c_uint, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_float]
    return iokit, cf


def _displays(iokit, cf):
    """返回所有可调亮度显示节点的 io_object_t 列表

    两类都枚举（独显驱动加载后显示栈多出 NVIDIA 节点，单一类匹配会漏）：
      - IODisplayConnect：亮度参数的正确宿主节点（display0，接手包文档钦点姿势）
      - IODisplay：AppleBacklightDisplay / AppleDisplay 对象（旧版只匹配这类）
    """
    out = []
    for cls in (b'IODisplayConnect', b'IODisplay'):
        matched = iokit.IOServiceMatching(cls)
        it = ctypes.c_uint(0)
        kr = iokit.IOServiceGetMatchingServices(K_IOMASTERPORTDEFAULT, matched,
                                                ctypes.byref(it))
        if kr != 0 or it.value == 0:
            continue
        while True:
            svc = iokit.IOIteratorNext(it.value)
            if svc == 0:
                break
            out.append(svc)
        iokit.IOObjectRelease(it.value)
    return out


def display_count():
    iokit, cf = _load()
    if not iokit:
        return 0
    return len(_displays(iokit, cf))


def get_brightness():
    """返回 dict: {ok, percent(0-100), raw(0-255 估算), displays, error}"""
    iokit, cf = _load()
    if not iokit:
        return {'ok': False, 'error': '无法加载 IOKit/CoreFoundation'}
    key = cf.CFStringCreateWithCString(None, K_IODISPLAY_BRIGHTNESS_KEY,
                                       K_CFSTRINGENCODING_UTF8)
    vals = []
    svcs = _displays(iokit, cf)
    try:
        for svc in svcs:
            v = ctypes.c_float(0.0)
            kr = iokit.IODisplayGetFloatParameter(svc, 0, key,
                                                  ctypes.byref(v))
            if kr == 0:
                vals.append(float(v.value))
    finally:
        cf.CFRelease(key)
        for svc in svcs:
            iokit.IOObjectRelease(svc)
    if not vals:
        return {'ok': False, 'error': '没有可通过 IOKit 调亮度的显示器'}
    pct = max(0.0, min(100.0, (sum(vals) / len(vals)) * 100.0))
    return {'ok': True, 'percent': round(pct, 1),
            'raw': int(round(pct / 100.0 * 255)), 'displays': len(vals)}


def set_brightness(percent):
    """设亮度，percent = 0..100。返回 dict: {ok, percent, applied, total}"""
    ensure_pwm_mode()   # PWMWAKE_V5
    try:
        pct = float(percent)
    except (TypeError, ValueError):
        return {'ok': False, 'error': '亮度值必须是数字'}
    pct = max(0.0, min(100.0, pct))

    iokit, cf = _load()
    if not iokit:
        return {'ok': False, 'error': '无法加载 IOKit/CoreFoundation'}
    key = cf.CFStringCreateWithCString(None, K_IODISPLAY_BRIGHTNESS_KEY,
                                       K_CFSTRINGENCODING_UTF8)
    svcs = _displays(iokit, cf)
    applied = 0
    try:
        for svc in svcs:
            kr = iokit.IODisplaySetFloatParameter(svc, 0, key,
                                                  ctypes.c_float(pct / 100.0))
            if kr == 0:
                applied += 1
    finally:
        cf.CFRelease(key)
        for svc in svcs:
            iokit.IOObjectRelease(svc)
    if applied == 0:
        return {'ok': False, 'error': '显示器拒绝了亮度写入（外接屏常见）',
                'total': len(svcs)}
    return {'ok': True, 'percent': pct, 'applied': applied,
            'total': len(svcs)}



# ---- PWMWAKE_V5 -----------------------------
# 面板默认处于 AUX 背光模式时不接受 PWM 引脚输出，任何 IOKit 亮度写入都会石沉大海。
# 写之前先确保面板在 PWM 模式（事件驱动守护负责常态，这里只做写入前的兜底，带节流）。
_LAST_PWM_ENSURE = [0.0]


def pwm_tool():
    import os as _os
    here = _os.path.dirname(_os.path.abspath(__file__))
    for p in [_os.path.expanduser("~/bin/pwmwake"),
              "/usr/local/bin/pwmwake",
              _os.path.join(here, "bin", "pwmwake"),
              _os.path.expanduser("~/bin/auxbright")]:
        if _os.path.isfile(p) and _os.access(p, _os.X_OK):
            return p
    return None


def ensure_pwm_mode(min_interval=1.5):
    """确保面板在 PWM 模式；返回 'pwmwake'/'auxbright'/None"""
    import subprocess as _sp
    import time as _t
    now = _t.time()
    if now - _LAST_PWM_ENSURE[0] < min_interval:
        return None
    _LAST_PWM_ENSURE[0] = now
    tool = pwm_tool()
    if not tool:
        return None
    arg = "ensure" if tool.endswith("pwmwake") else "pwm"
    try:
        _sp.run([tool, arg], capture_output=True, timeout=6)
        return "pwmwake" if arg == "ensure" else "auxbright"
    except Exception:
        return None
# ---- /PWMWAKE_V5 ----------------------------

if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1 and sys.argv[1] in ('set', 's'):
        print('set_brightness:', set_brightness(sys.argv[2]))
    print('get_brightness:', get_brightness())
