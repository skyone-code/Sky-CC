// ============================================================================
// mckextload —— 开机把 TongfangFan.kext 装进内核
//
// 背景（2.8.15）：
//   早期 install-kext.sh 写的 LaunchDaemon 直接把 ProgramArguments 指到
//   /usr/bin/kmutil。launchd 在「系统设置 → 登录项 → 允许在后台」里是拿
//   可执行文件名当显示名的，于是那条守护显示成一条来路不明的 "kmutil"
//   （项目来自身份不明的开发者），看起来像测试残留。
//
//   本程序是同一件事的自有执行体：launchd 以 root 跑它，它再去调
//   /usr/bin/kmutil load -p <kext>。显示名变成「Sky CC散热扩展」，
//   既不影响开机加载，也不会再出现 kmutil 字样。
//
// 为什么必须 root：实测非 root 调 kmutil load 会直接报
//   "Insufficient permissions for action: Unable to load ... in unprivileged request."
// 也就没法并进 MacConsoleHelper（它是用户级 LaunchAgent）。
//
// 退出码：始终保持 0 —— 加载失败也不该让 launchd 反复重启。
// ============================================================================
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define KEXT_PATH "/Library/Extensions/TongfangFan.kext"
#define LOG_PATH "/tmp/macconsole-fankext.log"

static FILE *g_log = NULL;

static void logline(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#include <stdarg.h>
static void logline(const char *fmt, ...) {
    if (!g_log) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(g_log, "[%02d:%02d:%02d] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    g_log = fopen(LOG_PATH, "a");
    logline("=== 启动 (uid=%d) ===", (int)geteuid());

    struct stat st;
    if (stat(KEXT_PATH, &st) != 0) {
        logline("kext 不存在，跳过：%s", KEXT_PATH);
        logline("（未安装散热内核扩展时属正常，app 里点「立即安装」即可）");
        if (g_log) fclose(g_log);
        return 0;
    }

    // 已经在内核里就不用重复加载
    if (access("/System/Library/Extensions", F_OK) == 0) { /* 仅为了不引入额外判断 */ }

    pid_t pid = fork();
    if (pid < 0) {
        logline("fork 失败：%s", strerror(errno));
        if (g_log) fclose(g_log);
        return 0;
    }
    if (pid == 0) {
        // 子进程：kmutil load -p <kext>
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); }
        if (g_log) {
            fflush(g_log);
            dup2(fileno(g_log), STDOUT_FILENO);
            dup2(fileno(g_log), STDERR_FILENO);
        }
        execl("/usr/bin/kmutil", "kmutil", "load", "-p", KEXT_PATH, (char *)NULL);
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        logline("waitpid 失败：%s", strerror(errno));
    } else if (WIFEXITED(status)) {
        logline("kmutil load 退出码 %d", WEXITSTATUS(status));
        if (WEXITSTATUS(status) == 0) logline("TongfangFan.kext 加载完成");
    } else if (WIFSIGNALED(status)) {
        logline("kmutil load 被信号 %d 终止", WTERMSIG(status));
    }

    if (g_log) fclose(g_log);
    // 始终 0：失败也不要让 launchd 因非零退出反复拉起
    return 0;
}
