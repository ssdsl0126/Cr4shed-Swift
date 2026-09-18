#import "Cr4shedCommon.h"
#import <objc/message.h>
#include <dlfcn.h>

BOOL CR4BoolMessage(id object, SEL sel) {
    if (!object || !sel || ![object respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
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

bool CR4ParseThreadState(const void *bytes, size_t size, int32_t flavor, CR4ParsedThreadState *outState) {
    if (!bytes || !outState || size < sizeof(arm_thread_state64_t)) return false;
    if (flavor != ARM_THREAD_STATE64 && flavor != 1) return false;
    const arm_thread_state64_t *state = (const arm_thread_state64_t *)bytes;
    memset(outState, 0, sizeof(*outState));
    outState->pc = (uint64_t)__darwin_arm_thread_state64_get_pc(*state);
    outState->lr = (uint64_t)__darwin_arm_thread_state64_get_lr(*state);
    outState->cpsr = state->__cpsr;
    for (int i = 0; i < 29; i++) {
        outState->x[i] = state->__x[i];
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
        NSLog(@"[cr4shedd] CR4DisplaySystemNotice called with title: %@, msg: %@", title, message);
        if (fnAlert) {
            CFOptionFlags flags = 0;
            fnAlert(30.0, 3, NULL, NULL, NULL, (__bridge CFStringRef)(title ?: @"Cr4shed"), (__bridge CFStringRef)(message ?: @""), CFSTR("好"), NULL, NULL, &flags);
        } else if (fnNotice) {
            fnNotice(30.0, 0, NULL, NULL, NULL, (__bridge CFStringRef)(title ?: @"Cr4shed"), (__bridge CFStringRef)(message ?: @""), CFSTR("好"));
        }
    });
}
