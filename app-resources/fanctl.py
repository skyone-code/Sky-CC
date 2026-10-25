#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fanctl.py —— TongfangFan.kext 用户态客户端（ctypes，无第三方依赖）

原理:
    TongfangFan.kext 直接挂在 ACPI 的 PNP0C14（WMI）设备上，自解析 _WDG
    找到 ABBC0F6F 方法块，暴露 TongfangFanDriver IOService +
    TongfangFanUserClient。本模块经 IOServiceGetMatchingService →
    IOServiceOpen → IOConnectCallStructMethod 调用 kext 的
    externalMethod(selector=0)：

        入参 12 字节: {u32 selector, u32 arg1, u32 arg2}
        出参  8 字节: {i32 status, u32 result}

本机协议（已用 BIOS DSDT 反编译确认，与 Linux qc71_laptop 一致）:
    WMI GetSetULong 必须传 8 字节缓冲区 [addr_lo, addr_hi, data_lo, data_hi,
    0, read?, 0, 0]，DSDT 的 WMBC→OEMG 按 SAC1 分发：
        SAC1 = 0x0000 → WKBC：经 EC 邮箱(LDAT/HDAT/CMDL/CMDH + BFLG) 写 EC RAM
        SAC1 = 0x0100 → RKBC：经同一邮箱读 EC RAM，返回 40 字节 AC00

两个必须记住的坑:
    1. 写风扇相关寄存器前必须先置 CTRL_1(0x0741) bit0 开「手动门」，
       否则 EC 静默拒收（返回命令回显但值不变）。
    2. 不要直写 PWM(0x1804/0x1809) —— 会让 EC 停转风扇。
       正确做法是只写 FAN_CTRL 档位，让 EC 自己算占空比。

