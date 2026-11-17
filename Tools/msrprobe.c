// msrprobe —— 验证 SkyCCMSR.kext 是否能读到 APERF/MPERF
//
// 独立小工具，不依赖主工程任何代码：连上 kext 的 user client，
// 连采两次，按 ΔAPERF / ΔMPERF 算出睿频倍数，再乘基频得到实时频率。
//
// 用法：./msrprobe            （默认采 200 ms）
//      ./msrprobe 500        （自定义采样间隔，毫秒）

#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>

typedef struct {
    uint64_t aperf;
    uint64_t mperf;
    uint64_t perfStatus;
} Sample;

static int readSample(io_connect_t conn, Sample *s) {
    size_t sz = sizeof(*s);
    kern_return_t kr = IOConnectCallStructMethod(conn, 0, NULL, 0, s, &sz);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}

int main(int argc, char **argv) {
    uint32_t delayMs = argc > 1 ? (uint32_t)atoi(argv[1]) : 200;

    // 基频：hw.cpufrequency（这正是状态栏现在显示的那个固定值）
    uint64_t baseHz = 0;
    size_t len = sizeof(baseHz);
    if (sysctlbyname("hw.cpufrequency", &baseHz, &len, NULL, 0) != 0) baseHz = 0;

    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("SkyCCMSRService"));
    if (!svc) {
        printf("✗ 找不到 SkyCCMSRService —— kext 没加载？\n");
        return 1;
    }
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) {
        printf("✗ IOServiceOpen 失败 0x%x\n", kr);
        return 2;
    }

    Sample a, b;
    int err = readSample(conn, &a);
    if (err) { printf("✗ 首次读取失败 0x%x\n", err); return 3; }
    usleep(delayMs * 1000);
    err = readSample(conn, &b);
    if (err) { printf("✗ 二次读取失败 0x%x\n", err); return 4; }

    uint64_t dA = b.aperf - a.aperf;
    uint64_t dM = b.mperf - a.mperf;

    printf("APERF  : %llu → %llu  (Δ%llu)\n",
           (unsigned long long)a.aperf, (unsigned long long)b.aperf, (unsigned long long)dA);
    printf("MPERF  : %llu → %llu  (Δ%llu)\n",
           (unsigned long long)a.mperf, (unsigned long long)b.mperf, (unsigned long long)dM);
    printf("PERF_STATUS: 0x%llx（倍频字段 %llu ×100MHz）\n",
           (unsigned long long)b.perfStatus, (unsigned long long)(b.perfStatus & 0xffff));

    if (dM == 0) { printf("✗ ΔMPERF 为 0，计数未递增\n"); return 5; }

    double ratio = (double)dA / (double)dM;
    double mhz = baseHz > 0 ? (double)baseHz / 1e6 * ratio : 0.0;
    printf("\n睿频倍数: %.3f×\n", ratio);
    if (mhz > 0) printf("实时频率: %.0f MHz（基频 %.0f MHz）\n", mhz, (double)baseHz / 1e6);

    IOServiceClose(conn);
    return 0;
}
