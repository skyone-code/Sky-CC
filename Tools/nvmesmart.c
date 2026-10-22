// nvmesmart —— 按控制器枚举所有 NVMe 盘的 SMART（log page 0x02）
//
// 为什么需要它：随包的 nvmetemp 是单盘工具（IOServiceGetMatchingService 取首个匹配），
// 本机两块 NVMe（SKHynix 512G + OV 1TB）只有一块能出数，另一块永远「未覆盖」。
//
// 用法（无参数）：
//   nvmesmart            输出 JSON：{"ok":true,"disks":[{"bsd":"disk0",...}]}
//   nvmesmart --text     输出人读文本（排障用）
//
// 依赖 SDK 里的 IOKit/storage/nvme/NVMeSMARTLibExternal.h（Apple 公开头，
// 提供 kIONVMeSMARTUserClientTypeID / IONVMeSMARTInterface 的精确布局）。
//
// 编译：clang -O2 -framework IOKit -framework CoreFoundation -o nvmesmart nvmesmart.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

#define MAX_DISKS 16

typedef struct {
    char bsd[32];
    char model[64];
    int  ok;
    NVMeSMARTData data;
} DiskSMART;

// 在服务及其子节点（最多 3 层）里找 "BSD Name"
static int find_bsd_name(io_registry_entry_t svc, char *out, size_t n, int depth)
{
    out[0] = 0;
    CFTypeRef prop = IORegistryEntryCreateCFProperty(svc, CFSTR("BSD Name"),
                                                     kCFAllocatorDefault, 0);
    if (prop) {
        if (CFGetTypeID(prop) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)prop, out, (CFIndex)n, kCFStringEncodingUTF8);
        }
        CFRelease(prop);
        if (out[0]) return 1;
    }
    if (depth <= 0) return 0;

    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(svc, kIOServicePlane, &it) != kIOReturnSuccess) return 0;
    io_object_t child;
    int found = 0;
    while (!found && (child = IOIteratorNext(it))) {
        found = find_bsd_name(child, out, n, depth - 1);
        IOObjectRelease(child);
    }
    IOObjectRelease(it);
    return found;
}

// 取型号（控制器节点上的 "Model Number"）
static void find_model(io_registry_entry_t svc, char *out, size_t n)
{
    out[0] = 0;
    io_registry_entry_t cur = svc;
    int depth = 0;
    while (cur && depth < 5 && !out[0]) {
        CFTypeRef p = IORegistryEntryCreateCFProperty(cur, CFSTR("Model Number"),
                                                      kCFAllocatorDefault, 0);
        if (p) {
            if (CFGetTypeID(p) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)p, out, (CFIndex)n, kCFStringEncodingUTF8);
            }
            CFRelease(p);
        }
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) != kIOReturnSuccess) break;
        if (cur != svc) IOObjectRelease(cur);
        cur = parent;
        depth++;
    }
    if (cur && cur != svc) IOObjectRelease(cur);
}

static int read_smart(io_service_t svc, NVMeSMARTData *data)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(svc,
                                                    kIONVMeSMARTUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plugin, &score);
    if (kr != kIOReturnSuccess || plugin == NULL) return 0;

    IONVMeSMARTInterface **intf = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin,
                                           CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                                           (LPVOID *)&intf);
    int ok = 0;
    if (hr == S_OK && intf) {
        memset(data, 0, sizeof(*data));
        kr = (*intf)->SMARTReadData(intf, data);
        ok = (kr == kIOReturnSuccess);
        (*intf)->Release(intf);
    }
    IODestroyPlugInInterface(plugin);
    return ok;
}

static void json_escape(const char *s, char *out, size_t n)
{
    size_t j = 0;
    for (size_t i = 0; s[i] && j + 2 < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; }
        else if (c < 0x20) { out[j++] = ' '; }
        else out[j++] = (char)c;
    }
    out[j] = 0;
}

