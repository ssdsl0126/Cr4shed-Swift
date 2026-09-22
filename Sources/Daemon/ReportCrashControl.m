#import "ReportCrashControl.h"
#import "Cr4shedCommon.h"

#include <errno.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// libproc 在 iOS 上由 libSystem 导出，但新 SDK 不再附带公开头文件。
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

#define CR4_PROC_ALL_PIDS 1
#define CR4_PROC_NAME_BUFFER_SIZE 4096

static bool CR4EnvironmentFlagEnabled(const char *name) {
    const char *value = getenv(name);
    if (!value) return false;
    return strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 || strcasecmp(value, "yes") == 0;
}

bool CR4IsSafeModeActive(void) {
    if (CR4EnvironmentFlagEnabled("_SafeMode") ||
        CR4EnvironmentFlagEnabled("_MSSafeMode") ||
        CR4EnvironmentFlagEnabled("DISABLE_TWEAKS")) {
        return true;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    if ([manager fileExistsAtPath:@"/var/mobile/.eksafemode"] ||
        [manager fileExistsAtPath:@"/private/var/mobile/.eksafemode"]) {
        return true;
    }

    NSString *dopamineMarker = CR4JBRootPath(@"/basebin/.safe_mode");
    return dopamineMarker.length && [manager fileExistsAtPath:dopamineMarker];
}

bool CR4IsReportCrashPID(pid_t pid) {
    if (pid <= 0) return false;
    char name[CR4_PROC_NAME_BUFFER_SIZE] = {0};
    int length = proc_name(pid, name, sizeof(name));
    return length > 0 && strcmp(name, "ReportCrash") == 0;
}

pid_t CR4FindReportCrashPID(void) {
    int byteCount = proc_listpids(CR4_PROC_ALL_PIDS, 0, NULL, 0);
    if (byteCount <= 0) return 0;

    // 进程可能在两次调用之间增加，预留一小段空间避免截断尾部。
    size_t capacity = (size_t)byteCount + 64 * sizeof(pid_t);
    pid_t *pids = calloc(1, capacity);
    if (!pids) return 0;

    int written = proc_listpids(CR4_PROC_ALL_PIDS, 0, pids, (int)capacity);
    size_t count = written > 0 ? (size_t)written / sizeof(pid_t) : 0;
    pid_t result = 0;
    for (size_t index = 0; index < count; index++) {
        if (CR4IsReportCrashPID(pids[index])) {
            result = pids[index];
            break;
        }
    }
    free(pids);
    return result;
}

static int CR4RunLaunchctl(const char *launchctl, char *const arguments[]) {
    pid_t child = 0;
    int spawnResult = posix_spawn(&child, launchctl, NULL, NULL, arguments, environ);
    if (spawnResult != 0) return spawnResult;

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return errno;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return ECHILD;
}

static pid_t CR4WaitForReportCrash(void) {
    // launchctl 退出后进程建立仍可能稍有延迟，短时间轮询只发生在 daemon 启动阶段。
    for (unsigned int attempt = 0; attempt < 15; attempt++) {
        pid_t pid = CR4FindReportCrashPID();
        if (pid > 0) return pid;
        usleep(100000);
    }
    return 0;
}

pid_t CR4StartReportCrash(int *launchStatus) {
    if (launchStatus) *launchStatus = 0;

    pid_t existingPID = CR4FindReportCrashPID();
    if (existingPID > 0) return existingPID;

    // rootless SSH 中的 launchctl 来自 jailbreak root，而不是系统 /bin。
    NSString *launchctlPath = CR4JBRootPath(@"/usr/bin/launchctl");
    const char *launchctl = launchctlPath.fileSystemRepresentation;
    if (!launchctlPath.length || !launchctl || access(launchctl, X_OK) != 0) {
        CR4DebugLog(@"[cr4shedd] launchctl executable not found at %@", launchctlPath ?: @"(null)");
        if (launchStatus) *launchStatus = ENOENT;
        return 0;
    }

    char *const arguments[] = {
        (char *)launchctl,
        (char *)"start",
        (char *)"com.apple.ReportCrash",
        NULL
    };
    CR4DebugLog(@"[cr4shedd] Executing: %@ start com.apple.ReportCrash", launchctlPath);
    int status = CR4RunLaunchctl(launchctl, arguments);
    pid_t pid = CR4WaitForReportCrash();
    CR4DebugLog(@"[cr4shedd] launchctl path=%@ returned status=%d, ReportCrash PID=%d", launchctlPath, status, pid);

    if (launchStatus) *launchStatus = pid > 0 ? status : (status != 0 ? status : ETIMEDOUT);
    return pid;
}
