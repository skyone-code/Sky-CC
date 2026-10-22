#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rgbkb.py —— ITE 8291 (048d:ce00) 键盘灯控制器 · macOS 用户态实现

协议逆向来源（三份证据互相印证）:
  1. 本机 OEM Control Center 的 keyboard.dll 导出符号:
       HID_Get_FirmwareVersion_80H / HID_Set_Effect_Type_08H /
       HID_Set_Picture_12H / HID_Set_Color_14H / HID_Set_RowIndex_16H
  2. rodgomesc/avell-unofficial-control-center (rev 0.03，同为 048d:ce00)
     - handler.py: bmRequestType=0x21, bRequest=0x09, wValue=0x0300
       → USB SET_REPORT，Report Type = Feature(0x03)，Report ID = 0
     - main.py: 效果/亮度包用 8 字节 feature report
                颜色向量用 64 字节写 OUT 端点
  3. kirainmoe/tongfang-macos issue #28 与 gitlab it829x-reversing

本机实测: Feature 报告读写均返回 kr=0，固件版本读取成功，颜色写入生效。

8 字节 Feature 报告结构:
  [0] 0x08 命令码        [1] 0x02 下发 / 0x01 熄灯
  [2] 效果码             [3] 速度 01-0A (1 最快)
  [4] 亮度 08/16/24/32   [5] 颜色码 01-08
  [6] 附加(部分效果需要)  [7] 保存 00/01

其它命令:
  0x16 行号   -> 16 00 <row 0-5> 00 00 00 00 00   （选行）
  0x80 读固件 -> 80 00 ...                         （随后 GET 回读）
  0x14 调色板 -> 14 00 <idx 1-7> <R> <G> <B> 00 00 （rev0.03 命名色）

颜色下发（rev 0.03 真实方式，见文件顶部常量说明）:
  enable user mode -> 08 02 33 00 <亮度> 00 00 <保存>
  然后逐行: 16 00 <row>  +  64 字节「分平面」行缓冲
            [0..20] 蓝   [21..41] 绿   [42..62] 红   [63] 填充
