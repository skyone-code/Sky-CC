#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
server.py —— Mac 控制台本地后端

纯 Python 标准库实现（http.server + subprocess + ctypes），无第三方依赖。
启动后浏览器访问 http://127.0.0.1:8787

数据来源:
  sysctl / system_profiler / ioreg / pmset / df / ps  →  系统信息
  smc.py  (ctypes → IOKit AppleSMC)                   →  温度 / 功耗 / 电流
  rgbkb.py (ctypes → IOKit HID)                       →  键盘灯控制
"""
import ctypes
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, 'web')
sys.path.insert(0, HERE)

# psutil 随包自带（vendor/，cp36-abi3 wheel，兼容系统 python3.9）。
# 能用就用（CPU / 内存 / 网络 / 磁盘），拿不到就回退到原有的标准库实现，
# 保证在没有 vendor 的机器上也不会崩。
sys.path.insert(0, os.path.join(HERE, 'vendor'))
try:
    import psutil
    HAVE_PSUTIL = True
    try:                      # 预热一次，后续 cpu_percent(None) 才是区间均值
        psutil.cpu_percent(interval=0.1)
    except Exception:
        pass
except Exception:
    psutil = None
    HAVE_PSUTIL = False

import smc            # noqa: E402
import rgbkb          # noqa: E402
import fanctl         # noqa: E402
import bright         # noqa: E402  (屏幕亮度, IOKit IODisplay 参数接口)

PORT = int(os.environ.get('MACCONSOLE_PORT', '8787'))

# --------------------------------------------------------------------------
# 工具
# --------------------------------------------------------------------------

def sh(cmd, timeout=6):
    """执行命令，返回 stdout（失败返回空串）"""
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str),
                           capture_output=True, text=True, timeout=timeout)
        return p.stdout or ''
    except Exception:
        return ''


def sysctl(key, default=None):
    v = sh(['sysctl', '-n', key]).strip()
    return v if v else default


# --------------------------------------------------------------------------
# 数据采集
# --------------------------------------------------------------------------

_GPU_CACHE = {'t': 0, 'v': None}


def gpu_info():
    if time.time() - _GPU_CACHE['t'] < 30 and _GPU_CACHE['v']:
        return _GPU_CACHE['v']
    out = sh(['system_profiler', 'SPDisplaysDataType'], timeout=20)
    gpus = []
    cur = None
    for line in out.splitlines():
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(' '))
        s = line.strip()
        # GPU 名称：缩进恰为 4 个空格且以冒号结尾
        # （子项 Displays: / Display: 缩进为 6、8，要排除）
        if indent == 4 and s.endswith(':'):
            if cur:
                gpus.append(cur)
            cur = {'name': s[:-1].strip(), 'detail': {}}
            continue
        if cur and indent >= 6 and ':' in s:
            k, _, v = s.partition(':')
            cur['detail'][k.strip()] = v.strip()
    if cur:
        gpus.append(cur)
    for g in gpus:
        _normalize_gpu(g)
    _GPU_CACHE['t'] = time.time()
    _GPU_CACHE['v'] = gpus
    return gpus


# macOS 下独显没驱动（本机 NVIDIA），system_profiler 只给 Device ID，
# 没有 Chipset Model。常见 NVIDIA Device ID → 型号（PCI 数据库实测，
# 本机 0x1e91 = RTX 2070 Super）。查不到就退回「厂商 + Device ID」。
_NVIDIA_IDS = {
    '1e81': 'RTX 2080 Super', '1e82': 'RTX 2080', '1e84': 'RTX 2070 Super',
    '1e87': 'RTX 2080', '1e89': 'RTX 2060', '1e90': 'RTX 2080 Max-Q',
    '1e91': 'RTX 2070 Super', '1e93': 'RTX 2080 Super Max-Q',
    '1f02': 'RTX 2070 Super', '1f08': 'RTX 2070', '1f10': 'RTX 2070',
    '1f11': 'RTX 2060', '1f12': 'RTX 2060 Max-Q', '1f14': 'RTX 2070',
    '2184': 'GTX 1650 Super', '1c82': 'GTX 1050 Ti', '1c81': 'GTX 1050',
    '1b81': 'GTX 1070', '1b06': 'GTX 1080',
}


def _normalize_gpu(g):
    """统一 GPU 条目：name 取可显示型号，并补 bus / vendor 字段。

    macOS 没加载驱动的独显（本机 NVIDIA）在 system_profiler 里没有
    Chipset Model，标题行只剩「Display:」，直接用会显示成 "Display"。
    这里退回 Vendor + Device ID；同时补 bus（Built-In / PCIe）供 UI
    区分核显与独显——EC 0x044F 读的是独显温度，名称不能取 gpus.first
    （2026-10-17 修：磁贴曾显示「Intel UHD Graphics 630」张冠李戴）。
    """
    d = g.get('detail') or {}
    model = (d.get('Chipset Model') or '').strip()
    name = (g.get('name') or '').strip()
    if model:
        name = model
    if not name or name in ('Display', 'Graphics/Displays'):
        vendor = (d.get('Vendor') or '').strip()
        vendor = vendor.split('(')[0].strip() or vendor
        dev = (d.get('Device ID') or '').strip()
        model = _NVIDIA_IDS.get(dev.lower().lstrip('0x'))
        name = ' '.join(x for x in (vendor, model or dev) if x) or 'GPU'
    g['name'] = name
    g['bus'] = (d.get('Bus') or '').strip()
    g['vendor'] = (d.get('Vendor') or '').strip()


# CPU 占用率采样状态：host_processor_info 返回的是累计计数，两次求差才有意义
_CPU_TICK = {'tot': None, 'idle': None, 'pct': None}


def _cpu_sample():
    """采一次 host_processor_info，返回 (总计数, 空闲计数)；失败返回 None。"""
    try:
        class _ProcessorCpuLoadInfo(ctypes.Structure):
            _fields_ = [('user', ctypes.c_uint32), ('system', ctypes.c_uint32),
                        ('idle', ctypes.c_uint32), ('nice', ctypes.c_uint32)]

        libc = ctypes.CDLL('/usr/lib/libSystem.dylib')
        ncpu = ctypes.c_uint(0)
        info = ctypes.c_void_p()
        ncnt = ctypes.c_uint(0)
        # PROCESSOR_CPU_LOAD_INFO = 2
        kr = libc.host_processor_info(libc.mach_host_self(), 2,
                                      ctypes.byref(ncpu), ctypes.byref(info),
                                      ctypes.byref(ncnt))
        if kr != 0 or not info.value:
            return None
        n = ncpu.value or 1
        arr = ctypes.cast(info, ctypes.POINTER(_ProcessorCpuLoadInfo))
        tot = idle = 0
        for i in range(n):
            s = arr[i]
            tot += s.user + s.system + s.idle + s.nice
            idle += s.idle
        libc.vm_deallocate(libc.mach_task_self(), info,
                           n * ctypes.sizeof(_ProcessorCpuLoadInfo))
        return tot, idle
    except Exception:
        return None


def cpu_usage():
    """CPU 占用率（%）。

    优先 psutil（随包自带）；没有 psutil 时回退到原来的 mach 实现：
    走 host_processor_info 直接读 CPU 时间片累计计数，纯 ctypes、不 fork 子进程
    （本机沙箱把 ps / top 都禁了，而且 fork 一个 top 采瞬时占用本身也不准）。

    mach 路径两次采样求差才有意义，所以第一次调用会自己补采一次（约 120 ms），
    之后返回「距上一次调用」这段时间的平均占用率。
    """
    if HAVE_PSUTIL:
        try:
            v = psutil.cpu_percent(interval=None)
            if v is not None:
                return round(float(v), 1)
        except Exception:
            pass
    s = _cpu_sample()
    if s is None:
        return _CPU_TICK['pct']
    tot, idle = s
    prev_tot, prev_idle = _CPU_TICK['tot'], _CPU_TICK['idle']
    _CPU_TICK['tot'], _CPU_TICK['idle'] = tot, idle
    if prev_tot is None:
        # 第一次调用：补采一次，免得前端第一帧闪一个「—」
        time.sleep(0.12)
        return cpu_usage()
    d_tot = tot - prev_tot
    d_idle = idle - prev_idle
    if d_tot <= 0:
        return _CPU_TICK['pct']
    _CPU_TICK['pct'] = round(max(0.0, min(100.0, 100.0 * (1 - d_idle / d_tot))), 1)
    return _CPU_TICK['pct']


def overview():
    memsize = int(sysctl('hw.memsize', '0') or 0)
    mem = None
    if HAVE_PSUTIL:
        try:
            v = psutil.virtual_memory()
            mem = {'total': v.total, 'used': v.used, 'percent': round(v.percent, 1)}
        except Exception:
            mem = None
    vm = sh(['vm_stat'])
    page = 4096
    free_pages = inactive = 0
    for line in vm.splitlines():
        if 'page size of' in line:
            m = re.search(r'page size of (\d+)', line)
            if m:
                page = int(m.group(1))
        if line.startswith('Pages free'):
            free_pages = int(re.sub(r'\D', '', line) or 0)
        if line.startswith('Pages inactive'):
            inactive = int(re.sub(r'\D', '', line) or 0)

    used_mem = memsize - (free_pages + inactive) * page
    total_mem = memsize

    load = sysctl('vm.loadavg', '{ 0 0 0 }')
    load_vals = [float(x) for x in re.findall(r'[\d.]+', load)[:3]] or [0, 0, 0]

    bt = sysctl('kern.boottime', '')
    m = re.search(r'sec\s*=\s*(\d+)', bt)
    boot_sec = int(m.group(1)) if m else 0
    uptime = time.time() - boot_sec if boot_sec else 0

    return {
        'cpu': {
            'brand': sysctl('machdep.cpu.brand_string', '未知'),
            'physical': int(sysctl('hw.physicalcpu', '0') or 0),
            'logical': int(sysctl('hw.logicalcpu', '0') or 0),
            'freq_mhz': int(sysctl('hw.cpufrequency_max', '0') or 0) // 1000000 or None,
        },
        'memory': mem or {
            'total': total_mem,
            'used': max(0, used_mem),
            'percent': round(max(0, used_mem) / total_mem * 100, 1) if total_mem else 0,
        },
        'load': load_vals,
        'cpu_usage': cpu_usage(),
        # 2026-10-19 新增：GPU 占用率 / 硬盘温度 / 网络速率（顶部六宫格 + 网络卡）
        'gpu_usage': gpu_usage(),
        'disk_temp': disk_temp(),
        'net': net_usage(),
        'uptime': int(uptime),
        'os': {
            'name': sh(['sw_vers', '-productName']).strip(),
            'version': sh(['sw_vers', '-productVersion']).strip(),
            'build': sh(['sw_vers', '-buildVersion']).strip(),
        },
        'model': sysctl('hw.model', '未知'),
        'gpus': gpu_info(),
    }


# --------------------------------------------------------------------------
# GPU 占用率 / 硬盘温度 / 网络速率（2026-10-19 新增，供六宫格与网络卡使用）
# --------------------------------------------------------------------------

_GPU_USAGE_CACHE = {'t': 0, 'v': None}


def gpu_usage():
    """GPU 占用率（%）。

    psutil 不管 GPU，所以走 IORegistry：IOAccelerator 节点的
    PerformanceStatistics 字典里就有 "Device Utilization %"
    （与 exelban/Stats 同源，本机 IntelAccelerator 实测有该键）。
    多张卡时取最大值；ioreg 有 1 秒缓存，避免每帧都 spawn。
    """
    if time.time() - _GPU_USAGE_CACHE['t'] < 1.0 and _GPU_USAGE_CACHE['v'] is not None:
        return _GPU_USAGE_CACHE['v']
    out = sh(['ioreg', '-r', '-c', 'IOAccelerator', '-w0'], timeout=8)
    vals = [int(m.group(1))
            for m in re.finditer(r'"Device Utilization %"\s*=\s*(\d+)', out)]
    if not vals:   # 少数驱动写的是 GPU Activity(%)
        vals = [int(m.group(1))
                for m in re.finditer(r'"GPU Activity\(%\)"\s*=\s*(\d+)', out)]
    v = max(vals) if vals else None
    _GPU_USAGE_CACHE['t'] = time.time()
    _GPU_USAGE_CACHE['v'] = v
    return v


_DISK_TEMP_CACHE = {'t': 0, 'v': None}


def _nvmetemp_path():
    for c in (os.path.join(HERE, 'bin', 'nvmetemp'),
              '/usr/local/bin/nvmetemp',
              os.path.expanduser('~/bin/nvmetemp')):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def disk_temp():
    """硬盘温度（℃）——NVMe SMART。

    SMART 在 macOS 上只有 IOKit 的 user client plugin（NVMeSMARTLib.plugin）能取，
    Python 侧没有绑定，所以做成命令行小工具 bin/nvmetemp（源码见项目 06-工具源码）。
    SMART 不必高频刷，缓存 15 秒。
    """
    if time.time() - _DISK_TEMP_CACHE['t'] < 15 and _DISK_TEMP_CACHE['v'] is not None:
        return dict(_DISK_TEMP_CACHE['v'])
    exe = _nvmetemp_path()
    if not exe:
        return {'ok': False, 'error': '缺少 nvmetemp'}
    raw = sh([exe], timeout=6).strip()
    try:
        data = json.loads(raw)
    except Exception:
        data = {'ok': False, 'error': 'nvmetemp 输出异常'}
    _DISK_TEMP_CACHE['t'] = time.time()
    _DISK_TEMP_CACHE['v'] = data
    return dict(data)


_NET_TICK = {'t': 0, 'sent': 0, 'recv': 0}


def net_usage():
    """网络上下行速率（KB/s）+ 累计流量。

    psutil.net_io_counters() 优先；没有 psutil 时回退 netstat -ib 累加。
    速率 = 相邻两次采样的字节差 / 间隔（首次采样返回 0）。
    """
    sent = recv = None
    if HAVE_PSUTIL:
        try:
            # 按网卡分开统计，跳过 lo0：本机 API 轮询走回环，
            # 算进去会让上下行出现「两者几乎相等」的假流量（2026-10-19 修）
            c = psutil.net_io_counters(pernic=True)
            s = r = 0
            for nic, v in c.items():
                if nic == 'lo0' or nic.startswith('lo'):
                    continue
                s += v.bytes_sent
                r += v.bytes_recv
            sent, recv = s, r
        except Exception:
            sent = recv = None
    if sent is None:
        s = r = 0
        for line in sh(['netstat', '-ib'], timeout=6).splitlines()[1:]:
            p = line.split()
            if len(p) < 10 or p[0].startswith('lo'):
                continue
            try:
                r += int(p[6])     # Ibytes
                s += int(p[9])     # Obytes
            except (ValueError, IndexError):
                continue
        sent, recv = s, r

    now = time.time()
    dt = now - _NET_TICK['t'] if _NET_TICK['t'] else 0
    if dt > 0:
        up = max(0, sent - _NET_TICK['sent']) / dt / 1024.0
        down = max(0, recv - _NET_TICK['recv']) / dt / 1024.0
    else:
        up = down = 0.0
    _NET_TICK.update({'t': now, 'sent': sent, 'recv': recv})
    return {'up_kbs': round(up, 1), 'down_kbs': round(down, 1),
            'total_sent': sent, 'total_recv': recv}


def battery():
    out = sh(['ioreg', '-r', '-c', 'AppleSmartBattery', '-w0'], timeout=8)
    d = {}
    for k, v in re.findall(r'"(\w+)" = (-?\d+)', out):
        d[k] = int(v)
    pct_raw = sh(['pmset', '-g', 'batt'])
    pct = None
    m = re.search(r'(\d+)%', pct_raw)
    if m:
        pct = int(m.group(1))
    state = '未知'
    for kw, lab in (('charging', '充电中'), ('discharging', '放电中'),
                    ('charged', '已充满'), ('AC Power', '接通电源')):
        if kw.lower() in pct_raw.lower():
            state = lab
            break

    temp = d.get('Temperature')
    return {
        'percent': pct,
        'state': state,
        'raw_text': pct_raw.strip(),
        'voltage_mv': d.get('Voltage'),
        'amperage_ma': d.get('Amperage'),
        'temperature_c': round(temp / 100, 1) if temp else None,
        'cycle_count': d.get('CycleCount'),
        'design_capacity': d.get('DesignCapacity'),
        'max_capacity': d.get('MaxCapacity'),
        'current_capacity': d.get('CurrentCapacity'),
        'health_percent': (round(d['MaxCapacity'] / d['DesignCapacity'] * 100, 1)
                           if d.get('DesignCapacity') and d.get('MaxCapacity') else None),
        'external_connected': bool(d.get('ExternalConnected')),
    }


def disks():
    out = sh(['df', '-k'])
    res = []
    seen = set()
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9 or not parts[0].startswith('/dev/'):
            continue
        fs, total, used, avail, pct, mount = (parts[0], parts[1], parts[2],
                                              parts[3], parts[4],
                                              ' '.join(parts[8:]))
        if mount.startswith('/System/Volumes/') or mount in seen:
            continue
        seen.add(mount)
        try:
            total_i, used_i, avail_i = int(total), int(used), int(avail)
        except ValueError:
            continue
        if total_i < 100 * 1024:
            continue
        res.append({
            'device': fs, 'mount': mount,
            'total': total_i * 1024, 'used': used_i * 1024,
            'avail': avail_i * 1024,
            'percent': int(pct.rstrip('%')) if pct.rstrip('%').isdigit() else 0,
        })
    res.sort(key=lambda x: -x['total'])
    return res


def processes(limit=8):
    """占用最高的进程。ps 优先，top 回退，两者都不可用则返回空列表。"""
    out = sh(['ps', '-Ao', 'pcpu,pmem,comm', '-r'], timeout=8)
    rows = []
    for line in out.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            cpu = float(parts[0])
            mem = float(parts[1])
        except ValueError:
            continue
        rows.append({'cpu': cpu, 'mem': mem,
                     'name': os.path.basename(parts[2].strip())})
        if len(rows) >= limit:
            break
    if rows:
        return rows

    # 回退方案: top
    out = sh(['top', '-l', '1', '-n', str(limit * 2),
              '-stats', 'pid,command,cpu,mem'], timeout=15)
    started = False
    for line in out.splitlines():
        if line.startswith('PID'):
            started = True
            continue
        if not started:
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            cpu = float(parts[2])
        except ValueError:
            continue
        mem = parts[3]
        mb = 0.0
        try:
            if mem.endswith('M'):
                mb = float(mem[:-1])
            elif mem.endswith('G'):
                mb = float(mem[:-1]) * 1024
            elif mem.endswith('K'):
                mb = float(mem[:-1]) / 1024
        except ValueError:
            pass
        rows.append({'cpu': cpu, 'mem': round(mb / 1024 * 100, 1) if mb else 0,
                     'name': os.path.basename(parts[1])})
        if len(rows) >= limit:
            break
    return rows


def hid_devices():
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            'hidmod', os.path.join(HERE, 'hid.py'))
        hidmod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hidmod)
        out = []
        for d in hidmod.find_devices():
            out.append({
                'vendor_id': f'{d.vendor_id:#06x}' if d.vendor_id is not None else None,
                'product_id': f'{d.product_id:#06x}' if d.product_id is not None else None,
                'product': d.product,
                'manufacturer': d.manufacturer,
                'usage_page': f'{d.usage_page:#06x}' if d.usage_page is not None else None,
                'usage': d.usage,
                'feature_size': d.max_feature_report_size,
                'output_size': d.max_output_report_size,
                'input_size': d.max_input_report_size,
            })
        return out
    except Exception as e:
        return [{'error': str(e)}]


def rgb_state():
    prof = rgbkb.load_profile()
    g = rgbkb.load_gains()
    e = rgbkb.load_endpoint()
    gains = {'R': g[0], 'G': g[1], 'B': g[2],
             'factors': [round(x / 1000.0, 3) for x in g],
             # 滑条端点（100% 处的增益）与当前滑条位置，供界面无跳变往返
             'end': {'R': e[0], 'G': e[1], 'B': e[2]},
             'end_factors': [round(x / 1000.0, 3) for x in e],
             'slider': rgbkb.gains_to_slider(g),
             # 满白经校准后实际下发的 RGB（便于直观看出被压了多少）
             'white_rgb': list(rgbkb.apply_gains((255, 255, 255)))}
    if not rgbkb.KeyboardRGB.available():
        return {'available': False, 'profile': prof, 'white_gain': gains}
    try:
        with rgbkb.KeyboardRGB() as kb:
            return {'available': True, 'info': kb.info(),
                    'state': kb.get_state(), 'firmware': kb.get_firmware(),
                    'profile': prof, 'profile_path': rgbkb.PROFILE_PATH,
                    'white_gain': gains}
    except Exception as e:
        return {'available': False, 'error': str(e), 'profile': prof,
                'white_gain': gains}


# --------------------------------------------------------------------------
# 能力矩阵：这台机器在 macOS 上到底能做什么
# --------------------------------------------------------------------------

def capability():
    """能力矩阵 —— 全部基于本机实测，而不是「照着 Linux 驱动猜」。
    每次展示时重新探测 EC，所以开关之间的变化会立刻反映出来。"""
    fn = smc.snapshot()
    fan_kext = fanctl.kext_loaded()

    usable = [
        {'name': 'CPU 各核心温度', 'detail': 'SMC TC1C~TC6C，6 个物理核心独立读数'},
        {'name': 'CPU 封装温度', 'detail': 'SMC TC0P / TC0D / TC0E / TC0F / TC0H'},
        {'name': 'CPU 电流与功耗', 'detail': 'SMC PC0C / PCPC / PCPT / PCTR (sp96 定点)'},
        {'name': '内存 / 负载 / 运行时间', 'detail': 'sysctl + vm_stat'},
        {'name': '显卡信息', 'detail': 'system_profiler，核显 + RTX 2070S 均可见'},
        {'name': '电池', 'detail': 'ioreg AppleSmartBattery + pmset'},
        {'name': '磁盘占用', 'detail': 'df，含 Word / Windows 分区'},
        {'name': '键盘灯控制', 'detail': 'ITE 8291 (048d:ce00) HID Feature 报告，已实测可写'},
        {'name': '屏幕亮度', 'detail': 'IOKit IODisplaySetFloatParameter 改系统亮度，'
                                      '面板 PWM 模式下由 macOS 原生链路驱动屏幕'
                                      '（auxbright 守护保持模式），系统滑条与控制台滑条同一真相源'},
    ]
    partial = [
        {'name': '电池健康度', 'detail': 'VirtualSMC 对电池建模较粗：循环次数恒为 0、'
                                        '设计容量 = 最大容量，容量读数可信度有限'},
    ]

    if fan_kext:
        usable.append({
            'name': '散热模式控制',
            'detail': 'kext → WMI ABBC0F6F → EC 邮箱(LDAT/HDAT/CMDL/CMDH)；'
                      '自动 / 基准·拉满(78%，约 5500 RPM) / 手动 L0-7(24%~53%)；'
                      '写入前先开 CTRL_1 手动门 —— 与 Windows Control Center 同路'})

        usable.append({
            'name': '风扇转速与温度读数',
            'detail': '绕开 SMC，直接读 EC 0x046C(CPU) / 0x0464(GPU)（大端，实测 '
                      + _ec_live_rpm_text() + '），温度 0x043E(CPU) / 0x044F(独显)。'
                      '实测两路 PWM 数值始终相同（12 进程满载全程 80→177 一致），'
                      'EC 给两颗风扇的是同一个占空比；转速差约 12% 来自风扇个体/型号差异，'
                      '不是接反。两颗风扇的归属由用户实物确认：他亲手换过 CPU 风扇，'
                      '转速较高的 0x046C 才是 CPU 风扇（2026-10-16 修正，之前标反）。'
                      '同期 0x043E 从 64℃ 升到 89℃ 而 0x044F 仅 60→62℃，'
                      '确认后者不在 CPU 那一路'})
        try:
            prob = _fan().ec_probe()
        except Exception:
            prob = {}
        usable.append({
            'name': '性能模式（专业 / 平衡 / 省电）',
            'detail': '写 EC 0x07AB（MyFanCCI_Mode_Index）= 0x11/0x22/0x33，'
                      '就是 BIOS「Power Mode」和键盘上那颗模式按钮的同一个开关，'
                      '键盘灯实时跟随（专业=2 灯、平衡=1 灯、省电=不亮）。'
                      '12 子进程满载实测：专业档 CPU 算力最快、风扇随温度爬升 29→44%；'
                      '平衡档风扇最猛（78℃ 就 41~47%）、算力慢 4~5%；'
                      '省电档风扇压在 31% 不动、算力慢 5~9%（A/B/C/A 交叉复现）。'
                      '注意正确入口是 0x07AB，不是 CTRL_3 (0x07A5) 直写——'
                      '后者 bit2 被 EC 掩码，且模式索引有效时写入会被秒级覆盖。'
                      '当前档位：'
                      + '0x%02X（%s）' % (prob.get('modeindex', 0),
                         {0x11: '专业', 0x22: '平衡', 0x33: '省电'}.get(
                             prob.get('modeindex', 0), '未知'))})
        usable.append({
            'name': '电池充电阈值',
            'detail': 'EC 0x07B9，bit0-6 = 百分比，实测可写（设 80 → 回读 0xD0，'
                      'bit7 reached 置位后停止充电）；当前阈值 '
                      + str(prob.get('charge', 0)) + '%'})
        if prob.get('support_lightbar', False):
            usable.append({
                'name': '海岸灯（Lightbar / 灯条）',
                'detail': 'EC 0x0748 控制字节 + 0x0749-0x074B RGB，实测可写、回读一致。'
                          '已肉眼验证三种状态：ctrl=0x80 多彩轮换动画（机器出厂行为）、'
                          'ctrl=0x00 停在固定色（显示 RGB 寄存器里存的颜色）、ctrl=0x84 关灯——'
                          '即 bit7 是「轮换/动画」位（不是开关位），bit2 才是关灯位。'
                          'bit4/5 被 EC 掩码写不进去；bit0/1/3/6 语义未知'
                          '（OEM 侧还有 WelcomeMode、BreathingLightEffect 未对应）。'
                          'OEM 的 DefaultRGBLightbar.exe 同走这组寄存器；HID 侧 MyLightBar 设备'
                          '本机不存在，EC 是唯一通路'})
    else:
        partial.append({
            'name': '散热 / 性能模式 / 风扇转速 / 充电阈值 / 海岸灯',
            'detail': '方案已备好（TongfangFan.kext），首次运行 app 会自动安装：散热模式（自动/基准/手动）、性能模式（专业/平衡/省电）、'
                      '风扇转速与温度读数、电池充电阈值、海岸灯'})

    return {
        'usable': usable,
        'partial': partial,
        'unavailable': [
            {'name': '硬盘 / NVMe 温度', 'detail': '所有来源都查过：SMC 只枚举出 TC* 一串 '
                                                'CPU 温度键（无 TH*/Tm*）；ioreg 里 '
                                                'IONVMeController 与 IOBlockStorageDevice '
                                                '都不上报温度（全系统唯一的 Temperature 键是电池的）；'
                                                'EC 页 0x04 整页扫描也没有像硬盘热敏的寄存器。'
                                                '常规做法要靠 smartctl（smartmontools），'
                                                '本机未安装且无 brew，且 macOS 读 NVMe SMART 需管理员权限'},
            {'name': 'GPU 占用率与功耗', 'detail': 'macOS 没有开放 GPU 利用率的用户态接口。'
                                              '独显 RTX 2070S 在 macOS 下只有一个 PCIe 设备条目'
                                              '（官方驱动早已停更、始终空载），核显 UHD 630 也不上报。'
                                              '核显与 CPU 同封装、本机没有它的独立热敏'
                                              '（SMC 无 TG* 键），界面上核显那一格是 CPU 封装温度的参考值'},
            {'name': '自定义风扇曲线（BIOS Fan Control Mode）', 'detail': 'BIOS 里「Fan Control Mode」'
                                              '（Fixed/Custom/Cool/Balanced/Quiet/Fanless，'
                                              'NVRAM 0x12F4）才是真正的风扇设置，但运行时换不了：'
                                              'OEM 地址表（keyboard.dll 774 个常量）里没有对应寄存器；'
                                              'MYFAN2 曲线单元格 0x0743-47 写得进、回读一致，却完全无效'
                                              '（改成温度断点或占空比值，风扇都毫无反应，'
                                              '与 PL 设置一样是 EC 独占的死单元格）；'
                                              'CTRL_3 (0x07A5) 低三位在模式索引有效时被 EC 秒级覆盖，'
                                              '清空索引后能写住但负载下测不出差异。'
                                              '结论：它是 POST 时按 NVRAM 一次性选好的内部曲线，'
                                              '之后 EC 自己调度。可试路径：BIOS 里设为 Custom 再重启，'
                                              'EC 可能就会启用曲线单元格（待验证）'},
        ],
        'smc': {
            'available': fn['available'],
            'key_count': fn['key_count'],
            'fan_note': fn['fan_note'],
        },
    }


def _ec_live_rpm_text():
    """给能力矩阵用的实时转速文案（读不到就给占位）"""
    try:
        s = _fan().fan_status()
        return 'CPU %d RPM / GPU %d RPM' % (s['rpm_cpu'], s['rpm_gpu'])
    except Exception:
        return 'CPU ~3000 RPM / GPU ~3500 RPM'


# --------------------------------------------------------------------------
# 控制动作
# --------------------------------------------------------------------------

CAFFEINATE_PID = os.path.join(
    os.path.expanduser('~/Library/Application Support/MacConsole'),
    '.caffeinate.pid')
os.makedirs(os.path.dirname(CAFFEINATE_PID), exist_ok=True)


# auxbright v4: 面板背光模式保持器（PWM 模式 + macOS 原生链路方案）。
# 本机面板 (BOE NV156FHM-N4J) 默认处于 eDP AUX 背光模式，根本不看 iGPU 的
# PWM 引脚；而 macOS 亮度链路只写 PWM 占空比寄存器——这就是旧方案里
# 「系统亮度改了屏幕不动」的根因。把面板切到 PWM 模式 (DPCD 0x721=0x08) 后，
# 原生链路全面接管：IOKit 系统亮度 -> macOS 写 PWM duty -> 面板跟随。
# auxbright watch 守护只负责保持面板在 PWM 模式（睡眠唤醒后每秒校验改回）。
# 旧的 auxsmooth.py 轮询+渐变+DPCD 0x723 写入方案已废弃（PWM 模式下
# DPCD 写入被面板忽略），auxsmooth.py 现在是兼容层 CLI。
AUXBRIGHT_CANDIDATES = [
    os.path.expanduser('~/bin/auxbright'),
    '/usr/local/bin/auxbright',
    '/opt/homebrew/bin/auxbright',
    os.path.expanduser('~/Desktop/work/auxbright/auxbright'),
]


def find_auxbright():
    """找 auxbright v4（面板背光模式保持器）。用于模式查询/切换，不再用于亮度读写。"""
    for p in AUXBRIGHT_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    env_path = os.environ.get('AUXBRIGHT_PATH')
    if env_path and os.access(env_path, os.X_OK):
        return env_path
    here_bin = os.path.join(HERE, 'bin', 'auxbright')
    if os.path.isfile(here_bin) and os.access(here_bin, os.X_OK):
        return here_bin
    return shutil.which('auxbright') or None



# ---- PWMWAKE_V5 ----
PWMWAKE_CANDIDATES = [
    os.path.expanduser('~/bin/pwmwake'),
    '/usr/local/bin/pwmwake',
    os.path.join(HERE, 'bin', 'pwmwake'),
]


def find_pwmwake():
    """找 pwmwake（v5 事件驱动守护，提供一次性 ensure 入口）"""
    for p in PWMWAKE_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which('pwmwake') or None


_LAST_PWM_ENSURE = [0.0]


def ensure_pwm_mode(min_interval=1.5):
    """写系统亮度前兜底：把面板切回 PWM 模式。1.5 秒内不重复写 DPCD。"""
    import time as _t
    now = _t.time()
    if now - _LAST_PWM_ENSURE[0] < min_interval:
        return None
    _LAST_PWM_ENSURE[0] = now
    tool = find_pwmwake()
    if tool:
        try:
            sh([tool, 'ensure'], timeout=6)
            return 'pwmwake'
        except Exception:
            pass
    tool = find_auxbright()
    if tool:
        try:
            sh([tool, 'pwm'], timeout=6)
            return 'auxbright'
        except Exception:
            pass
    return None
# ---- /PWMWAKE_V5 ----


def panel_bl_mode():
    """读面板背光模式；成功返回 'PWM'/'AUX(DPCD)' 等，失败返回 None"""
    tool = find_auxbright()
    if not tool:
        return None
    try:
        out = sh([tool, 'mode'], timeout=6).strip()
        for line in out.splitlines():
            if '0x721' in line:
                return line.split('(')[-1].rstrip(')') if '(' in line else line
        return out or None
    except Exception:
        return None


def caffeinate_running():
    """caffeinate 守护是否在跑：PID 文件存在且进程活着"""
    if not os.path.exists(CAFFEINATE_PID):
        return False
    try:
        pid = int(open(CAFFEINATE_PID).read().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def do_control(action, params):
    if action == 'volume_get':
        # 读系统真实音量与静音状态（AppleScript 的 get volume settings）
        out = sh(['osascript', '-e',
                  'set v to output volume of (get volume settings)',
                  '-e', 'set m to output muted of (get volume settings)',
                  '-e', 'return (v as string) & " " & (m as string)']).strip()
        parts = out.split()
        if len(parts) >= 2:
            try:
                return {'ok': True, 'volume': int(parts[0]),
                        'muted': parts[1].lower() == 'true'}
            except ValueError:
                pass
        return {'ok': False, 'error': '读取失败：' + (out or 'osascript 无输出')}

    if action == 'volume':
        v = int(params.get('value', 50))
        sh(['osascript', '-e', f'set volume output volume {max(0, min(100, v))}'])
        return {'ok': True, 'volume': v}

    if action == 'mute':
        sh(['osascript', '-e', 'set volume output muted true'])
        return {'ok': True, 'muted': True}

    if action == 'unmute':
        sh(['osascript', '-e', 'set volume output muted false'])
        return {'ok': True, 'muted': False}

    if action == 'brightness_get':
        # 新方案（2026-10-17）：面板在 PWM 模式下由 macOS 原生链路驱动，
        # 「系统亮度」就是真相源——F1/F2、控制中心滑条、控制台写的都是它，
        # 原生链路负责送到屏幕。旧的「读 DPCD 0x723 硬件真值」在 PWM 模式下
        # 已失效（该寄存器被面板忽略），故改为读系统亮度。
        b = bright.get_brightness()
        mode = panel_bl_mode()
        if mode:
            b['panel_mode'] = mode
        b['via'] = 'iokit'
        return b

    if action == 'brightness':
        v = int(params.get('value', 50))
        v = max(0, min(100, v))
        # 单真相源架构（v3 / 2026-10-17 起为「PWM 模式 + 原生链路」版）：
        #   1) IOKit 公开接口改「系统亮度」——F1/F2、控制中心滑条写的也是这里；
        #   2) 面板在 PWM 模式下，macOS 原生把系统亮度写进 iGPU PWM 占空比
        #      寄存器驱动屏幕（自带原生渐变，无需任何软件渐变层）；
        #   3) auxbright watch 守护保持面板在 PWM 模式（睡眠唤醒后校验改回）。
        # 守护没在跑时先补一次模式切换，保证本次写入能到达屏幕。
        applied = ensure_pwm_mode()   # PWMWAKE_V5: 写系统亮度前先把面板切回 PWM
        res = bright.set_brightness(v)
        if res.get('ok') and applied:
            res['via'] = res.get('via', 'iokit') + '+' + applied + '-ensure'
        elif res.get('ok') and not _brightness_daemon_alive():
            tool = find_pwmwake() or find_auxbright()
            if tool:
                try:
                    sh([tool, 'ensure' if tool.endswith('pwmwake') else 'pwm'], timeout=6)
                except Exception:
                    pass
                res['via'] = res.get('via', 'iokit') + '+ensure-retry'
        mode = panel_bl_mode()
        if mode:
            res['panel_mode'] = mode
        return res

    if action == 'caffeinate':
        # 不带 on 参数 = 查询当前状态（供界面高亮；按钮高亮必须反映真实运行状态，
        # 不能反映"上次点了什么"——用户红线）
        if 'on' not in params:
            return {'ok': True, 'on': caffeinate_running()}
        on = bool(params.get('on'))
        if on:
            if os.path.exists(CAFFEINATE_PID):
                return {'ok': True, 'on': True, 'note': '已在运行'}
            p = subprocess.Popen(['caffeinate', '-d', '-i', '-s'],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            with open(CAFFEINATE_PID, 'w') as f:
                f.write(str(p.pid))
            return {'ok': True, 'on': True, 'pid': p.pid}
        else:
            if os.path.exists(CAFFEINATE_PID):
                try:
                    pid = int(open(CAFFEINATE_PID).read().strip())
                    os.kill(pid, 15)
                except Exception:
                    pass
                os.remove(CAFFEINATE_PID)
            return {'ok': True, 'on': False}

    if action == 'rgb':
        return do_rgb(params)

    return {'ok': False, 'error': f'未知动作: {action}'}


def do_rgb(params):
    if not rgbkb.KeyboardRGB.available():
        return {'ok': False, 'error': '未检测到 ITE 8291 键盘灯设备'}
    mode = params.get('mode', 'color')
    result = {'ok': False, 'error': f'未知 RGB 模式: {mode}'}
    try:
        with rgbkb.KeyboardRGB() as kb:
            if mode == 'off':
                kr = kb.disable()
                result = {'ok': kr == 0, 'kr': kr, 'mode': 'off'}
            elif mode == 'brightness':
                kr = kb.set_brightness(int(params.get('level', 3)))
                result = {'ok': kr == 0, 'kr': kr, 'mode': 'brightness'}
            elif mode == 'effect':
                # 自带 hex 就走「命名色 0x14 + 槽位」，让灯效跑在自定义颜色上
                eff_rgb = None
                if params.get('hex'):
                    try:
                        hx = str(params['hex']).lstrip('#')
                        eff_rgb = [int(hx[i:i + 2], 16) for i in (0, 2, 4)]
                    except Exception:
                        eff_rgb = None
                kr = kb.set_style(params.get('style', 'rainbow'),
                                  brightness=int(params.get('brightness', 3)),
                                  speed=int(params.get('speed', 5)),
                                  save=int(params.get('save', 1)),
                                  rgb=eff_rgb,
                                  slot=int(params.get('slot', 1)))
                result = {'ok': kr == 0, 'kr': kr, 'mode': 'effect',
                          'style': params.get('style'),
                          'hex': (params.get('hex') if eff_rgb else None)}
            elif mode == 'color':
                hx = str(params.get('hex', '#00a0ff')).lstrip('#')
                r, g, b = (int(hx[i:i + 2], 16) for i in (0, 2, 4))
                kr = kb.set_color(r, g, b,
                                  brightness=int(params.get('brightness', 4)),
                                  save=int(params.get('save', 1)))
                result = {'ok': kr == 0, 'kr': kr, 'mode': 'color', 'hex': hx}
            elif mode == 'zones':
                zones = [(int(z[0]), int(z[1]), int(z[2]))
                         for z in params.get('zones', [])]
                if not zones:
                    return {'ok': False, 'error': 'zones 为空'}
                kb.user_mode(save=1,
                             brightness=int(params.get('brightness', 4)))
                time.sleep(0.05)
                kr = kb.set_zone_colors(zones, repeat=1, save=1)
                result = {'ok': kr == 0, 'kr': kr, 'mode': 'zones'}
    except Exception as e:
        return {'ok': False, 'error': str(e)}

    # 成功后自动记住，供开机恢复
    if result.get('ok') and params.get('remember', True):
        prof = rgbkb.profile_from_params(params)
        result['remembered'] = rgbkb.save_profile(prof)
        result['profile'] = prof
    return result


# --------------------------------------------------------------------------
# 散热模式（TongfangFan.kext → WMI ABBC0F6F → EC 0x751）
# --------------------------------------------------------------------------

_FAN = None


def _fan():
    global _FAN
    if _FAN is None:
        _FAN = fanctl.FanControl()
    return _FAN


def lightbar_state():
    """海岸灯（Lightbar）状态：以 EC 回读为准，不读任何缓存。"""
    if not fanctl.kext_loaded():
        return {'available': False,
                'note': 'TongfangFan.kext 未加载，EC 不可达'}
    try:
        st = _fan().lightbar_status()
    except Exception as e:
        return {'available': False, 'error': str(e)}
    if not st:
        return {'available': False, 'note': 'EC 读失败'}
    return {'available': True, **st}


def do_lightbar(params):
    """设置海岸灯：控制字节 ctrl + hex 颜色。返回 EC 回读的真实状态。

    ctrl 既接受 'cycle'(0x80 多彩轮换) / 'static'(0x00 固定色) 两个已验证取值，
    也接受 0-255 的裸值，用于探测 bit0-3 / bit6 这些语义未明的位。
    """
    if not fanctl.kext_loaded():
        return {'ok': False, 'error': 'TongfangFan.kext 未加载'}
    hx = str(params.get('hex', '')).lstrip('#')
    if not re.fullmatch(r'[0-9a-fA-F]{6}', hx):
        return {'ok': False, 'error': 'hex 颜色无效'}
    rgb = (int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16))

    c = params.get('ctrl', params.get('mode', 'cycle'))
    if c == 'cycle':
        ctrl = fanctl.LIGHTBAR_CYCLE
    elif c == 'static':
        ctrl = fanctl.LIGHTBAR_STATIC
    elif c == 'off':
        ctrl = fanctl.LIGHTBAR_OFF
    else:
        try:
            ctrl = int(c)
        except (TypeError, ValueError):
            return {'ok': False, 'error': 'ctrl 取值无效'}
        if not 0 <= ctrl <= 0xFF:
            return {'ok': False, 'error': 'ctrl 超出 0-255'}

    try:
        st = _fan().lightbar_set(rgb, ctrl)
    except Exception as e:
        return {'ok': False, 'error': str(e)}
    if not st:
        return {'ok': False, 'error': '写入后回读失败'}
    # 'available' 必须与 lightbar_state() 的形状一致 —— 前端靠它判断可否渲染控件
    return {'ok': True, 'available': True, **st}


def fan_state():
    """散热模式状态 + 实时转速/温度/占空比（供界面展示）"""
    loaded = fanctl.kext_loaded()
    st = fanctl.load_state() or {'mode': 'normal', 'level': 0}
    out = {'available': loaded, 'mode': st['mode'], 'level': st['level']}
    if loaded:
        try:
            live = _fan().fan_status()
            out['live'] = live
            # 界面以 EC 里的真实状态为准，保存的设置只用于「重启后自动恢复」
            out['actual'] = live.get('actual', st['mode'])
            out['actual_level'] = live.get('actual_level', st['level'])
            # 性能模式（EC 0x07AB 模式索引）：0x11=专业 0x22=平衡 0x33=省电
            out['modeindex'] = live.get('modeindex')
            out['synced'] = (out['actual'] == st['mode'] and
                             (out['actual'] != 'custom' or
                              out['actual_level'] == st['level']))
            try:
                out['charge'] = _fan().charge_threshold()
            except Exception:
                pass
        except Exception as e:
            out['live_error'] = str(e)
    else:
        out['hint'] = ('TongfangFan.kext 未加载 —— 点控制页的「自动安装」'
                       '或双击随附的「安装散热控制.command」（需管理员密码）')
    return out


def do_fan(params):
    """散热控制。支持:
        mode   : normal(自动) / boost(基准·最大)
        level  : 0-7 手动档位（24%→53% 占空比）
        profile: quiet / balance / perf —— 走旧的 CTRL_3 直写路径，
                 ⚠️ 该路径 2026-10-15 已实测走不通（bit2 被 EC 掩码、bit4 无后果），
                 保留仅供对照；真正生效的性能模式请用 modeindex
        modeindex: 0x11=专业/性能(Gaming) 0x22=平衡(Office) 0x33=省电(BatterySaver)
                 —— 性能模式的正确入口（2026-10-16 实测有效，见 set_mode_index）
    """
    if not fanctl.kext_loaded():
        return {'ok': False, 'error': 'TongfangFan.kext 未加载',
                'hint': '点控制页「自动安装」或双击「安装散热控制.command」后重试'}
    try:
        mode = str(params.get('mode', ''))
        if 'profile' in params:
            prof = str(params.get('profile'))
            if prof not in ('quiet', 'balance', 'perf'):
                return {'ok': False, 'error': 'profile 必须是 quiet/balance/perf'}
            r = _fan().set_profile(prof)
            return {'ok': bool(r and r.get('status') == 0), 'reply': r,
                    'profile': prof}

        if 'modeindex' in params:
            code = int(params.get('modeindex'))
            if code not in (0x11, 0x22, 0x33):
                return {'ok': False,
                        'error': 'modeindex 必须是 0x11(专业)/0x22(平衡)/0x33(省电)'}
            r = _fan().set_mode_index(code)
            cur = _fan().ec_read(fanctl.EC_FAN_MODE_INDEX)
            return {'ok': bool(r and r.get('status') == 0), 'reply': r,
                    'modeindex': (cur or {}).get('result', 0) & 0xFF,
                    'ctrl3': (_fan().ec_read(fanctl.EC_CTRL_3) or {}).get('result', 0) & 0xFF,
                    'fan_ctrl': (_fan().ec_read(fanctl.EC_FAN_CTRL) or {}).get('result', 0) & 0xFF}

        if 'charge' in params:
            pct = int(params.get('charge'))
            if not 0 <= pct <= 100:
                return {'ok': False, 'error': '充电阈值必须在 0-100'}
            r = _fan().set_charge_threshold(pct)
            return {'ok': bool(r and r.get('status') == 0), 'reply': r,
                    'charge': pct}

        if mode in ('normal', 'boost'):
            r = _fan().set_mode(mode)
            level = int(params.get('level', 0) or 0)
        elif 'level' in params or mode == 'custom':
            mode = 'custom'
            level = int(params.get('level', 0))
            if not 0 <= level <= 7:
                return {'ok': False, 'error': 'level 必须在 0-7'}
            r = _fan().set_level(level)
        else:
            return {'ok': False, 'error': '缺少 mode / level / profile'}
        ok = bool(r and r.get('status') == 0)
        if ok:
            fanctl.save_state(mode, level)
        return {'ok': ok, 'reply': r, 'mode': mode, 'level': level}
    except Exception as e:
        return {'ok': False, 'error': str(e)}


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

MIME = {'.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
        '.js': 'application/javascript; charset=utf-8',
        '.png': 'image/png', '.jpg': 'image/jpeg', '.ico': 'image/x-icon',
        '.json': 'application/json; charset=utf-8',
        '.svg': 'image/svg+xml'}


class Handler(BaseHTTPRequestHandler):
    server_version = 'MacConsole/1.0'

    def log_message(self, fmt, *args):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path):
        if not os.path.isfile(path):
            self.send_error(404)
            return
        ext = os.path.splitext(path)[1].lower()
        with open(path, 'rb') as f:
            body = f.read()
        self.send_response(200)
        self.send_header('Content-Type', MIME.get(ext, 'application/octet-stream'))
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = urlparse(self.path).path

        if p in ('/', '/index.html'):
            return self._file(os.path.join(WEB, 'index.html'))

        if p.startswith('/assets/') or p.startswith('/static/'):
            rel = p.split('/', 2)[-1] if p.count('/') >= 2 else ''
            safe = os.path.normpath(rel).lstrip('./')
            return self._file(os.path.join(WEB, 'assets', safe))

        try:
            if p == '/api/overview':
                return self._json(overview())
            if p == '/api/sensors':
                return self._json(smc.snapshot())
            if p == '/api/battery':
                return self._json(battery())
            if p == '/api/disks':
                return self._json(disks())
            if p == '/api/processes':
                return self._json(processes())
            if p == '/api/hid':
                return self._json(hid_devices())
            if p == '/api/rgb':
                return self._json(rgb_state())
            if p == '/api/fan':
                return self._json(fan_state())
            if p == '/api/lightbar':
                return self._json(lightbar_state())
            if p == '/api/capability':
                return self._json(capability())
            if p == '/api/all':
                t0 = time.time()
                payload = {
                    'overview': overview(),
                    'sensors': smc.snapshot(),
                    'battery': battery(),
                    'disks': disks(),
                    'processes': processes(),
                }
                payload['elapsed_ms'] = int((time.time() - t0) * 1000)
                return self._json(payload)
        except Exception as e:
            return self._json({'error': str(e)}, 500)

        self.send_error(404)

    def do_POST(self):
        p = urlparse(self.path).path
        try:
            n = int(self.headers.get('Content-Length') or 0)
            params = json.loads(self.rfile.read(n) or b'{}') if n else {}
        except Exception:
            params = {}

        if p == '/api/control':
            return self._json(do_control(params.get('action', ''), params))
        if p == '/api/fan':
            return self._json(do_fan(params))
        if p == '/api/lightbar':
            return self._json(do_lightbar(params))
        if p == '/api/rgb':
            return self._json(do_rgb(params))
        if p == '/api/rgb/apply':
            # 手动恢复上次保存的灯效
            return self._json(rgbkb.apply_profile())
        if p == '/api/rgb/forget':
            # 清除保存的灯效
            return self._json({'ok': rgbkb.clear_profile()})
        if p == '/api/rgb/save':
            # 直接把当前 profile 覆盖保存（用于界面手动记忆）
            prof = params.get('profile')
            if not isinstance(prof, dict) or not prof:
                return self._json({'ok': False, 'error': 'profile 无效'})
            return self._json({'ok': rgbkb.save_profile(prof), 'profile': prof})
        if p == '/api/rgb/whitecal':
            # 由「肉眼看到的偏色」反算三通道增益（与 BetterRGB 同款算法）
            observed = str(params.get('observed', '')).lstrip('#')
            res = rgbkb.calc_white_gains(observed)
            if not res:
                return self._json({'ok': False, 'error': 'observed 颜色无效'})
            rgbkb.save_gains(res['R'], res['G'], res['B'], observed)
            # 这次标定即成为滑条端点（对应 t=100），之后滑条可无损往外拖
            rgbkb.save_endpoint(res['R'], res['G'], res['B'])
            re = rgbkb.apply_profile()
            return self._json({'ok': True, 'white_gain': res,
                               'slider': 100,
                               'reapplied': re.get('ok')})
        if p == '/api/rgb/whitegain':
            # 两种用法：直接给 R/G/B 增益，或给滑条位置 t（按端点插值）
            if 't' in params:
                g = rgbkb.save_gains(*rgbkb.slider_to_gains(params.get('t', 0)))
            else:
                g = rgbkb.save_gains(params.get('R', 1000),
                                     params.get('G', 1000),
                                     params.get('B', 1000))
            re = rgbkb.apply_profile()
            return self._json({'ok': True,
                               'white_gain': {'R': g[0], 'G': g[1], 'B': g[2]},
                               'slider': rgbkb.gains_to_slider(g),
                               'reapplied': re.get('ok')})
        if p == '/api/rgb/whitegain/reset':
            rgbkb.clear_gains()
            rgbkb.clear_endpoint()
            re = rgbkb.apply_profile()
            return self._json({'ok': True, 'slider': 0,
                               'reapplied': re.get('ok')})
        self.send_error(404)


def _brightness_daemon_alive():
    """pwmwake v5（事件驱动）或 auxbright watch v4 守护是否在跑。

    模式必须锚定：pgrep -f 'pwmwake' 会误中任何命令行里带 "pwmwake" 字样的进程
    （终端里 tail 守护日志、自动化脚本调用串等），害得真没人跑时也不去拉守护。
    守护进程的 cmdline 就是「…/pwmwake」且无参数，用 r'(^|/)pwmwake$' 精确匹配。
    """
    try:
        # PWMWAKE_V5: v5 事件驱动守护（pwmwake）或旧 v4 守护（auxbright watch）
        for pat in (r'(^|/)pwmwake$', 'auxbright watch'):
            try:
                r = subprocess.run(['pgrep', '-f', pat], capture_output=True)
                if r.returncode == 0 and r.stdout.strip():
                    return True
            except Exception:
                pass
        return False
    except Exception:
        return False


def ensure_brightness_daemon():
    """确保 auxbright watch 守护在跑：保持面板 PWM 模式，亮度交给 macOS 原生链路。

    这是「系统亮度滑条持续有效」的关键：面板睡眠唤醒后可能复位回 AUX 模式
    （此时原生亮度写的是 PWM 寄存器，面板不听），需要守护每秒校验并切回。
    守护脱离控制台独立存活（控制台关掉后系统滑条照样好用），重复启动有
    pgrep 护栏。旧版（auxsmooth.py 轮询渐变）已废弃。
    """
    try:
        # 优先 pwmwake v5.x（事件驱动、镜像/假负载模式无盲区）——无参数即守护模式，
        # 与 LaunchAgent com.user.pwmwake 的启动方式一致，日志落到同一个
        # ~/Library/Logs/pwmwake.out.log；找不到 pwmwake 才回退 auxbright v4 watch。
        # 背景：LaunchAgent 的 program 路径改过布局（python/bin→native/bin），launchd
        # 内存里的旧任务不会自动重读，守护一旦死了就再也起不来——这层兜底专门补这个洞。
        pwmwake = None
        for cand in (os.path.join(HERE, 'bin', 'pwmwake'),
                     os.path.expanduser('~/bin/pwmwake'),
                     '/usr/local/bin/pwmwake'):
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                pwmwake = cand
                break
        if pwmwake:
            if _brightness_daemon_alive():
                print('亮度守护已在运行')
                return
            log = open(os.path.expanduser('~/Library/Logs/pwmwake.out.log'), 'a')
            subprocess.Popen([pwmwake], stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
            # pwmwake 就位后再清 v4 残留（顺序反了会有「都没守护」的空窗）：
            # 老版本拉起的 auxbright watch 会长期存活（甚至从已进废纸篓的旧 bundle 里跑），
            # 让存活检查误判挡住 pwmwake 上位，且 v4 在镜像模式下钉不住面板
            _kill_stale_auxbright()
            print('pwmwake 守护已启动（PWM 模式保持，亮度走 macOS 原生链路）')
            return
        backend = os.path.join(HERE, 'bin', 'auxbright')
        if not (os.path.isfile(backend) and os.access(backend, os.X_OK)):
            backend = find_auxbright()
        if not backend:
            print('找不到 pwmwake / auxbright 二进制，跳过守护启动')
            return
        if _brightness_daemon_alive():
            print('auxbright 守护已在运行')
            return
        log = open('/tmp/auxbright-console.log', 'a')
        subprocess.Popen([backend, 'watch'],
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True)
        print('auxbright 守护已启动（PWM 模式保持，亮度走 macOS 原生链路）')
    except Exception as e:
        print(f'守护启动失败（不影响控制台，唤醒后面板模式可能需手动切）: {e}')


def _kill_stale_auxbright():
    """清掉老版本拉起的 auxbright watch 残留（v4：镜像模式钉不住面板，
    还会让存活检查误判挡住 pwmwake）。只杀命令行精确匹配 'auxbright watch' 的进程。"""
    try:
        r = subprocess.run(['pgrep', '-f', 'auxbright watch'],
                           capture_output=True, timeout=5)
        if r.returncode != 0 or not r.stdout.strip():
            return
        for tok in r.stdout.decode().split():
            try:
                os.kill(int(tok), signal.SIGTERM)
                print(f'已清理旧版 auxbright watch 残留 (pid {tok})')
            except (ValueError, ProcessLookupError, PermissionError):
                pass
    except Exception:
        pass


def install_login_agents():
    """安装登录项守护（幂等）：auxbright PWM 模式保持 + rgbrestore 键盘灯效恢复。
    launchctl 在没有 GUI 会话的环境（如 SSH/沙箱）会失败——如实记录，
    不影响本次使用；plist 就绪，下次登录生效。"""
    try:
        script = os.path.join(HERE, 'scripts', 'ensure-agents.sh')
        if os.path.isfile(script) and os.access(script, os.X_OK):
            r = subprocess.run(['/bin/zsh', script],
                               capture_output=True, timeout=30)
            for line in r.stdout.decode(errors='replace').splitlines():
                print('[agents]', line)
    except Exception as e:
        print(f'登录项安装失败（不影响本次使用）: {e}')


def main():
    if os.environ.get('MACCONSOLE_CHILD'):
        import threading
        def _watch_parent():
            while True:
                if os.getppid() == 1:
                    os._exit(0)
                time.sleep(2)
        threading.Thread(target=_watch_parent, daemon=True).start()
    os.makedirs(WEB, exist_ok=True)
    # 启动时恢复上次保存的散热模式（EC 断电会回默认，跟键盘灯同理）
    try:
        r = fanctl.apply_state()
        if r.get('ok'):
            print(f"散热模式已恢复: {r['state']['mode']}"
                  + (f" 等级 {r['state']['level']}" if r['state']['mode'] == 'custom' else ''))
        elif r.get('reason') != 'no-saved-state' and fanctl.kext_loaded():
            print(f"散热模式恢复失败: {r}")
    except Exception as e:
        print(f"散热模式恢复出错（不影响服务）: {e}")
    # 启动时恢复上次保存的键盘灯效（含白平衡增益；每次开 app 都恢复，
    # 「标定一次、重启不丢」靠的就是这条 + rgbrestore 登录项）
    try:
        r = rgbkb.apply_profile()
        if r.get('ok'):
            print(f"键盘灯效已恢复: mode={r.get('mode')}")
        else:
            print(f"键盘灯效无需恢复: {r.get('error', r)}")
    except Exception as e:
        print(f"键盘灯效恢复出错（不影响服务）: {e}")
    # 亮度守护 + 登录项（系统亮度滑条保持可用的根本保证）
    ensure_brightness_daemon()
    install_login_agents()
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    print(f'Mac 控制台已启动:  http://127.0.0.1:{PORT}')
    print('按 Control-C 停止')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止')
    finally:
        srv.server_close()


if __name__ == '__main__':
    main()
