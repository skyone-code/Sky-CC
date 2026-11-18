# SkyCCEC.kext —— 自己维护的 EC 通道

取代 `app-resources/TongfangFan.kext`（那个只有二进制、没有源码）。同时把原先
单独的 `SkyCCMSR.kext` 并进来，只留一个内核扩展。

## 对外 ABI（与旧 kext 逐字节一致，用户态不用改）

`IOConnectCallStructMethod(conn, 0, cmd, 12, reply, 8)`

```c
struct Cmd   { uint32_t selector, arg1, arg2; };
struct Reply { int32_t  status;   uint32_t result; };   // status = IOReturn
```

| selector | arg1 | arg2 | 说明 |
|---|---|---|---|
| 0 | — | — | INFO：result = 目标块是否存在 |
| 1 | 0 普通 / 1 强冷 / 2 自定义 | — | 写 `0x751`（FAN_CTRL 档位） |
| 2 | 0..7 | — | 写 `0x751` = `0x80 \| 档位` |
| 3 | WMI methodId | data | methodId=4 时按 `(value<<16)\|addr` 写；其他方法透传 |
| 4 | EC 地址(16 位) | 数据(16 位) | 写 EC |
| 5 | EC 地址(16 位) | — | 读 EC，result = 数据 |
| 6 | — | — | 已服务的事务数（诊断） |

另外新增 `IOConnectCallStructMethod(conn, 1, NULL, 0, &sample, 24)`：
返回 `{u64 aperf, u64 mperf, u64 perf_status}`，实时频率 = 基频 × ΔAPERF/ΔMPERF。

## EC 通道协议（从旧二进制反汇编还原）

旧 kext 只有二进制，这份实现是照着它的机器码还原的行为，不是抄上游：

1. 匹配 `IOACPIPlatformDevice` / `IONameMatch = PNP0C14`（ACPI WMI 设备）
2. 读 `_WDG`，按 20 字节一个块切分（16 字节 GUID + 2 字节 ObjectId +
   instanceCount + flags），找 GUID：
   - 首选 `ABBC0F6F-8EA1-11D1-00A0-C90629100000`（真 WMI 控制块）
   - 退选 `DBBC0F6F-…`（OTA 擦写口，实测读全 0xFF，仅兜底）
3. 方法名 = `"WM"` + ObjectId 两个 ASCII 字符，调用
   `evaluateObject(method, &reply, {instance, methodId, input}, 3)`
4. EC 事务固定 methodId = 4，入参是 **8 字节 OSData**：

   | 偏移 | 含义 |
   |---|---|
   | 0 | 地址低 8 位 |
   | 1 | 地址高 8 位 |
   | 2 | 数据低 8 位 |
   | 3 | 数据高 8 位 |
   | 4 | 恒 0（未用） |
   | 5 | 1 = 读，0 = 写 |
   | 6,7 | 恒 0 |

5. 回参可能是 `OSData`（2 或 4 字节小端）或 `OSNumber`；**低 16 位为 `0xFEFE`
   表示 EC 忙 / 超时**（固件哨兵值），按 `kIOReturnIOError` 上报，本实现会
   隔 3ms 再试，最多 3 次。

## 构建 / 安装 / 验证

```sh
zsh Sources/ECDriver/build-ec-kext.sh        # 产物 app-resources/SkyCCEC.kext
sudo sh Sources/ECDriver/install-ec-kext.sh  # 装到 /Library/Extensions + 重建 collection
# 必须重启一次（macOS 26 不接受新 kext 热加载）
./Tools/ecprobe                              # 新旧 kext 对拍 + MSR 采样
```

`Tools/ecprobe` 会同时连 `TongfangFanDriver` 和 `SkyCCECDriver`（`IOMatchCategory`
不同，两个 kext 可以并存），逐地址对比读数——验证阶段不用卸载旧 kext。

## 为什么不用上游源码

上游 [kirainmoe/TongfangEnhancer](https://github.com/kirainmoe/TongfangEnhancer)
（GPL）只有「固定地址写风扇档位」的能力，没有通用 EC 读写；通用通道是前一位
作者在二进制里加的。所以这里按**对外行为**重写，而不是搬上游代码。

## 版权与许可

本内核扩展的 WMI/EC 通信协议基于
[TongfangEnhancer](https://github.com/kirainmoe/TongfangEnhancer)（**GPL-2.0**，
Copyright (C) 2019 kirainmoe / Kai Ren）还原实现——WMI 方法封装、EC 邮箱事务与
风扇档位寄存器均源自该项目的公开源码与接口约定。依 GPL-2.0 条款，**本内核扩展
（Sources/ECDriver/ 全部源码与产物 SkyCCEC.kext）同样按 GPL-2.0 发布**，任何人可
按该协议获取、修改与再分发；本程序不提供任何担保。协议全文见
[gnu.org/licenses/old-licenses/gpl-2.0.html](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)。

安装器内也带了一页开源声明（license.html），用户安装时必须同意后才继续。
