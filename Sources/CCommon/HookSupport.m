#include "Cr4shedCommon.h"
#include <dlfcn.h>
#include <objc/runtime.h>

typedef void (*CR4MSHookFunction)(void *, void *, void **);
typedef void (*CR4MSHookMessageEx)(Class, SEL, IMP, IMP *);

static void *CR4HookLib(void) {
    static void *handle = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *candidates[] = {
            "/usr/lib/libellekit.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            "/usr/lib/libsubstrate.dylib",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/usr/lib/libhooker.dylib",
            "/var/jb/usr/lib/libhooker.dylib",
            NULL
        };
        for (int i = 0; candidates[i]; i++) {
            handle = dlopen(candidates[i], RTLD_NOW);
            if (handle) break;
            handle = dlopen(CR4JBRootPathC(candidates[i]), RTLD_NOW);
            if (handle) break;
        }
        if (!handle) handle = RTLD_DEFAULT;
    });
    return handle;
}

void CR4HookFunction(void *symbol, void *replace, void **original) {
    if (!symbol || !replace) return;
    CR4MSHookFunction fn = (CR4MSHookFunction)dlsym(CR4HookLib(), "MSHookFunction");
    if (!fn) fn = (CR4MSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (fn) {
        fn(symbol, replace, original);
        return;
    }
    if (original) *original = symbol;
}

void CR4HookMessage(Class cls, SEL sel, IMP imp, IMP *orig) {
    if (!cls || !sel || !imp) return;
    CR4MSHookMessageEx fn = (CR4MSHookMessageEx)dlsym(CR4HookLib(), "MSHookMessageEx");
    if (!fn) fn = (CR4MSHookMessageEx)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (fn) {
        fn(cls, sel, imp, orig);
        return;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return;
    IMP previous = method_setImplementation(m, imp);
    if (orig) *orig = previous;
}
