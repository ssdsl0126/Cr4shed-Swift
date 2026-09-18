#import "Cr4shedCommon.h"
#import <CoreSymbolication/CoreSymbolication.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <string.h>

NSString *CR4NameForRemoteSymbol(uint64_t addr, NSString *path, NSString *uuidStr, uint64_t imgAddr, int32_t archCpuType, int32_t archCpuSubtype) {
    NSString *name = nil;
    if (!path.length || !uuidStr.length || !addr || !imgAddr) return nil;
    CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, (__bridge CFStringRef)uuidStr);
    if (!uuid) return nil;
    CSArchitecture arch;
    arch.cpu_type = archCpuType;
    arch.cpu_subtype = archCpuSubtype;
    CSSymbolicatorRef symbolicator = CSSymbolicatorCreateWithURLAndArchitecture((__bridge CFURLRef)[NSURL fileURLWithPath:path], arch);
    if (!CSIsNull(symbolicator)) {
        CSSymbolOwnerRef owner = CSSymbolicatorGetSymbolOwnerWithUUIDAtTime(symbolicator, uuid, kCSNow);
        if (!CSIsNull(owner)) {
            uint64_t base = CSSymbolOwnerGetBaseAddress(owner);
            uint64_t symOffset = addr - imgAddr + base;
            CSSymbolRef symbol = CSSymbolOwnerGetSymbolWithAddress(owner, symOffset);
            if (!CSIsNull(symbol)) {
                const char *c_name = CSSymbolGetName(symbol);
                if (c_name) name = [NSString stringWithUTF8String:c_name];
                else name = [NSString stringWithFormat:@"func_%llx", CSSymbolGetRange(symbol).location];
            }
        }
        CSRelease(symbolicator);
    }
    CFRelease(uuid);
    return name;
}

NSString *CR4NameForLocalSymbol(NSNumber *addrNum, uint64_t *outOffset) {
    NSString *name = nil;
    void *symAddr = (void *)[addrNum unsignedLongLongValue];
    Dl_info info = { NULL, NULL, NULL, NULL };
    int success = dladdr(symAddr, &info);
    if (!symAddr || !success) return nil;
    CSSymbolicatorRef symbolicator = CSSymbolicatorCreateWithTask(mach_task_self());
    if (CSIsNull(symbolicator)) return nil;
    CSSymbolOwnerRef owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(symbolicator, (vm_address_t)symAddr, kCSNow);
    if (!CSIsNull(owner)) {
        uint64_t imgAddr = (uint64_t)info.dli_fbase;
        if (outOffset) *outOffset = (uint64_t)symAddr - imgAddr;
        CSSymbolRef symbol = CSSymbolOwnerGetSymbolWithAddress(owner, (mach_vm_address_t)symAddr);
        if (!CSIsNull(symbol)) {
            const char *c_name = CSSymbolGetName(symbol);
            if (c_name) name = [NSString stringWithUTF8String:c_name];
            else name = [NSString stringWithFormat:@"func_%llx", CSSymbolGetRange(symbol).location - imgAddr];
        }
    }
    CSRelease(symbolicator);
    return name;
}

mach_vm_address_t CR4FindSymbolInTask(mach_port_t task, const char *symbolName, NSString *lastPathComponent, NSString **imageName) {
    if (!task || !symbolName || !lastPathComponent.length) return 0;
    CSSymbolicatorRef symbolicator = CSSymbolicatorCreateWithTask(task);
    if (CSIsNull(symbolicator)) return 0;
    mach_vm_address_t addr = 0;
    NSString *imagePath = nil;
    
    // 优先通过 SymbolOwner 快速定位特定模块，避免遍历进程几十万个符号导致 ReportCrash 占用 100% CPU
    CSSymbolOwnerRef owner = CSSymbolicatorGetSymbolOwnerWithNameAtTime(symbolicator, [lastPathComponent UTF8String], kCSNow);
    if (!CSIsNull(owner)) {
        CSSymbolRef symbol = CSSymbolOwnerGetSymbolWithName(owner, symbolName);
        if (!CSIsNull(symbol)) {
            addr = CSSymbolGetRange(symbol).location - CSSymbolOwnerGetBaseAddress(owner);
            const char *c_path = CSSymbolOwnerGetPath(owner);
            if (c_path) imagePath = [NSString stringWithUTF8String:c_path];
        }
    }
    
    CSRelease(symbolicator);
    if (imageName) *imageName = imagePath;
    return addr;
}

static NSArray *CR4SymbolicatedStackSymbols(NSArray *callStackSymbols, NSArray *callStackReturnAddresses) {
    if (!callStackSymbols.count || !callStackReturnAddresses.count) return callStackSymbols ?: @[];
    NSMutableArray *symArr = [callStackSymbols mutableCopy];
    NSUInteger count = MIN(callStackSymbols.count, callStackReturnAddresses.count);
    for (uint32_t i = 0; i < count; i++) {
        uint64_t offset = 0;
        NSString *symName = CR4NameForLocalSymbol(callStackReturnAddresses[i], &offset);
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
    return symArr;
}

NSArray *CR4SymbolicatedException(NSException *e) {
    @autoreleasepool {
        return CR4SymbolicatedStackSymbols(e.callStackSymbols, e.callStackReturnAddresses);
    }
}
