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
 *   {"mode": "dgpu" | "igpu" | "auto", "exclude": ["com.foo.bar", ...]}
 *
 *   mode=dgpu  → 默认给独显（Windows「高性能」）
 *   mode=igpu  → 一律给核显（Windows「节能」）
 *   mode=auto  → 不干预，返回 Apple 的答案
 *   exclude    → 名单里的 bundle id 一律走核显（per-app 例外）
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
static int g_mode = 1;            /* 1 = dgpu, 0 = igpu/auto */
static int g_have_policy;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static NSString *policyPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    return [[dirs[0] stringByAppendingPathComponent:@"SkyCC"]
            stringByAppendingPathComponent:@"gpu-policy.json"];
}

/* 返回 YES 表示「这个进程不该被接管」 */
static BOOL isExcluded(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    if ([bundleID hasPrefix:@"com.apple."]) return YES;      /* 系统进程，永不动 */
    if ([bundleID isEqualToString:@"com.skycc.console"]) return YES;

    NSString *p = policyPath();
    if (!p) return NO;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return NO;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![j isKindOfClass:[NSDictionary class]]) return NO;
    NSArray *ex = j[@"exclude"];
    if ([ex isKindOfClass:[NSArray class]]) {
        for (id v in ex)
            if ([v isKindOfClass:[NSString class]] && [v isEqualToString:bundleID]) return YES;
    }
    return NO;
}

static void loadPolicy(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

    /* 环境变量是最高优先级的开关：OPTIMUS_LAUNCH=0 让单次启动退回 Apple 默认，
       用于排查「是不是注入导致的」这类问题。 */
    const char *off = getenv("OPTIMUS_LAUNCH");
    if (off && strcmp(off, "0") == 0) { g_mode = 0; g_have_policy = 1; return; }

    if (isExcluded(bundleID)) { g_mode = 0; g_have_policy = 1; return; }

    /* 后台进程过滤：被路由的每个进程首次摸 Metal 都要付 ~390ms 的 Mesa 带起
       （dlopen libvulkan_nouveau，实测 287-407ms，静态初始化器主导）。LaunchAgents、
       XPC 服务、各种系统辅助进程也走独显的话，系统每次孵化它们整屏就顿一下，
       而它们根本不做需要独显的工作。用户应用住在 /Applications（或 ~/Applications）
       下的 .app 包里（Electron 的 Helper.app 也算）；其余一律保持 Apple 默认（核显）。
       OPTIMUS_ALLOW_ANY_PATH=1 可关掉这个过滤。 */
    if (!getenv("OPTIMUS_ALLOW_ANY_PATH")) {
        NSString *bp = [[NSBundle mainBundle] bundlePath];
        BOOL userApp = ([bp hasPrefix:@"/Applications/"] ||
                        [bp hasPrefix:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications/"]]) &&
                       [bp hasSuffix:@".app"];
        if (!userApp) { g_mode = 0; g_have_policy = 1; return; }
    }

    g_mode = 1;                       /* 文件读不到时的默认：结构上「注入了就是要独显」 */
    NSString *p = policyPath();
    if (!p) { g_have_policy = 1; return; }
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) { g_have_policy = 1; return; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if ([j isKindOfClass:[NSDictionary class]]) {
        NSString *m = j[@"mode"];
        if ([m isKindOfClass:[NSString class]]) {
            if ([m isEqualToString:@"igpu"] || [m isEqualToString:@"auto"]) g_mode = 0;
            else if ([m isEqualToString:@"dgpu"]) g_mode = 1;
        }
    }
    g_have_policy = 1;
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