"""
import os
import sys
import time
import importlib.util

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'hidmod', os.path.join(_here, 'hid.py'))
_hid = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_hid)

VID = 0x048d
PID = 0xce00

BRIGHTNESS = {1: 0x08, 2: 0x16, 3: 0x24, 4: 0x32}
BRIGHTNESS_LABEL = {1: '最暗', 2: '偏暗', 3: '偏亮', 4: '最亮'}

PROGRAMS = {
    'breathing': 0x02, 'wave': 0x03, 'random': 0x04, 'reactive': 0x04,
    'rainbow': 0x05, 'ripple': 0x06, 'reactiveripple': 0x07,
    'marquee': 0x09, 'raindrop': 0x0A, 'aurora': 0x0E,
    'reactiveaurora': 0x0E, 'fireworks': 0x11,
}

PROGRAM_LABEL = {
    'breathing': '呼吸', 'wave': '波浪', 'random': '随机', 'reactive': '按键响应',
    'rainbow': '彩虹', 'ripple': '涟漪', 'reactiveripple': '响应涟漪',
    'marquee': '跑马灯', 'raindrop': '雨滴', 'aurora': '极光',
    'reactiveaurora': '响应极光', 'fireworks': '烟花',
}

COLOURS = {'r': 0x01, 'o': 0x02, 'y': 0x03, 'g': 0x04,
           'b': 0x05, 't': 0x06, 'p': 0x07}

COLOUR_LABEL = {'r': '红', 'o': '橙', 'y': '黄', 'g': '绿',
                'b': '蓝', 't': '青', 'p': '紫'}

# ---------------------------------------------------------------------------
# 颜色缓冲的真实布局（rev 0.03 · 参照 pobrn/ite8291r3-ctl）
#
# 键盘物理上是 6 行 × 21 列。每次更新一行：先发 0x16(行号) Feature，
# 再向 OUT 端点写 64 字节行缓冲。
#
# 行缓冲「不是」交错的 RGB，而是分平面的：
#     [ 0..20] 蓝平面 21B   [21..41] 绿平面 21B   [42..62] 红平面 21B   [63] 填充
#
# 早期按 [pad,R,G,B]×16 交错下发是错的 —— 固件把交错的 00 FF FF FF 当平面解析，
# 三个平面各自「大部分亮、少量灭」，合成出偏冷的白，肉眼即「淡蓝」。
# ---------------------------------------------------------------------------
NUM_ROWS = 6
NUM_COLS = 21
ROW_LEN = 64                      # macOS Output 报告 64 字节（描述符无 Report ID）
PLANE_BLUE = 0
PLANE_GREEN = NUM_COLS            # 21
PLANE_RED = 2 * NUM_COLS          # 42

# 兼容旧接口名
ZONE_COUNT = NUM_ROWS
COLOR_VECTOR_LEN = ROW_LEN

# 灯效配置持久化位置（开机自动恢复用）
PROFILE_DIR = os.path.expanduser('~/Library/Application Support/MacConsole')
PROFILE_PATH = os.path.join(PROFILE_DIR, 'rgb_profile.json')


class KeyboardRGB:
    """ITE 8291 键盘灯控制。用作上下文管理器自动关闭句柄。"""

    def __init__(self):
        devs = _hid.find_devices(vendor_id=VID, product_id=PID)
        if not devs:
            raise RuntimeError('未找到 ITE 8291 键盘灯设备 (048d:ce00)')
        self._dev = devs[0]
        self._opened = False

    @staticmethod
    def available():
        try:
            return bool(_hid.find_devices(vendor_id=VID, product_id=PID))
        except Exception:
            return False

    # ---- 生命周期 ----
    def open(self):
        self._dev.open()
        self._opened = True
        return self

    def close(self):
        if self._opened:
            self._dev.close()
            self._opened = False

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()
        return False

    def info(self):
        d = self._dev
        return {
            'product': d.product,
            'manufacturer': d.manufacturer,
            'vendor_id': f'{d.vendor_id:#06x}',
            'product_id': f'{d.product_id:#06x}',
            'usage_page': f'{d.usage_page:#06x}',
            'feature_report_size': d.max_feature_report_size,
            'output_report_size': d.max_output_report_size,
        }

    # ---- 底层 ----
    def _feature(self, payload8):
        """发送 8 字节 Feature 报告 (report id = 0)"""
        pkt = list(payload8) + [0] * (8 - len(payload8))
        return self._dev.set_report(pkt[:8], 'feature', 0)

    def _output(self, payload, length):
        """发送 Output 报告（颜色向量走这里）"""
        pkt = list(payload) + [0] * (length - len(payload))
        return self._dev.set_report(pkt[:length], 'output', 0)

    def read_feature(self, length=8):
        kr, data = self._dev.get_report(length, 'feature', 0)
        return data if kr == 0 else None

    # ---- 查询 ----
    def get_firmware(self):
        """0x80 查询固件版本"""
        self._feature([0x80, 0, 0, 0, 0, 0, 0, 0])
        time.sleep(0.2)
        d = self.read_feature(8)
        if d and d[0] == 0x80:
            return {'raw': d.hex(), 'version_bytes': list(d[1:5])}
        return {'raw': d.hex() if d else None, 'version_bytes': None}

    def get_state(self):
        """读回当前灯效状态字节"""
        d = self.read_feature(8)
        if not d:
            return None
        st = {
            'raw': d.hex(),
            'command': d[0],
            'mode': d[1],
            'program': d[2],
            'speed': d[3],
            'brightness_raw': d[4],
            'colour': d[5],
            'program2': d[6],
        }
        for lvl, raw in BRIGHTNESS.items():
            if raw == d[4]:
                st['brightness_level'] = lvl
        st['off'] = (d[0] == 0x08 and d[1] == 0x01)
        return st

    # ---- 控制 ----
    def disable(self):
        """熄灯"""
        return self._feature([0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    def set_brightness(self, level):
        """单独调亮度（不改灯效）"""
        raw = BRIGHTNESS.get(int(level))
        if raw is None:
            raise ValueError('亮度等级取值 1-4')
        return self._feature([0x08, 0x02, 0x33, 0x00, raw, 0x00, 0x00, 0x00])

    def set_effect(self, program_code, speed=5, brightness=3,
                   colour=0x00, program2=0x00, save=0x01):
        """直接下发效果包"""
        return self._feature([0x08, 0x02, program_code,
                              speed & 0xFF, BRIGHTNESS[brightness],
                              colour & 0xFF, program2 & 0xFF, save & 0xFF])

    def set_named_color(self, slot, r, g, b):
        """命令 0x14：把一个 RGB 写进「命名色」槽位（槽位 1-7）。

        载荷格式来自本项目早前的逆向（README 协议卡片里有记）：
            14 00 <槽位 1-7> <R> <G> <B> 00 00
        灯效包的第 6 字节（colour）随后指向某个槽位 —— 这是让「预设灯效」
        用上任意颜色的唯一通路，因为灯效包本身只带一个字节，装不下 RGB。
        """
        slot = max(1, min(7, int(slot)))
        return self._feature([0x14, 0x00, slot & 0xFF,
                              int(r) & 0xFF, int(g) & 0xFF, int(b) & 0xFF,
                              0x00, 0x00])

    def set_style(self, name, brightness=3, speed=5, save=1, rgb=None, slot=1):
        """按名称设置预设灯效，例如 rainbow / wave / breathing。

        以前灯效只能白/彩虹——因为灯效包里的 colour 字节是硬编码的。
        现在给了 rgb 的话：先用 0x14 把这个颜色写进命名色槽位，
        再让 colour 字节指向该槽位，灯效就能跑在任意颜色上。

        注意：这条是按协议推导出来的，写下去 kr 都是 0，
        但**颜色是否真的变了需要肉眼确认**——设备没有可靠的回读通道。
        """
        if name not in PROGRAMS:
            raise ValueError(f'未知灯效: {name}')
        prog = PROGRAMS[name]
        colour = 0x08          # 各灯效原有的默认 colour
        prog2 = 0x00
        if name == 'rainbow':
            colour = 0x00
        elif name == 'marquee':
            colour = 0x08
        elif name == 'wave':
            colour = 0x00
            prog2 = 0x01
        elif name in ('reactive', 'reactiveaurora', 'fireworks'):
            prog2 = 0x01

        if rgb:
            r, g, b = (int(rgb[0]), int(rgb[1]), int(rgb[2]))
            self.set_named_color(slot, r, g, b)
            time.sleep(0.05)
            colour = slot & 0xFF
        return self.set_effect(prog, speed=speed, brightness=brightness,
                               colour=colour, program2=prog2, save=save)

    # ---- 行缓冲（rev 0.03 的真实颜色下发方式） ----
    def set_row_index(self, row):
        """0x16 选择要写入的行 (0-5)"""
        return self._feature([0x16, 0x00, row & 0xFF,
                              0x00, 0x00, 0x00, 0x00, 0x00])

    @staticmethod
    def build_row_buffer(r, g, b):
        """构造一行 64 字节的平面缓冲：蓝平面21 + 绿平面21 + 红平面21 + 填充"""
        arr = bytearray(ROW_LEN)
        for i in range(NUM_COLS):
            arr[PLANE_BLUE + i] = b & 0xFF
            arr[PLANE_GREEN + i] = g & 0xFF
            arr[PLANE_RED + i] = r & 0xFF
        return arr

    def user_mode(self, save=1, brightness=3):
        """进入用户自定义颜色模式 = 效果码 0x33（rev 0.03 的 user mode）"""
        return self._feature([0x08, 0x02, 0x33, 0x00,
                              BRIGHTNESS.get(int(brightness), 0x24),
                              0x00, 0x00, save & 0xFF])

    def set_zone_colors(self, zones, repeat=1, save=1):
        """按行下发颜色（键盘 6 行 × 21 列）。

        zones: [(r,g,b), ...]，最多 6 项，自顶向下逐行映射；不足时重复最后一项。
        每行：先发 0x16 行号，再写 64 字节平面缓冲。
        repeat>1 时整轮重复（默认 1 次，与官方实现一致）。
        """
        if not zones:
            raise ValueError('zones 不能为空')
        cols = [apply_gains((int(c[0]), int(c[1]), int(c[2])))
                for c in zones]
        last = 0
        for _ in range(max(1, int(repeat))):
            for row in range(NUM_ROWS):
                r, g, b = cols[row % len(cols)]
                arr = self.build_row_buffer(r, g, b)
                self.set_row_index(row)
                time.sleep(0.02)
                last = self._output(arr, ROW_LEN)
        return last

    def set_color(self, r, g, b, brightness=4, save=1, repeat=1):
        """把整个键盘设成单一颜色（完整流程）"""
        self.user_mode(save=save, brightness=brightness)
        time.sleep(0.05)
        return self.set_zone_colors([(r, g, b)], repeat=repeat, save=save)


def hex_to_rgb(s):
    s = s.lstrip('#')
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def rgb_to_hex(rgb):
    return '#%02x%02x%02x' % tuple(int(x) & 0xFF for x in rgb)


# --------------------------------------------------------------------------
# 灯效配置持久化 + 一键恢复
# --------------------------------------------------------------------------

def save_profile(profile):
    """把灯效配置写入 ~/Library/Application Support/MacConsole/rgb_profile.json"""
    import json
    try:
        os.makedirs(PROFILE_DIR, exist_ok=True)
        profile = dict(profile or {})
        profile['updated'] = time.strftime('%Y-%m-%d %H:%M:%S')
        with open(PROFILE_PATH, 'w', encoding='utf-8') as f:
            json.dump(profile, f, ensure_ascii=False, indent=2)
        return True
    except Exception:
        return False


def load_profile():
    """读取已保存的灯效配置；不存在返回 None"""
    import json
    try:
        with open(PROFILE_PATH, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def clear_profile():
    try:
        os.remove(PROFILE_PATH)
        return True
    except Exception:
        return False


def apply_profile(profile=None):
    """按配置恢复灯效。profile 为 None 时读已保存的配置。

    返回 {'ok', 'kr', 'mode', 'profile'}
    """
    profile = profile or load_profile()
    if not profile:
        return {'ok': False, 'error': '没有已保存的灯效配置'}
    if not KeyboardRGB.available():
        return {'ok': False, 'error': '未检测到 ITE 8291 键盘灯设备'}

    mode = profile.get('mode', 'color')
    kr = -1
    with KeyboardRGB() as kb:
        if mode == 'off':
            kr = kb.disable()
        elif mode == 'brightness':
            kr = kb.set_brightness(int(profile.get('brightness', 3)))
        elif mode == 'effect':
            # 保存过的自定义颜色要一并恢复，否则开机自启只剩默认白
            eff_rgb = profile.get('rgb')
            if not eff_rgb and profile.get('hex'):
                eff_rgb = list(hex_to_rgb(profile['hex']))
            kr = kb.set_style(profile.get('style', 'rainbow'),
                              brightness=int(profile.get('brightness', 3)),
                              speed=int(profile.get('speed', 5)),
                              save=1,
                              rgb=eff_rgb,
                              slot=int(profile.get('slot', 1)))
        elif mode == 'zones':
            kb.set_brightness(int(profile.get('brightness', 4)))
            time.sleep(0.05)
            zones = [tuple(int(c) for c in z) for z in profile.get('zones', [])]
            if not zones:
                return {'ok': False, 'error': '配置里的 zones 为空'}
            kr = kb.set_zone_colors(zones, repeat=1, save=1)
        else:                                   # color
            rgb = profile.get('rgb')
            if rgb:
                r, g, b = (int(rgb[0]), int(rgb[1]), int(rgb[2]))
            else:
                r, g, b = hex_to_rgb(profile.get('hex', '#ff9500'))
            kb.set_brightness(int(profile.get('brightness', 4)))
            time.sleep(0.05)
            kr = kb.set_zone_colors([(r, g, b)], repeat=1, save=1)

    return {'ok': kr == 0, 'kr': kr, 'mode': mode, 'profile': profile,
            'gains': list(load_gains()),
            'applied_rgb': list(apply_gains((r, g, b))) if mode == 'color' else None}


def profile_from_params(params):
    """把 server 的 /api/rgb 参数归一化成可保存的 profile"""
    mode = params.get('mode', 'color')
    if mode == 'off':
        return {'mode': 'off'}
    if mode == 'brightness':
        return {'mode': 'brightness', 'brightness': int(params.get('level', 3))}
    if mode == 'effect':
        prof = {'mode': 'effect', 'style': params.get('style', 'rainbow'),
                'brightness': int(params.get('brightness', 3)),
                'speed': int(params.get('speed', 5))}
        # 灯效带自定义颜色时把 hex / rgb 一起存下来，开机自启才能复现
        if params.get('hex'):
            hx = str(params['hex']).lstrip('#')
            try:
                prof['hex'] = hx
                prof['rgb'] = list(hex_to_rgb(hx))
                prof['slot'] = int(params.get('slot', 1))
            except Exception:
                pass
        return prof
    if mode == 'zones':
        return {'mode': 'zones', 'brightness': int(params.get('brightness', 4)),
                'zones': [[int(c) for c in z] for z in params.get('zones', [])]}
    hx = str(params.get('hex', '#ff9500')).lstrip('#')
    try:
        rgb = list(hex_to_rgb(hx))
    except Exception:
        hx, rgb = 'ff9500', [255, 149, 0]
    return {'mode': 'color', 'hex': hx, 'rgb': rgb,
            'brightness': int(params.get('brightness', 4))}


# ---------------------------------------------------------------------------
# 白色光谱校准
#
# 实测：下发纯白 (255,255,255) 时键盘明显偏蓝 —— 这颗灯条的蓝光 LED 效率远高于
# 红/绿，三通道同时打满时蓝压过其余两个。OEM 自己也有 ColorCalibration 流程。
#
# 做法参照 ZavierChen/BetterRGB-ITE8291-Adaptive：让用户指出"纯白指令下肉眼看到
# 的实际颜色"，转到线性光空间后，以最弱通道为基准反算三通道衰减增益；
# 只衰减过强通道，不会溢出。增益单位是千分比，1000 = 不衰减。
# ---------------------------------------------------------------------------
GAIN_PATH = os.path.join(PROFILE_DIR, 'rgb_white_gain.json')
DEFAULT_GAIN = (1000, 1000, 1000)
_gains_cache = None


def _srgb_to_linear(c):
    v = max(0.0, min(255.0, float(c))) / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def calc_white_gains(observed_hex):
    """由「看到的颜色」反算三通道增益。observed_hex 形如 '7f9bff'"""
    s = str(observed_hex).lstrip('#')
    try:
        r, g, b = (int(s[i:i + 2], 16) for i in (0, 2, 4))
    except Exception:
        return None
    lin = (_srgb_to_linear(r), _srgb_to_linear(g), _srgb_to_linear(b))
    strongest, weakest = max(lin), min(lin)
    if strongest < 0.01 or weakest < 0.0005:
        return None
    out = []
    for ch in lin:
        out.append(1000 if ch <= 1e-6
                   else max(50, min(1000, int(weakest / ch * 1000.0 + 0.5))))
    return {'R': out[0], 'G': out[1], 'B': out[2], 'observed': s.lower(),
            'factors': [round(x / 1000.0, 3) for x in out]}


def load_gains():
    global _gains_cache
    if _gains_cache is not None:
        return _gains_cache
    import json
    try:
        with open(GAIN_PATH, encoding='utf-8') as f:
            d = json.load(f)
        _gains_cache = (int(d.get('R', 1000)), int(d.get('G', 1000)),
                        int(d.get('B', 1000)))
    except Exception:
        _gains_cache = DEFAULT_GAIN
    return _gains_cache


def save_gains(gain_r, gain_g, gain_b, observed=None):
    global _gains_cache
    import json
    g = (max(50, min(1000, int(gain_r))),
         max(50, min(1000, int(gain_g))),
         max(50, min(1000, int(gain_b))))
    os.makedirs(PROFILE_DIR, exist_ok=True)
    with open(GAIN_PATH, 'w', encoding='utf-8') as f:
        json.dump({'R': g[0], 'G': g[1], 'B': g[2], 'observed': observed,
                   'updated': time.strftime('%Y-%m-%d %H:%M:%S')},
                  f, ensure_ascii=False, indent=2)
    _gains_cache = g
    return g


def clear_gains():
    global _gains_cache
    _gains_cache = DEFAULT_GAIN
    try:
        os.remove(GAIN_PATH)
    except Exception:
        pass
    return DEFAULT_GAIN


def apply_gains(rgb):
    """把校准增益作用到一个 (r,g,b) 上"""
    gr, gg, gb = load_gains()
    r, g, b = int(rgb[0]), int(rgb[1]), int(rgb[2])
    return (min(255, (r * gr + 500) // 1000),
            min(255, (g * gg + 500) // 1000),
            min(255, (b * gb + 500) // 1000))


# ---------------------------------------------------------------------------
# 滑条端点（让「去蓝强度」滑条可无跳变往返）
#
# 早期实现把滑条位置 t 硬编码映射成 gain = 1000 - k*t（G 用 0.70、B 用 0.80）。
# 问题：界面「点选偏色色块」走的是 calc_white_gains，反算出来的三通道比例
# 一般不在那条直线上；一旦用户随后再碰下滑条，G 会从标定值瞬间跳到直线上，
# 眼睛能看到明显跳变。
#
# 现在改为：滑条只在「中性白(1000,1000,1000)」与一个可变的端点之间线性插值，
#           gain(t) = 1000 - (1000 - end) * t / 100
# 默认端点 (1000, 300, 200) 保留原来拉满时的衰减量；一旦用户做了一次色块
# 标定，端点就被替换成那次标定的结果，于是标定值正好落在 t = 100，
# 滑条从 100 往回拖是「减弱这次校正」，语义自然且完全可逆。
# ---------------------------------------------------------------------------
END_PATH = os.path.join(PROFILE_DIR, 'rgb_white_end.json')
DEFAULT_END = (1000, 300, 200)
_end_cache = None


def load_endpoint():
    global _end_cache
    if _end_cache is not None:
        return _end_cache
    import json
    try:
        with open(END_PATH, encoding='utf-8') as f:
            d = json.load(f)
        _end_cache = (max(50, min(1000, int(d.get('R', 1000)))),
                      max(50, min(1000, int(d.get('G', DEFAULT_END[1])))),
                      max(50, min(1000, int(d.get('B', DEFAULT_END[2])))))
    except Exception:
        _end_cache = DEFAULT_END
    return _end_cache


def save_endpoint(gain_r, gain_g, gain_b):
    """设置滑条 100% 处的增益端点"""
    global _end_cache
    import json
    g = (max(50, min(1000, int(gain_r))),
         max(50, min(1000, int(gain_g))),
         max(50, min(1000, int(gain_b))))
    os.makedirs(PROFILE_DIR, exist_ok=True)
    with open(END_PATH, 'w', encoding='utf-8') as f:
        json.dump({'R': g[0], 'G': g[1], 'B': g[2],
                   'updated': time.strftime('%Y-%m-%d %H:%M:%S')},
                  f, ensure_ascii=False, indent=2)
    _end_cache = g
    return g


def clear_endpoint():
    global _end_cache
    _end_cache = DEFAULT_END
    try:
        os.remove(END_PATH)
    except Exception:
        pass
    return DEFAULT_END


def slider_to_gains(t):
    """滑条位置 0-100 → 增益三元组（中性白 → 端点 线性插值）"""
    end = load_endpoint()
    t = max(0.0, min(100.0, float(t)))
    return tuple(int(round(1000 - (1000 - e) * t / 100.0)) for e in end)


def gains_to_slider(gains=None):
    """增益三元组 → 滑条位置 0-100（取三通道中偏离中性最大的那个）"""
    cur = list(gains) if gains else list(load_gains())
    end = load_endpoint()
    ts = []
    for c, e in zip(cur, end):
        span = 1000 - e
        if span <= 0:
            continue
        ts.append((1000 - c) / float(span) * 100.0)
    if not ts:
        return 0
    return int(max(0, min(100, round(max(ts)))))


if __name__ == '__main__':
    import json

    cmd = sys.argv[1] if len(sys.argv) > 1 else 'info'

    # --- 恢复已保存的灯效（开机自启脚本调用这个） ---
    if cmd == 'apply':
        r = apply_profile()
        print(json.dumps(r, ensure_ascii=False))
        sys.exit(0 if r.get('ok') else 1)

    # --- 查看当前保存的配置 ---
    if cmd == 'profile':
        p = load_profile()
        print(json.dumps(p, ensure_ascii=False, indent=2) if p else '(无配置)')
        sys.exit(0)

    # --- 清除配置 ---
    if cmd == 'clear':
        print('已清除保存的灯效配置' if clear_profile() else '本来就没有配置')
        sys.exit(0)

    # --- 直接设一个颜色并记住: rgbkb.py set '#ff9500' [亮度1-4] ---
    if cmd == 'set':
        if not KeyboardRGB.available():
            print('未检测到 ITE 8291 键盘灯设备')
            sys.exit(1)
        hexv = (sys.argv[2] if len(sys.argv) > 2 else '#ff9500').lstrip('#')
        bright = int(sys.argv[3]) if len(sys.argv) > 3 else 4
        r, g, b = hex_to_rgb(hexv)
        with KeyboardRGB() as kb:
            kb.set_brightness(bright)
            time.sleep(0.05)
            kr = kb.set_zone_colors([(r, g, b)], repeat=8, save=1)
        p = {'mode': 'color', 'hex': hexv, 'rgb': [r, g, b], 'brightness': bright}
        save_profile(p)
        print(json.dumps({'ok': kr == 0, 'kr': kr, 'profile': p},
                         ensure_ascii=False))
        sys.exit(0 if kr == 0 else 1)

    # --- 默认: 打印设备信息 ---
    if not KeyboardRGB.available():
        print('未检测到 ITE 8291 键盘灯设备')
        sys.exit(1)
    with KeyboardRGB() as kb:
        print('设备信息:')
        print(json.dumps(kb.info(), ensure_ascii=False, indent=2))
        print()
        print('当前状态:')
        print(json.dumps(kb.get_state(), ensure_ascii=False, indent=2))
        print()
        print('固件版本查询:')
        print(json.dumps(kb.get_firmware(), ensure_ascii=False, indent=2))
        print()
        print('已保存的灯效配置:')
        print(json.dumps(load_profile(), ensure_ascii=False, indent=2)
              if load_profile() else '(无)')
