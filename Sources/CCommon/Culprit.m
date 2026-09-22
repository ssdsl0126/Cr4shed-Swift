#import "Cr4shedCommon.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>

static inline uintptr_t CR4StripPAC(uintptr_t addr) {
    return addr & 0x0000007fffffffffULL;
}

static BOOL CR4IsSelfImage(NSString *name) {
    if (!name.length) return YES;
    NSString *lower = [name lowercaseString];
    return [lower containsString:@"cr4shed"] || [lower containsString:@"0cr4shed"];
}

static BOOL CR4IsThirdPartyTweakPath(const char *path) {
    if (!path) return NO;
    if (strstr(path, "MobileSubstrate/DynamicLibraries") || strstr(path, "TweakInject") || strstr(path, "/var/jb/")) {
        return YES;
    }
    if (strncmp(path, "/System/", 8) != 0 &&
        strncmp(path, "/usr/lib/", 9) != 0 &&
        strncmp(path, "/Library/Apple/", 15) != 0) {
        return YES;
    }
    return NO;
}

NSArray<NSString *> *CR4GetAllKnownTweakNames(void) {
    static NSArray<NSString *> *cachedTweaks = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet<NSString *> *tweaks = [NSMutableSet set];
        NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. 扫描已知插件目录
    NSArray<NSString *> *tweakDirs = @[
        CR4JBRootPath(@"/Library/MobileSubstrate/DynamicLibraries"),
        CR4JBRootPath(@"/usr/lib/TweakInject"),
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries",
        @"/var/jb/usr/lib/TweakInject",
        @"/Library/MobileSubstrate/DynamicLibraries"
    ];
    for (NSString *dir in tweakDirs) {
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f hasSuffix:@".dylib"] && !CR4IsSelfImage(f)) {
                [tweaks addObject:f];
            }
        }
    }

    // 2. 扫描当前进程已加载的非系统镜像
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (CR4IsThirdPartyTweakPath(path)) {
            NSString *name = [[NSString stringWithUTF8String:path] lastPathComponent];
            if ([name hasSuffix:@".dylib"] && !CR4IsSelfImage(name)) {
                [tweaks addObject:name];
            }
        }
    }

        cachedTweaks = [tweaks allObjects];
    });
    return cachedTweaks;
}

NSString *CR4GetImageFromSymbol(NSString *symbol) {
    if (!symbol.length) return @"";
    NSArray *components = [symbol componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *nonEmpty = [NSMutableArray array];
    for (NSString *comp in components) {
        if (comp.length > 0) [nonEmpty addObject:comp];
    }
    if (nonEmpty.count >= 2) {
        return nonEmpty[1];
    }
    return @"";
}

NSString *CR4DetermineCulpritWithAddresses(NSArray *symbols, NSArray *addresses) {
    // 1. 优先通过 dladdr 精准判定内存指针所属模块
    if (addresses && addresses.count > 0) {
        for (NSNumber *addrNum in addresses) {
            uintptr_t raw = (uintptr_t)[addrNum unsignedLongLongValue];
            void *addr = (void *)CR4StripPAC(raw);
            if (!addr) continue;
            Dl_info info;
            if (dladdr(addr, &info) && info.dli_fname) {
                const char *fname = info.dli_fname;
                if (CR4IsThirdPartyTweakPath(fname)) {
                    NSString *name = [[NSString stringWithUTF8String:fname] lastPathComponent];
                    if (!CR4IsSelfImage(name)) {
                        return name;
                    }
                }
            }
        }
    }

    // 2. 将调用栈符号与系统已安装/已加载的插件全量比对（不依赖脆弱的空格分割）
    NSArray<NSString *> *allTweaks = CR4GetAllKnownTweakNames();
    for (NSString *symbol in symbols) {
        if (!symbol.length) continue;
        for (NSString *tweak in allTweaks) {
            NSString *tweakStem = [tweak stringByDeletingPathExtension];
            // 只要符号行包含插件名（带或不带 .dylib），直接命中
            if ([symbol rangeOfString:tweak options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [symbol rangeOfString:tweakStem options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return tweak;
            }
        }
    }

    // 3. 原版 getImage 兼容兜底
    for (NSString *symbol in symbols) {
        NSString *image = CR4GetImageFromSymbol(symbol);
        if (!image.length || CR4IsSelfImage(image)) continue;
        NSString *imageWithExt = [image hasSuffix:@".dylib"] ? image : [image stringByAppendingPathExtension:@"dylib"];
        for (NSString *tweak in allTweaks) {
            if ([tweak caseInsensitiveCompare:image] == NSOrderedSame ||
                [tweak caseInsensitiveCompare:imageWithExt] == NSOrderedSame) {
                return tweak;
            }
        }
    }

    return @"Unknown";
}

NSString *CR4DetermineCulprit(NSArray *symbols) {
    return CR4DetermineCulpritWithAddresses(symbols, nil);
}

NSArray<NSString *> *CR4HardBlacklist(void) {
    return @[
        @"ProtectedCloudKeySyncing", @"gssc", @"awdd", @"biometrickitd", @"spindump",
        @"keybagd", @"ReportMemoryException", @"nsurlsessiond", @"locationd", @"coreduetd",
        @"mDNSResponder", @"hangreporter", @"nanoregistrylaunchd", @"nanoregistryd",
        @"mobilewatchdog", @"misd", @"dasd", @"passd", @"CircleJoinRequested", @"suggestd"
    ];
}

bool CR4IsHardBlacklisted(NSString *procName) {
    if (!procName.length) return true;
    return [CR4HardBlacklist() containsObject:procName];
}
