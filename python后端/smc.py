#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
smc.py —— macOS SMC (System Management Controller) 读取模块

纯 ctypes 直调 IOKit 的 AppleSMC 用户客户端，无第三方依赖。
在本机（OpenCore + VirtualSMC）上实测可用。

提供: CPU 各核心温度、封装温度、电流、功耗、电压

【重要】ctypes 的 c_char 字段在 Python 3 下返回 bytes，
        比较必须用 b'\\x00'，用 0 会导致判断恒真。
"""
import ctypes
import ctypes.util
import struct
import threading

__all__ = ['SMC', 'decode', 'SmcError']

_IOCONNECT = None
_LOCK = threading.Lock()


def _load():
    global _IOCONNECT
    if _IOCONNECT is not None:
        return _IOCONNECT

    iokit_path = (ctypes.util.find_library('IOKit')
                  or '/System/Library/Frameworks/IOKit.framework/IOKit')
    libc_path = ctypes.util.find_library('System') or '/usr/lib/libSystem.B.dylib'

    IOKit = ctypes.CDLL(iokit_path)
    libc = ctypes.CDLL(libc_path)

    class Vers(ctypes.Structure):
        _fields_ = [('major', ctypes.c_char), ('minor', ctypes.c_char),
                    ('build', ctypes.c_char), ('reserved', ctypes.c_char),
                    ('release', ctypes.c_uint16)]

    class PLimit(ctypes.Structure):
        _fields_ = [('version', ctypes.c_uint16), ('length', ctypes.c_uint16),
                    ('cpuPLimit', ctypes.c_uint32), ('gpuPLimit', ctypes.c_uint32),
                    ('memPLimit', ctypes.c_uint32)]

    class KeyInfo(ctypes.Structure):
        _fields_ = [('dataSize', ctypes.c_uint32), ('dataType', ctypes.c_uint32),
                    ('dataAttributes', ctypes.c_char)]

    class KeyData(ctypes.Structure):
        _fields_ = [('key', ctypes.c_uint32), ('vers', Vers),
                    ('pLimitData', PLimit), ('keyInfo', KeyInfo),
                    ('result', ctypes.c_char), ('status', ctypes.c_char),
                    ('data8', ctypes.c_char), ('data32', ctypes.c_uint32),
                    ('bytes', ctypes.c_uint8 * 32)]

    IOKit.IOServiceMatching.restype = ctypes.c_void_p
    IOKit.IOServiceMatching.argtypes = [ctypes.c_char_p]
    IOKit.IOServiceGetMatchingService.restype = ctypes.c_uint32
    IOKit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    IOKit.IOServiceOpen.restype = ctypes.c_int
    IOKit.IOServiceOpen.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                    ctypes.c_uint32,
                                    ctypes.POINTER(ctypes.c_uint32)]
    IOKit.IOConnectCallStructMethod.restype = ctypes.c_int
    IOKit.IOConnectCallStructMethod.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t,
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
    IOKit.IOServiceClose.restype = ctypes.c_int
    IOKit.IOServiceClose.argtypes = [ctypes.c_uint32]
    libc.mach_task_self.restype = ctypes.c_uint32
    libc.mach_task_self.argtypes = []

    _IOCONNECT = dict(IOKit=IOKit, libc=libc, KeyData=KeyData,
                      SIZE=ctypes.sizeof(KeyData))
    return _IOCONNECT


# ---- 常量 ----
KERNEL_INDEX_SMC = 2
SMC_CMD_READ_BYTES = 5
SMC_CMD_READ_INDEX = 8
SMC_CMD_READ_KEYINFO = 9


class SmcError(RuntimeError):
    pass


class SMC:
    """AppleSMC 用户客户端。用作上下文管理器最省心:

        with SMC() as smc:
            data, dtype = smc.read('TC0P')
    """

    def __init__(self):
        env = _load()
        self._env = env
        matching = env['IOKit'].IOServiceMatching(b'AppleSMC')
        if not matching:
            raise SmcError('IOServiceMatching(AppleSMC) 失败')
        service = env['IOKit'].IOServiceGetMatchingService(0, matching)
        if not service:
            raise SmcError('系统中找不到 AppleSMC 服务')
        self._service = service
        conn = ctypes.c_uint32(0)
        kr = env['IOKit'].IOServiceOpen(
            service, env['libc'].mach_task_self(), 0, ctypes.byref(conn))
        if kr != 0:
            raise SmcError(f'IOServiceOpen 失败 (kern_return={kr})')
        self._conn = conn.value

    # -- 生命周期 --
    def close(self):
        if getattr(self, '_conn', 0):
            self._env['IOKit'].IOServiceClose(self._conn)
            self._conn = 0

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    # -- 底层 --
    def _call(self, inp, out):
        KD = self._env['KeyData']
        sz = ctypes.c_size_t(self._env['SIZE'])
        return self._env['IOKit'].IOConnectCallStructMethod(
            self._conn, KERNEL_INDEX_SMC,
            ctypes.byref(inp), self._env['SIZE'],
            ctypes.byref(out), ctypes.byref(sz))

    def key_count(self):
        data, _ = self.read('#KEY')
        if data and len(data) == 4:
            return struct.unpack('>I', data)[0]
        return 0

    def all_keys(self):
        """枚举全部键名（依赖 #KEY 计数）"""
        n = self.key_count()
        keys, seen = [], set()
        for i in range(n + 64):
            k = self._read_index(i)
            if k is None:
                break
            if k not in seen:
                seen.add(k)
                keys.append(k)
        return keys

    def _read_index(self, index):
        KD = self._env['KeyData']
        inp, out = KD(), KD()
        inp.data8 = bytes([SMC_CMD_READ_INDEX])
        inp.data32 = index
        if self._call(inp, out) != 0 or out.result != b'\x00':
            return None
        return struct.pack('>I', out.key).decode('ascii', 'replace')

    def read(self, key):
        """返回 (raw_bytes | None, data_type | None)"""
        KD = self._env['KeyData']
        try:
            k32 = struct.unpack('>I', key.encode('ascii'))[0]
        except Exception:
            return None, None

        inp, out = KD(), KD()
        inp.key = k32
        inp.data8 = bytes([SMC_CMD_READ_KEYINFO])
        if self._call(inp, out) != 0 or out.result != b'\x00':
            return None, None
        size = out.keyInfo.dataSize
        dtype = struct.pack('>I', out.keyInfo.dataType).decode('ascii', 'replace')

        inp2, out2 = KD(), KD()
        inp2.key = k32
        inp2.keyInfo.dataSize = size
        inp2.data8 = bytes([SMC_CMD_READ_BYTES])
        if self._call(inp2, out2) != 0 or out2.result != b'\x00':
            return None, dtype
        return bytes(bytearray(out2.bytes)[:size]), dtype

    def read_value(self, key):
        """直接返回解码后的 Python 数值/字符串，失败返回 None"""
        data, dtype = self.read(key)
        return decode(dtype, data)


