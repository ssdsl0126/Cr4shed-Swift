#ifndef CR4_REPORT_CRASH_CONTROL_H
#define CR4_REPORT_CRASH_CONTROL_H

#include <stdbool.h>
#include <sys/types.h>
#import <Foundation/Foundation.h>

/// 检查注入框架使用的安全模式环境变量和标记文件。
bool CR4IsSafeModeActive(void);

/// 返回当前 ReportCrash PID；未运行时返回 0。
pid_t CR4FindReportCrashPID(void);

/// 验证指定 PID 当前是否属于 ReportCrash。
bool CR4IsReportCrashPID(pid_t pid);

/// 通过系统 launchd job 启动 ReportCrash；返回确认存活的 PID，失败时返回 0 并写入状态码。
pid_t CR4StartReportCrash(int *_Nullable launchStatus);

#endif