int main(int argc, char **argv)
{
    int text = (argc > 1 && strcmp(argv[1], "--text") == 0);

    // 按 Apple 文档：带 "NVMe SMART Capable" 属性的服务就是能读 SMART 的设备节点
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                             &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(match, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);

    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);

    DiskSMART found[MAX_DISKS];
    int count = 0;

    if (kr == kIOReturnSuccess) {
        io_object_t svc;
        while ((svc = IOIteratorNext(iter)) && count < MAX_DISKS) {
            char bsd[32] = "";
            if (!find_bsd_name(svc, bsd, sizeof(bsd), 3)) { IOObjectRelease(svc); continue; }
            // 只要整盘（disk0），跳过分区（disk0s2）与网卡（en0/en1 也带这个属性）
            if (strncmp(bsd, "disk", 4) != 0) { IOObjectRelease(svc); continue; }
            // 只收整盘（disk0），跳过分区（disk0s2）
            if (strchr(bsd, 's') && strncmp(bsd, "disk", 4) == 0) {
                const char *p = bsd + 4;
                while (*p >= '0' && *p <= '9') { p++; }
                if (*p == 's') { IOObjectRelease(svc); continue; }
            }
            // 去重（同一块盘可能有多层节点带 BSD Name）
            int dup = 0;
            for (int i = 0; i < count; i++) if (strcmp(found[i].bsd, bsd) == 0) dup = 1;
            if (dup) { IOObjectRelease(svc); continue; }

            DiskSMART *d = &found[count];
            memset(d, 0, sizeof(*d));
            strncpy(d->bsd, bsd, sizeof(d->bsd) - 1);
            find_model(svc, d->model, sizeof(d->model));
            d->ok = read_smart(svc, &d->data);
            // 读不到又连型号都取不到（磁盘映像 / APFS 合成卷这类伪设备）直接丢掉
            if (!d->ok && d->model[0] == 0) { IOObjectRelease(svc); continue; }
            count++;
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }

    if (text) {
        if (count == 0) { printf("没有找到 NVMe SMART 设备\n"); return 1; }
        for (int i = 0; i < count; i++) {
            DiskSMART *d = &found[i];
            if (!d->ok) { printf("%-6s %-32s SMART 读取失败\n", d->bsd, d->model); continue; }
            printf("%-6s %-32s %d°C  spare=%d%%  used=%d%%  read=%llu  write=%llu\n",
                   d->bsd, d->model, (int)d->data.TEMPERATURE - 273,
                   d->data.AVAILABLE_SPARE, d->data.PERCENTAGE_USED,
                   (unsigned long long)d->data.DATA_UNITS_READ[0],
                   (unsigned long long)d->data.DATA_UNITS_WRITTEN[0]);
        }
        return 0;
    }

    printf("{\"ok\":%s,\"disks\":[", count > 0 ? "true" : "false");
    for (int i = 0; i < count; i++) {
        DiskSMART *d = &found[i];
        char model[128];
        json_escape(d->model, model, sizeof(model));
        if (i) printf(",");
        if (d->ok) {
            printf("{\"bsd\":\"%s\",\"model\":\"%s\",\"ok\":true,"
                   "\"temperature_c\":%d,\"available_spare\":%d,\"available_spare_threshold\":%d,"
                   "\"percentage_used\":%d,\"critical_warning\":%d,"
                   "\"data_units_read\":%llu,\"data_units_written\":%llu,"
                   "\"host_read_commands\":%llu,\"host_write_commands\":%llu,"
                   "\"power_cycles\":%llu,\"power_on_hours\":%llu,"
                   "\"unsafe_shutdowns\":%llu,\"media_errors\":%llu}",
                   d->bsd, model,
                   (int)d->data.TEMPERATURE - 273,
                   d->data.AVAILABLE_SPARE, d->data.AVAILABLE_SPARE_THRESHOLD,
                   d->data.PERCENTAGE_USED, d->data.CRITICAL_WARNING,
                   (unsigned long long)d->data.DATA_UNITS_READ[0],
                   (unsigned long long)d->data.DATA_UNITS_WRITTEN[0],
                   (unsigned long long)d->data.HOST_READ_COMMANDS[0],
                   (unsigned long long)d->data.HOST_WRITE_COMMANDS[0],
                   (unsigned long long)d->data.POWER_CYCLES[0],
                   (unsigned long long)d->data.POWER_ON_HOURS[0],
                   (unsigned long long)d->data.UNSAFE_SHUTDOWNS[0],
                   (unsigned long long)d->data.MEDIA_ERRORS[0]);
        } else {
            printf("{\"bsd\":\"%s\",\"model\":\"%s\",\"ok\":false}", d->bsd, model);
        }
    }
    printf("]}\n");
    return count > 0 ? 0 : 1;
}
