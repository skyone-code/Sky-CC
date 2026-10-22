#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auxsmooth — 屏幕亮度 CLI（兼容层 / v3 起职责已变）
============================================================================

【2026-10-17 重大架构变更：本机亮度已改用「面板 PWM 模式 + macOS 原生链路」】

旧方案（v1/v2，已废弃）：
    轮询系统亮度 -> 渐变 -> 写 DPCD 0x723（eDP AUX 背光）
    问题：面板 8 位、轮询延迟、软件渐变，不如 Windows 顺滑。

新方案（当前运行中，v3）：
    1. 面板背光切到 **PWM 模式**（DPCD 0x721 = 0x08）——
       面板默认是 AUX 模式，根本不看 iGPU 的 PWM 引脚；
    2. 之后 macOS 原生亮度链路全面接管：系统滑条/F1F2/控制中心
       -> macOS 写 iGPU PWM 占空比寄存器 -> 面板跟随（自带原生渐变）；
    3. 唯一需要的常驻逻辑是「PWM 模式保持」：睡眠唤醒后面板可能
       复位回 AUX 模式，需要有人每秒检查并切回——这就是
       `auxbright watch`（v4 C 程序）的职责。

因此本脚本的职责变为：
  * watch      -> 直接执行 auxbright v4 的 watch（模式保持守护）
  * mode/pwm/aux -> 委托 auxbright（查看/切换面板背光模式）
  * get/set/osset -> **系统亮度**（IOKit，等同 F1/控制中心滑条），
                      这才是现在的真相源；原生链路会把它送到屏幕
  * sysget     -> 系统亮度详情（调试用）
  * raw <0-255> -> 已废弃：PWM 模式下 DPCD 写入被面板忽略。
                  仅当面版处于 AUX 模式时才有意义（紧急兜底）。

命令行（server.py / 模板包装脚本 / 手动调试均兼容旧用法）
------------------------------------------------------------
  auxsmooth watch            守护模式（= auxbright watch，PWM 模式保持）
  auxsmooth mode             显示当前背光模式（PWM/AUX）
  auxsmooth pwm              强制切 PWM 模式
  auxsmooth aux              强制切 AUX 模式（紧急兜底）
  auxsmooth get              读系统亮度，输出 "NN (NN%)"
  auxsmooth set <0-100>      设置系统亮度（IOKit，等同 F1）
  auxsmooth osset <0-100>    set 的别名（兼容旧版）
  auxsmooth sysget           读系统亮度详情
  auxsmooth raw <0-255>      【废弃】直接写 DPCD（PWM 模式下无效）

环境变量
--------
  AUXBRIGHT_PATH        auxbright v4 二进制路径（默认自动查找）
  AUXSMOOTH_DEBUG       置 1 打开调试日志
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import bright  # noqa: E402  (IOKit 系统亮度，同目录)

DEBUG = bool(os.environ.get('AUXSMOOTH_DEBUG'))


def log(msg):
    print(msg, flush=True)


def dbg(msg):
    if DEBUG:
        log('[dbg] ' + msg)


# --------------------------------------------------------------------------
# auxbright v4 后端（PWM 模式保持 + DPCD 紧急兜底的唯一执行者）
# --------------------------------------------------------------------------

AUXBRIGHT_CANDIDATES = [
    os.path.expanduser('~/bin/auxbright'),
    os.path.join(HERE, 'bin', 'auxbright'),
    os.path.join(HERE, 'auxbright'),
    '/Users/skyone/Desktop/Mac控制台/auxbright',
    '/Users/skyone/Desktop/Mac控制台-交接包/auxbright',
    '/usr/local/bin/auxbright',
    '/opt/homebrew/bin/auxbright',
]


def find_auxbright():
    env = os.environ.get('AUXBRIGHT_PATH')
    if env and os.path.isfile(env) and os.access(env, os.X_OK):
        return env
    for p in AUXBRIGHT_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


BACKEND = find_auxbright()


def _need_backend():
    if not BACKEND:
        log('错误: 找不到 auxbright v4 二进制（PWM 模式保持器）')
        return False
    return True


# --------------------------------------------------------------------------
# 委托命令（mode/pwm/aux/watch 直接由 auxbright v4 执行）
# --------------------------------------------------------------------------


def cmd_delegate(args, exec_watch=False):
    """把命令委托给 auxbright v4；watch 用 execv 替换当前进程（守护语义）"""
    if not _need_backend():
        return 1
    if exec_watch:
        os.execv(BACKEND, [BACKEND] + args)
        return 1  # execv 失败才会到这
    try:
        r = subprocess.run([BACKEND] + args, timeout=10)
        return r.returncode
    except Exception as e:
        dbg(f'auxbright {" ".join(args)} 异常: {e}')
        return 1


# --------------------------------------------------------------------------
# 系统亮度命令（现在的真相源）
# --------------------------------------------------------------------------


def cmd_get():
    b = bright.get_brightness()
    if not b.get('ok'):
        log('E: 读不到系统亮度: ' + str(b.get('error', '')))
        return 1
    pct = int(round(b['percent']))
    print(f'{pct} ({pct}%)')
    return 0


def cmd_set(pct):
    try:
        pct = float(pct)
    except (TypeError, ValueError):
        log('E: 亮度值必须是数字')
        return 1
    pct = max(0.0, min(100.0, pct))
    res = bright.set_brightness(pct)
    if not res.get('ok'):
        log('E: 设置系统亮度失败: ' + str(res.get('error', '')))
        return 1
    log(f'系统亮度 = {pct:.0f}%（原生链路将同步到屏幕）')
    return 0


def cmd_sysget():
    b = bright.get_brightness()
    if not b.get('ok'):
        log('E: 读不到系统亮度: ' + str(b.get('error', '')))
        return 1
    log(f'系统亮度 = {b["percent"]:.1f}%（{b.get("displays", "?")} 个显示器）')
    return 0


def cmd_raw(n):
    """废弃命令：PWM 模式下 DPCD 写入被面板忽略，仅 AUX 模式兜底有意义"""
    log('注意: raw 直接写 DPCD 0x723 是旧 AUX 方案的遗留；')
    log('      当前面板在 PWM 模式时该写入被忽略，亮度由 macOS 原生链路驱动。')
    log('      如需调亮度请用 set <0-100>（系统亮度）。')
    if not _need_backend():
        return 1
    try:
        n = int(max(0, min(255, int(float(n)))))
    except (TypeError, ValueError):
        log('E: raw 值必须是 0-255 的整数')
        return 1
    r = subprocess.run([BACKEND, 'raw', str(n)], timeout=10)
    return r.returncode


USAGE = __doc__.split('命令行')[1].split('环境变量')[0] if __doc__ else ''


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help', 'help'):
        print(__doc__)
        return 0
    cmd = argv[1]
    if cmd == 'watch':
        return cmd_delegate(['watch'], exec_watch=True)
    if cmd == 'mode':
        return cmd_delegate(['mode'])
    if cmd == 'pwm':
        return cmd_delegate(['pwm'])
    if cmd == 'aux':
        return cmd_delegate(['aux'])
    if cmd == 'get':
        return cmd_get()
    if cmd == 'set' and len(argv) > 2:
        return cmd_set(argv[2])
    if cmd == 'osset' and len(argv) > 2:
        return cmd_set(argv[2])
    if cmd == 'sysget':
        return cmd_sysget()
    if cmd == 'raw' and len(argv) > 2:
        return cmd_raw(argv[2])
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
