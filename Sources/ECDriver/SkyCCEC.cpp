//
//  SkyCCEC.cpp —— EC 通道实现（协议说明与许可声明见 SkyCCEC.hpp 顶部：
//  协议基于 TongfangEnhancer（GPL-2.0，Copyright (C) 2019 kirainmoe）还原
//  实现，本扩展因此同样按 GPL-2.0 发布）
//

#include "SkyCCEC.hpp"

#include <i386/proc_reg.h>
#include <mach/kmod.h>

// ---------------------------------------------------------------- kmod 头

// 链接器不会生成 _kmod_info，必须源码给出；start/stop 不能留空，否则
// kmutil load 会报 "kext (kmod) start/stop routine failed (-603946985)"。
extern "C" {
kern_return_t SkyCCEC_kmod_start(kmod_info_t *ki, void *data);
kern_return_t SkyCCEC_kmod_stop(kmod_info_t *ki, void *data);

kmod_info_t kmod_info = {
    0,                    // next
    KMOD_INFO_VERSION,    // info_version
    0xFFFFFFFFu,          // id
    { "com.skycc.EC" },
    { "1.0.0" },
    -1,                   // reference_count
    0, 0, 0, 0,           // reference_list / address / size / hdr_size
    (kmod_start_func_t *)&SkyCCEC_kmod_start,
    (kmod_stop_func_t *)&SkyCCEC_kmod_stop
};

kern_return_t SkyCCEC_kmod_start(kmod_info_t *ki, void *data) { return KERN_SUCCESS; }
kern_return_t SkyCCEC_kmod_stop(kmod_info_t *ki, void *data)  { return KERN_SUCCESS; }
}

