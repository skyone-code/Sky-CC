/*
 * gpu-router.c — 全局 GPU 路由（Metal 默认设备重定向）
 *
 * 注入到进程后，把 MTLCreateSystemDefaultDevice 换成「独显」，效果等价于 Windows
 * 上 NVIDIA 控制面板的「首选图形处理器 = 高性能 NVIDIA 处理器」。
 *
 * 为什么必须注入：默认 Metal 设备由 SkyLight/WindowServer 按「显示拥有者」决定
 * （MTLCreateSystemDefaultDevice → CGSCreateDefaultMetalDevice），内屏挂在 Intel 上，
 * 客户端没有 API 能改。interpose 是唯一在用户态可行的入口。
 *
 * 装载方式（由 Mac 控制台写入，不在这里做）：
 *   launchctl setenv DYLD_INSERT_LIBRARIES <本 dylib 路径>
 * 之后启动的 app 全部继承；不需要注入的进程由下面的策略表挡掉。
 *
 * 策略写在 ~/Library/Application Support/SkyCC/gpu-policy.json：
 *   {"mode": "whitelist", "include": ["com.foo.bar", ...]}
 *
 *   mode=whitelist → 白名单模式：include 里的 bundle id 走独显，
 *                    其余一律保持 Apple 的答案（2026-11-24 起唯一模式；
 *                    旧的全局 dgpu / exclude 字段废弃，读到旧文件一律不接管，
 *                    等 app 下次写策略时自然覆盖成新格式）
 *
 * 安全：com.apple.* 一律不接管。系统进程本来就带 library validation、注入也加载不进来，
 * 但有些 com.apple.* 的工具进程没有，所以这一条是显式保护，不靠运气。
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <os/log.h>

static os_log_t lg;

/* 策略在构造函数里读一次就固定：app 跑起来之后改设置，下一次启动才生效。
   每次 dispatch 都去读盘会让「一次 launch 一次 syscall」变成热路径开销，
   而这个值在进程生命周期里不该变。 */
static int g_mode = 0;            /* 1 = 本进程被白名单命中，接管独显；0 = 不干预 */
static int g_have_policy;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static NSString *policyPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    return [[dirs[0] stringByAppendingPathComponent:@"SkyCC"]
            stringByAppendingPathComponent:@"gpu-policy.json"];
}

static void loadPolicy(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

    /* 环境变量是最高优先级的开关：OPTIMUS_LAUNCH=0 让单次启动退回 Apple 默认，
       用于排查「是不是注入导致的」这类问题。 */
    const char *off = getenv("OPTIMUS_LAUNCH");
    if (off && strcmp(off, "0") == 0) { g_mode = 0; g_have_policy = 1; return; }

    /* 结构性保护：系统进程与自身永不接管（白名单也救不回来）。 */
    if (bundleID.length == 0 ||
        [bundleID hasPrefix:@"com.apple."] ||
        [bundleID isEqualToString:@"com.skycc.console"]) {
        g_mode = 0; g_have_policy = 1; return;
    }

    /* 白名单模式（2026-11-24 起）：只有 include 里的 bundle id 才接管。
       默认 0：文件缺失 / 格式不对 / 旧版字段（dgpu·exclude 时代）→ 一律不干预，
       行为等同未注入；app 侧写回新格式后按名单放行。 */
    g_mode = 0;
    g_have_policy = 1;

    NSString *p = policyPath();
    if (!p) return;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![j isKindOfClass:[NSDictionary class]]) return;

    NSString *m = j[@"mode"];
    if (![m isKindOfClass:[NSString class]] || ![m isEqualToString:@"whitelist"]) return;

    NSArray *inc = j[@"include"];
    if (![inc isKindOfClass:[NSArray class]]) return;
    for (id v in inc)
        if ([v isKindOfClass:[NSString class]] && [v isEqualToString:bundleID]) {
            g_mode = 1;
            return;
        }
}

/* 设备列表缓存：进程的 Metal 设备来自 IOAccelDevice 注册，一旦注册齐全就不再变化。
   MTLCopyAllDevices 持 Metal 全局锁（dispatch barrier sync），且枚举快照会拷贝设备数组——
   如果任何进程的 NVMTLDevice 还在初始化中，枚举会撞上半成品对象直接 SIGSEGV
   （实测 QQLive 2026-11-23 两次崩溃都是这个栈），同时全局锁会让 WindowServer
   合成停顿，表现为整屏冻结 <1s。所以：每次调用都枚举是错误的，缓存起来。
   空结果不缓存——驱动可能还没注册完，下一次调用再试。 */
static NSArray<id<MTLDevice>> *g_devices;
static pthread_mutex_t g_dev_lock = PTHREAD_MUTEX_INITIALIZER;

static NSArray<id<MTLDevice>> *deviceList(void) {
    pthread_mutex_lock(&g_dev_lock);
    NSArray *cached = g_devices;
    pthread_mutex_unlock(&g_dev_lock);
    if (cached.count > 0) return cached;

    NSArray *fresh = MTLCopyAllDevices();
    if (fresh.count > 0) {
        pthread_mutex_lock(&g_dev_lock);
        if (g_devices.count == 0) g_devices = fresh;
        pthread_mutex_unlock(&g_dev_lock);
        return g_devices.count > 0 ? g_devices : fresh;
    }
    return fresh;                                     /* 空：下次调用再试 */
}

static id<MTLDevice> pickNvidia(void) {
    id<MTLDevice> best = nil;
    for (id<MTLDevice> d in deviceList()) {
        if (d.isLowPower) continue;                       /* 核显 */
        if (!best || d.registryID != best.registryID) best = d;
    }
    return best;                                          /* nil = 保持 Apple 的答案 */
}

static id<MTLDevice> pickIgpu(void) {
    NSArray *all = deviceList();
    for (id<MTLDevice> d in all)
        if (d.isLowPower) return d;
    return all.firstObject;
}

/* 注意：interpose 是全局的，在本函数里再调 MTLCreateSystemDefaultDevice 会递归，
   所以「原实现」只能用「低功耗设备」近似（内屏挂在 Intel 上，就是它）。 */
static id<MTLDevice> routed_MTLCreateSystemDefaultDevice(void) {
    pthread_once(&g_once, loadPolicy);

    if (!g_mode) return pickIgpu();

    id<MTLDevice> nv = pickNvidia();
    if (!nv) {
        os_log(lg, "gpu-router: no discrete device, keeping Apple's default");
        return pickIgpu();
    }
    static int said;
    if (!said++)
        os_log(lg, "gpu-router: %{public}@ (registryID %llu) serves as default device",
               nv.name, (unsigned long long)nv.registryID);
    return nv;
}

struct interposer { const void *replacement; const void *replacee; } __attribute__((aligned(16)));

__attribute__((used))
static const struct interposer interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)routed_MTLCreateSystemDefaultDevice, (const void *)MTLCreateSystemDefaultDevice },
};

__attribute__((constructor))
static void init(void) {
    lg = os_log_create("com.skycc.gpu-router", "route");
    if (getenv("MC_GPU_ROUTER_DEBUG"))
        os_log(lg, "gpu-router: injected into %{public}s (%{public}@)",
               getprogname() ?: "?", [[NSBundle mainBundle] bundleIdentifier] ?: @"no-bundle");
}
