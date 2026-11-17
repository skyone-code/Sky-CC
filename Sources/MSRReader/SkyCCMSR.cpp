//
//  SkyCCMSR.cpp —— Sky CC 的 CPU 实时频率读数（Intel APERF / MPERF）
//
//  为什么单独一个 kext：app-resources 里的 TongfangFan.kext 只有二进制、
//  没有源码（仓库从初始导入起就只有 .kext），没法在里面加 selector；
//  而读 MSR 必须在内核态（用户态执行 rdmsr 直接 #GP）。所以另立一个
//  只读的小驱动，与风扇 / EC 那套完全解耦，互不影响。
//
//  为什么不用 mp_rendezvous 遍历所有核：那不是 KPI，第三方 kext 链接不到，
//  加载时会因 undefined symbol 被拒。所以这里只读「调用线程当前所在核」的
//  两个计数器。用户态多次调用取平均，即可近似全核频率（线程在采样期间
//  会被调度器搬到不同核心上，统计上覆盖足够）。
//
//  设计上刻意保持极简：不写任何 MSR、不分配内存、不加锁、不起线程、
//  不持有任何跨调用状态。externalMethod 里只有三次 rdmsr64 和一次 memcpy。
//  读寄存器是幂等的，最坏情况是数值没意义，不会 panic。
//
//  频率换算是用户态做的：
//      真实频率 = 基频 × ΔAPERF / ΔMPERF
//  （MPERF 按基频递增，APERF 按实际频率递增，比值即当前睿频倍数）
//

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <i386/proc_reg.h>
#include <mach/kmod.h>

// 链接器不会自动生成 __kmod_info —— 必须由源码给出，否则 kmutil 会拒绝：
//   "kexts must have a _kmod_info symbol"
// 标准宏 KMOD_EXPLICIT_DECL 的 name 参数会经过 # 字符串化，带点的 bundle id
// 不是合法 token，所以照着它的展开形式手写一份（字段顺序与 mach/kmod.h 的
// kmod_info_t 一致，KMOD_INFO_VERSION / -1U / -1 都照抄宏里的值）。
// start/stop 留空：匹配靠 IOKitPersonalities，不走 kmod 的启动回调。
extern "C" {
kmod_info_t kmod_info = {
    0,                    // next
    KMOD_INFO_VERSION,    // info_version
    0xFFFFFFFFu,          // id
    { "com.skycc.MSRReader" },
    { "1.0.0" },
    -1,                   // reference_count
    0, 0, 0, 0,           // reference_list / address / size / hdr_size
    0, 0                  // start / stop
};
}

#define kMSR_MPERF        0xE7
#define kMSR_APERF        0xE8
#define kMSR_PERF_STATUS  0x198

// 与用户态 Sources/SkyCC/Native/NativeMSR.swift 里的结构体逐字节对应，
// 改这里必须同步改那边（两边都有 static_assert 兜底）。
struct SkyCCMSRSample {
    uint64_t aperf;
    uint64_t mperf;
    uint64_t perfStatus;
};

enum {
    kSkyCCMSRMethodSample = 0,
};

class SkyCCMSRService : public IOService {
    OSDeclareDefaultStructors(SkyCCMSRService)
    typedef IOService super;

public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual IOReturn newUserClient(task_t owningTask,
                                   void *securityID,
                                   UInt32 type,
                                   OSDictionary *properties,
                                   IOUserClient **handler) APPLE_KEXT_OVERRIDE;
};

class SkyCCMSRClient : public IOUserClient {
    OSDeclareDefaultStructors(SkyCCMSRClient)
    typedef IOUserClient super;

public:
    virtual bool initWithTask(task_t owningTask,
                              void *securityID,
                              UInt32 type,
                              OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    virtual IOReturn externalMethod(uint32_t selector,
                                    IOExternalMethodArguments *args,
                                    IOExternalMethodDispatch *dispatch,
                                    OSObject *target,
                                    void *reference) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(SkyCCMSRService, IOService)
OSDefineMetaClassAndStructors(SkyCCMSRClient, IOUserClient)

// MARK: - Service

bool SkyCCMSRService::start(IOService *provider)
{
    if (!super::start(provider)) return false;
    registerService();
    IOLog("SkyCCMSR: started (APERF/MPERF reader)\n");
    return true;
}

void SkyCCMSRService::stop(IOService *provider)
{
    IOLog("SkyCCMSR: stopped\n");
    super::stop(provider);
}

IOReturn SkyCCMSRService::newUserClient(task_t owningTask,
                                        void *securityID,
                                        UInt32 type,
                                        OSDictionary *properties,
                                        IOUserClient **handler)
{
    if (!handler) return kIOReturnBadArgument;

    SkyCCMSRClient *client = new SkyCCMSRClient;
    if (!client) return kIOReturnNoMemory;

    if (!client->initWithTask(owningTask, securityID, type, properties)) {
        client->release();
        return kIOReturnError;
    }
    if (!client->attach(this)) {
        client->release();
        return kIOReturnError;
    }
    if (!client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnError;
    }

    *handler = client;
    return kIOReturnSuccess;
}

// MARK: - Client

bool SkyCCMSRClient::initWithTask(task_t owningTask,
                                  void *securityID,
                                  UInt32 type,
                                  OSDictionary *properties)
{
    if (!super::initWithTask(owningTask, securityID, type, properties)) return false;
    return true;
}

IOReturn SkyCCMSRClient::externalMethod(uint32_t selector,
                                        IOExternalMethodArguments *args,
                                        IOExternalMethodDispatch *dispatch,
                                        OSObject *target,
                                        void *reference)
{
    if (selector != kSkyCCMSRMethodSample) return kIOReturnUnsupported;
    if (!args) return kIOReturnBadArgument;

    // 固定结构输出：调用方（helper）必须给足 sizeof(SkyCCMSRSample)
    if (!args->structureOutput || args->structureOutputSize < sizeof(SkyCCMSRSample))
        return kIOReturnBadArgument;

    SkyCCMSRSample s;
    s.aperf      = rdmsr64(kMSR_APERF);
    s.mperf      = rdmsr64(kMSR_MPERF);
    s.perfStatus = rdmsr64(kMSR_PERF_STATUS);

    memcpy(args->structureOutput, &s, sizeof(s));
    args->structureOutputSize = sizeof(s);
    return kIOReturnSuccess;
}