寄存器图: qc71_laptop ec.h（本机 DSDT OEM ID = QCCFL357，PROJ_ID = 8）
前置条件: TongfangFan.kext 已加载（双击 安装散热控制.command）。
"""
import ctypes
import ctypes.util
import json
import os
import threading
import time

__all__ = ['FanControl', 'kext_loaded']

# EC 邮箱（LDAT/HDAT/CMDL/CMDH + BFLG 忙标志）是全局单例资源：
# DSDT 的 WMBC→OEMG→WKBC/RKBC 用 If(!BFLG) 判忙，重叠访问会直接返回
# 0xFEFEFEFE（kext 转成 kIOReturnIOError）。所以所有 EC 事务必须串行化。
_EC_LOCK = threading.RLock()

# 0xE00002CA —— kext 在收到 0xFEFE 时返回的错误
KIO_RETURN_IO_ERROR = -536870198
# EC 忙时的重试策略
_EC_RETRIES = 8
_EC_RETRY_DELAY = 0.08


def is_ok(reply):
    """判断 kext 回复是否成功"""
    return bool(reply) and reply.get('status') == 0

# ---- 与 kext 端 TongfangFan.hpp 保持一致 ----
SEL_INFO = 0        # arg1 <- hasGuid
SEL_SET_MODE = 1    # arg1: 0 normal / 1 boost / 2 custom
SEL_SET_LEVEL = 2   # arg1: 0..5
SEL_RAW_METHOD = 3  # arg1: WMI methodId, arg2: data -> result
SEL_EC_WRITE = 4    # arg1: EC 16位地址, arg2: 16位数据
SEL_EC_READ = 5     # arg1: EC 16位地址 -> result = 读回值

# ---- EC 寄存器图（来自 Linux qc71_laptop，LAPQC71/QCCFL 家族）----
EC_FAN_CTRL   = 0x0751   # 风扇控制: bit4=TURBO bit5=AUTO bit6=BOOST, 0x80+n=级别
# 2026-10-16 由用户实物确认修正：他亲手换过 CPU 风扇，转速较高的那颗才是 CPU 风扇，
# 也就是 0x046C 对应 CPU、0x0464 对应 GPU —— 之前标反了。
# （两路占空比恒等，行为上无差别，但显示必须跟物理机器对得上。）
EC_FAN_RPM1   = 0x046C   # CPU 风扇转速（16位）
EC_FAN_RPM2   = 0x0464   # GPU 风扇转速（16位）
EC_FAN_TEMP1  = 0x043E   # CPU 附近温度（°C）
EC_FAN_TEMP2  = 0x044F   # GPU 附近温度（°C）
EC_FAN_PWM1   = 0x1809   # CPU 风扇占空比（量程 0-200）—— 与转速寄存器一起对调，保持同组
EC_FAN_PWM2   = 0x1804   # GPU 风扇占空比（量程 0-200）
EC_CTRL_1     = 0x0741   # bit0 = 手动风扇模式
EC_CTRL_2     = 0x078C   # bit2-3 = TURBO_LEVEL(0-3)  ← CPU 性能档/功耗墙入口
EC_CTRL_3     = 0x07A5   # bit2=静音 bit4=超频 bit7=高性能（随档位自动变，勿手写）
EC_FAN_MODE_INDEX = 0x07AB  # 性能模式真正入口: 0x11=专业/性能 0x22=平衡 0x33=省电（OEM 魔数）
EC_MODE_PROFILE1 = 0x07B0  # 上面三档的镜像（0x11/0x22/0x33）
EC_BIOS_CTRL3 = 0x07A3   # bit5=降低占空比 bit6=常转（BIOS 的风扇最低选项）
EC_BATT_CHARGE = 0x07B9  # 电池充电阈值: bit0-6 = 百分比, bit7 = 已到达该阈值
EC_PL1        = 0x0783   # 功耗墙 PL1（本机实测读 0 —— 固件未启用，无控制入口）
EC_PL2        = 0x0784   # 功耗墙 PL2（同上）
# ---- 海岸灯（Lightbar / 灯条，OEM 的 DefaultRGBLightbar.exe 同走这组）----
EC_LIGHTBAR_CTRL  = 0x0748  # 控制字节: bit0/1/2/3/6/7 可写，bit4/5 被 EC 掩码
EC_LIGHTBAR_RED   = 0x0749  # 红通道 0-255（实测全程可写、回读一致）
EC_LIGHTBAR_GREEN = 0x074A  # 绿通道
EC_LIGHTBAR_BLUE  = 0x074B  # 蓝通道
# 已肉眼验证的三个取值（2026-10-16，用户逐个点过去看灯确认）：
LIGHTBAR_CYCLE    = 0x80    # 多彩轮换动画（机器原始基线，灯自己在轮色）
LIGHTBAR_STATIC   = 0x00    # 固定色，显示 RGB 寄存器里存的那个颜色
LIGHTBAR_OFF      = 0x84    # 关灯（= bit7 + bit2）
# 语义小结：bit7 = 轮换/动画（曾误推为开关位，实测清掉它只是停止轮换、定在固定色）；
#          bit2 = 关灯。
# 其余 bit0/1/3/6 的语义未知（OEM 侧还有 WelcomeMode / BreathingLightEffect 两个灯效开关）。
LIGHTBAR_WRITABLE_MASK = 0xCF   # 写之前先与一次，bit4/5 EC 不接受
EC_PL4        = 0x0785   # 功耗墙 PL4（同上）
EC_SUPPORT_1  = 0x0765   # bit7 = 支持 FAN_BOOST
EC_SUPPORT_2  = 0x0766   # bit0 = 支持静音模式（本机不支持）
EC_SUPPORT_5  = 0x0742   # bit4 = FAN_TURBO, bit5 = FAN
EC_PROJ_ID    = 0x0740   # 项目 ID，本机 = 8 (GK7CPCS_GK5CQ7Z)

# ---- 位定义（qc71_laptop ec.h）----
FAN_CTRL_LEVEL_MASK = 0x07
FAN_CTRL_TURBO      = 0x10
FAN_CTRL_AUTO       = 0x20
FAN_CTRL_BOOST      = 0x40
FAN_CTRL_AUTO_MODE  = 0xA0   # 0x80 | AUTO —— 交回 EC 自动调度
CTRL_1_MANUAL_MODE  = 0x01   # 手动风扇模式门控 —— 不开这道门，EC 拒收 FAN_CTRL/PWM 写入
CTRL_3_FAN_QUIET    = 0x04
CTRL_3_OVERBOOST    = 0x10
CTRL_3_HIGH_PWR     = 0x80

# CTRL_2 —— CPU 性能档（对应 OEM 的功耗墙/性能模式）
CTRL_2_TURBO_LEVEL_MASK = 0x0C   # bit2-3
CTRL_2_SINGLE_COLOR_KBD = 0x01
CTRL_2_KBD_BRIGHTNESS   = 0xE0   # bit5-7

# 电池充电阈值
BATT_CHARGE_MASK   = 0x7F        # bit0-6 = 百分比
BATT_CHARGE_REACHED = 0x80       # bit7  = 已达到该阈值（停止充电）

MODE_NAMES = {0: 'normal', 1: 'boost', 2: 'custom'}
MODE_CODES = {v: k for k, v in MODE_NAMES.items()}

STATE_DIR = os.path.expanduser(
    '~/Library/Application Support/MacConsole')
STATE_PATH = os.path.join(STATE_DIR, 'fan_state.json')

KEXT_ID = 'com.macconsole.TongfangFan'
SERVICE_CLASS = 'TongfangFanDriver'

_kIOReturnSuccess = 0

_IOKIT = None


def _iokit():
    global _IOKIT
    if _IOKIT is not None:
        return _IOKIT
    path = (ctypes.util.find_library('IOKit')
            or '/System/Library/Frameworks/IOKit.framework/IOKit')
    _IOKIT = ctypes.CDLL(path)
    return _IOKIT


def _mach_task_self():
    libc = ctypes.CDLL(None)
    return ctypes.c_uint32.in_dll(libc, 'mach_task_self_').value


class _Msg(ctypes.Structure):
    _fields_ = [('selector', ctypes.c_uint32),
                ('arg1', ctypes.c_uint32),
                ('arg2', ctypes.c_uint32)]


class _Reply(ctypes.Structure):
    _fields_ = [('status', ctypes.c_int32),
                ('result', ctypes.c_uint32)]


def _find_service():
    """枚举所有 TongfangFanDriver，优先返回 ABBC0F6F 实例（真 WMBC）。
    DBBC0F6F 设备上的 WMBC 是空壳（所有方法分支为空）。"""
    io = _iokit()
    io.IOServiceGetMatchingServices.restype = ctypes.c_int
    io.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint, ctypes.c_void_p,
                                                ctypes.POINTER(ctypes.c_uint)]
    io.IOServiceMatching.restype = ctypes.c_void_p
    io.IOServiceMatching.argtypes = [ctypes.c_char_p]
    io.IOIteratorNext.restype = ctypes.c_uint
    io.IOIteratorNext.argtypes = [ctypes.c_uint]
    io.IOObjectRelease.argtypes = [ctypes.c_uint]

    iter_h = ctypes.c_uint(0)
    kr = io.IOServiceGetMatchingServices(
        0, io.IOServiceMatching(SERVICE_CLASS.encode()), ctypes.byref(iter_h))
    if kr != 0:
        return 0
    fallback = 0
    target = 0
    while True:
        svc = io.IOIteratorNext(iter_h)
        if svc == 0:
            break
        if _service_is_abbc(svc):
            if target != 0:
                io.IOObjectRelease(target)
            target = svc
        elif fallback == 0:
            fallback = svc
        else:
            io.IOObjectRelease(svc)
    io.IOObjectRelease(iter_h)
    if target != 0:
        return target
    return fallback


def _service_is_abbc(svc):
    """检查服务实例的 WMIGuid 是否 ABBC0F6F（真 WMBC）"""
    io = _iokit()
    CF = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    CF.CFStringCreateWithCString.restype = ctypes.c_void_p
    CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    CF.CFStringGetCString.restype = ctypes.c_bool
    CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    CF.CFRelease.argtypes = [ctypes.c_void_p]
    io.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
    io.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint, ctypes.c_void_p,
                                                   ctypes.c_void_p, ctypes.c_uint]
    kUTF8 = 0x08000100
    key = CF.CFStringCreateWithCString(None, b'WMIGuid', kUTF8)
    prop = io.IORegistryEntryCreateCFProperty(svc, key, None, 0)
    CF.CFRelease(key)
    if not prop:
        return False
    buf = ctypes.create_string_buffer(64)
    ok = CF.CFStringGetCString(prop, buf, 64, kUTF8)
    CF.CFRelease(prop)
    return ok and buf.value.startswith(b'ABBC0F6F')


def kext_loaded():
    """探测 TongfangFanDriver 服务是否已注册（不打开连接）"""
    io = _iokit()
    io.IOServiceGetMatchingService.restype = ctypes.c_uint
    io.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]
    io.IOServiceMatching.restype = ctypes.c_void_p
    io.IOServiceMatching.argtypes = [ctypes.c_char_p]
    io.IOObjectRelease.argtypes = [ctypes.c_uint]

    svc = io.IOServiceGetMatchingService(
        0, io.IOServiceMatching(SERVICE_CLASS.encode()))
    if svc == 0:
        return False
    io.IOObjectRelease(svc)
    return True


class FanControl(object):
    """一次打开一次调用的轻量封装（每次操作各自开关连接）"""

    def _call_once(self, selector, arg1=0, arg2=0):
        io = _iokit()
        io.IOServiceGetMatchingService.restype = ctypes.c_uint
        io.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]
        io.IOServiceMatching.restype = ctypes.c_void_p
        io.IOServiceMatching.argtypes = [ctypes.c_char_p]
        io.IOServiceOpen.restype = ctypes.c_int
        io.IOServiceOpen.argtypes = [ctypes.c_uint, ctypes.c_uint,
                                     ctypes.c_uint, ctypes.POINTER(ctypes.c_uint)]
        io.IOServiceClose.argtypes = [ctypes.c_uint]
        io.IOObjectRelease.argtypes = [ctypes.c_uint]
        io.IOConnectCallStructMethod.restype = ctypes.c_int
        io.IOConnectCallStructMethod.argtypes = [
            ctypes.c_uint, ctypes.c_uint,
            ctypes.c_void_p, ctypes.c_size_t,
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]

        svc = _find_service()
        if svc == 0:
            return None  # kext 未加载
        conn = ctypes.c_uint(0)
        kr = io.IOServiceOpen(svc, _mach_task_self(), 0, ctypes.byref(conn))
        io.IOObjectRelease(svc)
        if kr != _kIOReturnSuccess:
            return {'status': kr, 'result': 0}

        msg = _Msg(selector, arg1, arg2)
        reply = _Reply()
        out_size = ctypes.c_size_t(ctypes.sizeof(_Reply))
        kr = io.IOConnectCallStructMethod(
            conn.value, 0, ctypes.byref(msg), ctypes.sizeof(_Msg),
            ctypes.byref(reply), ctypes.byref(out_size))
        io.IOServiceClose(conn.value)
        if kr != _kIOReturnSuccess:
            return {'status': kr, 'result': 0}
        return {'status': reply.status, 'result': reply.result}

    def _call(self, selector, arg1=0, arg2=0):
        """串行化 + EC 忙自动重试。EC 是全局单例，重叠访问必失败。"""
        with _EC_LOCK:
            reply = None
            for attempt in range(_EC_RETRIES):
                reply = self._call_once(selector, arg1, arg2)
                if reply is None:
                    return None            # kext 未加载
                if reply.get('status') == 0:
                    return reply
                # 只有 EC 忙(IOError)才重试；其他错误直接返回
                if reply.get('status') != KIO_RETURN_IO_ERROR:
                    return reply
                time.sleep(_EC_RETRY_DELAY * (attempt + 1))
            return reply

    # ---- 高层接口 ----

    def info(self):
        """kext 自检：返回 hasGuid 探测结果"""
        return self._call(SEL_INFO)

    def set_mode(self, mode):
        """mode: 'normal' | 'boost' | 'custom'
        按 Linux qc71_laptop 的控制流程（EC 层直写，不依赖 kext 内置字节表）：
            auto  -> FAN_CTRL = 0x80 | AUTO(0x20) = 0xA0
            boost -> FAN_CTRL = BOOST(0x40)，再把 PWM 拉到 0xFF（满占空比）
        """
        if mode not in ('normal', 'boost', 'custom'):
            raise ValueError('mode 必须是 normal/boost/custom')
        with _EC_LOCK:   # 整个序列原子完成，不让状态轮询插进来
            if mode == 'normal':
                # 关掉手动门 —— EC 立刻收回 FAN_CTRL/PWM 的管辖权并自行调度
                return self.ec_write(EC_CTRL_1, 0x00)
            if mode == 'boost':
                # 基准档：开手动门 + BOOST。实测 78% 占空比 / ~5500 RPM
                self.ec_write(EC_CTRL_1, CTRL_1_MANUAL_MODE)
                return self.ec_write(EC_FAN_CTRL, FAN_CTRL_BOOST)
            self.ec_write(EC_CTRL_1, CTRL_1_MANUAL_MODE)
            return self.ec_write(EC_FAN_CTRL, 0x80)

    def set_level(self, level):
        """手动档位 0-7（实测占空比 24% → 53%，转速 2328 → 4278 RPM）"""
        level = int(level)
        if not 0 <= level <= 7:
            raise ValueError('level 必须在 0-7')
        # 让 EC 按档位自己算占空比（直写 PWM 会让 EC 停转，必须避免）
        with _EC_LOCK:
            self.ec_write(EC_CTRL_1, CTRL_1_MANUAL_MODE)
            return self.ec_write(EC_FAN_CTRL, 0x80 | level)

    def set_pwm(self, percent):
        """按占空比百分比 0-100 选档（EC 不接受直写 PWM，只能选档位）
        实测映射: 档位 0-7 → 24%~53%，BOOST → 78%"""
        pct = max(0, min(100, int(percent)))
        if pct >= 70:
            return self.set_mode('boost')
        level = min(7, round(pct / 53.0 * 7))
        return self.set_level(level)

    def set_profile(self, profile):
        """「性能模式」专业/平衡/省电 —— 正确入口是 MyFanCCI_Mode_Index(0x07AB)。

        2026-10-16 05:00 修正：此前判定「无效」是**误判**（旧负载用 Python 线程，
        GIL 串行化只压满一个核，温度上不到 60℃，三档都停在最小占空比，当然测不出差异）。
        改用 12 个子进程真满载后确认三档均有可复现差异：

            0x11 专业(Gaming)     : CTRL_3=0x89 FAN_CTRL=0x00  风扇随温爬升 29→44%，算力最快
            0x22 平衡(Office)     : CTRL_3=0x88 FAN_CTRL=0xA0  风扇最猛(78℃就41-47%)，算力慢4~5%
            0x33 省电(BatterySaver): CTRL_3=0x8E FAN_CTRL=0xA0  风扇压在31%不动，算力慢5~9%

        写 0x07AB 会连带改 CTRL_3(0x07A5)/FAN_CTRL(0x0751) 和 EC 内部风扇调度区
        (页0 0xD0-0xDF 与页7 0x10-0x1F 是同一段16字节环形缓冲的两个视图)。

        ⚠️ 注意：本函数走的仍是旧的 CTRL_3 直写路径（bit2 FAN_QUIET 被 EC 掩码、
        bit4 OVERBOOST 无后果），那条路 2026-10-15 已实测走不通，保留仅供对照。
        真正生效的写法见 set_mode_index()。

        ⚠️ OEM 三套功耗预设(GAMING 65/100/130、OFFICE 45/65/160、BATTERYSAVER 35/60/160)
        在本机无效：本机没有功耗墙（只有温度墙），生效寄存器 0x0783/84/85 恒为 0，
        且直接写进去 0.3 秒内就被 EC 清零。
        """
        cur = self.ec_read(EC_CTRL_3)
        if cur.get('status') != 0:
            return cur
        v = cur.get('result', 0) & 0xFF
        if profile == 'quiet':
            v = (v | CTRL_3_FAN_QUIET) & ~CTRL_3_OVERBOOST
        elif profile == 'balance':
            v = v & ~CTRL_3_FAN_QUIET & ~CTRL_3_OVERBOOST
        elif profile == 'perf':
            v = (v | CTRL_3_OVERBOOST) & ~CTRL_3_FAN_QUIET
        else:
            raise ValueError('profile 必须是 quiet/balance/perf')
        return self.ec_write(EC_CTRL_3, v)

    def set_mode_index(self, code):
        """性能模式的正确入口：写 MyFanCCI_Mode_Index(0x07AB)。

        code: 0x11=专业/性能(Gaming)  0x22=平衡/均衡(Office)  0x33=省电(BatterySaver)
        这三个是 OEM 的魔数（枚举 Performance=1/Balanced=2/BatterySaver=3 各乘 0x11）。
        写完 EC 会自动连带设置 CTRL_3 与 FAN_CTRL，风扇行为和 CPU 算力随之改变。
        """
        if code not in (0x11, 0x22, 0x33):
            raise ValueError('code 必须是 0x11/0x22/0x33')
        return self.ec_write(EC_FAN_MODE_INDEX, code)

    def raw(self, method_id, data):
        """透传 WMI 方法（调试用）"""
        return self._call(SEL_RAW_METHOD, int(method_id), int(data))

    # ---- CPU 性能档：CTRL_2 的 TURBO_LEVEL (0-3) ----
    # ⚠️ 2026-10-16：控制页按钮与 /api/fan 的 turbo 字段已移除（实测无下游）。
    # 底层方法保留，仅用于将来若发现固件启用了功耗墙时快速恢复验证。
    def set_turbo(self, level):
        """CPU 性能档 0-3。对应 CTRL_2(0x078C) 的 bit2-3。
        需先开 CTRL_1 手动门，写完保持门开着（否则 EC 会回滚）。

        ⚠️ 实测本机「写得进去但没有任何可观测效果」，无法证明它等于 PL1/PL2：
          * PL1/PL2/PL4 设置寄存器 0x0783/0x0784/0x0785 恒读到 0，固件没启用；
          * 写完整个 EC 页（0x07 / 0x04 各 256 字节）做差分，只有 CTRL_2 自己变了；
          * 12 线程满载下切 0/1/2/3，迭代数 2339/2363/2379/2368 —— 全在 ±2% 的
            顺序漂移范围内。真要是 PL1 从 35W 变 65W，差距会是几十个百分点。
          * Linux qc71_laptop 的 ec.h 里这段注释写着「有些寄存器没用到，仅作文档」，
            TURBO_LEVEL 只在头文件里定义，驱动代码从未引用它。
        2026-10-16 补充定性：OEM 侧这是 TURBO_MODE 四档设置（1-4，默认 2），
        真实功能是在 Windows 上切电源计划（本机 hive 里出现过 Ultimate Performance
        方案，第 4 档疑为极限档）；macOS 没有电源计划机制，EC 侧又无功耗墙可调，
        所以无论第几档都没有下游。bit4 语义未实测，按红线不写。
        """
        level = int(level)
        if not 0 <= level <= 3:
            raise ValueError('turbo level 必须在 0-3')
        with _EC_LOCK:
            # 借一下 CTRL_1 手动门，写完立刻还原：
            # 实测关门后 TURBO_LEVEL 依然保持，而风扇能回到 EC 自动调度，
            # 所以不会留下「风扇脱离自动」的副作用
            prev = self.ec_read(EC_CTRL_1).get('result', 0) & 0xFF
            self.ec_write(EC_CTRL_1, CTRL_1_MANUAL_MODE)
            cur = self.ec_read(EC_CTRL_2).get('result', 0) & 0xFF
            v = (cur & ~CTRL_2_TURBO_LEVEL_MASK) | (level << 2)
            r = self.ec_write(EC_CTRL_2, v)
            if not (prev & CTRL_1_MANUAL_MODE):
                self.ec_write(EC_CTRL_1, prev)
            return r

    def turbo_level(self):
        """读当前 CPU 性能档 0-3"""
        r = self.ec_read(EC_CTRL_2)
        if not r or r.get('status') != 0:
            return None
        return ((r.get('result', 0) & 0xFF) >> 2) & 3

    # ---- 电池充电阈值：0x07B9 ----
    def set_charge_threshold(self, pct):
        """设电池充电阈值百分比（0 = 不限制）。
        实测可写：写 80 → 回读 0xD0（bit7 reached 置位）"""
        pct = int(pct)
        if not 0 <= pct <= 100:
            raise ValueError('充电阈值必须在 0-100')
        with _EC_LOCK:
            return self.ec_write(EC_BATT_CHARGE, pct & BATT_CHARGE_MASK)

    def charge_threshold(self):
        """读电池充电阈值：返回 (百分比, 是否已到达)"""
        r = self.ec_read(EC_BATT_CHARGE)
        if not r or r.get('status') != 0:
            return None
        v = r.get('result', 0) & 0xFF
        return {'percent': v & BATT_CHARGE_MASK, 'reached': bool(v & BATT_CHARGE_REACHED)}

    # ---- 海岸灯（Lightbar / 灯条）----
    def lightbar_status(self):
        """读海岸灯当前状态：一次性 4 字节读，不做轮询。

        该寄存器区域只验证了一半（可写、位掩码已知，但 CTRL 各 bit 语义未确认），
        所以刻意避免任何循环采样，把对 EC 邮箱的占用压到最低。
        """
        with _EC_LOCK:
            def rb(a):
                r = self.ec_read(a)
                if not r or r.get('status') != 0:
                    return None
                return r.get('result', 0) & 0xFF
            ctrl = rb(EC_LIGHTBAR_CTRL)
            r, g, b = rb(EC_LIGHTBAR_RED), rb(EC_LIGHTBAR_GREEN), rb(EC_LIGHTBAR_BLUE)
        if None in (ctrl, r, g, b):
            return None
        # bit2 是关灯位，优先级高于 bit7 的轮换位（0x84 = 关，0x80 = 轮换）
        if ctrl & 0x04:
            mode = 'off'
        elif ctrl & LIGHTBAR_CYCLE:
            mode = 'cycle'
        else:
            mode = 'static'
        return {'ctrl': ctrl, 'mode': mode,
                'rgb': [r, g, b], 'hex': '%02x%02x%02x' % (r, g, b)}

    def lightbar_set(self, rgb, ctrl=LIGHTBAR_CYCLE):
        """设置海岸灯：锁内一气呵成写 4 字节，随后回读一次供界面展示真实状态。

        ctrl 直接给控制字节（会先与 LIGHTBAR_WRITABLE_MASK 过滤，因为 bit4/5 EC 不接受）。
        不做渐变/动画/轮询——每次调用只占用 EC 邮箱一次。
        """
        r, g, b = (max(0, min(255, int(x))) & 0xFF for x in rgb)
        ctrl = int(ctrl) & LIGHTBAR_WRITABLE_MASK
        with _EC_LOCK:
            self.ec_write(EC_LIGHTBAR_CTRL, ctrl)
            self.ec_write(EC_LIGHTBAR_RED, r)
            self.ec_write(EC_LIGHTBAR_GREEN, g)
            self.ec_write(EC_LIGHTBAR_BLUE, b)
        return self.lightbar_status()

    def ec_probe(self):
        """一次性探测本机 EC 能力位，供「能力边界」页展示真实情况"""
        def rb(a):
            r = self.ec_read(a)
            return (r or {}).get('result', 0) & 0xFF
        with _EC_LOCK:
            s1, s2, s5 = rb(EC_SUPPORT_1), rb(EC_SUPPORT_2), rb(EC_SUPPORT_5)
            return {
                'proj_id': rb(EC_PROJ_ID),
                'support_fan_boost': bool(s1 & 0x80),
                'support_lightbar': bool(s1 & 0x40),
                'support_silent_mode': bool(s2 & 0x01),
                'support_fan_turbo': bool(s5 & 0x10),
                'pl1': rb(EC_PL1) | (rb(EC_PL1 + 1) << 8),
                'pl2': rb(EC_PL2) | (rb(EC_PL2 + 1) << 8),
                'turbo': ((rb(EC_CTRL_2) & 0xFF) >> 2) & 3,
                'modeindex': rb(EC_FAN_MODE_INDEX),
                'charge': rb(EC_BATT_CHARGE) & BATT_CHARGE_MASK,
                'charge_reached': bool(rb(EC_BATT_CHARGE) & BATT_CHARGE_REACHED),
            }

    # ---- v1.0.6: qc71 协议 EC RAM 读写 ----
    def ec_read(self, addr):
        """读 EC RAM 16 位地址，返回 (kr, value)"""
        r = self._call(SEL_EC_READ, addr & 0xFFFF, 0)
        return r

    def ec_write(self, addr, value):
        """写 EC RAM 16 位地址"""
        return self._call(SEL_EC_WRITE, addr & 0xFFFF, value & 0xFFFF)

    def fan_status(self):
        """读取风扇/温度/占空比状态（整组快照，避免与写入交错）"""
        with _EC_LOCK:
            return self._fan_status_locked()

    def _fan_status_locked(self):
        def byte_of(r):
            return (r or {}).get('result', 0) & 0xFF

        def rpm_of(r):
            """qc71: rpm = b1 << 8 | b2（大端）"""
            v = (r or {}).get('result', 0)
            return ((v & 0xFF) << 8) | ((v >> 8) & 0xFF)

        rpm1 = self.ec_read(EC_FAN_RPM1)
        rpm2 = self.ec_read(EC_FAN_RPM2)
        t1 = self.ec_read(EC_FAN_TEMP1)
        t2 = self.ec_read(EC_FAN_TEMP2)
        p1 = self.ec_read(EC_FAN_PWM1)
        p2 = self.ec_read(EC_FAN_PWM2)
        ctrl = self.ec_read(EC_FAN_CTRL)
        ctrl1 = self.ec_read(EC_CTRL_1)
        c3 = self.ec_read(EC_CTRL_3)
        mi = self.ec_read(EC_FAN_MODE_INDEX)

        mode = []
        v = byte_of(ctrl)
        if v & FAN_CTRL_BOOST:
            mode.append('BOOST')
        if v & FAN_CTRL_AUTO:
            mode.append('AUTO')
        if v & FAN_CTRL_TURBO:
            mode.append('TURBO')
        if v >= 0x80:
            mode.append('LV%d' % (v & 7))
        # 注意：不要把 CTRL_3 的 QUIET / OVERBOOST 位算进「当前模式」。
        # 实测（2026-10-15）：CTRL_3 bit2(FAN_QUIET) 写进去会被 EC 掩码掉（0x9D→回读 0x99）；
        # bit4(OVERBOOST) 虽然写得住，但清掉它风扇占空比/温度/转速完全不变。
        # 所以这两位不代表任何生效状态，显示出来只会误导人。
        prof = byte_of(c3)

        # EC 里的真实状态，用来校准界面显示（保存的设置可能因为下发失败而对不上）
        manual = bool(byte_of(ctrl1) & CTRL_1_MANUAL_MODE)
        if not manual:
            actual, actual_level = 'normal', 0
        elif v & FAN_CTRL_BOOST:
            actual, actual_level = 'boost', 0
        elif v >= 0x80:
            actual, actual_level = 'custom', v & 7
        else:
            actual, actual_level = 'custom', 0

        return {
            'rpm_cpu': rpm_of(rpm1),
            'rpm_gpu': rpm_of(rpm2),
            'temp_cpu': byte_of(t1),
            'temp_gpu': byte_of(t2),
            'pwm_cpu_pct': round(byte_of(p1) * 100 / 255),
            'pwm_gpu_pct': round(byte_of(p2) * 100 / 255),
            'fan_ctrl': v,
            'ctrl_1': byte_of(ctrl1),
            'manual': manual,
            'actual': actual,
            'actual_level': actual_level,
            'profile': prof,
            'modeindex': byte_of(mi),
            'mode': ' | '.join(mode) or 'AUTO',
        }


# ---- 状态持久化（重启后 EC 回默认，服务启动时自动恢复） ----

def load_state():
    try:
        with open(STATE_PATH, encoding='utf-8') as f:
            d = json.load(f)
        if d.get('mode') in MODE_CODES and 0 <= int(d.get('level', 0)) <= 7:
            return {'mode': d['mode'], 'level': int(d.get('level', 0))}
    except (OSError, ValueError):
        pass
    return None


def save_state(mode, level):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(STATE_PATH, 'w', encoding='utf-8') as f:
            json.dump({'mode': mode, 'level': int(level)}, f, ensure_ascii=False)
    except OSError:
        pass


def clear_state():
    try:
        os.remove(STATE_PATH)
    except OSError:
        pass


def apply_state():
    """服务启动时调用：恢复上次设置的模式/等级"""
    st = load_state()
    if not st:
        return {'ok': False, 'reason': 'no-saved-state'}
    fc = FanControl()
    if st['mode'] == 'custom':
        r = fc.set_level(st['level'])
    else:
        r = fc.set_mode(st['mode'])
    return {'ok': bool(r and r['status'] == 0), 'reply': r,
            'state': st}


if __name__ == '__main__':
    import sys
    if not kext_loaded():
        print('TongfangFanDriver 未加载 —— 先双击「安装散热控制.command」')
        sys.exit(1)
    fc = FanControl()
    if len(sys.argv) >= 2 and sys.argv[1] == 'status':
        print('风扇状态:', json.dumps(fc.fan_status(), ensure_ascii=False))
    elif len(sys.argv) >= 2 and sys.argv[1] == 'ec':
        # ec <r|w> <addr> [value]   例: ec r 0x751 / ec w 0x751 0x40
        op = sys.argv[2]
        addr = int(sys.argv[3], 0)
        if op == 'r':
            print('read  0x%04X ->' % addr, fc.ec_read(addr))
        elif op == 'w' and len(sys.argv) >= 5:
            val = int(sys.argv[4], 0)
            print('write 0x%04X = 0x%04X ->' % (addr, val), fc.ec_write(addr, val))
        else:
            print('用法: ec r <addr> | ec w <addr> <value>')
    elif len(sys.argv) >= 2 and sys.argv[1] == 'monitor':
        import time
        while True:
            st = fc.fan_status()
            print('CPU %s°C %5s RPM %3s%% | GPU %s°C %5s RPM %3s%% | '
                  'ctrl=0x%02X %s' % (
                      st['temp_cpu'], st['rpm_cpu'], st['pwm_cpu_pct'],
                      st['temp_gpu'], st['rpm_gpu'], st['pwm_gpu_pct'],
                      st['fan_ctrl'], st['mode']))
            time.sleep(2)
    elif len(sys.argv) >= 2 and sys.argv[1] == 'pwm':
        print('set_pwm:', sys.argv[2], '->', fc.set_pwm(sys.argv[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] == 'profile':
        print('set_profile:', sys.argv[2], '->', fc.set_profile(sys.argv[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] in ('mode', 'level', 'raw', 'state'):
        print('info :', fc.info())
        if sys.argv[1] == 'mode' and len(sys.argv) >= 3:
            print('set_mode:', sys.argv[2], '->', fc.set_mode(sys.argv[2]))
        elif sys.argv[1] == 'level' and len(sys.argv) >= 3:
            print('set_level:', sys.argv[2], '->', fc.set_level(int(sys.argv[2])))
        elif sys.argv[1] == 'raw' and len(sys.argv) >= 4:
            print('raw:', sys.argv[2], sys.argv[3], '->',
                  fc.raw(int(sys.argv[2]), int(sys.argv[3])))
        elif sys.argv[1] == 'state':
            print('saved:', load_state())
            print('apply :', apply_state())
    else:
        print('用法: fanctl.py status | monitor | '
              '[mode normal|boost] | [level 0-5] | [pwm 0-100] | '
              '[profile quiet|balance|perf] | [raw <m> <d>] | [state] | '
              '[ec r|w <addr> [value]]')
