#import "Cr4shedCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

@interface NSObject (CR4NotificationCenterInitializer)
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

id CR4CreateNotificationCenter(NSString *bundleID) {
    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithBundleIdentifier:)]) return nil;
    // 使用 ARC 能识别的 alloc/init 方法族，正确转移 +1 所有权。
    // Swift perform(...).takeUnretainedValue() 不会接管 alloc 返回的所有权。
    return [[cls alloc] initWithBundleIdentifier:bundleID];
}

BOOL CR4BoolMessage(id object, SEL sel) {
    if (!object || !sel || ![object respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

NSDictionary *CR4DecodeExceptionDetails(id report) {
    if (!report) return nil;
    SEL selector = NSSelectorFromString(@"decode_exceptionCodes");
    Method method = class_getInstanceMethod(object_getClass(report), selector);
    // 私有接口只在无额外参数、返回对象的签名下调用，避免系统升级后发生 ABI 错配。
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != '@' || returnType[1] == '?') return nil;

    @try {
        id result = ((id (*)(id, SEL))objc_msgSend)(report, selector);
        return [result isKindOfClass:[NSDictionary class]] ? result : nil;
    } @catch (__unused NSException *exception) {
        // 附加诊断不可阻断系统报告或现有 Mach 日志。
        return nil;
    }
}

NSString *CR4ReadStringAtTaskAddress(id report, uint64_t addr) {
    if (!report) return nil;
    SEL sel26 = NSSelectorFromString(@"_readStringAtTaskAddress:maxLength:immutableCheck:isInSharedCache:");
    SEL sel16 = NSSelectorFromString(@"_readStringAtTaskAddress:maxLength:immutableCheck:");
    SEL sel15 = NSSelectorFromString(@"_readStringAtTaskAddress:immutableOnly:maxLength:");
    SEL selAlt = NSSelectorFromString(@"_readStringAtTaskAddress:immutableOnly:maxLength:");
    BOOL imut = NO;
    BOOL inCache = NO;
    if ([report respondsToSelector:sel26]) {
        return ((NSString *(*)(id, SEL, uint64_t, uint64_t, BOOL *, BOOL *))objc_msgSend)(report, sel26, addr, 0, &imut, &inCache);
    }
    if ([report respondsToSelector:sel16]) {
        return ((NSString *(*)(id, SEL, uint64_t, uint64_t, BOOL *))objc_msgSend)(report, sel16, addr, 0, &imut);
    }
    if ([report respondsToSelector:sel15] || [report respondsToSelector:selAlt]) {
        return ((NSString *(*)(id, SEL, uint64_t, BOOL, uint64_t))objc_msgSend)(report, sel15, addr, NO, 0);
    }
    return nil;
}

#import <mach/arm/thread_status.h>

static bool CR4CopyThreadState64(const void *bytes, size_t size, int32_t flavor, arm_thread_state64_t *outState) {
    if (!bytes || !outState) return false;

    const uint8_t *stateBytes = (const uint8_t *)bytes;
    if (flavor == ARM_UNIFIED_THREAD_STATE) {
        if (size < sizeof(arm_state_hdr_t)) return false;

        arm_state_hdr_t header = {0};
        memcpy(&header, stateBytes, sizeof(header));
        if (header.flavor != ARM_THREAD_STATE64 || header.count < ARM_THREAD_STATE64_COUNT) return false;

        size_t payloadSize = size - sizeof(header);
        if ((size_t)header.count > payloadSize / sizeof(natural_t)) return false;
        stateBytes += sizeof(header);
    } else if (flavor == ARM_THREAD_STATE64) {
        if (size < sizeof(arm_thread_state64_t)) return false;
    } else {
        return false;
    }

    memcpy(outState, stateBytes, sizeof(*outState));
    return true;
}

bool CR4ParseThreadState(const void *bytes, size_t size, int32_t flavor, CR4ParsedThreadState *outState) {
    if (!outState) return false;

    arm_thread_state64_t state = {0};
    if (!CR4CopyThreadState64(bytes, size, flavor, &state)) return false;

    // 寄存器只用于生成日志；先在副本上移除 PAC，避免认证失败中断 ReportCrash。
    arm_thread_state64_ptrauth_strip(state);
    memset(outState, 0, sizeof(*outState));
    outState->pc = (uint64_t)arm_thread_state64_get_pc(state);
    outState->lr = (uint64_t)arm_thread_state64_get_lr(state);
    outState->cpsr = state.__cpsr;
    for (int i = 0; i < 29; i++) {
        outState->x[i] = state.__x[i];
    }
    return true;
}

typedef SInt32 (*CR4CFUserNotificationDisplayNoticeFn)(
    CFTimeInterval timeout,
    CFOptionFlags flags,
    CFURLRef iconURL,
    CFURLRef soundURL,
    CFURLRef localizationURL,
    CFStringRef alertHeader,
    CFStringRef alertMessage,
    CFStringRef defaultButtonTitle
);

typedef SInt32 (*CR4CFUserNotificationDisplayAlertFn)(
    CFTimeInterval timeout,
    CFOptionFlags flags,
    CFURLRef iconURL,
    CFURLRef soundURL,
    CFURLRef localizationURL,
    CFStringRef alertHeader,
    CFStringRef alertMessage,
    CFStringRef defaultButtonTitle,
    CFStringRef alternateButtonTitle,
    CFStringRef otherButtonTitle,
    CFOptionFlags *responseFlags
);

void CR4DisplaySystemNotice(NSString *title, NSString *message) {
    static CR4CFUserNotificationDisplayAlertFn fnAlert = NULL;
    static CR4CFUserNotificationDisplayNoticeFn fnNotice = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
        if (handle) {
            fnAlert = (CR4CFUserNotificationDisplayAlertFn)dlsym(handle, "CFUserNotificationDisplayAlert");
            fnNotice = (CR4CFUserNotificationDisplayNoticeFn)dlsym(handle, "CFUserNotificationDisplayNotice");
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CR4DebugLog(@"[cr4shedd] CR4DisplaySystemNotice called with title: %@, msg: %@", title, message);
        if (fnAlert) {
            CFOptionFlags flags = 0;
            fnAlert(30.0, 3, NULL, NULL, NULL, (__bridge CFStringRef)(title ?: @"Cr4shed"), (__bridge CFStringRef)(message ?: @""), CFSTR("好"), NULL, NULL, &flags);
        } else if (fnNotice) {
            fnNotice(30.0, 0, NULL, NULL, NULL, (__bridge CFStringRef)(title ?: @"Cr4shed"), (__bridge CFStringRef)(message ?: @""), CFSTR("好"));
        }
    });
}