#define EC_LOG(fmt, ...) \
    do { if (_debug) IOLog("SkyCCEC: " fmt "\n", ##__VA_ARGS__); } while (0)

// 目标 GUID：真 WMI 控制块（另一个 DBBC0F6F 是 OTA 擦写口，读全 0xFF）
static const char kTargetGuid[]   = "ABBC0F6F-8EA1-11D1-00A0-C90629100000";
static const char kFallbackGuid[] = "DBBC0F6F-8EA1-11D1-00A0-C90629100000";

// 把 _WDG 里的 16 字节原始 GUID 转成 ACPI 规范的字符串形式
// （前三段小端，后两段大端）
static void guidToString(const uint8_t *in, char *out)
{
    // 前 3 段按小端逐字节倒序
    int o = 0;
    for (int i = 3; i >= 0; i--) o += snprintf(out + o, 3, "%02X", in[i]);
    out[o++] = '-';
    o += snprintf(out + o, 3, "%02X", in[5]);
    o += snprintf(out + o, 3, "%02X", in[4]);
    out[o++] = '-';
    o += snprintf(out + o, 3, "%02X", in[7]);
    o += snprintf(out + o, 3, "%02X", in[6]);
    out[o++] = '-';
    o += snprintf(out + o, 3, "%02X", in[8]);
    o += snprintf(out + o, 3, "%02X", in[9]);
    out[o++] = '-';
    for (int i = 10; i <= 15; i++) o += snprintf(out + o, 3, "%02X", in[i]);
    out[o] = '\0';
}

// ---------------------------------------------------------------- Driver

OSDefineMetaClassAndStructors(SkyCCECDriver, IOService)
OSDefineMetaClassAndStructors(SkyCCECUserClient, IOUserClient)

IOService *SkyCCECDriver::probe(IOService *provider, SInt32 *score)
{
    if (!super::probe(provider, score)) return nullptr;

    // 只认 ACPI WMI 设备（PNP0C14），且必须带 _WDG
    IOACPIPlatformDevice *dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!dev) return nullptr;
    if (dev->validateObject("_WDG") != kIOReturnSuccess) return nullptr;

    _device = dev;
    dev->retain();          // 持有 provider，避免 stop 之后还在用悬空指针
    return this;
}

bool SkyCCECDriver::loadTargetBlock()
{
    if (!_device) return false;

    OSObject *result = nullptr;
    if (_device->evaluateObject("_WDG", &result) != kIOReturnSuccess || !result) {
        IOLog("SkyCCEC: %s _WDG evaluate failed\n", _device->getName());
        return false;
    }
    OSData *data = OSDynamicCast(OSData, result);
    if (!data) {
        result->release();
        IOLog("SkyCCEC: %s _WDG returned non-data object\n", _device->getName());
        return false;
    }

    unsigned len = data->getLength();
    if (len == 0 || len % sizeof(SkyCCWMIBlock) != 0) {
        IOLog("SkyCCEC: %s _WDG bad length %u\n", _device->getName(), len);
        data->release();
        return false;
    }

    const SkyCCWMIBlock *blocks = (const SkyCCWMIBlock *)data->getBytesNoCopy();
    unsigned count = len / sizeof(SkyCCWMIBlock);

    // 先找目标 GUID，找不到再退到备用；都不在就不接管这个设备
    const char *wanted = nullptr;
    for (int pass = 0; pass < 2 && !wanted; pass++) {
        const char *cand = (pass == 0) ? kTargetGuid : kFallbackGuid;
        for (unsigned i = 0; i < count; i++) {
            char g[37];
            guidToString(blocks[i].guid, g);
            if (strcmp(g, cand) == 0) {
                wanted = cand;
                // 方法名 = "WM" + ObjectId（两个 ASCII 字符）
                _methodName[0] = 'W';
                _methodName[1] = 'M';
                _methodName[2] = (char)blocks[i].objectId[0];
                _methodName[3] = (char)blocks[i].objectId[1];
                _methodName[4] = '\0';
                _instanceCount = blocks[i].instanceCount;
                EC_LOG("%s block[%u] -> %s (instances %u, flags 0x%x)",
                       g, i, _methodName, _instanceCount, blocks[i].flags);
                break;
            }
        }
    }

    data->release();
    if (!wanted) {
        IOLog("SkyCCEC: %s _WDG has %u blocks, no target GUID\n",
              _device->getName(), count);
        return false;
    }
    return true;
}

bool SkyCCECDriver::start(IOService *provider)
{
    if (!super::start(provider)) {
        IOLog("SkyCCEC: super::start failed\n");
        return false;
    }

    OSBoolean *dbg = OSDynamicCast(OSBoolean, getProperty("DebugMode"));
    _debug = (dbg != nullptr) && dbg->getValue();

    _ecLock = IOLockAlloc();
    if (!_ecLock) {
        IOLog("SkyCCEC: IOLockAlloc failed\n");
        return false;
    }

    if (!loadTargetBlock()) return false;

    _hasTarget = true;
    _ready = true;
    setProperty("WMIMethod", OSString::withCString(_methodName));
    registerService();

    IOLog("SkyCCEC: service registered on %s (method %s)\n",
          _device ? _device->getName() : "?", _methodName);
    return true;
}

void SkyCCECDriver::stop(IOService *provider)
{
    if (_ecLock) {
        IOLockFree(_ecLock);
        _ecLock = nullptr;
    }
    _ready = false;
    if (_device) {
        _device->release();
        _device = nullptr;
    }
    super::stop(provider);
}

IOReturn SkyCCECDriver::newUserClient(task_t owningTask,
                                      void *securityID,
                                      UInt32 type,
                                      OSDictionary *properties,
                                      IOUserClient **handler)
{
    if (!handler) return kIOReturnBadArgument;

    SkyCCECUserClient *client = new SkyCCECUserClient;
    if (!client) return kIOReturnNoMemory;

    if (!client->initWithTask(owningTask, securityID, type, properties) ||
        !client->attach(this) ||
        !client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnError;
    }

    client->setDriver(this);
    *handler = client;
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------- WMI

IOReturn SkyCCECDriver::evaluateWM(uint8_t methodId, OSObject *input, OSObject **result)
{
    if (!_device || !_methodName[0]) return kIOReturnNotReady;

    OSNumber *inst = OSNumber::withNumber((unsigned long long)0, 8);
    OSNumber *mid  = OSNumber::withNumber((unsigned int)methodId, 32);
    if (!inst || !mid) {
        if (inst) inst->release();
        if (mid)  mid->release();
        return kIOReturnNoMemory;
    }

    OSObject *args[3] = { inst, mid, input };
    IOReturn kr = _device->evaluateObject(_methodName, result, args, 3);

    inst->release();
    mid->release();
    return kr;
}

// 把 WMI 回参解释成数值；返回 false 表示固件回了「EC 忙 / 超时」哨兵
static bool parseWMReply(OSObject *reply, uint32_t *value)
{
    *value = 0;
    if (!reply) return true;

    if (OSData *d = OSDynamicCast(OSData, reply)) {
        unsigned len = d->getLength();
        const uint8_t *p = (const uint8_t *)d->getBytesNoCopy();
        if (len >= 2) {
            uint32_t v = (uint32_t)p[0] | ((uint32_t)p[1] << 8);
            if (len >= 4) {
                v |= ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
            }
            *value = v;
            return !(p[0] == 0xFE && p[1] == 0xFE);
        }
        return true;   // 回了个空 buffer：当作「没有值」，不算失败
    }

    if (OSNumber *n = OSDynamicCast(OSNumber, reply)) {
        uint32_t v = n->unsigned32BitValue();
        *value = v;
        return (v & 0xFFFF) != 0xFEFE;
    }

    return true;
}

IOReturn SkyCCECDriver::ecTransaction(uint16_t addr, uint16_t data, bool isRead, uint32_t *out)
{
    if (out) *out = 0;
    if (!_device || !_methodName[0]) return kIOReturnNotReady;

    uint8_t buf[8] = {0};
    buf[0] = (uint8_t)(addr & 0xFF);
    buf[1] = (uint8_t)(addr >> 8);
    buf[2] = (uint8_t)(data & 0xFF);
    buf[3] = (uint8_t)(data >> 8);
    buf[5] = isRead ? 1 : 0;

    IOReturn kr = kIOReturnIOError;
    uint32_t value = 0;

    if (_ecLock) IOLockLock(_ecLock);

    // EC 忙（0xFEFE）时最多再试两次：固件单次事务约 2ms，3ms 后基本已就绪。
    // 不在这里做长时间重试——上层（app）有自己的 1.5s 看门狗，长重试只会
    // 把「读不到」变成「读到但很久」，反而更难判。
    for (int attempt = 0; attempt < 3; attempt++) {
        OSData *input = OSData::withBytes(buf, sizeof(buf));
        if (!input) { kr = kIOReturnNoMemory; break; }

        OSObject *reply = nullptr;
        kr = evaluateWM(kSkyCCWMIMethodId, input, &reply);
        input->release();
        if (kr != kIOReturnSuccess) break;

        bool ok = parseWMReply(reply, &value);
        if (reply) reply->release();

        kr = ok ? kIOReturnSuccess : kIOReturnIOError;
        if (ok) break;
        if (attempt < 2) IOSleep(3);
    }

    if (_ecLock) IOLockUnlock(_ecLock);

    _ecOps++;
    if (out) *out = value;
    return kr;
}

// ---------------------------------------------------------------- dispatch

int32_t SkyCCECDriver::dispatch(uint32_t selector, uint32_t arg1, uint32_t arg2, uint32_t *result)
{
    if (result) *result = 0;

    switch (selector) {
    case kSkyCCSelInfo:
        if (result) *result = _hasTarget ? 1 : 0;
        return KERN_SUCCESS;

    case kSkyCCSelSetMode: {
        uint16_t level;
        switch (arg1) {
        case 0:  level = kSkyCCFanModeNormal; break;
        case 1:  level = kSkyCCFanModeBoost;  break;
        case 2:  level = kSkyCCFanModeCustom; break;
        default: return kIOReturnBadArgument;
        }
        return (int32_t)ecTransaction(kSkyCCECFanCtrlAddr, level, false, result);
    }

    case kSkyCCSelSetLevel: {
        if (arg1 > 7) return kIOReturnBadArgument;
        uint16_t level = (uint16_t)(kSkyCCFanLevelBase | (arg1 & 0x7));
        return (int32_t)ecTransaction(kSkyCCECFanCtrlAddr, level, false, result);
    }

    case kSkyCCSelRawMethod: {
        // methodId 4 = WMBC 的 GetSetULong 兼容形态：(value << 16) | addr
        if (arg1 == kSkyCCWMIMethodId) {
            uint16_t addr = (uint16_t)(arg2 & 0xFFFF);
            uint16_t val  = (uint16_t)((arg2 >> 16) & 0xFFFF);
            return (int32_t)ecTransaction(addr, val, false, result);
        }
        OSNumber *in = OSNumber::withNumber((unsigned int)arg2, 32);
        if (!in) return kIOReturnNoMemory;
        OSObject *reply = nullptr;
        IOReturn kr = evaluateWM((uint8_t)arg1, in, &reply);
        in->release();
        if (kr != kIOReturnSuccess) return (int32_t)kr;
        uint32_t v = 0;
        bool ok = parseWMReply(reply, &v);
        if (reply) reply->release();
        if (result) *result = v;
        return (int32_t)(ok ? kIOReturnSuccess : kIOReturnIOError);
    }

    case kSkyCCSelECWrite:
        return (int32_t)ecTransaction((uint16_t)(arg1 & 0xFFFF),
                                      (uint16_t)(arg2 & 0xFFFF), false, result);

    case kSkyCCSelECRead:
        return (int32_t)ecTransaction((uint16_t)(arg1 & 0xFFFF), 0, true, result);

    case kSkyCCSelECInfo:
        if (result) *result = (uint32_t)_ecOps;
        return KERN_SUCCESS;

    default:
        return kIOReturnUnsupported;
    }
}

IOReturn SkyCCECDriver::msrSample(SkyCCMSRSample *out)
{
    if (!out) return kIOReturnBadArgument;
    out->aperf      = rdmsr64(0xE8);    // APERF
    out->mperf      = rdmsr64(0xE7);    // MPERF
    out->perfStatus = rdmsr64(0x198);   // IA32_PERF_STATUS
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------- UserClient

bool SkyCCECUserClient::initWithTask(task_t owningTask,
                                     void *securityID,
                                     UInt32 type,
                                     OSDictionary *properties)
{
    if (!super::initWithTask(owningTask, securityID, type, properties)) return false;
    _driver = OSDynamicCast(SkyCCECDriver, getProvider());
    return true;
}

IOReturn SkyCCECUserClient::externalMethod(uint32_t selector,
                                           IOExternalMethodArguments *args,
                                           IOExternalMethodDispatch *dispatch,
                                           OSObject *target,
                                           void *reference)
{
    if (!_driver) _driver = OSDynamicCast(SkyCCECDriver, getProvider());
    if (!_driver) return kIOReturnNotReady;
    if (!args) return kIOReturnBadArgument;

    // selector 0：命令包（与旧 kext 的 12 进 / 8 出一致）
    if (selector == kSkyCCMethodCommand) {
        if (!args->structureInput || args->structureInputSize < sizeof(SkyCCECCommand))
            return kIOReturnBadArgument;
        if (!args->structureOutput || args->structureOutputSize < sizeof(SkyCCECReply))
            return kIOReturnBadArgument;

        SkyCCECCommand cmd;
        memcpy(&cmd, args->structureInput, sizeof(cmd));

        SkyCCECReply reply;
        reply.status = _driver->dispatch(cmd.selector, cmd.arg1, cmd.arg2, &reply.result);

        memcpy(args->structureOutput, &reply, sizeof(reply));
        args->structureOutputSize = sizeof(reply);
        return kIOReturnSuccess;
    }

    // selector 1：MSR 采样（无入参，24 字节出参）
    if (selector == kSkyCCMethodMSR) {
        if (!args->structureOutput || args->structureOutputSize < sizeof(SkyCCMSRSample))
            return kIOReturnBadArgument;

        SkyCCMSRSample sample;
        IOReturn kr = _driver->msrSample(&sample);
        if (kr != kIOReturnSuccess) return kr;

        memcpy(args->structureOutput, &sample, sizeof(sample));
        args->structureOutputSize = sizeof(sample);
        return kIOReturnSuccess;
    }

    return kIOReturnUnsupported;
}
