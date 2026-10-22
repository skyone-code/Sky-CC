// pwmwake v5.2 — eDP 面板 PWM 模式保持守护（事件驱动，无轮询）
//
// 【v5.2 修复（2026-10-20）：镜像/独显模式盲区】
//   v5.1 的 framebuffer 定位拿「主屏」：镜像+假负载模式下主屏是独显的
//   NVRMFramebuffer（HDMI 假负载），那里没有 eDP 面板的 AUX 通道，
//   DPCD 读必然失败 → 守护所有补针 err=-2 → 睡眠/镜像后面板掉回
//   AUX 模式（0x721=0x0A）无人纠正 → 系统滑条/亮度键「写入成功但
//   物理不变亮」。
//   修法与当年 auxbright v4 builtinfb 完全相同：CGDisplayIsBuiltin()
//   固定拿内建屏 framebuffer（面板永远挂在内建屏上），主屏是谁都行。
//   （DPCD 读写事务代码沿用 auxbright-PWM模式版 v4 的实现，已实测多年。）
//
// 【守护语义（与 v5.1 一致）】
//   事件驱动、零轮询；持有内建屏 framebuffer 服务引用（长连接）：
//     1. 启动首针：立即 ensure 一次，失败则 1s/4s/9s 退避重试
//     2. IODisplayWrangler 兴趣通知（显示电源/modeset 事件）→ 300ms 防抖补针
//     3. 系统睡眠/唤醒（IORegisterForSystemPower）→ 唤醒 2s 后补针
//     4. CGDisplay 重配置回调（登录时 WindowServer modeset 翻转）→ 防抖补针
//
// 【硬件事实备查】
//   DPCD 0x721 bits[1:0]: 00b=PWM / 01b=PRESET / 10b=DPCD(AUX) / 11b=PRODUCT
//   写 0x08 清 bits[1:0] 保留 bit3(FREQ_AUX_SET) → PWM 模式；0x0A 是出厂默认
//
// 用法:
//   pwmwake          守护模式（launchd 常驻，com.user.pwmwake）
//   pwmwake ensure   一次性确保 PWM 模式（App 亮度写入前兜底，同步返回）
//   pwmwake mode     查询并打印当前模式（一次性，不阻塞）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <time.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <ApplicationServices/ApplicationServices.h>

#define DPCD_BL_MODE  0x00721   // BACKLIGHT_MODE_SET
#define BL_MODE_PWM   0x08      // PWM 模式（清 bits[1:0] 保留 bit3）

