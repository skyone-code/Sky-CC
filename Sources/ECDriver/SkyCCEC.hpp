//
//  SkyCCEC.hpp —— EC 通道（自己维护的版本，取代只有二进制的 TongfangFan.kext）
//
//  来历：原 TongfangFan.kext 是从 kirainmoe/TongfangEnhancer（GPL）抽出来的
//  二进制，仓库里一直没有源码，所以既没法加新 selector，也没法审。这里按它
//  的外部契约重写一份，行为对齐：
//
//    · 匹配 IOACPIPlatformDevice / IONameMatch = PNP0C14（ACPI WMI 设备）
//    · 解析 _WDG 找到 GUID 对应的块，用块里的 2 字节 ObjectId 拼出方法名
//      "WM<obj>"，调用 (instance, methodId, input) 三个参数
//    · EC 事务：methodId=4，入参是 8 字节 OSData
//         [0]=addr 低 8 位 [1]=addr 高 8 位 [2]=data 低 8 位 [3]=data 高 8 位
//         [4]=0          [5]=1 读 / 0 写        [6]=0 [7]=0
//      回参可能是 OSData（2/4 字节小端）或 OSNumber；低 16 位为 0xFEFE 表示
//      EC 忙 / 超时（固件哨兵值），按 kIOReturnIOError 上报。
//
//  上半段 ABI 与旧 kext 完全一致（selector 0 + 12 字节命令 + 8 字节回执），
//  所以用户态不改也能直接换过来。另外新增 selector 1 专门吐 MSR 采样，把
//  原先单独的 SkyCCMSR.kext 并进来，只留一个内核扩展。
//
//  ─────────────────────────────────────────────────────────────────────
//  版权与许可声明
//
//  本内核扩展（SkyCCEC.kext）的 WMI/EC 通信协议基于 TongfangEnhancer 还原
//  实现：
//
//      TongfangEnhancer — Copyright (C) 2019 kirainmoe (Kai Ren)
//      https://github.com/kirainmoe/TongfangEnhancer
//      授权方式：GNU General Public License v2.0（GPL-2.0）
//
//  依 GPL-2.0 条款，本内核扩展同样以 GPL-2.0 发布，实现源码随本仓库
//  （Sources/ECDriver/ 目录）提供，任何人可按该协议获取、修改与再分发。
//  本程序不提供任何担保。协议全文：
//  https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
//  ─────────────────────────────────────────────────────────────────────
//

#ifndef SKYCC_EC_HPP
#define SKYCC_EC_HPP

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>

// 用户态下发的命令（与旧 kext 逐字节一致）
struct SkyCCECCommand {
    uint32_t selector;
    uint32_t arg1;
    uint32_t arg2;
};

// 回执：status = IOReturn，result = 读回的值
struct SkyCCECReply {
    int32_t  status;
    uint32_t result;
};

// 内部 selector（与旧 kext 的编号一一对应，勿改）
enum {
    kSkyCCSelInfo       = 0,   // arg1 忽略 -> result = 目标块是否存在
    kSkyCCSelSetMode    = 1,   // arg1: 0 普通 / 1 强冷 / 2 自定义
    kSkyCCSelSetLevel   = 2,   // arg1: 0..7
    kSkyCCSelRawMethod  = 3,   // arg1 = WMI methodId，arg2 = data
    kSkyCCSelECWrite    = 4,   // arg1 = 地址(16 位)，arg2 = 数据(16 位)
    kSkyCCSelECRead     = 5,   // arg1 = 地址(16 位) -> result = 数据
    kSkyCCSelECInfo     = 6,   // result = 已服务的事务数（诊断用）
};

// IOConnectCallStructMethod 的 selector 号
enum {
    kSkyCCMethodCommand = 0,   // 上面的命令包
    kSkyCCMethodMSR     = 1,   // 直接吐 MSR 采样（无入参）
};

// 与 SkyCCMSR 里一致的采样结构，64 位对齐，24 字节
struct SkyCCMSRSample {
    uint64_t aperf;
    uint64_t mperf;
    uint64_t perfStatus;
};

// EC 固定常量（与旧 kext 相同）
enum {
    kSkyCCECFanCtrlAddr = 0x0751,  // FAN_CTRL 档位寄存器
    kSkyCCWMIMethodId   = 4,       // WMBC 的 method id
    kSkyCCFanModeNormal = 0x00,
    kSkyCCFanModeBoost  = 0x40,
    kSkyCCFanModeCustom = 0xA0,
    kSkyCCFanLevelBase  = 0x80,
};

// _WDG 里一个块的布局（ACPI WMI 规范：16 + 2 + 1 + 1 = 20 字节）
struct SkyCCWMIBlock {
    uint8_t  guid[16];
    union {
        uint8_t objectId[2];
        struct {
            uint8_t notifyId;
            uint8_t reserved;
        };
    };
    uint8_t  instanceCount;
    uint8_t  flags;
};

class SkyCCECDriver : public IOService {
    OSDeclareDefaultStructors(SkyCCECDriver)
    typedef IOService super;

private:
    IOACPIPlatformDevice *_device       = nullptr;
    bool                  _hasTarget    = false;   // 找到 ABBC0F6F 块
    bool                  _ready        = false;
    char                  _methodName[5] = {0};    // "WMxx"
    uint8_t               _instanceCount = 0;
    bool                  _debug        = false;
    IOLock               *_ecLock       = nullptr;
    uint64_t              _ecOps        = 0;

    bool        loadTargetBlock();
    IOReturn    evaluateWM(uint8_t methodId, OSObject *input, OSObject **result);
    IOReturn    ecTransaction(uint16_t addr, uint16_t data, bool isRead, uint32_t *out);

public:
    virtual IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    virtual bool       start(IOService *provider)                APPLE_KEXT_OVERRIDE;
    virtual void       stop(IOService *provider)                 APPLE_KEXT_OVERRIDE;

    virtual IOReturn newUserClient(task_t owningTask,
                                   void *securityID,
                                   UInt32 type,
                                   OSDictionary *properties,
                                   IOUserClient **handler) APPLE_KEXT_OVERRIDE;

    // 给 user client 用
    int32_t  dispatch(uint32_t selector, uint32_t arg1, uint32_t arg2, uint32_t *result);
    IOReturn msrSample(SkyCCMSRSample *out);
};

class SkyCCECUserClient : public IOUserClient {
    OSDeclareDefaultStructors(SkyCCECUserClient)
    typedef IOUserClient super;

private:
    SkyCCECDriver *_driver = nullptr;

public:
    virtual bool     initWithTask(task_t owningTask,
                                  void *securityID,
                                  UInt32 type,
                                  OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    virtual IOReturn externalMethod(uint32_t selector,
                                    IOExternalMethodArguments *args,
                                    IOExternalMethodDispatch *dispatch,
                                    OSObject *target,
                                    void *reference) APPLE_KEXT_OVERRIDE;

    void setDriver(SkyCCECDriver *driver) { _driver = driver; }
};

#endif /* SKYCC_EC_HPP */