def decode(dtype, data):
    """把 SMC 原始字节按类型解码为数值"""
    if data is None or dtype is None:
        return None
    try:
        if dtype in ('sp78', 'sp87', 'sp96', 'sp5a', 'sp69', 'sp4b'):
            if len(data) != 2:
                return None
            raw = struct.unpack('>h', data)[0]
            div = {'sp78': 256.0, 'sp87': 128.0, 'sp96': 64.0,
                   'sp5a': 1024.0, 'sp69': 512.0, 'sp4b': 2048.0}[dtype]
            return raw / div
        if dtype == 'fpe2' and len(data) == 2:
            return struct.unpack('>H', data)[0] / 4.0
        if dtype == 'flt' and len(data) == 4:
            return struct.unpack('<f', data)[0]
        if dtype == 'ui8 ' and len(data) == 1:
            return data[0]
        if dtype == 'si8 ' and len(data) == 1:
            return struct.unpack('>b', data)[0]
        if dtype == 'ui16' and len(data) == 2:
            return struct.unpack('>H', data)[0]
        if dtype == 'si16' and len(data) == 2:
            return struct.unpack('>h', data)[0]
        if dtype == 'ui32' and len(data) == 4:
            return struct.unpack('>I', data)[0]
        if dtype == 'si32' and len(data) == 4:
            return struct.unpack('>i', data)[0]
        if dtype == 'ui64' and len(data) == 8:
            return struct.unpack('>Q', data)[0]
        if dtype == 'flag':
            return data[0] if data else None
        if dtype == 'ch8*':
            return data.decode('ascii', 'replace').rstrip('\x00')
        if dtype.startswith('hex'):
            return data.hex()
    except Exception:
        return None
    return None


