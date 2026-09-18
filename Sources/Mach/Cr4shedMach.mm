#import "Cr4shedCommon.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/arm/thread_status.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vector>

@interface CR4MachSession : NSObject
@property (nonatomic, assign) time_t crashTime;
@property (nonatomic, assign) uint64_t far;
@property (nonatomic, assign) int realCrashedNumber;
@property (nonatomic, assign) BOOL hasBeenHandled;
@property (nonatomic, assign) BOOL collected;
@property (nonatomic, assign) BOOL generated;

@property (nonatomic, copy) NSString *processName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *exceptionType;
@property (nonatomic, copy) NSString *exceptionSubtype;
@property (nonatomic, copy) NSString *exceptionCodes;
@property (nonatomic, copy) NSString *vmInfo;
@property (nonatomic, assign) uint64_t threadNum;
@property (nonatomic, copy) NSString *threadName;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *terminationReason;
@property (nonatomic, strong) NSArray<NSString *> *stackSymbols;
@property (nonatomic, strong) NSArray<NSString *> *loadedImages;
@end

@implementation CR4MachSession
@end

static const char *kCR4MachSessionKey = "kCR4MachSessionKey";
static CR4MachSession *CR4GetSession(id self) {
    if (!self) return nil;
    CR4MachSession *session = (CR4MachSession *)objc_getAssociatedObject(self, kCR4MachSessionKey);
    if (!session) {
        session = [CR4MachSession new];
        objc_setAssociatedObject(self, kCR4MachSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return session;
}

static id CR4IvarValue(id self, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
    if (!ivar) return nil;
    return object_getIvar(self, ivar);
}

static int CR4IvarInt(id self, const char *name, int defVal) {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
    if (!ivar) return defVal;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(int *)((uintptr_t)self + offset);
}

static uint32_t CR4IvarUInt32(id self, const char *name, uint32_t defVal) {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
    if (!ivar) return defVal;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(uint32_t *)((uintptr_t)self + offset);
}

static uint64_t CR4IvarUInt64(id self, const char *name, uint64_t defVal) {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
    if (!ivar) return defVal;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(uint64_t *)((uintptr_t)self + offset);
}

static void *CR4IvarPointer(id self, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(self), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    return *(void **)((uintptr_t)self + offset);
}

static uint64_t CR4ThreadGetID(mach_port_t thread) {
    thread_identifier_info_data_t identifier_info = {0};
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t kr = thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&identifier_info, &count);
    if (kr != KERN_SUCCESS) return 0;
    return identifier_info.thread_id;
}

static uint64_t CR4ThreadNumber(mach_port_t task, mach_port_t thread) {
    uint64_t desired_id = CR4ThreadGetID(thread);
    thread_act_port_array_t threads = NULL;
    mach_msg_type_number_t thread_count = 0;
    if (task_threads(task, &threads, &thread_count) == KERN_SUCCESS && threads) {
        for (unsigned int i = 0; i < thread_count; i++) {
            if (CR4ThreadGetID(threads[i]) == desired_id) {
                vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_act_port_t) * thread_count);
                return i;
            }
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_act_port_t) * thread_count);
    }
    return 0;
}

static void CR4SharedInit(id self, mach_port_t task, mach_port_t thread) {
    CR4MachSession *session = CR4GetSession(self);
    session.crashTime = time(NULL);
    mach_port_t realThread = MACH_PORT_NULL;
    uint64_t far = 0;

    if (task != MACH_PORT_NULL) {
        thread_act_port_array_t threads = NULL;
        mach_msg_type_number_t thread_count = 0;
        if (task_threads(task, &threads, &thread_count) == KERN_SUCCESS && threads) {
            for (unsigned int i = 0; i < thread_count; i++) {
                arm_exception_state64_t state = {0};
                mach_msg_type_number_t count = sizeof(state) / sizeof(natural_t);
                kern_return_t kr = thread_get_state(threads[i], ARM_EXCEPTION_STATE64, (thread_state_t)&state, &count);
                if (kr == KERN_SUCCESS && (state.__esr & 0xFC000000) != 0x54000000 && state.__esr != 0) {
                    realThread = threads[i];
                    far = state.__far;
                    break;
                }
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_act_port_t) * thread_count);
        }
    }

    session.hasBeenHandled = (task != MACH_PORT_NULL) ? CR4ProcessHasBeenHandled(task) : NO;
    uint64_t crashingAddr = CR4IvarUInt64(self, "_crashingAddress", 0);
    session.far = crashingAddr ? crashingAddr : far;
    if (realThread == MACH_PORT_NULL) realThread = thread;
    session.realCrashedNumber = (task != MACH_PORT_NULL && realThread != MACH_PORT_NULL) ? (int)CR4ThreadNumber(task, realThread) : -1;
}

