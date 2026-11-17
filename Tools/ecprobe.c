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
#include <time.h>

typedef struct { uint32_t sel, a1, a2; } Cmd;
typedef struct { int32_t status; uint32_t result; } Reply;
typedef struct { uint64_t aperf, mperf, perfStatus; } Sample;

typedef struct {
    const char *cls;      // 服务类名
    io_connect_t conn;
    int isNew;            // 新 kext 才有 MSR
} Chan;

// 新 kext 的 selector 号
enum { kSelInfo = 0, kSelECWrite = 4, kSelECRead = 5 };

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

// 采样窗口的倍数排序用
static int cmpD(const void *x, const void *y)
{
    double a = *(const double *)x, b = *(const double *)y;
    return (a < b) ? -1 : (a > b);
}

int main(int argc, char **argv) {
    // --stress [次数]：只对新通道连打同一个地址，看连续访问是否稳定
    if (argc > 1 && strcmp(argv[1], "--stress") == 0) {
        int n = (argc > 2) ? atoi(argv[2]) : 200;
        if (n <= 0) n = 200;
        Chan s = {0}; s.isNew = 1;
        if (openChan(&s, "SkyCCECDriver")) { printf("新 kext 未连接\n"); return 1; }
        int fail = 0; Reply r;
        for (int i = 0; i < n; i++) {
            memset(&r, 0, sizeof(r));
            if (call(&s, kSelECRead, 0x740, 0, &r) != 0 || r.status != 0) fail++;
            usleep(2000);
        }
        printf("连打 0x740 %d 次：失败 %d，成功 %d\n", n, fail, n - fail);
        IOServiceClose(s.conn);
        return fail ? 2 : 0;
    }

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

    // 写通路验证：把 0x751（风扇控制）的现值**原样写回**，再回读。
    // 写同值不会改变硬件的目标状态，但足以证明写通道真的打通 —— 写不进去的话
    // 回读会和预期不符（或者命令直接失败）。只有新旧通道都在时做，出问题能互相兜底。
    if (!oe && !ne && newc.isNew) {
        Reply ra = {0}, w = {0}, rb = {0};
        int ea = call(&oldc, kSelECRead, 0x751, 0, &ra);
        usleep(20000);
        int ew = call(&newc, kSelECWrite, 0x751, ra.result & 0xFF, &w);
        usleep(20000);
        int eb = call(&oldc, kSelECRead, 0x751, 0, &rb);
        printf("\n写通路（0x751 写回同值 0x%02X）\n", (unsigned)(ra.result & 0xFF));
        printf("  写入      : %s", (ew == 0 && w.status == 0) ? "成功" : "失败");
        if (ew) printf("（调用错误 0x%x）", (unsigned)ew);
        else if (w.status) printf("（status %d）", w.status);
        printf("\n  旧通道回读: 0x%02X\n", (unsigned)(rb.result & 0xFF));
        printf("  状态       : %s\n",
               (ea == 0 && eb == 0 && ra.status == 0 && rb.status == 0 &&
                (ra.result & 0xFF) == (rb.result & 0xFF)) ? "写后未变化 ✓" : "变化了 ✗");
    }

    // MSR 采样（仅新 kext）
    //
    // APERF/MPERF 是「每核」MSR，而且核心被停核时计数器一起停。所以线程在两个
    // 采样点之间跳到另一个核心时，两次读到的绝对值属于不同计数器，差值可能是
    // 任意值（实测 ±1e11 级别，对应停核时长），直接相减会得到负数（无符号下溢）
    // 或荒唐的倍数。
    //
    // 判定「同一个核」的办法不能靠增量大小绝对值，用**墙钟上界**：MPERF 按基频
    // 计数、且在深度 C-state 时停止，所以同核的 ΔMPERF 必然 ≤ 经过时间 × 基频；
    // 跨核跳变的增量是「停核时长」量级（实测 1e11，比这大几百倍）。因此：
    //   0 < ΔMPERF ≤ 墙钟×基频×1.1  → 同核，比值可信
    // 注意不能对 ΔMPERF 设下界：C-state 会让它远小于墙钟，那是正常的，比值不受影响。
    // 比值 < 1 也是合法的（核心能降到基频以下的低频 P-state），不能一刀切掉。
    if (!ne && newc.isNew) {
        uint64_t baseHz = 0; size_t len = sizeof(baseHz);
        if (sysctlbyname("hw.cpufrequency", &baseHz, &len, NULL, 0) != 0) baseHz = 0;

        // 跨核在负载高时会连续命中，固定窗口数会一个都采不到；改成「采够就停」
        enum { kWant = 6, kTry = 60, kMs = 100 };
        double ratios[kWant]; int nR = 0, tried = 0, skipped = 0;
        uint64_t lastPerf = 0;

        Sample a, b;
        struct timespec t0, t1;
        size_t sz = sizeof(Sample);
        kern_return_t kr = IOConnectCallStructMethod(newc.conn, 1, NULL, 0, &a, &sz);
        clock_gettime(CLOCK_MONOTONIC, &t0);
        if (kr != KERN_SUCCESS) {
            printf("\nMSR：调用失败 0x%x（新 kext 没起来？）\n", kr);
        } else {
            printf("\nMSR 采样（最多 %d 次 × %d ms，取 %d 个同核窗口）\n", kTry, kMs, kWant);
            while (nR < kWant && tried < kTry) {
                usleep(kMs * 1000);
                sz = sizeof(Sample);
                if (IOConnectCallStructMethod(newc.conn, 1, NULL, 0, &b, &sz) != KERN_SUCCESS) break;
                clock_gettime(CLOCK_MONOTONIC, &t1);
                tried++;
                lastPerf = b.perfStatus;

                double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
                int64_t dA = (int64_t)(b.aperf - a.aperf);
                int64_t dM = (int64_t)(b.mperf - a.mperf);
                a = b; t0 = t1;           // 坏窗口之后以新核为新基准

                double cap = el * (double)baseHz * 1.1;   // 同核时 ΔMPERF 的上界
                if (dA <= 0 || dM <= 0 || (double)dM > cap) { skipped++; continue; }
                ratios[nR++] = (double)dA / (double)dM;
            }

            if (nR == 0) {
                printf("\n✗ 试了 %d 次全部跨核，本次拿不到可信读数\n", tried);
            } else {
                qsort(ratios, nR, sizeof(double), cmpD);
                double med = ratios[nR / 2];
                double mn = ratios[0], mx = ratios[nR - 1];
                printf("\n同核窗口 %d 个（试 %d 次，跨核作废 %d）\n", nR, tried, skipped);
                printf("区间 %.2f×–%.2f×，中位 %.3f×\n", mn, mx, med);
                printf("→ 实时频率 %.0f MHz（基频 %.0f MHz）\n",
                       baseHz / 1e6 * med, baseHz / 1e6);
                // PERF_STATUS bits[15:8] 是当前请求倍频，单位 100MHz；与上面
                // 用比值算出来的频率互相独立，可作交叉验证
                printf("PERF_STATUS=0x%llx（bits[15:8]=%llu → %llu MHz）\n",
                       (unsigned long long)lastPerf,
                       (unsigned long long)((lastPerf >> 8) & 0xFF),
                       (unsigned long long)(((lastPerf >> 8) & 0xFF) * 100));
            }
        }
    }

    if (!oe) IOServiceClose(oldc.conn);
    if (!ne) IOServiceClose(newc.conn);
    return 0;
}