# --------------------------------------------------------------------------
# 高层封装：这台机器的实际可用传感器
# --------------------------------------------------------------------------

# i7-9750H: 6 个物理核心。TC1C~TC6C 是各核心温度，TC0P/TC0D/TC0E/TC0F/TC0H 是封装/接近温度
CORE_TEMP_KEYS = [f'TC{i}C' for i in range(1, 9)]
PACKAGE_TEMP_KEYS = ['TC0P', 'TC0D', 'TC0E', 'TC0F', 'TC0H', 'TC0p']
POWER_KEYS = {
    'PC0C': ('CPU 电流', 'A', 'sp96'),
    'PC0R': ('CPU 电流(读回)', 'A', 'sp96'),
    'PCPC': ('封装电流', 'A', 'sp96'),
    'PCPR': ('封装功率', 'W', 'sp96'),
    'PCPT': ('封装总功率', 'W', 'sp96'),
    'PCTR': ('CPU 总功率', 'W', 'sp96'),
    'PCAM': ('电流(flt)', 'A', 'flt'),
    'PCGC': ('显示核心时钟', 'GHz', 'flt'),
    'PCGM': ('显示核心时钟', 'GHz', 'flt'),
    'PCEC': ('能效值', '', 'flt'),
    'PC3C': ('核心电流', 'A', 'flt'),
    'VC0C': ('核心电压', 'V', 'sp96'),
}


def snapshot():
    """返回一份完整的传感器快照。SMC 不可用时返回 available=False。"""
    out = {
        'available': False,
        'error': None,
        'key_count': 0,
        'cores': [],          # [{name, celsius}]
        'package': [],        # [{name, celsius}]
        'power': [],          # [{name, value, unit, key}]
        'fan_available': False,
        'fan_note': None,
        'raw_temps': {},
    }

    try:
        with SMC() as smc:
            out['available'] = True
            out['key_count'] = smc.key_count()

            # 核心温度
            for i, key in enumerate(CORE_TEMP_KEYS, start=1):
                v = smc.read_value(key)
                if isinstance(v, float):
                    out['cores'].append({'name': f'核心 {i}', 'key': key,
                                         'celsius': round(v, 1)})
                    out['raw_temps'][key] = round(v, 1)

            # 封装温度
            for key in PACKAGE_TEMP_KEYS:
                v = smc.read_value(key)
                if isinstance(v, float) and v > 0:
                    out['package'].append({'name': key, 'key': key,
                                           'celsius': round(v, 1)})
                    out['raw_temps'][key] = round(v, 1)

            # 功耗/电流
            for key, (name, unit, _) in POWER_KEYS.items():
                v = smc.read_value(key)
                if isinstance(v, (int, float)) and v != 0:
                    out['power'].append({'key': key, 'name': name, 'unit': unit,
                                         'value': round(float(v), 3)})

            # 风扇 —— 本机 FNum=0，SMC 未建模风扇
            fan_num = smc.read_value('FNum')
            fac0 = smc.read_value('FAC0')
            f0ac = smc.read_value('F0Ac')
            has_fan = bool(f0ac) or bool(fan_num)
            out['fan_available'] = has_fan
            out['fan_keys'] = {'FNum': fan_num, 'FAC0': fac0, 'F0Ac': f0ac}
            if not has_fan:
                out['fan_note'] = (
                    'SMC 的 FNum=0，即 VirtualSMC 没有建模风扇。'
                    '风扇由 EC 固件独立控制，macOS 侧既读不到转速也写不了目标值。'
                    'F0Ac / F0Mn / F0Mx / F0Tg 全部不存在。'
                )
    except SmcError as e:
        out['error'] = f'SMC 不可用: {e}'
    except Exception as e:
        out['error'] = f'SMC 读取异常: {e}'

    return out


if __name__ == '__main__':
    import json
    print(json.dumps(snapshot(), ensure_ascii=False, indent=2))
