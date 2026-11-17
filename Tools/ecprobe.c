// ecprobe —— 新旧 EC 通道对拍 + MSR 频率采样
//
// 用途：新的 SkyCCEC.kext 与旧 TongfangFan.kext 可以同时加载（IOMatchCategory
// 不同），这个工具同时连两者，读同一批 EC 地址做逐字节对比；顺便采两次 MSR
// 算实时频率。只读，不写任何寄存器。
//
// 用法：./ecprobe            读预设的一批地址并对比
//      ./ecprobe 0x740 0x741 自定义地址

#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>

typedef struct { uint32_t sel, a1, a2; } Cmd;
typedef struct { int32_t status; uint32_t result; } Reply;
typedef struct { uint64_t aperf, mperf, perfStatus; } Sample;

typedef struct {
    const char *cls;      // 服务类名
    io_connect_t conn;
    int isNew;            // 新 kext 才有 MSR
} Chan;

// 新 kext 的 selector 号
enum { kSelInfo = 0, kSelECRead = 5 };

static int openChan(Chan *c, const char *cls) {
    c->cls = cls;
    c->conn = 0;
    io_service_t svc = 0;
    io_iterator_t it = 0;

    // 老 kext 一个类会有多个实例（ABBC0F6F 与 DBBC0F6F），必须挑 GUID 前缀对的
    if (IOServiceGetMatchingServices(0, IOServiceMatching(cls), &it) != KERN_SUCCESS) return -1;
    io_service_t fallback = 0, target = 0;
    while ((svc = IOIteratorNext(it))) {
        CFTypeRef g = IORegistryEntryCreateCFProperty(svc, CFSTR("WMIGuid"),
                                                      kCFAllocatorDefault, 0);
        int matched = 0;
        if (g) {
            if (CFGetTypeID(g) == CFStringGetTypeID()) {
                char buf[64] = {0};
                CFStringGetCString((CFStringRef)g, buf, sizeof(buf), kCFStringEncodingUTF8);
                matched = (strncmp(buf, "ABBC0F6F", 8) == 0);
            }
            CFRelease(g);
        }
        if (matched) {
            if (target) IOObjectRelease(target);
            target = svc;
        } else if (!fallback) {
            fallback = svc;
        } else {
            IOObjectRelease(svc);
        }
    }
    IOObjectRelease(it);

    svc = target ? target : fallback;
    if (target && fallback) IOObjectRelease(fallback);
    if (!svc) return -2;

    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c->conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -(int)kr;
}

static int call(Chan *c, uint32_t sel, uint32_t a1, uint32_t a2, Reply *out) {
    Cmd cmd = { sel, a1, a2 };
    uint8_t buf[64];
    size_t sz = sizeof(buf);
    memset(buf, 0, sizeof(buf));
    kern_return_t kr = IOConnectCallStructMethod(c->conn, 0, &cmd, sizeof(cmd), buf, &sz);
    if (kr != KERN_SUCCESS) return (int)kr;
    if (sz < 8) return -999;
    memcpy(out, buf, 8);
    return 0;
}

int main(int argc, char **argv) {
    uint32_t addrs[32];
    int naddr = 0;
    if (argc > 1) {
        for (int i = 1; i < argc && naddr < 32; i++) addrs[naddr++] = (uint32_t)strtoul(argv[i], NULL, 0);
    } else {
        uint32_t preset[] = { 0x740, 0x741, 0x74E, 0x7A3, 0x7A4, 0x7AB, 0x464, 0x465, 0x46C, 0x46D, 0x751 };
        for (unsigned i = 0; i < sizeof(preset)/sizeof(preset[0]); i++) addrs[naddr++] = preset[i];
    }

    Chan oldc = {0}, newc = {0};
    int oe = openChan(&oldc, "TongfangFanDriver");
    newc.isNew = 1;
    int ne = openChan(&newc, "SkyCCECDriver");

    printf("旧 TongfangFanDriver : %s\n", oe == 0 ? "已连接" : "未连接");
    printf("新 SkyCCECDriver     : %s\n", ne == 0 ? "已连接" : "未连接");
    if (oe && ne) return 1;

    Reply r;
    if (!ne) {
        if (call(&newc, kSelInfo, 0, 0, &r) == 0)
            printf("新 kext INFO        : status=%d hasTarget=%u\n", r.status, r.result);
    }

    printf("\n%-6s | %-10s | %-10s | %s\n", "地址", "旧 kext", "新 kext", "一致");
    printf("-------+------------+------------+------\n");
    int diff = 0, okcnt = 0;
    for (int i = 0; i < naddr; i++) {
        Reply ro = {0}, rn = {0};
        int eo = oe ? -1 : call(&oldc, kSelECRead, addrs[i], 0, &ro);
        int en = ne ? -1 : call(&newc, kSelECRead, addrs[i], 0, &rn);
        char so[24], sn[24];
        if (eo == 0 && ro.status == 0) snprintf(so, sizeof(so), "0x%02X", ro.result & 0xFF);
        else snprintf(so, sizeof(so), "%s", eo ? "err" : "fail");
        if (en == 0 && rn.status == 0) snprintf(sn, sizeof(sn), "0x%02X", rn.result & 0xFF);
        else snprintf(sn, sizeof(sn), "%s", en ? "err" : "fail");
        int same = (eo == 0 && en == 0 && ro.status == 0 && rn.status == 0 &&
                    ((ro.result & 0xFF) == (rn.result & 0xFF)));
        if (same) okcnt++; else diff++;
        printf("0x%04X | %-10s | %-10s | %s\n", addrs[i], so, sn, same ? "✓" : "✗");
        usleep(8000);   // 别把 EC 邮箱踩满
    }
    if (!oe) { printf("\n对比：%d 项一致，%d 项不同\n", okcnt, diff); }

    // MSR 采样（仅新 kext）
    if (!ne && newc.isNew) {
        uint64_t baseHz = 0; size_t len = sizeof(baseHz);
        if (sysctlbyname("hw.cpufrequency", &baseHz, &len, NULL, 0) != 0) baseHz = 0;

        Sample a, b;
        size_t sz = sizeof(Sample);
        kern_return_t kr = IOConnectCallStructMethod(newc.conn, 1, NULL, 0, &a, &sz);
        if (kr != KERN_SUCCESS) {
            printf("\nMSR：调用失败 0x%x（新 kext 没起来？）\n", kr);
        } else {
            usleep(200000);
            sz = sizeof(Sample);
            IOConnectCallStructMethod(newc.conn, 1, NULL, 0, &b, &sz);
            uint64_t dA = b.aperf - a.aperf, dM = b.mperf - a.mperf;
            printf("\nMSR：APERF Δ%llu / MPERF Δ%llu\n",
                   (unsigned long long)dA, (unsigned long long)dM);
            printf("     PERF_STATUS=0x%llx（倍频字段 %llu ×100MHz）\n",
                   (unsigned long long)b.perfStatus,
                   (unsigned long long)(b.perfStatus & 0xFFFF));
            if (dM == 0) {
                printf("     ✗ ΔMPERF 为 0，计数器没走\n");
            } else {
                double ratio = (double)dA / (double)dM;
                printf("     倍数 %.3f×，实时频率 %.0f MHz（基频 %.0f MHz）\n",
                       ratio, baseHz / 1e6 * ratio, baseHz / 1e6);
            }
        }
    }

    if (!oe) IOServiceClose(oldc.conn);
    if (!ne) IOServiceClose(newc.conn);
    return 0;
}
