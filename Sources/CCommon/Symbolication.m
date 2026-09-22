#import "Cr4shedCommon.h"
#import <CoreSymbolication/CoreSymbolication.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <string.h>

// 全局注入模块只在真正符号化时加载该框架，避免增加每个宿主的启动依赖。
#define CR4_SYMBOLICATION_FUNCTIONS(X) \
    X(CSSymbolicatorCreateWithURLAndArchitecture) \
    X(CSSymbolicatorCreateWithTask) \
    X(CSSymbolicatorGetSymbolOwnerWithUUIDAtTime) \
    X(CSSymbolicatorGetSymbolOwnerWithAddressAtTime) \
    X(CSSymbolicatorGetSymbolOwnerWithNameAtTime) \
    X(CSSymbolOwnerGetBaseAddress) \
    X(CSSymbolOwnerGetSymbolWithAddress) \
    X(CSSymbolOwnerGetSymbolWithName) \
    X(CSSymbolOwnerGetPath) \
    X(CSSymbolGetName) \
    X(CSSymbolGetRange) \
    X(CSIsNull) \
    X(CSRelease)

static struct {
#define CR4_DECLARE_SYMBOL(name) __typeof__(&name) name;
    CR4_SYMBOLICATION_FUNCTIONS(CR4_DECLARE_SYMBOL)
#undef CR4_DECLARE_SYMBOL
} symbolication;

static bool CR4LoadSymbolication(void) {
    static dispatch_once_t once;
    static bool available = false;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return;
        bool complete = true;
#define CR4_RESOLVE_SYMBOL(name) \
        symbolication.name = (__typeof__(symbolication.name))dlsym(handle, #name); \
        complete = complete && symbolication.name != NULL;
        CR4_SYMBOLICATION_FUNCTIONS(CR4_RESOLVE_SYMBOL)
#undef CR4_RESOLVE_SYMBOL
        // 保留句柄，确保函数指针在并发报告期间始终有效；接口缺失时保留原始栈。
        available = complete;
    });
    return available;
}

NSString *CR4NameForRemoteSymbol(uint64_t addr, NSString *path, NSString *uuidStr, uint64_t imgAddr, int32_t archCpuType, int32_t archCpuSubtype) {
    NSString *name = nil;
    if (!path.length || !uuidStr.length || !addr || !imgAddr) return nil;
    if (!CR4LoadSymbolication()) return nil;
    CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, (__bridge CFStringRef)uuidStr);
    if (!uuid) return nil;
    CSArchitecture arch;
    arch.cpu_type = archCpuType;
    arch.cpu_subtype = archCpuSubtype;
    CSSymbolicatorRef symbolicator = symbolication.CSSymbolicatorCreateWithURLAndArchitecture((__bridge CFURLRef)[NSURL fileURLWithPath:path], arch);
    if (!symbolication.CSIsNull(symbolicator)) {
        CSSymbolOwnerRef owner = symbolication.CSSymbolicatorGetSymbolOwnerWithUUIDAtTime(symbolicator, uuid, kCSNow);
        if (!symbolication.CSIsNull(owner)) {
            uint64_t base = symbolication.CSSymbolOwnerGetBaseAddress(owner);
            uint64_t symOffset = addr - imgAddr + base;
            CSSymbolRef symbol = symbolication.CSSymbolOwnerGetSymbolWithAddress(owner, symOffset);
            if (!symbolication.CSIsNull(symbol)) {
                const char *c_name = symbolication.CSSymbolGetName(symbol);
                if (c_name) name = [NSString stringWithUTF8String:c_name];
                else name = [NSString stringWithFormat:@"func_%llx", symbolication.CSSymbolGetRange(symbol).location];
            }
        }
        symbolication.CSRelease(symbolicator);
    }
    CFRelease(uuid);
    return name;
}

static NSString *CR4NameForLocalSymbolWithSymbolicator(NSNumber *addrNum, uint64_t *outOffset, CSSymbolicatorRef symbolicator) {
    NSString *name = nil;
    void *symAddr = (void *)[addrNum unsignedLongLongValue];
    Dl_info info = { NULL, NULL, NULL, NULL };
    int success = dladdr(symAddr, &info);
    if (!symAddr || !success) return nil;
    CSSymbolOwnerRef owner = symbolication.CSSymbolicatorGetSymbolOwnerWithAddressAtTime(symbolicator, (vm_address_t)symAddr, kCSNow);
    if (!symbolication.CSIsNull(owner)) {
        uint64_t imgAddr = (uint64_t)info.dli_fbase;
        if (outOffset) *outOffset = (uint64_t)symAddr - imgAddr;
        CSSymbolRef symbol = symbolication.CSSymbolOwnerGetSymbolWithAddress(owner, (mach_vm_address_t)symAddr);
        if (!symbolication.CSIsNull(symbol)) {
            const char *c_name = symbolication.CSSymbolGetName(symbol);
            if (c_name) name = [NSString stringWithUTF8String:c_name];
            else name = [NSString stringWithFormat:@"func_%llx", symbolication.CSSymbolGetRange(symbol).location - imgAddr];
        }
    }
    return name;
}

