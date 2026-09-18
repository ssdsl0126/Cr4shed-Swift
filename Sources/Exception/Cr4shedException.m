#import "Cr4shedCommon.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <dlfcn.h>
#include <stdlib.h>

static NSUncaughtExceptionHandler *oldHandler = NULL;

static unsigned long CR4GetImageVersion(uint32_t img) {
    if (img >= _dyld_image_count()) return 0;
    const struct mach_header *header = _dyld_get_image_header(img);
    if (!header) return 0;
    BOOL is64bit = header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64;
    uintptr_t cursor = (uintptr_t)header + (is64bit ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    const struct segment_command *segmentCommand = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += segmentCommand->cmdsize) {
        segmentCommand = (const struct segment_command *)cursor;
        if (segmentCommand->cmd == LC_ID_DYLIB) {
            const struct dylib_command *dylibCommand = (const struct dylib_command *)segmentCommand;
            return dylibCommand->dylib.current_version;
        }
    }
    return 0;
}

static void CR4CreateCrashLog(NSString *specialisedInfo, NSMutableDictionary *extraInfo) {
    if (CR4IsProcessBlacklisted(nil)) return;
    CR4MarkProcessAsHandled();

    NSDate *now = [NSDate date];
    NSString *dateString = CR4StringFromDate(now, CR4DateFormatPretty);
    NSString *processID = [NSBundle mainBundle].bundleIdentifier;
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSString *device = [NSString stringWithFormat:@"%@, iOS %@", CR4DeviceName(), CR4DeviceVersion()];
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *versionString = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: bundle.infoDictionary[@"CFBundleVersion"];

    NSMutableString *errorMessage = [NSMutableString stringWithFormat:
        @"Date: %@\nProcess: %@\nBundle id: %@\nDevice: %@\n",
        dateString, processName, processID, device];
    if (versionString.length) [errorMessage appendFormat:@"Bundle version: %@\n", versionString];
    [errorMessage appendFormat:@"\n%@\n\nLoaded images:\n", specialisedInfo];

    uint32_t image_cnt = _dyld_image_count();
    for (unsigned int i = 0; i < image_cnt; i++) {
        [errorMessage appendFormat:@"%u: %s (Version: %lu)\n", i, _dyld_get_image_name(i), CR4GetImageVersion(i)];
    }

    if (!extraInfo) extraInfo = [NSMutableDictionary new];
    [extraInfo addEntriesFromDictionary:@{
        @"ProcessName": processName ?: @"",
        @"ProcessBundleID": processID ?: @""
    }];
    errorMessage = [CR4AddInfoToLog(errorMessage, [extraInfo copy]) mutableCopy];

    NSString *filenameDateStr = CR4StringFromDate(now, CR4DateFormatFilename);
    NSString *filename = [NSString stringWithFormat:@"%@@%@", processName, filenameDateStr];
    CR4WriteLog(errorMessage, filename);
}

static void CR4CreateNSExceptionLog(NSException *e) {
    if ([e.reason containsString:@"optimistic locking failure"]) return;
    if ([e.reason containsString:@"This NSPersistentStoreCoordinator has no persistent stores"]) return;

    NSString *culprit = CR4DetermineCulpritWithAddresses(e.callStackSymbols, e.callStackReturnAddresses);
    if (!culprit || [culprit isEqualToString:@"Unknown"]) {
        NSArray<NSString *> *allTweaks = CR4GetAllKnownTweakNames();
        for (NSString *tweak in allTweaks) {
            NSString *stem = [tweak stringByDeletingPathExtension];
            if ([e.reason rangeOfString:tweak options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [e.reason rangeOfString:stem options:NSCaseInsensitiveSearch].location != NSNotFound) {
                culprit = tweak;
                break;
            }
        }
    }
    NSString *stackSymbols = [CR4SymbolicatedException(e) componentsJoinedByString:@"\n"];
    NSMutableString *info = [NSMutableString stringWithFormat:
        @"Exception type: %@\nReason: %@\nCulprit: %@\n\n",
        e.name, e.reason, culprit];

    NSDictionary *excUserInfo = e.userInfo;
    if (excUserInfo.allKeys.count) {
        NSMutableString *userInfoStr = [@"User info:\n" mutableCopy];
        for (NSString *key in excUserInfo.allKeys) {
            NSString *objStr = [excUserInfo[key] description];
            if ([objStr componentsSeparatedByString:@"\n"].count > 1)
                objStr = [@"\n" stringByAppendingString:objStr];
            if (!objStr.length) objStr = @"N/A";
            [userInfoStr appendFormat:@"%@: %@\n", key, objStr];
        }
        [userInfoStr appendString:@"\n"];
        [info appendString:userInfoStr];
    }
    [info appendFormat:@"Call stack:\n%@", stackSymbols];

    NSMutableDictionary *extraInfo = [@{
        @"Culprit": culprit ?: @"Unknown",
        @"NSExceptionReason": e.reason ?: @""
    } mutableCopy];
    CR4CreateCrashLog([info copy], extraInfo);
}

static void CR4UnhandledExceptionHandler(NSException *e) {
    @autoreleasepool {
        NSLog(@"[Cr4shedException] Handling uncaught NSException: %@ (reason: %@) in %@", e.name, e.reason, [[NSProcessInfo processInfo] processName]);
        static BOOL hasCrashed = NO;
        if (hasCrashed) exit(EXIT_FAILURE);
        hasCrashed = YES;
        @try {
            CR4CreateNSExceptionLog(e);
        } @catch (NSException *ex) {
            NSLog(@"[Cr4shedException] Error creating NSException log: %@", ex);
            exit(EXIT_FAILURE);
        }
        if (oldHandler) oldHandler(e);
    }
}

__attribute__((constructor))
static void CR4ExceptionInit(void) {
    @autoreleasepool {
        NSString *procName = [[NSProcessInfo processInfo] processName];
        if (CR4IsHardBlacklisted(procName)) return;
        
        // 直接安全注册未捕获异常处理，不再使用 MSHookFunction 改写 Foundation 共享缓存
        // 彻底根除因改写 12 字节微型函数破坏临近指令引起的全局 CPU 飙升与死锁
        oldHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&CR4UnhandledExceptionHandler);
    }
}