static BOOL CR4IsExceptionNonFatal(id self) {
    SEL sel = NSSelectorFromString(@"isExceptionNonFatal");
    if ([self respondsToSelector:sel]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(self, sel);
    }
    void *exitSnapshot = CR4IvarPointer(self, "_exit_snapshot");
    int64_t *exceptionCode = (int64_t *)CR4IvarPointer(self, "_exceptionCode");
    if (!exitSnapshot && exceptionCode && (exceptionCode[0] >> 58 != 10)) {
        return NO;
    }
    return YES;
}

static NSString *CR4DecodeSignal(id self, int sig) {
    for (NSString *selName in @[@"decode_signal", @"signalName"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([self respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(self, sel);
            if ([val isKindOfClass:[NSString class]]) return val;
        }
    }
    return @"SIGNUNKN";
}

static void CR4CollectMachCrash(id self) {
    CR4MachSession *session = CR4GetSession(self);
    if (session.hasBeenHandled || session.collected) return;

    int sig = CR4IvarInt(self, "_signal", 0);
    NSString *procName = (NSString *)CR4IvarValue(self, "_procName");
    if (!procName.length) {
        SEL sel = NSSelectorFromString(@"procName");
        if ([self respondsToSelector:sel]) {
            procName = ((id (*)(id, SEL))objc_msgSend)(self, sel);
        }
    }
    session.processName = procName ?: @"Unknown";

    if (sig == 0 || sig == SIGKILL || CR4IsProcessBlacklisted(session.processName)) {
        return;
    }

    mach_port_t task = (mach_port_t)CR4IvarUInt32(self, "_task", MACH_PORT_NULL);
    int threadNum = CR4IvarInt(self, "_crashedThreadNumber", 0);

    int64_t *oldCodes = (int64_t *)CR4IvarPointer(self, "_exceptionCode");
    uint32_t codeCount = CR4IvarUInt32(self, "_exceptionCodeCount", 0);
    std::vector<int64_t> codes;
    if (oldCodes && codeCount > 0) {
        for (uint32_t i = 0; i < codeCount; i++) codes.push_back(oldCodes[i]);
    } else {
        codes.push_back(0);
        codes.push_back(0);
    }

    int exceptionType = CR4IvarInt(self, "_exceptionType", 0);
    if (exceptionType == EXC_CORPSE_NOTIFY && session.realCrashedNumber != -1) {
        if (codes.size() < 2) codes.resize(2);
        codes[1] = (int64_t)session.far;
        if (exceptionType == EXC_BAD_ACCESS) {
            threadNum = session.realCrashedNumber;
        }
    }

    if (CR4IsExceptionNonFatal(self)) return;

    session.bundleID = (NSString *)CR4IvarValue(self, "_bundle_id") ?: @"";
    NSString *sigName = CR4DecodeSignal(self, sig);
    session.exceptionType = [NSString stringWithFormat:@"EXC_%d (%@)", exceptionType, sigName];
    session.exceptionCodes = [NSString stringWithFormat:@"0x%llx, 0x%llx", (unsigned long long)codes[0], codes.size() > 1 ? (unsigned long long)codes[1] : 0ULL];
    session.threadNum = (uint64_t)threadNum;

    NSArray *threadNames = (NSArray *)CR4IvarValue(self, "_threadNames");
    if ([threadNames isKindOfClass:[NSArray class]] && (NSUInteger)threadNum < threadNames.count) {
        session.threadName = threadNames[threadNum];
    } else {
        NSArray *threadInfos = (NSArray *)CR4IvarValue(self, "_threadInfos");
        if ([threadInfos isKindOfClass:[NSArray class]] && (NSUInteger)threadNum < threadInfos.count) {
            NSDictionary *info = threadInfos[threadNum];
            session.threadName = info[@"name"] ?: info[@"queue"];
        }
    }

    NSMutableArray<NSString *> *symbols = [NSMutableArray array];
    NSArray *threadInfos = (NSArray *)CR4IvarValue(self, "_threadInfos");
    NSArray *taskImages = (NSArray *)CR4IvarValue(self, "_usedImages") ?: (NSArray *)CR4IvarValue(self, "_taskImages");
    if ([threadInfos isKindOfClass:[NSArray class]] && [taskImages isKindOfClass:[NSArray class]]) {
        NSUInteger idx = (NSUInteger)threadNum < threadInfos.count ? (NSUInteger)threadNum : 0;
        NSDictionary *tInfo = threadInfos[idx];
        NSArray *frames = tInfo[@"frames"];
        if ([frames isKindOfClass:[NSArray class]]) {
            for (NSUInteger i = 0; i < frames.count; i++) {
                NSDictionary *frame = frames[i];
                NSUInteger imageIndex = [frame[@"imageIndex"] unsignedIntegerValue];
                if (imageIndex < taskImages.count) {
                    NSDictionary *image = taskImages[imageIndex];
                    NSUInteger imgBase = [image[@"base"] unsignedIntegerValue];
                    NSUInteger imgOffset = [frame[@"imageOffset"] unsignedIntegerValue];
                    NSString *symName = frame[@"symbol"] ?: @"";
                    NSString *imgName = image[@"name"] ?: @"";
                    NSString *line = [NSString stringWithFormat:@"%-4lu %-36@ 0x%016llx 0x%llx + 0x%llx // %@",
                                      (unsigned long)i, imgName, (unsigned long long)(imgBase + imgOffset),
                                      (unsigned long long)imgBase, (unsigned long long)imgOffset, symName];
                    [symbols addObject:line];
                }
            }
        }
    }
    session.stackSymbols = symbols;

    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSArray *rawImages = (NSArray *)CR4IvarValue(self, "_binaryImages") ?: (NSArray *)CR4IvarValue(self, "_taskImages");
    if ([rawImages isKindOfClass:[NSArray class]]) {
        for (id item in rawImages) {
            if ([item isKindOfClass:[NSDictionary class]]) {
                NSString *p = item[@"ExecutablePath"] ?: item[@"path"] ?: item[@"name"];
                if (p.length) [images addObject:p];
            } else if ([item respondsToSelector:NSSelectorFromString(@"symbolInfo")]) {
                id sInfo = ((id (*)(id, SEL))objc_msgSend)(item, NSSelectorFromString(@"symbolInfo"));
                if (sInfo && [sInfo respondsToSelector:NSSelectorFromString(@"path")]) {
                    NSString *p = ((id (*)(id, SEL))objc_msgSend)(sInfo, NSSelectorFromString(@"path"));
                    if (p.length) [images addObject:p];
                }
            }
        }
    }
    session.loadedImages = images;

    NSString *version = (NSString *)CR4IvarValue(self, "_short_vers") ?: (NSString *)CR4IvarValue(self, "_bundle_vers");
    session.version = version ?: @"";
    session.terminationReason = (NSString *)CR4IvarValue(self, "_terminator_reason") ?: @"";
    session.collected = YES;
}

static void CR4GenerateMachReport(id self) {
    CR4MachSession *session = CR4GetSession(self);
    if (session.hasBeenHandled || session.generated) return;
    if (!session.collected) CR4CollectMachCrash(self);
    if (!session.collected) return;
    session.generated = YES;

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:session.crashTime];
    NSString *dateString = CR4StringFromDate(now, CR4DateFormatPretty);
    NSString *device = [NSString stringWithFormat:@"%@, iOS %@", CR4DeviceName(), CR4DeviceVersion()];
    NSString *culprit = CR4DetermineCulprit(session.stackSymbols);

    NSMutableString *log = [NSMutableString stringWithFormat:
        @"Date: %@\nProcess: %@\nBundle id: %@\nDevice: %@\n",
        dateString, session.processName, session.bundleID, device];
    if (session.version.length) [log appendFormat:@"Bundle version: %@\n", session.version];
    [log appendFormat:@"\nException type: %@\nException codes: %@\nCulprit: %@\n",
        session.exceptionType, session.exceptionCodes, culprit];
    if (session.terminationReason.length) [log appendFormat:@"Termination Reason: %@\n", session.terminationReason];
    [log appendFormat:@"\nTriggered by thread: %llu\nThread name: %@\nCall stack:\n%@\n",
        session.threadNum, session.threadName ?: @"", [session.stackSymbols componentsJoinedByString:@"\n"]];

    if (session.loadedImages.count) {
        [log appendString:@"\nLoaded images:\n"];
        for (NSUInteger i = 0; i < session.loadedImages.count; i++) {
            [log appendFormat:@"%lu: %@\n", (unsigned long)i, session.loadedImages[i]];
        }
    }

    NSDictionary *extra = @{
        @"ProcessName": session.processName ?: @"",
        @"ProcessBundleID": session.bundleID ?: @"",
        @"Culprit": culprit ?: @"Unknown"
    };
    log = [CR4AddInfoToLog(log, extra) mutableCopy];

    NSString *filenameDate = CR4StringFromDate(now, CR4DateFormatFilename);
    NSString *filename = [NSString stringWithFormat:@"%@@%@", session.processName, filenameDate];
    
    NSLog(@"[Cr4shedMach] Writing Mach crash log for %@ to %@", session.processName, filename);
    CR4WriteLog(log, filename);
}

static void (*orig_loadBundleInfo)(id, SEL);
static void hooked_loadBundleInfo(id self, SEL _cmd) {
    if (orig_loadBundleInfo) orig_loadBundleInfo(self, _cmd);
    CR4CollectMachCrash(self);
    CR4GenerateMachReport(self);
}

static void (*orig_generateLogAtLevel)(id, SEL, BOOL, id);
static void hooked_generateLogAtLevel(id self, SEL _cmd, BOOL level, id block) {
    if (orig_generateLogAtLevel) orig_generateLogAtLevel(self, _cmd, level, block);
    CR4GenerateMachReport(self);
}

static id (*orig_init7)(id, SEL, uint32_t, int32_t, uint32_t, uint64_t, int32_t, unsigned int *, uint32_t);
static id hooked_init7(id self, SEL _cmd, uint32_t task, int32_t type, uint32_t thread, uint64_t threadId, int32_t flavor, unsigned int *state, uint32_t count) {
    id res = orig_init7 ? orig_init7(self, _cmd, task, type, thread, threadId, flavor, state, count) : self;
    CR4SharedInit(res, task, thread);
    return res;
}

static id (*orig_init6)(id, SEL, uint32_t, int32_t, uint32_t, int32_t, unsigned int *, uint32_t);
static id hooked_init6(id self, SEL _cmd, uint32_t task, int32_t type, uint32_t thread, int32_t flavor, unsigned int *state, uint32_t count) {
    id res = orig_init6 ? orig_init6(self, _cmd, task, type, thread, flavor, state, count) : self;
    CR4SharedInit(res, task, thread);
    return res;
}

__attribute__((constructor))
static void CR4MachInit(void) {
    @autoreleasepool {
        NSLog(@"[Cr4shedMach] Loaded into %@", [[NSProcessInfo processInfo] processName]);
        Class targetCls = NSClassFromString(@"OSACrashReport") ?: NSClassFromString(@"CrashReport") ?: NSClassFromString(@"LegacyCrashReport");
        if (!targetCls) {
            int numClasses = objc_getClassList(NULL, 0);
            if (numClasses > 0) {
                Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
                numClasses = objc_getClassList(classes, numClasses);
                for (int i = 0; i < numClasses; i++) {
                    const char *name = class_getName(classes[i]);
                    if (strcmp(name, "OSACrashReport") == 0 || strcmp(name, "CrashReport") == 0) {
                        targetCls = classes[i];
                        break;
                    }
                }
                free(classes);
            }
        }

        if (targetCls) {
            NSLog(@"[Cr4shedMach] Hooking target class: %s", class_getName(targetCls));
            CR4HookMessage(targetCls, NSSelectorFromString(@"loadBundleInfo"), (IMP)hooked_loadBundleInfo, (IMP *)&orig_loadBundleInfo);
            CR4HookMessage(targetCls, NSSelectorFromString(@"generateLogAtLevel:withBlock:"), (IMP)hooked_generateLogAtLevel, (IMP *)&orig_generateLogAtLevel);
            CR4HookMessage(targetCls, NSSelectorFromString(@"initWithTask:exceptionType:thread:threadId:threadStateFlavor:threadState:threadStateCount:"), (IMP)hooked_init7, (IMP *)&orig_init7);
            CR4HookMessage(targetCls, NSSelectorFromString(@"initWithTask:exceptionType:thread:threadStateFlavor:threadState:threadStateCount:"), (IMP)hooked_init6, (IMP *)&orig_init6);
        } else {
            NSLog(@"[Cr4shedMach] Target CrashReport class not found");
        }
    }
}