NSString *CR4NameForLocalSymbol(NSNumber *addrNum, uint64_t *outOffset) {
    if (!CR4LoadSymbolication()) return nil;
    CSSymbolicatorRef symbolicator = symbolication.CSSymbolicatorCreateWithTask(mach_task_self());
    if (symbolication.CSIsNull(symbolicator)) return nil;
    NSString *name = CR4NameForLocalSymbolWithSymbolicator(addrNum, outOffset, symbolicator);
    symbolication.CSRelease(symbolicator);
    return name;
}

mach_vm_address_t CR4FindSymbolInTask(mach_port_t task, const char *symbolName, NSString *lastPathComponent, NSString **imageName) {
    if (!task || !symbolName || !lastPathComponent.length) return 0;
    if (!CR4LoadSymbolication()) return 0;
    CSSymbolicatorRef symbolicator = symbolication.CSSymbolicatorCreateWithTask(task);
    if (symbolication.CSIsNull(symbolicator)) return 0;
    mach_vm_address_t addr = 0;
    NSString *imagePath = nil;
    
    // 优先通过 SymbolOwner 快速定位特定模块，避免遍历进程几十万个符号导致 ReportCrash 占用 100% CPU
    CSSymbolOwnerRef owner = symbolication.CSSymbolicatorGetSymbolOwnerWithNameAtTime(symbolicator, [lastPathComponent UTF8String], kCSNow);
    if (!symbolication.CSIsNull(owner)) {
        CSSymbolRef symbol = symbolication.CSSymbolOwnerGetSymbolWithName(owner, symbolName);
        if (!symbolication.CSIsNull(symbol)) {
            addr = symbolication.CSSymbolGetRange(symbol).location - symbolication.CSSymbolOwnerGetBaseAddress(owner);
            const char *c_path = symbolication.CSSymbolOwnerGetPath(owner);
            if (c_path) imagePath = [NSString stringWithUTF8String:c_path];
        }
    }
    
    symbolication.CSRelease(symbolicator);
    if (imageName) *imageName = imagePath;
    return addr;
}

static NSArray *CR4SymbolicatedStackSymbols(NSArray *callStackSymbols, NSArray *callStackReturnAddresses) {
    if (!callStackSymbols.count || !callStackReturnAddresses.count) return callStackSymbols ?: @[];
    if (!CR4LoadSymbolication()) return callStackSymbols;
    // 一次异常复用一个符号化器，避免每个栈帧重新构建整个进程的符号上下文。
    CSSymbolicatorRef symbolicator = symbolication.CSSymbolicatorCreateWithTask(mach_task_self());
    if (symbolication.CSIsNull(symbolicator)) return callStackSymbols;
    @try {
        NSMutableArray *symArr = [callStackSymbols mutableCopy];
        NSUInteger count = MIN(callStackSymbols.count, callStackReturnAddresses.count);
        for (NSUInteger i = 0; i < count; i++) {
            @autoreleasepool {
                uint64_t offset = 0;
                NSString *symName = CR4NameForLocalSymbolWithSymbolicator(callStackReturnAddresses[i], &offset, symbolicator);
                if (!symName.length) continue;
                NSMutableArray<NSString *> *components = [[symArr[i] componentsSeparatedByString:@" "] mutableCopy];
                NSMutableArray<NSString *> *newComponents = [[NSMutableArray alloc] initWithCapacity:3];
                for (NSString *comp in components) {
                    if (comp.length) {
                        [newComponents addObject:comp];
                        if (newComponents.count >= 3) break;
                    }
                }
                if (newComponents.count < 3) continue;
                NSString *newSym = [newComponents[0] stringByPaddingToLength:4 withString:@" " startingAtIndex:0];
                newSym = [newSym stringByAppendingString:newComponents[1]];
                newSym = [newSym stringByPaddingToLength:40 withString:@" " startingAtIndex:0];
                newSym = [newSym stringByAppendingString:newComponents[2]];
                NSUInteger padding = newSym.length + 30;
                newSym = [NSString stringWithFormat:@"%@ 0x%llx + 0x%llx", newSym, [callStackReturnAddresses[i] unsignedLongLongValue] - offset, offset];
                newSym = [newSym stringByPaddingToLength:padding withString:@" " startingAtIndex:0];
                newSym = [newSym stringByAppendingFormat:@" // %@", symName];
                symArr[i] = newSym;
            }
        }
        return symArr;
    } @finally {
        symbolication.CSRelease(symbolicator);
    }
}

NSArray *CR4SymbolicatedException(NSException *e) {
    @autoreleasepool {
        return CR4SymbolicatedStackSymbols(e.callStackSymbols, e.callStackReturnAddresses);
    }
}