// ------------------------------------------------------------------ 日志
static void logline(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);
    fprintf(stderr, "[pwmwake %s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

// ------------------------------------------------------------------ framebuffer 定位
// 核心修复：固定拿内建屏（CGDisplayIsBuiltin）——面板永远挂在内建屏上。
// 不能用 CGMainDisplayID：镜像/独显模式下主屏是 NVRMFramebuffer，无 AUX 通道。
static io_service_t get_fb(void) {
    uint32_t n = 0;
    CGGetOnlineDisplayList(0, NULL, &n);
    if (n > 0) {
        CGDirectDisplayID *ids = (CGDirectDisplayID *)calloc(n, sizeof(CGDirectDisplayID));
        CGGetOnlineDisplayList(n, ids, &n);
        for (uint32_t i = 0; i < n; i++) {
            if (CGDisplayIsBuiltin(ids[i])) {
                io_service_t s = CGDisplayIOServicePort(ids[i]);
                if (s != MACH_PORT_NULL) { free(ids); return s; }
            }
        }
        free(ids);
    }
    return CGDisplayIOServicePort(CGMainDisplayID());   // 兜底
}

// ------------------------------------------------------------------ DPCD 事务
// 沿用 auxbright v4 实现：IOI2C DisplayPort Native transaction
static int dpcd_transaction(io_service_t fb, int is_write, uint32_t addr,
                            uint8_t *buf, uint32_t len) {
    io_service_t itf;
    if (IOFBCopyI2CInterfaceForBus(fb, 0, &itf) != KERN_SUCCESS) return kIOReturnNoDevice;
    IOI2CConnectRef c;
    kern_return_t kr = IOI2CInterfaceOpen(itf, kNilOptions, &c);
    IOObjectRelease(itf);
    if (kr != KERN_SUCCESS) return kr;
    IOI2CRequest req;
    memset(&req, 0, sizeof(req));
    if (is_write) {
        req.sendTransactionType = kIOI2CDisplayPortNativeTransactionType;
        req.sendAddress = addr;
        req.sendBuffer = (vm_address_t)(uintptr_t)buf;
        req.sendBytes = len;
        req.replyTransactionType = kIOI2CNoTransactionType;
    } else {
        req.sendTransactionType = kIOI2CNoTransactionType;
        req.replyTransactionType = kIOI2CDisplayPortNativeTransactionType;
        req.replyAddress = addr;
        req.replyBuffer = (vm_address_t)(uintptr_t)buf;
        req.replyBytes = len;
    }
    kr = IOI2CSendRequest(c, kNilOptions, &req);
    int ok = (kr == kIOReturnSuccess && req.result == kIOReturnSuccess);
    IOI2CInterfaceClose(c, kNilOptions);
    return ok ? kIOReturnSuccess : (int)(kr ? kr : req.result);
}

static int panel_mode_read(io_service_t fb, uint8_t *val) {
    uint8_t buf[1] = {0};
    if (dpcd_transaction(fb, 0, DPCD_BL_MODE, buf, 1) != kIOReturnSuccess) return -1;
    *val = buf[0];
    return 0;
}

static int panel_mode_write(io_service_t fb, uint8_t val) {
    uint8_t buf[1] = {val};
    return dpcd_transaction(fb, 1, DPCD_BL_MODE, buf, 1) == kIOReturnSuccess ? 0 : -1;
}

static const char *mode_name(uint8_t v) {
    switch (v & 0x03) {
        case 0: return "PWM";
        case 1: return "PRESET";
        case 2: return "AUX(DPCD)";
        default: return "PRODUCT";
    }
}

// ------------------------------------------------------------------ ensure 核心
// 返回值：0=已是PWM或成功切到PWM；-1=DPCD失败；-2=拿不到内建屏framebuffer
static int ensure_pwm(const char *tag, int verbose) {
    io_service_t fb = get_fb();
    if (fb == MACH_PORT_NULL) {
        if (verbose) logline("失败：%s 拿不到内建屏 framebuffer（err=-2）", tag);
        return -2;
    }
    uint8_t v = 0;
    int r1 = panel_mode_read(fb, &v);
    if (r1 == 0 && (v & 0x03) == 0x00) {
        if (verbose) logline("%s：模式已是 PWM（0x%02X），无需写入", tag, v);
        IOObjectRelease(fb);
        return 0;
    }
    if (r1 != 0) {
        // 读失败时 fb 可能已失效（睡眠中/刚 modeset），重取一次再试
        IOObjectRelease(fb);
        fb = get_fb();
        if (fb == MACH_PORT_NULL) {
            if (verbose) logline("失败：%s DPCD 读失败且重取 framebuffer 失败（err=-2）", tag);
            return -2;
        }
        r1 = panel_mode_read(fb, &v);
        if (r1 != 0) {
            if (verbose) logline("失败：%s DPCD 读失败（err=-1）", tag);
            IOObjectRelease(fb);
            return -1;
        }
    }
    if (panel_mode_write(fb, BL_MODE_PWM) != 0) {
        if (verbose) logline("失败：%s DPCD 写 0x08 失败（err=-1）", tag);
        IOObjectRelease(fb);
        return -1;
    }
    uint8_t v2 = 0;
    panel_mode_read(fb, &v2);
    logline("%s：面板背光模式 0x%02X (%s) -> 0x%02X (%s)，亮度交还 macOS 原生链路",
            tag, v, mode_name(v), v2, mode_name(v2));
    IOObjectRelease(fb);
    return (v2 & 0x03) == 0x00 ? 0 : -1;
}

// ------------------------------------------------------------------ 守护：事件驱动
static CFRunLoopTimerRef g_nudge_timer = NULL;
static io_object_t g_wrangler_notif = 0;
static IONotificationPortRef g_np = NULL;

// 防抖合并补针：事件后 delay 毫秒执行一次，窗口内新事件重置计时
static void nudge_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    ensure_pwm("事件补针", 1);
}

static void schedule_nudge(double delay_sec) {
    if (g_nudge_timer) {
        CFRunLoopTimerSetNextFireDate(g_nudge_timer,
            CFAbsoluteTimeGetCurrent() + delay_sec);
        return;
    }
    g_nudge_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay_sec,
        0, 0, 0, nudge_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), g_nudge_timer, kCFRunLoopDefaultMode);
}

// IODisplayWrangler 通用兴趣通知（显示电源变化 / modeset）
static void wrangler_callback(void *ref, io_service_t service,
                              uint32_t messageType, void *messageArgument) {
    (void)ref; (void)service; (void)messageArgument;
    if (messageType == kIOMessageServicePropertyChange ||
        messageType == kIOMessageServiceBusyStateChange) {
        schedule_nudge(0.3);
    }
}

// 系统电源回调：睡眠放行，唤醒 2 秒后补针（等显示栈稳定）
static void power_callback(void *ref, io_service_t service,
                           natural_t messageType, void *messageArgument) {
    (void)ref; (void)service;
    switch (messageType) {
        case kIOMessageSystemWillSleep:
            IOAllowPowerChange(kIOMainPortDefault, (long)messageArgument);
            break;
        case kIOMessageSystemHasPoweredOn:
            logline("系统唤醒，2 秒后补针");
            schedule_nudge(2.0);
            break;
        default:
            break;
    }
}

// CGDisplay 重配置回调：登录时 WindowServer 接管会触发 modeset 翻转
static void display_reconfig_callback(CGDirectDisplayID display,
                                      CGDisplayChangeSummaryFlags flags,
                                      void *userInfo) {
    (void)display; (void)userInfo;
    if (flags & kCGDisplayBeginConfigurationFlag) return;   // 等事务结束
    if (flags & (kCGDisplaySetModeFlag | kCGDisplayAddFlag |
                 kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                 kCGDisplayDisabledFlag | kCGDisplayMirrorFlag |
                 kCGDisplayUnMirrorFlag)) {
        schedule_nudge(0.4);
    }
}

// 启动首针退避重试：0s / 1s / 4s / 9s
static int g_boot_retries = 0;
static void boot_retry_fired(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    int rc = ensure_pwm("启动补针", 1);
    g_boot_retries++;
    if (rc != 0 && g_boot_retries < 3) {
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + (g_boot_retries == 1 ? 3.0 : 5.0),
            0, 0, 0, boot_retry_fired, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    } else if (rc != 0) {
        logline("启动补针连续失败 3 次，转入事件驱动等待（显示/唤醒事件会再次补针）");
    }
}

static int cmd_daemon(void) {
    logline("pwmwake v5.2 守护启动（内建屏固定定位 + 事件驱动，无轮询）");

    // 首针
    int rc = ensure_pwm("启动首针", 1);
    if (rc != 0) {
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1.0,
            0, 0, 0, boot_retry_fired, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    }

    // IODisplayWrangler 兴趣通知
    io_service_t wrangler = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"));
    if (wrangler != MACH_PORT_NULL) {
        g_np = IONotificationPortCreate(kIOMainPortDefault);
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(g_np),
                           kCFRunLoopDefaultMode);
        if (IOServiceAddInterestNotification(g_np, wrangler, kIOGeneralInterest,
                                             wrangler_callback, NULL,
                                             &g_wrangler_notif) == KERN_SUCCESS) {
            logline("已注册 IODisplayWrangler 兴趣通知");
        }
    } else {
        logline("警告：找不到 IODisplayWrangler，显示事件补针不可用");
    }

    // 系统电源通知（睡眠/唤醒）
    io_connect_t power_port;
    io_object_t power_notif;
    IONotificationPortRef power_np = IONotificationPortCreate(kIOMainPortDefault);
    power_port = IORegisterForSystemPower(NULL, &power_np, power_callback, &power_notif);
    if (power_port != MACH_PORT_NULL) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(power_np),
                           kCFRunLoopDefaultMode);
        logline("已注册系统电源通知（睡眠/唤醒）");
    }

    // CGDisplay 重配置回调（登录 modeset / 显示器插拔 / 镜像开关）
    if (CGDisplayRegisterReconfigurationCallback(display_reconfig_callback, NULL) == kCGErrorSuccess) {
        logline("已注册 CGDisplay 重配置回调（登录 modeset 补针）");
    }

    CFRunLoopRun();   // 事件驱动，零轮询
    return 0;
}

// ------------------------------------------------------------------ 命令
static int cmd_ensure(void) {
    return ensure_pwm("ensure", 1) == 0 ? 0 : 1;
}

static int cmd_mode(void) {
    io_service_t fb = get_fb();
    if (fb == MACH_PORT_NULL) { fprintf(stderr, "E: 拿不到内建屏 framebuffer\n"); return 1; }
    uint8_t v = 0;
    int rc = panel_mode_read(fb, &v);
    IOObjectRelease(fb);
    if (rc != 0) { fprintf(stderr, "E: DPCD 读失败\n"); return 1; }
    printf("背光模式: 0x721 = 0x%02X (%s)\n", v, mode_name(v));
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc == 1) return cmd_daemon();
    if (argc >= 2) {
        if (!strcmp(argv[1], "ensure")) return cmd_ensure();
        if (!strcmp(argv[1], "mode"))   return cmd_mode();
    }
    printf("用法: pwmwake [守护] | ensure | mode\n");
    return 0;
}
